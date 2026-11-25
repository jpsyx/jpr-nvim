use std::env;
use std::fs;
use std::io;
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use review_core::ReviewSession;
use review_core::ports::{Ports, ReviewStore, SystemClock};
use review_forge_github::GhForge;
use review_model::LocalReviewContext;
use review_rpc::ServeOptions;
use review_store_fs::FsStore;
use review_workspace_git::{GitWorkspace, inspect_local_worktree};

/// Seconds between resends of what GitHub refused, while the server polls.
pub const RETRY_SECONDS: u64 = 20;

/// Seconds between worktree file checks for live buffer refresh and re-anchoring.
pub const WATCH_SECONDS: u64 = 2;

const MAX_UNIX_SOCKET_BYTES: usize = 96;

struct TempSocketDirGuard(Option<PathBuf>);

impl Drop for TempSocketDirGuard {
    fn drop(&mut self) {
        if let Some(directory) = self.0.take() {
            let _ = fs::remove_dir_all(directory);
        }
    }
}

/// Chooses the Unix domain socket path for a serving `jpr-review` daemon.
///
/// Uses `<state_dir>/s.sock` when within macOS's 104-byte `SUN_LEN` ceiling,
/// otherwise falls back to a private per-process directory under `temp_dir()`,
/// or `/tmp` if `temp_dir()` itself would exceed the length limit.
#[must_use]
pub fn build_socket_path_from_state_dir(state_dir: &Path, pid: u32) -> PathBuf {
    let candidate = state_dir.join("s.sock");
    if candidate.as_os_str().len() <= MAX_UNIX_SOCKET_BYTES {
        return candidate;
    }
    let hash = fnv1a_hash32(state_dir.as_os_str().as_encoded_bytes());
    let subdir = format!("jpr-{pid}-{hash:08x}");
    let temp_candidate = env::temp_dir().join(&subdir).join("s.sock");
    if temp_candidate.as_os_str().len() <= MAX_UNIX_SOCKET_BYTES {
        temp_candidate
    } else {
        Path::new("/tmp").join(subdir).join("s.sock")
    }
}

fn fnv1a_hash32(bytes: &[u8]) -> u32 {
    let mut hash = 0x811c_9dc5_u32;
    for &byte in bytes {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(0x0100_0193_u32);
    }
    hash
}

/// Runs `jpr-review serve` for pull request `number` of `repo` (owner/name).
///
/// It speaks JSON-RPC on stdin and stdout until the client shuts it down or
/// closes stdin. The Neovim plugin starts one per review tab; `poll` is the
/// seconds between background syncs, 0 for none.
pub fn run(number: u64, repo: &str, poll: u64) -> Result<()> {
    let (owner, name) = super::parse_repo(repo)?;
    let cwd = env::current_dir().context("reading the current directory")?;
    let state_dir = super::state_dir(&owner, &name, number)?;
    let store = FsStore::new_with_root(state_dir.clone(), super::state_root_config()?);
    let store_handle = store.clone();
    let pid = std::process::id();
    let (socket_path, _temp_dir_guard) = prepare_daemon_socket(&state_dir, &store, pid)?;
    let ports = Ports {
        forge: Box::new(GhForge::new(cwd.clone(), Some(repo.to_owned()))),
        store: Box::new(store),
        workspace: Box::new(GitWorkspace::open(&cwd)?),
        clock: Box::new(SystemClock),
    };
    let session = ReviewSession::open(number, ports)?;
    serve_session(
        session,
        &store_handle,
        &state_dir,
        &cwd,
        pid,
        poll,
        socket_path,
    )
}

/// Runs `jpr-review serve --local` for the current worktree without a linked PR.
pub fn run_local(base: Option<&str>, repo: Option<&str>, poll: u64) -> Result<()> {
    if let Some(explicit_repo) = repo {
        let _ = super::parse_repo(explicit_repo)?;
    }
    let cwd = env::current_dir().context("reading the current directory")?;
    let info = inspect_local_worktree(&cwd, base)?;
    let effective_repo = repo
        .map(str::to_owned)
        .or_else(|| super::socket_client::infer_repo_from_git_remote(&info.worktree));
    let state_dir =
        super::local_state_dir(&info.worktree, &info.branch, effective_repo.as_deref())?;
    let store = FsStore::new_with_root(state_dir.clone(), super::state_root_config()?);
    let store_handle = store.clone();
    let pid = std::process::id();
    let (socket_path, _temp_dir_guard) = prepare_daemon_socket(&state_dir, &store, pid)?;
    // Pass ONLY explicit `--repo` to `GhForge` (never `origin`-inferred repo)
    // so mid-session `:Jpr sync` resolves upstream PRs on forks cleanly.
    let ports = Ports {
        forge: Box::new(GhForge::new(info.worktree.clone(), repo.map(str::to_owned))),
        store: Box::new(store),
        workspace: Box::new(GitWorkspace::open(&info.worktree)?),
        clock: Box::new(SystemClock),
    };
    let context = LocalReviewContext {
        branch: info.branch,
        base_ref: info.base_ref,
        base_sha: info.base_sha,
        repo: effective_repo,
    };
    let session = ReviewSession::open_local(context, ports)?;
    serve_session(
        session,
        &store_handle,
        &state_dir,
        &info.worktree,
        pid,
        poll,
        socket_path,
    )
}

