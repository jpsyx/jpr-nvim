//! Local-only threads, agent replies, and promotion to GitHub drafts.

use anyhow::{Context, Result, bail};
use review_diff::FileText;
use review_model::{
    AgentThreadState, Anchor, AnchorKind, Message, Origin, ReactionContent, SessionView, Side,
    Thread, ThreadState,
};

use super::ReviewSession;
use crate::comments::toggle_reaction_in_list;
use crate::reanchor::extract_snapshot_from_text;

impl ReviewSession {
    /// Creates a review thread or PR conversation comment with `origin`
    /// (`Origin::Github` drafts/publishes on the forge; `Origin::Local` stores
    /// locally in `local.json` without touching GitHub).
    pub fn comment_with_origin(
        &mut self,
        anchor: Anchor,
        body: &str,
        origin: Origin,
    ) -> Result<(Thread, SessionView)> {
        if body.trim().is_empty() {
            bail!("comment body cannot be empty");
        }
        match origin {
            Origin::Github => {
                let thread = self.create_github_thread_entry(anchor, body)?;
                let view = self.save_and_announce_threads()?;
                Ok((thread, view))
            }
            Origin::Local => self.create_local_thread(anchor, body),
        }
    }

    /// Appends an agent-authored reply to local `thread_id`, marks the thread
    /// [`AgentThreadState::Answered`], saves, and announces the updated threads.
    ///
    /// Refuses GitHub threads and GitHub or optimistic thread identifiers so
    /// agent automation can never touch pull-request threads on the forge.
    pub fn agent_reply(
        &mut self,
        thread_id: &str,
        body: &str,
        author: Option<&str>,
    ) -> Result<(Thread, SessionView)> {
        if body.trim().is_empty() {
            bail!("reply body cannot be empty");
        }
        if self.is_forbidden_github_thread_target(thread_id) {
            bail!(
                "refusing to reply to GitHub thread {thread_id}: agent replies are allowed only on local threads"
            );
        }
        if self.find_thread(thread_id).is_none() {
            bail!("unknown local thread {thread_id}");
        }
        let sequence = self.allocate_local_id();
        let message_id = format!("loc-m-{sequence}");
        let reply_author = author
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .unwrap_or("agent");
        let message = self.create_local_message(&message_id, Some(reply_author), body, false);
        let thread = self
            .find_thread_mut(thread_id)
            .with_context(|| format!("unknown local thread {thread_id}"))?;
        thread.messages.push(message);
        thread.agent = Some(AgentThreadState::Answered);
        let updated = thread.clone();
        let view = self.save_and_announce_threads()?;
        Ok((updated, view))
    }

    /// Promotes local `thread_id` into a new GitHub thread (draft code thread
    /// or published PR comment) with `body`, records `promoted_to` on the local
    /// thread, saves, and announces the updated threads.
    pub fn promote_thread(&mut self, thread_id: &str, body: &str) -> Result<(Thread, SessionView)> {
        if body.trim().is_empty() {
            bail!("comment body cannot be empty");
        }
        let mut anchor = {
            let local_thread = self
                .find_thread(thread_id)
                .with_context(|| format!("unknown thread {thread_id}"))?;
            if local_thread.origin != Origin::Local {
                bail!("only local threads can be promoted to GitHub");
            }
            if let Some(existing) = local_thread.promoted_to.as_deref() {
                bail!("local thread {thread_id} was already promoted to {existing}");
            }
            local_thread.anchor.clone()
        };
        anchor.snapshot = None;
        let github_thread = self.create_github_thread_entry(anchor, body)?;
        if let Some(local_thread) = self.find_thread_mut(thread_id) {
            local_thread.promoted_to = Some(github_thread.id.clone());
        }
        let view = self.save_and_announce_threads()?;
        Ok((github_thread, view))
    }

    /// Returns whether `thread_id` refers to an existing local-only thread.
    pub(super) fn is_local_thread(&self, thread_id: &str) -> bool {
        self.find_thread(thread_id)
            .is_some_and(|thread| thread.origin == Origin::Local)
    }

