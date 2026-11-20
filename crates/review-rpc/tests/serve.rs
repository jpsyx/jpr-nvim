//! The server end to end, over in-memory streams and the fake ports.

use std::io::{BufReader, Cursor, Read};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use review_core::ReviewSession;
use review_core::fakes::{
    FakeForge, FixedClock, MemoryStore, changed_file, github_thread, sample_pr,
};
use review_core::ports::ForgeSnapshot;
use review_model::ViewedState;
use review_rpc::{ServeOptions, serve};
use serde_json::Value;

fn forge() -> FakeForge {
    FakeForge::new(
        sample_pr(),
        ForgeSnapshot {
            head_sha: "abc123".into(),
            has_pending_review: false,
            threads: vec![github_thread("T1", "src/a.rs")],
            files: vec![changed_file("src/a.rs", ViewedState::Viewed)],
        },
    )
}

fn session(forge: &FakeForge) -> Arc<Mutex<ReviewSession>> {
    let session = ReviewSession::open(
        7,
        Box::new(forge.clone()),
        Box::new(MemoryStore::default()),
        Box::new(FixedClock::at(100)),
    )
    .unwrap();
    Arc::new(Mutex::new(session))
}

fn options(poll_every: Option<Duration>) -> ServeOptions {
    ServeOptions {
        server_version: "9.9.9".into(),
        poll_every,
    }
}

fn request(id: u64, method: &str) -> String {
    format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"{method}\"}}\n")
}

fn messages(output: &Mutex<Vec<u8>>) -> Vec<Value> {
    let bytes = output.lock().unwrap().clone();
    String::from_utf8(bytes)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// Serves `input` and returns what was written, waiting up to a second for
/// `expected` messages because events arrive from another thread.
fn run(input: &str, forge: &FakeForge, expected: usize) -> Vec<Value> {
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    serve(
        Cursor::new(input.to_owned()),
        &output,
        &session(forge),
        &options(None),
    )
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        let written = messages(&output);
        if written.len() >= expected || Instant::now() > deadline {
            return written;
        }
        thread::sleep(Duration::from_millis(10));
    }
}

fn response(messages: &[Value], id: u64) -> &Value {
    messages
        .iter()
        .find(|message| message["id"] == id)
        .unwrap_or_else(|| panic!("no response {id} in {messages:?}"))
}

fn event(messages: &[Value]) -> &Value {
    messages
        .iter()
        .find(|message| message["method"] == "event")
        .unwrap_or_else(|| panic!("no event in {messages:?}"))
}

#[test]
fn initialize_reports_the_protocol_and_server_versions() {
    let written = run(&request(1, "initialize"), &forge(), 1);
    let result = &response(&written, 1)["result"];
    assert_eq!(result["protocolVersion"], 1);
    assert_eq!(result["version"], "9.9.9");
}

#[test]
fn snapshot_before_any_sync_is_empty() {
    let written = run(&request(1, "snapshot"), &forge(), 1);
    let result = &response(&written, 1)["result"];
    assert_eq!(result["sync"]["state"], "never");
    assert_eq!(result["files"], serde_json::json!([]));
}

#[test]
fn sync_answers_with_the_view_and_announces_it() {
    let written = run(&request(1, "sync"), &forge(), 2);
    let result = &response(&written, 1)["result"];
    assert_eq!(result["files"][0]["path"], "src/a.rs");
    assert_eq!(result["files"][0]["threads"], 1);
    assert_eq!(
        result["sync"],
        serde_json::json!({ "state": "synced", "at": 100 })
    );
    assert_eq!(event(&written)["params"]["type"], "synced");
}

#[test]
fn a_failed_sync_is_an_engine_error_and_an_event() {
    let forge = forge();
    forge.fail_with(Some("offline"));
    let written = run(&request(1, "sync"), &forge, 2);
    let error = &response(&written, 1)["error"];
    assert_eq!(error["code"], -32000);
    assert!(error["message"].as_str().unwrap().contains("offline"));
    assert_eq!(event(&written)["params"]["type"], "syncFailed");
}

#[test]
fn unknown_methods_and_bad_json_get_error_responses() {
    let written = run(
        &format!("{}{{oops\n", request(1, "frobnicate")),
        &forge(),
        2,
    );
    assert_eq!(response(&written, 1)["error"]["code"], -32601);
    let parse_error = written
        .iter()
        .find(|message| message["id"].is_null())
        .unwrap();
    assert_eq!(parse_error["error"]["code"], -32700);
}

#[test]
fn shutdown_answers_and_stops_reading() {
    let written = run(
        &format!("{}{}", request(1, "shutdown"), request(2, "initialize")),
        &forge(),
        2,
    );
    assert_eq!(response(&written, 1)["result"], Value::Null);
    assert!(
        written.iter().all(|message| message["id"] != 2),
        "{written:?}"
    );
}

/// A reader that keeps the server running until `done` holds or `deadline`
/// passes, so a test waits on what it expects instead of a fixed window.
struct EndsWhen<F: Fn() -> bool> {
    done: F,
    deadline: Instant,
}

impl<F: Fn() -> bool> Read for EndsWhen<F> {
    fn read(&mut self, _buffer: &mut [u8]) -> std::io::Result<usize> {
        while !(self.done)() && Instant::now() < self.deadline {
            thread::sleep(Duration::from_millis(5));
        }
        Ok(0)
    }
}

#[test]
fn the_poller_syncs_in_the_background() {
    let forge = forge();
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    let watched = forge.clone();
    let reader = BufReader::new(EndsWhen {
        done: move || watched.fetches() >= 2,
        deadline: Instant::now() + Duration::from_secs(10),
    });
    serve(
        reader,
        &output,
        &session(&forge),
        &options(Some(Duration::from_millis(20))),
    )
    .unwrap();
    assert!(forge.fetches() >= 2, "fetched {} times", forge.fetches());
}

#[test]
fn shutdown_waits_for_every_event_to_be_written() {
    let input = format!(
        "{}{}{}",
        request(1, "initialize"),
        request(2, "sync"),
        request(3, "shutdown")
    );
    for attempt in 0..200 {
        let output = Arc::new(Mutex::new(Vec::<u8>::new()));
        serve(
            Cursor::new(input.clone()),
            &output,
            &session(&forge()),
            &options(None),
        )
        .unwrap();
        let written = messages(&output);
        let synced = written
            .iter()
            .position(|message| message["params"]["type"] == "synced");
        let shutdown = written.iter().position(|message| message["id"] == 3);
        assert!(
            matches!((synced, shutdown), (Some(event), Some(answer)) if event < answer),
            "attempt {attempt}: {written:?}"
        );
    }
}

/// A writer whose reader has gone away.
struct Closed;

impl std::io::Write for Closed {
    fn write(&mut self, _buffer: &[u8]) -> std::io::Result<usize> {
        Err(std::io::ErrorKind::BrokenPipe.into())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
fn a_closed_output_ends_serving_with_an_error() {
    let input = format!("{}{}", request(1, "sync"), request(2, "shutdown"));
    let result = serve(
        Cursor::new(input),
        &Arc::new(Mutex::new(Closed)),
        &session(&forge()),
        &options(Some(Duration::from_millis(1))),
    );
    assert!(result.is_err());
}
