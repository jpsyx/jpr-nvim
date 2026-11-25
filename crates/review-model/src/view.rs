//! The read models a frontend draws, and the events that announce changes.
//! Their JSON shape is the wire format in docs/protocol.md.

use serde::{Deserialize, Serialize};

use crate::{PullRequest, ViewedState};

/// When the session last talked to the forge, and how it went, so a frontend
/// can show how fresh its view is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum SyncState {
    /// Never synced.
    Never,
    /// The last sync succeeded.
    Synced {
        /// When it finished, in Unix seconds.
        at: u64,
    },
    /// The last sync failed.
    Failed {
        /// When it failed, in Unix seconds.
        at: u64,
        /// What went wrong, for a person to read.
        message: String,
    },
}

/// Working-tree dirty and commit-divergence summary relative to the PR head.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WorktreeStatus {
    /// Whether any tracked or untracked file is modified in the worktree.
    pub is_dirty: bool,
    /// Commits on `HEAD` not reachable from the pull request's remote head commit.
    pub ahead: usize,
    /// Commits on the pull request's remote head commit not reachable from `HEAD`.
    pub behind: usize,
    /// Sorted repository-relative paths currently modified or untracked.
    pub modified_paths: Vec<String>,
}

/// How the local checkout reacted when the forge's `headSha` moved on sync.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HeadMoveOutcome {
    /// Local `HEAD` was already at the new `headSha` (for example right after `:Jpr push`).
    AlreadyAtTarget,
    /// Local `HEAD` fast-forwarded cleanly (auto-stashing and restoring dirty changes when needed).
    FastForwarded,
    /// Fast-forward succeeded, but popping the auto-stash hit conflicts; conflict markers and the stash entry remain.
    RestoreConflict,
    /// Local `HEAD` has unpushed commits ahead of the remote `headSha`; left untouched.
    AheadOfTarget,
    /// Local `HEAD` and remote `headSha` diverged; left untouched.
    Diverged,
    /// Fetching or fast-forwarding failed before changing `HEAD`.
    Failed,
}

/// One changed file as the file list shows it: a frontend draws one row per
/// file from it, in the order the session gives.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileRow {
    /// The file's path from the repository root.
    pub path: String,
    /// Lines the pull request adds to the file.
    pub additions: u64,
    /// Lines the pull request removes from the file.
    pub deletions: u64,
    /// Whether the reviewer has viewed the file.
    pub viewed: ViewedState,
    /// Threads anchored to this file, open or resolved.
    pub threads: usize,
    /// Whether this file currently has uncommitted local changes in the worktree.
    #[serde(default)]
    pub is_modified: bool,
    /// Local threads anchored to this file, open or resolved.
    #[serde(default)]
    pub local_threads: usize,
    /// Whether this file exists only in the local worktree and has not been pushed to the pull request yet.
    #[serde(default)]
    pub is_local_only: bool,
}

/// One row of the changed files drawn as a tree: a directory, or a file of
/// [`SessionView::files`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TreeRow {
    /// How deep the row is nested; top-level rows are 0.
    pub depth: usize,
    /// A directory's path below its parent row (a directory holding only
    /// one directory is joined to it, as in `src/core`), or a file's name.
    pub name: String,
    /// A file's index in `SessionView::files`; `None` for a directory.
    pub file: Option<usize>,
}

/// Context for an unlinked local worktree review session (`SessionView::pr == None`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalReviewContext {
    /// Checked-out branch name, or `detached-<short-sha>` when HEAD is detached.
    pub branch: String,
    /// Base branch or git ref being diffed against (for example `develop` or `main`).
    pub base_ref: String,
    /// Resolved full commit SHA of `base_ref`.
    pub base_sha: String,
    /// Inferred `owner/name` repository from `origin` remote, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
}

/// Everything a frontend needs to draw the session's status. The session
/// returns it for a snapshot or a sync and sends it with every `Synced` event,
/// so a frontend redraws from it alone.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionView {
    /// The pull request, or `None` until a sync has ever succeeded for it.
    pub pr: Option<PullRequest>,
    /// Local worktree review context when unlinked (`pr == None`); omitted once
    /// linked to a pull request (`pr == Some(..)`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub local_context: Option<LocalReviewContext>,
    /// The changed files, in the forge's order.
    pub files: Vec<FileRow>,
    /// The changed files as a tree, for a file panel.
    pub tree: Vec<TreeRow>,
    /// How many files are viewed; a dismissed file does not count.
    pub viewed_count: usize,
    /// How many threads the pull request has, across every file.
    pub thread_count: usize,
    /// How many pending draft messages the reviewer has on this pull request.
    #[serde(default)]
    pub draft_count: usize,
    /// How many pull-request conversation messages exist.
    #[serde(default)]
    pub conversation_count: usize,
    /// Open unsent local threads queued for `:Jpr send`.
    #[serde(default)]
    pub local_unsent_count: usize,
    /// Viewed marks waiting to reach the forge.
    pub queued_count: usize,
    /// When the session last talked to the forge, and how it went.
    pub sync: SyncState,
    /// Dirty and ahead/behind state of the local checkout relative to the PR head.
    #[serde(default)]
    pub worktree_status: WorktreeStatus,
}

