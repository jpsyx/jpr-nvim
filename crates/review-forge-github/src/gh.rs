//! Running `gh`, the GitHub CLI, with a timeout. `gh` is how the reviewer is
//! already logged in, so everything happens as that account. Copied from dif.

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

/// Runs `gh` in one directory.
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
            if let Some(message) = graphql::error_message(&stdout) {
                bail!("{message}");
            }
            bail!("{}", String::from_utf8_lossy(&output.stderr).trim());
        }
        Ok(stdout)
    }
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
}
