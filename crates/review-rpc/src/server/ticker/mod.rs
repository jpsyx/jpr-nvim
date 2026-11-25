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
                let _ = guard.sync_background();
                let now = Instant::now();
                *last_sync = now;
                *last_retry = now;
            }
            PollStep::Retry => {
                let _ = guard.flush_queued_background();
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
mod tests;
