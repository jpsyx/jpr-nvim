//! The GitHub forge: `gh pr view` for the pull request and `gh api graphql`
//! for threads, files and viewed state. Adapted from dif's `github/` module.

mod gh;
pub mod graphql;
pub mod pr;

use std::path::PathBuf;

use anyhow::Result;
use review_core::ports::{Forge, ForgeSnapshot};
use review_model::PullRequest;
use serde_json::{Value, json};

pub use gh::{GH_TIMEOUT, Gh};

/// [`Forge`] over the GitHub CLI.
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
        let mut after: Option<String> = None;
        loop {
            let data = self.graphql(query, &json!({ "pr": pr.node_id, "after": after }))?;
            let (batch, next) = page(&data)?;
            items.extend(batch);
            match next {
                Some(cursor) => after = Some(cursor),
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
        let threads = self.paged(graphql::THREADS, pr, |data| {
            let (head, threads, next) = graphql::parse_threads_page(data)?;
            if !head.is_empty() {
                head_sha = head;
            }
            Ok((threads, next))
        })?;
        let files = self.paged(graphql::FILES, pr, graphql::parse_files_page)?;
        let pending = graphql::parse_pending_review(
            &self.graphql(graphql::PENDING_REVIEW, &json!({ "pr": pr.node_id }))?,
        );
        Ok(ForgeSnapshot {
            head_sha,
            has_pending_review: pending.is_some(),
            threads,
            files,
        })
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
}
