//! Turning local edits into GitHub suggestion drafts, reading anchored code,
//! and submitting reviews.

use anyhow::{Context, Result, bail};
use review_diff::{FileText, create_suggestion_from_edit};
use review_model::{
    Anchor, AnchorKind, MessageSync, ReviewEvent, SessionView, Side, SubmitPreview, SuggestedEdit,
    Thread,
};

use super::ReviewSession;
use crate::comments::create_submit_preview_from_threads;
use crate::ports::{ForgeWriteError, QueuedCommentOp};

impl ReviewSession {
    /// Reads the exact lines covered by `anchor` (`Left` from the merge base,
    /// `Right` from disk) so a suggestion fence can prefill them.
    pub fn anchored_lines(&mut self, anchor: &Anchor) -> Result<String> {
        let (start_line, end_line) = anchor_line_bounds(anchor)?;
        let path = anchor.file.as_deref().context("anchor has no file path")?;
        let (base, current) = self.file_texts(path)?;
        let source = match anchor.side {
            Side::Left => &base,
            Side::Right => &current,
        };
        if source.is_binary() {
            bail!("{path} is binary");
        }
        let lines = source.lines();
        let start = usize::try_from(start_line - 1)?;
        let end = usize::try_from(end_line)?.min(lines.len());
        if start >= lines.len() || start >= end {
            return Ok(String::new());
        }
        Ok(lines[start..end].join("\n"))
    }

    /// Turns the uncommitted edit around 1-based `cursor_line` of `edited_text`
    /// (measured against `pr.head_sha`) into a draft suggestion thread and
    /// returns the reverted text for that hunk.
    pub fn suggest_from_edit(
        &mut self,
        path: &str,
        edited_text: &str,
        cursor_line: u64,
        comment_body: Option<&str>,
    ) -> Result<(SuggestedEdit, Thread, SessionView)> {
        let pr = self.synced_pr()?.clone();
        if !self.saved.files.iter().any(|file| file.path == path) {
            bail!("{path} is not a file this pull request changes");
        }
        let head_bytes = self
            .ports
            .workspace
            .file_at(&pr.head_sha, path)?
            .with_context(|| format!("{path} does not exist at head commit {}", pr.head_sha))?;
        let head_text = FileText::from_bytes(Some(head_bytes));
        let head_str = head_text
            .as_text()
            .with_context(|| format!("{path} is binary and cannot take a suggestion"))?;
        let suggested = create_suggestion_from_edit(path, head_str, edited_text, cursor_line)
            .context("no uncommitted edit at the cursor line")?;
        let full_body = match comment_body.map(str::trim).filter(|text| !text.is_empty()) {
            Some(prefix) => format!("{prefix}\n\n{}", suggested.suggestion_body),
            None => suggested.suggestion_body.clone(),
        };
        let (thread, view) = self.comment(suggested.anchor.clone(), &full_body)?;
        Ok((suggested, thread, view))
    }

    /// Preview of pending draft comments and allowed review actions.
    pub fn submit_preview(&self) -> Result<SubmitPreview> {
        let pr = self.synced_pr()?;
        let mut preview = create_submit_preview_from_threads(
            &pr.author,
            self.saved.registry.viewer_login.as_deref(),
            &self.threads,
        );
        if preview.blocked_reason.is_none() {
            if self
                .saved
                .registry
                .queued_ops
                .iter()
                .any(|op| matches!(op, QueuedCommentOp::SubmitReview { .. }))
            {
                preview.blocked_reason =
                    Some("a review submission is already queued and waiting for GitHub".to_owned());
            } else if !self.saved.registry.queued_ops.is_empty() {
                preview.blocked_reason =
                    Some("queued comment changes are still waiting for GitHub".to_owned());
            }
        }
        Ok(preview)
    }

