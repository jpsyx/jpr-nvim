//! In-memory [`FakeForge`](super::FakeForge) implementations for comments,
//! reactions, thread resolution, and review submission.

use review_model::{
    Anchor, AnchorKind, Message, MessageSync, Origin, Reaction, ReactionContent, ReviewEvent,
    Thread, ThreadState,
};

use super::{FakeForge, ForgeState};
use crate::ports::{CreatedReviewThread, ForgeWriteError, ReplyRequest};

const FAKE_TIMESTAMP: &str = "2026-11-20T00:00:00Z";

fn check_write(state: &ForgeState) -> std::result::Result<(), ForgeWriteError> {
    if let Some(message) = &state.rejected_write_failure {
        return Err(ForgeWriteError::Rejected(message.clone()));
    }
    if let Some(message) = state.failure.as_ref().or(state.write_failure.as_ref()) {
        return Err(ForgeWriteError::Transient(message.clone()));
    }
    Ok(())
}

fn build_fake_message(
    state: &ForgeState,
    id: &str,
    body: &str,
    sync: MessageSync,
    database_id: Option<String>,
) -> Message {
    let author = state
        .snapshot
        .viewer_login
        .clone()
        .unwrap_or_else(|| "alice".to_owned());
    let mut message = Message::create_with_sync(id, &author, body, FAKE_TIMESTAMP, Some(sync));
    message.viewer_did_author = true;
    message.database_id = database_id;
    message
}

fn ensure_anchor_kind_matches(
    thread: &Thread,
    anchor_kind: AnchorKind,
) -> std::result::Result<(), ForgeWriteError> {
    if (thread.anchor.kind == AnchorKind::Pr) != (anchor_kind == AnchorKind::Pr) {
        return Err(ForgeWriteError::Rejected(format!(
            "anchor kind mismatch for thread {}",
            thread.id
        )));
    }
    Ok(())
}

fn find_thread_with_message_mut<'a>(
    threads: &'a mut [Thread],
    message_id: &str,
) -> Option<&'a mut Thread> {
    threads.iter_mut().find(|thread| {
        thread
            .messages
            .iter()
            .any(|message| message.id == message_id)
    })
}

fn apply_reaction(reactions: &mut Vec<Reaction>, content: ReactionContent, added: bool) {
    if let Some(existing) = reactions
        .iter_mut()
        .find(|reaction| reaction.content == content)
    {
        if added && !existing.viewer_has_reacted {
            existing.viewer_has_reacted = true;
            existing.count += 1;
        } else if !added && existing.viewer_has_reacted {
            existing.viewer_has_reacted = false;
            existing.count = existing.count.saturating_sub(1);
        }
    } else if added {
        reactions.push(Reaction {
            content,
            count: 1,
            viewer_has_reacted: true,
        });
    }
    reactions.retain(|reaction| reaction.count > 0);
}

impl FakeForge {
    pub(super) fn create_review_thread_in_memory(
        &self,
        pending_review_id: Option<&str>,
        anchor: &Anchor,
        body: &str,
    ) -> std::result::Result<CreatedReviewThread, ForgeWriteError> {
        let mut state = self.lock();
        check_write(&state)?;
        state.next_id += 1;
        let seq = state.next_id;
        let review_id = pending_review_id
            .map(str::to_owned)
            .or_else(|| state.snapshot.pending_review_id.clone())
            .unwrap_or_else(|| "PRR_fake".to_owned());
        let message = build_fake_message(
            &state,
            &format!("PRRC_fake_{seq}"),
            body,
            MessageSync::Draft,
            Some((1000 + seq).to_string()),
        );
        let thread = Thread {
            id: format!("PRRT_fake_{seq}"),
            origin: Origin::Github,
            anchor: anchor.clone(),
            state: ThreadState::Open,
            outdated: false,
            messages: vec![message],
        };
        state.snapshot.threads.push(thread.clone());
        state.snapshot.has_pending_review = true;
        state.snapshot.pending_review_id = Some(review_id.clone());
        drop(state);
        Ok(CreatedReviewThread {
            pending_review_id: review_id,
            thread,
        })
    }

    pub(super) fn create_conversation_comment_in_memory(
        &self,
        body: &str,
    ) -> std::result::Result<Thread, ForgeWriteError> {
        let mut state = self.lock();
        check_write(&state)?;
        state.next_id += 1;
        let seq = state.next_id;
        let id = format!("IC_fake_{seq}");
        let message = build_fake_message(&state, &id, body, MessageSync::Published, None);
        let thread = Thread {
            id,
            origin: Origin::Github,
            anchor: Anchor::pr(),
            state: ThreadState::Open,
            outdated: false,
            messages: vec![message],
        };
        state.snapshot.threads.push(thread.clone());
        drop(state);
        Ok(thread)
    }

