//! Pulling the pull request from the forge.

use anyhow::Result;
use review_model::{Event, HeadMoveOutcome, Origin, PullRequest, SessionView, SyncState, Thread};

use super::ReviewSession;
use crate::comments::{merge_unflushed_threads, reconcile_concurrent_edits, record_agreed_bodies};
use crate::ports::{FastForwardOutcome, ForgeSnapshot};
use crate::reanchor::collect_changed_digest_paths;
use crate::viewed::{apply_queued, drop_stale_marks};

struct HeadMoveSummary {
    outcome: HeadMoveOutcome,
    conflicted_paths: Vec<String>,
    message: Option<String>,
}

impl HeadMoveSummary {
    const fn create_clean(outcome: HeadMoveOutcome) -> Self {
        Self {
            outcome,
            conflicted_paths: Vec::new(),
            message: None,
        }
    }

    const fn create_with_message(outcome: HeadMoveOutcome, message: String) -> Self {
        Self {
            outcome,
            conflicted_paths: Vec::new(),
            message: Some(message),
        }
    }

    fn create_conflict_from_paths(head_sha: &str, conflicted_paths: Vec<String>) -> Self {
        let short_head = build_short_sha_from_sha(head_sha);
        let paths_list = conflicted_paths.join(", ");
        Self {
            outcome: HeadMoveOutcome::RestoreConflict,
            conflicted_paths,
            message: Some(format!(
                "fast-forwarded to {short_head}, but restoring local changes conflicted in {paths_list}"
            )),
        }
    }
}

fn build_short_sha_from_sha(sha: &str) -> &str {
    sha.get(..7).unwrap_or(sha)
}

fn fast_forward_result_to_head_move(result: Result<FastForwardOutcome>) -> HeadMoveSummary {
    result.map_or_else(
        |error| HeadMoveSummary::create_with_message(HeadMoveOutcome::Failed, format!("{error:#}")),
        fast_forward_outcome_to_head_move,
    )
}

fn fast_forward_outcome_to_head_move(outcome: FastForwardOutcome) -> HeadMoveSummary {
    match outcome {
        FastForwardOutcome::AlreadyAtTarget { .. } => {
            HeadMoveSummary::create_clean(HeadMoveOutcome::AlreadyAtTarget)
        }
        FastForwardOutcome::FastForwarded { .. } => {
            HeadMoveSummary::create_clean(HeadMoveOutcome::FastForwarded)
        }
        FastForwardOutcome::RestoreConflict {
            head_sha,
            conflicted_paths,
            ..
        } => HeadMoveSummary::create_conflict_from_paths(&head_sha, conflicted_paths),
        FastForwardOutcome::AheadOfTarget {
            head_sha,
            target_sha,
        } => HeadMoveSummary::create_with_message(
            HeadMoveOutcome::AheadOfTarget,
            format!(
                "local HEAD {} has unpushed commits ahead of remote {}",
                build_short_sha_from_sha(&head_sha),
                build_short_sha_from_sha(&target_sha),
            ),
        ),
        FastForwardOutcome::Diverged {
            head_sha,
            target_sha,
        } => HeadMoveSummary::create_with_message(
            HeadMoveOutcome::Diverged,
            format!(
                "local HEAD {} and remote {} have diverged; left worktree untouched",
                build_short_sha_from_sha(&head_sha),
                build_short_sha_from_sha(&target_sha),
            ),
        ),
    }
}

impl ReviewSession {
    /// Sends the queued viewed marks first, then pulls the pull request from
    /// the forge, saves it, and announces it. A failed pull keeps the
    /// previous view and announces the failure; it saves only the queue,
    /// and only when marks were sent before it failed.
    pub fn sync(&mut self) -> Result<SessionView> {
        let now = self.ports.clock.now();
        // GitHub may lag behind a mark that lands now, so the pull that
        // follows can briefly undo it until a later pull.
        let has_landed = self.send_queued();
        match self.pull() {
            Ok((pr, snapshot)) => self.apply_pull(pr, snapshot, now),
            Err(error) => {
                self.fail_sync(&error, now, has_landed);
                Err(error)
            }
        }
    }

