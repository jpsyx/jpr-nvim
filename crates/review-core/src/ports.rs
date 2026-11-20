//! The ports: everything the engine needs from the outside world. Adapters
//! (GitHub, the file store, the system clock) implement them, and tests use
//! the in-memory fakes.

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
