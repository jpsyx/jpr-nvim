//! In-memory fakes of every port, for tests here and in other crates. Each
//! fake is a cheap handle: clones share state, so a test can keep one and give
//! another to the session.

mod comments;
mod workspace;

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use anyhow::{Result, anyhow};
use review_model::{
    AgentRound, Anchor, AnchorKind, ChangedFile, Message, MessageSync, Origin, PullRequest,
    Reaction, ReactionContent, ReviewEvent, Thread, ThreadState, ViewedState,
};

use crate::ports::{
    Clock, CreatedReviewThread, Forge, ForgeSnapshot, ForgeWriteError, Ports, ReplyRequest,
    ReviewStore, StoreSnapshot,
};

pub use workspace::{FAKE_MERGE_BASE, FakeWorkspace};

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
        base_sha: "base000".into(),
        is_cross_repository: false,
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
        messages: vec![Message::create_with_sync(
            &format!("{id}-c1"),
            "bob",
            "why?",
            "2026-11-19T00:00:00Z",
            Some(MessageSync::Published),
        )],
        agent: None,
        promoted_to: None,
    }
}

#[derive(Debug, Default)]
struct ForgeState {
    pr: Option<PullRequest>,
    current_branch_pr_override: Option<Option<PullRequest>>,
    pinned_repo: Option<String>,
    snapshot: ForgeSnapshot,
    failure: Option<String>,
    fetches: usize,
    read_failure: Option<String>,
    write_failure: Option<String>,
    rejected_write_failure: Option<String>,
    next_id: u64,
    viewed_calls: Vec<(String, bool)>,
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

    /// Replaces what `pull_request` reports.
    pub fn set_pr(&self, pr: PullRequest) {
        self.lock().pr = Some(pr);
    }

    /// Clears the pull request reported by `pull_request` and `current_branch_pr`.
    pub fn clear_pr(&self) {
        let mut state = self.lock();
        state.pr = None;
        state.current_branch_pr_override = Some(None);
    }

    /// Overrides what `current_branch_pr` returns.
    pub fn set_current_branch_pr(&self, pr: Option<PullRequest>) {
        self.lock().current_branch_pr_override = Some(pr);
    }

    /// Repository pinned via [`Forge::pin_repo`], if any.
    #[must_use]
    pub fn pinned_repo(&self) -> Option<String> {
        self.lock().pinned_repo.clone()
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

    /// Makes every later write fail with `message` while reads still work, or
    /// lets writes succeed again with `None`. A forge that answers reads but
    /// refuses writes is how a queued change is tested.
    pub fn fail_writes_with(&self, message: Option<&str>) {
        self.lock().write_failure = message.map(str::to_owned);
    }

    /// Makes every later comment/review write fail with a rejected error
    /// (`ForgeWriteError::Rejected`), or lets writes succeed again with `None`.
    pub fn reject_writes_with(&self, message: Option<&str>) {
        self.lock().rejected_write_failure = message.map(str::to_owned);
    }

    /// Makes every later read fail with `message` while writes still work, or
    /// lets reads succeed again with `None`. A forge that takes a queued mark
    /// and then fails the pull is how a sync's partial progress is tested.
    pub fn fail_reads_with(&self, message: Option<&str>) {
        self.lock().read_failure = message.map(str::to_owned);
    }

    /// Every viewed mark the forge accepted, in order.
    #[must_use]
    pub fn viewed_calls(&self) -> Vec<(String, bool)> {
        self.lock().viewed_calls.clone()
    }

    fn lock(&self) -> MutexGuard<'_, ForgeState> {
        self.state.lock().expect("the fake forge lock is poisoned")
    }
}

impl Forge for FakeForge {
    fn pull_request(&self, number: u64) -> Result<PullRequest> {
        let state = self.lock();
        if let Some(message) = state.failure.as_ref().or(state.read_failure.as_ref()) {
            return Err(anyhow!("{message}"));
        }
        state
            .pr
            .clone()
            .filter(|pr| pr.number == number)
            .ok_or_else(|| anyhow!("no pull request #{number}"))
    }

