//! Running a command nobody is watching, such as a fetch that could stop at
//! an ssh prompt: no prompts, a deadline, and a bounded wait for its output.

use std::io::{self, Read};
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

use crate::process::{create_command, get_stdout_from_output};

/// How long to keep reading a program's output once it has exited or been
/// killed. A helper it started, such as an ssh connection kept for reuse,
/// can hold the pipes open long after.
const PIPE_GRACE: Duration = Duration::from_secs(1);

/// Runs `program` in `dir` with nobody at the keyboard, and returns its
/// stdout as text or fails with its stderr.
///
/// Git's terminal prompts are off (`GIT_TERMINAL_PROMPT=0`), and the program
/// is killed once `timeout` passes. See [`isolates_process_group`] for what
/// else the kill reaches.
pub fn run_unattended(
    program: &str,
    args: &[&str],
    dir: &Path,
    timeout: Duration,
) -> Result<String> {
    let isolate = isolates_process_group(has_terminal());
    run_unattended_with(program, args, dir, timeout, isolate)
}

/// Whether an unattended command gets its own process group, which the
/// timeout then kills whole, helpers such as ssh included.
///
/// Only when the engine has a terminal: there an ssh passphrase or host key
/// prompt, which `GIT_TERMINAL_PROMPT` does not cover, would otherwise read
/// keystrokes meant for the terminal. Without one, as under Neovim's
/// `jobstart`, nothing can prompt, and staying in the engine's group lets
/// `jobstop` stop the command and its helpers with the engine. The timeout
/// then kills only the program itself.
#[must_use]
pub const fn isolates_process_group(has_terminal: bool) -> bool {
    has_terminal
}

/// Whether this process has a controlling terminal a prompt could use.
fn has_terminal() -> bool {
    cfg!(unix) && std::fs::File::open("/dev/tty").is_ok()
}

/// [`run_unattended`], in its own process group when `isolate` is set.
pub fn run_unattended_with(
    program: &str,
    args: &[&str],
    dir: &Path,
    timeout: Duration,
    isolate: bool,
) -> Result<String> {
    let mut command = create_command(program, args, dir);
    command
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    if isolate {
        std::os::unix::process::CommandExt::process_group(&mut command, 0);
    }
    let child = command
        .spawn()
        .with_context(|| format!("running {program}"))?;
    let output = wait_with_timeout(child, timeout, isolate)
        .with_context(|| format!("running {program} {}", args.join(" ")))?;
    get_stdout_from_output(program, args, output)
        .map(|stdout| String::from_utf8_lossy(&stdout).into_owned())
}

/// What a command that ran out of time failed with: how long it had,
/// whether what it started may still run, and what it printed on stderr.
fn build_timeout_message(timeout: Duration, is_kill_missing: bool, stderr: &str) -> String {
    let mut message = format!("timed out after {}s", timeout.as_secs_f32());
    if is_kill_missing {
        message.push_str(" (kill could not be run, so what it started may still be running)");
    }
    if !stderr.is_empty() {
        message.push_str(": ");
        message.push_str(stderr);
    }
    message
}

/// Waits for `child` like [`Child::wait_with_output`], but stops it once
/// `timeout` passes, and stops reading its pipes [`PIPE_GRACE`] after it
/// has gone.
fn wait_with_timeout(mut child: Child, timeout: Duration, isolate: bool) -> Result<Output> {
    // Drain both pipes while waiting, so a large answer cannot block it.
    let stdout = PipeReader::start(child.stdout.take());
    let stderr = PipeReader::start(child.stderr.take());
    let give_up_at = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= give_up_at {
            let is_kill_missing = stop(&mut child, isolate);
            let stderr_text = String::from_utf8_lossy(&stderr.finish(PIPE_GRACE)).into_owned();
            bail!(
                "{}",
                build_timeout_message(timeout, is_kill_missing, stderr_text.trim())
            );
        }
        thread::sleep(Duration::from_millis(20));
    };
    Ok(Output {
        status,
        stdout: stdout.finish(PIPE_GRACE),
        stderr: stderr.finish(PIPE_GRACE),
    })
}

/// Kills `child`, and when it was `isolate`d, the process group it leads, so
/// a helper it started (such as ssh waiting at a prompt) does not outlive
/// it. Returns whether `kill` was needed for that but could not be run.
fn stop(child: &mut Child, isolate: bool) -> bool {
    let is_kill_missing = cfg!(unix) && isolate && kill_process_group(child.id()).is_err();
    let _ = child.kill();
    let _ = child.wait();
    is_kill_missing
}

/// Sends SIGKILL to the process group `group`.
fn kill_process_group(group: u32) -> io::Result<ExitStatus> {
    // The standard library cannot signal a group and `unsafe` is forbidden
    // here, so the `kill` command does.
    Command::new("kill")
        .args(["-s", "KILL", "--", &format!("-{group}")])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
}

/// A pipe read on its own thread into a buffer, so what came through can be
/// taken at any time, even while something still holds the pipe open.
struct PipeReader {
    bytes: Arc<Mutex<Vec<u8>>>,
    thread: Option<JoinHandle<()>>,
}

