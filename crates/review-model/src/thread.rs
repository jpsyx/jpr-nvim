//! Review threads. GitHub's and local ones share one shape.

use serde::{Deserialize, Serialize};

/// Where a thread lives.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    /// On the forge (GitHub).
    Github,
    /// Only on this machine, for the agent.
    Local,
}

/// Which side of the diff a thread is anchored to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum Side {
    /// The old file.
    Left,
    /// The new file.
    Right,
}

/// What a thread is attached to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AnchorKind {
    Line,
    Range,
    File,
    Pr,
}

/// Where a thread is attached.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Anchor {
    /// The file, for every kind but `pr`.
    pub file: Option<String>,
    pub kind: AnchorKind,
    pub side: Side,
    /// The first line, for `line` and `range`.
    pub start: Option<u64>,
    /// The last line, for `line` and `range`.
    pub end: Option<u64>,
    /// The commit the line numbers refer to, when known.
    pub commit: Option<String>,
    /// The anchored code, used to re-anchor a thread whose lines moved.
    pub snapshot: Option<String>,
}

impl Anchor {
    /// A single line on the new side of `file`.
    #[must_use]
    pub fn line(file: &str, line: u64) -> Self {
        Self {
            file: Some(file.to_owned()),
            kind: AnchorKind::Line,
            side: Side::Right,
            start: Some(line),
            end: Some(line),
            commit: None,
            snapshot: None,
        }
    }
}

/// Whether a thread still needs attention.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThreadState {
    Open,
    Resolved,
}

/// Where a forge message stands. Local messages have none.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageSync {
    /// In the reviewer's pending review, visible only to them.
    Draft,
    /// Being written to the forge.
    Pending,
    Published,
    Failed,
    /// Waiting for the network.
    Queued,
}

/// One message in a thread.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub id: String,
    pub author: String,
    pub body: String,
    pub created: String,
    pub updated: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sync: Option<MessageSync>,
}

/// A conversation attached to an anchor.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Thread {
    pub id: String,
    pub origin: Origin,
    pub anchor: Anchor,
    pub state: ThreadState,
    /// The forge says the anchored code changed since the thread was opened.
    #[serde(default)]
    pub outdated: bool,
    pub messages: Vec<Message>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_thread_round_trips_through_json_with_its_wire_spellings() {
        let thread = Thread {
            id: "T1".into(),
            origin: Origin::Github,
            anchor: Anchor::line("src/a.rs", 12),
            state: ThreadState::Open,
            outdated: false,
            messages: vec![Message {
                id: "C1".into(),
                author: "bob".into(),
                body: "why?".into(),
                created: "2026-11-19T00:00:00Z".into(),
                updated: "2026-11-19T00:00:00Z".into(),
                sync: Some(MessageSync::Draft),
            }],
        };
        let json = serde_json::to_value(&thread).unwrap();
        assert_eq!(json["origin"], "github");
        assert_eq!(json["anchor"]["kind"], "line");
        assert_eq!(json["anchor"]["side"], "RIGHT");
        assert_eq!(json["state"], "open");
        assert_eq!(json["messages"][0]["sync"], "draft");
        let back: Thread = serde_json::from_value(json).unwrap();
        assert_eq!(back, thread);
    }

    #[test]
    fn a_local_message_omits_sync_and_outdated_defaults_to_false() {
        let json = serde_json::json!({
            "id": "L1", "origin": "local",
            "anchor": { "file": null, "kind": "pr", "side": "RIGHT", "start": null, "end": null, "commit": null, "snapshot": null },
            "state": "resolved",
            "messages": [{ "id": "m", "author": "me", "body": "b", "created": "c", "updated": "u" }]
        });
        let thread: Thread = serde_json::from_value(json).unwrap();
        assert!(!thread.outdated);
        assert_eq!(thread.anchor.kind, AnchorKind::Pr);
        assert_eq!(thread.messages[0].sync, None);
        let out = serde_json::to_value(&thread).unwrap();
        assert!(out["messages"][0].get("sync").is_none());
    }
}
