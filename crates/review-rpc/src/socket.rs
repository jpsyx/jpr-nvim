//! Unix domain socket server for local CLI clients (`jpr-review reply`, etc.).

mod io;

use std::fs::{self, DirBuilder, Permissions};
use std::io::{ErrorKind, Write};
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use serde_json::Value;

use crate::protocol::{RpcError, failure, parse_request, success};
use crate::server::{Shared, handle, write_events};
use io::{CLIENT_LINE_TIMEOUT, LineRead, read_bounded_line, write_socket_reply};

const ACCEPT_POLL_INTERVAL: Duration = Duration::from_millis(25);
const CLIENT_IO_POLL: Duration = Duration::from_millis(50);
const MAX_CONCURRENT_CLIENTS: usize = 64;
const MAX_CONSECUTIVE_BLANK_LINES: usize = 16;

struct SocketGuard {
    path: PathBuf,
}

impl Drop for SocketGuard {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_file(&self.path)
            && error.kind() != ErrorKind::NotFound
        {
            let _ = error;
        }
    }
}

/// Background Unix domain socket listener that forwards allowlisted CLI RPC
/// requests to the active review session and cleans up the socket file on drop.
pub struct SocketServer {
    stopped: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
    _guard: SocketGuard,
}

impl SocketServer {
    /// Binds `socket_path` with `0o600` permissions and starts accepting CLI
    /// client connections until stopped.
    pub fn start<W: Write + Send + 'static>(
        socket_path: &Path,
        shared: Shared<W>,
        server_version: String,
    ) -> Result<Self> {
        prepare_socket_path(socket_path)?;
        let listener = UnixListener::bind(socket_path)
            .with_context(|| format!("binding Unix socket {}", socket_path.display()))?;
        let guard = SocketGuard {
            path: socket_path.to_path_buf(),
        };
        fs::set_permissions(socket_path, Permissions::from_mode(0o600))
            .with_context(|| format!("setting permissions on {}", socket_path.display()))?;
        listener
            .set_nonblocking(true)
            .context("setting Unix socket listener nonblocking")?;
        let stopped = Arc::new(AtomicBool::new(false));
        let stopped_clone = Arc::clone(&stopped);
        let handle = thread::Builder::new()
            .name("jpr-socket-accept".into())
            .spawn(move || {
                run_accept_loop(&listener, &stopped_clone, &shared, &server_version);
            })
            .context("spawning Unix socket accept thread")?;
        Ok(Self {
            stopped,
            handle: Some(handle),
            _guard: guard,
        })
    }

    /// Signals the accept loop to stop, joins active client handlers, and
    /// unlinks the socket file.
    pub fn stop_and_join(mut self) {
        self.stop_inner();
    }

    fn stop_inner(&mut self) {
        self.stopped.store(true, Ordering::Release);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for SocketServer {
    fn drop(&mut self) {
        self.stop_inner();
    }
}

/// Returns whether `method` is safe to invoke over the Unix domain socket.
#[must_use]
pub fn is_socket_method_allowed(method: &str) -> bool {
    matches!(
        method,
        "snapshot" | "threads" | "agentReply" | "prepassWrite"
    )
}

fn prepare_socket_path(socket_path: &Path) -> Result<()> {
    if let Some(parent) = socket_path.parent()
        && !parent.as_os_str().is_empty()
    {
        ensure_private_socket_parent(parent)?;
    }
    match fs::symlink_metadata(socket_path) {
        Ok(metadata) => remove_stale_socket(socket_path, &metadata),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => {
            Err(error).with_context(|| format!("inspecting socket path {}", socket_path.display()))
        }
    }
}

fn ensure_private_socket_parent(parent: &Path) -> Result<()> {
    match fs::symlink_metadata(parent) {
        Err(error) if error.kind() == ErrorKind::NotFound => {
            DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)
                .with_context(|| {
                    format!("creating socket parent directory {}", parent.display())
                })?;
            fs::set_permissions(parent, Permissions::from_mode(0o700))
                .with_context(|| format!("setting permissions on {}", parent.display()))
        }
        Ok(metadata) => {
            if metadata.file_type().is_dir()
                && !is_shared_parent_directory(parent, &metadata)
                && (metadata.permissions().mode() & 0o077) != 0
            {
                fs::set_permissions(parent, Permissions::from_mode(0o700))
                    .with_context(|| format!("setting permissions on {}", parent.display()))?;
            }
            Ok(())
        }
        Err(error) => Err(error)
            .with_context(|| format!("inspecting socket parent directory {}", parent.display())),
    }
}

fn is_shared_parent_directory(parent: &Path, metadata: &fs::Metadata) -> bool {
    if (metadata.permissions().mode() & 0o1000) != 0 {
        return true;
    }
    if parent == Path::new("/tmp")
        || parent == Path::new("/var/tmp")
        || parent == std::env::temp_dir().as_path()
    {
        return true;
    }
    ["HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR"]
        .into_iter()
        .filter_map(std::env::var_os)
        .any(|value| Path::new(&value) == parent)
}

