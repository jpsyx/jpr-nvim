//! GitHub owner (personal profile + organizations) and repository discovery.

use std::collections::HashSet;

use anyhow::{Context, Result, anyhow, bail};
use review_model::{ForgeOwner, ForgeRepo, OwnerKind};
use serde_json::{Value, json};

use crate::GhForge;

/// GraphQL query fetching the authenticated viewer and one page of organizations.
pub const OWNERS_QUERY: &str = r"
query($after: String) {
  viewer {
    login
    name
    organizations(first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { login name }
    }
  }
}
";

/// The fields `gh repo list --json` must report for repository summaries.
pub const REPO_LIST_FIELDS: &str = "nameWithOwner,description,isPrivate,isArchived,updatedAt";

fn non_empty_trimmed(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

/// Validates that `owner` is a safe single GitHub account/organization login.
pub fn validate_owner_login(owner: &str) -> Result<()> {
    let trimmed = owner.trim();
    if trimmed.is_empty()
        || trimmed == "."
        || trimmed == ".."
        || trimmed.starts_with('-')
        || trimmed.bytes().any(|byte| {
            matches!(byte, b'/' | b'\\' | b'?' | b'#')
                || byte.is_ascii_whitespace()
                || byte.is_ascii_control()
        })
    {
        bail!("invalid GitHub owner {owner:?}");
    }
    Ok(())
}

/// Parses one GraphQL `viewer` page into `(viewer_owner, org_owners, next_cursor)`.
pub fn parse_owners_page(data: &Value) -> Result<(ForgeOwner, Vec<ForgeOwner>, Option<String>)> {
    let viewer = data
        .get("viewer")
        .context("GitHub GraphQL response did not report viewer")?;
    let viewer_login = viewer["login"]
        .as_str()
        .filter(|login| !login.is_empty())
        .context("GitHub GraphQL viewer did not report login")?;
    let viewer_owner = ForgeOwner {
        login: viewer_login.to_owned(),
        name: non_empty_trimmed(viewer["name"].as_str()),
        kind: OwnerKind::User,
    };
    let mut orgs = Vec::new();
    if let Some(nodes) = viewer
        .pointer("/organizations/nodes")
        .and_then(Value::as_array)
    {
        for node in nodes {
            let Some(login) = node["login"].as_str().filter(|text| !text.is_empty()) else {
                continue;
            };
            orgs.push(ForgeOwner {
                login: login.to_owned(),
                name: non_empty_trimmed(node["name"].as_str()),
                kind: OwnerKind::Organization,
            });
        }
    }
    let has_next = viewer
        .pointer("/organizations/pageInfo/hasNextPage")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let next_cursor = if has_next {
        viewer
            .pointer("/organizations/pageInfo/endCursor")
            .and_then(Value::as_str)
            .filter(|cursor| !cursor.is_empty())
            .map(str::to_owned)
    } else {
        None
    };
    Ok((viewer_owner, orgs, next_cursor))
}

/// Places `viewer` first followed by deduplicated organizations sorted
/// case-insensitively by login.
#[must_use]
pub fn assemble_owners(viewer: ForgeOwner, orgs: Vec<ForgeOwner>) -> Vec<ForgeOwner> {
    let mut seen = HashSet::new();
    seen.insert(viewer.login.to_ascii_lowercase());
    let mut unique_orgs = Vec::new();
    for org in orgs {
        if seen.insert(org.login.to_ascii_lowercase()) {
            unique_orgs.push(org);
        }
    }
    unique_orgs.sort_by(|left, right| {
        left.login
            .to_ascii_lowercase()
            .cmp(&right.login.to_ascii_lowercase())
    });
    let mut owners = Vec::with_capacity(1 + unique_orgs.len());
    owners.push(viewer);
    owners.extend(unique_orgs);
    owners
}

/// Parses `gh repo list --json REPO_LIST_FIELDS` output into [`ForgeRepo`] items.
pub fn parse_repo_list(stdout: &str) -> Result<Vec<ForgeRepo>> {
    let items: Vec<Value> = serde_json::from_str(stdout).context("reading gh repo list output")?;
    items.iter().map(parse_repo_item).collect()
}

fn parse_repo_item(value: &Value) -> Result<ForgeRepo> {
    let name_with_owner = value["nameWithOwner"]
        .as_str()
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| anyhow!("gh repo list item did not report /nameWithOwner"))?;
    let description = non_empty_trimmed(value["description"].as_str());
    let is_private = value["isPrivate"]
        .as_bool()
        .context("gh repo list item did not report /isPrivate")?;
    let is_archived = value["isArchived"]
        .as_bool()
        .context("gh repo list item did not report /isArchived")?;
    let updated_at = value["updatedAt"]
        .as_str()
        .map(str::to_owned)
        .context("gh repo list item did not report /updatedAt")?;
    Ok(ForgeRepo {
        name_with_owner,
        description,
        is_private,
        is_archived,
        updated_at,
    })
}

