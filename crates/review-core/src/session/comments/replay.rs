//! Per-operation forge replay handlers for queued comment operations.

use review_model::{
    AnchorKind, MessageSync, PullRequest, ReactionContent, ReviewEvent, ThreadState,
};

use super::super::ReviewSession;
use crate::comments::{find_message_mut, toggle_reaction_in_list};
use crate::ports::{ForgeWriteError, QueuedCommentOp, ReplyRequest};

pub(super) enum ReplayOutcome {
    Landed,
    Transient,
    Rejected,
}

impl ReviewSession {
    pub(super) fn replay_queued_op(
        &mut self,
        pr: &PullRequest,
        op: &QueuedCommentOp,
        remaining_ops: &mut [QueuedCommentOp],
    ) -> ReplayOutcome {
        match op {
            QueuedCommentOp::CreateReviewThread { .. } => {
                self.replay_create_thread(pr, op, remaining_ops)
            }
            QueuedCommentOp::CreateConversationComment { .. } => {
                self.replay_create_conversation(pr, op, remaining_ops)
            }
            QueuedCommentOp::ReplyToThread { .. } => self.replay_reply(pr, op, remaining_ops),
            QueuedCommentOp::EditMessage { .. }
            | QueuedCommentOp::DeleteMessage { .. }
            | QueuedCommentOp::SetResolved { .. }
            | QueuedCommentOp::SetReaction { .. }
            | QueuedCommentOp::SubmitReview { .. } => self.replay_mutation_op(pr, op),
        }
    }

    fn replay_mutation_op(&mut self, pr: &PullRequest, op: &QueuedCommentOp) -> ReplayOutcome {
        match op {
            QueuedCommentOp::EditMessage {
                thread_id,
                anchor_kind,
                message_id,
                body,
            } => self.replay_edit(thread_id, *anchor_kind, message_id, body),
            QueuedCommentOp::DeleteMessage {
                thread_id,
                anchor_kind,
                message_id,
            } => self.replay_delete(thread_id, *anchor_kind, message_id),
            QueuedCommentOp::SetResolved {
                thread_id,
                resolved,
            } => self.replay_resolved(thread_id, *resolved),
            QueuedCommentOp::SetReaction {
                subject_id,
                content,
                added,
            } => self.replay_reaction(subject_id, *content, *added),
            QueuedCommentOp::SubmitReview { event, body } => self.replay_submit(pr, *event, body),
            QueuedCommentOp::CreateReviewThread { .. }
            | QueuedCommentOp::CreateConversationComment { .. }
            | QueuedCommentOp::ReplyToThread { .. } => ReplayOutcome::Landed,
        }
    }

    fn replay_create_thread(
        &mut self,
        pr: &PullRequest,
        op: &QueuedCommentOp,
        remaining_ops: &mut [QueuedCommentOp],
    ) -> ReplayOutcome {
        let QueuedCommentOp::CreateReviewThread {
            temp_thread_id,
            temp_message_id,
            anchor,
            body,
        } = op
        else {
            return ReplayOutcome::Landed;
        };
        let pending_id = self.saved.registry.pending_review_id.clone();
        match self
            .ports
            .forge
            .create_review_thread(pr, pending_id.as_deref(), anchor, body)
        {
            Ok(created) => {
                self.saved.registry.pending_review_id = Some(created.pending_review_id);
                self.finish_created_thread(
                    temp_thread_id,
                    temp_message_id,
                    created.thread,
                    remaining_ops,
                );
                ReplayOutcome::Landed
            }
            Err(error) => self.handle_op_message_error(temp_message_id, error),
        }
    }

    fn replay_create_conversation(
        &mut self,
        pr: &PullRequest,
        op: &QueuedCommentOp,
        remaining_ops: &mut [QueuedCommentOp],
    ) -> ReplayOutcome {
        let QueuedCommentOp::CreateConversationComment {
            temp_thread_id,
            temp_message_id,
            body,
        } = op
        else {
            return ReplayOutcome::Landed;
        };
        match self.ports.forge.create_conversation_comment(pr, body) {
            Ok(created_thread) => {
                self.finish_created_thread(
                    temp_thread_id,
                    temp_message_id,
                    created_thread,
                    remaining_ops,
                );
                ReplayOutcome::Landed
            }
            Err(error) => self.handle_op_message_error(temp_message_id, error),
        }
    }

    fn replay_reply(
        &mut self,
        pr: &PullRequest,
        op: &QueuedCommentOp,
        remaining_ops: &mut [QueuedCommentOp],
    ) -> ReplayOutcome {
        let QueuedCommentOp::ReplyToThread {
            thread_id,
            root_database_id,
            temp_message_id,
            body,
        } = op
        else {
            return ReplayOutcome::Landed;
        };
        let resolved_thread_id = self.resolve_id(thread_id);
        let fallback_db_id = self
            .find_thread(&resolved_thread_id)
            .and_then(|thread| thread.messages.first())
            .and_then(|message| message.database_id.clone());
        let effective_db_id = root_database_id.as_deref().or(fallback_db_id.as_deref());
        let pending_id = self.saved.registry.pending_review_id.clone();
        let request = ReplyRequest {
            thread_id: &resolved_thread_id,
            root_database_id: effective_db_id,
            pending_review_id: pending_id.as_deref(),
            body,
        };
        match self.ports.forge.reply_to_thread(pr, &request) {
            Ok(real_msg) => {
                if real_msg.sync == Some(MessageSync::Draft)
                    && self.saved.registry.pending_review_id.is_none()
                {
                    self.refresh_pending_review_id(pr);
                }
                let real_msg_id = real_msg.id.clone();
                if let Some(slot) = find_message_mut(&mut self.threads, temp_message_id) {
                    *slot = real_msg;
                }
                self.record_id_mapping(temp_message_id, &real_msg_id, remaining_ops);
                ReplayOutcome::Landed
            }
            Err(error) => self.handle_op_message_error(temp_message_id, error),
        }
    }

