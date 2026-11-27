//! The on-disk format's tests: round trips, versions, and defaults.

use std::collections::{BTreeMap, BTreeSet};

use review_core::fakes::{changed_file, sample_pr};
use review_core::ports::{LocalStoreState, SyncRegistry};
use review_model::{AgentKind, AgentThreadState, Anchor, Message, Origin, Thread, ThreadState};
use serde_json::{Value, json};

use super::*;

fn session() -> SessionRecord {
    SessionRecord {
        pid: Some(42),
        worktree: Some("/tmp/widgets-worktrees/pr-7".into()),
        pr: Some(sample_pr()),
        last_synced_at: Some(100),
        socket: Some("/tmp/jpr.sock".into()),
        agent_session_id: Some("11111111-2222-3333-4444-555555555555".into()),
        agent_kind: Some(AgentKind::Codex),
    }
}

fn as_json(bytes: &[u8]) -> Value {
    serde_json::from_slice(bytes).unwrap()
}

#[test]
fn a_session_round_trips_inside_a_version_3_envelope() {
    let bytes = encode_session(&session()).unwrap();
    let encoded_json = as_json(&bytes);
    assert_eq!(encoded_json["version"], json!(3));
    assert_eq!(encoded_json["pr"]["headSha"], json!("abc123"));
    assert_eq!(encoded_json["pr"]["baseSha"], json!("base000"));
    assert_eq!(encoded_json["pr"]["body"], json!("Fixes the widget crash."));
    assert_eq!(encoded_json["socket"], json!("/tmp/jpr.sock"));
    assert_eq!(
        encoded_json["agentSessionId"],
        json!("11111111-2222-3333-4444-555555555555")
    );
    assert_eq!(encoded_json["agentKind"], json!("codex"));
    assert_eq!(decode_session(&bytes).unwrap(), session());
}

#[test]
fn a_version_1_and_2_session_load_with_empty_agent_fields() {
    let v1 = decode_session(
        br#"{"version": 1, "pr": {"owner": "octo", "number": 7, "headSha": "abc123"}}"#,
    )
    .unwrap();
    let pr = v1.pr.unwrap();
    assert_eq!((pr.head_sha.as_str(), pr.base_sha.as_str()), ("abc123", ""));
    assert_eq!(pr.body, "");
    assert_eq!(v1.socket, None);
    assert_eq!(v1.agent_session_id, None);
    assert_eq!(v1.agent_kind, None);

    let v2 = decode_session(
        br#"{"version": 2, "pid": 7, "pr": {"owner": "octo", "number": 7, "baseSha": "base000"}}"#,
    )
    .unwrap();
    assert_eq!(v2.pid, Some(7));
    assert_eq!(v2.socket, None);
    assert_eq!(v2.agent_session_id, None);
    assert_eq!(v2.agent_kind, None);
}

#[test]
fn the_viewed_file_is_a_version_1_envelope_around_the_files() {
    let files = vec![changed_file("src/a.rs", ViewedState::Viewed)];
    let bytes = encode_files(&files).unwrap();
    assert_eq!(
        as_json(&bytes),
        json!({
            "version": 1,
            "files": [{ "path": "src/a.rs", "additions": 3, "deletions": 1, "viewed": "VIEWED" }],
        })
    );
    assert!(bytes.ends_with(b"}\n"));
    assert_eq!(decode_files(&bytes).unwrap(), files);
}

#[test]
fn the_github_file_is_a_version_2_envelope_around_the_registry() {
    let registry = SyncRegistry {
        queued_viewed: BTreeMap::from([("src/a.rs".to_owned(), false)]),
        ..SyncRegistry::default()
    };
    let bytes = encode_registry(&registry).unwrap();
    let encoded_json = as_json(&bytes);
    assert_eq!(encoded_json["version"], json!(2));
    assert_eq!(encoded_json["queuedViewed"], json!({ "src/a.rs": false }));
    assert_eq!(decode_registry(&bytes).unwrap(), registry);
}