impl GhForge {
    /// Builds `gh repo list` arguments for optional `owner` and `limit`.
    pub fn repo_list_args(owner: Option<&str>, limit: u32) -> Result<Vec<String>> {
        if limit == 0 {
            bail!("limit must be at least 1");
        }
        let mut args = vec!["repo".to_owned(), "list".to_owned()];
        if let Some(login) = owner {
            validate_owner_login(login)?;
            args.push(login.trim().to_owned());
        }
        args.extend([
            "--limit".to_owned(),
            limit.to_string(),
            "--json".to_owned(),
            REPO_LIST_FIELDS.to_owned(),
        ]);
        Ok(args)
    }

    /// Lists the authenticated user's profile followed by all organizations they
    /// belong to, sorted case-insensitively.
    pub fn list_owners(&self) -> Result<Vec<ForgeOwner>> {
        let mut viewer: Option<ForgeOwner> = None;
        let mut orgs = Vec::new();
        let mut after_cursor: Option<String> = None;
        loop {
            let data = self.graphql(OWNERS_QUERY, &json!({ "after": after_cursor }))?;
            let (page_viewer, page_orgs, next_cursor) = parse_owners_page(&data)?;
            if viewer.is_none() {
                viewer = Some(page_viewer);
            }
            orgs.extend(page_orgs);
            if let Some(cursor) = next_cursor {
                after_cursor = Some(cursor);
            } else {
                let profile = viewer.context("GitHub did not return viewer profile")?;
                return Ok(assemble_owners(profile, orgs));
            }
        }
    }

    /// Lists up to `limit` repositories owned by `owner` (or the authenticated
    /// user's personal profile when `owner` is `None`).
    pub fn list_repos(&self, owner: Option<&str>, limit: u32) -> Result<Vec<ForgeRepo>> {
        let args = Self::repo_list_args(owner, limit)?;
        let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
        parse_repo_list(&self.gh.run(&arg_refs, None)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn assemble_owners_places_viewer_first_and_deduplicates_orgs_case_insensitively() {
        let data: Value = serde_json::from_str(
            r#"{
                "viewer": {
                    "login": "pablo",
                    "name": "Pablo",
                    "organizations": {
                        "pageInfo": { "hasNextPage": true, "endCursor": "CUR1" },
                        "nodes": [
                            { "login": "zeta-org", "name": "" },
                            { "login": "Acme", "name": "Acme Corp" },
                            { "login": "acme", "name": "Duplicate" }
                        ]
                    }
                }
            }"#,
        )
        .unwrap();
        let (viewer, orgs, cursor) = parse_owners_page(&data).unwrap();
        assert_eq!(viewer.login, "pablo");
        assert_eq!(viewer.kind, OwnerKind::User);
        assert_eq!(cursor.as_deref(), Some("CUR1"));
        let combined = assemble_owners(viewer, orgs);
        assert_eq!(combined.len(), 3);
        assert_eq!(combined[0].login, "pablo");
        assert_eq!(combined[1].login, "Acme");
        assert_eq!(combined[2].login, "zeta-org");
        assert_eq!(combined[2].name, None);
    }

    #[test]
    fn repo_list_args_includes_owner_and_rejects_zero_limit_or_unsafe_logins() {
        assert_eq!(
            GhForge::repo_list_args(None, 100).unwrap(),
            vec!["repo", "list", "--limit", "100", "--json", REPO_LIST_FIELDS,]
        );
        assert_eq!(
            GhForge::repo_list_args(Some("acme"), 50).unwrap(),
            vec![
                "repo",
                "list",
                "acme",
                "--limit",
                "50",
                "--json",
                REPO_LIST_FIELDS,
            ]
        );
        assert!(GhForge::repo_list_args(None, 0).is_err());
        assert!(GhForge::repo_list_args(Some("a/b"), 10).is_err());
        assert!(GhForge::repo_list_args(Some("-flag"), 10).is_err());
    }

    #[test]
    fn parse_repo_list_normalizes_blank_descriptions_and_preserves_flags() {
        let repos = parse_repo_list(
            r#"[
                {"nameWithOwner":"acme/widgets","description":"","isPrivate":true,"isArchived":false,"updatedAt":"2026-11-24T12:00:00Z"},
                {"nameWithOwner":"acme/docs","description":"Docs","isPrivate":false,"isArchived":true,"updatedAt":"2026-11-20T00:00:00Z"}
            ]"#,
        )
        .unwrap();
        assert_eq!(repos.len(), 2);
        assert_eq!(repos[0].description, None);
        assert!(repos[0].is_private);
        assert_eq!(repos[1].description.as_deref(), Some("Docs"));
        assert!(repos[1].is_archived);
    }
}
