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
        /// Whether the failure was caused by missing or invalid `gh` authentication.
        #[serde(default)]
        auth_required: bool,
        /// Whether this failure came from the background poller rather than an
        /// explicit user-initiated request (`sync`, `setViewed`, `push`).
        #[serde(default)]
        is_background: bool,
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
mod tests;