fn remove_stale_socket(socket_path: &Path, metadata: &fs::Metadata) -> Result<()> {
    if !metadata.file_type().is_socket() {
        bail!(
            "refusing to overwrite non-socket at {}",
            socket_path.display()
        );
    }
    match UnixStream::connect(socket_path) {
        Ok(_) => bail!("socket {} is already active", socket_path.display()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) if error.kind() == ErrorKind::ConnectionRefused => {
            match fs::remove_file(socket_path) {
                Ok(()) => Ok(()),
                Err(remove_error) if remove_error.kind() == ErrorKind::NotFound => Ok(()),
                Err(remove_error) => Err(remove_error)
                    .with_context(|| format!("removing stale socket {}", socket_path.display())),
            }
        }
        Err(error) => bail!("probing socket {}: {error}", socket_path.display()),
    }
}

fn run_accept_loop<W: Write + Send + 'static>(
    listener: &UnixListener,
    stopped: &Arc<AtomicBool>,
    shared: &Shared<W>,
    server_version: &str,
) {
    let mut clients: Vec<JoinHandle<()>> = Vec::new();
    while !stopped.load(Ordering::Acquire) {
        clients.retain(|client| !client.is_finished());
        match listener.accept() {
            Ok((stream, _)) if clients.len() < MAX_CONCURRENT_CLIENTS => {
                let client_shared = (
                    Arc::clone(&shared.0),
                    Arc::clone(&shared.1),
                    Arc::clone(&shared.2),
                );
                let client_stopped = Arc::clone(stopped);
                let client_version = server_version.to_owned();
                match thread::Builder::new()
                    .name("jpr-socket-client".into())
                    .spawn(move || {
                        handle_socket_client(
                            stream,
                            &client_stopped,
                            &client_shared,
                            &client_version,
                        );
                    }) {
                    Ok(handle) => clients.push(handle),
                    Err(_) => thread::sleep(ACCEPT_POLL_INTERVAL),
                }
            }
            Ok((stream, _)) => drop(stream),
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(_) => thread::sleep(ACCEPT_POLL_INTERVAL),
        }
    }
    for client in clients {
        let _ = client.join();
    }
}

fn handle_socket_client<W: Write>(
    mut stream: UnixStream,
    stopped: &AtomicBool,
    shared: &Shared<W>,
    server_version: &str,
) {
    if stream.set_nonblocking(false).is_err()
        || stream.set_read_timeout(Some(CLIENT_IO_POLL)).is_err()
        || stream.set_write_timeout(Some(CLIENT_IO_POLL)).is_err()
    {
        return;
    }
    let mut buffer = Vec::new();
    let mut consecutive_blanks = 0_usize;
    let mut last_request = Instant::now();
    loop {
        match read_bounded_line(&mut stream, &mut buffer, stopped) {
            Ok(LineRead::Line(line)) if line.trim().is_empty() => {
                consecutive_blanks += 1;
                if consecutive_blanks >= MAX_CONSECUTIVE_BLANK_LINES
                    || last_request.elapsed() >= CLIENT_LINE_TIMEOUT
                {
                    break;
                }
            }
            Ok(LineRead::Line(line)) => {
                consecutive_blanks = 0;
                last_request = Instant::now();
                let reply = process_socket_line(&line, shared, server_version);
                if write_socket_reply(&mut stream, &reply, stopped).is_err() {
                    break;
                }
            }
            Ok(outcome @ (LineRead::TooLong | LineRead::InvalidUtf8)) => {
                write_socket_error(&mut stream, matches!(outcome, LineRead::TooLong), stopped);
                break;
            }
            Ok(LineRead::Eof | LineRead::Stopped | LineRead::TimedOut) | Err(_) => break,
        }
    }
}

fn write_socket_error(stream: &mut UnixStream, is_too_long: bool, stopped: &AtomicBool) {
    let error = if is_too_long {
        RpcError::new(
            RpcError::INVALID_REQUEST,
            "request exceeds maximum line length",
        )
    } else {
        RpcError::new(RpcError::PARSE_ERROR, "request is not valid UTF-8")
    };
    let _ = write_socket_reply(stream, &failure(&Value::Null, &error), stopped);
}

fn process_socket_line<W: Write>(
    line: &str,
    (session, events, writer): &Shared<W>,
    server_version: &str,
) -> Value {
    match parse_request(line) {
        Ok(request) if !is_socket_method_allowed(&request.method) => failure(
            &request.id,
            &RpcError::new(
                RpcError::INVALID_REQUEST,
                format!(
                    "method {:?} is not allowed on the Unix socket",
                    request.method
                ),
            ),
        ),
        Ok(request) => {
            let reply = match handle(session, &request, server_version) {
                Ok(result) => success(&request.id, result),
                Err(error) => failure(&request.id, &error),
            };
            // Flush session events to Neovim stdio before answering the socket
            // caller; ignore broken stdio during shutdown races.
            let _ = write_events(events, writer);
            reply
        }
        Err((id, error)) => failure(&id, &error),
    }
}

#[cfg(test)]
mod tests;
