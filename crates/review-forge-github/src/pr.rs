//! Reading `gh pr view`'s JSON into a pull request.

use anyhow::{Context, Result, anyhow, bail};
use review_model::PullRequest;
use serde_json::Value;

/// The fields `gh pr view --json` must report.
pub const PR_FIELDS: &str = "number,title,url,id,headRefName,headRefOid,state,baseRefName,baseRefOid,author,isCrossRepository";

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
    let is_cross_repository = value["isCrossRepository"]
        .as_bool()
        .context("gh pr view did not report /isCrossRepository")?;
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
        is_cross_repository,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const OPEN: &str = r#"{"number":7,"title":"Fix the widget","url":"https://github.com/octo/widgets/pull/7",
        "id":"PR_7","headRefName":"fix/widget","headRefOid":"abc123","state":"OPEN",
        "baseRefName":"main","baseRefOid":"base000","author":{"login":"alice"},"isCrossRepository":false}"#;

    #[test]
    fn pr_fields_covers_every_key_read_by_parse_pr() {
        let allowed_keys: std::collections::BTreeSet<&str> = PR_FIELDS.split(',').collect();
        let mut parsed: Value = serde_json::from_str(OPEN).unwrap();
        parsed
            .as_object_mut()
            .unwrap()
            .retain(|key, _| allowed_keys.contains(key.as_str()));
        let filtered_json = serde_json::to_string(&parsed).unwrap();
        let pr = parse_pr(&filtered_json).unwrap();
        assert_eq!((pr.number, pr.is_cross_repository), (7, false));
    }

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
        assert!(!pr.is_cross_repository);

        let fork_pr =
            parse_pr(&OPEN.replace("\"isCrossRepository\":false", "\"isCrossRepository\":true"))
                .unwrap();
        assert!(fork_pr.is_cross_repository);
    }

    #[test]
    fn rejects_missing_is_cross_repository() {
        let missing = OPEN.replace(",\"isCrossRepository\":false", "");
        let error = parse_pr(&missing).unwrap_err();
        assert!(error.to_string().contains("isCrossRepository"), "{error:#}");
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
