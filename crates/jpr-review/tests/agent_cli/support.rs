//! Shared harness and fake-daemon helpers for `agent_cli` integration tests.

use std::fs;
use std::io::{BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use review_core::ReviewSession;
use review_core::fakes::{
    FakeForge, FakeWorkspace, FixedClock, MemoryStore, changed_file, create_fake_ports,
    github_thread, sample_pr,
};
use review_core::ports::ForgeSnapshot;
use review_model::{Anchor, Origin, ViewedState};
use review_rpc::{ServeOptions, serve};
use review_store_fs::state_dir;
use serde_json::{Value, json};
use tempfile::TempDir;

/// Isolated temporary HOME and XDG_STATE_HOME directory for CLI tests.
pub struct TestEnvironment {
    /// Root temporary directory.
    pub root: TempDir,
    /// Temporary `HOME` directory.
    pub home: PathBuf,
    /// Temporary `XDG_STATE_HOME` directory.
    pub state: PathBuf,
}

impl TestEnvironment {
    /// Creates an isolated temporary home and state environment.
    pub fn create() -> Self {
        let root = tempfile::tempdir().expect("tempdir");
        let home = root.path().join("home");
        let state = root.path().join("state");
        fs::create_dir_all(&home).expect("home dir");
        fs::create_dir_all(&state).expect("state dir");
        Self { root, home, state }
    }

    /// Computes the state directory for `(owner, repo, number)`.
    pub fn pr_state_directory(&self, owner: &str, repo: &str, number: u64) -> PathBuf {
        state_dir(Some(&self.state), &self.home, "jpr", owner, repo, number).expect("state dir")
    }

    /// Executes `jpr-review` with isolated environment variables and optional stdin.
    pub fn run(
        &self,
        args: &[&str],
        stdin_data: Option<&str>,
        extra_environment: &[(&str, &str)],
    ) -> Output {
        let mut command = Command::new(env!("CARGO_BIN_EXE_jpr-review"));
        command
            .args(args)
            .current_dir(self.root.path())
            .env("HOME", &self.home)
            .env("XDG_STATE_HOME", &self.state)
            .env_remove("JPR_SOCKET")
            .env_remove("JPR_PR")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .stdin(if stdin_data.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            });
        for (key, value) in extra_environment {
            command.env(key, value);
        }
        let mut child = command.spawn().expect("spawn jpr-review");
        if let (Some(data), Some(mut stdin)) = (stdin_data, child.stdin.take()) {
            stdin.write_all(data.as_bytes()).expect("write stdin");
        }
        child.wait_with_output().expect("wait jpr-review")
    }
}

struct ChannelReader {
    receiver: mpsc::Receiver<Vec<u8>>,
    buffer: Vec<u8>,
    position: usize,
}

impl Read for ChannelReader {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        while self.position >= self.buffer.len() {
            let Ok(chunk) = self.receiver.recv() else {
                return Ok(0);
            };
            self.buffer = chunk;
            self.position = 0;
        }
        let count = out.len().min(self.buffer.len() - self.position);
        out[..count].copy_from_slice(&self.buffer[self.position..self.position + count]);
        self.position += count;
        Ok(count)
    }
}

struct ChannelWriter {
    sender: mpsc::Sender<Value>,
    pending: Vec<u8>,
}

