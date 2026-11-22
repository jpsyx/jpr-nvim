//! Pure state transitions for threads, queued comment operations, concurrent
//! edit recovery, and review-submission previews.

use std::collections::{BTreeMap, HashSet};

use review_model::{
    AnchorKind, Message, MessageSync, Origin, Reaction, ReactionContent, SubmitDraft,
    SubmitPreview, Thread, build_snippet_from_body,
};

use crate::ports::QueuedCommentOp;

/// Rewrites `from_id` to `to_id` across every queued operation for
/// `ReviewSession::record_id_mapping` so dependent replies, edits, deletes,
/// and reactions target the canonical forge ID once a temporary ID is created.
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

/// Records the forge-confirmed body of every published or draft message into
/// `agreed_bodies` for `ReviewSession::save_and_announce_threads` and
/// `ReviewSession::apply_pull` so `reconcile_concurrent_edits` can detect
/// remote edits.
pub fn record_agreed_bodies(threads: &[Thread], agreed_bodies: &mut BTreeMap<String, String>) {
    for thread in threads
        .iter()
        .filter(|thread| thread.origin == Origin::Github)
    {
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
/// since the edit was queued during `ReviewSession::apply_pull`, avoiding
/// silent overwrites while preserving the local text in `recoverable_body`.
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
        let Some(remote_message) = find_message_mut(remote_threads, message_id) else {
            return true;
        };
        let Some(agreed) = agreed_bodies.get(message_id) else {
            return true;
        };
        if &remote_message.body == agreed {
            return true;
        }
        remote_message.recoverable_body = Some(body.clone());
        updated_agreed.push((message_id.clone(), remote_message.body.clone()));
        false
    });
    for (message_id, remote_body) in updated_agreed {
        agreed_bodies.insert(message_id, remote_body);
    }
}

/// Re-attaches optimistic threads and messages (`Pending`, `Queued`, or `Failed`)
/// from `local_threads` onto `remote_threads` during `ReviewSession::apply_pull`
/// so unsynced local work remains visible across a remote refresh.
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
    for local_message in local_messages {
        if let Some(existing) = remote
            .messages
            .iter_mut()
            .find(|message| message.id == local_message.id)
        {
            if is_unflushed_sync(local_message.sync) {
                let preserved_recoverable = existing.recoverable_body.take();
                *existing = local_message.clone();
                if existing.recoverable_body.is_none() {
                    existing.recoverable_body = preserved_recoverable;
                }
            } else if existing.recoverable_body.is_none()
                && local_message.recoverable_body.is_some()
            {
                existing
                    .recoverable_body
                    .clone_from(&local_message.recoverable_body);
            }
        } else if is_unflushed_sync(local_message.sync) {
            remote.messages.push(local_message.clone());
        }
    }
}

/// Optimistically toggles `content` in `reactions` and returns whether the
/// viewer's reaction is now active (`true`) or removed (`false`), for example
/// when `ReviewSession::toggle_reaction` or `FakeForge::set_reaction` updates
/// a comment's reaction summary.
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

/// Summarizes pending draft comments, self-review eligibility, and sync
/// blockers into a [`SubmitPreview`] for `ReviewSession::submit_preview`.
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

/// Returns a mutable reference to the message matching `message_id` inside
/// `threads`, for example when updating a comment's body or sync state during
/// session mutations and pull reconciliation.
pub fn find_message_mut<'a>(
    threads: &'a mut [Thread],
    message_id: &str,
) -> Option<&'a mut Message> {
    threads
        .iter_mut()
        .flat_map(|thread| thread.messages.iter_mut())
        .find(|message| message.id == message_id)
}

/// Counts code-anchored review threads (excluding PR conversation comments)
/// for `ReviewSession::session_view`.
#[must_use]
pub fn count_code_threads(threads: &[Thread]) -> usize {
    threads
        .iter()
        .filter(|thread| thread.anchor.kind != AnchorKind::Pr)
        .count()
}

#[cfg(test)]
mod tests;
