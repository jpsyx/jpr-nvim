//! One pull request's review session: the facade every frontend talks to.
//! Each use case lives in its own submodule; this one holds the state they
//! share.

mod agent_loop;
mod comments;
mod diffs;
mod local;
mod submit;
mod sync;
#[cfg(test)]
mod test_support;
mod viewed;
mod worktree_watch;

use diffs::BaseCache;

use std::collections::BTreeMap;
use std::sync::mpsc::{self, Receiver, Sender};

use anyhow::{Context, Result};
use review_model::{Event, Origin, PullRequest, SessionView, SyncState, Thread};

use crate::ports::{Ports, StoreSnapshot};
use crate::presenter::session_view;
use crate::viewed::apply_queued;

/// One pull request's review session: the facade every frontend talks to.
///
/// It owns the session state, reaches the outside world only through its
/// [`Ports`], and announces changes as [`Event`]s to its subscribers.
pub struct ReviewSession {
    number: u64,
    ports: Ports,
    saved: StoreSnapshot,
    threads: Vec<Thread>,
    sync: SyncState,
    subscribers: Vec<Sender<Event>>,
    base_cache: BaseCache,
    disk_digests: Option<BTreeMap<String, u64>>,
}

impl ReviewSession {
    /// Opens pull request `number`'s session from what its store saved.
    /// Nothing talks to the forge until [`sync`](Self::sync).
    pub fn open(number: u64, ports: Ports) -> Result<Self> {
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
            number,
            ports,
            saved,
            threads,
            sync,
            subscribers: Vec::new(),
            base_cache: BaseCache::default(),
            disk_digests: None,
        })
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
        session_view(
            self.saved.session.pr.as_ref(),
            &self.saved.files,
            &self.threads,
            &self.sync,
            self.saved.registry.queued_viewed.len() + self.saved.registry.queued_ops.len(),
        )
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

    fn publish(&mut self, event: &Event) {
        self.subscribers
            .retain(|subscriber| subscriber.send(event.clone()).is_ok());
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
        assert!(view.files.is_empty());
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
