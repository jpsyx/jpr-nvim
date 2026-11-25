//! Pulling the pull request from the forge.

use anyhow::Result;
use review_model::{
    ChangedFile, Event, HeadMoveOutcome, Origin, PullRequest, SessionView, SyncState, Thread,
};

use super::ReviewSession;
use crate::comments::{merge_unflushed_threads, reconcile_concurrent_edits, record_agreed_bodies};
use crate::ports::{FastForwardOutcome, ForgeSnapshot};
use crate::reanchor::{collect_changed_digest_paths, hash_bounded_file_bytes};
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
        if !self.is_linked() {
            return self.sync_or_link_local(now);
        }
        // GitHub may lag behind a mark that lands now, so the pull that
        // follows can briefly undo it until a later pull.
        let has_landed = self.send_queued();
        let result = self
            .pull()
            .and_then(|(pr, snapshot)| self.apply_pull(pr, snapshot, now));
        if let Err(error) = &result {
            self.fail_sync(error, now, has_landed);
        }
        result
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
        let super::SessionTarget::Pr { number } = self.target else {
            anyhow::bail!("cannot pull pull request while unlinked");
        };
        let pr = self.ports.forge.pull_request(number)?;
        let snapshot = self.ports.forge.fetch(&pr)?;
        Ok((pr, snapshot))
    }

    /// Applies a fetched pull request and forge snapshot to session state,
    /// announces the update, and returns the refreshed view.
    pub(super) fn apply_pull(
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
            .map(|existing_pr| existing_pr.head_sha.clone());
        let prior_head_sha = self.pending_head_move_from.clone().or(previous_head_sha);
        let pr_head_sha = pr.head_sha.clone();
        if let Some(prior_sha) = prior_head_sha
            .as_ref()
            .filter(|prior_sha| *prior_sha != &pr_head_sha)
        {
            self.pending_head_move_from = Some(prior_sha.clone());
        } else {
            self.pending_head_move_from = None;
        }
        self.reconcile_pulled_state(pr, snapshot, now)?;
        let view =
            if let Some(prior_sha) = prior_head_sha.filter(|prior_sha| prior_sha != &pr_head_sha) {
                self.handle_head_moved(&prior_sha, &pr_head_sha)?
            } else {
                self.seed_pulled_file_digests();
                self.view()
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
        let pulled_head_sha = pr.head_sha.clone();
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
        self.reconcile_viewed_and_local_files(&mut snapshot.files);
        self.sync = SyncState::Synced { at: now };
        self.split_and_save_threads()?;
        if self
            .pushed_head
            .as_ref()
            .is_some_and(|pushed| pushed.base_pr_head_sha != pulled_head_sha)
        {
            self.pushed_head = None;
        }
        Ok(())
    }

    fn reconcile_viewed_and_local_files(&mut self, incoming_files: &mut Vec<ChangedFile>) {
        let did_promote = self.promote_adopted_local_viewed(incoming_files);
        let queue = &mut self.saved.registry.queued_viewed;
        drop_stale_marks(queue, incoming_files);
        apply_queued(incoming_files, queue);
        self.saved.files = std::mem::take(incoming_files);
        if did_promote {
            let _ = self.send_queued();
        }
        if self.base_cache.merge_base.is_empty() {
            self.local_files
                .retain(|local| !self.saved.files.iter().any(|pr| pr.path == local.path));
        } else {
            self.refresh_local_files();
            self.prune_stale_local_viewed();
        }
    }

    fn handle_head_moved(&mut self, previous_sha: &str, pr_head_sha: &str) -> Result<SessionView> {
        let summary =
            fast_forward_result_to_head_move(self.ports.workspace.fast_forward_to(pr_head_sha));
        if matches!(
            summary.outcome,
            HeadMoveOutcome::AlreadyAtTarget
                | HeadMoveOutcome::FastForwarded
                | HeadMoveOutcome::RestoreConflict
        ) {
            self.reanchor_after_head_move(&summary.conflicted_paths)?;
        }
        if summary.outcome != HeadMoveOutcome::Failed {
            self.pending_head_move_from = None;
        }
        let view = self.view();
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

    fn reanchor_after_head_move(&mut self, excluded_paths: &[String]) -> Result<()> {
        let current_digests = self.collect_worktree_digests();
        let mut candidate_paths = self.disk_digests.as_ref().map_or_else(
            || self.collect_local_thread_paths(),
            |previous_digests| collect_changed_digest_paths(previous_digests, &current_digests),
        );
        if !excluded_paths.is_empty() {
            candidate_paths.retain(|candidate_path| !excluded_paths.contains(candidate_path));
        }
        if !candidate_paths.is_empty() {
            self.reanchor_and_save_local_threads(&candidate_paths)?;
        }
        self.disk_digests = Some(current_digests);
        Ok(())
    }

    fn seed_pulled_file_digests(&mut self) {
        let Some(digests) = self.disk_digests.as_mut() else {
            return;
        };
        for file in &self.saved.files {
            if !digests.contains_key(&file.path)
                && let Ok(Some(bytes)) = self.ports.workspace.file_on_disk(&file.path)
            {
                digests.insert(
                    file.path.clone(),
                    hash_bounded_file_bytes(&bytes, super::diffs::MAX_DIFF_BYTES),
                );
            }
        }
    }
}

#[cfg(test)]
mod head_move_tests;
#[cfg(test)]
mod tests;
