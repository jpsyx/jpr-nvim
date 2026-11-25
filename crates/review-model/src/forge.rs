//! Forge owner and repository discovery wire models.

use serde::{Deserialize, Serialize};

/// Kind of GitHub account returned by `jpr-review owners`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OwnerKind {
    /// The authenticated user's personal profile.
    User,
    /// A GitHub organization the authenticated user belongs to.
    Organization,
}

/// A GitHub user profile or organization that owns repositories.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ForgeOwner {
    /// Account or organization login (e.g. `"octocat"` or `"acme-corp"`).
    pub login: String,
    /// Optional human-readable display name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Whether this entry is the authenticated user or an organization.
    pub kind: OwnerKind,
}

/// Compact summary of a GitHub repository returned by `jpr-review repos`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ForgeRepo {
    /// Repository slug in `owner/name` form.
    pub name_with_owner: String,
    /// Optional repository description.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Whether the repository is private.
    pub is_private: bool,
    /// Whether the repository is archived.
    pub is_archived: bool,
    /// ISO-8601 timestamp when the repository was last updated.
    pub updated_at: String,
}
