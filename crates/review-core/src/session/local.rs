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

    pub(super) fn is_local_thread(&self, thread_id: &str) -> bool {
        self.find_thread(thread_id)
            .is_some_and(|thread| thread.origin == Origin::Local)
    }

    pub(super) fn is_local_message(&self, message_id: &str) -> bool {
        self.threads.iter().any(|thread| {
            thread.origin == Origin::Local
                && thread
                    .messages
                    .iter()
                    .any(|message| message.id == message_id)
        })
    }

    pub(super) const fn allocate_local_id(&mut self) -> u64 {
        self.saved.local.next_local_id += 1;
        self.saved.local.next_local_id
    }

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

    pub(super) fn capture_disk_snapshot(&self, path: &str, anchor: &Anchor) -> Option<String> {
        let bytes = self.ports.workspace.file_on_disk(path).ok().flatten()?;
        if bytes.len() > super::diffs::MAX_DIFF_BYTES {
            return None;
        }
        let text = FileText::from_bytes(Some(bytes));
        let content = text.as_text()?;
        extract_snapshot_from_text(content, anchor)
    }

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
mod tests {
    use review_model::{
        AgentThreadState, Anchor, MessageSync, Origin, ReactionContent, Side, Thread, ThreadState,
    };

    use super::super::test_support::Fakes;
    use crate::ports::ReviewStore;

    fn create_local_comment(
        session: &mut super::super::ReviewSession,
        path: &str,
        line: u64,
        body: &str,
    ) -> Thread {
        session
            .comment_with_origin(Anchor::line(path, line), body, Origin::Local)
            .unwrap()
            .0
    }

    #[test]
    fn local_comments_save_to_local_store_without_touching_forge() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        fakes
            .forge
            .fail_writes_with(Some("forge must not be called"));

        let (thread, view) = session
            .comment_with_origin(
                Anchor::line("src/a.rs", 1),
                "Ask agent about lifetime",
                Origin::Local,
            )
            .unwrap();

