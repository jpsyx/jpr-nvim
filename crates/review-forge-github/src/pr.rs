//! Reading `gh pr view` and `gh pr list` JSON into pull request models.

use anyhow::{Context, Result, anyhow, bail};
use review_model::{PullRequest, PullRequestSummary};
use serde_json::Value;

/// The fields `gh pr view --json` must report.
pub const PR_FIELDS: &str = "number,title,url,id,headRefName,headRefOid,state,baseRefName,baseRefOid,author,isCrossRepository";

/// The fields `gh pr list --json` must report for open PR summaries.
pub const PR_LIST_FIELDS: &str = "number,title,author,headRefName,isDraft,updatedAt";

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

/// Parses `gh pr list --json PR_LIST_FIELDS` into compact pull request summaries.
pub fn parse_pr_list(stdout: &str) -> Result<Vec<PullRequestSummary>> {
    let items: Vec<Value> = serde_json::from_str(stdout).context("reading gh pr list output")?;
    items.iter().map(parse_pr_summary).collect()
}

fn parse_pr_summary(value: &Value) -> Result<PullRequestSummary> {
    let number = value["number"]
        .as_u64()
        .context("gh pr list item did not report /number")?;
    let title = value["title"]
        .as_str()
        .map(str::to_owned)
        .context("gh pr list item did not report /title")?;
    let head_ref = value["headRefName"]
        .as_str()
        .map(str::to_owned)
        .context("gh pr list item did not report /headRefName")?;
    let is_draft = value["isDraft"]
        .as_bool()
        .context("gh pr list item did not report /isDraft")?;
    let updated_at = value["updatedAt"]
        .as_str()
        .map(str::to_owned)
        .context("gh pr list item did not report /updatedAt")?;
    let author = value
        .pointer("/author/login")
        .and_then(Value::as_str)
        .filter(|login| !login.is_empty())
        .unwrap_or("ghost")
        .to_owned();
    Ok(PullRequestSummary {
        number,
        title,
        author,
        head_ref,
        is_draft,
        updated_at,
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

    const LIST_JSON: &str = r#"[
        {"number":42,"title":"Add OAuth","author":{"login":"alice"},"headRefName":"feat/oauth","isDraft":false,"updatedAt":"2026-11-23T15:04:05Z"},
        {"number":43,"title":"WIP refactor","author":null,"headRefName":"chore/wip","isDraft":true,"updatedAt":"2026-11-22T10:00:00Z"}
    ]"#;

    #[test]
    fn pr_list_fields_covers_every_key_read_by_parse_pr_list() {
        let allowed_keys: std::collections::BTreeSet<&str> = PR_LIST_FIELDS.split(',').collect();
        let mut parsed: Vec<Value> = serde_json::from_str(LIST_JSON).unwrap();
        for item in &mut parsed {
            item.as_object_mut()
                .unwrap()
                .retain(|key, _| allowed_keys.contains(key.as_str()));
        }
        let summaries = parse_pr_list(&serde_json::to_string(&parsed).unwrap()).unwrap();
        assert_eq!(
            summaries,
            vec![
                PullRequestSummary {
                    number: 42,
                    title: "Add OAuth".into(),
                    author: "alice".into(),
                    head_ref: "feat/oauth".into(),
                    is_draft: false,
                    updated_at: "2026-11-23T15:04:05Z".into(),
                },
                PullRequestSummary {
                    number: 43,
                    title: "WIP refactor".into(),
                    author: "ghost".into(),
                    head_ref: "chore/wip".into(),
                    is_draft: true,
                    updated_at: "2026-11-22T10:00:00Z".into(),
                },
            ]
        );
    }

    #[test]
    fn parse_pr_list_returns_empty_vec_for_empty_json_array() {
        assert_eq!(parse_pr_list("[]").unwrap(), Vec::new());
    }

    #[test]
    fn empty_or_omitted_author_falls_back_to_ghost() {
        let json = r#"[
            {"number":1,"title":"Empty login","author":{"login":""},"headRefName":"a","isDraft":false,"updatedAt":"2026-11-23T00:00:00Z"},
            {"number":2,"title":"No author key","headRefName":"b","isDraft":false,"updatedAt":"2026-11-23T00:00:00Z"}
        ]"#;
        let summaries = parse_pr_list(json).unwrap();
        assert_eq!(summaries.len(), 2);
        assert_eq!(summaries[0].author, "ghost");
        assert_eq!(summaries[1].author, "ghost");
    }

    #[test]
    fn rejects_malformed_or_non_array_pr_list_json() {
        assert!(parse_pr_list("not json").is_err());
        assert!(parse_pr_list("{}").is_err());
    }

    #[test]
    fn rejects_pr_list_item_missing_any_required_field() {
        let valid_item: Value = serde_json::from_str(
            r#"{"number":42,"title":"Add OAuth","author":{"login":"alice"},"headRefName":"feat/oauth","isDraft":false,"updatedAt":"2026-11-23T15:04:05Z"}"#,
        )
        .unwrap();
        for required_key in ["number", "title", "headRefName", "isDraft", "updatedAt"] {
            let mut incomplete = valid_item.clone();
            incomplete.as_object_mut().unwrap().remove(required_key);
            let payload = serde_json::to_string(&vec![incomplete]).unwrap();
            let error = parse_pr_list(&payload).unwrap_err();
            assert!(
                error.to_string().contains(required_key),
                "expected error for missing {required_key}, got: {error:#}"
            );
        }
    }
}
