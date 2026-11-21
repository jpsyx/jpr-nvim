//! Pulling the pull request from the forge.

use anyhow::Result;
use review_model::{Event, PullRequest, SessionView, SyncState};

use super::ReviewSession;
use crate::comments::{merge_unflushed_threads, reconcile_concurrent_edits, record_agreed_bodies};
use crate::ports::ForgeSnapshot;
use crate::viewed::{apply_queued, drop_stale_marks};

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
    /// saves, and announces it.
    fn apply_pull(
        &mut self,
        pr: PullRequest,
        mut snapshot: ForgeSnapshot,
        now: u64,
    ) -> Result<SessionView> {
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
        merge_unflushed_threads(&mut snapshot.threads, &self.threads);
        self.threads = snapshot.threads;
        let _ = self.send_queued_comments();
        self.apply_pending_thread_ops();
        record_agreed_bodies(&self.threads, &mut self.saved.registry.agreed_bodies);
        self.saved.registry.threads.clone_from(&self.threads);
        let queue = &mut self.saved.registry.queued_viewed;
        drop_stale_marks(queue, &snapshot.files);
        apply_queued(&mut snapshot.files, queue);
        self.saved.files = snapshot.files;
        self.sync = SyncState::Synced { at: now };
        self.ports.store.save(&self.saved)?;
        let view = self.view();
        self.publish(&Event::Synced {
            view: Box::new(view.clone()),
        });
        Ok(view)
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
}
