//! Private creation, lookup, and optimistic-update helpers for
//! `ReviewSession` comments.

use anyhow::{Context, Result, bail};
use review_model::{
    Anchor, AnchorKind, Message, MessageSync, Origin, PullRequest, SessionView, Thread, ThreadState,
};

use super::super::ReviewSession;
use crate::comments::find_message_mut;
use crate::ports::{ForgeWriteError, QueuedCommentOp};

impl ReviewSession {
    pub(super) fn validate_anchor_file(&self, anchor: &Anchor) -> Result<()> {
        let Some(path) = anchor.file.as_deref() else {
            bail!("code comment anchor requires a file path");
        };
        if !self.saved.files.iter().any(|file| file.path == path) {
            bail!("{path} is not a file this pull request changes");
        }
        Ok(())
    }

    pub(super) fn create_pr_comment(
        &mut self,
        pr: &PullRequest,
        body: &str,
    ) -> Result<(Thread, SessionView)> {
        match self.ports.forge.create_conversation_comment(pr, body) {
            Ok(thread) => {
                self.threads.push(thread.clone());
                let view = self.save_and_announce_threads()?;
                Ok((thread, view))
            }
            Err(error) => self.record_failed_or_queued_thread(Anchor::pr(), body, error),
        }
    }

    pub(super) fn create_code_thread(
        &mut self,
        pr: &PullRequest,
        anchor: Anchor,
        body: &str,
    ) -> Result<(Thread, SessionView)> {
        let pending_id = self.saved.registry.pending_review_id.clone();
        match self
            .ports
            .forge
            .create_review_thread(pr, pending_id.as_deref(), &anchor, body)
        {
            Ok(created) => {
                self.saved.registry.pending_review_id = Some(created.pending_review_id);
                self.threads.push(created.thread.clone());
                let view = self.save_and_announce_threads()?;
                Ok((created.thread, view))
            }
            Err(error) => self.record_failed_or_queued_thread(anchor, body, error),
        }
    }

    fn record_failed_or_queued_thread(
        &mut self,
        anchor: Anchor,
        body: &str,
        error: ForgeWriteError,
    ) -> Result<(Thread, SessionView)> {
        let temp_thread_id = self.allocate_temp_id("t");
        let temp_message_id = self.allocate_temp_id("m");
        let (sync, sync_error) = match error {
            ForgeWriteError::Transient(_) => {
                let op = if anchor.kind == AnchorKind::Pr {
                    QueuedCommentOp::CreateConversationComment {
                        temp_thread_id: temp_thread_id.clone(),
                        temp_message_id: temp_message_id.clone(),
                        body: body.to_owned(),
                    }
                } else {
                    QueuedCommentOp::CreateReviewThread {
                        temp_thread_id: temp_thread_id.clone(),
                        temp_message_id: temp_message_id.clone(),
                        anchor: anchor.clone(),
                        body: body.to_owned(),
                    }
                };
                self.saved.registry.queued_ops.push(op);
                (MessageSync::Queued, None)
            }
            ForgeWriteError::Rejected(reason) => (MessageSync::Failed, Some(reason)),
        };
        let message = self.create_optimistic_message(&temp_message_id, body, sync, sync_error);
        let thread = Thread {
            id: temp_thread_id,
            origin: Origin::Github,
            anchor,
            state: ThreadState::Open,
            outdated: false,
            messages: vec![message],
        };
        self.threads.push(thread.clone());
        let view = self.save_and_announce_threads()?;
        Ok((thread, view))
    }

    pub(super) fn record_failed_or_queued_reply(
        &mut self,
        thread_id: &str,
        root_database_id: Option<String>,
        body: &str,
        error: ForgeWriteError,
    ) -> Result<(Thread, SessionView)> {
        let temp_message_id = self.allocate_temp_id("m");
        let (sync, sync_error) = match error {
            ForgeWriteError::Transient(_) => {
                self.saved
                    .registry
                    .queued_ops
                    .push(QueuedCommentOp::ReplyToThread {
                        thread_id: thread_id.to_owned(),
                        root_database_id,
                        temp_message_id: temp_message_id.clone(),
                        body: body.to_owned(),
                    });
                (MessageSync::Queued, None)
            }
            ForgeWriteError::Rejected(reason) => (MessageSync::Failed, Some(reason)),
        };
        let message = self.create_optimistic_message(&temp_message_id, body, sync, sync_error);
        let thread = self.push_reply_message(thread_id, message)?;
        let view = self.save_and_announce_threads()?;
        Ok((thread, view))
    }

    pub(super) fn record_failed_or_queued_edit(
        &mut self,
        thread_id: &str,
        anchor_kind: AnchorKind,
        message_id: &str,
        body: &str,
        error: ForgeWriteError,
    ) -> Result<(Thread, SessionView)> {
        let (sync, sync_error) = match error {
            ForgeWriteError::Transient(_) => {
                self.saved
                    .registry
                    .queued_ops
                    .push(QueuedCommentOp::EditMessage {
                        thread_id: thread_id.to_owned(),
                        anchor_kind,
                        message_id: message_id.to_owned(),
                        body: body.to_owned(),
                    });
                (MessageSync::Queued, None)
            }
            ForgeWriteError::Rejected(reason) => (MessageSync::Failed, Some(reason)),
        };
        let target = find_message_mut(&mut self.threads, message_id)
            .with_context(|| format!("unknown message {message_id}"))?;
        body.clone_into(&mut target.body);
        target.sync = Some(sync);
        target.sync_error = sync_error;
        let thread = self
            .find_thread(thread_id)
            .context("thread disappeared")?
            .clone();
        let view = self.save_and_announce_threads()?;
        Ok((thread, view))
    }

