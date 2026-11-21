mod anchor;

use serde::{Deserialize, Serialize};

use crate::Reaction;
pub use anchor::{Anchor, AnchorKind, Side};

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
    /// Whether the current reviewer authored this message.
    #[serde(default)]
    pub viewer_did_author: bool,
    /// Numeric GitHub comment id as a decimal string, for the REST replies API.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub database_id: Option<String>,
    /// Reactions with at least one reactor.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reactions: Vec<Reaction>,
    /// Forge error message when `sync` is `Failed`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sync_error: Option<String>,
    /// Local edit text preserved when a concurrent forge edit won.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recoverable_body: Option<String>,
}

impl Message {
    /// Creates a message with `sync` and default metadata, for tests and local
    /// optimistic placeholders.
    #[must_use]
    pub fn create_with_sync(
        id: &str,
        author: &str,
        body: &str,
        timestamp: &str,
        sync: Option<MessageSync>,
    ) -> Self {
        Self {
            id: id.to_owned(),
            author: author.to_owned(),
            body: body.to_owned(),
            created: timestamp.to_owned(),
            updated: timestamp.to_owned(),
            sync,
            viewer_did_author: false,
            database_id: None,
            reactions: Vec::new(),
            sync_error: None,
            recoverable_body: None,
        }
    }
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

/// How a frontend colors a thread's sign and preview badge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MarkerKind {
    /// Published on the forge.
    Published,
    /// Draft in the pending review, or queued/pending delivery.
    Draft,
    /// Refused by the forge and waiting for retry or edit.
    Failed,
    /// Local thread for the agent.
    Local,
}

/// Compact read model for a thread marker, preview, and inline block.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadPreview {
    /// Identifies the thread.
    pub thread_id: String,
    /// Where the thread is attached.
    pub anchor: Anchor,
    /// 1-based line in the current file where a unified overlay places the
    /// marker, or `0` for a file-level thread.
    pub display_line: u64,
    /// Visual badge category.
    pub kind: MarkerKind,
    /// Open or resolved.
    pub state: ThreadState,
    /// Marked outdated by the forge.
    pub outdated: bool,
    /// Total messages in the thread.
    pub message_count: usize,
    /// First message's author login.
    pub first_author: String,
    /// Trimmed first non-empty line of the first message.
    pub snippet: String,
    /// Full messages for inline expansion and the popup.
    pub messages: Vec<Message>,
}

/// Summarizes `thread` into a [`ThreadPreview`] at 1-based `display_line`
/// (`0` for file-level threads), deriving its badge [`MarkerKind`] and
/// first-line snippet.
///
/// Use it when attaching compact thread markers to diff views, for example
/// single-file overlays or unified and split diff stream rows.
#[must_use]
pub fn create_thread_preview_from_thread(thread: &Thread, display_line: u64) -> ThreadPreview {
    let kind = thread_to_marker_kind(thread);
    let first_author = thread
        .messages
        .first()
        .map_or_else(String::new, |message| message.author.clone());
    let snippet = thread.messages.first().map_or_else(String::new, |message| {
        build_snippet_from_body(&message.body)
    });
    ThreadPreview {
        thread_id: thread.id.clone(),
        anchor: thread.anchor.clone(),
        display_line,
        kind,
        state: thread.state,
        outdated: thread.outdated,
        message_count: thread.messages.len(),
        first_author,
        snippet,
        messages: thread.messages.clone(),
    }
}

fn thread_to_marker_kind(thread: &Thread) -> MarkerKind {
    if thread.origin == Origin::Local {
        return MarkerKind::Local;
    }
    if thread
        .messages
        .iter()
        .any(|message| message.sync == Some(MessageSync::Failed))
    {
        return MarkerKind::Failed;
    }
    if thread.messages.iter().any(|message| {
        matches!(
            message.sync,
            Some(MessageSync::Draft | MessageSync::Pending | MessageSync::Queued)
        )
    }) {
        return MarkerKind::Draft;
    }
    MarkerKind::Published
}

/// Extracts up to 80 characters of the trimmed first non-empty line of `body`
/// (or an empty string when `body` is blank).
///
/// Use it for compact one-line comment summaries, for example in diff thread
/// previews or pending-review draft lists.
#[must_use]
pub fn build_snippet_from_body(body: &str) -> String {
    body.lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default()
        .chars()
        .take(80)
        .collect()
}

#[cfg(test)]
mod tests;
