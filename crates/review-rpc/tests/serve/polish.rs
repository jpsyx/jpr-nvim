//! Push, conflict-resolution dispatch, and Unix socket refusal RPC tests.

use std::io::{BufReader, Cursor};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use review_core::ReviewSession;
use review_core::fakes::{
    FakeForge, FakeWorkspace, FixedClock, MemoryStore, create_fake_ports, sample_pr,
};
use review_model::WorktreeStatus;
use review_rpc::{RpcError, ServeOptions, serve};
use serde_json::{Value, json};

use crate::support::{
    EndsWhen, build_request_with_params, changed_snapshot, forge, messages, options, request,
    response, session,
};

fn create_push_ready_session(fake_forge: &FakeForge) -> Arc<Mutex<ReviewSession>> {
    let workspace = FakeWorkspace::default();
    workspace.put_base("src/a.rs", "fn a() {}\n");
    workspace.put_at("abc123", "src/a.rs", "fn a() { 1 }\n");
    workspace.put_at("def456", "src/a.rs", "fn a() { 2 }\n");
    workspace.put_disk("src/a.rs", "fn a() { 2 }\n");
    let ports = create_fake_ports(
        fake_forge,
        &MemoryStore::default(),
        &workspace,
        &FixedClock::at(100),
    );
    let mut review_session = ReviewSession::open(7, ports).unwrap();
    review_session.sync().unwrap();
    workspace.set_head_commit("def456");
    workspace.set_worktree_status(Some(WorktreeStatus {
        is_dirty: false,
        ahead: 1,
        behind: 0,
        modified_paths: Vec::new(),
    }));
    let mut updated_pr = sample_pr();
    updated_pr.head_sha = "def456".into();
    fake_forge.set_pr(updated_pr);
    fake_forge.set_snapshot(changed_snapshot());
    Arc::new(Mutex::new(review_session))
}

#[test]
fn push_over_stdio_pushes_head_and_returns_push_result() {
    let fake_forge = forge();
    let shared = create_push_ready_session(&fake_forge);
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    serve(
        Cursor::new(request(1, "push")),
        &output,
        &shared,
        &options(None),
    )
    .unwrap();
    let written = messages(&output);
    let head_moved = written
        .iter()
        .position(|message| message["params"]["type"] == "headMoved")
        .expect("a headMoved event");
    let synced = written
        .iter()
        .position(|message| message["params"]["type"] == "synced")
        .expect("a synced event");
    let answer = written
        .iter()
        .position(|message| message["id"] == 1)
        .unwrap();
    assert!(head_moved < synced && synced < answer, "{written:?}");
    let result = &response(&written, 1)["result"];
    assert_eq!(result["isPushed"], true, "{written:?}");
    assert_eq!(result["headSha"], "def456", "{written:?}");
}

fn confirm_conflict_round_over_stdio(
    shared: &Arc<Mutex<ReviewSession>>,
    prompt: &str,
) -> Vec<Value> {
    let confirm_output = Arc::new(Mutex::new(Vec::<u8>::new()));
    let confirm_params = json!({
        "round": 1,
        "kind": "conflict",
        "threadIds": [],
        "prompt": prompt,
    })
    .to_string();
    let confirm_input = build_request_with_params(3, "confirmSend", &confirm_params);
    serve(
        Cursor::new(confirm_input),
        &confirm_output,
        shared,
        &options(None),
    )
    .unwrap();
    messages(&confirm_output)
}

fn prepare_conflict_dispatch_over_stdio(shared: &Arc<Mutex<ReviewSession>>) -> Value {
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    let prepare_input = request(1, "sync")
        + &build_request_with_params(
            2,
            "prepareConflictResolution",
            r#"{"paths":["src/a.rs"],"agent":"claude"}"#,
        );
    serve(Cursor::new(prepare_input), &output, shared, &options(None)).unwrap();
    let prepare_written = messages(&output);
    response(&prepare_written, 2)["result"].clone()
}