impl Write for ChannelWriter {
    fn write(&mut self, chunk: &[u8]) -> std::io::Result<usize> {
        self.pending.extend_from_slice(chunk);
        while let Some(newline) = self.pending.iter().position(|byte| *byte == b'\n') {
            let line: Vec<u8> = self.pending.drain(..=newline).collect();
            let text = String::from_utf8(line).expect("UTF-8 line");
            let parsed: Value = serde_json::from_str(text.trim_end()).expect("JSON line");
            let _ = self.sender.send(parsed);
        }
        Ok(chunk.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn open_daemon_session() -> Arc<Mutex<ReviewSession>> {
    let forge = FakeForge::new(
        sample_pr(),
        ForgeSnapshot {
            head_sha: "abc123".into(),
            threads: vec![github_thread("T1", "src/a.rs")],
            files: vec![changed_file("src/a.rs", ViewedState::Unviewed)],
            ..ForgeSnapshot::default()
        },
    );
    let ports = create_fake_ports(
        &forge,
        &MemoryStore::default(),
        &FakeWorkspace::default(),
        &FixedClock::at(100),
    );
    let mut session = ReviewSession::open(7, ports).expect("open");
    session.sync().expect("sync");
    session
        .comment_with_origin(Anchor::line("src/a.rs", 1), "Check", Origin::Local)
        .expect("local comment");
    Arc::new(Mutex::new(session))
}

/// Spawns a live `review_rpc::serve` daemon listening on `socket_path`.
pub fn spawn_socket_daemon(
    socket_path: &Path,
) -> (mpsc::Sender<Vec<u8>>, mpsc::Receiver<Value>, JoinHandle<()>) {
    let shared_session = open_daemon_session();
    let (stdin_sender, stdin_receiver) = mpsc::channel();
    let (stdout_sender, stdout_receiver) = mpsc::channel();
    let options = ServeOptions {
        server_version: "1.0.0".into(),
        poll_every: None,
        retry_every: None,
        socket_path: Some(socket_path.to_path_buf()),
        watch_every: None,
    };
    let handle = thread::spawn(move || {
        let reader = BufReader::new(ChannelReader {
            receiver: stdin_receiver,
            buffer: Vec::new(),
            position: 0,
        });
        let writer = Arc::new(Mutex::new(ChannelWriter {
            sender: stdout_sender,
            pending: Vec::new(),
        }));
        serve(reader, &writer, &shared_session, &options).expect("serve");
    });
    wait_for_socket(socket_path);
    (stdin_sender, stdout_receiver, handle)
}

fn wait_for_socket(socket_path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(3);
    while !socket_path.exists() {
        assert!(Instant::now() < deadline, "socket never appeared");
        thread::sleep(Duration::from_millis(10));
    }
}

/// Returns sample pre-pass findings serialized as JSON.
pub fn sample_findings_json() -> String {
    json!([
        { "anchor": { "file": "src/a.rs", "kind": "line", "side": "RIGHT", "start": 2, "end": 2 }, "body": "[high] Check bounds." },
        { "anchor": { "file": null, "kind": "pr", "side": "RIGHT", "start": null, "end": null }, "body": "[nit] Clarify title." }
    ])
    .to_string()
}

/// Asserts that `output` exited with status 0, printing stderr on failure.
pub fn assert_success(output: &Output, label: &str) {
    assert!(
        output.status.success(),
        "{label} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// Spawns `count` concurrent `jpr-review reply` invocations against `loc-1`.
pub fn spawn_concurrent_replies(environment: &Arc<TestEnvironment>, count: usize) {
    let handles: Vec<_> = (0..count)
        .map(|index| {
            let environment_ref = Arc::clone(environment);
            thread::spawn(move || {
                let body = format!("Concurrent reply {index}");
                let args = [
                    "reply",
                    "loc-1",
                    "--body",
                    &body,
                    "--pr",
                    "7",
                    "--repo",
                    "octo/widgets",
                ];
                environment_ref.run(&args, None, &[])
            })
        })
        .collect();
    for handle in handles {
        assert_success(&handle.join().expect("join"), "concurrent reply");
    }
}

/// Sends a shutdown request and joins the daemon thread.
pub fn shutdown_socket_daemon(stdin_sender: mpsc::Sender<Vec<u8>>, handle: JoinHandle<()>) {
    stdin_sender
        .send(b"{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"shutdown\"}\n".to_vec())
        .expect("send shutdown");
    drop(stdin_sender);
    handle.join().expect("daemon join");
}

/// Initializes a git repository with an `origin` remote and `src/a.rs` in `repo_directory`.
pub fn init_git_worktree(repo_directory: &Path) {
    fs::create_dir_all(repo_directory.join("src")).expect("src dir");
    fs::write(
        repo_directory.join("src/a.rs"),
        "fn one() {}\nlet bound = 2;\n",
    )
    .expect("write file");
    for args in [
        &["init", "-q"][..],
        &[
            "remote",
            "add",
            "origin",
            "https://github.com/octo/widgets.git",
        ][..],
    ] {
        let status = Command::new("git")
            .args(args)
            .current_dir(repo_directory)
            .status()
            .expect("git");
        assert!(status.success());
    }
}
