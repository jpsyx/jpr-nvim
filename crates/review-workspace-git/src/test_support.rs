//! Fixtures shared by this crate's tests: real git repositories in temporary
//! directories, and helpers that watch the processes a test starts.

use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use crate::process::GIT_REPOSITORY_VARIABLES;

/// Runs git with `args` in `dir` as a fixed test author, failing the test
/// when git fails.
pub fn git(dir: &Path, args: &[&str]) {
    let mut command = Command::new("git");
    for variable in GIT_REPOSITORY_VARIABLES {
        command.env_remove(variable);
    }
    let status = command
        .args(args)
        .current_dir(dir)
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@example.com")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@example.com")
        .status()
        .unwrap();
    assert!(status.success(), "git {args:?}");
}

/// A temporary directory holding a one-commit repository named `widgets`.
pub fn repo() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("widgets");
    fs::create_dir(&root).unwrap();
    git(&root, &["init", "-q", "-b", "main"]);
    fs::write(root.join("a.txt"), "a\n").unwrap();
    git(&root, &["add", "."]);
    git(&root, &["commit", "-q", "-m", "init"]);
    dir
}

/// The process id a test helper wrote to `pid_file`, waiting a few seconds
/// for it to appear. Fails the test when none does, so a check on the
/// process can never pass on an empty id.
pub fn wait_for_pid(pid_file: &Path) -> String {
    let give_up_at = Instant::now() + Duration::from_secs(5);
    loop {
        let pid = fs::read_to_string(pid_file).unwrap_or_default();
        let pid = pid.trim();
        if !pid.is_empty() {
            return pid.to_owned();
        }
        assert!(
            Instant::now() < give_up_at,
            "no pid in {}",
            pid_file.display()
        );
        thread::sleep(Duration::from_millis(20));
    }
}

/// Whether the `kill` command can be run here. Minimal images may lack it.
pub fn is_kill_available() -> bool {
    Command::new("kill")
        .args(["-0", &std::process::id().to_string()])
        .status()
        .is_ok()
}

/// Whether the process `pid` is gone within a few seconds.
pub fn is_eventually_gone(pid: &str) -> bool {
    let give_up_at = Instant::now() + Duration::from_secs(5);
    while Instant::now() < give_up_at {
        let is_alive = Command::new("kill")
            .args(["-0", pid])
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success();
        if !is_alive {
            return true;
        }
        thread::sleep(Duration::from_millis(50));
    }
    false
}

/// Stops the leftover helper process `pid`, if it still runs.
pub fn stop_helper(pid: &str) {
    let _ = Command::new("kill").arg(pid).stderr(Stdio::null()).status();
}
