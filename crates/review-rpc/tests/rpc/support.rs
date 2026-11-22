//! Shared server harness and socket helpers for `rpc` integration tests.

use std::io::{BufRead, BufReader, Cursor, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
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

static NEXT_SOCKET_SEQUENCE: AtomicU64 = AtomicU64::new(1);

/// Creates a fake forge seeded with one thread and one file.
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

/// Default `ServeOptions` for integration tests.
pub fn default_options() -> ServeOptions {
    ServeOptions {
        server_version: "9.9.9".into(),
        poll_every: None,
        retry_every: None,
        socket_path: None,
        watch_every: None,
    }
}

/// Formats a JSON-RPC request line without `params`.
pub fn request(id: u64, method: &str) -> String {
    format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"{method}\"}}\n")
}

/// Formats a JSON-RPC request line with raw JSON `params`.
pub fn build_request_with_params(id: u64, method: &str, params: &str) -> String {
    format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"{method}\",\"params\":{params}}}\n")
}

/// Runs `serve` over an in-memory input script and returns parsed JSON lines.
pub fn run_script(input: &str, fake_forge: &FakeForge) -> Vec<Value> {
    let (session, _) = workspace_with_disk(fake_forge);
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    serve(
        Cursor::new(input.to_owned()),
        &output,
        &session,
        &default_options(),
    )
    .unwrap();
    let bytes = output.lock().unwrap().clone();
    String::from_utf8(bytes)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// Finds the JSON response matching `id` in `messages`.
pub fn response(messages: &[Value], id: u64) -> &Value {
    messages
        .iter()
        .find(|message| message["id"] == id)
        .unwrap_or_else(|| panic!("no response {id} in {messages:?}"))
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
            let text = String::from_utf8(line).expect("valid UTF-8 line");
            let parsed: Value = serde_json::from_str(text.trim_end()).expect("valid JSON line");
            let _ = self.sender.send(parsed);
        }
        Ok(chunk.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Handle to a running JSON-RPC server thread connected via channels.
pub struct LiveServer {
    stdin_sender: mpsc::Sender<Vec<u8>>,
    stdout_receiver: mpsc::Receiver<Value>,
    /// Join handle for the server thread.
    pub handle: JoinHandle<anyhow::Result<()>>,
}

impl LiveServer {
    /// Sends one raw line to the server's stdin channel.
    pub fn send_line(&self, line: &str) {
        self.stdin_sender
            .send(line.as_bytes().to_vec())
            .expect("stdin channel open");
    }

    /// Receives the next JSON message emitted on the server's stdout channel.
    pub fn recv_json(&self) -> Value {
        self.stdout_receiver
            .recv_timeout(Duration::from_secs(3))
            .expect("expected JSON message on stdio")
    }

    /// Reads messages from stdout until the response with `id` arrives.
    pub fn recv_until_id(&self, id: u64) -> Vec<Value> {
        let mut collected = Vec::new();
        loop {
            let message = self.recv_json();
            let is_match = message["id"] == id;
            collected.push(message);
            if is_match {
                return collected;
            }
        }
    }
}

/// Spawns `serve` on a background thread backed by in-memory stdio channels.
pub fn spawn_live_server(session: Arc<Mutex<ReviewSession>>, options: ServeOptions) -> LiveServer {
    let (stdin_sender, stdin_receiver) = mpsc::channel();
    let (stdout_sender, stdout_receiver) = mpsc::channel();
    let reader = BufReader::new(ChannelReader {
        receiver: stdin_receiver,
        buffer: Vec::new(),
        position: 0,
    });
    let writer = Arc::new(Mutex::new(ChannelWriter {
        sender: stdout_sender,
        pending: Vec::new(),
    }));
    let handle = thread::spawn(move || serve(reader, &writer, &session, &options));
    LiveServer {
        stdin_sender,
        stdout_receiver,
        handle,
    }
}

/// RAII guard that removes a temporary Unix socket path on drop.
pub struct SocketPathGuard(pub PathBuf);

impl Drop for SocketPathGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// Allocates a unique temporary socket path under `/tmp`.
pub fn temp_socket_path() -> SocketPathGuard {
    let sequence = NEXT_SOCKET_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    SocketPathGuard(PathBuf::from(format!(
        "/tmp/jpr-rpc-{}-{sequence}.sock",
        std::process::id()
    )))
}

/// Polls until a Unix socket accepts connections and returns the stream.
pub fn connect_socket(path: &Path) -> UnixStream {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if let Ok(stream) = UnixStream::connect(path) {
            return stream;
        }
        assert!(
            Instant::now() < deadline,
            "timed out connecting to {}",
            path.display()
        );
        thread::sleep(Duration::from_millis(10));
    }
}

/// Sends one JSON-RPC line over `stream` and reads the single-line response.
pub fn socket_call(stream: &mut UnixStream, line: &str) -> Value {
    stream.write_all(line.as_bytes()).unwrap();
    stream.flush().unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut response_line = String::new();
    reader.read_line(&mut response_line).unwrap();
    serde_json::from_str(response_line.trim_end()).unwrap()
}

/// Opens a `ReviewSession` paired with a pre-populated `FakeWorkspace`.
pub fn workspace_with_disk(fake_forge: &FakeForge) -> (Arc<Mutex<ReviewSession>>, FakeWorkspace) {
    let workspace = FakeWorkspace::default();
    workspace.put_base("src/a.rs", "fn a() {}\n");
    workspace.put_at("abc123", "src/a.rs", "fn a() { 1 }\nlet keep = true;\n");
    workspace.put_disk("src/a.rs", "fn a() { 1 }\nlet keep = true;\n");
    let ports = create_fake_ports(
        fake_forge,
        &MemoryStore::default(),
        &workspace,
        &FixedClock::at(100),
    );
    (
        Arc::new(Mutex::new(ReviewSession::open(7, ports).unwrap())),
        workspace,
    )
}
