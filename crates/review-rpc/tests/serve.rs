//! The server end to end, over in-memory streams and the fake ports.

#[path = "serve/support.rs"]
mod support;

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

use support::{
    Closed, EndsWhen, build_request_with_params, changed_snapshot, event, forge, messages, options,
    request, response, run, session, synced_views,
};

#[test]
fn initialize_reports_the_protocol_and_server_versions() {
    let written = run(&request(1, "initialize"), &forge());
    let result = &response(&written, 1)["result"];
    assert_eq!(result["protocolVersion"], 5);
    assert_eq!(result["version"], "9.9.9");
}

#[test]
fn snapshot_before_any_sync_is_empty() {
    let written = run(&request(1, "snapshot"), &forge());
    let result = &response(&written, 1)["result"];
    assert_eq!(result["sync"]["state"], "never");
    assert_eq!(result["files"], serde_json::json!([]));
}

#[test]
fn sync_answers_with_the_view_and_announces_it() {
    let written = run(&request(1, "sync"), &forge());
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
    let written = run(&request(1, "sync"), &forge);
    let error = &response(&written, 1)["error"];
    assert_eq!(error["code"], -32000);
    assert!(error["message"].as_str().unwrap().contains("offline"));
    assert_eq!(event(&written)["params"]["type"], "syncFailed");
}

#[test]
fn unknown_methods_and_bad_json_get_error_responses() {
    let written = run(&format!("{}{{oops\n", request(1, "frobnicate")), &forge());
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
    );
    assert_eq!(response(&written, 1)["result"], Value::Null);
    assert!(
        written.iter().all(|message| message["id"] != 2),
        "{written:?}"
    );
}

