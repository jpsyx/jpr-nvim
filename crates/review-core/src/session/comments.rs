//! Review comments, replies, edits, deletions, resolution, reactions, and
//! offline queue replay.

mod helpers;
mod queue;
mod reconcile;
mod replay;
#[cfg(test)]
mod tests;

use anyhow::{Context, Result, bail};
use review_model::{
    Anchor, AnchorKind, MentionCandidate, ReactionContent, SessionView, Thread, ThreadState,
};

use super::ReviewSession;
use crate::comments::{find_message_mut, toggle_reaction_in_list};
use crate::ports::{ForgeWriteError, QueuedCommentOp, ReplyRequest};

impl ReviewSession {
    /// Every review thread and conversation comment currently known.
    #[must_use]
    pub fn threads(&self) -> &[Thread] {
        &self.threads
    }

    /// Cached `@mention` completion candidates, PR participants first.
    #[must_use]
    pub fn mentions(&self) -> &[MentionCandidate] {
        &self.saved.registry.mention_candidates
    }

    /// Creates a draft code thread (`File`/`Line`/`Range`) or a published PR
    /// conversation comment (`Pr`).
    pub fn comment(&mut self, anchor: Anchor, body: &str) -> Result<(Thread, SessionView)> {
        if body.trim().is_empty() {
            bail!("comment body cannot be empty");
        }
        let pr = self.synced_pr()?.clone();
        if anchor.kind == AnchorKind::Pr {
            return self.create_pr_comment(&pr, body);
        }
        self.validate_anchor_file(&anchor)?;
        self.create_code_thread(&pr, anchor, body)
    }

    /// Replies to `thread_id` (immediate via REST when no pending review is
    /// active, else added to the pending review).
    pub fn reply(&mut self, thread_id: &str, body: &str) -> Result<(Thread, SessionView)> {
        if body.trim().is_empty() {
            bail!("reply body cannot be empty");
        }
        let pr = self.synced_pr()?.clone();
        let resolved_id = self.resolve_id(thread_id);
        let root_db_id = self
            .find_thread(&resolved_id)
            .with_context(|| format!("unknown thread {thread_id}"))?
            .messages
            .first()
            .and_then(|message| message.database_id.clone());
        let pending_id = self.saved.registry.pending_review_id.clone();
        let request = ReplyRequest {
            thread_id: &resolved_id,
            root_database_id: root_db_id.as_deref(),
            pending_review_id: pending_id.as_deref(),
            body,
        };
        match self.ports.forge.reply_to_thread(&pr, &request) {
            Ok(message) => {
                if message.sync == Some(review_model::MessageSync::Draft)
                    && self.saved.registry.pending_review_id.is_none()
                {
                    self.refresh_pending_review_id(&pr);
                }
                let thread = self.push_reply_message(&resolved_id, message)?;
                let view = self.save_and_announce_threads()?;
                Ok((thread, view))
            }
            Err(error) => self.record_failed_or_queued_reply(&resolved_id, root_db_id, body, error),
        }
    }

