//! Pushing local commits on `HEAD` to the pull request's remote branch.

use anyhow::{Result, bail};
use review_model::{PushResult, WorktreeStatus};

use super::{PushedHead, ReviewSession};

impl ReviewSession {
    /// Pushes `HEAD` to the synced pull request's `head_ref`, then runs a
    /// forge sync. When `git push` succeeds and the follow-up sync fails,
    /// returns `Ok` with `is_pushed: true` and `sync_error: Some(..)`.
    pub fn push(&mut self) -> Result<PushResult> {
        let pr = self.synced_pr()?.clone();
        let effective_remote_sha = self
            .effective_remote_head_sha()
            .unwrap_or(&pr.head_sha)
            .to_owned();
        let local_head_sha = self.ports.workspace.head_commit()?;
        let status = self
            .ports
            .workspace
            .worktree_status(Some(&effective_remote_sha))?;
        validate_push_status(&status, &local_head_sha, &effective_remote_sha)?;
        let head_sha = self.ports.workspace.push_head(&pr)?;
        self.pushed_head = Some(PushedHead {
            base_pr_head_sha: pr.head_sha,
            pushed_sha: head_sha.clone(),
        });
        match self.sync() {
            Ok(view) => Ok(PushResult {
                is_pushed: true,
                head_sha,
                sync_error: None,
                view,
            }),
            Err(error) => {
                let view = self.view();
                self.last_worktree_status = Some(view.worktree_status.clone());
                Ok(PushResult {
                    is_pushed: true,
                    head_sha,
                    sync_error: Some(format!("{error:#}")),
                    view,
                })
            }
        }
    }
}

