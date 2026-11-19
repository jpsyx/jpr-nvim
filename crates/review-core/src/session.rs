//! The facade every frontend talks to. It owns the session state, reaches the
//! outside world only through the ports, and announces changes as events.

use std::sync::mpsc::{self, Receiver, Sender};

use anyhow::Result;
use review_model::{Event, PullRequest, SessionView, SyncState, Thread};

use crate::ports::{Clock, Forge, ForgeSnapshot, ReviewStore, StoreSnapshot};
use crate::presenter::session_view;

/// One pull request's review session.
pub struct ReviewSession {
    number: u64,
    forge: Box<dyn Forge>,
    store: Box<dyn ReviewStore>,
    clock: Box<dyn Clock>,
    saved: StoreSnapshot,
    threads: Vec<Thread>,
    sync: SyncState,
    subscribers: Vec<Sender<Event>>,
}

impl ReviewSession {
    /// Opens pull request `number`'s session from what `store` saved. Nothing
    /// talks to the forge until [`sync`](Self::sync).
    pub fn open(
        number: u64,
        forge: Box<dyn Forge>,
        store: Box<dyn ReviewStore>,
        clock: Box<dyn Clock>,
    ) -> Result<Self> {
        let saved = store.load()?;
        let sync = saved
            .session
            .last_synced_at
            .map_or(SyncState::Never, |at| SyncState::Synced { at });
        Ok(Self {
            number,
            forge,
            store,
            clock,
            saved,
            threads: Vec::new(),
            sync,
            subscribers: Vec::new(),
        })
    }

    /// Records the process serving this session, so others can find it.
    pub fn record_daemon(&mut self, pid: u32, worktree: &str) -> Result<()> {
        self.saved.session.pid = Some(pid);
        self.saved.session.worktree = Some(worktree.to_owned());
        self.store.save(&self.saved)
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
        )
    }

    /// Pulls the pull request from the forge, saves it, and announces it. A
    /// failure keeps the previous view, announces the failure, and saves nothing.
    pub fn sync(&mut self) -> Result<SessionView> {
        let now = self.clock.now();
        match self.pull() {
            Ok((pr, snapshot)) => {
                self.saved.session.pr = Some(pr);
                self.saved.session.last_synced_at = Some(now);
                self.saved.files = snapshot.files;
                self.threads = snapshot.threads;
                self.sync = SyncState::Synced { at: now };
                self.store.save(&self.saved)?;
                let view = self.view();
                self.publish(&Event::Synced {
                    view: Box::new(view.clone()),
                });
                Ok(view)
            }
            Err(error) => {
                let message = format!("{error:#}");
                self.sync = SyncState::Failed {
                    at: now,
                    message: message.clone(),
                };
                self.publish(&Event::SyncFailed { message });
                Err(error)
            }
        }
    }

    fn pull(&self) -> Result<(PullRequest, ForgeSnapshot)> {
        let pr = self.forge.pull_request(self.number)?;
        let snapshot = self.forge.fetch(&pr)?;
        Ok((pr, snapshot))
    }

    fn publish(&mut self, event: &Event) {
        self.subscribers
            .retain(|subscriber| subscriber.send(event.clone()).is_ok());
    }
}

#[cfg(test)]
mod tests {
    use review_model::ViewedState;

    use super::*;
    use crate::fakes::{
        FakeForge, FixedClock, MemoryStore, changed_file, github_thread, sample_pr,
    };

    fn snapshot() -> ForgeSnapshot {
        ForgeSnapshot {
            head_sha: "abc123".into(),
            has_pending_review: false,
            threads: vec![github_thread("T1", "src/a.rs")],
            files: vec![
                changed_file("src/a.rs", ViewedState::Viewed),
                changed_file("src/b.rs", ViewedState::Unviewed),
            ],
        }
    }

    fn open(forge: &FakeForge, store: &MemoryStore, clock: &FixedClock) -> ReviewSession {
        ReviewSession::open(
            7,
            Box::new(forge.clone()),
            Box::new(store.clone()),
            Box::new(clock.clone()),
        )
        .expect("the session opens")
    }

    #[test]
    fn a_new_session_has_not_synced() {
        let session = open(
            &FakeForge::new(sample_pr(), snapshot()),
            &MemoryStore::default(),
            &FixedClock::at(10),
        );
        let view = session.view();
        assert_eq!(view.sync, SyncState::Never);
        assert!(view.pr.is_none());
        assert!(view.files.is_empty());
    }

