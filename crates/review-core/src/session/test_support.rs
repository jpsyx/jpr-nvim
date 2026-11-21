//! Fixtures shared by the session's tests: a session over fakes that the
//! test keeps handles to.

use review_model::ViewedState;

use super::ReviewSession;
use crate::fakes::{
    FakeForge, FakeWorkspace, FixedClock, MemoryStore, changed_file, create_fake_ports,
    github_thread, sample_pr,
};
use crate::ports::ForgeSnapshot;

/// The fakes behind a test session. Each is a handle that shares state with
/// the session's copy, so a test steers and inspects them.
#[derive(Clone, Default)]
pub struct Fakes {
    pub forge: FakeForge,
    pub store: MemoryStore,
    pub workspace: FakeWorkspace,
    pub clock: FixedClock,
}

impl Fakes {
    /// Fakes at time `now` whose forge reports [`create_snapshot`] for the
    /// sample pull request.
    pub fn new(now: u64) -> Self {
        Self {
            forge: FakeForge::new(sample_pr(), create_snapshot()),
            clock: FixedClock::at(now),
            ..Self::default()
        }
    }

    /// A session for pull request 7 over these fakes.
    pub fn open(&self) -> ReviewSession {
        let ports = create_fake_ports(&self.forge, &self.store, &self.workspace, &self.clock);
        ReviewSession::open(7, ports).expect("the session opens")
    }

    /// A session for pull request 7 over these fakes, synced once.
    pub fn open_synced(&self) -> ReviewSession {
        let mut session = self.open();
        session.sync().expect("the sync succeeds");
        session
    }
}

/// What the fake forge reports: one thread, a viewed `src/a.rs` and an
/// unviewed `src/b.rs`.
pub fn create_snapshot() -> ForgeSnapshot {
    ForgeSnapshot {
        head_sha: "abc123".into(),
        has_pending_review: false,
        threads: vec![github_thread("T1", "src/a.rs")],
        files: vec![
            changed_file("src/a.rs", ViewedState::Viewed),
            changed_file("src/b.rs", ViewedState::Unviewed),
        ],
        ..ForgeSnapshot::default()
    }
}
