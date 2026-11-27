//! Protocol v4, Unix domain socket server, and worktree watcher integration tests.

#[path = "rpc/support.rs"]
mod support;

use std::io::Cursor;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use review_rpc::{ServeOptions, serve};
use serde_json::json;

use support::{
    LiveServer, build_request_with_params, connect_socket, default_options, forge, request,
    response, run_script, socket_call, spawn_live_server, temp_socket_path, workspace_with_disk,
};

#[test]
fn socket_agent_reply_pushes_threads_changed_to_stdio_and_refuses_github_threads() {
    let socket_path = temp_socket_path();
    let (session, _) = workspace_with_disk(&forge());
    let options = ServeOptions {
        socket_path: Some(socket_path.0.clone()),
        ..default_options()
    };
    let server = spawn_live_server(session, options);
    server.send_line(&request(1, "sync"));
    server.recv_until_id(1);
    let local_comment = r#"{"anchor":{"file":"src/a.rs","kind":"line","side":"RIGHT","start":1,"end":1},"body":"Check","origin":"local"}"#;
    server.send_line(&build_request_with_params(2, "comment", local_comment));
    assert_eq!(
        server.recv_until_id(2).last().unwrap()["result"]["thread"]["id"],
        "loc-1"
    );

    let mut stream = connect_socket(&socket_path.0);
    assert_socket_refusals(&mut stream);
    assert_socket_allowed_calls(&mut stream, &server);

    server.send_line(&request(3, "shutdown"));
    server.recv_until_id(3);
    server.handle.join().unwrap().unwrap();
    assert!(!socket_path.0.exists(), "socket should be unlinked on exit");
}

