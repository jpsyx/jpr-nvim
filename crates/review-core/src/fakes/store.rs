//! In-memory [`ReviewStore`] and [`Clock`] fakes shared by session and server tests.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use anyhow::{Result, anyhow};
use review_model::AgentRound;

use crate::ports::{Clock, ReviewStore, StoreSnapshot};

#[derive(Debug, Default)]
struct MemoryStoreState {
    snapshot: StoreSnapshot,
    rounds: Vec<AgentRound>,
    save_failure: Option<String>,
    retarget_snapshot: Option<StoreSnapshot>,
    retarget_failure: Option<String>,
    retargeted_prs: Vec<(String, String, u64)>,
    finalized_retarget_count: usize,
}

/// A store that keeps the snapshot and rounds in memory, for tests that open a
/// session without a disk. Clones share state, so a test can read what the
/// session saved.
#[derive(Debug, Clone, Default)]
pub struct MemoryStore {
    state: Arc<Mutex<MemoryStoreState>>,
}

impl MemoryStore {
    /// What was saved last.
    #[must_use]
    pub fn saved(&self) -> StoreSnapshot {
        self.lock().snapshot.clone()
    }

    /// Makes later `save` calls fail with `message`, or succeed again with `None`.
    pub fn fail_saves_with(&self, message: Option<&str>) {
        self.lock().save_failure = message.map(str::to_owned);
    }

    /// Preloads an existing PR snapshot returned by [`ReviewStore::retarget_to_pr`].
    pub fn set_retarget_snapshot(&self, snapshot: Option<StoreSnapshot>) {
        self.lock().retarget_snapshot = snapshot;
    }

    /// Makes later `retarget_to_pr` calls fail with `message`, or succeed again with `None`.
    pub fn fail_retarget_with(&self, message: Option<&str>) {
        self.lock().retarget_failure = message.map(str::to_owned);
    }

    /// Every `(owner, repo, number)` passed to [`ReviewStore::retarget_to_pr`].
    #[must_use]
    pub fn retargeted_prs(&self) -> Vec<(String, String, u64)> {
        self.lock().retargeted_prs.clone()
    }

    /// How many times [`ReviewStore::finalize_retarget`] succeeded.
    #[must_use]
    pub fn finalized_retarget_count(&self) -> usize {
        self.lock().finalized_retarget_count
    }

    fn lock(&self) -> MutexGuard<'_, MemoryStoreState> {
        self.state
            .lock()
            .expect("the memory store lock is poisoned")
    }
}

impl ReviewStore for MemoryStore {
    fn load(&self) -> Result<StoreSnapshot> {
        Ok(self.saved())
    }

    fn save(&self, snapshot: &StoreSnapshot) -> Result<()> {
        let mut state = self.lock();
        if let Some(message) = &state.save_failure {
            return Err(anyhow!("{message}"));
        }
        state.snapshot = snapshot.clone();
        drop(state);
        Ok(())
    }

    fn append_round(&self, round: &AgentRound) -> Result<()> {
        self.lock().rounds.push(round.clone());
        Ok(())
    }

    fn rounds(&self) -> Result<Vec<AgentRound>> {
        Ok(self.lock().rounds.clone())
    }

    fn retarget_to_pr(
        &self,
        owner: &str,
        repo: &str,
        number: u64,
    ) -> Result<Option<StoreSnapshot>> {
        let mut state = self.lock();
        if let Some(message) = &state.retarget_failure {
            return Err(anyhow!("{message}"));
        }
        state
            .retargeted_prs
            .push((owner.to_owned(), repo.to_owned(), number));
        Ok(state.retarget_snapshot.take())
    }

    fn finalize_retarget(&self) -> Result<()> {
        self.lock().finalized_retarget_count += 1;
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