    /// Edits `message_id`'s body on the forge (or updates an unflushed local
    /// placeholder in place).
    pub fn edit_message(&mut self, message_id: &str, body: &str) -> Result<(Thread, SessionView)> {
        if body.trim().is_empty() {
            bail!("message body cannot be empty");
        }
        let _ = self.synced_pr()?;
        let resolved_msg_id = self.resolve_id(message_id);
        let (thread_id, anchor_kind, current_sync) = self.locate_message(&resolved_msg_id)?;
        if let Some(result) =
            self.edit_unflushed_message(&thread_id, &resolved_msg_id, current_sync, body)?
        {
            return Ok(result);
        }
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
                let thread = self.replace_message(&thread_id, &resolved_msg_id, updated)?;
                let view = self.save_and_announce_threads()?;
                Ok((thread, view))
            }
            Err(error) => self.record_failed_or_queued_edit(
                &thread_id,
                anchor_kind,
                &resolved_msg_id,
                body,
                error,
            ),
        }
    }

    /// Deletes `message_id` (removing its thread when it was the sole message).
    pub fn delete_message(&mut self, message_id: &str) -> Result<SessionView> {
        let _ = self.synced_pr()?;
        let resolved_msg_id = self.resolve_id(message_id);
        let (thread_id, anchor_kind, _) = self.locate_message(&resolved_msg_id)?;
        if resolved_msg_id.starts_with("tmp-") {
            self.drop_local_message_and_ops(&thread_id, &resolved_msg_id);
            return self.save_and_announce_threads();
        }
        match self
            .ports
            .forge
            .delete_message(anchor_kind, &resolved_msg_id)
        {
            Ok(()) => {
                self.remove_message_from_threads(&thread_id, &resolved_msg_id);
                self.drop_queued_ops_for_removed_message(&thread_id, &resolved_msg_id);
                self.saved.registry.agreed_bodies.remove(&resolved_msg_id);
                self.save_and_announce_threads()
            }
            Err(ForgeWriteError::Transient(_)) => {
                self.remove_message_from_threads(&thread_id, &resolved_msg_id);
                self.drop_queued_ops_for_removed_message(&thread_id, &resolved_msg_id);
                self.saved
                    .registry
                    .queued_ops
                    .push(QueuedCommentOp::DeleteMessage {
                        thread_id,
                        anchor_kind,
                        message_id: resolved_msg_id,
                    });
                self.save_and_announce_threads()
            }
            Err(ForgeWriteError::Rejected(reason)) => bail!("{reason}"),
        }
    }

    /// Resolves (`true`) or unresolves (`false`) `thread_id`.
    pub fn set_resolved(
        &mut self,
        thread_id: &str,
        resolved: bool,
    ) -> Result<(Thread, SessionView)> {
        let _ = self.synced_pr()?;
        let resolved_id = self.resolve_id(thread_id);
        let target_state = if resolved {
            ThreadState::Resolved
        } else {
            ThreadState::Open
        };
        let thread = self
            .find_thread_mut(&resolved_id)
            .with_context(|| format!("unknown thread {thread_id}"))?;
        if thread.anchor.kind == AnchorKind::Pr {
            bail!("pull-request conversation comments cannot be resolved");
        }
        let previous_state = thread.state;
        thread.state = target_state;
        let snapshot_thread = thread.clone();
        match self.ports.forge.set_resolved(&resolved_id, resolved) {
            Ok(()) => {}
            Err(ForgeWriteError::Transient(_)) => {
                self.saved
                    .registry
                    .queued_ops
                    .push(QueuedCommentOp::SetResolved {
                        thread_id: resolved_id,
                        resolved,
                    });
            }
            Err(ForgeWriteError::Rejected(reason)) => {
                if let Some(target) = self.find_thread_mut(&resolved_id) {
                    target.state = previous_state;
                }
                bail!("{reason}");
            }
        }
        let view = self.save_and_announce_threads()?;
        Ok((snapshot_thread, view))
    }

    /// Toggles `content` on `message_id` for the viewer.
    pub fn toggle_reaction(
        &mut self,
        message_id: &str,
        content: ReactionContent,
    ) -> Result<(Thread, SessionView)> {
        let _ = self.synced_pr()?;
        let resolved_msg_id = self.resolve_id(message_id);
        let (thread_id, _, _) = self.locate_message(&resolved_msg_id)?;
        let message =
            find_message_mut(&mut self.threads, &resolved_msg_id).context("message disappeared")?;
        let previous_reactions = message.reactions.clone();
        let added = toggle_reaction_in_list(&mut message.reactions, content);
        let result = self
            .ports
            .forge
            .set_reaction(&resolved_msg_id, content, added);
        self.apply_reaction_result(&resolved_msg_id, content, added, previous_reactions, result)?;
        let thread = self
            .find_thread(&thread_id)
            .context("thread disappeared")?
            .clone();
        let view = self.save_and_announce_threads()?;
        Ok((thread, view))
    }

    /// Re-queues a `MessageSync::Failed` message and immediately attempts to
    /// flush the queue.
    pub fn retry_message(&mut self, message_id: &str) -> Result<SessionView> {
        let _ = self.synced_pr()?;
        let resolved_msg_id = self.resolve_id(message_id);
        self.enqueue_failed_message(&resolved_msg_id)?;
        let _ = self.send_queued_comments();
        self.save_and_announce_threads()
    }
}
