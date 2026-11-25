//! One pull request's review session: the facade every frontend talks to.
//! Each use case lives in its own submodule; this one holds the state they
//! share.

mod agent_loop;
mod comments;
mod diffs;
mod local;
mod local_files;
#[cfg(test)]
mod local_mode_tests;
mod push;
mod submit;
mod sync;
#[cfg(test)]
mod test_support;
mod viewed;
mod worktree_watch;

use diffs::BaseCache;
pub use local_files::PathRename;

use std::collections::BTreeMap;
use std::sync::mpsc::{self, Receiver, Sender};

use anyhow::{Context, Result, bail};
use review_model::{
    ChangedFile, Event, LocalReviewContext, Origin, PullRequest, SessionView, SyncState, Thread,
    WorktreeStatus,
};

use crate::ports::{Ports, StoreSnapshot};
use crate::presenter::session_view;
use crate::viewed::apply_queued;

#[derive(Debug, Clone, PartialEq, Eq)]
enum SessionTarget {
    Pr { number: u64 },
    Local(Box<LocalReviewContext>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PushedHead {
    base_pr_head_sha: String,
    pushed_sha: String,
}

/// One pull request's or local worktree's review session: the facade every
/// frontend talks to.
///
/// It owns the session state, reaches the outside world only through its
/// [`Ports`], and announces changes as [`Event`]s to its subscribers.
pub struct ReviewSession {
    target: SessionTarget,
    ports: Ports,
    saved: StoreSnapshot,
    threads: Vec<Thread>,
    sync: SyncState,
    subscribers: Vec<Sender<Event>>,
    base_cache: BaseCache,
    local_files: Vec<ChangedFile>,
    local_file_counts: BTreeMap<String, (u64, (u64, u64))>,
    disk_digests: Option<BTreeMap<String, u64>>,
    last_worktree_status: Option<WorktreeStatus>,
    pushed_head: Option<PushedHead>,
    pending_head_move_from: Option<String>,
}

impl ReviewSession {
    /// Opens pull request `number`'s session from what its store saved.
    /// Nothing talks to the forge until [`sync`](Self::sync).
    pub fn open(number: u64, ports: Ports) -> Result<Self> {
        Self::open_with_target(SessionTarget::Pr { number }, ports)
    }

    /// Opens an unlinked local worktree review session from what its store
    /// saved, immediately populating local changed files and disk digests.
    pub fn open_local(context: LocalReviewContext, ports: Ports) -> Result<Self> {
        let mut session = Self::open_with_target(SessionTarget::Local(Box::new(context)), ports)?;
        session.sync = SyncState::Never;
        session.refresh_local_files();
        let initial_digests = session.collect_worktree_digests();
        session.disk_digests = Some(initial_digests);
        Ok(session)
    }

    fn open_with_target(target: SessionTarget, ports: Ports) -> Result<Self> {
        let mut saved = ports.store.load()?;
        // The queue is saved before the files, so a crash between the two
        // can leave the files behind a queued mark.
        apply_queued(&mut saved.files, &saved.registry.queued_viewed);
        let sync = saved
            .session
            .last_synced_at
            .map_or(SyncState::Never, |at| SyncState::Synced { at });
        let mut threads = saved.registry.threads.clone();
        threads.extend(saved.local.threads.clone());
        Ok(Self {
            target,
            ports,
            saved,
            threads,
            sync,
            subscribers: Vec::new(),
            base_cache: BaseCache::default(),
            local_files: Vec::new(),
            local_file_counts: BTreeMap::new(),
            disk_digests: None,
            last_worktree_status: None,
            pushed_head: None,
            pending_head_move_from: None,
        })
    }

    /// Whether this session is linked to a GitHub pull request.
    #[must_use]
    pub const fn is_linked(&self) -> bool {
        matches!(self.target, SessionTarget::Pr { .. })
    }

    /// Local review context when unlinked, or `None` once linked to a PR.
    pub(super) fn local_context(&self) -> Option<&LocalReviewContext> {
        match &self.target {
            SessionTarget::Local(context) => Some(context),
            SessionTarget::Pr { .. } => None,
        }
    }

    /// Whether a base commit is available for computing local worktree diffs.
    pub(super) fn has_active_base(&self) -> bool {
        match &self.target {
            SessionTarget::Local(context) => {
                !context.base_sha.is_empty() || !context.base_ref.is_empty()
            }
            SessionTarget::Pr { .. } => self
                .saved
                .session
                .pr
                .as_ref()
                .is_some_and(|pr| !pr.base_sha.is_empty()),
        }
    }

    /// Resolves the active base commit SHA, refreshing `base_ref` in local mode
    /// if the local base branch moved.
    pub(super) fn active_base_sha(&mut self) -> Result<String> {
        match &mut self.target {
            SessionTarget::Pr { .. } => {
                let base_sha = self.synced_pr()?.base_sha.clone();
                if base_sha.is_empty() {
                    bail!("the base commit is not known yet; sync with GitHub first");
                }
                Ok(base_sha)
            }
            SessionTarget::Local(context) => {
                if let Ok(resolved) = self.ports.workspace.resolve_ref(&context.base_ref)
                    && !resolved.is_empty()
                {
                    context.base_sha.clone_from(&resolved);
                    return Ok(resolved);
                }
                if context.base_sha.is_empty() {
                    bail!(
                        "the local base commit for {} is not known",
                        context.base_ref
                    );
                }
                Ok(context.base_sha.clone())
            }
        }
    }

    /// Records the process serving this session, so others can find it.
    pub fn record_daemon(&mut self, pid: u32, worktree: &str) -> Result<()> {
        self.record_daemon_with_socket(pid, worktree, None)
    }

    /// Records the process serving this session and its optional Unix domain
    /// socket path, so CLI tools can discover and talk to it.
    pub fn record_daemon_with_socket(
        &mut self,
        pid: u32,
        worktree: &str,
        socket: Option<&str>,
    ) -> Result<()> {
        self.saved.session.pid = Some(pid);
        self.saved.session.worktree = Some(worktree.to_owned());
        self.saved.session.socket = socket.map(str::to_owned);
        self.ports.store.save(&self.saved)
    }

    /// A channel that receives every later [`Event`].
    pub fn subscribe(&mut self) -> Receiver<Event> {
        let (sender, receiver) = mpsc::channel();
        self.subscribers.push(sender);
        receiver
    }

    /// The current status view.
    #[must_use]
    pub fn view(&self) -> SessionView {
        let worktree_status = self.current_worktree_status();
        self.view_with_status(&worktree_status)
    }

    /// Builds the session status view using a pre-read worktree status.
    pub(super) fn view_with_status(&self, worktree_status: &WorktreeStatus) -> SessionView {
        let effective = self.effective_files();
        session_view(
            self.saved.session.pr.as_ref(),
            self.local_context(),
            &effective,
            &self.threads,
            &self.sync,
            self.saved.registry.queued_viewed.len() + self.saved.registry.queued_ops.len(),
            worktree_status,
        )
    }

    /// Remote head SHA to compare `HEAD` against, preferring an in-flight
    /// pushed SHA until the next forge sync catches up.
    pub(super) fn effective_remote_head_sha(&self) -> Option<&str> {
        self.pushed_head
            .as_ref()
            .map(|pushed| pushed.pushed_sha.as_str())
            .or_else(|| {
                self.saved
                    .session
                    .pr
                    .as_ref()
                    .map(|pr| pr.head_sha.as_str())
            })
    }

    /// Live dirty and ahead/behind status from the workspace, or `None` when
    /// the workspace cannot report it.
    pub(super) fn read_worktree_status(&self) -> Option<WorktreeStatus> {
        let remote_head_sha = self.effective_remote_head_sha();
        self.ports.workspace.worktree_status(remote_head_sha).ok()
    }

    /// Live worktree status, falling back to the last published status or an
    /// empty default.
    pub(super) fn current_worktree_status(&self) -> WorktreeStatus {
        self.read_worktree_status()
            .or_else(|| self.last_worktree_status.clone())
            .unwrap_or_default()
    }

    /// Partitions GitHub and local threads into their separate store slices
    /// before saving so `github.json` and `local.json` stay isolated.
    pub(super) fn split_and_save_threads(&mut self) -> Result<()> {
        self.saved.registry.threads = self
            .threads
            .iter()
            .filter(|thread| thread.origin == Origin::Github)
            .cloned()
            .collect();
        self.saved.local.threads = self
            .threads
            .iter()
            .filter(|thread| thread.origin == Origin::Local)
            .cloned()
            .collect();
        self.ports.store.save(&self.saved)
    }

    /// The pull request as last synced, for use cases that need it.
    fn synced_pr(&self) -> Result<&PullRequest> {
        self.saved
            .session
            .pr
            .as_ref()
            .context("the pull request has not synced with GitHub yet")
    }

    /// The synced pull request, refusing unlinked local sessions with a clear notice.
    pub(super) fn require_linked_pr(&self) -> Result<&PullRequest> {
        if !self.is_linked() {
            bail!(
                "this review is not linked to a GitHub pull request yet; run :Jpr sync once a PR is open"
            );
        }
        self.synced_pr()
    }

    fn publish(&mut self, event: &Event) {
        if let Some(view) = get_view_from_event(event) {
            self.last_worktree_status = Some(view.worktree_status.clone());
        }
        self.subscribers
            .retain(|subscriber| subscriber.send(event.clone()).is_ok());
    }
}

const fn get_view_from_event(event: &Event) -> Option<&SessionView> {
    match event {
        Event::Synced { view }
        | Event::ViewedChanged { view }
        | Event::ThreadsChanged { view }
        | Event::FilesChanged { view, .. }
        | Event::AgentRound { view, .. }
        | Event::WorktreeStatusChanged { view }
        | Event::HeadMoved { view, .. } => Some(view),
        Event::SyncFailed { .. } => None,
    }
}

#[cfg(test)]
mod tests {
    use review_model::SyncState;

    use super::test_support::Fakes;
    use crate::fakes::github_thread;
    use crate::ports::{ReviewStore, StoreSnapshot};

    #[test]
    fn a_new_session_has_not_synced() {
        let view = Fakes::new(10).open().view();
        assert_eq!(view.sync, SyncState::Never);
        assert!(view.pr.is_none());
        assert_eq!(view.files, Vec::new());
    }

    #[test]
    fn reopening_restores_persisted_threads_before_sync() {
        let fakes = Fakes::new(10);
        let mut snapshot = StoreSnapshot::default();
        snapshot.registry.threads = vec![github_thread("T1", "src/a.rs")];
        fakes.store.save(&snapshot).unwrap();
        let view = fakes.open().view();
        assert_eq!(view.thread_count, 1);
    }

    #[test]
    fn reopening_counts_both_queued_viewed_and_queued_ops() {
        let fakes = Fakes::new(10);
        let mut snapshot = StoreSnapshot::default();
        snapshot
            .registry
            .queued_viewed
            .insert("src/a.rs".into(), true);
        snapshot
            .registry
            .queued_ops
            .push(crate::ports::QueuedCommentOp::SetResolved {
                thread_id: "T1".into(),
                resolved: true,
            });
        fakes.store.save(&snapshot).unwrap();
        let view = fakes.open().view();
        assert_eq!(view.queued_count, 2);
    }

    #[test]
    fn record_daemon_saves_the_pid_and_worktree() {
        let fakes = Fakes::new(1);
        fakes
            .open()
            .record_daemon(4242, "/tmp/widgets-worktrees/pr-7")
            .expect("it saves");
        let saved = fakes.store.saved();
        assert_eq!(saved.session.pid, Some(4242));
        assert_eq!(
            saved.session.worktree.as_deref(),
            Some("/tmp/widgets-worktrees/pr-7")
        );
    }

    #[test]
    fn a_dropped_subscriber_does_not_stop_the_others() {
        let mut session = Fakes::new(1).open();
        drop(session.subscribe());
        let events = session.subscribe();
        session.sync().expect("the sync succeeds");
        assert!(events.try_recv().is_ok());
    }
}
