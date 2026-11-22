//! Pushing local commits on `HEAD` to the pull request's remote branch.

use anyhow::{Result, bail};
use review_model::PushResult;

use super::ReviewSession;

impl ReviewSession {
    /// Pushes `HEAD` to the synced pull request's `head_ref`, then runs a
    /// forge sync. When `git push` succeeds and the follow-up sync fails,
    /// returns `Ok` with `is_pushed: true` and `sync_error: Some(..)`.
    pub fn push(&mut self) -> Result<PushResult> {
        let (head_ref, remote_head_sha) = {
            let pr = self.synced_pr()?;
            (pr.head_ref.clone(), pr.head_sha.clone())
        };
        let status = self
            .ports
            .workspace
            .worktree_status(Some(&remote_head_sha))?;
        if status.ahead == 0 && status.is_dirty {
            bail!("nothing committed to push: commit your changes before running :Jpr push");
        }
        let head_sha = self.ports.workspace.push_head(&head_ref)?;
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
        assert!(fakes.workspace.pushed_refs().is_empty());

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
        assert!(fakes.workspace.pushed_refs().is_empty());
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

        fakes.workspace.fail_push_with(Some("remote rejected"));
        let push_error = session.push().unwrap_err();
        assert!(
            push_error.to_string().contains("remote rejected"),
            "{push_error}"
        );
    }
}
