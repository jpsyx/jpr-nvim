//! Serving a `ReviewSession` over any line-based transport, such as stdio.
//! Responses and event notifications share one writer, one JSON message per
//! line.

mod agent;
mod comments;
mod ticker;

use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use review_core::ReviewSession;
use review_model::Event;
use serde::Serialize;
use serde_json::{Value, json};

use crate::params::{
    get_bool_from_params, get_mode_from_params, get_renames_from_params, get_string_from_params,
    get_viewed_paths_from_params,
};
use crate::protocol::{
    PROTOCOL_VERSION, Request, RpcError, failure, notification, parse_request, success,
};
#[cfg(unix)]
use crate::socket::SocketServer;

pub use ticker::{
    PollStep, get_poll_step_from_elapsed, get_wake_interval_from_intervals,
    get_wake_interval_from_poll_and_retry,
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
    /// Optional Unix domain socket path for CLI clients (`jpr-review reply`, etc.).
    pub socket_path: Option<PathBuf>,
    /// Optional interval for checking worktree file changes on disk.
    pub watch_every: Option<Duration>,
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
        "push" => to_value(&engine_result_to_rpc(lock(session)?.push())?),
        "fileDiff" => {
            let path = get_string_from_params(params, "path")?;
            to_value(&engine_result_to_rpc(lock(session)?.file_diff(path))?)
        }
        "stream" => {
            let mode = get_mode_from_params(params)?;
            to_value(&engine_result_to_rpc(lock(session)?.stream(mode))?)
        }
        "setViewed" => {
            let paths = get_viewed_paths_from_params(params)?;
            let viewed = get_bool_from_params(params, "viewed")?;
            to_value(&engine_result_to_rpc(
                lock(session)?.set_viewed_paths(&paths, viewed),
            )?)
        }
        "setCollapsed" => {
            let path = get_string_from_params(params, "path")?;
            let collapsed = get_bool_from_params(params, "collapsed")?;
            if let Err(error) = review_core::reanchor::validate_safe_relative_path(path) {
                return Err(RpcError::new(RpcError::INVALID_PARAMS, error.to_string()));
            }
            to_value(&engine_result_to_rpc(
                lock(session)?.set_collapsed(path, collapsed),
            )?)
        }
        "refreshWorktree" => {
            let renames = get_renames_from_params(params)?;
            to_value(&engine_result_to_rpc(
                lock(session)?.refresh_worktree(&renames),
            )?)
        }
        "shutdown" => Ok(Value::Null),
        other => comments::handle_comment_method(session, other, params),
    }
}

/// An engine failure as an RPC error, with its whole context chain.
pub fn engine_result_to_rpc<T>(result: anyhow::Result<T>) -> Result<T, RpcError> {
    result.map_err(|error| {
        let code = if review_core::is_auth_error(&error) {
            RpcError::AUTH_REQUIRED
        } else {
            RpcError::ENGINE_ERROR
        };
        RpcError::new(code, format!("{error:#}"))
    })
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
    if ticker::has_enabled_watch(options) {
        let _ = lock(session).map(|mut guard| guard.poll_worktree_files());
    }
    let socket_server = start_socket_server(options, session, &events, writer)?;
    let (stop, stopped) = mpsc::channel::<()>();
    let shared = (Arc::clone(session), Arc::clone(&events), Arc::clone(writer));
    let ticker_handle = ticker::start_ticker(options, stopped, shared);
    let answered = answer_requests(reader, writer, session, &events, options);
    drop(stop);
    if let Some(handle) = ticker_handle {
        let _ = handle.join();
    }
    stop_socket_server(socket_server);
    let shutdown = answered?;
    write_events(&events, writer)?;
    if let Some(reply) = shutdown {
        write_line(writer, &reply)?;
    }
    Ok(())
}

#[cfg(unix)]
fn start_socket_server<W: Write + Send + 'static>(
    options: &ServeOptions,
    session: &Arc<Mutex<ReviewSession>>,
    events: &Arc<Mutex<Receiver<Event>>>,
    writer: &Arc<Mutex<W>>,
) -> Result<Option<SocketServer>> {
    options
        .socket_path
        .as_deref()
        .map(|socket_path| {
            SocketServer::start(
                socket_path,
                (Arc::clone(session), Arc::clone(events), Arc::clone(writer)),
                options.server_version.clone(),
            )
        })
        .transpose()
}

#[cfg(not(unix))]
fn start_socket_server<W: Write + Send + 'static>(
    options: &ServeOptions,
    _session: &Arc<Mutex<ReviewSession>>,
    _events: &Arc<Mutex<Receiver<Event>>>,
    _writer: &Arc<Mutex<W>>,
) -> Result<Option<()>> {
    if options.socket_path.is_some() {
        anyhow::bail!("Unix domain sockets are not supported on this platform");
    }
    Ok(None)
}

