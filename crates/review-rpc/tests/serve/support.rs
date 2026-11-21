//! Fixtures for the server's end-to-end tests: a session over the fake
//! ports, request lines, and readers and writers that steer `serve`.

use std::io::{Cursor, Read};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use review_core::ReviewSession;
use review_core::fakes::{
    FakeForge, FakeWorkspace, FixedClock, MemoryStore, changed_file, create_fake_ports,
    github_thread, sample_pr,
};
use review_core::ports::ForgeSnapshot;
use review_model::ViewedState;
use review_rpc::{ServeOptions, serve};
use serde_json::Value;

/// A forge for the sample pull request with one thread and a viewed
/// `src/a.rs`.
pub fn forge() -> FakeForge {
    FakeForge::new(
        sample_pr(),
        ForgeSnapshot {
            head_sha: "abc123".into(),
            has_pending_review: false,
            threads: vec![github_thread("T1", "src/a.rs")],
            files: vec![changed_file("src/a.rs", ViewedState::Viewed)],
            ..ForgeSnapshot::default()
        },
    )
}

/// A checkout where `src/a.rs` gained a body since the merge base.
fn create_workspace() -> FakeWorkspace {
    let workspace = FakeWorkspace::default();
    workspace.put_base("src/a.rs", "fn a() {}\n");
    workspace.put_disk("src/a.rs", "fn a() { 1 }\n");
    workspace
}

/// A session for pull request 7 over `forge` and in-memory fakes, at time
/// 100.
pub fn session(forge: &FakeForge) -> Arc<Mutex<ReviewSession>> {
    let ports = create_fake_ports(
        forge,
        &MemoryStore::default(),
        &create_workspace(),
        &FixedClock::at(100),
    );
    Arc::new(Mutex::new(ReviewSession::open(7, ports).unwrap()))
}

/// Serve options for server version 9.9.9 that poll every `poll_every` and
/// never retry.
pub fn options(poll_every: Option<Duration>) -> ServeOptions {
    ServeOptions {
        server_version: "9.9.9".into(),
        poll_every,
        retry_every: None,
    }
}

/// A request line for `method` without params.
pub fn request(id: u64, method: &str) -> String {
    format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"{method}\"}}\n")
}

/// A request line for `method` with the JSON `params`.
pub fn build_request_with_params(id: u64, method: &str, params: &str) -> String {
    format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"{method}\",\"params\":{params}}}\n")
}

/// Every message written to `output` so far, parsed.
pub fn messages(output: &Mutex<Vec<u8>>) -> Vec<Value> {
    let bytes = output.lock().unwrap().clone();
    String::from_utf8(bytes)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// Serves `input` and returns everything written, events included: `serve`
/// writes every event before it returns.
pub fn run(input: &str, forge: &FakeForge) -> Vec<Value> {
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    serve(
        Cursor::new(input.to_owned()),
        &output,
        &session(forge),
        &options(None),
    )
    .unwrap();
    messages(&output)
}

/// The response to request `id` among `messages`.
pub fn response(messages: &[Value], id: u64) -> &Value {
    messages
        .iter()
        .find(|message| message["id"] == id)
        .unwrap_or_else(|| panic!("no response {id} in {messages:?}"))
}

/// The first `event` notification among `messages`.
pub fn event(messages: &[Value]) -> &Value {
    messages
        .iter()
        .find(|message| message["method"] == "event")
        .unwrap_or_else(|| panic!("no event in {messages:?}"))
}

/// A reader that keeps the server running until `done` holds or `deadline`
/// passes, so a test waits on what it expects instead of a fixed window.
pub struct EndsWhen<F: Fn() -> bool> {
    pub done: F,
    pub deadline: Instant,
}

impl<F: Fn() -> bool> Read for EndsWhen<F> {
    fn read(&mut self, _buffer: &mut [u8]) -> std::io::Result<usize> {
        while !(self.done)() && Instant::now() < self.deadline {
            thread::sleep(Duration::from_millis(5));
        }
        Ok(0)
    }
}

/// The views of every `synced` event in `output`.
pub fn synced_views(output: &Mutex<Vec<u8>>) -> Vec<Value> {
    messages(output)
        .into_iter()
        .filter(|message| message["params"]["type"] == "synced")
        .map(|message| message["params"]["view"].clone())
        .collect()
}

/// What the forge reports after a push: a new head and a second file.
pub fn changed_snapshot() -> ForgeSnapshot {
    ForgeSnapshot {
        head_sha: "def456".into(),
        has_pending_review: false,
        threads: vec![github_thread("T1", "src/a.rs")],
        files: vec![
            changed_file("src/a.rs", ViewedState::Viewed),
            changed_file("src/b.rs", ViewedState::Unviewed),
        ],
        ..ForgeSnapshot::default()
    }
}

/// A writer whose reader has gone away.
pub struct Closed;

impl std::io::Write for Closed {
    fn write(&mut self, _buffer: &[u8]) -> std::io::Result<usize> {
        Err(std::io::ErrorKind::BrokenPipe.into())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
