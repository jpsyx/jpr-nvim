//! The GitHub forge: `gh pr view` for the pull request, `gh api graphql` for
//! threads, files and viewed state, and the viewed mutations.

mod gh;
pub mod graphql;
mod mutations;
pub mod pr;

use std::path::PathBuf;

use anyhow::{Context, Result};
use review_core::ports::{
    CreatedReviewThread, Forge, ForgeSnapshot, ForgeWriteError, ReplyRequest,
};
use review_model::{
    Anchor, AnchorKind, Message, PullRequest, PullRequestSummary, Reaction, ReactionContent,
    ReviewEvent, Thread,
};
use serde_json::{Value, json};

pub use gh::{GH_TIMEOUT, Gh};

/// [`Forge`] over the GitHub CLI, for any frontend that reviews GitHub pull
/// requests. Every call runs as the account `gh` is logged in to, so it needs
/// no token of its own.
#[derive(Debug, Clone)]
pub struct GhForge {
    gh: Gh,
    repo: Option<String>,
}

impl GhForge {
    /// Runs `gh` in `dir`. `repo` (`owner/name`) pins the repository
    /// `gh pr view` looks in; without it `gh` infers it from `dir`'s remotes.
    #[must_use]
    pub const fn new(dir: PathBuf, repo: Option<String>) -> Self {
        Self {
            gh: Gh::new(dir),
            repo,
        }
    }

    /// The `gh pr view` arguments for pull request `number`.
    #[must_use]
    pub fn view_args(&self, number: u64) -> Vec<String> {
        let mut args = vec![
            "pr".to_owned(),
            "view".to_owned(),
            number.to_string(),
            "--json".to_owned(),
            pr::PR_FIELDS.to_owned(),
        ];
        if let Some(repo) = &self.repo {
            args.push("--repo".to_owned());
            args.push(repo.clone());
        }
        args
    }

    /// The `gh pr list` arguments for listing open pull requests.
    #[must_use]
    pub fn list_args(&self, limit: u32) -> Vec<String> {
        let mut args = vec![
            "pr".to_owned(),
            "list".to_owned(),
            "--state".to_owned(),
            "open".to_owned(),
            "--limit".to_owned(),
            limit.to_string(),
            "--json".to_owned(),
            pr::PR_LIST_FIELDS.to_owned(),
        ];
        if let Some(repo) = &self.repo {
            args.push("--repo".to_owned());
            args.push(repo.clone());
        }
        args
    }

    /// Lists up to `limit` open pull requests in the inferred or pinned repository.
    pub fn open_pull_requests(&self, limit: u32) -> Result<Vec<PullRequestSummary>> {
        let args = self.list_args(limit);
        let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
        pr::parse_pr_list(&self.gh.run(&arg_refs, None)?)
    }

    fn graphql(&self, query: &str, variables: &Value) -> Result<Value> {
        let body = json!({ "query": query, "variables": variables });
        graphql::parse_data_from_answer(
            &self
                .gh
                .run(&["api", "graphql", "--input", "-"], Some(&body))?,
        )
    }

    fn paged<T>(
        &self,
        query: &str,
        pr: &PullRequest,
        mut page: impl FnMut(&Value) -> Result<(Vec<T>, Option<String>)>,
    ) -> Result<Vec<T>> {
        let mut items = Vec::new();
        let mut after_cursor: Option<String> = None;
        loop {
            let data = self.graphql(query, &json!({ "pr": pr.node_id, "after": after_cursor }))?;
            let (page_items, next_cursor) = page(&data)?;
            items.extend(page_items);
            match next_cursor {
                Some(cursor) => after_cursor = Some(cursor),
                None => return Ok(items),
            }
        }
    }
}

impl Forge for GhForge {
    fn pull_request(&self, number: u64) -> Result<PullRequest> {
        let args = self.view_args(number);
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        pr::parse_pr(&self.gh.run(&args, None)?)
    }

