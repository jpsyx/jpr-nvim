//! Pulling the pull request from the forge.

mod head_move;

use anyhow::Result;
use review_model::{ChangedFile, Event, Origin, PullRequest, SessionView, SyncState, Thread};

use super::ReviewSession;
use crate::collapsed::viewed_states_from_files;
use crate::comments::{merge_unflushed_threads, reconcile_concurrent_edits, record_agreed_bodies};
use crate::ports::ForgeSnapshot;
use crate::reanchor::hash_bounded_file_bytes;
use crate::sync_delta::{SyncComparisonSnapshot, compute_sync_delta};
use crate::viewed::{apply_queued, drop_stale_marks};

impl ReviewSession {
    /// Sends the queued viewed marks first, then pulls the pull request from
    /// the forge, saves it, and announces it. A failed pull keeps the
    /// previous view and announces the failure; it saves only the queue,
    /// and only when marks were sent before it failed.
    pub fn sync(&mut self) -> Result<SessionView> {
        self.sync_with_background(false)
    }

    /// Background poller variant of [`Self::sync`], marking any resulting
    /// [`Event::SyncFailed`] with `is_background = true`.
    pub fn sync_background(&mut self) -> Result<SessionView> {
        self.sync_with_background(true)
    }

    fn sync_with_background(&mut self, is_background: bool) -> Result<SessionView> {
        let now = self.ports.clock.now();
        if !self.is_linked() {
            return self.sync_or_link_local(now);
        }
        // GitHub may lag behind a mark that lands now, so the pull that
        // follows can briefly undo it until a later pull.
        let (has_landed, _) = self.send_queued();
        let result = self
            .pull()
            .and_then(|(pr, snapshot)| self.apply_pull(pr, snapshot, now, is_background));
        if let Err(error) = &result {
            self.fail_sync(error, now, has_landed, is_background);
        }
        result
    }

    /// Records and announces a failed pull. Marks that landed before it are
    /// saved and announced first, so the queue count shown is not stale.
    fn fail_sync(
        &mut self,
        error: &anyhow::Error,
        now: u64,
        has_landed: bool,
        is_background: bool,
    ) {
        let message = format!("{error:#}");
        let auth_required = crate::is_auth_error(error);
        self.sync = SyncState::Failed {
            at: now,
            message: message.clone(),
        };
        if has_landed {
            // The pull's error is the one to report. Should this save fail,
            // the shrunken queue is saved by the next save that succeeds.
            let _ = self.save_and_announce_viewed();
        }
        self.publish(&Event::SyncFailed {
            message,
            auth_required,
            is_background,
        });
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
        is_background: bool,
    ) -> Result<SessionView> {
        let before_snapshot = self.create_sync_comparison_snapshot();
        let pr_head_sha = pr.head_sha.clone();
        let was_own_push = self
            .pushed_head
            .as_ref()
            .is_some_and(|pushed| pushed.pushed_sha == pr_head_sha);
        let moved_from_sha = self.track_head_move_for_sync(&pr_head_sha);
        self.reconcile_pulled_state(pr, snapshot, now)?;
        let after_snapshot = self.create_sync_comparison_snapshot();
        let delta = compute_sync_delta(
            &before_snapshot,
            &after_snapshot,
            &self.saved.registry.id_map,
            was_own_push,
        );
        let view = if let Some(prior_sha) = moved_from_sha {
            self.handle_head_moved(&prior_sha, &pr_head_sha)?
        } else {
            self.seed_pulled_file_digests();
            self.view()
        };
        self.publish(&Event::Synced {
            view: Box::new(view.clone()),
            is_background,
            delta,
        });
        Ok(view)
    }

    fn create_sync_comparison_snapshot(&self) -> SyncComparisonSnapshot {
        SyncComparisonSnapshot {
            had_pr: self.saved.session.pr.is_some(),
            head_sha: self
                .saved
                .session
                .pr
                .as_ref()
                .map(|existing_pr| existing_pr.head_sha.clone()),
            files: self.saved.files.clone(),
            threads: self.threads.clone(),
        }
    }

    fn get_prior_head_sha_for_sync(
        &self,
        previous_head_sha: Option<String>,
        pr_head_sha: &str,
    ) -> Option<String> {
        let tracked = self.pending_head_move_from.clone().or(previous_head_sha);
        if tracked.as_deref().is_some_and(|sha| sha != pr_head_sha) || self.has_checked_reopen_head
        {
            return tracked;
        }
        let Ok(local_head) = self.ports.workspace.head_commit() else {
            return tracked;
        };
        if local_head != pr_head_sha
            && self
                .pushed_head
                .as_ref()
                .is_none_or(|pushed| pushed.pushed_sha != local_head)
        {
            Some(local_head)
        } else {
            tracked
        }
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
        let previous = viewed_states_from_files(&self.saved.files);
        let forge = viewed_states_from_files(incoming_files);
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
        self.apply_collapsed_dirs_after_pull(&previous, &forge);
    }

    fn apply_collapsed_dirs_after_pull(
        &mut self,
        previous: &std::collections::BTreeMap<String, review_model::ViewedState>,
        forge: &std::collections::BTreeMap<String, review_model::ViewedState>,
    ) {
        let local_only_paths: Vec<String> = self
            .local_files
            .iter()
            .map(|file| file.path.clone())
            .collect();
        let should_prune_empty = !self.base_cache.merge_base.is_empty();
        self.saved.local.collapsed_dirs = crate::collapsed::create_collapsed_dirs_after_pull(
            &self.saved.local.collapsed_dirs,
            previous,
            forge,
            &self.saved.files,
            &local_only_paths,
            should_prune_empty,
        );
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