impl PipeReader {
    fn start(pipe: Option<impl Read + Send + 'static>) -> Self {
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let thread = pipe.map(|mut pipe| {
            let bytes = Arc::clone(&bytes);
            thread::spawn(move || {
                let mut chunk = [0_u8; 8192];
                while let Ok(count @ 1..) = pipe.read(&mut chunk) {
                    lock(&bytes).extend_from_slice(&chunk[..count]);
                }
            })
        });
        Self { bytes, thread }
    }

    /// Everything read until the pipe closed, or until `grace` passed.
    fn finish(self, grace: Duration) -> Vec<u8> {
        let give_up_at = Instant::now() + grace;
        if let Some(thread) = &self.thread {
            while !thread.is_finished() && Instant::now() < give_up_at {
                thread::sleep(Duration::from_millis(10));
            }
        }
        std::mem::take(&mut *lock(&self.bytes))
    }
}

fn lock(bytes: &Mutex<Vec<u8>>) -> MutexGuard<'_, Vec<u8>> {
    bytes.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{is_eventually_gone, is_kill_available, stop_helper, wait_for_pid};

    /// The process group `pid` belongs to, as `ps` reports it.
    fn get_process_group_from_pid(pid: &str) -> String {
        let output = Command::new("ps").args(["-o", "pgid=", "-p", pid]).output();
        String::from_utf8_lossy(&output.unwrap().stdout)
            .trim()
            .to_owned()
    }

    #[test]
    fn only_an_engine_with_a_terminal_isolates_its_commands() {
        assert!(isolates_process_group(true));
        assert!(!isolates_process_group(false));
    }

    #[test]
    fn a_timeout_names_what_could_not_be_stopped_and_what_the_program_said() {
        let timeout = Duration::from_millis(500);
        assert_eq!(
            build_timeout_message(timeout, false, ""),
            "timed out after 0.5s"
        );
        assert_eq!(
            build_timeout_message(timeout, false, "Connecting to example.com"),
            "timed out after 0.5s: Connecting to example.com"
        );
        let message = build_timeout_message(timeout, true, "");
        assert!(message.contains("kill could not be run"), "{message}");
    }

    #[test]
    fn unattended_commands_have_git_prompts_turned_off() {
        let dir = tempfile::tempdir().unwrap();
        let script = "printf %s \"$GIT_TERMINAL_PROMPT\"";
        let stdout = run_unattended("sh", &["-c", script], dir.path(), Duration::from_secs(5));
        assert_eq!(stdout.unwrap(), "0");
    }

    #[test]
    fn an_unattended_command_past_its_timeout_is_stopped_with_what_it_said() {
        let dir = tempfile::tempdir().unwrap();
        let started = Instant::now();
        let timeout = Duration::from_millis(200);
        // The script holds `6*7`, not `42`, so finding `42` proves the
        // message carries what the program said, not its command line.
        let script = "echo stuck-at-$((6*7)) >&2; sleep 30";
        let error =
            run_unattended_with("sh", &["-c", script], dir.path(), timeout, true).unwrap_err();
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "{:?}",
            started.elapsed()
        );
        let message = format!("{error:#}");
        assert!(message.contains("timed out"), "{message}");
        assert!(message.contains("stuck-at-42"), "{message}");
    }

    #[cfg(unix)]
    #[test]
    fn an_isolated_command_is_stopped_with_everything_it_started() {
        if !is_kill_available() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let pid_file = dir.path().join("helper.pid");
        let script = format!("sleep 30 & echo $! > '{}'; wait", pid_file.display());
        let timeout = Duration::from_millis(300);
        run_unattended_with("sh", &["-c", &script], dir.path(), timeout, true).unwrap_err();
        let helper_pid = wait_for_pid(&pid_file);
        assert!(
            is_eventually_gone(&helper_pid),
            "helper {helper_pid} still runs"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_command_stays_in_the_engines_process_group_unless_isolated() {
        let dir = tempfile::tempdir().unwrap();
        let engine_group = get_process_group_from_pid(&std::process::id().to_string());
        let script = "ps -o pgid= -p $$";
        let timeout = Duration::from_secs(5);
        let shared = run_unattended_with("sh", &["-c", script], dir.path(), timeout, false);
        assert_eq!(shared.unwrap().trim(), engine_group);
        let isolated = run_unattended_with("sh", &["-c", script], dir.path(), timeout, true);
        assert_ne!(isolated.unwrap().trim(), engine_group);
    }

    #[test]
    fn output_held_open_by_a_helper_is_not_waited_for_forever() {
        let dir = tempfile::tempdir().unwrap();
        let started = Instant::now();
        let timeout = Duration::from_secs(20);
        let script = "sleep 10 & echo $!";
        let stdout = run_unattended_with("sh", &["-c", script], dir.path(), timeout, false);
        let elapsed = started.elapsed();
        let helper_pid = stdout.unwrap();
        stop_helper(helper_pid.trim());
        assert_ne!(helper_pid.trim(), "");
        assert!(elapsed < Duration::from_secs(5), "{elapsed:?}");
    }
}