    /// Records and announces a failed pull. Marks that landed before it are
    /// saved and announced first, so the queue count shown is not stale.
    fn fail_sync(&mut self, error: &anyhow::Error, now: u64, has_landed: bool) {
        let message = format!("{error:#}");
        self.sync = SyncState::Failed {
            at: now,
            message: message.clone(),
        };
        if has_landed {
            // The pull's error is the one to report. Should this save fail,
            // the shrunken queue is saved by the next save that succeeds.
            let _ = self.save_and_announce_viewed();
        }
        self.publish(&Event::SyncFailed { message });
    }

    fn pull(&self) -> Result<(PullRequest, ForgeSnapshot)> {
        let pr = self.ports.forge.pull_request(self.number)?;
        let snapshot = self.ports.forge.fetch(&pr)?;
        Ok((pr, snapshot))
    }

    /// Keeps what a successful pull reported, reconciles queued comment ops,
    /// fast-forwards when remote `head_sha` moved, saves, and announces it.
    fn apply_pull(
        &mut self,
        pr: PullRequest,
        snapshot: ForgeSnapshot,
        now: u64,
    ) -> Result<SessionView> {
        let previous_head_sha = self
            .saved
            .session
            .pr
            .as_ref()
            .map(|existing| existing.head_sha.clone());
        let pr_head_sha = pr.head_sha.clone();
        self.reconcile_pulled_state(pr, snapshot, now)?;
        let view = if let Some(previous_sha) =
            previous_head_sha.filter(|previous| previous != &pr_head_sha)
        {
            self.handle_head_moved(&previous_sha, &pr_head_sha)?
        } else {
            let view = self.view();
            self.last_worktree_status = Some(view.worktree_status.clone());
            view
        };
        self.publish(&Event::Synced {
            view: Box::new(view.clone()),
        });
        Ok(view)
    }

    fn reconcile_pulled_state(
        &mut self,
        pr: PullRequest,
        mut snapshot: ForgeSnapshot,
        now: u64,
    ) -> Result<()> {
        self.saved.session.pr = Some(pr);
        self.saved.session.last_synced_at = Some(now);
        reconcile_concurrent_edits(
            &mut snapshot.threads,
            &mut self.saved.registry.agreed_bodies,
            &mut self.saved.registry.queued_ops,
        );
        self.saved.registry.pending_review_id = snapshot.pending_review_id;
        self.saved.registry.viewer_login = snapshot.viewer_login;
        self.saved.registry.mention_candidates = snapshot.mention_candidates;
        self.clear_reconciled_queued_markers();
        let (github_threads, local_threads): (Vec<Thread>, Vec<Thread>) = self
            .threads
            .drain(..)
            .partition(|thread| thread.origin == Origin::Github);
        merge_unflushed_threads(&mut snapshot.threads, &github_threads);
        self.threads = snapshot.threads;
        self.threads.extend(local_threads);
        let _ = self.send_queued_comments();
        self.apply_pending_thread_ops();
        record_agreed_bodies(&self.threads, &mut self.saved.registry.agreed_bodies);
        let queue = &mut self.saved.registry.queued_viewed;
        drop_stale_marks(queue, &snapshot.files);
        apply_queued(&mut snapshot.files, queue);
        self.saved.files = snapshot.files;
        self.sync = SyncState::Synced { at: now };
        self.split_and_save_threads()
    }

    fn handle_head_moved(&mut self, previous_sha: &str, pr_head_sha: &str) -> Result<SessionView> {
        let summary =
            fast_forward_result_to_head_move(self.ports.workspace.fast_forward_to(pr_head_sha));
        if matches!(
            summary.outcome,
            HeadMoveOutcome::FastForwarded | HeadMoveOutcome::RestoreConflict
        ) {
            self.reanchor_after_head_move()?;
        }
        let view = self.view();
        self.last_worktree_status = Some(view.worktree_status.clone());
        self.publish(&Event::HeadMoved {
            previous_sha: previous_sha.to_owned(),
            head_sha: pr_head_sha.to_owned(),
            outcome: summary.outcome,
            conflicted_paths: summary.conflicted_paths,
            message: summary.message,
            view: Box::new(view.clone()),
        });
        Ok(view)
    }

