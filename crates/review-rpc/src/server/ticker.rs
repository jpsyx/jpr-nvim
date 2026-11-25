//! Background polling, retry, and worktree file-watch ticker for the RPC server.

use std::io::Write;
use std::sync::Mutex;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use review_core::ReviewSession;

use super::{ServeOptions, Shared, write_events};

const MIN_TICKER_INTERVAL: Duration = Duration::from_millis(1);

/// What the poller does when it wakes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PollStep {
    /// Pull from the forge (which sends the queue first).
    Sync,
    /// Resend the queue only.
    Retry,
    /// Nothing to do yet.
    Wait,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct TickerActions {
    poll: PollStep,
    should_watch: bool,
}

#[derive(Clone, Copy)]
struct TickerConfig {
    poll_every: Option<Duration>,
    retry_every: Option<Duration>,
    watch_every: Option<Duration>,
    wake_interval: Duration,
}

/// What the poller does `since_sync` after its last sync: sync once a whole
/// `poll_every` has passed, else resend a waiting queue, else wait.
#[must_use]
pub fn get_poll_step_from_elapsed(
    since_sync: Duration,
    poll_every: Duration,
    has_queued: bool,
) -> PollStep {
    if since_sync >= poll_every {
        PollStep::Sync
    } else if has_queued {
        PollStep::Retry
    } else {
        PollStep::Wait
    }
}

/// How long the poller sleeps between wake-ups: the shorter of the two
/// intervals.
#[must_use]
pub fn get_wake_interval_from_poll_and_retry(
    poll_every: Duration,
    retry_every: Option<Duration>,
) -> Duration {
    retry_every.map_or(poll_every, |retry_every| retry_every.min(poll_every))
}

/// How long the background ticker sleeps between wake-ups across sync polling,
/// retry polling, and worktree watching; `None` disables the background ticker
/// and zero intervals are ignored.
#[must_use]
pub fn get_wake_interval_from_intervals(
    poll_every: Option<Duration>,
    retry_every: Option<Duration>,
    watch_every: Option<Duration>,
) -> Option<Duration> {
    let poll_every = normalize_interval(poll_every);
    let retry_every = poll_every.and_then(|_| normalize_interval(retry_every));
    let watch_every = normalize_interval(watch_every);
    let poll_wake = poll_every.map(|poll| get_wake_interval_from_poll_and_retry(poll, retry_every));
    let combined = match (poll_wake, watch_every) {
        (Some(poll), Some(watch)) => Some(poll.min(watch)),
        (Some(poll), None) => Some(poll),
        (None, Some(watch)) => Some(watch),
        (None, None) => None,
    };
    combined.map(|interval| interval.max(MIN_TICKER_INTERVAL))
}

pub(super) fn has_enabled_watch(options: &ServeOptions) -> bool {
    normalize_interval(options.watch_every).is_some()
}

pub(super) fn start_ticker<W: Write + Send + 'static>(
    options: &ServeOptions,
    stopped: Receiver<()>,
    shared: Shared<W>,
) -> Option<JoinHandle<()>> {
    let poll_every = normalize_interval(options.poll_every);
    let retry_every = poll_every.and_then(|_| normalize_interval(options.retry_every));
    let watch_every = normalize_interval(options.watch_every);
    let wake_interval = get_wake_interval_from_intervals(poll_every, retry_every, watch_every)?;
    let config = TickerConfig {
        poll_every,
        retry_every,
        watch_every,
        wake_interval,
    };
    Some(spawn_ticker(shared, stopped, config))
}

fn normalize_interval(interval: Option<Duration>) -> Option<Duration> {
    interval.filter(|duration| !duration.is_zero())
}

fn get_ticker_actions_from_elapsed(
    config: TickerConfig,
    since_sync: Duration,
    since_retry: Duration,
    since_watch: Duration,
    has_queued: bool,
) -> TickerActions {
    let poll = if config.poll_every.is_some_and(|poll| since_sync >= poll) {
        PollStep::Sync
    } else if config.poll_every.is_some()
        && has_queued
        && config.retry_every.is_some_and(|retry| since_retry >= retry)
    {
        PollStep::Retry
    } else {
        PollStep::Wait
    };
    let should_watch = config.watch_every.is_some_and(|watch| since_watch >= watch);
    TickerActions { poll, should_watch }
}

fn spawn_ticker<W: Write + Send + 'static>(
    (session, events, writer): Shared<W>,
    stopped: Receiver<()>,
    config: TickerConfig,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let now = Instant::now();
        let mut last_sync = now;
        let mut last_retry = now;
        let mut last_watch = now;
        while stopped.recv_timeout(config.wake_interval) == Err(RecvTimeoutError::Timeout) {
            run_ticker_tick(
                &session,
                config,
                &mut last_sync,
                &mut last_retry,
                &mut last_watch,
            );
            if write_events(&events, &writer).is_err() {
                break;
            }
        }
    })
}