        assert_eq!(thread.origin, Origin::Local);
        assert_eq!(thread.agent, Some(AgentThreadState::Unsent));
        assert!(thread.messages[0].sync.is_none());
        assert!(thread.messages[0].viewer_did_author);
        assert_eq!(view.local_unsent_count, 1);
        assert_eq!(view.draft_count, 0);
        assert_eq!(fakes.store.saved().local.threads.len(), 1);
        assert!(
            fakes
                .store
                .saved()
                .registry
                .threads
                .iter()
                .all(|item| item.origin == Origin::Github)
        );
    }

    #[test]
    fn local_threads_survive_sync_without_leaking_into_registry() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let thread = create_local_comment(&mut session, "src/a.rs", 1, "Ask agent");

        let synced_view = session.sync().unwrap();

        assert_eq!(synced_view.local_unsent_count, 1);
        assert!(
            session
                .threads()
                .iter()
                .any(|item| item.id == thread.id && item.origin == Origin::Local)
        );
        assert_eq!(fakes.store.saved().local.threads.len(), 1);
        assert!(
            fakes
                .store
                .saved()
                .registry
                .threads
                .iter()
                .all(|item| item.origin == Origin::Github)
        );
    }

    #[test]
    fn agent_reply_refuses_github_threads_optimistic_ids_and_unknown_threads() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();

        for forbidden in ["T1", "PRRT_123", "IC_1", "PRRC_1", "tmp-t-1"] {
            let error = session
                .agent_reply(forbidden, "Done.", None)
                .expect_err("GitHub thread must be refused");
            assert!(
                error.to_string().contains("GitHub thread"),
                "unexpected error for {forbidden}: {error}"
            );
        }

        assert_eq!(
            session
                .agent_reply("loc-999", "Unknown", None)
                .unwrap_err()
                .to_string(),
            "unknown local thread loc-999"
        );
    }

    #[test]
    fn agent_reply_flips_state_to_answered_and_reviewer_reply_reopens_to_unsent() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let local = create_local_comment(&mut session, "src/a.rs", 1, "Why clone here?");

        let (answered, view) = session
            .agent_reply(&local.id, "Done. (abc1234)", Some("   "))
            .unwrap();
        assert_eq!(answered.agent, Some(AgentThreadState::Answered));
        let reply_message = answered.messages.last().unwrap();
        assert_eq!(reply_message.author, "agent");
        assert!(!reply_message.viewer_did_author);
        assert!(reply_message.sync.is_none());
        assert_eq!(view.local_unsent_count, 0);

        let (reopened, view_after_user_reply) = session
            .reply(&local.id, "What about empty slices?")
            .unwrap();
        assert_eq!(reopened.agent, Some(AgentThreadState::Unsent));
        assert!(reopened.messages.last().unwrap().viewer_did_author);
        assert_eq!(view_after_user_reply.local_unsent_count, 1);

        let (custom, _) = session
            .agent_reply(&local.id, "Handled empty slices.", Some(" claude "))
            .unwrap();
        assert_eq!(custom.messages.last().unwrap().author, "claude");
    }

    #[test]
    fn promoting_local_thread_creates_github_draft_and_rejects_duplicates() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        assert!(session.promote_thread("T1", "Note").is_err());
        assert!(session.promote_thread("loc-999", "Note").is_err());

        let local = create_local_comment(&mut session, "src/a.rs", 1, "Check bounds");
        session.agent_reply(&local.id, "Verified.", None).unwrap();

        let (github_draft, view) = session
            .promote_thread(&local.id, "Polished note for PR author")
            .unwrap();
        assert_eq!(github_draft.origin, Origin::Github);
        assert_eq!(github_draft.messages.len(), 1);
        assert_eq!(github_draft.messages[0].body, "Polished note for PR author");
        assert_eq!(github_draft.messages[0].sync, Some(MessageSync::Draft));
        assert_eq!(view.draft_count, 1);

        let duplicate_error = session
            .promote_thread(&local.id, "Second promotion")
            .expect_err("duplicate promotion must be refused");
        assert!(duplicate_error.to_string().contains("already promoted"));
    }

    #[test]
    fn promote_thread_emits_single_event_and_clears_snapshot() {
        let fakes = Fakes::new(100);
        fakes.workspace.put_disk("src/a.rs", "let x = 1;\n");
        let mut session = fakes.open_synced();
        let local = create_local_comment(&mut session, "src/a.rs", 1, "Check bounds");
        assert!(local.anchor.snapshot.is_some());

        let events = session.subscribe();
        let (github_draft, _) = session
            .promote_thread(&local.id, "Polished note for PR author")
            .unwrap();

        assert!(github_draft.anchor.snapshot.is_none());
        assert!(matches!(
            events.try_recv().unwrap(),
            review_model::Event::ThreadsChanged { .. }
        ));
        assert!(events.try_recv().is_err());
    }

    #[test]
    fn offline_promote_thread_remaps_promoted_to_on_sync() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let local = create_local_comment(&mut session, "src/a.rs", 1, "Check bounds");

        fakes.forge.fail_writes_with(Some("offline"));
        let (optimistic, _) = session
            .promote_thread(&local.id, "Draft while offline")
            .unwrap();
        assert!(optimistic.id.starts_with("tmp-"));

        fakes.forge.fail_writes_with(None);
        session.sync().unwrap();

        let stored_local = fakes
            .store
            .saved()
            .local
            .threads
            .into_iter()
            .find(|item| item.id == local.id)
            .expect("local thread remains persisted");
        let promoted_id = stored_local.promoted_to.expect("promoted_to stays set");
        assert!(
            !promoted_id.starts_with("tmp-"),
            "expected real GitHub ID, got {promoted_id}"
        );
        assert!(
            session
                .threads()
                .iter()
                .any(|item| item.origin == Origin::Github && item.id == promoted_id)
        );
    }

    #[test]
    fn deleting_offline_promoted_draft_clears_promoted_to_for_repromotion() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let local = create_local_comment(&mut session, "src/a.rs", 1, "Check bounds");

        fakes.forge.fail_writes_with(Some("offline"));
        let (optimistic, _) = session
            .promote_thread(&local.id, "Draft while offline")
            .unwrap();
        let draft_message_id = &optimistic.messages[0].id;

        session.delete_message(draft_message_id).unwrap();
        let cleared = session
            .threads()
            .iter()
            .find(|item| item.id == local.id)
            .unwrap();
        assert!(cleared.promoted_to.is_none());
        assert!(fakes.store.saved().local.threads[0].promoted_to.is_none());

        fakes.forge.fail_writes_with(None);
        let (repromoted, _) = session.promote_thread(&local.id, "Second try").unwrap();
        assert_eq!(repromoted.origin, Origin::Github);
    }

    #[test]
    fn deleting_online_promoted_thread_clears_promoted_to_after_last_message() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let local = create_local_comment(&mut session, "src/a.rs", 1, "Check bounds");

        let (promoted, _) = session.promote_thread(&local.id, "Draft note").unwrap();
        let (with_reply, _) = session.reply(&promoted.id, "Extra detail").unwrap();
        session.delete_message(&with_reply.messages[1].id).unwrap();
        assert_eq!(
            session
                .threads()
                .iter()
                .find(|item| item.id == local.id)
                .unwrap()
                .promoted_to
                .as_deref(),
            Some(promoted.id.as_str())
        );

        session.delete_message(&with_reply.messages[0].id).unwrap();
        let cleared = session
            .threads()
            .iter()
            .find(|item| item.id == local.id)
            .unwrap();
        assert!(cleared.promoted_to.is_none());
        assert!(fakes.store.saved().local.threads[0].promoted_to.is_none());

        let (repromoted, _) = session.promote_thread(&local.id, "Second try").unwrap();
        assert_eq!(repromoted.origin, Origin::Github);
        assert_ne!(repromoted.id, promoted.id);
    }

    #[test]
    fn deleting_transient_queued_promoted_thread_and_reconcile_clears_promoted_to() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let local = create_local_comment(&mut session, "src/a.rs", 1, "Check bounds");
        let (promoted, _) = session.promote_thread(&local.id, "Draft note").unwrap();

        let mut remote_snapshot = super::super::test_support::create_snapshot();
        remote_snapshot.threads.push(promoted.clone());
        fakes.forge.set_snapshot(remote_snapshot);

        fakes.forge.fail_writes_with(Some("offline"));
        session.delete_message(&promoted.messages[0].id).unwrap();
        assert!(
            session
                .threads()
                .iter()
                .find(|item| item.id == local.id)
                .unwrap()
                .promoted_to
                .is_none()
        );
        assert!(fakes.store.saved().local.threads[0].promoted_to.is_none());

        let mut stale_saved = fakes.store.saved();
        stale_saved.local.threads[0].promoted_to = Some(promoted.id.clone());
        fakes.store.save(&stale_saved).unwrap();
        let mut reopened = fakes.open();
        reopened.sync().unwrap();
        assert!(
            reopened
                .threads()
                .iter()
                .find(|item| item.id == local.id)
                .unwrap()
                .promoted_to
                .is_none()
        );
        assert!(fakes.store.saved().local.threads[0].promoted_to.is_none());

        fakes.forge.fail_writes_with(None);
        let (repromoted, _) = reopened.promote_thread(&local.id, "Second try").unwrap();
        assert_eq!(repromoted.origin, Origin::Github);
    }

    #[test]
    fn retry_message_refuses_local_messages_without_touching_forge() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let local = create_local_comment(&mut session, "src/a.rs", 1, "Check bounds");
        fakes.forge.fail_with(Some("offline"));

        let error = session
            .retry_message(&local.messages[0].id)
            .expect_err("local message cannot be retried on GitHub");
        assert!(
            error
                .to_string()
                .contains("local comments cannot be retried")
        );
    }

    #[test]
    fn reopening_restores_local_threads_and_allocates_unique_ids() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let first = create_local_comment(&mut session, "src/a.rs", 1, "First question");
        assert_eq!(first.id, "loc-1");
        assert_eq!(first.messages[0].id, "loc-m-1");

        let mut reopened = fakes.open();
        assert_eq!(reopened.view().local_unsent_count, 1);
        let second = create_local_comment(&mut reopened, "src/b.rs", 1, "Second question");
        assert_eq!(second.id, "loc-2");
        assert_eq!(second.messages[0].id, "loc-m-2");
        assert_eq!(reopened.view().local_unsent_count, 2);
    }

    #[test]
    fn local_mutations_reject_blank_bodies() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let local = create_local_comment(&mut session, "src/a.rs", 1, "Valid body");
        let message_id = &local.messages[0].id;

        assert!(
            session
                .comment_with_origin(Anchor::line("src/a.rs", 1), "   ", Origin::Local)
                .is_err()
        );
        assert!(session.reply(&local.id, " \n\t ").is_err());
        assert!(session.edit_message(message_id, "").is_err());
        assert!(session.promote_thread(&local.id, "   ").is_err());
    }

    #[test]
    fn local_snapshot_captures_right_side_and_handles_missing_or_out_of_bounds() {
        let fakes = Fakes::new(100);
        fakes
            .workspace
            .put_disk("src/a.rs", "fn a() {}\nlet x = 1;\n");
        let mut session = fakes.open_synced();

        let captured = create_local_comment(&mut session, "src/a.rs", 2, "Line two");
        assert_eq!(captured.anchor.snapshot.as_deref(), Some("let x = 1;"));

        let (left_thread, _) = session
            .comment_with_origin(
                Anchor::side_line("src/a.rs", Side::Left, 1),
                "Base line",
                Origin::Local,
            )
            .unwrap();
        assert!(left_thread.anchor.snapshot.is_none());

        let out_of_bounds = create_local_comment(&mut session, "src/a.rs", 99, "Past EOF");
        assert!(out_of_bounds.anchor.snapshot.is_none());

        let missing_disk = create_local_comment(&mut session, "src/b.rs", 1, "Missing file");
        assert!(missing_disk.anchor.snapshot.is_none());
    }

    #[test]
    fn local_pr_anchor_is_normalized_and_oversized_disk_skips_snapshot() {
        let fakes = Fakes::new(100);
        fakes.workspace.put_disk(
            "src/a.rs",
            &"x\n".repeat(super::super::diffs::MAX_DIFF_BYTES / 2 + 1),
        );
        let mut session = fakes.open_synced();

        let oversized = create_local_comment(&mut session, "src/a.rs", 1, "Too big");
        assert!(oversized.anchor.snapshot.is_none());

        let mut dirty_pr_anchor = Anchor::pr();
        dirty_pr_anchor.file = Some("src/a.rs".into());
        let (normalized, _) = session
            .comment_with_origin(dirty_pr_anchor, "PR note", Origin::Local)
            .unwrap();
        assert!(normalized.anchor.file.is_none());
    }

    #[test]
    fn local_edit_resolve_and_reaction_work_offline_without_forge() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let local = create_local_comment(&mut session, "src/a.rs", 1, "Initial");
        let (conversation_thread, _) = session
            .comment_with_origin(Anchor::pr(), "PR note", Origin::Local)
            .unwrap();

        fakes.forge.fail_with(Some("offline"));
        let mut reopened = fakes.open();
        let message_id = local.messages[0].id.clone();

        let (edited, _) = reopened.edit_message(&message_id, "Edited").unwrap();
        assert_eq!(edited.messages[0].body, "Edited");

        let (reacted, _) = reopened
            .toggle_reaction(&message_id, ReactionContent::ThumbsUp)
            .unwrap();
        assert!(reacted.messages[0].reactions[0].viewer_has_reacted);

        let (resolved, _) = reopened.set_resolved(&local.id, true).unwrap();
        assert_eq!(resolved.state, ThreadState::Resolved);
        let (reopened_thread, _) = reopened.set_resolved(&local.id, false).unwrap();
        assert_eq!(reopened_thread.state, ThreadState::Open);

        assert!(
            reopened
                .set_resolved(&conversation_thread.id, true)
                .is_err()
        );
    }

    #[test]
    fn delete_local_message_reconciles_agent_state_and_drops_empty_thread() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let local = create_local_comment(&mut session, "src/a.rs", 1, "Initial");

        let (answered, _) = session.agent_reply(&local.id, "Fixed.", None).unwrap();
        let (with_followup, _) = session.reply(&local.id, "One more check").unwrap();
        let followup_id = &with_followup.messages[2].id;
        session.delete_message(followup_id).unwrap();
        assert_eq!(
            session.threads().last().unwrap().agent,
            Some(AgentThreadState::Answered)
        );

        let agent_message_id = &answered.messages[1].id;
        session.delete_message(agent_message_id).unwrap();
        assert_eq!(
            session.threads().last().unwrap().agent,
            Some(AgentThreadState::Unsent)
        );

        let view = session.delete_message(&local.messages[0].id).unwrap();
        assert!(session.threads().iter().all(|item| item.id != local.id));
        assert!(fakes.store.saved().local.threads.is_empty());
        assert_eq!(view.local_unsent_count, 0);
    }
}
