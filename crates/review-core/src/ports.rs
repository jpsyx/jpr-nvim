//! The ports: everything the engine needs from the outside world. Adapters
//! (GitHub, the file store, the system clock) implement them, and tests use
//! the in-memory fakes.

use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use review_model::{
    AgentKind, AgentRound, Anchor, AnchorKind, ChangedFile, MentionCandidate, Message, PullRequest,
    Reaction, ReactionContent, ReviewEvent, Thread,
};
use serde::{Deserialize, Serialize};

/// How a forge write failed: transient errors can be queued and retried,
/// while rejected requests need the reviewer to edit, retry, or delete.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ForgeWriteError {
    /// Network timeout, offline `gh`, HTTP 5xx, or rate limit.
    Transient(String),
    /// Validation error (HTTP 4xx / GraphQL refusal) that retrying unchanged
    /// will not fix.
    Rejected(String),
}

impl std::fmt::Display for ForgeWriteError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Transient(message) | Self::Rejected(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for ForgeWriteError {}

/// Result of creating a new draft review thread on the forge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreatedReviewThread {
    /// Node id of the pending review that owns the draft thread.
    pub pending_review_id: String,
    /// Created review thread with its single draft message.
    pub thread: Thread,
}

/// Parameters for replying to an existing code review thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplyRequest<'a> {
    /// Target review thread node id (`PRRT_...`).
    pub thread_id: &'a str,
    /// Decimal `fullDatabaseId` of the thread's first comment, for REST replies.
    pub root_database_id: Option<&'a str>,
    /// Existing pending review node id (`PRR_...`), when one is active.
    pub pending_review_id: Option<&'a str>,
    /// Markdown reply body.
    pub body: &'a str,
}

/// An offline or transiently failed comment write persisted in
/// [`SyncRegistry::queued_ops`] via [`ReviewStore`] until the forge accepts it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum QueuedCommentOp {
    /// Draft review thread anchored to a file, line, or range.
    CreateReviewThread {
        /// Temporary optimistic thread id assigned locally (`tmp-...`).
        temp_thread_id: String,
        /// Temporary optimistic message id assigned locally (`tmp-...`).
        temp_message_id: String,
        /// Where the draft thread is attached.
        anchor: Anchor,
        /// Markdown comment body.
        body: String,
    },
    /// Top-level pull-request conversation comment.
    CreateConversationComment {
        /// Temporary optimistic thread id assigned locally (`tmp-...`).
        temp_thread_id: String,
        /// Temporary optimistic message id assigned locally (`tmp-...`).
        temp_message_id: String,
        /// Markdown comment body.
        body: String,
    },
    /// Reply to a code review thread.
    ReplyToThread {
        /// Target thread id (real `PRRT_...` or temporary id mapped via `id_map`).
        thread_id: String,
        /// Decimal `fullDatabaseId` of the thread's first comment, when known.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        root_database_id: Option<String>,
        /// Temporary optimistic reply message id assigned locally (`tmp-...`).
        temp_message_id: String,
        /// Markdown reply body.
        body: String,
    },
    /// Edit a review comment or issue comment.
    EditMessage {
        /// Owning thread id.
        thread_id: String,
        /// Whether the thread is a PR conversation comment or code review comment.
        anchor_kind: AnchorKind,
        /// Target message id (real node id or temporary id mapped via `id_map`).
        message_id: String,
        /// Updated markdown body.
        body: String,
    },
    /// Delete a review comment or issue comment.
    DeleteMessage {
        /// Owning thread id.
        thread_id: String,
        /// Whether the thread is a PR conversation comment or code review comment.
        anchor_kind: AnchorKind,
        /// Target message id (real node id or temporary id mapped via `id_map`).
        message_id: String,
    },
    /// Resolve or unresolve a code review thread.
    SetResolved {
        /// Target thread id (real `PRRT_...` or temporary id mapped via `id_map`).
        thread_id: String,
        /// Whether the thread should become resolved (`true`) or open (`false`).
        resolved: bool,
    },
    /// Add or remove a reaction on a comment node.
    SetReaction {
        /// Target comment node id (or temporary id mapped via `id_map`).
        subject_id: String,
        /// Reaction kind to toggle.
        content: ReactionContent,
        /// Whether to add (`true`) or remove (`false`) the reaction.
        added: bool,
    },
    /// Submit the pending review (or a zero-draft review).
    SubmitReview {
        /// Verdict (`COMMENT`, `APPROVE`, or `REQUEST_CHANGES`).
        event: ReviewEvent,
        /// Summary review body.
        body: String,
    },
}

