//! Serving a `ReviewSession` over any line-based transport, such as stdio.
//! Responses and event notifications share one writer, one JSON message per
//! line.

mod comments;

use std::io::{BufRead, Write};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow};
use review_core::ReviewSession;
use review_model::Event;
use serde::Serialize;
use serde_json::{Value, json};

use crate::params::{get_bool_from_params, get_mode_from_params, get_string_from_params};
use crate::protocol::{
    PROTOCOL_VERSION, Request, RpcError, failure, notification, parse_request, success,
};

/// How a server runs, for example as the `serve` command sets it from its
/// flags.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServeOptions {
    /// The engine's version, reported by `initialize`.
    pub server_version: String,
    /// How often to sync in the background; `None` syncs only on request.
    pub poll_every: Option<Duration>,
    /// How often, between syncs, to resend what the forge refused; `None`
    /// waits for the next sync. Only a server that polls retries.
    pub retry_every: Option<Duration>,
}

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

/// Answers one request. Routing only: every rule lives in the session.
pub fn handle(
    session: &Mutex<ReviewSession>,
    request: &Request,
    server_version: &str,
) -> Result<Value, RpcError> {
    let params = &request.params;
    match request.method.as_str() {
        "initialize" => {
            Ok(json!({ "protocolVersion": PROTOCOL_VERSION, "version": server_version }))
        }
        "snapshot" => to_value(&lock(session)?.view()),
        "sync" => to_value(&engine_result_to_rpc(lock(session)?.sync())?),
        "fileDiff" => {
            let path = get_string_from_params(params, "path")?;
            to_value(&engine_result_to_rpc(lock(session)?.file_diff(path))?)
        }
        "stream" => {
            let mode = get_mode_from_params(params)?;
            to_value(&engine_result_to_rpc(lock(session)?.stream(mode))?)
        }
        "setViewed" => {
            let (path, viewed) = (
                get_string_from_params(params, "path")?,
                get_bool_from_params(params, "viewed")?,
            );
            to_value(&engine_result_to_rpc(
                lock(session)?.set_viewed(path, viewed),
            )?)
        }
        "shutdown" => Ok(Value::Null),
        other => comments::handle_comment_method(session, other, params),
    }
}

/// An engine failure as an RPC error, with its whole context chain.
pub fn engine_result_to_rpc<T>(result: anyhow::Result<T>) -> Result<T, RpcError> {
    result.map_err(|error| RpcError::new(RpcError::ENGINE_ERROR, format!("{error:#}")))
}

/// Serves requests read from `reader` until it ends or a `shutdown` request
/// arrives, writing responses and `event` notifications to `writer`.
///
/// Every event is written before the response to the request that caused it,
/// and before the `shutdown` response.
pub fn serve<R: BufRead, W: Write + Send + 'static>(
    reader: R,
    writer: &Arc<Mutex<W>>,
    session: &Arc<Mutex<ReviewSession>>,
    options: &ServeOptions,
) -> Result<()> {
    let events = Arc::new(Mutex::new(
        session
            .lock()
            .map_err(|_| anyhow!("the review session lock is poisoned"))?
            .subscribe(),
    ));
    let (stop, stopped) = mpsc::channel::<()>();
    let poller = options.poll_every.map(|poll_every| {
        let shared = (Arc::clone(session), Arc::clone(&events), Arc::clone(writer));
        spawn_poller(
            shared,
            stopped,
            poll_every,
            get_wake_interval_from_poll_and_retry(poll_every, options.retry_every),
        )
    });
    let answered = answer_requests(reader, writer, session, &events, options);
    // The poller stops before the last drain, so no sync can announce
    // anything after it. The join waits for at most one in-flight sync and
    // the write of its events.
    drop(stop);
    if let Some(poller) = poller {
        // A poller that panicked has nothing left to stop.
        let _ = poller.join();
    }
    let shutdown = answered?;
    write_events(&events, writer)?;
    if let Some(reply) = shutdown {
        write_line(writer, &reply)?;
    }
    Ok(())
}

