//! Private creation, lookup, and optimistic-update helpers for
//! `ReviewSession` comments.

mod optimistic;

use anyhow::{Context, Result, bail};
use review_model::{Anchor, AnchorKind, MessageSync, Origin, PullRequest, Thread, ThreadState};

use super::super::ReviewSession;
use crate::ports::{ForgeWriteError, QueuedCommentOp};

impl ReviewSession {
    pub(in super::super) fn validate_github_anchor_file(&self, anchor: &Anchor) -> Result<()> {
        if anchor.kind == AnchorKind::Pr {
            return Ok(());
        }
        let path = anchor
            .file
            .as_deref()
            .context("code comment anchor requires a file path")?;
        if self.saved.files.iter().any(|file| file.path == path) {
            return Ok(());
        }
        if self.is_local_only_file(path) {
            bail!("Push this file to GitHub before adding GitHub comments");
        }
        bail!("{path} is not a file this pull request changes");
    }

    pub(in super::super) fn validate_local_anchor_file(&self, anchor: &Anchor) -> Result<()> {
        if anchor.kind == AnchorKind::Pr {
            return Ok(());
        }
        let path = anchor
            .file
            .as_deref()
            .context("code comment anchor requires a file path")?;
        if self.has_effective_file(path) {
            return Ok(());
        }
        bail!("{path} is not a file this pull request changes");
    }

    pub(in super::super) fn create_github_thread_entry(
        &mut self,
        anchor: Anchor,
        body: &str,
    ) -> Result<Thread> {
        let pr = self.require_linked_pr()?.clone();
        if anchor.kind == AnchorKind::Pr {
            return self.insert_pr_comment(&pr, body);
        }
        self.validate_github_anchor_file(&anchor)?;
        self.insert_code_thread(&pr, anchor, body)
    }

    fn insert_pr_comment(&mut self, pr: &PullRequest, body: &str) -> Result<Thread> {
        match self.ports.forge.create_conversation_comment(pr, body) {
            Ok(thread) => {
                self.threads.push(thread.clone());
                Ok(thread)
            }
            Err(error) => self.insert_failed_or_queued_thread(Anchor::pr(), body, error),
        }
    }

    fn insert_code_thread(
        &mut self,
        pr: &PullRequest,
        anchor: Anchor,
        body: &str,
    ) -> Result<Thread> {
        let pending_id = self.saved.registry.pending_review_id.clone();
        match self
            .ports
            .forge
            .create_review_thread(pr, pending_id.as_deref(), &anchor, body)
        {
            Ok(created) => {
                self.saved.registry.pending_review_id = Some(created.pending_review_id);
                self.threads.push(created.thread.clone());
                Ok(created.thread)
            }
            Err(error) => self.insert_failed_or_queued_thread(anchor, body, error),
        }
    }

    fn create_queued_thread_op(
        temp_thread_id: &str,
        temp_message_id: &str,
        anchor: &Anchor,
        body: &str,
    ) -> QueuedCommentOp {
        if anchor.kind == AnchorKind::Pr {
            QueuedCommentOp::CreateConversationComment {
                temp_thread_id: temp_thread_id.to_owned(),
                temp_message_id: temp_message_id.to_owned(),
                body: body.to_owned(),
            }
        } else {
            QueuedCommentOp::CreateReviewThread {
                temp_thread_id: temp_thread_id.to_owned(),
                temp_message_id: temp_message_id.to_owned(),
                anchor: anchor.clone(),
                body: body.to_owned(),
            }
        }
    }

    fn insert_failed_or_queued_thread(
        &mut self,
        anchor: Anchor,
        body: &str,
        error: ForgeWriteError,
    ) -> Result<Thread> {
        if let ForgeWriteError::AuthRequired(reason) = error {
            return Err(anyhow::Error::new(crate::ForgeAuthError::new(reason)));
        }
        let temp_thread_id = self.allocate_temp_id("t");
        let temp_message_id = self.allocate_temp_id("m");
        let (sync, sync_error) = match error {
            ForgeWriteError::Transient(_) => {
                let op =
                    Self::create_queued_thread_op(&temp_thread_id, &temp_message_id, &anchor, body);
                self.saved.registry.queued_ops.push(op);
                (MessageSync::Queued, None)
            }
            ForgeWriteError::Rejected(reason) => (MessageSync::Failed, Some(reason)),
            ForgeWriteError::AuthRequired(_) => unreachable!("handled above"),
        };
        let message = self.create_optimistic_message(&temp_message_id, body, sync, sync_error);
        let thread = Thread {
            id: temp_thread_id,
            origin: Origin::Github,
            anchor,
            state: ThreadState::Open,
            outdated: false,
            messages: vec![message],
            agent: None,
            promoted_to: None,
        };
        self.threads.push(thread.clone());
        Ok(thread)
    }
}