    /// Returns whether `message_id` belongs to a local-only thread.
    pub(super) fn is_local_message(&self, message_id: &str) -> bool {
        self.threads.iter().any(|thread| {
            thread.origin == Origin::Local
                && thread
                    .messages
                    .iter()
                    .any(|message| message.id == message_id)
        })
    }

    /// Increments and returns the monotonic local ID sequence counter.
    pub(super) const fn allocate_local_id(&mut self) -> u64 {
        self.saved.local.next_local_id += 1;
        self.saved.local.next_local_id
    }

    /// Appends a reviewer reply to local `thread_id` and marks it `Unsent`.
    pub(super) fn reply_local_thread(
        &mut self,
        thread_id: &str,
        body: &str,
    ) -> Result<(Thread, SessionView)> {
        if body.trim().is_empty() {
            bail!("reply body cannot be empty");
        }
        if !self.is_local_thread(thread_id) {
            bail!("unknown local thread {thread_id}");
        }
        let sequence = self.allocate_local_id();
        let message_id = format!("loc-m-{sequence}");
        let message = self.create_local_message(&message_id, None, body, true);
        let thread = self
            .find_thread_mut(thread_id)
            .with_context(|| format!("unknown local thread {thread_id}"))?;
        thread.messages.push(message);
        thread.agent = Some(AgentThreadState::Unsent);
        let updated = thread.clone();
        let view = self.save_and_announce_threads()?;
        Ok((updated, view))
    }

    /// Replaces the body of local `message_id` and persists the thread.
    pub(super) fn edit_local_message(
        &mut self,
        message_id: &str,
        body: &str,
    ) -> Result<(Thread, SessionView)> {
        if body.trim().is_empty() {
            bail!("message body cannot be empty");
        }
        let timestamp = self.ports.clock.now().to_string();
        let thread = self
            .threads
            .iter_mut()
            .find(|item| {
                item.origin == Origin::Local
                    && item.messages.iter().any(|message| message.id == message_id)
            })
            .with_context(|| format!("unknown local message {message_id}"))?;
        let message = thread
            .messages
            .iter_mut()
            .find(|item| item.id == message_id)
            .context("message disappeared")?;
        body.clone_into(&mut message.body);
        message.updated = timestamp;
        let updated = thread.clone();
        let view = self.save_and_announce_threads()?;
        Ok((updated, view))
    }

    /// Deletes local `message_id` and reconciles the thread's agent state.
    pub(super) fn delete_local_message(&mut self, message_id: &str) -> Result<SessionView> {
        let thread_id = self
            .threads
            .iter()
            .find_map(|item| {
                (item.origin == Origin::Local
                    && item.messages.iter().any(|message| message.id == message_id))
                .then(|| item.id.clone())
            })
            .with_context(|| format!("unknown local message {message_id}"))?;
        self.remove_message_from_threads(&thread_id, message_id);
        if let Some(thread) = self.find_thread_mut(&thread_id)
            && let Some(last) = thread.messages.last()
        {
            if !last.viewer_did_author {
                thread.agent = Some(AgentThreadState::Answered);
            } else if thread.agent == Some(AgentThreadState::Answered) {
                thread.agent = Some(AgentThreadState::Unsent);
            }
        }
        self.save_and_announce_threads()
    }

    /// Sets the resolved state of local code `thread_id`.
    pub(super) fn set_local_resolved(
        &mut self,
        thread_id: &str,
        is_resolved: bool,
    ) -> Result<(Thread, SessionView)> {
        let thread = self
            .find_thread_mut(thread_id)
            .with_context(|| format!("unknown local thread {thread_id}"))?;
        if thread.origin != Origin::Local {
            bail!("thread {thread_id} is not a local thread");
        }
        if thread.anchor.kind == AnchorKind::Pr {
            bail!("pull-request conversation comments cannot be resolved");
        }
        thread.state = if is_resolved {
            ThreadState::Resolved
        } else {
            ThreadState::Open
        };
        let updated = thread.clone();
        let view = self.save_and_announce_threads()?;
        Ok((updated, view))
    }