/// What the forge reports about a pull request in one pull.
/// [`Forge::fetch`] returns it and the session applies it on every sync.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ForgeSnapshot {
    /// The pull request's head commit at the time of the pull.
    pub head_sha: String,
    /// Whether the reviewer has a pending (unsubmitted) review.
    pub has_pending_review: bool,
    /// Node id of the reviewer's pending review, when `has_pending_review` holds.
    pub pending_review_id: Option<String>,
    /// Login of the authenticated `gh` viewer, when reported.
    pub viewer_login: Option<String>,
    /// Every review thread and conversation comment thread on the pull request.
    pub threads: Vec<Thread>,
    /// The changed files, with the reviewer's viewed state.
    pub files: Vec<ChangedFile>,
    /// `@mention` completion candidates, PR participants first.
    pub mention_candidates: Vec<MentionCandidate>,
}

/// The code forge that hosts the pull request, such as GitHub. The session
/// reaches the forge only through this trait, so each forge is one adapter and
/// tests use an in-memory fake.
pub trait Forge: Send {
    /// The open pull request numbered `number`. The session asks for it at the
    /// start of every sync.
    fn pull_request(&self, number: u64) -> Result<PullRequest>;
    /// The pull request's threads, changed files and viewed state, in one
    /// snapshot.
    fn fetch(&self, pr: &PullRequest) -> Result<ForgeSnapshot>;
    /// Marks `path` viewed (`true`) or unviewed (`false`) for the reviewer on
    /// the forge, at once.
    fn set_viewed(&self, pr: &PullRequest, path: &str, viewed: bool) -> Result<()>;

    /// Creates a draft review thread in `pending_review_id` (creating a pending
    /// review on `pr.head_sha` first when `None`).
    fn create_review_thread(
        &self,
        pr: &PullRequest,
        pending_review_id: Option<&str>,
        anchor: &Anchor,
        body: &str,
    ) -> std::result::Result<CreatedReviewThread, ForgeWriteError>;

    /// Publishes a top-level pull-request conversation comment (`AnchorKind::Pr`).
    fn create_conversation_comment(
        &self,
        pr: &PullRequest,
        body: &str,
    ) -> std::result::Result<Thread, ForgeWriteError>;

    /// Replies to an existing code review thread and returns the created
    /// [`Message`], publishing immediately when no pending review blocks it or
    /// attaching a draft reply to the active pending review.
    fn reply_to_thread(
        &self,
        pr: &PullRequest,
        request: &ReplyRequest<'_>,
    ) -> std::result::Result<Message, ForgeWriteError>;

    /// Updates the body of a review comment or issue comment.
    fn edit_message(
        &self,
        anchor_kind: AnchorKind,
        message_id: &str,
        body: &str,
    ) -> std::result::Result<Message, ForgeWriteError>;

    /// Deletes a review comment or issue comment.
    fn delete_message(
        &self,
        anchor_kind: AnchorKind,
        message_id: &str,
    ) -> std::result::Result<(), ForgeWriteError>;

    /// Resolves or unresolves a code review thread.
    fn set_resolved(
        &self,
        thread_id: &str,
        resolved: bool,
    ) -> std::result::Result<(), ForgeWriteError>;

    /// Adds (`added == true`) or removes (`added == false`) a reaction on
    /// `subject_id`, returning the updated non-empty reactions.
    fn set_reaction(
        &self,
        subject_id: &str,
        content: ReactionContent,
        added: bool,
    ) -> std::result::Result<Vec<Reaction>, ForgeWriteError>;

    /// Submits `pending_review_id` (or creates and submits a new review on
    /// `pr.head_sha` when `pending_review_id` is `None`).
    fn submit_review(
        &self,
        pr: &PullRequest,
        pending_review_id: Option<&str>,
        event: ReviewEvent,
        body: &str,
    ) -> std::result::Result<(), ForgeWriteError>;
}

/// The reviewer's checkout of the pull request.
///
/// It holds the checkout's git history and the files on disk. The session
/// reads the two sides of every diff through it, so a test can use an
/// in-memory fake instead of a repository.
pub trait Workspace: Send {
    /// The commit the pull request's changes are measured from: where the
    /// checked-out head and `base_sha` diverge.
    fn merge_base(&self, base_sha: &str) -> Result<String>;
    /// `path` as it is in `commit`, or `None` when it does not exist there.
    fn file_at(&self, commit: &str, path: &str) -> Result<Option<Vec<u8>>>;
    /// `path` as it is on disk in the checkout, or `None` when it is not there.
    fn file_on_disk(&self, path: &str) -> Result<Option<Vec<u8>>>;
    /// The files renamed between `commit` and the checkout, as `(old, new)` paths.
    fn renames(&self, commit: &str) -> Result<Vec<(String, String)>>;
    /// Sorted repo-relative paths whose worktree content differs from `commit`
    /// or are untracked.
    fn list_changed_files_since(&self, commit: &str) -> Result<Vec<String>>;
}