    /// Submits the pending review (or a zero-draft review) with `event` and `body`.
    pub fn submit_review(&mut self, event: ReviewEvent, body: &str) -> Result<SessionView> {
        let pr = self.synced_pr()?.clone();
        let preview = self.submit_preview()?;
        if let Some(reason) = preview.blocked_reason {
            bail!("{reason}");
        }
        if !preview.can_approve_or_request_changes && event != ReviewEvent::Comment {
            bail!("GitHub does not allow approving or requesting changes on your own pull request");
        }
        if event != ReviewEvent::Approve && preview.draft_count == 0 && body.trim().is_empty() {
            bail!("a review with zero drafts and this event needs a summary body");
        }
        let pending_id = self.saved.registry.pending_review_id.clone();
        match self
            .ports
            .forge
            .submit_review(&pr, pending_id.as_deref(), event, body)
        {
            Ok(()) => {
                self.mark_drafts_published();
                self.saved.registry.pending_review_id = None;
                self.save_and_announce_threads()
            }
            Err(ForgeWriteError::Transient(_)) => {
                self.saved
                    .registry
                    .queued_ops
                    .push(QueuedCommentOp::SubmitReview {
                        event,
                        body: body.to_owned(),
                    });
                self.save_and_announce_threads()
            }
            Err(ForgeWriteError::Rejected(reason)) => bail!("{reason}"),
        }
    }

    pub(super) fn mark_drafts_published(&mut self) {
        for thread in &mut self.threads {
            for message in &mut thread.messages {
                if message.sync == Some(MessageSync::Draft) {
                    message.sync = Some(MessageSync::Published);
                }
            }
        }
    }
}

fn anchor_line_bounds(anchor: &Anchor) -> Result<(u64, u64)> {
    match anchor.kind {
        AnchorKind::Line => {
            let line = anchor
                .end
                .or(anchor.start)
                .context("line anchor is missing a line number")?;
            if line == 0 {
                bail!("line anchor line number must be at least 1");
            }
            Ok((line, line))
        }
        AnchorKind::Range => {
            let start_line = anchor
                .start
                .context("range anchor is missing a start line")?;
            let end_line = anchor.end.unwrap_or(start_line);
            if start_line == 0 || end_line < start_line {
                bail!("range anchor line bounds {start_line}..={end_line} are invalid");
            }
            Ok((start_line, end_line))
        }
        AnchorKind::File | AnchorKind::Pr => {
            bail!("only line and range anchors have anchored code lines")
        }
    }
}

#[cfg(test)]
mod tests {
    use review_model::{Anchor, MessageSync, ReviewEvent, Side};

    use super::super::test_support::Fakes;
    use crate::ports::ReviewStore;

    #[test]
    fn suggest_from_edit_diffs_against_head_commit_creates_draft_and_returns_reverted_text() {
        let fakes = Fakes::new(100);
        fakes
            .workspace
            .put_at("abc123", "src/a.rs", "let a = 1;\nlet b = 2;\n");
        let mut session = fakes.open_synced();

        let (suggested, thread, view) = session
            .suggest_from_edit("src/a.rs", "let a = 10;\nlet b = 2;\n", 1, Some("Use 10:"))
            .unwrap();
        assert_eq!(suggested.reverted_text, "let a = 1;\nlet b = 2;\n");
        assert!(
            thread.messages[0]
                .body
                .contains("Use 10:\n\n```suggestion\nlet a = 10;\n```")
        );
        assert_eq!(view.draft_count, 1);
    }

    #[test]
    fn anchored_lines_reads_left_from_merge_base_and_right_from_disk() {
        let fakes = Fakes::new(100);
        fakes.workspace.put_base("src/a.rs", "old_1\nold_2\n");
        fakes.workspace.put_disk("src/a.rs", "new_1\nnew_2\n");
        let mut session = fakes.open_synced();

        let left = session
            .anchored_lines(&Anchor::range("src/a.rs", Side::Left, 1, 2))
            .unwrap();
        let right = session
            .anchored_lines(&Anchor::side_line("src/a.rs", Side::Right, 2))
            .unwrap();
        assert_eq!(left, "old_1\nold_2");
        assert_eq!(right, "new_2");
    }

    #[test]
    fn submit_review_publishes_all_drafts_and_blocks_self_approval() {
        let fakes = Fakes::new(100);
        let mut snap = super::super::test_support::create_snapshot();
        snap.viewer_login = Some("alice".into());
        fakes.forge.set_snapshot(snap);
        let mut session = fakes.open_synced();
        session
            .comment(Anchor::line("src/a.rs", 1), "draft note")
            .unwrap();

        let preview = session.submit_preview().unwrap();
        assert_eq!(preview.draft_count, 1);
        assert!(!preview.can_approve_or_request_changes);
        assert!(
            session
                .submit_review(ReviewEvent::Approve, "")
                .unwrap_err()
                .to_string()
                .contains("own pull request")
        );

        let view = session
            .submit_review(ReviewEvent::Comment, "overall summary")
            .unwrap();
        assert_eq!(view.draft_count, 0);
        assert_eq!(
            session.threads().last().unwrap().messages[0].sync,
            Some(MessageSync::Published)
        );
    }