#[test]
fn a_github_file_newer_than_version_2_is_refused() {
    let error = decode_registry(br#"{"version": 99}"#).unwrap_err();
    let message = format!("{error:#}");
    assert!(
        message.contains("version 99") && message.contains("version 2"),
        "{message}"
    );
}

#[test]
fn the_local_file_round_trips_v1_and_refuses_version_9() {
    let local = LocalStoreState {
        next_local_id: 4,
        next_round: 2,
        threads: vec![Thread {
            id: "loc-1".into(),
            origin: Origin::Local,
            anchor: Anchor::line("src/a.rs", 10),
            state: ThreadState::Open,
            outdated: false,
            messages: vec![Message::create_with_sync(
                "loc-m-1",
                "reviewer",
                "Check bounds",
                "2026-11-21T00:00:00Z",
                None,
            )],
            agent: Some(AgentThreadState::Sent { round: 1 }),
            promoted_to: Some("PRRT_promoted".into()),
        }],
        local_viewed: BTreeMap::from([("src/local.rs".to_owned(), ViewedState::Viewed)]),
        collapsed_dirs: BTreeSet::from(["src/core".to_owned()]),
    };
    let bytes = encode_local(&local).unwrap();
    let encoded_json = as_json(&bytes);
    assert_eq!(encoded_json["version"], json!(1));
    assert_eq!(encoded_json["nextLocalId"], json!(4));
    assert_eq!(encoded_json["nextRound"], json!(2));
    assert_eq!(encoded_json["threads"][0]["agent"]["state"], json!("sent"));
    assert_eq!(encoded_json["threads"][0]["agent"]["round"], json!(1));
    assert_eq!(
        encoded_json["threads"][0]["promotedTo"],
        json!("PRRT_promoted")
    );
    assert_eq!(encoded_json["collapsedDirs"], json!(["src/core"]));
    assert_eq!(decode_local(&bytes).unwrap(), local);

    let error = decode_local(br#"{"version": 9}"#).unwrap_err();
    let message = format!("{error:#}");
    assert!(
        message.contains("version 9") && message.contains("version 1"),
        "{message}"
    );
}

#[test]
fn local_json_v1_without_local_viewed_deserializes() {
    let raw = br#"{"version": 1, "nextLocalId": 2, "nextRound": 1, "threads": []}"#;
    let decoded = decode_local(raw).expect("v1 local.json without localViewed decodes");
    assert_eq!(decoded.next_local_id, 2);
    assert_eq!(decoded.next_round, 1);
    assert_eq!(decoded.threads, Vec::new());
    assert!(decoded.local_viewed.is_empty());
    assert!(decoded.collapsed_dirs.is_empty());
}

fn create_sample_queued_ops() -> Vec<review_core::ports::QueuedCommentOp> {
    use review_core::ports::QueuedCommentOp;
    use review_model::{Anchor, ReviewEvent};

    vec![
        QueuedCommentOp::CreateReviewThread {
            temp_thread_id: "tmp-t-1".into(),
            temp_message_id: "tmp-m-1".into(),
            anchor: Anchor::line("src/a.rs", 3),
            body: "nit".into(),
        },
        QueuedCommentOp::ReplyToThread {
            thread_id: "PRRT_1".into(),
            root_database_id: None,
            temp_message_id: "tmp-m-2".into(),
            body: "reply".into(),
        },
        QueuedCommentOp::SubmitReview {
            event: ReviewEvent::Comment,
            body: "looks close".into(),
        },
    ]
}

fn create_populated_registry_from_base(mut registry: SyncRegistry) -> SyncRegistry {
    use review_model::{
        Anchor, MentionCandidate, Message, MessageSync, Origin, Reaction, ReactionContent, Thread,
        ThreadState,
    };

    let mut message = Message::create_with_sync(
        "tmp-m-1",
        "alice",
        "nit",
        "2026-11-20T00:00:00Z",
        Some(MessageSync::Queued),
    );
    message.viewer_did_author = true;
    message.reactions.push(Reaction {
        content: ReactionContent::ThumbsUp,
        count: 1,
        viewer_has_reacted: true,
    });
    registry.pending_review_id = Some("PRR_1".into());
    registry.viewer_login = Some("alice".into());
    registry.next_temp_id = 2;
    registry.id_map.insert("tmp-t-1".into(), "PRRT_real".into());
    registry
        .agreed_bodies
        .insert("IC_1".into(), "original".into());
    registry.threads.push(Thread {
        id: "tmp-t-1".into(),
        origin: Origin::Github,
        anchor: Anchor::line("src/a.rs", 3),
        state: ThreadState::Open,
        outdated: false,
        messages: vec![message],
        agent: None,
        promoted_to: None,
    });
    registry.queued_ops = create_sample_queued_ops();
    registry.mention_candidates.push(MentionCandidate {
        login: "bob".into(),
        is_participant: true,
    });
    registry
}

#[test]
fn github_v1_reads_with_default_comment_fields_and_round_trips_as_v2() {
    let v1 = br#"{"version": 1, "queuedViewed": {"src/a.rs": true}}"#;
    let decoded = decode_registry(v1).expect("v1 github.json still decodes");
    assert_eq!(decoded.queued_viewed.get("src/a.rs"), Some(&true));
    assert_eq!(decoded.threads, Vec::new());
    assert_eq!(decoded.queued_ops, Vec::new());

    let registry = create_populated_registry_from_base(decoded);
    let encoded = encode_registry(&registry).expect("v2 encodes");
    assert_eq!(stored_version(&encoded).unwrap(), 2);
    let json_value = as_json(&encoded);
    assert_eq!(json_value["queuedOps"][0]["op"], "createReviewThread");
    assert_eq!(json_value["queuedOps"][0]["tempThreadId"], "tmp-t-1");
    assert_eq!(json_value["queuedOps"][0]["tempMessageId"], "tmp-m-1");
    assert_eq!(json_value["queuedOps"][1]["op"], "replyToThread");
    assert_eq!(json_value["queuedOps"][1]["threadId"], "PRRT_1");
    assert_eq!(json_value["queuedOps"][1]["tempMessageId"], "tmp-m-2");
    assert!(json_value["queuedOps"][1].get("rootDatabaseId").is_none());
    assert_eq!(json_value["queuedOps"][2]["op"], "submitReview");
    assert_eq!(decode_registry(&encoded).unwrap(), registry);
}

#[test]
fn a_newer_version_is_refused_naming_both_versions() {
    let error = decode_files(br#"{"version": 2, "files": []}"#).unwrap_err();
    let message = format!("{error:#}");
    assert!(
        message.contains("version 2") && message.contains("version 1"),
        "{message}"
    );
    assert!(!message.contains("delete"), "{message}");
}

#[test]
fn an_unknown_older_version_is_refused() {
    let error = decode_session(br#"{"version": 0}"#).unwrap_err();
    assert!(format!("{error:#}").contains("version 0"), "{error:#}");
    assert!(format!("{error:#}").contains("1 to 3"), "{error:#}");
}

#[test]
fn a_session_newer_than_version_3_is_refused() {
    let error = decode_session(br#"{"version": 4}"#).unwrap_err();
    let message = format!("{error:#}");
    assert!(
        message.contains("version 4") && message.contains("version 3"),
        "{message}"
    );
}

#[test]
fn a_file_without_a_version_is_refused() {
    let error = decode_files(b"[]").unwrap_err();
    assert!(format!("{error:#}").contains("fix or delete"), "{error:#}");
}

#[test]
fn an_old_file_missing_newer_fields_loads_with_defaults() {
    let files = decode_files(br#"{"version": 1, "files": [{"path": "src/a.rs"}]}"#).unwrap();
    assert_eq!(files[0].path, "src/a.rs");
    assert_eq!(
        (files[0].additions, files[0].viewed),
        (0, ViewedState::Unviewed)
    );
    let record =
        decode_session(br#"{"version": 1, "pr": {"owner": "octo", "number": 7}}"#).unwrap();
    let pr = record.pr.unwrap();
    assert_eq!(
        (pr.owner.as_str(), pr.number, pr.node_id.as_str()),
        ("octo", 7, "")
    );
    assert_eq!(record.last_synced_at, None);
}

#[test]
fn stored_version_reads_only_the_version() {
    assert_eq!(
        stored_version(br#"{"version": 3, "files": "anything"}"#).unwrap(),
        3
    );
}

#[test]
fn only_a_newer_version_blocks_an_overwrite() {
    assert!(refuse_newer(2, 1).is_err());
    assert!(refuse_newer(1, 1).is_ok());
    assert!(refuse_newer(0, 1).is_ok());
}
