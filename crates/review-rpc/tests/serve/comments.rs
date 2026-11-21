use std::io::Cursor;
use std::sync::{Arc, Mutex};

use review_core::fakes::{FakeForge, changed_file, github_thread, sample_pr};
use review_core::ports::ForgeSnapshot;
use review_model::{Anchor, MentionCandidate, ViewedState};
use review_rpc::serve;
use serde_json::{Value, json};

use super::support::{
    build_request_with_params, forge, messages, options, request, response, run, session,
};

fn forge_with_mentions() -> FakeForge {
    FakeForge::new(
        sample_pr(),
        ForgeSnapshot {
            head_sha: "abc123".into(),
            has_pending_review: false,
            threads: vec![github_thread("T1", "src/a.rs")],
            files: vec![changed_file("src/a.rs", ViewedState::Viewed)],
            mention_candidates: vec![
                MentionCandidate {
                    login: "alice".into(),
                    is_participant: true,
                },
                MentionCandidate {
                    login: "bob".into(),
                    is_participant: false,
                },
            ],
            ..ForgeSnapshot::default()
        },
    )
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
fn threads_and_mentions_return_synced_threads_and_seeded_candidates() {
    let input = request(1, "sync") + &request(2, "threads") + &request(3, "mentions");
    let written = run(&input, &forge_with_mentions());

    assert_eq!(response(&written, 2)["result"]["threads"][0]["id"], "T1");
    assert_eq!(
        response(&written, 3)["result"]["candidates"],
        json!([
            { "login": "alice", "isParticipant": true },
            { "login": "bob", "isParticipant": false },
        ])
    );
}

#[test]
fn comment_reply_and_edit_message_emit_threads_changed_before_responding() {
    let input = request(1, "sync")
        + &build_request_with_params(
            2,
            "comment",
            r#"{"anchor":{"file":"src/a.rs","kind":"line","side":"RIGHT","start":1,"end":1},"body":"nit"}"#,
        )
        + &build_request_with_params(3, "reply", r#"{"threadId":"T1","body":"agreed"}"#)
        + &build_request_with_params(
            4,
            "editMessage",
            r#"{"messageId":"PRRC_fake_1","body":"updated nit"}"#,
        );
    let written = run(&input, &forge());

    assert_eq!(
        response(&written, 2)["result"]["thread"]["id"],
        "PRRT_fake_1"
    );
    assert_eq!(
        response(&written, 3)["result"]["thread"]["messages"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        response(&written, 4)["result"]["thread"]["messages"][0]["body"],
        "updated nit"
    );
    for id in 2..=4 {
        assert_threads_changed_before(&written, id);
    }
}

#[test]
fn set_resolved_updates_thread_state_and_emits_threads_changed() {
    let input = request(1, "sync")
        + &build_request_with_params(2, "setResolved", r#"{"threadId":"T1","resolved":true}"#);
    let written = run(&input, &forge());

    assert_eq!(
        response(&written, 2)["result"]["thread"]["state"],
        "resolved"
    );
    assert_threads_changed_before(&written, 2);
}

#[test]
fn toggle_reaction_updates_reactions_and_emits_threads_changed() {
    let input = request(1, "sync")
        + &build_request_with_params(
            2,
            "toggleReaction",
            r#"{"messageId":"T1-c1","content":"THUMBS_UP"}"#,
        );
    let written = run(&input, &forge());

    assert_eq!(
        response(&written, 2)["result"]["thread"]["messages"][0]["reactions"][0]["content"],
        "THUMBS_UP"
    );
    assert_threads_changed_before(&written, 2);
}

#[test]
fn delete_message_removes_thread_and_emits_threads_changed() {
    let input = request(1, "sync")
        + &build_request_with_params(2, "deleteMessage", r#"{"messageId":"T1-c1"}"#);
    let written = run(&input, &forge());

    assert_eq!(response(&written, 2)["result"]["threadCount"], 0);
    assert_threads_changed_before(&written, 2);
}

#[test]
fn anchored_lines_returns_source_lines_for_anchor() {
    let input = request(1, "sync")
        + &build_request_with_params(
            2,
            "anchoredLines",
            r#"{"anchor":{"file":"src/a.rs","kind":"line","side":"RIGHT","start":1,"end":1}}"#,
        );
    let written = run(&input, &forge());

    assert_eq!(response(&written, 2)["result"]["text"], "fn a() { 1 }");
}

#[test]
fn suggest_from_edit_and_submit_review_publish_draft_and_emit_threads_changed() {
    let input = request(1, "sync")
        + &build_request_with_params(
            2,
            "suggestFromEdit",
            r#"{"path":"src/a.rs","editedText":"fn a() { 2 }\n","cursorLine":1,"commentBody":"use 2"}"#,
        )
        + &request(3, "submitPreview")
        + &build_request_with_params(4, "submitReview", r#"{"event":"APPROVE","body":"ship it"}"#);
    let written = run(&input, &forge());

    assert_eq!(
        response(&written, 2)["result"]["suggested"]["revertedText"],
        "fn a() { 1 }\n"
    );
    assert_eq!(response(&written, 3)["result"]["draftCount"], 1);
    assert_eq!(
        response(&written, 3)["result"]["canApproveOrRequestChanges"],
        true
    );
    assert_eq!(response(&written, 4)["result"]["draftCount"], 0);
    assert_threads_changed_before(&written, 2);
    assert_threads_changed_before(&written, 4);
}

#[test]
fn retry_message_flushes_failed_comment_and_emits_threads_changed() {
    let forge = forge();
    let shared = session(&forge);
    let failed_message_id = {
        let mut guard = shared.lock().unwrap();
        guard.sync().unwrap();
        forge.reject_writes_with(Some("rejected"));
        let (thread, _) = guard.comment(Anchor::line("src/a.rs", 1), "nit").unwrap();
        drop(guard);
        thread.messages[0].id.clone()
    };
    forge.reject_writes_with(None);
    let input = build_request_with_params(
        1,
        "retryMessage",
        &format!(r#"{{"messageId":"{failed_message_id}"}}"#),
    );
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    serve(Cursor::new(input), &output, &shared, &options(None)).unwrap();
    let written = messages(&output);
    assert_eq!(response(&written, 1)["result"]["draftCount"], 1);
    assert_threads_changed_before(&written, 1);
}