    #[test]
    fn submit_review_refuses_when_queued_or_failed_comment_exists() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        fakes.forge.fail_writes_with(Some("offline"));
        session
            .comment(Anchor::line("src/a.rs", 2), "queued note")
            .unwrap();

        let queued_preview = session.submit_preview().unwrap();
        assert!(
            queued_preview
                .blocked_reason
                .as_deref()
                .is_some_and(|reason| reason.contains("queued"))
        );
        let queued_error = session
            .submit_review(ReviewEvent::Comment, "summary")
            .unwrap_err();
        assert!(queued_error.to_string().contains("queued"));

        fakes.forge.reject_writes_with(Some("bad line"));
        session
            .comment(Anchor::line("src/a.rs", 3), "failed note")
            .unwrap();

        let failed_preview = session.submit_preview().unwrap();
        assert!(
            failed_preview
                .blocked_reason
                .as_deref()
                .is_some_and(|reason| reason.contains("failed"))
        );
        let failed_error = session
            .submit_review(ReviewEvent::Comment, "summary")
            .unwrap_err();
        assert!(failed_error.to_string().contains("failed"));
    }

    #[test]
    fn submit_review_queues_on_transient_failure_and_records_agreed_bodies_on_flush() {
        let fakes = Fakes::new(100);
        let mut snap = super::super::test_support::create_snapshot();
        snap.viewer_login = Some("bob".into());
        fakes.forge.set_snapshot(snap);
        let mut session = fakes.open_synced();
        let (draft_thread, _) = session
            .comment(Anchor::line("src/a.rs", 2), "draft note")
            .unwrap();
        let draft_msg_id = draft_thread.messages[0].id.clone();

        fakes.forge.fail_writes_with(Some("offline"));
        let view = session
            .submit_review(ReviewEvent::Approve, "looks good")
            .unwrap();
        assert_eq!(view.queued_count, 1);
        assert_eq!(view.draft_count, 1);

        fakes.forge.fail_writes_with(None);
        assert!(session.flush_queued().unwrap());
        let after = session.view();
        assert_eq!(after.queued_count, 0);
        assert_eq!(after.draft_count, 0);
        assert_eq!(
            session.threads().last().unwrap().messages[0].sync,
            Some(MessageSync::Published)
        );
        let saved = fakes.store.load().unwrap();
        assert!(saved.registry.pending_review_id.is_none());
        assert_eq!(
            saved
                .registry
                .agreed_bodies
                .get(&draft_msg_id)
                .map(String::as_str),
            Some("draft note")
        );
    }

    #[test]
    fn anchored_lines_rejects_binary_invalid_bounds_and_non_line_anchors_and_handles_end_only_line()
    {
        let fakes = Fakes::new(100);
        fakes.workspace.put_disk("src/a.rs", "first\nsecond\n");
        fakes.workspace.put_disk("src/b.rs", "PNG\0\x01");
        let mut session = fakes.open_synced();

        assert!(
            session
                .anchored_lines(&Anchor::side_line("src/b.rs", Side::Right, 1))
                .unwrap_err()
                .to_string()
                .contains("binary")
        );
        assert!(
            session
                .anchored_lines(&Anchor::side_line("src/a.rs", Side::Right, 0))
                .is_err()
        );
        let reversed_range = Anchor {
            file: Some("src/a.rs".into()),
            kind: review_model::AnchorKind::Range,
            side: Side::Right,
            start: Some(3),
            end: Some(1),
            commit: None,
            snapshot: None,
        };
        assert!(session.anchored_lines(&reversed_range).is_err());

        let end_only_line = Anchor {
            file: Some("src/a.rs".into()),
            kind: review_model::AnchorKind::Line,
            side: Side::Right,
            start: None,
            end: Some(2),
            commit: None,
            snapshot: None,
        };
        assert_eq!(session.anchored_lines(&end_only_line).unwrap(), "second");
        assert!(session.anchored_lines(&Anchor::file("src/a.rs")).is_err());
        assert!(session.anchored_lines(&Anchor::pr()).is_err());
    }

    #[test]
    fn suggest_from_edit_rejects_deleted_and_binary_files() {
        let fakes = Fakes::new(100);
        fakes.workspace.put_base("src/a.rs", "old\n");
        fakes.workspace.put_at("abc123", "src/b.rs", "PNG\0\x01");
        let mut session = fakes.open_synced();

        assert!(
            session
                .suggest_from_edit("src/a.rs", "new\n", 1, None)
                .unwrap_err()
                .to_string()
                .contains("does not exist at head commit")
        );
        assert!(
            session
                .suggest_from_edit("src/b.rs", "text\n", 1, None)
                .unwrap_err()
                .to_string()
                .contains("binary")
        );
    }

    #[test]
    fn suggest_from_edit_supports_added_and_renamed_files() {
        let added_fakes = Fakes::new(100);
        added_fakes
            .workspace
            .put_at("abc123", "src/a.rs", "let added = 1;\n");
        let mut added_session = added_fakes.open_synced();
        let (suggested, _, view) = added_session
            .suggest_from_edit("src/a.rs", "let added = 2;\n", 1, None)
            .unwrap();
        assert_eq!(suggested.reverted_text, "let added = 1;\n");
        assert_eq!(view.draft_count, 1);

        let renamed_fakes = Fakes::new(100);
        renamed_fakes.workspace.rename("src/old.rs", "src/a.rs");
        renamed_fakes
            .workspace
            .put_base("src/old.rs", "let x = 1;\n");
        renamed_fakes
            .workspace
            .put_at("abc123", "src/a.rs", "let x = 1;\n");
        let mut renamed_session = renamed_fakes.open_synced();
        let (renamed_suggested, _, renamed_view) = renamed_session
            .suggest_from_edit("src/a.rs", "let x = 2;\n", 1, None)
            .unwrap();
        assert_eq!(renamed_suggested.anchor.file.as_deref(), Some("src/a.rs"));
        assert_eq!(renamed_view.draft_count, 1);
    }

    #[test]
    fn submit_review_requires_body_for_zero_draft_comment_and_request_changes_but_not_approve() {
        let fakes = Fakes::new(100);
        let mut snap = super::super::test_support::create_snapshot();
        snap.viewer_login = Some("bob".into());
        fakes.forge.set_snapshot(snap);
        let mut session = fakes.open_synced();

        assert!(session.submit_review(ReviewEvent::Comment, "   ").is_err());
        assert!(
            session
                .submit_review(ReviewEvent::RequestChanges, "   ")
                .is_err()
        );
        let view = session.submit_review(ReviewEvent::Approve, "").unwrap();
        assert_eq!(view.draft_count, 0);
        assert_eq!(view.queued_count, 0);
    }

    #[test]
    fn submit_review_blocks_when_submit_is_already_queued() {
        let fakes = Fakes::new(100);
        let mut snap = super::super::test_support::create_snapshot();
        snap.viewer_login = Some("bob".into());
        fakes.forge.set_snapshot(snap);
        let mut session = fakes.open_synced();

        fakes.forge.fail_writes_with(Some("offline"));
        let queued_view = session.submit_review(ReviewEvent::Approve, "").unwrap();
        assert_eq!(queued_view.queued_count, 1);

        let preview = session.submit_preview().unwrap();
        assert!(
            preview
                .blocked_reason
                .as_deref()
                .is_some_and(|reason| reason.contains("already queued"))
        );
        assert!(
            session
                .submit_review(ReviewEvent::Approve, "")
                .unwrap_err()
                .to_string()
                .contains("already queued")
        );
    }

    #[test]
    fn submit_review_blocks_when_other_ops_are_queued() {
        let fakes = Fakes::new(100);
        let mut snap = super::super::test_support::create_snapshot();
        snap.viewer_login = Some("bob".into());
        fakes.forge.set_snapshot(snap);
        let mut session = fakes.open_synced();

        fakes.forge.fail_writes_with(Some("offline"));
        session.set_resolved("T1", true).unwrap();
        let blocked_preview = session.submit_preview().unwrap();
        assert!(
            blocked_preview
                .blocked_reason
                .as_deref()
                .is_some_and(|reason| reason.contains("queued comment changes"))
        );
        assert!(
            session
                .submit_review(ReviewEvent::Approve, "")
                .unwrap_err()
                .to_string()
                .contains("queued comment changes")
        );
    }
}