    fn reanchor_after_head_move(&mut self) -> Result<()> {
        let current_digests = self.collect_worktree_digests();
        let candidate_paths = self.disk_digests.as_ref().map_or_else(
            || self.collect_local_thread_paths(),
            |previous_digests| collect_changed_digest_paths(previous_digests, &current_digests),
        );
        if !candidate_paths.is_empty() && self.reanchor_changed_local_threads(&candidate_paths) {
            self.split_and_save_threads()?;
        }
        self.disk_digests = Some(current_digests);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use review_model::{Event, SyncState, ViewedState};

    use super::super::test_support::{Fakes, create_snapshot};

    #[test]
    fn sync_pulls_saves_and_announces() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open();
        let events = session.subscribe();
        let view = session.sync().expect("the sync succeeds");
        assert_eq!(view.files.len(), 2);
        assert_eq!(view.thread_count, 1);
        assert_eq!(view.viewed_count, 1);
        assert_eq!(view.sync, SyncState::Synced { at: 100 });
        let saved = fakes.store.saved();
        assert_eq!(saved.session.pr.map(|pr| pr.number), Some(7));
        assert_eq!(saved.session.last_synced_at, Some(100));
        assert_eq!(saved.files.len(), 2);
        assert_eq!(
            events.try_recv().expect("an event was sent"),
            Event::Synced {
                view: Box::new(view)
            }
        );
    }

    #[test]
    fn a_reopened_session_shows_the_saved_files_before_syncing() {
        let fakes = Fakes::new(100);
        fakes.open_synced();
        let view = fakes.open().view();
        assert_eq!(view.files.len(), 2);
        assert_eq!(
            view.pr.map(|pr| pr.title),
            Some("Fix the widget".to_owned())
        );
        assert_eq!(view.sync, SyncState::Synced { at: 100 });
    }

