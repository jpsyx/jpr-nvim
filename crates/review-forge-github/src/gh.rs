use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use serde_json::Value;

use crate::graphql;

/// How long one `gh` call may take. On a network that drops packets rather
/// than refusing connections, `gh` hangs instead of failing.
pub const GH_TIMEOUT: Duration = Duration::from_secs(30);

/// Runs `gh`, the GitHub CLI, in one directory with a timeout. `gh` is how the
/// reviewer is already logged in, so every call happens as that account; the
/// GitHub forge sends all its requests through it.
#[derive(Debug, Clone)]
pub struct Gh {
    dir: PathBuf,
}

impl Gh {
    /// A runner whose `gh` calls start in `dir`.
    #[must_use]
    pub const fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    /// Runs `gh <args>`, writing `input` as JSON to its stdin, and returns stdout.
    pub fn run(&self, args: &[&str], input: Option<&Value>) -> Result<String> {
        let mut child = Command::new("gh")
            .args(args)
            .current_dir(&self.dir)
            .stdin(if input.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("running gh (is the GitHub CLI installed?)")?;
        if let (Some(input), Some(mut stdin)) = (input, child.stdin.take()) {
            stdin.write_all(input.to_string().as_bytes())?;
        }
        let output = wait_with_timeout(child, GH_TIMEOUT)?;
        let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(gh_failure_to_error(&stdout, &stderr));
        }
        Ok(stdout)
    }
}

fn gh_failure_to_error(stdout: &str, stderr: &str) -> anyhow::Error {
    let message = format_gh_failure(stdout, stderr);
    if review_core::is_gh_auth_failure_text(&message) {
        anyhow::Error::new(review_core::ForgeAuthError::new(message))
    } else {
        anyhow::anyhow!(message)
    }
}

fn format_gh_failure(stdout: &str, stderr: &str) -> String {
    let stderr_trimmed = stderr.trim();
    if let Some(message) = graphql::error_message(stdout) {
        if stderr_trimmed.is_empty() {
            return message;
        }
        return format!("{stderr_trimmed}: {message}");
    }
    if let Some(rest_detail) = graphql::rest_error_message(stdout) {
        if stderr_trimmed.is_empty() {
            return rest_detail;
        }
        return format!("{stderr_trimmed}: {rest_detail}");
    }
    stderr_trimmed.to_owned()
}

/// Waits for `child` like [`Child::wait_with_output`], killing it once
/// `timeout` passes.
fn wait_with_timeout(mut child: Child, timeout: Duration) -> Result<Output> {
    // Drain both pipes while waiting, so a large answer cannot block `gh`.
    let stdout = child.stdout.take().map(read_in_background);
    let stderr = child.stderr.take().map(read_in_background);
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            bail!("gh timed out after {}s", timeout.as_secs_f32());
        }
        thread::sleep(Duration::from_millis(20));
    };
    let collect = |reader: Option<JoinHandle<Vec<u8>>>| {
        reader
            .and_then(|handle| handle.join().ok())
            .unwrap_or_default()
    };
    Ok(Output {
        status,
        stdout: collect(stdout),
        stderr: collect(stderr),
    })
}

fn read_in_background(mut pipe: impl Read + Send + 'static) -> JoinHandle<Vec<u8>> {
    thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = pipe.read_to_end(&mut bytes);
        bytes
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_hung_command_is_killed_and_reported_as_timed_out() {
        let child = Command::new("sleep")
            .arg("5")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let started = Instant::now();
        let error = wait_with_timeout(child, Duration::from_millis(100)).unwrap_err();
        assert!(started.elapsed() < Duration::from_secs(2));
        assert!(error.to_string().contains("timed out"), "{error}");
    }

    #[test]
    fn a_command_that_finishes_in_time_returns_its_output() {
        let child = Command::new("sh")
            .args(["-c", "echo out; echo err >&2"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let output = wait_with_timeout(child, Duration::from_secs(5)).unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "out\n");
        assert_eq!(String::from_utf8_lossy(&output.stderr), "err\n");
    }

    #[test]
    fn failure_formatting_preserves_stderr_status_alongside_graphql_and_rest_errors() {
        let gql = r#"{"errors":[{"message":"Something went wrong"}]}"#;
        assert_eq!(format_gh_failure(gql, ""), "Something went wrong");
        assert_eq!(
            format_gh_failure(gql, "gh: HTTP 502 Bad Gateway\n"),
            "gh: HTTP 502 Bad Gateway: Something went wrong"
        );
        let rest = r#"{"message":"Validation Failed","errors":["pending review"]}"#;
        assert_eq!(
            format_gh_failure(rest, "gh: HTTP 422"),
            "gh: HTTP 422: pending review"
        );
    }

    #[test]
    fn gh_failure_to_error_wraps_auth_failures_as_forge_auth_error() {
        let login_err = gh_failure_to_error(
            "",
            "To get started with GitHub CLI, please run:  gh auth login\n",
        );
        assert!(review_core::is_auth_error(&login_err));
        let unauth_err = gh_failure_to_error(
            r#"{"message":"Bad credentials"}"#,
            "gh: HTTP 401 Unauthorized\n",
        );
        assert!(review_core::is_auth_error(&unauth_err));
        let server_err = gh_failure_to_error("", "gh: HTTP 502 Bad Gateway\n");
        assert!(!review_core::is_auth_error(&server_err));
    }
}