    fn current_branch_pr(&self) -> Result<Option<PullRequest>> {
        let state = self.lock();
        if let Some(message) = state.failure.as_ref().or(state.read_failure.as_ref()) {
            return Err(anyhow!("{message}"));
        }
        Ok(match &state.current_branch_pr_override {
            Some(overridden) => overridden.clone(),
            None => state.pr.clone(),
        })
    }

    fn pin_repo(&self, owner: &str, repo: &str) {
        self.lock().pinned_repo = Some(format!("{owner}/{repo}"));
    }

    fn fetch(&self, _pr: &PullRequest) -> Result<ForgeSnapshot> {
        let mut state = self.lock();
        if let Some(message) = state.failure.as_ref().or(state.read_failure.as_ref()) {
            return Err(anyhow!("{message}"));
        }
        state.fetches += 1;
        Ok(state.snapshot.clone())
    }

    fn set_viewed(&self, _pr: &PullRequest, path: &str, viewed: bool) -> Result<()> {
        let mut state = self.lock();
        if let Some(message) = state.failure.as_ref().or(state.write_failure.as_ref()) {
            return Err(anyhow!("{message}"));
        }
        state.viewed_calls.push((path.to_owned(), viewed));
        let marked = crate::viewed::viewed_flag_to_state(viewed);
        for file in &mut state.snapshot.files {
            if file.path == path {
                file.viewed = marked;
            }
        }
        drop(state);
        Ok(())
    }

    fn create_review_thread(
        &self,
        _pr: &PullRequest,
        pending_review_id: Option<&str>,
        anchor: &Anchor,
        body: &str,
    ) -> std::result::Result<CreatedReviewThread, ForgeWriteError> {
        self.create_review_thread_in_memory(pending_review_id, anchor, body)
    }

    fn create_conversation_comment(
        &self,
        _pr: &PullRequest,
        body: &str,
    ) -> std::result::Result<Thread, ForgeWriteError> {
        self.create_conversation_comment_in_memory(body)
    }

    fn reply_to_thread(
        &self,
        _pr: &PullRequest,
        request: &ReplyRequest<'_>,
    ) -> std::result::Result<Message, ForgeWriteError> {
        self.reply_to_thread_in_memory(request)
    }

    fn edit_message(
        &self,
        anchor_kind: AnchorKind,
        message_id: &str,
        body: &str,
    ) -> std::result::Result<Message, ForgeWriteError> {
        self.edit_message_in_memory(anchor_kind, message_id, body)
    }

    fn delete_message(
        &self,
        anchor_kind: AnchorKind,
        message_id: &str,
    ) -> std::result::Result<(), ForgeWriteError> {
        self.delete_message_in_memory(anchor_kind, message_id)
    }

    fn set_resolved(
        &self,
        thread_id: &str,
        resolved: bool,
    ) -> std::result::Result<(), ForgeWriteError> {
        self.set_resolved_in_memory(thread_id, resolved)
    }

    fn set_reaction(
        &self,
        subject_id: &str,
        content: ReactionContent,
        added: bool,
    ) -> std::result::Result<Vec<Reaction>, ForgeWriteError> {
        self.set_reaction_in_memory(subject_id, content, added)
    }

    fn submit_review(
        &self,
        _pr: &PullRequest,
        _pending_review_id: Option<&str>,
        event: ReviewEvent,
        body: &str,
    ) -> std::result::Result<(), ForgeWriteError> {
        self.submit_review_in_memory(event, body)
    }
}

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

/// [`Ports`] over clones of these fakes, so a test keeps handles that share
/// state with what the session holds.
#[must_use]
pub fn create_fake_ports(
    forge: &FakeForge,
    store: &MemoryStore,
    workspace: &FakeWorkspace,
    clock: &FixedClock,
) -> Ports {
    Ports {
        forge: Box::new(forge.clone()),
        store: Box::new(store.clone()),
        workspace: Box::new(workspace.clone()),
        clock: Box::new(clock.clone()),
    }
}

#[cfg(test)]
mod tests;
