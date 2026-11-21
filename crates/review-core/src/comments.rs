//! Pure state transitions for threads, queued comment operations, concurrent
//! edit recovery, and review-submission previews.

use std::collections::{BTreeMap, HashSet};

use review_model::{
    AnchorKind, Message, MessageSync, Reaction, ReactionContent, SubmitDraft, SubmitPreview, Thread,
};

use crate::ports::QueuedCommentOp;

/// Rewrites `from_id` to `to_id` across every queued operation waiting behind
/// a newly created thread or message.
pub fn remap_queued_ops(ops: &mut [QueuedCommentOp], from_id: &str, to_id: &str) {
    let replace = |target: &mut String| {
        if target == from_id {
            to_id.clone_into(target);
        }
    };
    for op in ops {
        match op {
            QueuedCommentOp::ReplyToThread { thread_id, .. }
            | QueuedCommentOp::SetResolved { thread_id, .. } => replace(thread_id),
            QueuedCommentOp::EditMessage {
                thread_id,
                message_id,
                ..
            }
            | QueuedCommentOp::DeleteMessage {
                thread_id,
                message_id,
                ..
            } => {
                replace(thread_id);
                replace(message_id);
            }
            QueuedCommentOp::SetReaction { subject_id, .. } => replace(subject_id),
            QueuedCommentOp::CreateReviewThread { .. }
            | QueuedCommentOp::CreateConversationComment { .. }
            | QueuedCommentOp::SubmitReview { .. } => {}
        }
    }
}

/// Remembers the forge-confirmed body of every published or draft message.
pub fn record_agreed_bodies(threads: &[Thread], agreed_bodies: &mut BTreeMap<String, String>) {
    for thread in threads {
        for message in &thread.messages {
            if matches!(
                message.sync,
                Some(MessageSync::Published | MessageSync::Draft)
            ) {
                agreed_bodies.insert(message.id.clone(), message.body.clone());
            }
        }
    }
}

/// Drops queued `EditMessage` ops whose target message changed on the forge
/// since the edit was queued, preserving the local text in `recoverable_body`.
pub fn reconcile_concurrent_edits(
    remote_threads: &mut [Thread],
    agreed_bodies: &mut BTreeMap<String, String>,
    ops: &mut Vec<QueuedCommentOp>,
) {
    let mut updated_agreed = Vec::new();
    ops.retain(|op| {
        let QueuedCommentOp::EditMessage {
            message_id, body, ..
        } = op
        else {
            return true;
        };
        let Some(remote_msg) = find_message_mut(remote_threads, message_id) else {
            return true;
        };
        let Some(agreed) = agreed_bodies.get(message_id) else {
            return true;
        };
        if &remote_msg.body == agreed {
            return true;
        }
        remote_msg.recoverable_body = Some(body.clone());
        updated_agreed.push((message_id.clone(), remote_msg.body.clone()));
        false
    });
    for (message_id, remote_body) in updated_agreed {
        agreed_bodies.insert(message_id, remote_body);
    }
}

/// Re-attaches optimistic threads and messages (`Pending`, `Queued`, or `Failed`)
/// from `local_threads` onto a freshly pulled `remote_threads` list.
pub fn merge_unflushed_threads(remote_threads: &mut Vec<Thread>, local_threads: &[Thread]) {
    let known_threads: HashSet<String> = remote_threads
        .iter()
        .map(|thread| thread.id.clone())
        .collect();
    for local in local_threads {
        if !known_threads.contains(&local.id) && has_unflushed_messages(local) {
            remote_threads.push(local.clone());
            continue;
        }
        let Some(remote) = remote_threads
            .iter_mut()
            .find(|thread| thread.id == local.id)
        else {
            continue;
        };
        merge_unflushed_messages(remote, &local.messages);
    }
}

const fn is_unflushed_sync(sync: Option<MessageSync>) -> bool {
    matches!(
        sync,
        Some(MessageSync::Queued | MessageSync::Failed | MessageSync::Pending)
    )
}

fn has_unflushed_messages(thread: &Thread) -> bool {
    thread
        .messages
        .iter()
        .any(|message| is_unflushed_sync(message.sync))
}

fn merge_unflushed_messages(remote: &mut Thread, local_messages: &[Message]) {
    for local_msg in local_messages {
        if let Some(existing) = remote
            .messages
            .iter_mut()
            .find(|message| message.id == local_msg.id)
        {
            if is_unflushed_sync(local_msg.sync) {
                let preserved_recoverable = existing.recoverable_body.take();
                *existing = local_msg.clone();
                if existing.recoverable_body.is_none() {
                    existing.recoverable_body = preserved_recoverable;
                }
            } else if existing.recoverable_body.is_none() && local_msg.recoverable_body.is_some() {
                existing
                    .recoverable_body
                    .clone_from(&local_msg.recoverable_body);
            }
        } else if is_unflushed_sync(local_msg.sync) {
            remote.messages.push(local_msg.clone());
        }
    }
}

