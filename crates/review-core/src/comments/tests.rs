use std::collections::BTreeMap;

use review_model::{
    Anchor, AnchorKind, Message, MessageSync, Origin, Reaction, ReactionContent, Side, Thread,
    ThreadState,
};

use super::*;
use crate::ports::QueuedCommentOp;

fn create_line_thread(
    thread_id: &str,
    message_id: &str,
    body: &str,
    sync: Option<MessageSync>,
) -> Thread {
    Thread {
        id: thread_id.into(),
        origin: Origin::Github,
        anchor: Anchor::line("src/a.rs", 4),
        state: ThreadState::Open,
        outdated: false,
        messages: vec![Message::create_with_sync(
            message_id,
            "pablo",
            body,
            "2026-11-20T00:00:00Z",
            sync,
        )],
    }
}

#[test]
fn remapping_rewrites_dependent_queued_ops_after_temp_ids_resolve() {
    let mut ops = vec![
        QueuedCommentOp::ReplyToThread {
            thread_id: "tmp-t-1".into(),
            root_database_id: None,
            temp_message_id: "tmp-m-2".into(),
            body: "follow-up".into(),
        },
        QueuedCommentOp::EditMessage {
            thread_id: "tmp-t-1".into(),
            anchor_kind: AnchorKind::Line,
            message_id: "tmp-m-1".into(),
            body: "edited".into(),
        },
    ];
    remap_queued_ops(&mut ops, "tmp-t-1", "PRRT_9");
    remap_queued_ops(&mut ops, "tmp-m-1", "PRRC_9");
    assert!(matches!(
        &ops[0],
        QueuedCommentOp::ReplyToThread { thread_id, .. } if thread_id == "PRRT_9"
    ));
    assert!(matches!(
        &ops[1],
        QueuedCommentOp::EditMessage { thread_id, message_id, .. }
            if thread_id == "PRRT_9" && message_id == "PRRC_9"
    ));
}

#[test]
fn concurrent_forge_edit_drops_all_conflicting_edits_and_keeps_latest_recoverable_body() {
    let mut remote_threads = vec![create_line_thread(
        "PRRT_1",
        "PRRC_1",
        "edited on GitHub web",
        Some(MessageSync::Published),
    )];
    let mut agreed = BTreeMap::from([("PRRC_1".to_owned(), "original body".to_owned())]);
    let mut ops = vec![
        QueuedCommentOp::EditMessage {
            thread_id: "PRRT_1".into(),
            anchor_kind: AnchorKind::Line,
            message_id: "PRRC_1".into(),
            body: "first offline edit".into(),
        },
        QueuedCommentOp::EditMessage {
            thread_id: "PRRT_1".into(),
            anchor_kind: AnchorKind::Line,
            message_id: "PRRC_1".into(),
            body: "second offline edit".into(),
        },
    ];

    reconcile_concurrent_edits(&mut remote_threads, &mut agreed, &mut ops);

    assert!(
        ops.is_empty(),
        "all conflicting EditMessage ops are dropped"
    );
    assert_eq!(remote_threads[0].messages[0].body, "edited on GitHub web");
    assert_eq!(
        remote_threads[0].messages[0].recoverable_body.as_deref(),
        Some("second offline edit")
    );
    assert_eq!(
        agreed.get("PRRC_1").map(String::as_str),
        Some("edited on GitHub web")
    );
}

#[test]
fn submit_preview_collects_drafts_with_first_line_snippets() {
    let mut thread = create_line_thread(
        "PRRT_1",
        "PRRC_1",
        "nit here\nmore detail",
        Some(MessageSync::Draft),
    );
    thread.anchor = Anchor::side_line("src/a.rs", Side::Right, 10);
    let preview = create_submit_preview_from_threads("alice", Some("bob"), &[thread]);
    assert_eq!(preview.draft_count, 1);
    assert_eq!(preview.drafts[0].snippet, "nit here");
    assert!(preview.blocked_reason.is_none());
}

#[test]
fn submit_preview_disallows_approve_and_request_changes_only_for_pr_author() {
    let thread = create_line_thread("PRRT_1", "PRRC_1", "nit here", Some(MessageSync::Draft));
    let threads = [thread];
    let own = create_submit_preview_from_threads("alice", Some("alice"), &threads);
    assert!(!own.can_approve_or_request_changes);

    let peer = create_submit_preview_from_threads("alice", Some("bob"), &threads);
    assert!(peer.can_approve_or_request_changes);
}

