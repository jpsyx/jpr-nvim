//! Unix domain socket client, target fallback resolution, and UTC timestamp formatting.

use std::env;
#[cfg(unix)]
use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
#[cfg(unix)]
use std::time::Duration;

use anyhow::{Context, Result, bail};
use review_core::ports::ReviewStore;
use review_store_fs::FsStore;
use serde_json::Value;
#[cfg(unix)]
use serde_json::json;

use crate::theme::Theme;

#[cfg(unix)]
const SOCKET_IO_TIMEOUT: Duration = Duration::from_secs(5);
#[cfg(unix)]
const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
const GIT_ENV_VARS: [&str; 8] = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_SHALLOW_FILE",
    "GIT_PREFIX",
];

/// Socket override source from `--socket` or `$JPR_SOCKET`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SocketOverride<'a> {
    /// Explicit `--socket <PATH>` flag; connection failure must fail loudly.
    Explicit(&'a Path),
    /// Ambient `$JPR_SOCKET` environment variable; falls back when unavailable.
    Env(&'a Path),
}

/// Target PR, repository, and optional daemon socket resolved from flags or env.
#[derive(Debug, Clone, Copy)]
pub struct TargetContext<'a> {
    /// Socket override (`--socket` or `$JPR_SOCKET`), if set.
    pub socket: Option<SocketOverride<'a>>,
    /// Pull request number (`--pr` or `$JPR_PR`), if set.
    pub pr: Option<u64>,
    /// Repository in `owner/name` format (`--repo`), if set.
    pub repo: Option<&'a str>,
    /// Terminal theme used when prompting interactively.
    pub theme: Theme,
}

/// Sends one JSON-RPC 2.0 request to `socket_path`.
///
/// Returns `Ok(None)` when the socket does not exist or refuses connections so
/// callers can fall back to `FsStore`, `Ok(Some(result))` on success, and `Err`
/// when the daemon returns an RPC error or the socket I/O fails.
pub fn call_socket(socket_path: &Path, method: &str, params: &Value) -> Result<Option<Value>> {
    call_socket_platform(socket_path, method, params)
}

#[cfg(unix)]
fn call_socket_platform(socket_path: &Path, method: &str, params: &Value) -> Result<Option<Value>> {
    let mut stream = match UnixStream::connect(socket_path) {
        Ok(stream) => stream,
        Err(error)
            if matches!(
                error.kind(),
                ErrorKind::NotFound | ErrorKind::ConnectionRefused
            ) =>
        {
            return Ok(None);
        }
        Err(error) => {
            return Err(error).with_context(|| format!("connecting to {}", socket_path.display()));
        }
    };
    stream
        .set_read_timeout(Some(SOCKET_IO_TIMEOUT))
        .context("setting socket read timeout")?;
    stream
        .set_write_timeout(Some(SOCKET_IO_TIMEOUT))
        .context("setting socket write timeout")?;
    let mut payload = serde_json::to_vec(&json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    }))
    .context("encoding socket request")?;
    payload.push(b'\n');
    stream
        .write_all(&payload)
        .context("writing socket request")?;
    stream.flush().context("flushing socket request")?;
    read_rpc_reply(stream, socket_path)
}

#[cfg(not(unix))]
fn call_socket_platform(
    _socket_path: &Path,
    _method: &str,
    _params: &Value,
) -> Result<Option<Value>> {
    Ok(None)
}

#[cfg(unix)]
fn read_rpc_reply(stream: UnixStream, socket_path: &Path) -> Result<Option<Value>> {
    let limit = u64::try_from(MAX_RESPONSE_BYTES)
        .unwrap_or(u64::MAX)
        .saturating_add(1);
    let mut reader = BufReader::new(stream.take(limit));
    let mut bytes = Vec::new();
    let bytes_read = reader
        .read_until(b'\n', &mut bytes)
        .with_context(|| format!("reading reply from {}", socket_path.display()))?;
    if bytes_read == 0 {
        bail!("daemon closed {} without replying", socket_path.display());
    }
    if bytes.len() > MAX_RESPONSE_BYTES {
        bail!("reply from {} exceeded size limit", socket_path.display());
    }
    let line = std::str::from_utf8(&bytes)
        .with_context(|| format!("decoding reply from {}", socket_path.display()))?;
    let response: Value = serde_json::from_str(line.trim_end())
        .with_context(|| format!("parsing reply from {}", socket_path.display()))?;
    if let Some(error) = response.get("error").filter(|value| !value.is_null()) {
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown daemon RPC error");
        bail!("{message}");
    }
    response
        .get("result")
        .cloned()
        .map(Some)
        .with_context(|| format!("missing result in reply from {}", socket_path.display()))
}

/// Calls `method` on a live daemon socket or falls back to `on_store`.
///
/// Tries `--socket` (failing loudly if unreachable), then `$JPR_SOCKET` or
/// `session.json`'s `socket`, falling back to `on_store` when no live daemon responds.
pub fn execute_via_socket_or_store<T>(
    target: TargetContext<'_>,
    method: &str,
    params: &Value,
    on_socket: impl FnOnce(Value) -> Result<T>,
    on_store: impl FnOnce(&FsStore) -> Result<T>,
) -> Result<T> {
    match target.socket {
        Some(SocketOverride::Explicit(socket_path)) => {
            let result = call_socket(socket_path, method, params)?.with_context(|| {
                format!("cannot connect to daemon socket {}", socket_path.display())
            })?;
            return on_socket(result);
        }
        Some(SocketOverride::Env(socket_path)) => {
            if let Some(result) = call_socket(socket_path, method, params)? {
                return on_socket(result);
            }
        }
        None => {}
    }
    let store = open_store_from_target(target.pr, target.repo, target.theme)?;
    if let Some(session_socket) = load_session_socket(&store) {
        let was_already_tried = matches!(
            target.socket,
            Some(SocketOverride::Env(path)) if path == session_socket.as_path()
        );
        if !was_already_tried && let Some(result) = call_socket(&session_socket, method, params)? {
            return on_socket(result);
        }
    }
    on_store(&store)
}

