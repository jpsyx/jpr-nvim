//! Offline comment queue management, retry enqueueing, and persistence.

mod prune;

use std::collections::VecDeque;

use anyhow::{Context, Result, bail};
use review_model::{AnchorKind, Event, Message, MessageSync, Origin, SessionView, Thread};

use super::super::ReviewSession;
use super::replay::ReplayOutcome;
use crate::comments::{find_message_mut, record_agreed_bodies, remap_queued_ops};
use crate::ports::{ForgeWriteError, QueuedCommentOp};

impl ReviewSession {
    pub(super) fn allocate_temp_id(&mut self, prefix: &str) -> String {
        self.saved.registry.next_temp_id += 1;
        format!("tmp-{prefix}-{}", self.saved.registry.next_temp_id)
    }

    pub(in super::super) fn get_canonical_id_from_id(&self, id: &str) -> String {
        self.saved
            .registry
            .id_map
            .get(id)
            .cloned()
            .unwrap_or_else(|| id.to_owned())
    }

    pub(in super::super) fn save_and_announce_threads(&mut self) -> Result<SessionView> {
        record_agreed_bodies(&self.threads, &mut self.saved.registry.agreed_bodies);
        self.split_and_save_threads()?;
        let view = self.view();
        self.publish(&Event::ThreadsChanged {
            view: Box::new(view.clone()),
        });
        Ok(view)
    }

    pub(super) fn update_queued_op_body(&mut self, message_id: &str, body: &str) -> bool {
        let mut was_updated = false;
        for op in &mut self.saved.registry.queued_ops {
            match op {
                QueuedCommentOp::CreateReviewThread {
                    temp_message_id,
                    body: op_body,
                    ..
                }
                | QueuedCommentOp::CreateConversationComment {
                    temp_message_id,
                    body: op_body,
                    ..
                }
                | QueuedCommentOp::ReplyToThread {
                    temp_message_id,
                    body: op_body,
                    ..
                } if temp_message_id == message_id => {
                    body.clone_into(op_body);
                    was_updated = true;
                }
                QueuedCommentOp::EditMessage {
                    message_id: op_message_id,
                    body: op_body,
                    ..
                } if op_message_id == message_id => {
                    body.clone_into(op_body);
                    was_updated = true;
                }
                _ => {}
            }
        }
        was_updated
    }

    pub(super) fn enqueue_failed_message(
        &mut self,
        message_id: &str,
        new_body: Option<&str>,
    ) -> Result<()> {
        let mut op = self.create_retry_op_from_message_id(message_id)?;
        let message = find_message_mut(&mut self.threads, message_id)
            .with_context(|| format!("unknown message {message_id}"))?;
        if let Some(updated_body) = new_body {
            updated_body.clone_into(&mut message.body);
            set_queued_op_body(&mut op, updated_body);
        }
        message.sync = Some(MessageSync::Queued);
        message.sync_error = None;
        self.saved.registry.queued_ops.push(op);
        Ok(())
    }

    fn create_retry_op_from_message_id(&self, message_id: &str) -> Result<QueuedCommentOp> {
        for thread in self
            .threads
            .iter()
            .filter(|thread| thread.origin == Origin::Github)
        {
            let Some(message) = thread.messages.iter().find(|item| item.id == message_id) else {
                continue;
            };
            if message.sync != Some(MessageSync::Failed) {
                bail!("message {message_id} is not in a failed state");
            }
            return Ok(thread_message_to_retry_op(thread, message));
        }
        bail!("unknown message {message_id}")
    }

    /// Replays queued comment operations in FIFO order (stopping on transient
    /// or auth errors while marking rejected operations failed without wedging
    /// later ops) and returns `(has_progressed, auth_error_message)`.
    pub(in super::super) fn send_queued_comments(&mut self) -> (bool, Option<String>) {
        let Some(pr) = self.saved.session.pr.clone() else {
            return (false, None);
        };
        let mut queue = VecDeque::from(std::mem::take(&mut self.saved.registry.queued_ops));
        let mut has_progressed = false;
        let mut auth_error = None;
        while let Some(op) = queue.pop_front() {
            match self.replay_queued_op(&pr, &op, queue.make_contiguous()) {
                ReplayOutcome::Landed | ReplayOutcome::Rejected => has_progressed = true,
                ReplayOutcome::Transient => {
                    queue.push_front(op);
                    break;
                }
                ReplayOutcome::AuthRequired(message) => {
                    queue.push_front(op);
                    auth_error = Some(message);
                    break;
                }
            }
        }
        self.saved.registry.queued_ops = queue.into();
        (has_progressed, auth_error)
    }