    pub(super) fn edit_unflushed_message(
        &mut self,
        thread_id: &str,
        message_id: &str,
        current_sync: Option<MessageSync>,
        body: &str,
    ) -> Result<Option<(Thread, SessionView)>> {
        if !matches!(
            current_sync,
            Some(MessageSync::Queued | MessageSync::Failed)
        ) {
            return Ok(None);
        }
        if self.update_queued_op_body(message_id, body) {
            let target = find_message_mut(&mut self.threads, message_id)
                .with_context(|| format!("unknown message {message_id}"))?;
            body.clone_into(&mut target.body);
            target.sync_error = None;
            let thread = self
                .find_thread(thread_id)
                .context("thread disappeared")?
                .clone();
            let view = self.save_and_announce_threads()?;
            return Ok(Some((thread, view)));
        }
        if message_id.starts_with("tmp-") {
            self.enqueue_failed_message(message_id, Some(body))?;
            let _ = self.send_queued_comments();
            let canonical_thread_id = self.get_canonical_id_from_id(thread_id);
            let thread = self
                .find_thread(&canonical_thread_id)
                .context("thread disappeared")?
                .clone();
            let view = self.save_and_announce_threads()?;
            return Ok(Some((thread, view)));
        }
        Ok(None)
    }

    pub(super) fn refresh_pending_review_id(&mut self, pr: &PullRequest) {
        if let Ok(snapshot) = self.ports.forge.fetch(pr) {
            self.saved.registry.pending_review_id = snapshot.pending_review_id;
        }
    }

    pub(super) fn find_thread(&self, thread_id: &str) -> Option<&Thread> {
        self.threads.iter().find(|thread| thread.id == thread_id)
    }

    pub(super) fn find_thread_mut(&mut self, thread_id: &str) -> Option<&mut Thread> {
        self.threads
            .iter_mut()
            .find(|thread| thread.id == thread_id)
    }

    pub(super) fn locate_message(
        &self,
        message_id: &str,
    ) -> Result<(String, AnchorKind, Option<MessageSync>)> {
        self.threads
            .iter()
            .find_map(|thread| {
                thread
                    .messages
                    .iter()
                    .find(|message| message.id == message_id)
                    .map(|message| (thread.id.clone(), thread.anchor.kind, message.sync))
            })
            .with_context(|| format!("unknown message {message_id}"))
    }

    pub(super) fn push_reply_message(
        &mut self,
        thread_id: &str,
        message: Message,
    ) -> Result<Thread> {
        let thread = self
            .find_thread_mut(thread_id)
            .with_context(|| format!("unknown thread {thread_id}"))?;
        thread.messages.push(message);
        Ok(thread.clone())
    }

    pub(super) fn replace_message(
        &mut self,
        thread_id: &str,
        message_id: &str,
        replacement: Message,
    ) -> Result<Thread> {
        let thread = self
            .find_thread_mut(thread_id)
            .with_context(|| format!("unknown thread {thread_id}"))?;
        let slot = thread
            .messages
            .iter_mut()
            .find(|message| message.id == message_id)
            .with_context(|| format!("unknown message {message_id}"))?;
        *slot = replacement;
        Ok(thread.clone())
    }

    pub(super) fn apply_reaction_result(
        &mut self,
        message_id: &str,
        content: review_model::ReactionContent,
        is_added: bool,
        previous_reactions: Vec<review_model::Reaction>,
        result: std::result::Result<Vec<review_model::Reaction>, ForgeWriteError>,
    ) -> Result<()> {
        match result {
            Ok(reactions) => {
                if let Some(target) = find_message_mut(&mut self.threads, message_id) {
                    target.reactions = reactions;
                }
                Ok(())
            }
            Err(ForgeWriteError::Transient(_)) => {
                self.saved
                    .registry
                    .queued_ops
                    .push(QueuedCommentOp::SetReaction {
                        subject_id: message_id.to_owned(),
                        content,
                        added: is_added,
                    });
                Ok(())
            }
            Err(ForgeWriteError::Rejected(reason)) => {
                if let Some(target) = find_message_mut(&mut self.threads, message_id) {
                    target.reactions = previous_reactions;
                }
                bail!("{reason}");
            }
        }
    }

    fn create_optimistic_message(
        &self,
        id: &str,
        body: &str,
        sync: MessageSync,
        sync_error: Option<String>,
    ) -> Message {
        let author = self
            .saved
            .registry
            .viewer_login
            .clone()
            .unwrap_or_else(|| "you".to_owned());
        let timestamp = self.ports.clock.now().to_string();
        let mut message = Message::create_with_sync(id, &author, body, &timestamp, Some(sync));
        message.viewer_did_author = true;
        message.sync_error = sync_error;
        message
    }
}
