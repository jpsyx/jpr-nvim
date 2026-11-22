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
mod tests {
    use std::os::unix::fs::symlink;
    use std::sync::Mutex;
    use std::sync::atomic::AtomicU64;

    use review_core::ReviewSession;
    use review_core::fakes::sample_pr;
    use review_core::fakes::{
        FakeForge, FakeWorkspace, FixedClock, MemoryStore, create_fake_ports,
    };
    use review_core::ports::ForgeSnapshot;

    use super::*;

    static NEXT_UNIT_SOCK: AtomicU64 = AtomicU64::new(1);

    struct TempDirGuard(PathBuf);

    impl Drop for TempDirGuard {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn create_unit_temp_directory(label: &str) -> TempDirGuard {
        let sequence = NEXT_UNIT_SOCK.fetch_add(1, Ordering::Relaxed);
        TempDirGuard(PathBuf::from(format!(
            "/tmp/jpr-sock-{label}-{}-{sequence}",
            std::process::id()
        )))
    }

    fn create_test_shared() -> Shared<Vec<u8>> {
        let forge = FakeForge::new(sample_pr(), ForgeSnapshot::default());
        let ports = create_fake_ports(
            &forge,
            &MemoryStore::default(),
            &FakeWorkspace::default(),
            &FixedClock::at(100),
        );
        let mut session = ReviewSession::open(7, ports).unwrap();
        let events = Arc::new(Mutex::new(session.subscribe()));
        (
            Arc::new(Mutex::new(session)),
            events,
            Arc::new(Mutex::new(Vec::<u8>::new())),
        )
    }

    #[test]
    fn allowlist_permits_only_expected_socket_methods() {
        for allowed in ["snapshot", "threads", "agentReply", "prepassWrite"] {
            assert!(is_socket_method_allowed(allowed), "{allowed}");
        }
        for refused in [
            "initialize",
            "shutdown",
            "submitReview",
            "comment",
            "promoteThread",
            "sync",
            "push",
            "prepareConflictResolution",
            "setViewed",
            "reply",
            "editMessage",
            "deleteMessage",
            "setResolved",
            "toggleReaction",
        ] {
            assert!(!is_socket_method_allowed(refused), "{refused}");
        }
    }

    #[test]
    fn prepare_socket_path_refuses_regular_file_symlink_and_active_socket() {
        let temp_directory = create_unit_temp_directory("prep");
        fs::create_dir_all(&temp_directory.0).unwrap();
        let file_path = temp_directory.0.join("regular");
        fs::write(&file_path, b"keep").unwrap();
        assert!(prepare_socket_path(&file_path).is_err());
        assert_eq!(fs::read(&file_path).unwrap(), b"keep");

        let link_path = temp_directory.0.join("link");
        symlink(&file_path, &link_path).unwrap();
        assert!(prepare_socket_path(&link_path).is_err());
        assert!(fs::symlink_metadata(&link_path).is_ok());

        let live_path = temp_directory.0.join("live.sock");
        let _listener = UnixListener::bind(&live_path).unwrap();
        assert!(prepare_socket_path(&live_path).is_err());

        let stale_path = temp_directory.0.join("stale.sock");
        drop(UnixListener::bind(&stale_path).unwrap());
        prepare_socket_path(&stale_path).unwrap();
        assert!(!stale_path.exists());
    }

    #[test]
    fn socket_server_sets_0700_dir_and_0600_socket_permissions() {
        let temp_directory = create_unit_temp_directory("perms");
        let socket_path = temp_directory.0.join("sub").join("jpr.sock");
        let server =
            SocketServer::start(&socket_path, create_test_shared(), "1.0.0".into()).unwrap();
        let directory_mode = fs::metadata(socket_path.parent().unwrap())
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        let socket_mode = fs::metadata(&socket_path).unwrap().permissions().mode() & 0o777;
        assert_eq!(directory_mode, 0o700);
        assert_eq!(socket_mode, 0o600);
        server.stop_and_join();
        assert!(!socket_path.exists());
    }

    #[test]
    fn socket_server_tightens_existing_parent_dir_without_touching_symlinks() {
        let temp_directory = create_unit_temp_directory("existing");
        let existing_sub = temp_directory.0.join("existing");
        fs::create_dir_all(&existing_sub).unwrap();
        fs::set_permissions(&existing_sub, Permissions::from_mode(0o755)).unwrap();

        let socket_path = existing_sub.join("jpr.sock");
        let server =
            SocketServer::start(&socket_path, create_test_shared(), "1.0.0".into()).unwrap();
        let mode = fs::metadata(&existing_sub).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o700);
        server.stop_and_join();

        let link_target = temp_directory.0.join("target");
        fs::create_dir_all(&link_target).unwrap();
        fs::set_permissions(&link_target, Permissions::from_mode(0o755)).unwrap();
        let link_parent = temp_directory.0.join("link_parent");
        symlink(&link_target, &link_parent).unwrap();
        let linked_sock = link_parent.join("jpr.sock");
        prepare_socket_path(&linked_sock).unwrap();
        let target_mode = fs::metadata(&link_target).unwrap().permissions().mode() & 0o777;
        assert_eq!(target_mode, 0o755);
    }

    #[test]
    fn blank_line_spam_disconnects_client_without_eof() {
        let stopped = AtomicBool::new(false);
        let (mut client, server_stream) = UnixStream::pair().unwrap();
        let blanks = "\n".repeat(MAX_CONSECUTIVE_BLANK_LINES);
        client.write_all(blanks.as_bytes()).unwrap();
        client.flush().unwrap();

        let started = Instant::now();
        handle_socket_client(server_stream, &stopped, &create_test_shared(), "1.0.0");
        assert!(started.elapsed() < Duration::from_secs(1));
        drop(client);
    }
}
