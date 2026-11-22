//! Queue pruning and message removal helpers for [`ReviewSession`].

use review_model::Origin;

use crate::ports::QueuedCommentOp;
use crate::session::ReviewSession;

impl ReviewSession {
    pub(in crate::session::comments) fn drop_local_message_and_ops(
        &mut self,
        thread_id: &str,
        message_id: &str,
    ) {
        self.remove_message_from_threads(thread_id, message_id);
        let was_thread_removed = self.find_thread(thread_id).is_none();
        self.prune_queued_ops_for_drop(thread_id, message_id, was_thread_removed);
        self.promote_remaining_reply_if_root_deleted(thread_id);
    }

    fn clear_promoted_to_target(&mut self, removed_thread_id: &str) {
        for thread in &mut self.threads {
            if thread.origin == Origin::Local
                && thread.promoted_to.as_deref() == Some(removed_thread_id)
            {
                thread.promoted_to = None;
            }
        }
    }

    fn prune_queued_ops_for_drop(
        &mut self,
        thread_id: &str,
        message_id: &str,
        was_thread_removed: bool,
    ) {
        self.saved.registry.queued_ops.retain(|op| match op {
            QueuedCommentOp::CreateReviewThread {
                temp_thread_id,
                temp_message_id,
                ..
            }
            | QueuedCommentOp::CreateConversationComment {
                temp_thread_id,
                temp_message_id,
                ..
            } => {
                temp_message_id != message_id
                    && (!was_thread_removed || temp_thread_id != thread_id)
            }
            QueuedCommentOp::ReplyToThread {
                thread_id: op_thread_id,
                temp_message_id,
                ..
            } => {
                temp_message_id != message_id && (!was_thread_removed || op_thread_id != thread_id)
            }
            QueuedCommentOp::EditMessage {
                thread_id: op_thread_id,
                message_id: op_message_id,
                ..
            }
            | QueuedCommentOp::DeleteMessage {
                thread_id: op_thread_id,
                message_id: op_message_id,
                ..
            } => op_message_id != message_id && (!was_thread_removed || op_thread_id != thread_id),
            QueuedCommentOp::SetResolved {
                thread_id: op_thread_id,
                ..
            } => !was_thread_removed || op_thread_id != thread_id,
            QueuedCommentOp::SetReaction { subject_id, .. } => subject_id != message_id,
            QueuedCommentOp::SubmitReview { .. } => true,
        });
    }

    fn promote_remaining_reply_if_root_deleted(&mut self, thread_id: &str) {
        if !thread_id.starts_with("tmp-") {
            return;
        }
        let Some(thread) = self.find_thread(thread_id).cloned() else {
            return;
        };
        let has_create_thread = self.saved.registry.queued_ops.iter().any(|op| {
            matches!(
                op,
                QueuedCommentOp::CreateReviewThread { temp_thread_id, .. }
                    if temp_thread_id == thread_id
            )
        });
        if has_create_thread {
            return;
        }
        let Some(first_remaining) = thread.messages.first() else {
            return;
        };
        for op in &mut self.saved.registry.queued_ops {
            if let QueuedCommentOp::ReplyToThread {
                thread_id: op_thread_id,
                temp_message_id,
                body,
                ..
            } = op
                && op_thread_id == thread_id
                && temp_message_id == &first_remaining.id
            {
                *op = QueuedCommentOp::CreateReviewThread {
                    temp_thread_id: thread_id.to_owned(),
                    temp_message_id: first_remaining.id.clone(),
                    anchor: thread.anchor.clone(),
                    body: body.clone(),
                };
                break;
            }
        }
    }

    pub(in crate::session::comments) fn drop_queued_ops_for_removed_message(
        &mut self,
        thread_id: &str,
        message_id: &str,
    ) {
        let was_thread_removed = self.find_thread(thread_id).is_none();
        self.saved.registry.queued_ops.retain(|op| match op {
            QueuedCommentOp::EditMessage {
                message_id: op_message_id,
                ..
            } => op_message_id != message_id,
            QueuedCommentOp::SetReaction { subject_id, .. } => subject_id != message_id,
            QueuedCommentOp::SetResolved {
                thread_id: op_thread_id,
                ..
            } => !was_thread_removed || op_thread_id != thread_id,
            _ => true,
        });
    }

    pub(in crate::session) fn remove_message_from_threads(
        &mut self,
        thread_id: &str,
        message_id: &str,
    ) {
        let was_present = if let Some(thread) = self.find_thread_mut(thread_id) {
            thread.messages.retain(|message| message.id != message_id);
            true
        } else {
            false
        };
        self.threads.retain(|thread| !thread.messages.is_empty());
        if was_present && self.find_thread(thread_id).is_none() {
            self.clear_promoted_to_target(thread_id);
        }
    }
}