fn validate_push_status(
    status: &WorktreeStatus,
    local_head_sha: &str,
    effective_remote_sha: &str,
) -> Result<()> {
    if status.ahead == 0 && status.behind > 0 {
        bail!("local HEAD is behind the pull request head: run :Jpr sync before pushing");
    }
    if status.ahead == 0 && local_head_sha == effective_remote_sha {
        if status.is_dirty {
            bail!("nothing committed to push: commit your changes before running :Jpr push");
        }
        bail!("nothing to push: HEAD is already up to date with the pull request");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use review_model::{Event, HeadMoveOutcome, WorktreeStatus};

    use super::super::test_support::{Fakes, create_snapshot};
    use crate::fakes::sample_pr;

    #[test]
    fn push_refuses_dirty_worktree_with_zero_commits_ahead() {
        let fakes = Fakes::new(100);
        let unsynced_error = fakes.open().push().unwrap_err();
        assert!(
            unsynced_error.to_string().contains("not synced"),
            "{unsynced_error}"
        );
        assert_eq!(fakes.workspace.pushed_refs(), Vec::new());

        let mut session = fakes.open_synced();
        fakes.workspace.set_worktree_status(Some(WorktreeStatus {
            is_dirty: true,
            ahead: 0,
            behind: 0,
            modified_paths: vec!["src/a.rs".into()],
        }));
        let error = session.push().unwrap_err();
        assert!(
            error
                .to_string()
                .contains("commit your changes before running :Jpr push"),
            "{error}"
        );
        assert_eq!(fakes.workspace.pushed_refs(), Vec::new());
    }

    #[test]
    fn push_pushes_pr_head_ref_syncs_and_returns_push_result() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        fakes.workspace.set_head_commit("newhead1");
        fakes.workspace.set_worktree_status(Some(WorktreeStatus {
            is_dirty: false,
            ahead: 1,
            behind: 0,
            modified_paths: Vec::new(),
        }));
        let mut updated_pr = sample_pr();
        updated_pr.head_sha = "newhead1".into();
        fakes.forge.set_pr(updated_pr);
        let mut updated_snapshot = create_snapshot();
        updated_snapshot.head_sha = "newhead1".into();
        fakes.forge.set_snapshot(updated_snapshot);
        let events = session.subscribe();

        let push_result = session.push().unwrap();
        assert!(push_result.is_pushed);
        assert_eq!(push_result.head_sha, "newhead1");
        assert!(push_result.sync_error.is_none());
        assert_eq!(push_result.view.worktree_status.ahead, 0);
        assert_eq!(
            fakes.workspace.pushed_refs(),
            vec![("fix/widget".to_owned(), "newhead1".to_owned())]
        );
        assert!(matches!(
            events.try_recv().unwrap(),
            Event::HeadMoved {
                outcome: HeadMoveOutcome::AlreadyAtTarget,
                ..
            }
        ));
        assert!(matches!(events.try_recv().unwrap(), Event::Synced { .. }));
    }

    #[test]
    fn push_refuses_clean_up_to_date_and_behind_remote_worktrees() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();

        let up_to_date_error = session.push().unwrap_err();
        assert!(
            up_to_date_error.to_string().contains("already up to date"),
            "{up_to_date_error}"
        );
        assert_eq!(fakes.workspace.pushed_refs(), Vec::new());

        fakes.workspace.set_worktree_status(Some(WorktreeStatus {
            is_dirty: false,
            ahead: 0,
            behind: 2,
            modified_paths: Vec::new(),
        }));
        let behind_error = session.push().unwrap_err();
        assert!(
            behind_error
                .to_string()
                .contains("behind the pull request head: run :Jpr sync"),
            "{behind_error}"
        );
        assert_eq!(fakes.workspace.pushed_refs(), Vec::new());
    }

    #[test]
    fn push_keeps_pushed_result_with_sync_error_when_post_push_sync_fails() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        fakes.workspace.set_head_commit("newhead1");
        fakes.workspace.set_worktree_status(Some(WorktreeStatus {
            is_dirty: false,
            ahead: 1,
            behind: 0,
            modified_paths: Vec::new(),
        }));
        fakes.forge.fail_reads_with(Some("gh offline"));

        let push_result = session.push().unwrap();
        assert!(push_result.is_pushed);
        assert_eq!(push_result.head_sha, "newhead1");
        let sync_error = push_result.sync_error.expect("sync error is recorded");
        assert!(sync_error.contains("gh offline"), "{sync_error}");
        assert_eq!(push_result.view.worktree_status.ahead, 0);
        assert_eq!(
            fakes.workspace.status_remote_shas().last(),
            Some(&Some("newhead1".to_owned()))
        );

        let retry_error = session.push().unwrap_err();
        assert!(
            retry_error.to_string().contains("already up to date"),
            "{retry_error}"
        );
        assert_eq!(fakes.workspace.pushed_refs().len(), 1);
    }

    #[test]
    fn push_surfaces_remote_rejection_and_recovers_pushed_head_on_later_sync() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        fakes.workspace.set_head_commit("newhead1");
        fakes.workspace.set_worktree_status(Some(WorktreeStatus {
            is_dirty: false,
            ahead: 1,
            behind: 0,
            modified_paths: Vec::new(),
        }));
        fakes.forge.fail_reads_with(Some("gh offline"));
        session.push().unwrap();

        fakes.forge.fail_reads_with(None);
        let mut updated_pr = sample_pr();
        updated_pr.head_sha = "newhead1".into();
        fakes.forge.set_pr(updated_pr);
        let mut updated_snapshot = create_snapshot();
        updated_snapshot.head_sha = "newhead1".into();
        fakes.forge.set_snapshot(updated_snapshot);
        let events = session.subscribe();
        session.sync().unwrap();
        assert!(matches!(
            events.try_recv().unwrap(),
            Event::HeadMoved {
                outcome: HeadMoveOutcome::AlreadyAtTarget,
                ..
            }
        ));

        fakes.workspace.set_head_commit("newhead2");
        fakes.workspace.set_worktree_status(Some(WorktreeStatus {
            is_dirty: false,
            ahead: 1,
            behind: 0,
            modified_paths: Vec::new(),
        }));
        fakes.workspace.fail_push_with(Some("remote rejected"));
        let push_error = session.push().unwrap_err();
        assert!(push_error.to_string().contains("remote rejected"));
    }

    #[test]
    fn push_retains_pushed_head_across_lagging_sync_until_forge_head_advances() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        fakes.workspace.set_head_commit("newhead1");
        fakes.workspace.set_worktree_status(Some(WorktreeStatus {
            is_dirty: false,
            ahead: 1,
            behind: 0,
            modified_paths: Vec::new(),
        }));

        let push_result = session.push().unwrap();
        assert!(push_result.sync_error.is_none());
        assert_eq!(
            fakes.workspace.status_remote_shas().last(),
            Some(&Some("newhead1".to_owned()))
        );
        let retry_error = session.push().unwrap_err();
        assert!(retry_error.to_string().contains("already up to date"));

        let mut updated_pr = sample_pr();
        updated_pr.head_sha = "newhead1".into();
        fakes.forge.set_pr(updated_pr);
        let mut updated_snapshot = create_snapshot();
        updated_snapshot.head_sha = "newhead1".into();
        fakes.forge.set_snapshot(updated_snapshot);
        let events = session.subscribe();
        session.sync().unwrap();
        assert!(matches!(
            events.try_recv().unwrap(),
            Event::HeadMoved {
                outcome: HeadMoveOutcome::AlreadyAtTarget,
                ..
            }
        ));
    }

    #[test]
    fn push_forwards_cross_repository_pr_context_and_surfaces_refusal() {
        let fakes = Fakes::new(100);
        let mut fork_pr = sample_pr();
        fork_pr.head_ref = "main".into();
        fork_pr.is_cross_repository = true;
        fakes.forge.set_pr(fork_pr.clone());
        let mut session = fakes.open_synced();
        fakes.workspace.set_head_commit("forkhead1");
        fakes.workspace.set_worktree_status(Some(WorktreeStatus {
            is_dirty: false,
            ahead: 1,
            behind: 0,
            modified_paths: Vec::new(),
        }));
        fakes.workspace.fail_push_with(Some(
            "refusing to push cross-repository (fork) pull request",
        ));

        let refusal = session.push().unwrap_err();
        assert!(
            refusal.to_string().contains("cross-repository"),
            "{refusal}"
        );
        assert_eq!(fakes.workspace.pushed_prs(), Vec::new());

        fakes.workspace.fail_push_with(None);
        let mut advanced_pr = fork_pr.clone();
        advanced_pr.head_sha = "forkhead1".into();
        fakes.forge.set_pr(advanced_pr);
        let mut updated_snapshot = create_snapshot();
        updated_snapshot.head_sha = "forkhead1".into();
        fakes.forge.set_snapshot(updated_snapshot);

        let result = session.push().unwrap();
        assert!(result.is_pushed);
        assert_eq!(fakes.workspace.pushed_prs(), vec![fork_pr]);
    }
}
