//! The ports: everything the engine needs from the outside world. Adapters
//! (GitHub, the file store, the system clock) implement them, and tests use
//! the in-memory fakes.

use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use review_model::{ChangedFile, PullRequest, Thread};
use serde::{Deserialize, Serialize};

/// What the forge reports about a pull request in one pull.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ForgeSnapshot {
    pub head_sha: String,
    /// Whether the reviewer has a pending (unsubmitted) review.
    pub has_pending_review: bool,
    pub threads: Vec<Thread>,
    pub files: Vec<ChangedFile>,
}

/// The code forge that hosts the pull request (GitHub today).
pub trait Forge: Send {
    /// The open pull request numbered `number`.
    fn pull_request(&self, number: u64) -> Result<PullRequest>;
    /// Its threads, changed files and viewed state.
    fn fetch(&self, pr: &PullRequest) -> Result<ForgeSnapshot>;
}

/// The running daemon and what it last saw, persisted between runs.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SessionRecord {
    pub pid: Option<u32>,
    pub worktree: Option<String>,
    pub pr: Option<PullRequest>,
    /// Unix seconds of the last successful sync.
    pub last_synced_at: Option<u64>,
}

/// Everything the engine persists for one pull request. Later milestones add
/// local threads, the sync registry and agent rounds as new fields.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StoreSnapshot {
    pub session: SessionRecord,
    /// The changed files and their viewed state as last synced.
    pub files: Vec<ChangedFile>,
}

/// Durable storage for one pull request's review state.
pub trait ReviewStore: Send {
    /// What was saved last, or an empty snapshot when nothing was.
    fn load(&self) -> Result<StoreSnapshot>;
    /// Replaces what is saved.
    fn save(&self, snapshot: &StoreSnapshot) -> Result<()>;
}

/// The time in Unix seconds. A port so tests control it.
pub trait Clock: Send {
    fn now(&self) -> u64;
}

/// The real clock.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_secs())
    }
}
