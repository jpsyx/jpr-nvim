//! Pull requests and the files they change.

use serde::{Deserialize, Serialize};

/// A pull request under review.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequest {
    /// The repository owner, e.g. `octo`.
    pub owner: String,
    /// The repository name, e.g. `widgets`.
    pub repo: String,
    pub number: u64,
    pub title: String,
    pub url: String,
    /// The forge's own id for the pull request (GitHub's GraphQL node id).
    pub node_id: String,
    /// The author's login.
    pub author: String,
    /// The branch being merged, e.g. `fix/widget`.
    pub head_ref: String,
    /// The head commit new comments are anchored to.
    pub head_sha: String,
    /// The branch it merges into, e.g. `main`.
    pub base_ref: String,
}

/// Whether the reviewer has viewed a file, as the forge tracks it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ViewedState {
    Viewed,
    Unviewed,
    /// Viewed once, but the file changed since.
    Dismissed,
}

impl ViewedState {
    /// Parses GitHub's `FileViewedState` spelling.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "VIEWED" => Some(Self::Viewed),
            "UNVIEWED" => Some(Self::Unviewed),
            "DISMISSED" => Some(Self::Dismissed),
            _ => None,
        }
    }
}

/// One file the pull request changes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangedFile {
    pub path: String,
    pub additions: u64,
    pub deletions: u64,
    pub viewed: ViewedState,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pr() -> PullRequest {
        PullRequest {
            owner: "octo".into(),
            repo: "widgets".into(),
            number: 7,
            title: "Fix the widget".into(),
            url: "https://github.com/octo/widgets/pull/7".into(),
            node_id: "PR_7".into(),
            author: "alice".into(),
            head_ref: "fix/widget".into(),
            head_sha: "abc123".into(),
            base_ref: "main".into(),
        }
    }

    #[test]
    fn viewed_state_parses_github_spellings() {
        assert_eq!(ViewedState::parse("VIEWED"), Some(ViewedState::Viewed));
        assert_eq!(ViewedState::parse("UNVIEWED"), Some(ViewedState::Unviewed));
        assert_eq!(
            ViewedState::parse("DISMISSED"),
            Some(ViewedState::Dismissed)
        );
        assert_eq!(ViewedState::parse("viewed"), None);
    }

    #[test]
    fn viewed_state_serializes_as_github_spells_it() {
        assert_eq!(
            serde_json::to_string(&ViewedState::Dismissed).unwrap(),
            "\"DISMISSED\""
        );
    }

    #[test]
    fn pull_request_uses_camel_case_keys() {
        let json = serde_json::to_value(pr()).unwrap();
        assert_eq!(json["nodeId"], "PR_7");
        assert_eq!(json["headSha"], "abc123");
        assert_eq!(json["headRef"], "fix/widget");
        assert_eq!(json["baseRef"], "main");
    }
}
