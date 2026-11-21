//! The server end to end, over in-memory streams and the fake ports.

#[path = "serve/support.rs"]
mod support;

use std::io::{BufReader, Cursor};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use review_rpc::{ServeOptions, serve};
use serde_json::Value;

use support::{
    Closed, EndsWhen, build_request_with_params, changed_snapshot, event, forge, messages, options,
    request, response, run, session, synced_views,
};

#[test]
fn initialize_reports_the_protocol_and_server_versions() {
    let written = run(&request(1, "initialize"), &forge());
    let result = &response(&written, 1)["result"];
    assert_eq!(result["protocolVersion"], 3);
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
    assert_eq!(response(&written, 5)["result"]["protocolVersion"], 3);
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

fn assert_threads_changed_before(written: &[Value], request_id: u64) {
    let answer = written
        .iter()
        .position(|message| message["id"] == request_id)
        .unwrap_or_else(|| panic!("no response {request_id} in {written:?}"));
    let previous = written[..answer]
        .iter()
        .rposition(|message| message.get("id").is_some())
        .unwrap_or(0);
    let has_event = written[previous..answer]
        .iter()
        .any(|message| message["params"]["type"] == "threadsChanged");
    assert!(
        has_event,
        "expected threadsChanged before response {request_id} in {written:?}"
    );
}

#[test]
fn threads_mentions_comment_reply_and_edit_round_trip() {
    let input = request(1, "initialize")
        + &request(2, "sync")
        + &request(3, "threads")
        + &request(4, "mentions")
        + &build_request_with_params(
            5,
            "comment",
            r#"{"anchor":{"file":"src/a.rs","kind":"line","side":"RIGHT","start":1,"end":1},"body":"nit"}"#,
        )
        + &build_request_with_params(6, "reply", r#"{"threadId":"T1","body":"agreed"}"#)
        + &build_request_with_params(
            7,
            "editMessage",
            r#"{"messageId":"PRRC_fake_1","body":"updated nit"}"#,
        );
    let written = run(&input, &forge());

    assert_eq!(response(&written, 1)["result"]["protocolVersion"], 3);
    assert_eq!(response(&written, 3)["result"]["threads"][0]["id"], "T1");
    assert!(response(&written, 4)["result"]["candidates"].is_array());
    assert_eq!(
        response(&written, 5)["result"]["thread"]["id"],
        "PRRT_fake_1"
    );
    assert_eq!(
        response(&written, 6)["result"]["thread"]["messages"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        response(&written, 7)["result"]["thread"]["messages"][0]["body"],
        "updated nit"
    );
    for id in 5..=7 {
        assert_threads_changed_before(&written, id);
    }
}

#[test]
fn resolve_reaction_and_delete_round_trip() {
    let input = request(1, "sync")
        + &build_request_with_params(
            2,
            "comment",
            r#"{"anchor":{"file":"src/a.rs","kind":"line","side":"RIGHT","start":1,"end":1},"body":"nit"}"#,
        )
        + &build_request_with_params(3, "setResolved", r#"{"threadId":"T1","resolved":true}"#)
        + &build_request_with_params(
            4,
            "toggleReaction",
            r#"{"messageId":"T1-c1","content":"THUMBS_UP"}"#,
        )
        + &build_request_with_params(5, "deleteMessage", r#"{"messageId":"PRRC_fake_1"}"#);
    let written = run(&input, &forge());

    assert_eq!(
        response(&written, 3)["result"]["thread"]["state"],
        "resolved"
    );
    assert_eq!(
        response(&written, 4)["result"]["thread"]["messages"][0]["reactions"][0]["content"],
        "THUMBS_UP"
    );
    assert_eq!(response(&written, 5)["result"]["threadCount"], 1);
    for id in 2..=5 {
        assert_threads_changed_before(&written, id);
    }
}

#[test]
fn suggestions_anchored_lines_and_submit_round_trip() {
    let input = request(1, "sync")
        + &build_request_with_params(
            2,
            "anchoredLines",
            r#"{"anchor":{"file":"src/a.rs","kind":"line","side":"RIGHT","start":1,"end":1}}"#,
        )
        + &build_request_with_params(
            3,
            "suggestFromEdit",
            r#"{"path":"src/a.rs","editedText":"fn a() { 2 }\n","cursorLine":1,"commentBody":"use 2"}"#,
        )
        + &request(4, "submitPreview")
        + &build_request_with_params(5, "submitReview", r#"{"event":"APPROVE","body":"ship it"}"#);
    let written = run(&input, &forge());

    assert_eq!(response(&written, 2)["result"]["text"], "fn a() { 1 }");
    assert_eq!(
        response(&written, 3)["result"]["suggested"]["revertedText"],
        "fn a() { 1 }\n"
    );
    assert_eq!(response(&written, 4)["result"]["draftCount"], 1);
    assert_eq!(
        response(&written, 4)["result"]["canApproveOrRequestChanges"],
        true
    );
    assert_eq!(response(&written, 5)["result"]["draftCount"], 0);
    assert_threads_changed_before(&written, 3);
    assert_threads_changed_before(&written, 5);
}

#[test]
fn retry_message_round_trips_and_emits_threads_changed() {
    let forge = forge();
    let shared = session(&forge);
    let failed_id = {
        let mut guard = shared.lock().unwrap();
        guard.sync().unwrap();
        forge.reject_writes_with(Some("rejected"));
        let (thread, _) = guard
            .comment(review_model::Anchor::line("src/a.rs", 1), "nit")
            .unwrap();
        drop(guard);
        thread.messages[0].id.clone()
    };
    forge.reject_writes_with(None);
    let input = build_request_with_params(
        1,
        "retryMessage",
        &format!(r#"{{"messageId":"{failed_id}"}}"#),
    );
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    serve(Cursor::new(input), &output, &shared, &options(None)).unwrap();
    let written = support::messages(&output);
    assert_eq!(response(&written, 1)["result"]["draftCount"], 1);
    assert_threads_changed_before(&written, 1);
}