#[test]
fn prepare_conflict_resolution_and_confirm_send_round_trip_cleanly() {
    let shared = session(&forge());
    let dispatch = prepare_conflict_dispatch_over_stdio(&shared);
    assert_eq!(dispatch["kind"], "conflict", "{dispatch:?}");
    assert_eq!(dispatch["threadIds"], json!([]), "{dispatch:?}");
    let prompt = dispatch["prompt"].as_str().expect("conflict prompt string");
    assert!(prompt.contains("src/a.rs"), "{prompt}");

    let confirm_written = confirm_conflict_round_over_stdio(&shared, prompt);
    assert!(
        confirm_written
            .iter()
            .all(|message| message["params"]["type"] != "threadsChanged"),
        "{confirm_written:?}"
    );
    let agent_round_index = confirm_written
        .iter()
        .position(|message| message["params"]["type"] == "agentRound")
        .expect("an agentRound event");
    let answer_index = confirm_written
        .iter()
        .position(|message| message["id"] == 3)
        .unwrap();
    assert!(agent_round_index < answer_index, "{confirm_written:?}");
    let round_result = &response(&confirm_written, 3)["result"]["round"];
    assert_eq!(round_result["kind"], "conflict", "{confirm_written:?}");
    assert_eq!(round_result["threadIds"], json!([]));
    assert_eq!(round_result["prompt"], prompt);
}

#[cfg(unix)]
struct TempSocketGuard(std::path::PathBuf);

#[cfg(unix)]
impl Drop for TempSocketGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

#[cfg(unix)]
fn create_temp_socket_path() -> TempSocketGuard {
    use std::sync::atomic::AtomicU64;

    static NEXT_SERVE_SOCKET_ID: AtomicU64 = AtomicU64::new(1);
    let sequence = NEXT_SERVE_SOCKET_ID.fetch_add(1, Ordering::Relaxed);
    TempSocketGuard(std::path::PathBuf::from(format!(
        "/tmp/jpr-serve-v5-{}-{sequence}.sock",
        std::process::id()
    )))
}

#[cfg(unix)]
fn connect_unix_socket(socket_path: &std::path::Path) -> std::os::unix::net::UnixStream {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if let Ok(connected) = std::os::unix::net::UnixStream::connect(socket_path) {
            return connected;
        }
        assert!(Instant::now() < deadline, "timed out connecting to socket");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[cfg(unix)]
fn spawn_socket_test_server(
    socket_path: std::path::PathBuf,
    is_done: &Arc<AtomicBool>,
) -> std::thread::JoinHandle<anyhow::Result<()>> {
    let is_reader_done = Arc::clone(is_done);
    let shared = session(&forge());
    let serve_options = ServeOptions {
        socket_path: Some(socket_path),
        ..options(None)
    };
    std::thread::spawn(move || {
        let reader = BufReader::new(EndsWhen {
            done: move || is_reader_done.load(Ordering::Acquire),
            deadline: Instant::now() + Duration::from_secs(5),
        });
        serve(
            reader,
            &Arc::new(Mutex::new(Vec::<u8>::new())),
            &shared,
            &serve_options,
        )
    })
}

#[cfg(unix)]
fn assert_socket_refuses_method(stream: &mut std::os::unix::net::UnixStream, line: &str) {
    use std::io::{BufRead, Write};

    stream.write_all(line.as_bytes()).unwrap();
    stream.flush().unwrap();
    let mut raw_reply = String::new();
    BufReader::new(stream.try_clone().unwrap())
        .read_line(&mut raw_reply)
        .unwrap();
    let parsed: Value = serde_json::from_str(raw_reply.trim_end()).unwrap();
    assert_eq!(
        parsed["error"]["code"],
        RpcError::INVALID_REQUEST,
        "{parsed}"
    );
    assert!(
        parsed["error"]["message"]
            .as_str()
            .unwrap()
            .contains("not allowed on the Unix socket"),
        "{parsed}"
    );
}

#[cfg(unix)]
#[test]
fn unix_socket_refuses_push_and_prepare_conflict_resolution() {
    let socket_guard = create_temp_socket_path();
    let is_done = Arc::new(AtomicBool::new(false));
    let server_handle = spawn_socket_test_server(socket_guard.0.clone(), &is_done);
    let mut stream = connect_unix_socket(&socket_guard.0);
    assert_socket_refuses_method(&mut stream, &request(1, "push"));
    assert_socket_refuses_method(
        &mut stream,
        &build_request_with_params(
            2,
            "prepareConflictResolution",
            r#"{"paths":["src/a.rs"],"agent":"claude"}"#,
        ),
    );
    assert_socket_refuses_method(
        &mut stream,
        &build_request_with_params(
            3,
            "confirmSend",
            r#"{"round":1,"kind":"conflict","threadIds":[],"prompt":"Resolve src/a.rs"}"#,
        ),
    );
    drop(stream);
    is_done.store(true, Ordering::Release);
    server_handle.join().unwrap().unwrap();
}