    fn replay_edit(
        &mut self,
        thread_id: &str,
        anchor_kind: AnchorKind,
        message_id: &str,
        body: &str,
    ) -> ReplayOutcome {
        let resolved_msg_id = self.resolve_id(message_id);
        let resolved_thread_id = self.resolve_id(thread_id);
        match self
            .ports
            .forge
            .edit_message(anchor_kind, &resolved_msg_id, body)
        {
            Ok(updated) => {
                self.saved
                    .registry
                    .agreed_bodies
                    .insert(updated.id.clone(), updated.body.clone());
                if let Some(slot) = find_message_mut(&mut self.threads, &resolved_msg_id) {
                    *slot = updated;
                } else if let Some(thread) = self.find_thread_mut(&resolved_thread_id)
                    && let Some(slot) = thread
                        .messages
                        .iter_mut()
                        .find(|message| message.id == message_id)
                {
                    *slot = updated;
                }
                ReplayOutcome::Landed
            }
            Err(error) => self.handle_op_message_error(&resolved_msg_id, error),
        }
    }

    fn replay_delete(
        &mut self,
        thread_id: &str,
        anchor_kind: AnchorKind,
        message_id: &str,
    ) -> ReplayOutcome {
        let resolved_msg_id = self.resolve_id(message_id);
        let resolved_thread_id = self.resolve_id(thread_id);
        match self
            .ports
            .forge
            .delete_message(anchor_kind, &resolved_msg_id)
        {
            Ok(()) => {
                self.remove_message_from_threads(&resolved_thread_id, &resolved_msg_id);
                self.saved.registry.agreed_bodies.remove(&resolved_msg_id);
                ReplayOutcome::Landed
            }
            Err(ForgeWriteError::Transient(_)) => ReplayOutcome::Transient,
            Err(ForgeWriteError::Rejected(_)) => ReplayOutcome::Rejected,
        }
    }

    fn replay_resolved(&mut self, thread_id: &str, resolved: bool) -> ReplayOutcome {
        let resolved_thread_id = self.resolve_id(thread_id);
        match self.ports.forge.set_resolved(&resolved_thread_id, resolved) {
            Ok(()) => {
                if let Some(thread) = self.find_thread_mut(&resolved_thread_id) {
                    thread.state = if resolved {
                        ThreadState::Resolved
                    } else {
                        ThreadState::Open
                    };
                }
                ReplayOutcome::Landed
            }
            Err(ForgeWriteError::Transient(_)) => ReplayOutcome::Transient,
            Err(ForgeWriteError::Rejected(_)) => {
                if let Some(thread) = self.find_thread_mut(&resolved_thread_id) {
                    thread.state = if resolved {
                        ThreadState::Open
                    } else {
                        ThreadState::Resolved
                    };
                }
                ReplayOutcome::Rejected
            }
        }
    }

    fn replay_reaction(
        &mut self,
        subject_id: &str,
        content: ReactionContent,
        added: bool,
    ) -> ReplayOutcome {
        let resolved_subject_id = self.resolve_id(subject_id);
        match self
            .ports
            .forge
            .set_reaction(&resolved_subject_id, content, added)
        {
            Ok(reactions) => {
                if let Some(message) = find_message_mut(&mut self.threads, &resolved_subject_id) {
                    message.reactions = reactions;
                }
                ReplayOutcome::Landed
            }
            Err(ForgeWriteError::Transient(_)) => ReplayOutcome::Transient,
            Err(ForgeWriteError::Rejected(_)) => {
                if let Some(message) = find_message_mut(&mut self.threads, &resolved_subject_id) {
                    toggle_reaction_in_list(&mut message.reactions, content);
                }
                ReplayOutcome::Rejected
            }
        }
    }

    fn replay_submit(&mut self, pr: &PullRequest, event: ReviewEvent, body: &str) -> ReplayOutcome {
        let pending_id = self.saved.registry.pending_review_id.clone();
        match self
            .ports
            .forge
            .submit_review(pr, pending_id.as_deref(), event, body)
        {
            Ok(()) => {
                self.mark_drafts_published();
                self.saved.registry.pending_review_id = None;
                ReplayOutcome::Landed
            }
            Err(ForgeWriteError::Transient(_)) => ReplayOutcome::Transient,
            Err(ForgeWriteError::Rejected(_)) => ReplayOutcome::Rejected,
        }
    }
}
