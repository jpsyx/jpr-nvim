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

/// Everything a frontend needs to draw the session's status. The session
/// returns it for a snapshot or a sync and sends it with every `Synced` event,
/// so a frontend redraws from it alone.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionView {
    /// The pull request, or `None` until a sync has ever succeeded for it.
    pub pr: Option<PullRequest>,
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
    /// Viewed marks waiting to reach the forge.
    pub queued_count: usize,
    /// When the session last talked to the forge, and how it went.
    pub sync: SyncState,
}

/// A change the session announces to its subscribers. The RPC server forwards
/// each one to its client as an `event` notification, so a frontend redraws
/// without asking.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
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

    #[test]
    fn events_are_tagged_by_type_and_views_use_camel_case() {
        let view = SessionView {
            pr: None,
            files: vec![FileRow {
                path: "a.rs".into(),
                additions: 1,
                deletions: 2,
                viewed: ViewedState::Viewed,
                threads: 3,
            }],
            tree: Vec::new(),
            viewed_count: 1,
            thread_count: 3,
            draft_count: 1,
            conversation_count: 2,
            queued_count: 2,
            sync: SyncState::Never,
        };
        let json = serde_json::to_value(Event::Synced {
            view: Box::new(view.clone()),
        })
        .unwrap();
        assert_eq!(json["type"], "synced");
        assert_eq!(json["view"]["viewedCount"], 1);
        assert_eq!(json["view"]["threadCount"], 3);
        assert_eq!(json["view"]["draftCount"], 1);
        assert_eq!(json["view"]["conversationCount"], 2);
        assert_eq!(json["view"]["queuedCount"], 2);
        assert_eq!(json["view"]["files"][0]["viewed"], "VIEWED");
        let threads_changed = serde_json::to_value(Event::ThreadsChanged {
            view: Box::new(view),
        })
        .unwrap();
        assert_eq!(threads_changed["type"], "threadsChanged");
        let failed = serde_json::to_value(Event::SyncFailed {
            message: "offline".into(),
        })
        .unwrap();
        assert_eq!(
            failed,
            serde_json::json!({ "type": "syncFailed", "message": "offline" })
        );
    }
}