fn open_store_from_target(pr: Option<u64>, repo: Option<&str>, theme: Theme) -> Result<FsStore> {
    let number = super::pr_number(pr, theme)?;
    let repo_name = get_repo_name_from_flag_or_git(repo, theme)?;
    let (owner, name) = super::parse_repo(&repo_name)?;
    Ok(FsStore::new(super::state_dir(&owner, &name, number)?))
}

fn get_repo_name_from_flag_or_git(flag: Option<&str>, theme: Theme) -> Result<String> {
    if let Some(repo) = flag {
        return Ok(repo.to_owned());
    }
    if let Ok(cwd) = env::current_dir()
        && let Some(inferred) = infer_repo_from_git_remote(&cwd)
    {
        return Ok(inferred);
    }
    super::repo_name(None, theme)
}

fn load_session_socket(store: &FsStore) -> Option<PathBuf> {
    store
        .load()
        .ok()
        .and_then(|snapshot| snapshot.session.socket)
        .filter(|path| !path.trim().is_empty())
        .map(PathBuf::from)
}

/// Infers `owner/name` from `directory`'s `origin` git remote without network calls.
#[must_use]
pub fn infer_repo_from_git_remote(directory: &Path) -> Option<String> {
    let mut command = Command::new("git");
    command
        .args(["remote", "get-url", "origin"])
        .current_dir(directory);
    for variable in GIT_ENV_VARS {
        command.env_remove(variable);
    }
    let output = command.output().ok()?;
    if !output.status.success() {
        return None;
    }
    let url = String::from_utf8(output.stdout).ok()?;
    let (owner, name) = parse_owner_repo_from_remote_url(url.trim())?;
    Some(format!("{owner}/{name}"))
}

/// Extracts `(owner, repo)` from HTTPS, SSH scheme, or SCP-style git remote URLs.
#[must_use]
pub fn parse_owner_repo_from_remote_url(url: &str) -> Option<(String, String)> {
    let trimmed = url.trim().trim_end_matches('/');
    let trimmed = trimmed.strip_suffix(".git").unwrap_or(trimmed);
    let path_part = if let Some((scheme, after_scheme)) = trimmed.split_once("://") {
        if scheme.eq_ignore_ascii_case("file") {
            return None;
        }
        let (host, path) = after_scheme.split_once('/')?;
        if host.is_empty() {
            return None;
        }
        path
    } else if let Some((_, path)) = trimmed.split_once(':') {
        path
    } else {
        return None;
    };
    let path_part = path_part.trim_start_matches('/');
    let mut segments = path_part.split('/');
    let owner = segments.next().filter(|part| is_plain_repo_segment(part))?;
    let name = segments.next().filter(|part| is_plain_repo_segment(part))?;
    if segments.next().is_some() {
        return None;
    }
    Some((owner.to_owned(), name.to_owned()))
}

fn is_plain_repo_segment(segment: &str) -> bool {
    !segment.is_empty() && segment != "." && segment != ".."
}

/// Formats Unix epoch seconds as an ISO-8601 UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`).
#[must_use]
pub fn format_unix_seconds_to_iso8601(seconds: u64) -> String {
    let days = i64::try_from(seconds / 86_400).unwrap_or(i64::MAX);
    let seconds_of_day = seconds % 86_400;
    let hour = seconds_of_day / 3_600;
    let minute = (seconds_of_day % 3_600) / 60;
    let second = seconds_of_day % 60;
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year_base = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = if month_prime < 10 {
        month_prime + 3
    } else {
        month_prime - 9
    };
    let year = year_base + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_known_unix_timestamps_as_iso8601_utc() {
        assert_eq!(format_unix_seconds_to_iso8601(0), "1970-01-01T00:00:00Z");
        assert_eq!(
            format_unix_seconds_to_iso8601(1_709_164_800),
            "2024-02-29T00:00:00Z"
        );
        assert_eq!(
            format_unix_seconds_to_iso8601(1_763_510_400 + 3_723),
            "2025-11-19T01:02:03Z"
        );
    }

    #[test]
    fn parses_https_ssh_and_scp_git_remote_urls() {
        assert_eq!(
            parse_owner_repo_from_remote_url("https://github.com/octo/widgets.git"),
            Some(("octo".into(), "widgets".into()))
        );
        assert_eq!(
            parse_owner_repo_from_remote_url("git@github.com:octo/widgets.git"),
            Some(("octo".into(), "widgets".into()))
        );
        assert_eq!(
            parse_owner_repo_from_remote_url("ssh://git@github.com/octo/widgets"),
            Some(("octo".into(), "widgets".into()))
        );
        assert_eq!(
            parse_owner_repo_from_remote_url("file:///octo/widgets"),
            None
        );
        assert_eq!(
            parse_owner_repo_from_remote_url("file://localhost/octo/widgets"),
            None
        );
        assert_eq!(parse_owner_repo_from_remote_url("/local/path/repo"), None);
        assert_eq!(
            parse_owner_repo_from_remote_url("https://github.com/octo/widgets/extra"),
            None
        );
    }

    #[test]
    fn missing_socket_returns_none_for_store_fallback() {
        let temp_directory = tempfile::tempdir().unwrap();
        let missing = temp_directory.path().join("absent.sock");
        assert_eq!(call_socket(&missing, "threads", &json!({})).unwrap(), None);
    }
}