#[cfg(unix)]
fn stop_socket_server(server: Option<SocketServer>) {
    if let Some(socket_server) = server {
        socket_server.stop_and_join();
    }
}

#[cfg(not(unix))]
fn stop_socket_server(_server: Option<()>) {}

/// Handles a `stream` request while emitting `streamProgress` notifications
/// immediately as each file completes.
fn handle_stream_with_progress<W: Write>(
    session: &Mutex<ReviewSession>,
    params: &Value,
    writer: &Mutex<W>,
) -> Result<Result<Value, RpcError>> {
    let mode = match get_mode_from_params(params) {
        Ok(mode) => mode,
        Err(error) => return Ok(Err(error)),
    };
    let mut guard = match lock(session) {
        Ok(guard) => guard,
        Err(error) => return Ok(Err(error)),
    };
    let mut write_error: Option<anyhow::Error> = None;
    let stream_result = guard.stream_with_progress(mode, |completed, total, path| {
        if write_error.is_some() {
            return;
        }
        let progress = notification(
            "streamProgress",
            json!({ "completed": completed, "total": total, "path": path }),
        );
        if let Err(error) = write_line(writer, &progress) {
            write_error = Some(error);
        }
    });
    drop(guard);
    if let Some(error) = write_error {
        return Err(error);
    }
    Ok(engine_result_to_rpc(stream_result).and_then(|stream| to_value(&stream)))
}

/// Parses and executes one request line, returning its JSON-RPC reply and
/// whether the request was `shutdown`.
fn answer_single_request<W: Write>(
    line: &str,
    writer: &Mutex<W>,
    session: &Mutex<ReviewSession>,
    server_version: &str,
) -> Result<(Value, bool)> {
    match parse_request(line) {
        Ok(request) => {
            let result = if request.method == "stream" {
                handle_stream_with_progress(session, &request.params, writer)?
            } else {
                handle(session, &request, server_version)
            };
            let reply = match result {
                Ok(value) => success(&request.id, value),
                Err(error) => failure(&request.id, &error),
            };
            Ok((reply, request.method == "shutdown"))
        }
        Err((id, error)) => Ok((failure(&id, &error), false)),
    }
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
        let (reply, is_shutdown) =
            answer_single_request(&line, writer, session, &options.server_version)?;
        if is_shutdown {
            return Ok(Some(reply));
        }
        write_events(events, writer)?;
        write_line(writer, &reply)?;
    }
    Ok(None)
}

/// What the poller and socket server share with the server: the session, its
/// events, and the primary output.
pub type Shared<W> = (
    Arc<Mutex<ReviewSession>>,
    Arc<Mutex<Receiver<Event>>>,
    Arc<Mutex<W>>,
);

/// Writes every event announced so far to `writer` as an `event`
/// notification, in the order they were announced.
pub fn write_events<W: Write>(events: &Mutex<Receiver<Event>>, writer: &Mutex<W>) -> Result<()> {
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

/// Acquires the review session guard or returns `RpcError::ENGINE_ERROR` if
/// the mutex is poisoned, for example when servicing session and comment RPC
/// handlers.
pub fn lock(session: &Mutex<ReviewSession>) -> Result<MutexGuard<'_, ReviewSession>, RpcError> {
    session.lock().map_err(|_| {
        RpcError::new(
            RpcError::ENGINE_ERROR,
            "the review session lock is poisoned",
        )
    })
}

/// Encodes `value` into a JSON [`Value`] or returns `RpcError::ENGINE_ERROR` on
/// serialization failure, for example when building JSON-RPC responses in
/// `server` and `server::comments`.
pub fn to_value<T: Serialize>(value: &T) -> Result<Value, RpcError> {
    serde_json::to_value(value).map_err(|error| {
        RpcError::new(
            RpcError::ENGINE_ERROR,
            format!("encoding the result: {error}"),
        )
    })
}

#[cfg(test)]
mod auth_rpc_tests {
    use super::*;

    #[test]
    fn engine_result_to_rpc_maps_forge_auth_error_to_auth_required_code() {
        let auth_error: anyhow::Result<()> = Err(anyhow::Error::new(
            review_core::ForgeAuthError::new("gh auth login"),
        )
        .context("syncing pr"));
        let rpc_error = engine_result_to_rpc(auth_error).unwrap_err();
        assert_eq!(rpc_error.code, RpcError::AUTH_REQUIRED);
        assert_eq!(rpc_error.code, -32001);

        let generic_error: anyhow::Result<()> = Err(anyhow!("offline"));
        let generic_rpc = engine_result_to_rpc(generic_error).unwrap_err();
        assert_eq!(generic_rpc.code, RpcError::ENGINE_ERROR);
    }
}