#[test]
fn file_diff_answers_with_the_files_diff() {
    let input =
        request(1, "sync") + &build_request_with_params(2, "fileDiff", r#"{"path":"src/a.rs"}"#);
    let written = run(&input, &forge());
    let diff = &response(&written, 2)["result"];
    assert_eq!(diff["path"], "src/a.rs");
    assert_eq!(diff["added"][0]["line"], 1);
    assert_eq!(diff["baseText"], "fn a() {}\n");
}

#[test]
fn stream_answers_in_the_requested_mode() {
    let input = request(1, "sync") + &build_request_with_params(2, "stream", r#"{"mode":"split"}"#);
    let written = run(&input, &forge());
    let stream = &response(&written, 2)["result"];
    assert_eq!(stream["mode"], "split");
    assert_eq!(stream["rows"][0]["kind"], "file");
}

#[test]
fn set_viewed_announces_the_change_before_answering() {
    let input = request(1, "sync")
        + &build_request_with_params(2, "setViewed", r#"{"path":"src/a.rs","viewed":false}"#);
    let written = run(&input, &forge());
    let changed = written
        .iter()
        .position(|message| message["params"]["type"] == "viewedChanged")
        .expect("a viewedChanged event");
    let answer = written
        .iter()
        .position(|message| message["id"] == 2)
        .unwrap();
    assert!(changed < answer, "the event comes first");
    assert_eq!(
        response(&written, 2)["result"]["files"][0]["viewed"],
        "UNVIEWED"
    );
}

#[test]
fn bad_params_are_invalid_params_errors() {
    let input = build_request_with_params(1, "stream", r#"{"mode":"sideways"}"#)
        + &build_request_with_params(2, "fileDiff", "{}")
        + &build_request_with_params(3, "setViewed", r#"{"path":"a"}"#);
    let written = run(&input, &forge());
    for id in 1..=3 {
        assert_eq!(
            response(&written, id)["error"]["code"],
            -32602,
            "request {id}"
        );
    }
}

#[test]
fn missing_or_mistyped_params_are_errors_and_serving_goes_on() {
    let input = request(1, "fileDiff")
        + &build_request_with_params(2, "setViewed", r#"{"path":"src/a.rs","viewed":"yes"}"#)
        + &build_request_with_params(3, "stream", r#"["split"]"#)
        + &build_request_with_params(4, "fileDiff", r#"{"path":null}"#)
        + &request(5, "initialize");
    let written = run(&input, &forge());
    for id in 1..=4 {
        let error = &response(&written, id)["error"];
        assert_eq!(error["code"], -32602, "request {id}");
        assert!(
            error["message"].as_str().unwrap().contains("expected"),
            "{error}"
        );
    }
    assert_eq!(response(&written, 5)["result"]["protocolVersion"], 5);
}

#[test]
fn an_engine_failure_in_a_new_method_is_an_engine_error() {
    let written = run(
        &build_request_with_params(1, "stream", r#"{"mode":"unified"}"#),
        &forge(),
    );
    let error = &response(&written, 1)["error"];
    assert_eq!(error["code"], -32000);
    assert!(
        error["message"].as_str().unwrap().contains("not synced"),
        "{error}"
    );
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
fn the_poller_retries_a_refused_viewed_mark_between_syncs() {
    let forge = forge();
    let shared = session(&forge);
    {
        let mut session = shared.lock().unwrap();
        session.sync().unwrap();
        forge.fail_writes_with(Some("offline"));
        session.set_viewed("src/a.rs", false).unwrap();
    }
    forge.fail_writes_with(None);
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    let watched = forge.clone();
    let reader = BufReader::new(EndsWhen {
        done: move || !watched.viewed_calls().is_empty(),
        deadline: Instant::now() + Duration::from_secs(10),
    });
    let options = ServeOptions {
        retry_every: Some(Duration::from_millis(20)),
        ..options(Some(Duration::from_secs(3600)))
    };
    serve(reader, &output, &shared, &options).unwrap();
    assert_eq!(forge.viewed_calls(), [("src/a.rs".to_owned(), false)]);
    assert_eq!(forge.fetches(), 1, "it retried without syncing again");
    assert!(
        messages(&output)
            .iter()
            .any(|message| message["params"]["type"] == "viewedChanged"),
        "the landed mark is announced"
    );
}

#[test]
fn the_poller_announces_each_sync_while_the_client_is_connected() {
    let forge = forge();
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    let announced_while_open = Arc::new(AtomicBool::new(false));
    let (watched, written, announced) = (
        forge.clone(),
        Arc::clone(&output),
        Arc::clone(&announced_while_open),
    );
    // Once the first poll is announced the forge changes, and the reader
    // stays open until a later poll announces the change.
    let reader = BufReader::new(EndsWhen {
        done: move || {
            let views = synced_views(&written);
            if views.is_empty() {
                return false;
            }
            watched.set_snapshot(changed_snapshot());
            let has_changed = views.iter().any(|view| {
                view["files"]
                    .as_array()
                    .is_some_and(|files| files.len() == 2)
            });
            announced.store(has_changed, Ordering::SeqCst);
            has_changed
        },
        deadline: Instant::now() + Duration::from_secs(10),
    });
    serve(
        reader,
        &output,
        &session(&forge),
        &options(Some(Duration::from_millis(20))),
    )
    .unwrap();
    assert!(
        announced_while_open.load(Ordering::SeqCst),
        "{:?}",
        messages(&output)
    );
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
    let result = &response(&written, 1)["result"];
    assert_eq!(result["isPushed"], true, "{written:?}");
    assert_eq!(result["headSha"], "def456", "{written:?}");
}

#[test]
fn prepare_conflict_resolution_and_confirm_send_round_trip_cleanly() {
    let shared = session(&forge());
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    let prepare_input = request(1, "sync")
        + &build_request_with_params(
            2,
            "prepareConflictResolution",
            r#"{"paths":["src/a.rs"],"agent":"claude"}"#,
        );
    serve(Cursor::new(prepare_input), &output, &shared, &options(None)).unwrap();
    let prepare_written = messages(&output);
    let dispatch = &response(&prepare_written, 2)["result"];
    assert_eq!(dispatch["kind"], "conflict", "{prepare_written:?}");
    assert_eq!(dispatch["threadIds"], json!([]), "{prepare_written:?}");
    let prompt = dispatch["prompt"].as_str().expect("conflict prompt string");
    assert!(prompt.contains("src/a.rs"), "{prompt}");

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
        &shared,
        &options(None),
    )
    .unwrap();
    let confirm_written = messages(&confirm_output);
    let round_result = &response(&confirm_written, 3)["result"]["round"];
    assert_eq!(round_result["kind"], "conflict", "{confirm_written:?}");
    assert_eq!(round_result["threadIds"], json!([]));
    assert_eq!(round_result["prompt"], prompt);
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
    use std::os::unix::net::UnixStream;
    use std::path::PathBuf;

    let socket_path = PathBuf::from(format!("/tmp/jpr-serve-v5-{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&socket_path);
    let done = Arc::new(AtomicBool::new(false));
    let reader_done = Arc::clone(&done);
    let shared = session(&forge());
    let serve_options = ServeOptions {
        socket_path: Some(socket_path.clone()),
        ..options(None)
    };
    let server_handle = std::thread::spawn(move || {
        let reader = BufReader::new(EndsWhen {
            done: move || reader_done.load(Ordering::Acquire),
            deadline: Instant::now() + Duration::from_secs(5),
        });
        serve(
            reader,
            &Arc::new(Mutex::new(Vec::<u8>::new())),
            &shared,
            &serve_options,
        )
    });
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut stream = loop {
        if let Ok(connected) = UnixStream::connect(&socket_path) {
            break connected;
        }
        assert!(Instant::now() < deadline, "timed out connecting to socket");
        std::thread::sleep(Duration::from_millis(10));
    };
    assert_socket_refuses_method(&mut stream, &request(1, "push"));
    assert_socket_refuses_method(
        &mut stream,
        &build_request_with_params(
            2,
            "prepareConflictResolution",
            r#"{"paths":["src/a.rs"],"agent":"claude"}"#,
        ),
    );
    drop(stream);
    done.store(true, Ordering::Release);
    server_handle.join().unwrap().unwrap();
}

#[path = "serve/comments.rs"]
mod comments;