fn run_ticker_tick(
    session: &Mutex<ReviewSession>,
    config: TickerConfig,
    last_sync: &mut Instant,
    last_retry: &mut Instant,
    last_watch: &mut Instant,
) {
    let Ok(mut guard) = session.lock() else {
        return;
    };
    let actions = get_ticker_actions_from_elapsed(
        config,
        last_sync.elapsed(),
        last_retry.elapsed(),
        last_watch.elapsed(),
        guard.has_queued(),
    );
    if guard.is_linked() {
        match actions.poll {
            PollStep::Sync => {
                let _ = guard.sync();
                let now = Instant::now();
                *last_sync = now;
                *last_retry = now;
            }
            PollStep::Retry => {
                let _ = guard.flush_queued();
                *last_retry = Instant::now();
            }
            PollStep::Wait => {}
        }
    }
    if actions.should_watch {
        let _ = guard.poll_worktree_files();
        *last_watch = Instant::now();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MINUTE: Duration = Duration::from_secs(60);

    #[test]
    fn a_full_interval_since_the_last_sync_means_sync() {
        assert_eq!(
            get_poll_step_from_elapsed(MINUTE, MINUTE, true),
            PollStep::Sync
        );
        assert_eq!(
            get_poll_step_from_elapsed(MINUTE * 2, MINUTE, false),
            PollStep::Sync
        );
    }

    #[test]
    fn between_syncs_a_waiting_queue_is_retried() {
        assert_eq!(
            get_poll_step_from_elapsed(Duration::from_secs(20), MINUTE, true),
            PollStep::Retry
        );
        assert_eq!(
            get_poll_step_from_elapsed(Duration::from_secs(20), MINUTE, false),
            PollStep::Wait
        );
    }

    #[test]
    fn the_poller_wakes_at_the_shorter_interval() {
        let retry = Some(Duration::from_secs(20));
        assert_eq!(
            get_wake_interval_from_poll_and_retry(MINUTE, retry),
            Duration::from_secs(20)
        );
        assert_eq!(
            get_wake_interval_from_poll_and_retry(Duration::from_secs(5), retry),
            Duration::from_secs(5)
        );
        assert_eq!(get_wake_interval_from_poll_and_retry(MINUTE, None), MINUTE);
    }

    #[test]
    fn wake_interval_ignores_zero_and_enforces_minimum_floor() {
        assert_eq!(get_wake_interval_from_intervals(None, None, None), None);
        assert_eq!(
            get_wake_interval_from_intervals(
                Some(Duration::ZERO),
                Some(Duration::ZERO),
                Some(Duration::ZERO),
            ),
            None
        );
        assert_eq!(
            get_wake_interval_from_intervals(None, None, Some(Duration::from_nanos(1))),
            Some(Duration::from_millis(1))
        );
        assert_eq!(
            get_wake_interval_from_intervals(
                Some(MINUTE),
                Some(Duration::from_secs(20)),
                Some(Duration::from_secs(2)),
            ),
            Some(Duration::from_secs(2))
        );
    }

    #[test]
    fn watch_ticks_do_not_trigger_retry_when_retry_interval_not_elapsed_or_none() {
        let no_retry = TickerConfig {
            poll_every: Some(Duration::from_secs(10)),
            retry_every: None,
            watch_every: Some(Duration::from_millis(25)),
            wake_interval: Duration::from_millis(25),
        };
        let watch_tick = Duration::from_millis(30);
        assert_eq!(
            get_ticker_actions_from_elapsed(no_retry, watch_tick, watch_tick, watch_tick, true),
            TickerActions {
                poll: PollStep::Wait,
                should_watch: true,
            }
        );

        let slow_retry = TickerConfig {
            retry_every: Some(Duration::from_secs(10)),
            ..no_retry
        };
        assert_eq!(
            get_ticker_actions_from_elapsed(slow_retry, watch_tick, watch_tick, watch_tick, true),
            TickerActions {
                poll: PollStep::Wait,
                should_watch: true,
            }
        );
        assert_eq!(
            get_ticker_actions_from_elapsed(
                slow_retry,
                watch_tick,
                Duration::from_secs(10),
                Duration::ZERO,
                true,
            ),
            TickerActions {
                poll: PollStep::Retry,
                should_watch: false,
            }
        );
    }

    #[test]
    fn ticker_skips_sync_and_retry_while_unlinked_but_still_watches_worktree() {
        use review_core::fakes::{
            FakeForge, FakeWorkspace, FixedClock, MemoryStore, create_fake_ports, sample_pr,
        };
        use review_model::LocalReviewContext;

        let forge = FakeForge::new(sample_pr(), review_core::ports::ForgeSnapshot::default());
        let store = MemoryStore::default();
        let workspace = FakeWorkspace::default();
        workspace.put_base("src/a.rs", "old\n");
        workspace.put_disk("src/a.rs", "new\n");
        let clock = FixedClock::at(100);
        let ports = create_fake_ports(&forge, &store, &workspace, &clock);
        let context = LocalReviewContext {
            branch: "feat/local".into(),
            base_ref: "develop".into(),
            base_sha: "base000".into(),
            repo: None,
        };
        let session = Mutex::new(ReviewSession::open_local(context, ports).expect("local opens"));
        workspace.put_disk("src/b.rs", "added\n");

        let config = TickerConfig {
            poll_every: Some(Duration::from_millis(1)),
            retry_every: Some(Duration::from_millis(1)),
            watch_every: Some(Duration::from_millis(1)),
            wake_interval: Duration::from_millis(1),
        };
        let past = Instant::now()
            .checked_sub(Duration::from_secs(1))
            .expect("past instant");
        let mut last_sync = past;
        let mut last_retry = past;
        let mut last_watch = past;

        run_ticker_tick(
            &session,
            config,
            &mut last_sync,
            &mut last_retry,
            &mut last_watch,
        );

        assert_eq!(forge.fetches(), 0, "unlinked ticker must not sync forge");
        let files = session.lock().expect("lock").view().files;
        assert!(
            files.iter().any(|row| row.path == "src/b.rs"),
            "worktree watch must still refresh local files"
        );
    }
}
