//! The read models a frontend draws, and the events that announce changes.
//! Their JSON shape is the wire format in docs/protocol.md.

use serde::{Deserialize, Serialize};

use crate::{PullRequest, ViewedState};

/// When the session last talked to the forge, and how it went.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum SyncState {
    /// Never synced.
    Never,
    /// The last sync succeeded at `at` (Unix seconds).
    Synced { at: u64 },
    /// The last sync failed at `at` with `message`.
    Failed { at: u64, message: String },
}

/// One changed file as the file list shows it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileRow {
    pub path: String,
    pub additions: u64,
    pub deletions: u64,
    pub viewed: ViewedState,
    /// Threads anchored to this file, open or resolved.
    pub threads: usize,
}

/// Everything a frontend needs to draw the session's status.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionView {
    pub pr: Option<PullRequest>,
    pub files: Vec<FileRow>,
    pub viewed_count: usize,
    pub thread_count: usize,
    pub sync: SyncState,
}

/// A change the session announces to its subscribers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Event {
    /// A sync finished; `view` is the new state.
    // Boxed: the view dwarfs the other variants (clippy::large_enum_variant).
    Synced { view: Box<SessionView> },
    /// A sync failed; the previous view still stands.
    SyncFailed { message: String },
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
            viewed_count: 1,
            thread_count: 3,
            sync: SyncState::Never,
        };
        let json = serde_json::to_value(Event::Synced {
            view: Box::new(view),
        })
        .unwrap();
        assert_eq!(json["type"], "synced");
        assert_eq!(json["view"]["viewedCount"], 1);
        assert_eq!(json["view"]["threadCount"], 3);
        assert_eq!(json["view"]["files"][0]["viewed"], "VIEWED");
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
