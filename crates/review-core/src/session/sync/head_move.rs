//! Head-move tracking, fast-forward summary formatting, and post-move reanchoring.

use anyhow::Result;
use review_model::{Event, HeadMoveOutcome, SessionView};

use super::super::ReviewSession;
use crate::ports::FastForwardOutcome;
use crate::reanchor::collect_changed_digest_paths;

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
    pub(super) fn track_head_move_for_sync(&mut self, pr_head_sha: &str) -> Option<String> {
        let previous_head_sha = self
            .saved
            .session
            .pr
            .as_ref()
            .map(|existing_pr| existing_pr.head_sha.clone());
        let prior_head_sha = self.get_prior_head_sha_for_sync(previous_head_sha, pr_head_sha);
        self.has_checked_reopen_head = true;
        let moved_from = prior_head_sha.filter(|prior_sha| prior_sha != pr_head_sha);
        self.pending_head_move_from.clone_from(&moved_from);
        moved_from
    }

    pub(super) fn handle_head_moved(
        &mut self,
        previous_sha: &str,
        pr_head_sha: &str,
    ) -> Result<SessionView> {
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
}