    fn fetch(&self, pr: &PullRequest) -> Result<ForgeSnapshot> {
        let mut head_sha = pr.head_sha.clone();
        let mut threads = self.paged(graphql::THREADS, pr, |data| {
            let (page_head_sha, page_threads, next_cursor) = graphql::parse_threads_page(data)?;
            if !page_head_sha.is_empty() {
                head_sha = page_head_sha;
            }
            Ok((page_threads, next_cursor))
        })?;
        threads.extend(self.paged(graphql::CONVERSATION, pr, graphql::parse_conversation_page)?);
        let files = self.paged(graphql::FILES, pr, graphql::parse_files_page)?;
        let pending_data = self.graphql(graphql::PENDING_REVIEW, &json!({ "pr": pr.node_id }))?;
        let pending_review_id = graphql::parse_pending_review(&pending_data);
        let viewer_login = graphql::parse_viewer_login(&pending_data);
        let mentions_data = self.graphql(graphql::MENTIONS, &json!({ "pr": pr.node_id }))?;
        Ok(ForgeSnapshot {
            head_sha,
            has_pending_review: pending_review_id.is_some(),
            pending_review_id,
            viewer_login,
            threads,
            files,
            mention_candidates: graphql::parse_mentions(&mentions_data),
        })
    }

    fn set_viewed(&self, pr: &PullRequest, path: &str, viewed: bool) -> Result<()> {
        let mark = if viewed { "viewed" } else { "unviewed" };
        self.graphql(
            graphql::viewed_flag_to_mutation(viewed),
            &json!({ "pr": pr.node_id, "path": path }),
        )
        .with_context(|| format!("marking {path} {mark} on GitHub"))?;
        Ok(())
    }

    fn create_review_thread(
        &self,
        pr: &PullRequest,
        pending_review_id: Option<&str>,
        anchor: &Anchor,
        body: &str,
    ) -> std::result::Result<CreatedReviewThread, ForgeWriteError> {
        self.create_review_thread_impl(pr, pending_review_id, anchor, body)
    }

    fn create_conversation_comment(
        &self,
        pr: &PullRequest,
        body: &str,
    ) -> std::result::Result<Thread, ForgeWriteError> {
        self.create_conversation_comment_impl(pr, body)
    }

    fn reply_to_thread(
        &self,
        pr: &PullRequest,
        request: &ReplyRequest<'_>,
    ) -> std::result::Result<Message, ForgeWriteError> {
        self.reply_to_thread_impl(pr, request)
    }

    fn edit_message(
        &self,
        anchor_kind: AnchorKind,
        message_id: &str,
        body: &str,
    ) -> std::result::Result<Message, ForgeWriteError> {
        self.edit_message_impl(anchor_kind, message_id, body)
    }

    fn delete_message(
        &self,
        anchor_kind: AnchorKind,
        message_id: &str,
    ) -> std::result::Result<(), ForgeWriteError> {
        self.delete_message_impl(anchor_kind, message_id)
    }

    fn set_resolved(
        &self,
        thread_id: &str,
        resolved: bool,
    ) -> std::result::Result<(), ForgeWriteError> {
        self.set_resolved_impl(thread_id, resolved)
    }

    fn set_reaction(
        &self,
        subject_id: &str,
        content: ReactionContent,
        added: bool,
    ) -> std::result::Result<Vec<Reaction>, ForgeWriteError> {
        self.set_reaction_impl(subject_id, content, added)
    }

    fn submit_review(
        &self,
        pr: &PullRequest,
        pending_review_id: Option<&str>,
        event: ReviewEvent,
        body: &str,
    ) -> std::result::Result<(), ForgeWriteError> {
        self.submit_review_impl(pr, pending_review_id, event, body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn view_args_pin_the_repository_when_known() {
        let forge = GhForge::new(PathBuf::from("."), Some("octo/widgets".into()));
        assert_eq!(
            forge.view_args(7),
            [
                "pr",
                "view",
                "7",
                "--json",
                pr::PR_FIELDS,
                "--repo",
                "octo/widgets"
            ]
        );
        let local = GhForge::new(PathBuf::from("."), None);
        assert_eq!(
            local.view_args(7),
            ["pr", "view", "7", "--json", pr::PR_FIELDS]
        );
    }

    #[test]
    fn list_args_includes_state_limit_fields_and_optional_repo() {
        let without_repo = GhForge::new(PathBuf::from("."), None);
        assert_eq!(
            without_repo.list_args(50),
            vec![
                "pr",
                "list",
                "--state",
                "open",
                "--limit",
                "50",
                "--json",
                pr::PR_LIST_FIELDS,
            ]
        );
        let with_repo = GhForge::new(PathBuf::from("."), Some("octo/widgets".into()));
        assert_eq!(
            with_repo.list_args(20),
            vec![
                "pr",
                "list",
                "--state",
                "open",
                "--limit",
                "20",
                "--json",
                pr::PR_LIST_FIELDS,
                "--repo",
                "octo/widgets",
            ]
        );
    }
}
