//! Reading `gh pr view`'s JSON into a pull request.

use anyhow::{Context, Result, anyhow, bail};
use review_model::PullRequest;
use serde_json::Value;

/// The fields `gh pr view --json` must report.
pub const PR_FIELDS: &str =
    "number,title,url,id,headRefName,headRefOid,state,baseRefName,baseRefOid,author";

/// The owner and repository in a pull request URL such as
/// `https://github.com/octo/widgets/pull/7`.
#[must_use]
pub fn owner_repo_from_url(url: &str) -> Option<(String, String)> {
    let path = url.split("://").nth(1)?;
    let mut parts = path.split('/').skip(1);
    let owner = parts.next().filter(|part| !part.is_empty())?;
    let repo = parts.next().filter(|part| !part.is_empty())?;
    Some((owner.to_owned(), repo.to_owned()))
}

/// Parses `gh pr view --json PR_FIELDS`. Only an open pull request can be reviewed.
pub fn parse_pr(stdout: &str) -> Result<PullRequest> {
    let value: Value = serde_json::from_str(stdout).context("reading gh pr view output")?;
    let number = value["number"]
        .as_u64()
        .context("gh pr view did not report the number")?;
    match value["state"].as_str() {
        Some("OPEN") => {}
        Some(state) => bail!(
            "pull request #{number} is not open ({})",
            state.to_lowercase()
        ),
        None => bail!("gh pr view did not report the state"),
    }
    let text = |pointer: &str| {
        value
            .pointer(pointer)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| anyhow!("gh pr view did not report {pointer}"))
    };
    let url = text("/url")?;
    let (owner, repo) =
        owner_repo_from_url(&url).with_context(|| format!("unexpected pull request URL {url}"))?;
    Ok(PullRequest {
        owner,
        repo,
        number,
        title: text("/title")?,
        url,
        node_id: text("/id")?,
        author: text("/author/login")?,
        head_ref: text("/headRefName")?,
        head_sha: text("/headRefOid")?,
        base_ref: text("/baseRefName")?,
        base_sha: text("/baseRefOid")?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const OPEN: &str = r#"{"number":7,"title":"Fix the widget","url":"https://github.com/octo/widgets/pull/7",
        "id":"PR_7","headRefName":"fix/widget","headRefOid":"abc123","state":"OPEN",
        "baseRefName":"main","baseRefOid":"base000","author":{"login":"alice"}}"#;

    #[test]
    fn parses_an_open_pull_request() {
        let pr = parse_pr(OPEN).unwrap();
        assert_eq!(
            (pr.owner.as_str(), pr.repo.as_str(), pr.number),
            ("octo", "widgets", 7)
        );
        assert_eq!(pr.title, "Fix the widget");
        assert_eq!(pr.node_id, "PR_7");
        assert_eq!(pr.author, "alice");
        assert_eq!(
            (
                pr.head_ref.as_str(),
                pr.head_sha.as_str(),
                pr.base_ref.as_str()
            ),
            ("fix/widget", "abc123", "main")
        );
        assert_eq!(pr.base_sha, "base000");
    }

    #[test]
    fn rejects_a_merged_pull_request() {
        let error = parse_pr(&OPEN.replace("OPEN", "MERGED")).unwrap_err();
        assert_eq!(error.to_string(), "pull request #7 is not open (merged)");
    }

    #[test]
    fn reads_owner_and_repo_from_urls() {
        assert_eq!(
            owner_repo_from_url("https://github.com/octo/widgets/pull/7"),
            Some(("octo".to_owned(), "widgets".to_owned()))
        );
        assert_eq!(
            owner_repo_from_url("https://ghe.example.com/team/tool/pull/1"),
            Some(("team".to_owned(), "tool".to_owned()))
        );
        assert_eq!(owner_repo_from_url("not a url"), None);
        assert_eq!(owner_repo_from_url("https://github.com/octo"), None);
    }
}