    pub(super) fn reply_to_thread_in_memory(
        &self,
        request: &ReplyRequest<'_>,
    ) -> std::result::Result<Message, ForgeWriteError> {
        let mut state = self.lock();
        check_write(&state)?;
        if !state
            .snapshot
            .threads
            .iter()
            .any(|thread| thread.id == request.thread_id)
        {
            return Err(ForgeWriteError::Rejected(format!(
                "thread not found: {}",
                request.thread_id
            )));
        }
        state.next_id += 1;
        let seq = state.next_id;
        let sync = resolve_reply_sync(&mut state, request);
        let message = build_fake_message(
            &state,
            &format!("PRRC_fake_{seq}"),
            request.body,
            sync,
            Some((1000 + seq).to_string()),
        );
        let thread = state
            .snapshot
            .threads
            .iter_mut()
            .find(|thread| thread.id == request.thread_id)
            .ok_or_else(|| {
                ForgeWriteError::Rejected(format!("thread not found: {}", request.thread_id))
            })?;
        thread.messages.push(message.clone());
        drop(state);
        Ok(message)
    }

    pub(super) fn edit_message_in_memory(
        &self,
        anchor_kind: AnchorKind,
        message_id: &str,
        body: &str,
    ) -> std::result::Result<Message, ForgeWriteError> {
        let mut state = self.lock();
        check_write(&state)?;
        let thread = find_thread_with_message_mut(&mut state.snapshot.threads, message_id)
            .ok_or_else(|| ForgeWriteError::Rejected(format!("message not found: {message_id}")))?;
        ensure_anchor_kind_matches(thread, anchor_kind)?;
        let message = thread
            .messages
            .iter_mut()
            .find(|message| message.id == message_id)
            .ok_or_else(|| ForgeWriteError::Rejected(format!("message not found: {message_id}")))?;
        body.clone_into(&mut message.body);
        "2026-11-20T00:01:00Z".clone_into(&mut message.updated);
        let updated = message.clone();
        drop(state);
        Ok(updated)
    }

    pub(super) fn delete_message_in_memory(
        &self,
        anchor_kind: AnchorKind,
        message_id: &str,
    ) -> std::result::Result<(), ForgeWriteError> {
        let mut state = self.lock();
        check_write(&state)?;
        let thread = find_thread_with_message_mut(&mut state.snapshot.threads, message_id)
            .ok_or_else(|| ForgeWriteError::Rejected(format!("message not found: {message_id}")))?;
        ensure_anchor_kind_matches(thread, anchor_kind)?;
        thread.messages.retain(|message| message.id != message_id);
        state
            .snapshot
            .threads
            .retain(|thread| !thread.messages.is_empty());
        drop(state);
        Ok(())
    }

    pub(super) fn set_resolved_in_memory(
        &self,
        thread_id: &str,
        resolved: bool,
    ) -> std::result::Result<(), ForgeWriteError> {
        let mut state = self.lock();
        check_write(&state)?;
        let thread = state
            .snapshot
            .threads
            .iter_mut()
            .find(|thread| thread.id == thread_id)
            .ok_or_else(|| ForgeWriteError::Rejected(format!("thread not found: {thread_id}")))?;
        thread.state = if resolved {
            ThreadState::Resolved
        } else {
            ThreadState::Open
        };
        drop(state);
        Ok(())
    }

    pub(super) fn set_reaction_in_memory(
        &self,
        subject_id: &str,
        content: ReactionContent,
        added: bool,
    ) -> std::result::Result<Vec<Reaction>, ForgeWriteError> {
        let mut state = self.lock();
        check_write(&state)?;
        let thread = find_thread_with_message_mut(&mut state.snapshot.threads, subject_id)
            .ok_or_else(|| ForgeWriteError::Rejected(format!("message not found: {subject_id}")))?;
        let message = thread
            .messages
            .iter_mut()
            .find(|message| message.id == subject_id)
            .ok_or_else(|| ForgeWriteError::Rejected(format!("message not found: {subject_id}")))?;
        apply_reaction(&mut message.reactions, content, added);
        let reactions = message.reactions.clone();
        drop(state);
        Ok(reactions)
    }

    pub(super) fn submit_review_in_memory(
        &self,
        _event: ReviewEvent,
        _body: &str,
    ) -> std::result::Result<(), ForgeWriteError> {
        let mut state = self.lock();
        check_write(&state)?;
        for thread in &mut state.snapshot.threads {
            for message in &mut thread.messages {
                if message.sync == Some(MessageSync::Draft) {
                    message.sync = Some(MessageSync::Published);
                }
            }
        }
        state.snapshot.has_pending_review = false;
        state.snapshot.pending_review_id = None;
        drop(state);
        Ok(())
    }
}

fn resolve_reply_sync(state: &mut ForgeState, request: &ReplyRequest<'_>) -> MessageSync {
    let needs_pending_review = request.pending_review_id.is_none()
        && request.root_database_id.is_none()
        && !state.snapshot.has_pending_review;
    if needs_pending_review {
        state.snapshot.has_pending_review = true;
        if state.snapshot.pending_review_id.is_none() {
            state.snapshot.pending_review_id = Some("PRR_fake".to_owned());
        }
    }
    if request.pending_review_id.is_some()
        || request.root_database_id.is_none()
        || state.snapshot.has_pending_review
    {
        MessageSync::Draft
    } else {
        MessageSync::Published
    }
}