/// Outcome returned by `:Jpr push` after pushing `HEAD` to the pull request head branch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PushResult {
    /// Always `true` when `git push` succeeded.
    pub is_pushed: bool,
    /// Commit SHA pushed from `HEAD`.
    pub head_sha: String,
    /// Non-fatal error if the post-push GitHub sync failed after `git push` succeeded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sync_error: Option<String>,
    /// Current session view after pushing (and syncing when sync succeeded).
    pub view: SessionView,
}

/// A change the session announces to its subscribers. The RPC server forwards
/// each one to its client as an `event` notification, so a frontend redraws
/// without asking.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Event {
    /// A sync finished.
    Synced {
        /// The new state.
        // Boxed: it dwarfs the other variants (clippy::large_enum_variant).
        view: Box<SessionView>,
    },
    /// A sync failed; the previous view still stands.
    SyncFailed {
        /// What went wrong, for a person to read.
        message: String,
    },
    /// A file was marked viewed or unviewed, or a queued mark reached the
    /// forge.
    ViewedChanged {
        /// The new state.
        view: Box<SessionView>,
    },
    /// Threads changed (comment added, edited, deleted, resolved, or reacted).
    ThreadsChanged {
        /// The updated view with refreshed counts.
        view: Box<SessionView>,
    },
    /// Working-tree files under the PR diff changed on disk.
    FilesChanged {
        /// Repository-relative paths reported as changed.
        paths: Vec<String>,
        /// The updated view with refreshed file metrics.
        view: Box<SessionView>,
    },
    /// An agent dispatch or pre-pass round was confirmed and recorded.
    AgentRound {
        /// The recorded round details.
        round: crate::AgentRound,
        /// The updated view with refreshed counts.
        view: Box<SessionView>,
    },
    /// Local worktree dirty or ahead/behind status changed.
    WorktreeStatusChanged {
        /// The updated view with refreshed worktree status.
        view: Box<SessionView>,
    },
    /// The pull request's remote `headSha` changed during sync.
    HeadMoved {
        /// Previous `headSha` before the sync.
        previous_sha: String,
        /// New `headSha` observed on the forge.
        head_sha: String,
        /// How the local worktree reacted to the new `headSha`.
        outcome: HeadMoveOutcome,
        /// Repository-relative paths with restore conflicts, when any.
        #[serde(default)]
        conflicted_paths: Vec<String>,
        /// Human-readable detail when fast-forward or stash pop hit a snag.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        /// The updated view after reconciling `headSha`.
        view: Box<SessionView>,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sync_states_are_tagged_by_state() {
        assert_eq!(
            serde_json::to_value(SyncState::Never).unwrap(),
            serde_json::json!({ "state": "never" })
        );
        assert_eq!(
            serde_json::to_value(SyncState::Synced { at: 5 }).unwrap(),
            serde_json::json!({ "state": "synced", "at": 5 })
        );
        assert_eq!(
            serde_json::to_value(SyncState::Failed {
                at: 6,
                message: "offline".into()
            })
            .unwrap(),
            serde_json::json!({ "state": "failed", "at": 6, "message": "offline" })
        );
    }

    fn create_sample_view() -> SessionView {
        SessionView {
            pr: None,
            local_context: None,
            files: vec![FileRow {
                path: "a.rs".into(),
                additions: 1,
                deletions: 2,
                viewed: ViewedState::Viewed,
                threads: 3,
                is_modified: false,
                local_threads: 0,
                is_local_only: false,
            }],
            tree: Vec::new(),
            viewed_count: 1,
            thread_count: 3,
            draft_count: 1,
            conversation_count: 2,
            local_unsent_count: 4,
            queued_count: 2,
            sync: SyncState::Never,
            worktree_status: WorktreeStatus::default(),
        }
    }

    #[test]
    fn synced_event_uses_camel_case_view_fields() {
        let view = create_sample_view();
        let json = serde_json::to_value(Event::Synced {
            view: Box::new(view),
        })
        .unwrap();
        assert_eq!(json["type"], "synced");
        assert_eq!(json["view"]["viewedCount"], 1);
        assert_eq!(json["view"]["threadCount"], 3);
        assert_eq!(json["view"]["draftCount"], 1);
        assert_eq!(json["view"]["conversationCount"], 2);
        assert_eq!(json["view"]["localUnsentCount"], 4);
        assert_eq!(json["view"]["queuedCount"], 2);
        assert_eq!(json["view"]["files"][0]["viewed"], "VIEWED");
    }

    #[test]
    fn delta_and_failure_events_are_tagged_by_type() {
        let view = create_sample_view();
        let threads_changed = serde_json::to_value(Event::ThreadsChanged {
            view: Box::new(view.clone()),
        })
        .unwrap();
        assert_eq!(threads_changed["type"], "threadsChanged");
        let files_changed = serde_json::to_value(Event::FilesChanged {
            paths: vec!["src/lib.rs".into()],
            view: Box::new(view.clone()),
        })
        .unwrap();
        assert_eq!(files_changed["type"], "filesChanged");
        assert_eq!(files_changed["paths"], serde_json::json!(["src/lib.rs"]));
        let agent_round = serde_json::to_value(Event::AgentRound {
            round: crate::AgentRound {
                round: 1,
                kind: crate::AgentRoundKind::Send,
                thread_ids: vec!["loc-1".into()],
                prompt: "prompt".into(),
                sent_at: 99,
            },
            view: Box::new(view),
        })
        .unwrap();
        assert_eq!(agent_round["type"], "agentRound");
        assert_eq!(agent_round["round"]["round"], 1);
        let failed = serde_json::to_value(Event::SyncFailed {
            message: "offline".into(),
        })
        .unwrap();
        assert_eq!(
            failed,
            serde_json::json!({ "type": "syncFailed", "message": "offline" })
        );
    }

    #[test]
    fn worktree_status_push_result_and_head_moved_use_camel_case() {
        let mut view = create_sample_view();
        view.files[0].is_modified = true;
        view.files[0].local_threads = 1;
        view.worktree_status = WorktreeStatus {
            is_dirty: true,
            ahead: 2,
            behind: 1,
            modified_paths: vec!["a.rs".into()],
        };
        let push = serde_json::to_value(PushResult {
            is_pushed: true,
            head_sha: "abc1234".into(),
            sync_error: None,
            view: view.clone(),
        })
        .unwrap();
        assert_eq!(push["isPushed"], true);
        assert_eq!(push["headSha"], "abc1234");
        assert!(push.get("syncError").is_none());
        assert_eq!(push["view"]["worktreeStatus"]["isDirty"], true);
        assert_eq!(push["view"]["worktreeStatus"]["ahead"], 2);
        assert_eq!(push["view"]["worktreeStatus"]["behind"], 1);
        assert_eq!(push["view"]["files"][0]["isModified"], true);
        assert_eq!(push["view"]["files"][0]["localThreads"], 1);
        let status_event = serde_json::to_value(Event::WorktreeStatusChanged {
            view: Box::new(view.clone()),
        })
        .unwrap();
        assert_eq!(status_event["type"], "worktreeStatusChanged");
        let moved_event = serde_json::to_value(Event::HeadMoved {
            previous_sha: "old111".into(),
            head_sha: "new222".into(),
            outcome: HeadMoveOutcome::RestoreConflict,
            conflicted_paths: vec!["a.rs".into()],
            message: Some("stash pop conflict".into()),
            view: Box::new(view),
        })
        .unwrap();
        assert_eq!(moved_event["type"], "headMoved");
        assert_eq!(moved_event["previousSha"], "old111");
        assert_eq!(moved_event["headSha"], "new222");
        assert_eq!(moved_event["outcome"], "restoreConflict");
        assert_eq!(moved_event["conflictedPaths"], serde_json::json!(["a.rs"]));
    }

    #[test]
    fn legacy_view_json_without_polish_fields_deserializes_with_defaults() {
        let mut encoded = serde_json::to_value(create_sample_view()).unwrap();
        encoded
            .as_object_mut()
            .unwrap()
            .remove("worktreeStatus")
            .unwrap();
        let row = encoded["files"][0].as_object_mut().unwrap();
        row.remove("isModified").unwrap();
        row.remove("localThreads").unwrap();
        row.remove("isLocalOnly").unwrap();

        let decoded: SessionView = serde_json::from_value(encoded).unwrap();
        assert!(!decoded.files[0].is_modified);
        assert_eq!(decoded.files[0].local_threads, 0);
        assert!(!decoded.files[0].is_local_only);
        assert_eq!(decoded.worktree_status, WorktreeStatus::default());
        assert_eq!(decoded.local_context, None);
    }

    #[test]
    fn local_context_serializes_camel_case_and_is_omitted_when_none() {
        let mut view = create_sample_view();
        let encoded_none = serde_json::to_value(&view).unwrap();
        assert!(encoded_none.get("localContext").is_none());

        view.local_context = Some(LocalReviewContext {
            branch: "feat/local".into(),
            base_ref: "develop".into(),
            base_sha: "abc1234".into(),
            repo: Some("octo/widgets".into()),
        });
        let encoded_some = serde_json::to_value(&view).unwrap();
        assert_eq!(
            encoded_some["localContext"],
            serde_json::json!({
                "branch": "feat/local",
                "baseRef": "develop",
                "baseSha": "abc1234",
                "repo": "octo/widgets",
            })
        );

        view.local_context.as_mut().unwrap().repo = None;
        let encoded_no_repo = serde_json::to_value(&view).unwrap();
        assert!(encoded_no_repo["localContext"].get("repo").is_none());
    }
}
