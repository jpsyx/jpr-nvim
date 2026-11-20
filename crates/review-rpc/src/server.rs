//! Serving a `ReviewSession` over any line-based transport: stdio today, a
//! Unix socket for agent commands later. Responses and event notifications
//! share one writer, one JSON message per line.

use std::io::{BufRead, Write};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use review_core::ReviewSession;
use review_model::Event;
use serde::Serialize;
use serde_json::{Value, json};

use crate::protocol::{
    PROTOCOL_VERSION, Request, RpcError, failure, notification, parse_request, success,
};

/// How a server runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServeOptions {
    /// The engine's version, reported by `initialize`.
    pub server_version: String,
    /// How often to sync in the background; `None` syncs only on request.
    pub poll_every: Option<Duration>,
}

/// Answers one request. Routing only: every rule lives in the session.
pub fn handle(
    session: &Mutex<ReviewSession>,
    request: &Request,
    server_version: &str,
) -> Result<Value, RpcError> {
    match request.method.as_str() {
        "initialize" => {
            Ok(json!({ "protocolVersion": PROTOCOL_VERSION, "version": server_version }))
        }
        "snapshot" => to_value(&lock(session)?.view()),
        "sync" => {
            let view = lock(session)?
                .sync()
                .map_err(|error| RpcError::new(RpcError::ENGINE_ERROR, format!("{error:#}")))?;
            to_value(&view)
        }
        "shutdown" => Ok(Value::Null),
        other => Err(RpcError::new(
            RpcError::METHOD_NOT_FOUND,
            format!("unknown method {other:?}"),
        )),
    }
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
    let poller = options.poll_every.map(|every| {
        let shared = (Arc::clone(session), Arc::clone(&events), Arc::clone(writer));
        spawn_poller(shared, stopped, every)
    });
    let answered = answer_requests(reader, writer, session, &events, options);
    // The poller stops before the last drain, so no sync can announce
    // anything after it, and a closed output ends the poller instead of
    // blocking this join.
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

/// Syncs every `every` and writes what the sync announced, until `stopped`
/// fires or disconnects, or the output closes.
fn spawn_poller<W: Write + Send + 'static>(
    (session, events, writer): Shared<W>,
    stopped: Receiver<()>,
    every: Duration,
) -> JoinHandle<()> {
    thread::spawn(move || {
        // A message or a disconnect both mean stop.
        while stopped.recv_timeout(every) == Err(RecvTimeoutError::Timeout) {
            // A failure is announced as an event by the session.
            if let Ok(mut session) = session.lock() {
                let _ = session.sync();
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

fn lock(session: &Mutex<ReviewSession>) -> Result<MutexGuard<'_, ReviewSession>, RpcError> {
    session.lock().map_err(|_| {
        RpcError::new(
            RpcError::ENGINE_ERROR,
            "the review session lock is poisoned",
        )
    })
}

fn to_value<T: Serialize>(value: &T) -> Result<Value, RpcError> {
    serde_json::to_value(value).map_err(|error| {
        RpcError::new(
            RpcError::ENGINE_ERROR,
            format!("encoding the result: {error}"),
        )
    })
}