/// Answers requests until `reader` ends or a `shutdown` request arrives,
/// returning the `shutdown` response unwritten so events can go first.
fn answer_requests<R: BufRead, W: Write>(
    reader: R,
    writer: &Mutex<W>,
    session: &Mutex<ReviewSession>,
    events: &Mutex<Receiver<Event>>,
    options: &ServeOptions,
) -> Result<Option<Value>> {
    for line in reader.lines() {
        let line = line.context("reading a request")?;
        if line.trim().is_empty() {
            continue;
        }
        let (reply, done) = match parse_request(&line) {
            Ok(request) => {
                let reply = match handle(session, &request, &options.server_version) {
                    Ok(result) => success(&request.id, result),
                    Err(error) => failure(&request.id, &error),
                };
                (reply, request.method == "shutdown")
            }
            Err((id, error)) => (failure(&id, &error), false),
        };
        if done {
            return Ok(Some(reply));
        }
        write_events(events, writer)?;
        write_line(writer, &reply)?;
    }
    Ok(None)
}

/// What the poller shares with the server: the session, its events and the
/// output.
type Shared<W> = (
    Arc<Mutex<ReviewSession>>,
    Arc<Mutex<Receiver<Event>>>,
    Arc<Mutex<W>>,
);

/// Wakes every `wake_interval` and, as [`get_poll_step_from_elapsed`]
/// decides, syncs (every `poll_every`) or resends the queue, writing what that
/// announced, until `stopped` fires or disconnects, or the output closes.
fn spawn_poller<W: Write + Send + 'static>(
    (session, events, writer): Shared<W>,
    stopped: Receiver<()>,
    poll_every: Duration,
    wake_interval: Duration,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut last_sync = Instant::now();
        // A message or a disconnect both mean stop.
        while stopped.recv_timeout(wake_interval) == Err(RecvTimeoutError::Timeout) {
            if let Ok(mut session) = session.lock() {
                // A failure is announced as an event by the session.
                match get_poll_step_from_elapsed(
                    last_sync.elapsed(),
                    poll_every,
                    session.has_queued(),
                ) {
                    PollStep::Sync => {
                        let _ = session.sync();
                        last_sync = Instant::now();
                    }
                    PollStep::Retry => {
                        let _ = session.flush_queued();
                    }
                    PollStep::Wait => {}
                }
            }
            if write_events(&events, &writer).is_err() {
                break;
            }
        }
    })
}

/// Writes every event announced so far to `writer` as an `event`
/// notification, in the order they were announced.
fn write_events<W: Write>(events: &Mutex<Receiver<Event>>, writer: &Mutex<W>) -> Result<()> {
    // Holding the events lock while writing keeps two drains from
    // interleaving their events.
    let pending = events
        .lock()
        .map_err(|_| anyhow!("the event lock is poisoned"))?;
    for event in pending.try_iter() {
        let Ok(params) = serde_json::to_value(&event) else {
            continue;
        };
        write_line(writer, &notification("event", params))?;
    }
    drop(pending);
    Ok(())
}

/// Writes `message` and its newline in one call, so a message that fails to
/// encode never leaves a partial line on the wire.
fn write_line<W: Write>(writer: &Mutex<W>, message: &Value) -> Result<()> {
    let mut line = serde_json::to_vec(message).context("encoding a message")?;
    line.push(b'\n');
    let mut writer = writer
        .lock()
        .map_err(|_| anyhow!("the output lock is poisoned"))?;
    writer.write_all(&line).context("writing a message")?;
    writer.flush().context("flushing a message")
}

/// Acquires the review session lock or turns poisoning into an RPC error.
pub fn lock(session: &Mutex<ReviewSession>) -> Result<MutexGuard<'_, ReviewSession>, RpcError> {
    session.lock().map_err(|_| {
        RpcError::new(
            RpcError::ENGINE_ERROR,
            "the review session lock is poisoned",
        )
    })
}

/// Serializes a response value or turns serialization failure into an RPC error.
pub fn to_value<T: Serialize>(value: &T) -> Result<Value, RpcError> {
    serde_json::to_value(value).map_err(|error| {
        RpcError::new(
            RpcError::ENGINE_ERROR,
            format!("encoding the result: {error}"),
        )
    })
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
}
