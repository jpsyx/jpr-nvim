//! The server end to end, over in-memory streams and the fake ports.

#[path = "serve/poller.rs"]
mod poller;
#[path = "serve/support.rs"]
mod support;

use std::io::Cursor;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use review_rpc::serve;
use serde_json::Value;

use support::{
    Closed, build_request_with_params, changed_snapshot, event, forge, messages, options, request,
    response, run, session,
};

#[test]
fn initialize_reports_the_protocol_and_server_versions() {
    let written = run(&request(1, "initialize"), &forge());
    let result = &response(&written, 1)["result"];
    assert_eq!(result["protocolVersion"], 12);
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
        + &build_request_with_params(3, "setViewed", r#"{"path":"a"}"#)
        + &build_request_with_params(4, "prepareConflictResolution", "{}");
    let written = run(&input, &forge());
    for id in 1..=4 {
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
    assert_eq!(response(&written, 5)["result"]["protocolVersion"], 12);
}

#[test]
fn set_viewed_accepts_multiple_paths_and_emits_one_viewed_changed_event() {
    let forge = forge();
    forge.set_snapshot(changed_snapshot());
    let input = request(1, "sync")
        + &build_request_with_params(
            2,
            "setViewed",
            r#"{"paths":["src/a.rs","src/b.rs"],"viewed":true}"#,
        )
        + &build_request_with_params(3, "setViewed", r#"{"paths":[],"viewed":true}"#);
    let written = run(&input, &forge);
    assert_eq!(response(&written, 2)["result"]["viewedCount"], 2);
    let viewed_event_count = written
        .iter()
        .filter(|message| {
            message["method"] == "event" && message["params"]["type"] == "viewedChanged"
        })
        .count();
    assert_eq!(viewed_event_count, 1, "{written:?}");
    assert_eq!(response(&written, 3)["error"]["code"], -32602);
}

#[test]
fn stream_emits_stream_progress_notifications_in_order_before_the_response() {
    let forge = forge();
    forge.set_snapshot(changed_snapshot());
    let input =
        request(1, "sync") + &build_request_with_params(2, "stream", r#"{"mode":"unified"}"#);
    let written = run(&input, &forge);
    let response_index = written
        .iter()
        .position(|message| message["id"] == 2)
        .expect("a stream response");
    let progress_entries: Vec<(usize, Value)> = written
        .iter()
        .enumerate()
        .filter(|(_, message)| message["method"] == "streamProgress")
        .map(|(index, message)| (index, message["params"].clone()))
        .collect();
    assert_eq!(progress_entries.len(), 3, "{written:?}");
    for (index, _) in &progress_entries {
        assert!(
            *index < response_index,
            "streamProgress at {index} must arrive before stream response at {response_index}"
        );
    }
    let payloads: Vec<Value> = progress_entries
        .into_iter()
        .map(|(_, payload)| payload)
        .collect();
    assert_eq!(
        payloads,
        vec![
            serde_json::json!({ "completed": 0, "total": 2, "path": "" }),
            serde_json::json!({ "completed": 1, "total": 2, "path": "src/a.rs" }),
            serde_json::json!({ "completed": 2, "total": 2, "path": "src/b.rs" }),
        ]
    );
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
fn set_collapsed_returns_the_view_without_an_event() {
    let input = request(1, "sync")
        + &build_request_with_params(2, "setCollapsed", r#"{"path":"src","collapsed":true}"#);
    let written = run(&input, &forge());
    let sync_answer = written
        .iter()
        .position(|message| message["id"] == 1)
        .unwrap();
    let collapse_answer = written
        .iter()
        .position(|message| message["id"] == 2)
        .unwrap();
    assert!(
        written[sync_answer + 1..collapse_answer]
            .iter()
            .all(|message| message["method"] != "event"),
        "setCollapsed announces no event: {written:?}"
    );
    assert_eq!(
        response(&written, 2)["result"]["collapsedDirs"],
        serde_json::json!(["src"])
    );
}

#[test]
fn set_collapsed_rejects_an_unsafe_path() {
    let input =
        build_request_with_params(1, "setCollapsed", r#"{"path":"../src","collapsed":true}"#)
            + &build_request_with_params(2, "setCollapsed", r#"{"collapsed":true}"#)
            + &request(3, "snapshot");
    let written = run(&input, &forge());
    assert_eq!(response(&written, 1)["error"]["code"], -32602);
    assert_eq!(response(&written, 2)["error"]["code"], -32602);
    assert!(
        response(&written, 3)["result"]
            .get("collapsedDirs")
            .is_none()
    );
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

#[path = "serve/comments.rs"]
mod comments;
#[path = "serve/polish.rs"]
mod polish;
#[path = "serve/refresh_worktree.rs"]
mod refresh_worktree;
