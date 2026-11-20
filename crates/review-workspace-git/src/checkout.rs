use std::path::{Path, PathBuf};

use anyhow::Result;

use crate::custom::checkout_custom;
use crate::default_checkout::checkout_default;

/// How to create a pull request's worktree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorktreeCommand {
    /// `git worktree add` beside the repository, then `gh pr checkout`.
    Default,
    /// A shell command that creates the worktree and prints its path as its
    /// last line of output. `{n}` is replaced with the pull request number.
    Custom(String),
}

/// `template` with `{n}` replaced by `number`.
#[must_use]
pub fn render_custom(template: &str, number: u64) -> String {
    template.replace("{n}", &number.to_string())
}

/// Checks pull request `number` out into a worktree and returns its path.
///
/// An existing default worktree is reused only when it is on the pull
/// request's branch; anything else at that path is an error, never removed.
pub fn checkout_pr(dir: &Path, number: u64, command: &WorktreeCommand) -> Result<PathBuf> {
    match command {
        WorktreeCommand::Custom(template) => checkout_custom(dir, &render_custom(template, number)),
        WorktreeCommand::Default => checkout_default(dir, number),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_custom_substitutes_the_number() {
        assert_eq!(render_custom("wt pr {n}", 42), "wt pr 42");
    }
}
