//! In-memory fakes of every port, for tests here and in other crates. Each
//! fake is a cheap handle: clones share state, so a test can keep one and give
//! another to the session.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use anyhow::{Result, anyhow};
use review_model::{
    Anchor, ChangedFile, Message, MessageSync, Origin, PullRequest, Thread, ThreadState,
    ViewedState,
};

use crate::ports::{Clock, Forge, ForgeSnapshot, ReviewStore, StoreSnapshot};

/// A pull request with plausible values (#7 in octo/widgets), for tests that
/// need any valid pull request, such as a fake forge's or a store round trip.
#[must_use]
pub fn sample_pr() -> PullRequest {
    PullRequest {
        owner: "octo".into(),
        repo: "widgets".into(),
        number: 7,
        title: "Fix the widget".into(),
        url: "https://github.com/octo/widgets/pull/7".into(),
        node_id: "PR_7".into(),
        author: "alice".into(),
        head_ref: "fix/widget".into(),
        head_sha: "abc123".into(),
        base_ref: "main".into(),
    }
}

/// A changed file with three additions and one deletion, for tests that build
/// a forge snapshot or a stored file list.
#[must_use]
pub fn changed_file(path: &str, viewed: ViewedState) -> ChangedFile {
    ChangedFile {
        path: path.into(),
        additions: 3,
        deletions: 1,
        viewed,
    }
}

/// A published GitHub thread with one comment on line 1 of `path`, for tests
/// that count or forward threads.
#[must_use]
pub fn github_thread(id: &str, path: &str) -> Thread {
    Thread {
        id: id.into(),
        origin: Origin::Github,
        anchor: Anchor::line(path, 1),
        state: ThreadState::Open,
        outdated: false,
        messages: vec![Message {
            id: format!("{id}-c1"),
            author: "bob".into(),
            body: "why?".into(),
            created: "2026-11-19T00:00:00Z".into(),
            updated: "2026-11-19T00:00:00Z".into(),
            sync: Some(MessageSync::Published),
        }],
    }
}

#[derive(Debug, Default)]
struct ForgeState {
    pr: Option<PullRequest>,
    snapshot: ForgeSnapshot,
    failure: Option<String>,
    fetches: usize,
}

/// A forge that answers from memory, for session and server tests. Clones
/// share state, so a test keeps one to steer it (fail, change the snapshot,
/// count fetches) while the session holds another.
#[derive(Debug, Clone, Default)]
pub struct FakeForge {
    state: Arc<Mutex<ForgeState>>,
}

impl FakeForge {
    /// A forge that knows `pr` and reports `snapshot` for it.
    #[must_use]
    pub fn new(pr: PullRequest, snapshot: ForgeSnapshot) -> Self {
        let forge = Self::default();
        {
            let mut state = forge.lock();
            state.pr = Some(pr);
            state.snapshot = snapshot;
        }
        forge
    }

    /// Makes every later call fail with `message`, or succeed again with `None`.
    pub fn fail_with(&self, message: Option<&str>) {
        self.lock().failure = message.map(str::to_owned);
    }

    /// Replaces what `fetch` reports.
    pub fn set_snapshot(&self, snapshot: ForgeSnapshot) {
        self.lock().snapshot = snapshot;
    }

    /// How many times `fetch` succeeded.
    #[must_use]
    pub fn fetches(&self) -> usize {
        self.lock().fetches
    }

    fn lock(&self) -> MutexGuard<'_, ForgeState> {
        self.state.lock().expect("the fake forge lock is poisoned")
    }
}

impl Forge for FakeForge {
    fn pull_request(&self, number: u64) -> Result<PullRequest> {
        let state = self.lock();
        if let Some(message) = &state.failure {
            return Err(anyhow!("{message}"));
        }
        state
            .pr
            .clone()
            .filter(|pr| pr.number == number)
            .ok_or_else(|| anyhow!("no pull request #{number}"))
    }

    fn fetch(&self, _pr: &PullRequest) -> Result<ForgeSnapshot> {
        let mut state = self.lock();
        if let Some(message) = &state.failure {
            return Err(anyhow!("{message}"));
        }
        state.fetches += 1;
        Ok(state.snapshot.clone())
    }
}

/// A store that keeps the snapshot in memory, for tests that open a session
/// without a disk. Clones share state, so a test can read what the session
/// saved.
#[derive(Debug, Clone, Default)]
pub struct MemoryStore {
    saved: Arc<Mutex<StoreSnapshot>>,
}

impl MemoryStore {
    /// What was saved last.
    #[must_use]
    pub fn saved(&self) -> StoreSnapshot {
        self.saved
            .lock()
            .expect("the memory store lock is poisoned")
            .clone()
    }
}

impl ReviewStore for MemoryStore {
    fn load(&self) -> Result<StoreSnapshot> {
        Ok(self.saved())
    }

    fn save(&self, snapshot: &StoreSnapshot) -> Result<()> {
        *self
            .saved
            .lock()
            .expect("the memory store lock is poisoned") = snapshot.clone();
        Ok(())
    }
}

/// A clock a test sets by hand, so sync times are exact. Clones share the
/// time, so a test can move the clock the session reads.
#[derive(Debug, Clone, Default)]
pub struct FixedClock {
    now: Arc<AtomicU64>,
}

impl FixedClock {
    /// A clock that reads `now`.
    #[must_use]
    pub fn at(now: u64) -> Self {
        Self {
            now: Arc::new(AtomicU64::new(now)),
        }
    }

    /// Moves the clock to `now`.
    pub fn set(&self, now: u64) {
        self.now.store(now, Ordering::SeqCst);
    }
}

impl Clock for FixedClock {
    fn now(&self) -> u64 {
        self.now.load(Ordering::SeqCst)
    }
}