    pub(super) fn finish_created_thread(
        &mut self,
        temp_thread_id: &str,
        temp_message_id: &str,
        created_thread: Thread,
        remaining_ops: &mut [QueuedCommentOp],
    ) {
        let real_thread_id = created_thread.id.clone();
        let real_message = created_thread.messages.first().cloned();
        self.promote_optimistic_thread(temp_thread_id, temp_message_id, created_thread);
        self.record_id_mapping(temp_thread_id, &real_thread_id, remaining_ops);
        if let Some(created_message) = real_message {
            self.record_id_mapping(temp_message_id, &created_message.id, remaining_ops);
        }
    }

    pub(super) fn handle_op_message_error(
        &mut self,
        message_id: &str,
        error: ForgeWriteError,
    ) -> ReplayOutcome {
        match error {
            ForgeWriteError::Transient(_) => ReplayOutcome::Transient,
            ForgeWriteError::AuthRequired(reason) => ReplayOutcome::AuthRequired(reason),
            ForgeWriteError::Rejected(reason) => {
                if let Some(message) = find_message_mut(&mut self.threads, message_id) {
                    message.sync = Some(MessageSync::Failed);
                    message.sync_error = Some(reason);
                }
                ReplayOutcome::Rejected
            }
        }
    }

    fn promote_optimistic_thread(
        &mut self,
        temp_thread_id: &str,
        temp_message_id: &str,
        mut real_thread: Thread,
    ) {
        let Some(existing) = self.find_thread_mut(temp_thread_id) else {
            self.threads.push(real_thread);
            return;
        };
        existing.id = real_thread.id;
        existing.origin = real_thread.origin;
        existing.anchor = real_thread.anchor;
        existing.state = real_thread.state;
        existing.outdated = real_thread.outdated;
        if let Some(real_first) = real_thread.messages.drain(..).next() {
            if let Some(slot) = existing
                .messages
                .iter_mut()
                .find(|message| message.id == temp_message_id)
            {
                *slot = real_first;
            } else {
                existing.messages.insert(0, real_first);
            }
        }
    }

    pub(super) fn record_id_mapping(
        &mut self,
        temp_id: &str,
        real_id: &str,
        remaining_ops: &mut [QueuedCommentOp],
    ) {
        self.saved
            .registry
            .id_map
            .insert(temp_id.to_owned(), real_id.to_owned());
        remap_queued_ops(remaining_ops, temp_id, real_id);
        for thread in &mut self.threads {
            if thread.origin == Origin::Local && thread.promoted_to.as_deref() == Some(temp_id) {
                thread.promoted_to = Some(real_id.to_owned());
            }
        }
    }
}

fn thread_message_to_retry_op(thread: &Thread, message: &Message) -> QueuedCommentOp {
    if !message.id.starts_with("tmp-") {
        return QueuedCommentOp::EditMessage {
            thread_id: thread.id.clone(),
            anchor_kind: thread.anchor.kind,
            message_id: message.id.clone(),
            body: message.body.clone(),
        };
    }
    if thread.anchor.kind == AnchorKind::Pr
        && thread.id.starts_with("tmp-")
        && thread
            .messages
            .first()
            .is_some_and(|first| first.id == message.id)
    {
        return QueuedCommentOp::CreateConversationComment {
            temp_thread_id: thread.id.clone(),
            temp_message_id: message.id.clone(),
            body: message.body.clone(),
        };
    }
    if thread.id.starts_with("tmp-")
        && thread
            .messages
            .first()
            .is_some_and(|first| first.id == message.id)
    {
        return QueuedCommentOp::CreateReviewThread {
            temp_thread_id: thread.id.clone(),
            temp_message_id: message.id.clone(),
            anchor: thread.anchor.clone(),
            body: message.body.clone(),
        };
    }
    QueuedCommentOp::ReplyToThread {
        thread_id: thread.id.clone(),
        root_database_id: thread
            .messages
            .first()
            .and_then(|first| first.database_id.clone()),
        temp_message_id: message.id.clone(),
        body: message.body.clone(),
    }
}

fn set_queued_op_body(op: &mut QueuedCommentOp, updated_body: &str) {
    match op {
        QueuedCommentOp::CreateReviewThread { body, .. }
        | QueuedCommentOp::CreateConversationComment { body, .. }
        | QueuedCommentOp::ReplyToThread { body, .. }
        | QueuedCommentOp::EditMessage { body, .. } => updated_body.clone_into(body),
        _ => {}
    }
}