fn serve_session(
    mut session: ReviewSession,
    store_handle: &FsStore,
    initial_state_dir: &Path,
    worktree_root: &Path,
    pid: u32,
    poll: u64,
    socket_path: Option<PathBuf>,
) -> Result<()> {
    let socket_text = socket_path
        .as_ref()
        .map(|path| path.to_string_lossy().into_owned());
    session.record_daemon_with_socket(
        pid,
        &worktree_root.to_string_lossy(),
        socket_text.as_deref(),
    )?;
    let shared_session = Arc::new(Mutex::new(session));
    let options = create_serve_options(poll, socket_path);
    let result = review_rpc::serve(
        io::stdin().lock(),
        &Arc::new(Mutex::new(io::stdout())),
        &shared_session,
        &options,
    );
    let active_dir = store_handle.current_dir();
    if result.is_ok() {
        clear_owned_socket_record(
            &active_dir,
            &shared_session,
            pid,
            worktree_root,
            socket_text.as_deref(),
        );
    }
    if active_dir != initial_state_dir {
        let _ = fs::remove_dir(initial_state_dir);
    }
    result
}

fn clear_owned_socket_record(
    state_dir: &Path,
    shared_session: &Arc<Mutex<ReviewSession>>,
    pid: u32,
    cwd: &Path,
    socket_text: Option<&str>,
) {
    let Some(recorded_socket) = socket_text else {
        return;
    };
    let Ok(fresh) = FsStore::new(state_dir.to_path_buf()).load() else {
        return;
    };
    if fresh.session.pid == Some(pid)
        && fresh.session.socket.as_deref() == Some(recorded_socket)
        && let Ok(mut guard) = shared_session.lock()
    {
        let _ = guard.record_daemon_with_socket(pid, &cwd.to_string_lossy(), None);
    }
}

fn create_serve_options(poll: u64, socket_path: Option<PathBuf>) -> ServeOptions {
    ServeOptions {
        server_version: env!("CARGO_PKG_VERSION").to_owned(),
        poll_every: poll_interval(poll),
        retry_every: poll_interval(poll).map(|_| Duration::from_secs(RETRY_SECONDS)),
        socket_path,
        watch_every: Some(Duration::from_secs(WATCH_SECONDS)),
    }
}

#[cfg(unix)]
fn prepare_daemon_socket(
    state_dir: &Path,
    store: &FsStore,
    pid: u32,
) -> Result<(Option<PathBuf>, TempSocketDirGuard)> {
    let socket_path = build_socket_path_from_state_dir(state_dir, pid);
    ensure_no_live_daemon(store, &socket_path)?;
    let guard = create_temp_socket_directory(state_dir, &socket_path)?;
    Ok((Some(socket_path), guard))
}

#[cfg(not(unix))]
fn prepare_daemon_socket(
    _state_dir: &Path,
    _store: &FsStore,
    _pid: u32,
) -> Result<(Option<PathBuf>, TempSocketDirGuard)> {
    Ok((None, TempSocketDirGuard(None)))
}

#[cfg(unix)]
fn ensure_no_live_daemon(store: &FsStore, candidate: &Path) -> Result<()> {
    if let Ok(snapshot) = store.load()
        && let Some(recorded) = snapshot
            .session
            .socket
            .as_deref()
            .filter(|text| !text.trim().is_empty())
    {
        let recorded_path = Path::new(recorded);
        if UnixStream::connect(recorded_path).is_ok() {
            bail!(
                "another jpr-review daemon is already serving at {}",
                recorded_path.display()
            );
        }
    }
    if UnixStream::connect(candidate).is_ok() {
        bail!(
            "another jpr-review daemon is already serving at {}",
            candidate.display()
        );
    }
    Ok(())
}

#[cfg(unix)]
fn create_temp_socket_directory(
    state_dir: &Path,
    socket_path: &Path,
) -> Result<TempSocketDirGuard> {
    use std::os::unix::fs::DirBuilderExt;

    let Some(parent) = socket_path.parent().map(Path::to_path_buf) else {
        return Ok(TempSocketDirGuard(None));
    };
    if parent.as_path() == state_dir {
        return Ok(TempSocketDirGuard(None));
    }
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&parent)
        .with_context(|| format!("creating private socket directory {}", parent.display()))?;
    Ok(TempSocketDirGuard(Some(parent)))
}

/// `--poll` seconds as an interval; 0 turns background syncing off.
#[must_use]
pub const fn poll_interval(seconds: u64) -> Option<Duration> {
    if seconds == 0 {
        None
    } else {
        Some(Duration::from_secs(seconds))
    }
}

#[cfg(test)]
mod tests;
