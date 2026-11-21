//! Sync reconciliation helpers that preserve offline comment state across pulls.

use std::collections::HashSet;

use review_model::{MessageSync, ThreadState};

use super::super::ReviewSession;
use crate::comments::{find_message_mut, toggle_reaction_in_list};
use crate::ports::QueuedCommentOp;

impl ReviewSession {
    /// Reverts `Queued` markers on real messages whose queued `EditMessage` was
    /// dropped by concurrent-edit reconciliation before merging unflushed threads.
    pub(in super::super) fn clear_reconciled_queued_markers(&mut self) {
        let active_edit_ids: HashSet<String> = self
            .saved
            .registry
            .queued_ops
            .iter()
            .filter_map(|op| match op {
                QueuedCommentOp::EditMessage { message_id, .. } => {
                    Some(self.get_canonical_id_from_id(message_id))
                }
                _ => None,
            })
            .collect();
        for thread in &mut self.threads {
            for message in &mut thread.messages {
                if message.sync == Some(MessageSync::Queued)
                    && !message.id.starts_with("tmp-")
                    && !active_edit_ids.contains(&message.id)
                {
                    message.sync = Some(MessageSync::Published);
                }
            }
        }
    }

    /// Re-applies queued `DeleteMessage`, `SetResolved`, and `SetReaction`
    /// operations onto `self.threads` when queue replay stays offline during a
    /// pull.
    pub(in super::super) fn apply_pending_thread_ops(&mut self) {
        let queued = self.saved.registry.queued_ops.clone();
        for op in queued {
            match op {
                QueuedCommentOp::DeleteMessage {
                    thread_id,
                    message_id,
                    ..
                } => {
                    let canonical_thread_id = self.get_canonical_id_from_id(&thread_id);
                    let canonical_message_id = self.get_canonical_id_from_id(&message_id);
                    self.remove_message_from_threads(&canonical_thread_id, &canonical_message_id);
                }
                QueuedCommentOp::SetResolved {
                    thread_id,
                    resolved,
                } => {
                    let canonical_thread_id = self.get_canonical_id_from_id(&thread_id);
                    if let Some(thread) = self.find_thread_mut(&canonical_thread_id) {
                        thread.state = if resolved {
                            ThreadState::Resolved
                        } else {
                            ThreadState::Open
                        };
                    }
                }
                QueuedCommentOp::SetReaction {
                    subject_id,
                    content,
                    added,
                } => self.reapply_pending_reaction(&subject_id, content, added),
                _ => {}
            }
        }
    }

    fn reapply_pending_reaction(
        &mut self,
        subject_id: &str,
        content: review_model::ReactionContent,
        is_added: bool,
    ) {
        let canonical_subject_id = self.get_canonical_id_from_id(subject_id);
        if let Some(message) = find_message_mut(&mut self.threads, &canonical_subject_id) {
            let has_reacted = message
                .reactions
                .iter()
                .any(|reaction| reaction.content == content && reaction.viewer_has_reacted);
            if is_added != has_reacted {
                toggle_reaction_in_list(&mut message.reactions, content);
            }
        }
    }
}
