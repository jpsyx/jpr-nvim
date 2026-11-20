//! The ports: everything the engine needs from the outside world. Adapters
//! (GitHub, the file store, the system clock) implement them, and tests use
//! the in-memory fakes.

use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use review_model::{ChangedFile, PullRequest, Thread};
use serde::{Deserialize, Serialize};

/// What the forge reports about a pull request in one pull.
/// [`Forge::fetch`] returns it and the session applies it on every sync.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ForgeSnapshot {
    /// The pull request's head commit at the time of the pull.
    pub head_sha: String,
    /// Whether the reviewer has a pending (unsubmitted) review.
    pub has_pending_review: bool,
    /// Every review thread on the pull request.
    pub threads: Vec<Thread>,
    /// The changed files, with the reviewer's viewed state.
    pub files: Vec<ChangedFile>,
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
}

/// What the engine still owes the forge: changes made while the forge could
/// not be reached, sent again on the next try. Saved with everything else,
/// so a restarted engine still delivers them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SyncRegistry {
    /// Viewed marks the forge has not accepted yet, by path: `true` for
    /// viewed, `false` for unviewed.
    pub queued_viewed: BTreeMap<String, bool>,
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