    #[test]
    fn sync_pulls_saves_and_announces() {
        let (forge, store, clock) = (
            FakeForge::new(sample_pr(), snapshot()),
            MemoryStore::default(),
            FixedClock::at(100),
        );
        let mut session = open(&forge, &store, &clock);
        let events = session.subscribe();
        let view = session.sync().expect("the sync succeeds");
        assert_eq!(view.files.len(), 2);
        assert_eq!(view.thread_count, 1);
        assert_eq!(view.viewed_count, 1);
        assert_eq!(view.sync, SyncState::Synced { at: 100 });
        let saved = store.saved();
        assert_eq!(saved.session.pr.map(|pr| pr.number), Some(7));
        assert_eq!(saved.session.last_synced_at, Some(100));
        assert_eq!(saved.files.len(), 2);
        assert_eq!(
            events.try_recv().expect("an event was sent"),
            Event::Synced {
                view: Box::new(view)
            }
        );
    }

    #[test]
    fn a_reopened_session_shows_the_saved_files_before_syncing() {
        let (forge, store, clock) = (
            FakeForge::new(sample_pr(), snapshot()),
            MemoryStore::default(),
            FixedClock::at(100),
        );
        open(&forge, &store, &clock)
            .sync()
            .expect("the first sync succeeds");
        let view = open(&forge, &store, &clock).view();
        assert_eq!(view.files.len(), 2);
        assert_eq!(
            view.pr.map(|pr| pr.title),
            Some("Fix the widget".to_owned())
        );
        assert_eq!(view.sync, SyncState::Synced { at: 100 });
    }

    #[test]
    fn a_failed_sync_keeps_the_last_view_and_announces_the_failure() {
        let (forge, store, clock) = (
            FakeForge::new(sample_pr(), snapshot()),
            MemoryStore::default(),
            FixedClock::at(100),
        );
        let mut session = open(&forge, &store, &clock);
        session.sync().expect("the first sync succeeds");
        let events = session.subscribe();
        forge.fail_with(Some("gh timed out after 30s"));
        clock.set(160);
        let error = session.sync().expect_err("the forge fails");
        assert!(error.to_string().contains("timed out"));
        let view = session.view();
        assert_eq!(view.files.len(), 2, "the last synced files are kept");
        assert_eq!(
            view.sync,
            SyncState::Failed {
                at: 160,
                message: "gh timed out after 30s".into()
            }
        );
        assert_eq!(
            events.try_recv().expect("an event was sent"),
            Event::SyncFailed {
                message: "gh timed out after 30s".into()
            }
        );
        assert_eq!(
            store.saved().session.last_synced_at,
            Some(100),
            "a failure saves nothing"
        );
    }

    #[test]
    fn github_resetting_a_viewed_file_reaches_the_view() {
        let (forge, store, clock) = (
            FakeForge::new(sample_pr(), snapshot()),
            MemoryStore::default(),
            FixedClock::at(1),
        );
        let mut session = open(&forge, &store, &clock);
        session.sync().expect("the first sync succeeds");
        let mut changed = snapshot();
        changed.files[0].viewed = ViewedState::Dismissed;
        forge.set_snapshot(changed);
        let view = session.sync().expect("the second sync succeeds");
        assert_eq!(view.files[0].viewed, ViewedState::Dismissed);
        assert_eq!(view.viewed_count, 0);
    }

    #[test]
    fn record_daemon_saves_the_pid_and_worktree() {
        let store = MemoryStore::default();
        let mut session = open(
            &FakeForge::new(sample_pr(), snapshot()),
            &store,
            &FixedClock::at(1),
        );
        session
            .record_daemon(4242, "/tmp/widgets-worktrees/pr-7")
            .expect("it saves");
        let saved = store.saved();
        assert_eq!(saved.session.pid, Some(4242));
        assert_eq!(
            saved.session.worktree.as_deref(),
            Some("/tmp/widgets-worktrees/pr-7")
        );
    }

    #[test]
    fn a_dropped_subscriber_does_not_stop_the_others() {
        let mut session = open(
            &FakeForge::new(sample_pr(), snapshot()),
            &MemoryStore::default(),
            &FixedClock::at(1),
        );
        drop(session.subscribe());
        let events = session.subscribe();
        session.sync().expect("the sync succeeds");
        assert!(events.try_recv().is_ok());
    }
}
