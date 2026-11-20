use serde::{Deserialize, Serialize};

/// Where a thread lives, so a frontend can tell a forge thread from one kept
/// only on this machine.
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

/// What a thread is attached to. It decides which of an [`Anchor`]'s fields
/// are set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AnchorKind {
    /// One line of a file.
    Line,
    /// A run of lines of a file, from `start` to `end`.
    Range,
    /// A whole file, with no line.
    File,
    /// The pull request as a whole, with no file.
    Pr,
}

/// Where a thread is attached. A frontend uses it to place the thread in the
/// diff, and the snapshot lets a thread whose lines moved find them again.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Anchor {
    /// The file, for every kind but `pr`.
    pub file: Option<String>,
    /// What the thread is attached to.
    pub kind: AnchorKind,
    /// Which side of the diff the lines are on.
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
    /// A single line on the new side of `file`, with no commit or snapshot.
    /// Use it to anchor a thread to one line, for example in a test fixture.
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

/// Whether a thread still needs attention, so a frontend can fold settled
/// threads away.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThreadState {
    /// Still needs an answer or a fix.
    Open,
    /// Settled.
    Resolved,
}

/// Where a forge message stands, so a frontend can show which messages others
/// can see. Local messages have none.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageSync {
    /// In the reviewer's pending review, visible only to them.
    Draft,
    /// Being written to the forge.
    Pending,
    /// On the forge, visible to everyone who can see the pull request.
    Published,
    /// Writing it to the forge failed.
    Failed,
    /// Waiting for the network.
    Queued,
}

/// One message in a thread, as a frontend draws it in the conversation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    /// Identifies the message on the forge, or on this machine for a local one.
    pub id: String,
    /// The author's login; a bot's ends in `[bot]`.
    pub author: String,
    /// The message text, as the author wrote it.
    pub body: String,
    /// When the message was written, as the forge's timestamp.
    pub created: String,
    /// When the message was last edited, in the same format as `created`.
    pub updated: String,
    /// Where a forge message stands; `None`, and left out of the JSON, for a
    /// local message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sync: Option<MessageSync>,
}

/// A review conversation attached to an [`Anchor`].
///
/// GitHub's threads and the ones kept only on this machine share this one
/// shape, so the session counts them per file and a frontend draws both the
/// same way.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Thread {
    /// Identifies the thread on the forge, or on this machine for a local one.
    pub id: String,
    /// Whether the thread lives on the forge or only on this machine.
    pub origin: Origin,
    /// Where the thread is attached.
    pub anchor: Anchor,
    /// Whether the thread still needs attention.
    pub state: ThreadState,
    /// The forge says the anchored code changed since the thread was opened.
    #[serde(default)]
    pub outdated: bool,
    /// The messages, in the order the forge reports them.
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
        let serialized = serde_json::to_value(&thread).unwrap();
        assert!(serialized["messages"][0].get("sync").is_none());
    }
}