fn assert_socket_refusals(stream: &mut UnixStream) {
    let github_error = socket_call(
        stream,
        &build_request_with_params(10, "agentReply", r#"{"threadId":"T1","body":"nope"}"#),
    );
    assert_eq!(github_error["error"]["code"], -32000);
    assert!(
        github_error["error"]["message"]
            .as_str()
            .unwrap()
            .contains("GitHub thread")
    );
    for (index, method) in [
        "initialize",
        "shutdown",
        "submitReview",
        "comment",
        "promoteThread",
        "sync",
        "setViewed",
    ]
    .iter()
    .enumerate()
    {
        let response = socket_call(stream, &request(20 + index as u64, method));
        assert_eq!(response["error"]["code"], -32600, "method {method}");
    }
}

fn assert_socket_allowed_calls(stream: &mut UnixStream, server: &LiveServer) {
    let snapshot_reply = socket_call(stream, &request(11, "snapshot"));
    assert_eq!(snapshot_reply["result"]["pr"]["number"], 7);

    let threads_reply = socket_call(stream, &request(14, "threads"));
    assert_ne!(
        threads_reply["result"]["threads"].as_array().unwrap().len(),
        0
    );

    let reply_response = socket_call(
        stream,
        &build_request_with_params(12, "agentReply", r#"{"threadId":"loc-1","body":"Fixed"}"#),
    );
    assert_eq!(
        reply_response["result"]["thread"]["agent"]["state"],
        "answered"
    );
    let pushed = server.recv_json();
    assert_eq!(pushed["method"], "event");
    assert_eq!(pushed["params"]["type"], "threadsChanged");
    assert_eq!(pushed["params"]["view"]["localUnsentCount"], 0);
    let agent_replied = server.recv_json();
    assert_eq!(agent_replied["method"], "event");
    assert_eq!(agent_replied["params"]["type"], "agentReplied");
    assert_eq!(agent_replied["params"]["threadId"], "loc-1");

    let prepass_body = r#"{"findings":[{"anchor":{"file":"src/a.rs","kind":"line","side":"RIGHT","start":1,"end":1},"body":"[low] nit"}]}"#;
    let prepass_reply = socket_call(
        stream,
        &build_request_with_params(13, "prepassWrite", prepass_body),
    );
    assert_eq!(prepass_reply["result"]["threads"][0]["id"], "loc-3");
    assert_eq!(server.recv_json()["params"]["type"], "threadsChanged");
    let prepass_event = server.recv_json();
    assert_eq!(prepass_event["params"]["type"], "agentPrepassWritten");
    assert_eq!(prepass_event["params"]["count"], 1);
}

#[test]
fn prepare_send_confirm_send_promote_and_prepass_write_work_over_rpc() {
    let input = build_agent_flow_requests();
    let written = run_script(&input, &forge());

    assert_eq!(response(&written, 2)["result"]["kind"], "codex");
    assert_eq!(response(&written, 3)["result"]["thread"]["id"], "loc-2");
    assert_eq!(response(&written, 4)["result"]["round"], 1);
    assert_eq!(
        response(&written, 4)["result"]["threadIds"],
        json!(["loc-2"])
    );
    assert_eq!(response(&written, 5)["result"]["round"]["round"], 1);
    assert_eq!(
        response(&written, 5)["result"]["view"]["localUnsentCount"],
        0
    );
    assert_eq!(response(&written, 6)["result"]["kind"], "prepass");
    assert_eq!(response(&written, 7)["result"]["threads"][0]["id"], "loc-3");
    assert_eq!(response(&written, 8)["result"]["localUnsentCount"], 0);
    assert_eq!(
        response(&written, 9)["result"]["thread"]["origin"],
        "github"
    );
}

fn build_agent_flow_requests() -> String {
    let local_comment = r#"{"anchor":{"file":"src/a.rs","kind":"line","side":"RIGHT","start":1,"end":1},"body":"Fix","origin":"local"}"#;
    let confirm = r#"{"round":1,"kind":"send","threadIds":["loc-2"],"prompt":"Reply to loc-2"}"#;
    let prepass = r#"{"findings":[{"anchor":{"file":"src/a.rs","kind":"line","side":"RIGHT","start":1,"end":1},"body":"[high] bug"}]}"#;
    let anchors = r#"{"path":"src/a.rs","updates":[{"threadId":"loc-2","start":1,"end":1}]}"#;
    let promote = r#"{"threadId":"loc-2","body":"Promoted finding"}"#;
    request(1, "sync")
        + &build_request_with_params(2, "prepareAgentLaunch", r#"{"agent":"codex"}"#)
        + &build_request_with_params(3, "comment", local_comment)
        + &build_request_with_params(4, "prepareSend", r#"{"agent":"claude"}"#)
        + &build_request_with_params(5, "confirmSend", confirm)
        + &build_request_with_params(6, "preparePrepass", r#"{"agent":"claude"}"#)
        + &build_request_with_params(7, "prepassWrite", prepass)
        + &build_request_with_params(8, "updateLocalAnchors", anchors)
        + &build_request_with_params(9, "promoteThread", promote)
}

#[test]
fn worktree_watcher_pushes_files_changed_event_when_disk_changes() {
    let (session, workspace) = workspace_with_disk(&forge());
    session.lock().unwrap().sync().unwrap();
    let options = ServeOptions {
        watch_every: Some(Duration::from_millis(25)),
        ..default_options()
    };
    let server = spawn_live_server(session, options);
    server.send_line(&request(1, "snapshot"));
    server.recv_until_id(1);

    workspace.write_disk("src/a.rs", b"fn a() { 2 }\nlet keep = true;\n");
    let pushed = server.recv_json();
    assert_eq!(pushed["method"], "event");
    assert_eq!(pushed["params"]["type"], "filesChanged");
    assert_eq!(pushed["params"]["paths"], json!(["src/a.rs"]));

    server.send_line(&request(2, "shutdown"));
    server.recv_until_id(2);
    server.handle.join().unwrap().unwrap();
}

#[test]
fn watch_ticks_do_not_retry_queued_ops_when_retry_every_is_none_or_long() {
    let fake_forge = forge();
    let (session, workspace) = workspace_with_disk(&fake_forge);
    {
        let mut guard = session.lock().unwrap();
        guard.sync().unwrap();
        fake_forge.fail_writes_with(Some("offline"));
        guard.set_viewed("src/a.rs", false).unwrap();
    }
    fake_forge.fail_writes_with(None);
    let options = ServeOptions {
        poll_every: Some(Duration::from_secs(10)),
        retry_every: None,
        watch_every: Some(Duration::from_millis(25)),
        ..default_options()
    };
    let server = spawn_live_server(session, options);
    server.send_line(&request(1, "snapshot"));
    server.recv_until_id(1);

    workspace.write_disk("src/a.rs", b"fn a() { 3 }\n");
    assert_eq!(server.recv_json()["params"]["type"], "filesChanged");
    assert_eq!(fake_forge.viewed_calls(), Vec::new());

    server.send_line(&request(2, "shutdown"));
    server.recv_until_id(2);
    server.handle.join().unwrap().unwrap();
}

#[test]
fn zero_intervals_disable_background_ticker_and_serve_cleanly() {
    let (session, _) = workspace_with_disk(&forge());
    let options = ServeOptions {
        poll_every: Some(Duration::ZERO),
        retry_every: Some(Duration::ZERO),
        watch_every: Some(Duration::ZERO),
        ..default_options()
    };
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    let input = request(1, "snapshot") + &request(2, "shutdown");
    serve(Cursor::new(input), &output, &session, &options).unwrap();
    let text = String::from_utf8(output.lock().unwrap().clone()).unwrap();
    assert_eq!(text.lines().count(), 2);
}