/// Optimistically toggles `content` in `reactions`, returning whether the
/// reaction was added (`true`) or removed (`false`).
pub fn toggle_reaction_in_list(reactions: &mut Vec<Reaction>, content: ReactionContent) -> bool {
    if let Some(index) = reactions.iter().position(|item| item.content == content) {
        if reactions[index].viewer_has_reacted {
            reactions[index].viewer_has_reacted = false;
            reactions[index].count = reactions[index].count.saturating_sub(1);
            if reactions[index].count == 0 {
                reactions.remove(index);
            }
            return false;
        }
        reactions[index].viewer_has_reacted = true;
        reactions[index].count = reactions[index].count.saturating_add(1);
        return true;
    }
    reactions.push(Reaction {
        content,
        count: 1,
        viewer_has_reacted: true,
    });
    true
}

/// Builds the `:Jpr submit` preview from the current session threads.
#[must_use]
pub fn create_submit_preview_from_threads(
    pr_author: &str,
    viewer_login: Option<&str>,
    threads: &[Thread],
) -> SubmitPreview {
    let mut drafts = Vec::new();
    let mut blocked_reason = None;
    for thread in threads {
        collect_thread_drafts_and_blocker(thread, &mut drafts, &mut blocked_reason);
    }
    let is_self_review =
        !pr_author.is_empty() && viewer_login.is_some_and(|viewer| viewer == pr_author);
    SubmitPreview {
        draft_count: drafts.len(),
        drafts,
        can_approve_or_request_changes: !is_self_review,
        blocked_reason,
    }
}

fn collect_thread_drafts_and_blocker(
    thread: &Thread,
    drafts: &mut Vec<SubmitDraft>,
    blocked_reason: &mut Option<String>,
) {
    for message in &thread.messages {
        match message.sync {
            Some(MessageSync::Draft) => drafts.push(SubmitDraft {
                thread_id: thread.id.clone(),
                message_id: message.id.clone(),
                anchor: thread.anchor.clone(),
                snippet: build_snippet_from_body(&message.body),
            }),
            Some(MessageSync::Pending | MessageSync::Queued) if blocked_reason.is_none() => {
                *blocked_reason = Some(
                    "one or more comments are still queued for GitHub; wait for sync first"
                        .to_owned(),
                );
            }
            Some(MessageSync::Failed) => {
                *blocked_reason = Some(
                    "one or more comments failed to reach GitHub; retry, edit, or delete them first"
                        .to_owned(),
                );
            }
            _ => {}
        }
    }
}

fn build_snippet_from_body(body: &str) -> String {
    body.lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default()
        .chars()
        .take(80)
        .collect()
}

/// Finds the message with `message_id` inside `threads`.
pub fn find_message_mut<'a>(
    threads: &'a mut [Thread],
    message_id: &str,
) -> Option<&'a mut Message> {
    threads
        .iter_mut()
        .flat_map(|thread| thread.messages.iter_mut())
        .find(|message| message.id == message_id)
}

/// Counts code-anchored review threads, excluding PR conversation threads.
#[must_use]
pub fn count_code_threads(threads: &[Thread]) -> usize {
    threads
        .iter()
        .filter(|thread| thread.anchor.kind != AnchorKind::Pr)
        .count()
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use review_model::{
        Anchor, AnchorKind, Message, MessageSync, Origin, Side, Thread, ThreadState,
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
    fn submit_preview_collects_drafts_and_disallows_self_approval() {
        let mut thread = create_line_thread(
            "PRRT_1",
            "PRRC_1",
            "nit here\nmore detail",
            Some(MessageSync::Draft),
        );
        thread.anchor = Anchor::side_line("src/a.rs", Side::Right, 10);
        let threads = [thread];
        let own = create_submit_preview_from_threads("alice", Some("alice"), &threads);
        assert!(!own.can_approve_or_request_changes);
        assert_eq!(own.draft_count, 1);
        assert_eq!(own.drafts[0].snippet, "nit here");
        assert!(own.blocked_reason.is_none());

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
            create_submit_preview_from_threads("alice", Some("bob"), &[queued, failed]);
        assert!(
            queued_then_failed
                .blocked_reason
                .as_deref()
                .is_some_and(|reason| reason.contains("failed"))
        );
    }

    #[test]
    fn record_agreed_bodies_stores_published_and_draft_messages() {
        let published =
            create_line_thread("PRRT_1", "PRRC_1", "hello", Some(MessageSync::Published));
        let mut agreed = BTreeMap::new();
        record_agreed_bodies(&[published], &mut agreed);
        assert_eq!(agreed.get("PRRC_1").map(String::as_str), Some("hello"));
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
        let local_new =
            create_line_thread("tmp-t-1", "tmp-m-2", "failed", Some(MessageSync::Failed));

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
    fn toggle_reaction_adds_increments_and_removes_at_zero() {
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
    }
}