/// The running daemon and what it last saw, persisted between runs.
///
/// A later run uses it to find the serving process and show the last synced
/// pull request before it syncs again.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SessionRecord {
    /// The process serving the session, once one has recorded itself.
    pub pid: Option<u32>,
    /// The worktree the serving process runs in.
    pub worktree: Option<String>,
    /// The pull request as last synced.
    pub pr: Option<PullRequest>,
    /// Unix seconds of the last successful sync.
    pub last_synced_at: Option<u64>,
    /// Unix domain socket path where the running daemon accepts CLI requests.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub socket: Option<String>,
    /// Stable session identifier for resuming Claude Code or Codex on this PR.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_session_id: Option<String>,
    /// Agent kind (`claude` or `codex`) associated with `agent_session_id`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_kind: Option<AgentKind>,
}

/// Local-only threads and counters persisted in `local.json`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LocalStoreState {
    /// Next numeric suffix for `loc-<id>` threads and `loc-m-<id>` messages.
    pub next_local_id: u64,
    /// Next 1-based dispatch round counter.
    pub next_round: u64,
    /// Every `Origin::Local` thread on this pull request.
    pub threads: Vec<Thread>,
}

/// What the engine still owes the forge: changes made while the forge could
/// not be reached, sent again on the next try. Saved with everything else,
/// so a restarted engine still delivers them.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SyncRegistry {
    /// Viewed marks the forge has not accepted yet, by path: `true` for
    /// viewed, `false` for unviewed.
    pub queued_viewed: BTreeMap<String, bool>,
    /// Node id of the reviewer's active pending review on GitHub, if any.
    pub pending_review_id: Option<String>,
    /// Login of the authenticated reviewer.
    pub viewer_login: Option<String>,
    /// Counter for temporary optimistic thread and message ids (`tmp-1`, ...).
    pub next_temp_id: u64,
    /// Temporary id to real GitHub node id mappings learned during replay.
    pub id_map: BTreeMap<String, String>,
    /// Last forge-confirmed body per message id, for concurrent-edit detection.
    pub agreed_bodies: BTreeMap<String, String>,
    /// Persisted threads (published, draft, queued, and failed) so restarts keep
    /// optimistic state before the next sync.
    pub threads: Vec<Thread>,
    /// Comment operations waiting to be sent to GitHub.
    pub queued_ops: Vec<QueuedCommentOp>,
    /// Cached `@mention` candidates from the last sync.
    pub mention_candidates: Vec<MentionCandidate>,
}

/// Everything the engine persists for one pull request.
///
/// A [`ReviewStore`] saves and loads it whole, and the session reopens from
/// it, so a restarted engine shows the last synced files before its first
/// sync.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StoreSnapshot {
    /// The serving process and the last synced pull request.
    pub session: SessionRecord,
    /// The changed files and their viewed state as last synced.
    pub files: Vec<ChangedFile>,
    /// What the engine still owes the forge.
    pub registry: SyncRegistry,
    /// Local-only threads and counters for the reviewer-agent loop.
    pub local: LocalStoreState,
}

/// Durable storage for one pull request's review state.
///
/// The session loads from it when it opens, and saves through it after every
/// successful sync and when the daemon records itself; for example, a store can
/// keep files on disk or keep everything in memory for a test.
pub trait ReviewStore: Send {
    /// What was saved last, or an empty snapshot when nothing was.
    fn load(&self) -> Result<StoreSnapshot>;
    /// Replaces what is saved.
    fn save(&self, snapshot: &StoreSnapshot) -> Result<()>;
    /// Appends one delivered agent round to durable storage.
    fn append_round(&self, round: &AgentRound) -> Result<()>;
    /// All persisted agent rounds, in append order.
    fn rounds(&self) -> Result<Vec<AgentRound>>;
}

/// The time in Unix seconds. The session stamps each sync with it; it is a
/// port so tests control the time.
pub trait Clock: Send {
    /// The current time in Unix seconds.
    fn now(&self) -> u64;
}

/// The real clock, for a running engine.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_secs())
    }
}

/// The adapters a session runs on, one per port. Only a composition root,
/// or a test, builds one.
pub struct Ports {
    /// The forge that hosts the pull request.
    pub forge: Box<dyn Forge>,
    /// Where the session's state is saved.
    pub store: Box<dyn ReviewStore>,
    /// The checkout the diffs are read from.
    pub workspace: Box<dyn Workspace>,
    /// The time.
    pub clock: Box<dyn Clock>,
}
