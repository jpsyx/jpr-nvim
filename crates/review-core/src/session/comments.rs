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
    Anchor, AnchorKind, MentionCandidate, Origin, ReactionContent, SessionView, Thread, ThreadState,
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
        if !self.is_linked() {
            return &[];
        }
        &self.saved.registry.mention_candidates
    }

    /// Creates a draft code thread (`File`/`Line`/`Range`) or a published PR
    /// conversation comment (`Pr`).
    pub fn comment(&mut self, anchor: Anchor, body: &str) -> Result<(Thread, SessionView)> {
        self.comment_with_origin(anchor, body, Origin::Github)
    }

    /// Appends a reply to `thread_id` (published immediately when no pending
    /// review blocks it, attached as a draft to the active pending review, or
    /// appended locally for `Origin::Local`) and returns the updated [`Thread`]
    /// and [`SessionView`].
    pub fn reply(&mut self, thread_id: &str, body: &str) -> Result<(Thread, SessionView)> {
        if body.trim().is_empty() {
            bail!("reply body cannot be empty");
        }
        if self.is_local_thread(thread_id) {
            return self.reply_local_thread(thread_id, body);
        }
        let pr = self.require_linked_pr()?.clone();
        let canonical_thread_id = self.get_canonical_id_from_id(thread_id);
        let root_database_id = self
            .find_thread(&canonical_thread_id)
            .with_context(|| format!("unknown thread {thread_id}"))?
            .messages
            .first()
            .and_then(|message| message.database_id.clone());
        let pending_id = self.saved.registry.pending_review_id.clone();
        let request = ReplyRequest {
            thread_id: &canonical_thread_id,
            root_database_id: root_database_id.as_deref(),
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
                let thread = self.push_reply_message(&canonical_thread_id, message)?;
                let view = self.save_and_announce_threads()?;
                Ok((thread, view))
            }
            Err(error) => self.record_failed_or_queued_reply(
                &canonical_thread_id,
                root_database_id,
                body,
                error,
            ),
        }
    }

    /// Edits `message_id`'s body on the forge (or updates an unflushed or local
    /// message in place).
    pub fn edit_message(&mut self, message_id: &str, body: &str) -> Result<(Thread, SessionView)> {
        if body.trim().is_empty() {
            bail!("message body cannot be empty");
        }
        if self.is_local_message(message_id) {
            return self.edit_local_message(message_id, body);
        }
        let _ = self.require_linked_pr()?;
        let canonical_message_id = self.get_canonical_id_from_id(message_id);
        let (thread_id, anchor_kind, current_sync) = self.locate_message(&canonical_message_id)?;
        if let Some(result) =
            self.edit_unflushed_message(&thread_id, &canonical_message_id, current_sync, body)?
        {
            return Ok(result);
        }
        match self
            .ports
            .forge
            .edit_message(anchor_kind, &canonical_message_id, body)
        {
            Ok(updated) => {
                self.saved
                    .registry
                    .agreed_bodies
                    .insert(updated.id.clone(), updated.body.clone());
                let thread = self.replace_message(&thread_id, &canonical_message_id, updated)?;
                let view = self.save_and_announce_threads()?;
                Ok((thread, view))
            }
            Err(error) => self.record_failed_or_queued_edit(
                &thread_id,
                anchor_kind,
                &canonical_message_id,
                body,
                error,
            ),
        }
    }

    /// Deletes `message_id` (removing its thread when it was the sole message).
    pub fn delete_message(&mut self, message_id: &str) -> Result<SessionView> {
        if self.is_local_message(message_id) {
            return self.delete_local_message(message_id);
        }
        let _ = self.require_linked_pr()?;
        let canonical_message_id = self.get_canonical_id_from_id(message_id);
        let (thread_id, anchor_kind, _) = self.locate_message(&canonical_message_id)?;
        if canonical_message_id.starts_with("tmp-") {
            self.drop_local_message_and_ops(&thread_id, &canonical_message_id);
            return self.save_and_announce_threads();
        }
        match self
            .ports
            .forge
            .delete_message(anchor_kind, &canonical_message_id)
        {
            Ok(()) => {
                self.remove_message_from_threads(&thread_id, &canonical_message_id);
                self.drop_queued_ops_for_removed_message(&thread_id, &canonical_message_id);
                self.saved
                    .registry
                    .agreed_bodies
                    .remove(&canonical_message_id);
                self.save_and_announce_threads()
            }
            Err(ForgeWriteError::Transient(_)) => {
                self.remove_message_from_threads(&thread_id, &canonical_message_id);
                self.drop_queued_ops_for_removed_message(&thread_id, &canonical_message_id);
                self.saved
                    .registry
                    .queued_ops
                    .push(QueuedCommentOp::DeleteMessage {
                        thread_id,
                        anchor_kind,
                        message_id: canonical_message_id,
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
        is_resolved: bool,
    ) -> Result<(Thread, SessionView)> {
        if self.is_local_thread(thread_id) {
            return self.set_local_resolved(thread_id, is_resolved);
        }
        let _ = self.require_linked_pr()?;
        let canonical_thread_id = self.get_canonical_id_from_id(thread_id);
        let target_state = if is_resolved {
            ThreadState::Resolved
        } else {
            ThreadState::Open
        };
        let thread = self
            .find_thread_mut(&canonical_thread_id)
            .with_context(|| format!("unknown thread {thread_id}"))?;
        if thread.anchor.kind == AnchorKind::Pr {
            bail!("pull-request conversation comments cannot be resolved");
        }
        let previous_state = thread.state;
        thread.state = target_state;
        let snapshot_thread = thread.clone();
        self.apply_forge_resolved(&canonical_thread_id, is_resolved, previous_state)?;
        let view = self.save_and_announce_threads()?;
        Ok((snapshot_thread, view))
    }

    fn apply_forge_resolved(
        &mut self,
        canonical_thread_id: &str,
        is_resolved: bool,
        previous_state: ThreadState,
    ) -> Result<()> {
        match self
            .ports
            .forge
            .set_resolved(canonical_thread_id, is_resolved)
        {
            Ok(()) => Ok(()),
            Err(ForgeWriteError::Transient(_)) => {
                self.saved
                    .registry
                    .queued_ops
                    .push(QueuedCommentOp::SetResolved {
                        thread_id: canonical_thread_id.to_owned(),
                        resolved: is_resolved,
                    });
                Ok(())
            }
            Err(ForgeWriteError::Rejected(reason)) => {
                if let Some(target) = self.find_thread_mut(canonical_thread_id) {
                    target.state = previous_state;
                }
                bail!("{reason}");
            }
        }
    }

    /// Toggles `content` on `message_id` for the viewer.
    pub fn toggle_reaction(
        &mut self,
        message_id: &str,
        content: ReactionContent,
    ) -> Result<(Thread, SessionView)> {
        if self.is_local_message(message_id) {
            return self.toggle_local_reaction(message_id, content);
        }
        let _ = self.require_linked_pr()?;
        let canonical_message_id = self.get_canonical_id_from_id(message_id);
        let (thread_id, _, _) = self.locate_message(&canonical_message_id)?;
        let message = find_message_mut(&mut self.threads, &canonical_message_id)
            .context("message disappeared")?;
        let previous_reactions = message.reactions.clone();
        let is_added = toggle_reaction_in_list(&mut message.reactions, content);
        let result = self
            .ports
            .forge
            .set_reaction(&canonical_message_id, content, is_added);
        self.apply_reaction_result(
            &canonical_message_id,
            content,
            is_added,
            previous_reactions,
            result,
        )?;
        let thread = self
            .find_thread(&thread_id)
            .context("thread disappeared")?
            .clone();
        let view = self.save_and_announce_threads()?;
        Ok((thread, view))
    }

    /// Retries sending a [`MessageSync::Failed`](review_model::MessageSync::Failed)
    /// message to the forge and returns the updated [`SessionView`].
    pub fn retry_message(&mut self, message_id: &str) -> Result<SessionView> {
        let _ = self.require_linked_pr()?;
        if self.is_local_message(message_id) {
            bail!("local comments cannot be retried on GitHub");
        }
        let canonical_message_id = self.get_canonical_id_from_id(message_id);
        self.enqueue_failed_message(&canonical_message_id, None)?;
        let _ = self.send_queued_comments();
        self.save_and_announce_threads()
    }
}
