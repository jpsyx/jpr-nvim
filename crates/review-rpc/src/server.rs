//! Serving a `ReviewSession` over any line-based transport: stdio today, a
//! Unix socket for agent commands later. Responses and event notifications
//! share one writer, one JSON message per line.

use std::io::{BufRead, Write};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use review_core::ReviewSession;
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
pub fn serve<R: BufRead, W: Write + Send + 'static>(
    reader: R,
    writer: &Arc<Mutex<W>>,
    session: &Arc<Mutex<ReviewSession>>,
    options: &ServeOptions,
) -> Result<()> {
    forward_events(session, Arc::clone(writer))?;
    // Dropping `stop`, on any return, ends the poller.
    let (stop, stopped) = mpsc::channel::<()>();
    if let Some(every) = options.poll_every {
        spawn_poller(Arc::clone(session), stopped, every);
    }
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
        write_line(writer, &reply)?;
        if done {
            break;
        }
    }
    drop(stop);
    Ok(())
}

/// Syncs `session` every `every` until `stopped` fires or disconnects.
fn spawn_poller(session: Arc<Mutex<ReviewSession>>, stopped: Receiver<()>, every: Duration) {
    thread::spawn(move || {
        // A message or a disconnect both mean stop.
        while stopped.recv_timeout(every) == Err(RecvTimeoutError::Timeout) {
            // A failure is announced as an event by the session.
            if let Ok(mut session) = session.lock() {
                let _ = session.sync();
            }
        }
    });
}

/// Writes every session event to `writer` as an `event` notification.
fn forward_events<W: Write + Send + 'static>(
    session: &Mutex<ReviewSession>,
    writer: Arc<Mutex<W>>,
) -> Result<()> {
    let events = session
        .lock()
        .map_err(|_| anyhow!("the review session lock is poisoned"))?
        .subscribe();
    thread::spawn(move || {
        for event in events {
            let Ok(params) = serde_json::to_value(&event) else {
                continue;
            };
            if write_line(&writer, &notification("event", params)).is_err() {
                break;
            }
        }
    });
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