#[test]
fn submit_preview_prefers_failed_blocker_regardless_of_thread_order() {
    let queued = create_line_thread("tmp-1", "tmp-2", "queued", Some(MessageSync::Queued));
    let failed = create_line_thread("tmp-3", "tmp-4", "failed", Some(MessageSync::Failed));

    let queued_only =
        create_submit_preview_from_threads("alice", Some("bob"), std::slice::from_ref(&queued));
    assert!(
        queued_only
            .blocked_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("queued"))
    );

    let queued_then_failed =
        create_submit_preview_from_threads("alice", Some("bob"), &[queued.clone(), failed.clone()]);
    assert!(
        queued_then_failed
            .blocked_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("failed"))
    );

    let failed_then_queued =
        create_submit_preview_from_threads("alice", Some("bob"), &[failed, queued]);
    assert!(
        failed_then_queued
            .blocked_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("failed"))
    );
}

#[test]
fn record_agreed_bodies_stores_published_and_draft_messages_only() {
    let published = create_line_thread("PRRT_1", "PRRC_1", "hello", Some(MessageSync::Published));
    let draft = create_line_thread("PRRT_2", "PRRC_2", "draft body", Some(MessageSync::Draft));
    let queued = create_line_thread("tmp-1", "tmp-2", "queued body", Some(MessageSync::Queued));
    let mut agreed = BTreeMap::new();
    record_agreed_bodies(&[published, draft, queued], &mut agreed);
    assert_eq!(agreed.get("PRRC_1").map(String::as_str), Some("hello"));
    assert_eq!(agreed.get("PRRC_2").map(String::as_str), Some("draft body"));
    assert!(!agreed.contains_key("tmp-2"));
}

#[test]
fn merge_unflushed_threads_keeps_pending_and_preserves_recoverable_body() {
    let mut remote_thread = create_line_thread(
        "PRRT_1",
        "PRRC_1",
        "remote edit",
        Some(MessageSync::Published),
    );
    remote_thread.messages[0].recoverable_body = Some("local draft recovery".into());

    let mut local_thread = create_line_thread(
        "PRRT_1",
        "PRRC_1",
        "pending edit",
        Some(MessageSync::Pending),
    );
    local_thread.messages.push(Message::create_with_sync(
        "tmp-m-1",
        "bob",
        "pending reply",
        "2026-11-20T00:01:00Z",
        Some(MessageSync::Pending),
    ));
    let local_new = create_line_thread("tmp-t-1", "tmp-m-2", "failed", Some(MessageSync::Failed));

    let mut remote = vec![remote_thread];
    merge_unflushed_threads(&mut remote, &[local_thread, local_new]);
    assert_eq!(remote.len(), 2);
    assert_eq!(remote[0].messages.len(), 2);
    assert_eq!(remote[0].messages[0].body, "pending edit");
    assert_eq!(
        remote[0].messages[0].recoverable_body.as_deref(),
        Some("local draft recovery")
    );
    assert_eq!(remote[1].id, "tmp-t-1");
}

#[test]
fn toggle_reaction_adds_increments_decrements_and_removes_at_zero() {
    let mut reactions = Vec::new();
    assert!(toggle_reaction_in_list(
        &mut reactions,
        ReactionContent::ThumbsUp
    ));
    assert_eq!(reactions.len(), 1);
    assert_eq!(reactions[0].count, 1);
    assert!(reactions[0].viewer_has_reacted);

    assert!(!toggle_reaction_in_list(
        &mut reactions,
        ReactionContent::ThumbsUp
    ));
    assert!(reactions.is_empty());

    let mut peer_reactions = vec![Reaction {
        content: ReactionContent::Rocket,
        count: 2,
        viewer_has_reacted: false,
    }];
    assert!(toggle_reaction_in_list(
        &mut peer_reactions,
        ReactionContent::Rocket
    ));
    assert_eq!(peer_reactions[0].count, 3);
    assert!(peer_reactions[0].viewer_has_reacted);

    assert!(!toggle_reaction_in_list(
        &mut peer_reactions,
        ReactionContent::Rocket
    ));
    assert_eq!(peer_reactions[0].count, 2);
    assert!(!peer_reactions[0].viewer_has_reacted);
}