    #[test]
    fn a_failed_sync_keeps_the_last_view_and_announces_the_failure() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let events = session.subscribe();
        fakes.forge.fail_with(Some("gh timed out after 30s"));
        fakes.clock.set(160);
        let error = session.sync().expect_err("the forge fails");
        assert!(error.to_string().contains("timed out"));
        let view = session.view();
        assert_eq!(view.files.len(), 2, "the last synced files are kept");
        assert_eq!(
            view.sync,
            SyncState::Failed {
                at: 160,
                message: "gh timed out after 30s".into()
            }
        );
        assert_eq!(
            events.try_recv().expect("an event was sent"),
            Event::SyncFailed {
                message: "gh timed out after 30s".into()
            }
        );
        assert_eq!(
            fakes.store.saved().session.last_synced_at,
            Some(100),
            "a failure saves nothing"
        );
    }

    #[test]
    fn a_failed_pull_still_saves_and_announces_the_marks_it_sent() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        fakes.forge.fail_writes_with(Some("offline"));
        session.set_viewed("src/a.rs", false).unwrap();
        fakes.forge.fail_writes_with(None);
        fakes.forge.fail_reads_with(Some("gh timed out after 30s"));
        let events = session.subscribe();
        let error = session.sync().expect_err("the pull fails");
        assert!(error.to_string().contains("timed out"));
        assert_eq!(fakes.forge.viewed_calls(), [("src/a.rs".to_owned(), false)]);
        assert!(fakes.store.saved().registry.queued_viewed.is_empty());
        match events.try_recv().expect("a viewedChanged event") {
            Event::ViewedChanged { view } => assert_eq!(view.queued_count, 0),
            other => panic!("expected viewedChanged, got {other:?}"),
        }
        assert!(matches!(
            events.try_recv().expect("a syncFailed event"),
            Event::SyncFailed { .. }
        ));
    }

    #[test]
    fn github_resetting_a_viewed_file_reaches_the_view() {
        let fakes = Fakes::new(1);
        let mut session = fakes.open_synced();
        let mut changed = create_snapshot();
        changed.files[0].viewed = ViewedState::Dismissed;
        fakes.forge.set_snapshot(changed);
        let view = session.sync().expect("the second sync succeeds");
        assert_eq!(view.files[0].viewed, ViewedState::Dismissed);
        assert_eq!(view.viewed_count, 0);
    }

    fn advance_remote_head(fakes: &Fakes, head_sha: &str) {
        let mut updated_pr = crate::fakes::sample_pr();
        updated_pr.head_sha = head_sha.to_owned();
        fakes.forge.set_pr(updated_pr);
        let mut updated_snapshot = create_snapshot();
        updated_snapshot.head_sha = head_sha.to_owned();
        fakes.forge.set_snapshot(updated_snapshot);
    }

    fn take_head_moved_and_synced(
        events: &std::sync::mpsc::Receiver<Event>,
    ) -> (
        String,
        String,
        review_model::HeadMoveOutcome,
        Vec<String>,
        Option<String>,
        review_model::SessionView,
    ) {
        let head_moved = match events.try_recv().expect("expected HeadMoved event") {
            Event::HeadMoved {
                previous_sha,
                head_sha,
                outcome,
                conflicted_paths,
                message,
                view,
            } => (
                previous_sha,
                head_sha,
                outcome,
                conflicted_paths,
                message,
                *view,
            ),
            other => panic!("expected HeadMoved, got {other:?}"),
        };
        match events.try_recv().expect("expected Synced event") {
            Event::Synced { view } => assert_eq!(*view, head_moved.5),
            other => panic!("expected Synced, got {other:?}"),
        }
        head_moved
    }

    #[test]
    fn sync_fast_forwards_when_remote_head_moves_reanchors_local_threads_and_emits_head_moved() {
        let fakes = Fakes::new(100);
        fakes
            .workspace
            .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
        let mut session = fakes.open_synced();
        session
            .comment_with_origin(
                review_model::Anchor::line("src/a.rs", 2),
                "Why 1?",
                review_model::Origin::Local,
            )
            .unwrap();
        let events = session.subscribe();
        advance_remote_head(&fakes, "def456");
        fakes
            .workspace
            .put_disk("src/a.rs", "// upstream header\nfn f() {}\nlet x = 1;\n");

        let synced_view = session.sync().unwrap();
        let (previous_sha, head_sha, outcome, conflicted_paths, message, moved_view) =
            take_head_moved_and_synced(&events);
        assert_eq!(previous_sha, "abc123");
        assert_eq!(head_sha, "def456");
        assert_eq!(outcome, review_model::HeadMoveOutcome::FastForwarded);
        assert!(conflicted_paths.is_empty());
        assert!(message.is_none());
        assert_eq!(moved_view, synced_view);
        assert_eq!(session.threads().last().unwrap().anchor.start, Some(3));
        assert_eq!(fakes.store.saved().local.threads[0].anchor.start, Some(3));
    }

    #[test]
    fn sync_emits_restore_conflict_and_diverged_outcomes_without_failing_the_pull() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let events = session.subscribe();

        advance_remote_head(&fakes, "def456");
        fakes.workspace.set_fast_forward_outcome(Some(Ok(
            crate::ports::FastForwardOutcome::RestoreConflict {
                previous_sha: "abc123".into(),
                head_sha: "def456".into(),
                conflicted_paths: vec!["src/a.rs".into()],
            },
        )));
        session.sync().unwrap();
        let (_, _, outcome, conflicted_paths, message, _) = take_head_moved_and_synced(&events);
        assert_eq!(outcome, review_model::HeadMoveOutcome::RestoreConflict);
        assert_eq!(conflicted_paths, vec!["src/a.rs"]);
        assert!(message.is_some());

        advance_remote_head(&fakes, "999999");
        fakes.workspace.set_fast_forward_outcome(Some(Ok(
            crate::ports::FastForwardOutcome::Diverged {
                head_sha: "def456".into(),
                target_sha: "999999".into(),
            },
        )));
        session.sync().unwrap();
        let (_, _, outcome, _, message, _) = take_head_moved_and_synced(&events);
        assert_eq!(outcome, review_model::HeadMoveOutcome::Diverged);
        assert!(message.unwrap().contains("diverged"));
    }

    #[test]
    fn sync_emits_ahead_and_failed_outcomes_without_failing_the_pull() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let events = session.subscribe();

        advance_remote_head(&fakes, "def456");
        fakes.workspace.set_fast_forward_outcome(Some(Ok(
            crate::ports::FastForwardOutcome::AheadOfTarget {
                head_sha: "local99".into(),
                target_sha: "def456".into(),
            },
        )));
        session.sync().unwrap();
        let (_, _, outcome, _, message, _) = take_head_moved_and_synced(&events);
        assert_eq!(outcome, review_model::HeadMoveOutcome::AheadOfTarget);
        assert!(message.unwrap().contains("ahead"));

        advance_remote_head(&fakes, "fedcba");
        fakes
            .workspace
            .set_fast_forward_outcome(Some(Err("fetch timed out".into())));
        let view = session.sync().unwrap();
        assert_eq!(view.pr.unwrap().head_sha, "fedcba");
        let (_, _, outcome, _, message, _) = take_head_moved_and_synced(&events);
        assert_eq!(outcome, review_model::HeadMoveOutcome::Failed);
        assert!(message.unwrap().contains("fetch timed out"));
    }
}