    /// Toggles `content` on local `message_id`.
    pub(super) fn toggle_local_reaction(
        &mut self,
        message_id: &str,
        content: ReactionContent,
    ) -> Result<(Thread, SessionView)> {
        let thread = self
            .threads
            .iter_mut()
            .find(|item| {
                item.origin == Origin::Local
                    && item.messages.iter().any(|message| message.id == message_id)
            })
            .with_context(|| format!("unknown local message {message_id}"))?;
        let message = thread
            .messages
            .iter_mut()
            .find(|item| item.id == message_id)
            .context("message disappeared")?;
        toggle_reaction_in_list(&mut message.reactions, content);
        let updated = thread.clone();
        let view = self.save_and_announce_threads()?;
        Ok((updated, view))
    }

    fn create_local_thread(
        &mut self,
        mut anchor: Anchor,
        body: &str,
    ) -> Result<(Thread, SessionView)> {
        if anchor.kind == AnchorKind::Pr {
            anchor = Anchor::pr();
        } else {
            self.validate_anchor_file(&anchor)?;
        }
        if anchor.snapshot.is_none()
            && anchor.side == Side::Right
            && matches!(anchor.kind, AnchorKind::Line | AnchorKind::Range)
            && let Some(path) = anchor.file.as_deref()
        {
            anchor.snapshot = self.capture_disk_snapshot(path, &anchor);
        }
        let sequence = self.allocate_local_id();
        let thread_id = format!("loc-{sequence}");
        let message_id = format!("loc-m-{sequence}");
        let message = self.create_local_message(&message_id, None, body, true);
        let thread = Thread {
            id: thread_id,
            origin: Origin::Local,
            anchor,
            state: ThreadState::Open,
            outdated: false,
            messages: vec![message],
            agent: Some(AgentThreadState::Unsent),
            promoted_to: None,
        };
        self.threads.push(thread.clone());
        let view = self.save_and_announce_threads()?;
        Ok((thread, view))
    }

    /// Reads the UTF-8 line snapshot for `anchor` from worktree `path` when within the diff cap.
    pub(super) fn capture_disk_snapshot(&self, path: &str, anchor: &Anchor) -> Option<String> {
        let bytes = self.ports.workspace.file_on_disk(path).ok().flatten()?;
        if bytes.len() > super::diffs::MAX_DIFF_BYTES {
            return None;
        }
        let text = FileText::from_bytes(Some(bytes));
        let content = text.as_text()?;
        extract_snapshot_from_text(content, anchor)
    }

    /// Creates a local [`Message`] stamped with the session clock and author.
    pub(super) fn create_local_message(
        &self,
        id: &str,
        author_override: Option<&str>,
        body: &str,
        viewer_did_author: bool,
    ) -> Message {
        let author = author_override.map_or_else(
            || {
                self.saved
                    .registry
                    .viewer_login
                    .clone()
                    .unwrap_or_else(|| "you".to_owned())
            },
            str::to_owned,
        );
        let timestamp = self.ports.clock.now().to_string();
        let mut message = Message::create_with_sync(id, &author, body, &timestamp, None);
        message.viewer_did_author = viewer_did_author;
        message
    }

    fn is_forbidden_github_thread_target(&self, thread_id: &str) -> bool {
        let canonical = self.get_canonical_id_from_id(thread_id);
        self.find_thread(thread_id)
            .or_else(|| self.find_thread(&canonical))
            .is_some_and(|thread| thread.origin != Origin::Local)
            || thread_id.starts_with("PRRT_")
            || thread_id.starts_with("IC_")
            || thread_id.starts_with("PRRC_")
            || thread_id.starts_with("tmp-")
    }
}

#[cfg(test)]
mod promotion_tests;
#[cfg(test)]
mod tests;
