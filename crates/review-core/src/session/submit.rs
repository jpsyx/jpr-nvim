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
mod tests;
