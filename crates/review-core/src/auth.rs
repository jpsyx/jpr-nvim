//! Shared GitHub CLI authentication error typing and text classification.

use std::fmt;

/// Exit code used by `jpr-review` when a command fails because `gh` is not
/// authenticated with GitHub.
pub const AUTH_EXIT_CODE: u8 = 3;

/// Error raised when `gh` fails because GitHub CLI authentication is missing
/// or invalid (as opposed to `gh` being uninstalled, offline, or rejecting a
/// request for domain validation reasons).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForgeAuthError {
    message: String,
}

impl ForgeAuthError {
    /// Creates a new authentication error preserving `message`.
    #[must_use]
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }

    /// Underlying human-readable failure detail.
    #[must_use]
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for ForgeAuthError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ForgeAuthError {}

/// Returns `true` when any error in `error`'s causal chain is [`ForgeAuthError`].
#[must_use]
pub fn is_auth_error(error: &anyhow::Error) -> bool {
    error
        .chain()
        .any(<dyn std::error::Error + 'static>::is::<ForgeAuthError>)
}

/// Returns `true` when `text` matches a canonical unauthenticated or
/// invalid-token failure from the GitHub CLI (`gh`).
#[must_use]
pub fn is_gh_auth_failure_text(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    if [
        "is the github cli installed",
        "no such file or directory",
        "program not found",
    ]
    .iter()
    .any(|excluded| lower.contains(excluded))
    {
        return false;
    }
    if lower.contains("token in") && lower.contains("is invalid") {
        return true;
    }
    [
        "gh auth login",
        "not logged into any github hosts",
        "not authenticated",
        "authentication required",
        "failed to authenticate",
        "bad credentials",
        "http 401",
        "no oauth token",
        "requires authentication",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}
