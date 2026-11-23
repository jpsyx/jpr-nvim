use serde::{Deserialize, Serialize};

/// A pull request under review, as the forge reports it. The session saves it
/// and puts it in every view, so a frontend can title its panel and an adapter
/// can address the pull request on the forge again.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequest {
    /// The repository owner, e.g. `octo`.
    pub owner: String,
    /// The repository name, e.g. `widgets`.
    pub repo: String,
    /// The pull request number within its repository.
    pub number: u64,
    /// The title, as the author wrote it.
    pub title: String,
    /// The pull request's web page.
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
    /// The base branch's commit the pull request is compared against, for
    /// finding where its changes start. Empty when unknown, as in state an
    /// older build saved.
    #[serde(default)]
    pub base_sha: String,
    /// Whether the pull request's head branch lives in a fork repository.
    #[serde(default)]
    pub is_cross_repository: bool,
}

/// Whether the reviewer has viewed a file, as the forge tracks it. The file
/// list marks each file with it, and the session counts the viewed files.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ViewedState {
    /// Marked viewed, and unchanged since.
    Viewed,
    /// Not marked viewed.
    Unviewed,
    /// Viewed once, but the file changed since.
    Dismissed,
}

impl ViewedState {
    /// Parses GitHub's `FileViewedState` spelling, for adapters that read it
    /// from the forge. `None` for any other spelling.
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

/// One file the pull request changes, as the forge reports it. The session
/// saves the list and turns it into the file rows a frontend draws.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangedFile {
    /// The file's path from the repository root.
    pub path: String,
    /// Lines the pull request adds to the file.
    pub additions: u64,
    /// Lines the pull request removes from the file.
    pub deletions: u64,
    /// Whether the reviewer has viewed the file.
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
            base_sha: "base000".into(),
            is_cross_repository: false,
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
    fn pull_request_uses_camel_case_keys_and_defaults_cross_repository() {
        let json = serde_json::to_value(pr()).unwrap();
        assert_eq!(json["nodeId"], "PR_7");
        assert_eq!(json["headSha"], "abc123");
        assert_eq!(json["headRef"], "fix/widget");
        assert_eq!(json["baseRef"], "main");
        assert_eq!(json["baseSha"], "base000");
        assert_eq!(json["isCrossRepository"], false);

        let mut without_flag = json;
        without_flag
            .as_object_mut()
            .unwrap()
            .remove("isCrossRepository");
        let decoded: PullRequest = serde_json::from_value(without_flag).unwrap();
        assert!(!decoded.is_cross_repository);
    }
}
