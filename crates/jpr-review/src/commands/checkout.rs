//! `checkout`: put a pull request in its own worktree and say where.

use std::env;
use std::path::Path;

use anyhow::{Context, Result, bail};
use review_core::ports::Forge;
use review_forge_github::GhForge;
use review_model::PullRequest;
use review_workspace_git::{WorktreeCommand, checkout_pr};
use serde_json::json;

use crate::theme::Theme;

pub fn run(
    number: u64,
    expected_repo: Option<&str>,
    worktree_cmd: Option<&str>,
    theme: Theme,
) -> Result<()> {
    let cwd = env::current_dir().context("reading the current directory")?;
    super::narrate(theme, &format!("Looking up pull request #{number}..."));
    let pr = GhForge::new(cwd.clone(), None).pull_request(number)?;
    // Checked before any worktree exists, so a mismatch leaves nothing behind.
    ensure_expected_repo(&pr, expected_repo)?;
    super::narrate(
        theme,
        &format!("Checking out #{number} ({})...", pr.head_ref),
    );
    let command = worktree_cmd.map_or(WorktreeCommand::Default, |template| {
        WorktreeCommand::Custom(template.to_owned())
    });
    let worktree = checkout_pr(&cwd, number, &command)?;
    println!("{}", output_line(&pr, &worktree));
    Ok(())
}

/// Fails when `expected` (owner/name) is set and `pr` is in another repository.
///
/// The worktree comes from the current directory's repository, so a pull
/// request URL for another repository cannot be checked out here.
pub fn ensure_expected_repo(pr: &PullRequest, expected: Option<&str>) -> Result<()> {
    let Some(expected) = expected else {
        return Ok(());
    };
    let (owner, name) = super::parse_repo(expected)?;
    if owner.eq_ignore_ascii_case(&pr.owner) && name.eq_ignore_ascii_case(&pr.repo) {
        return Ok(());
    }
    bail!(
        "expected a pull request in {expected}, but this directory is a checkout of {}/{}; \
         run this from a checkout of {expected}",
        pr.owner,
        pr.repo,
    )
}

/// The JSON line `checkout` prints for its caller.
#[must_use]
pub fn output_line(pr: &PullRequest, worktree: &Path) -> String {
    json!({
        "worktree": worktree,
        "repo": format!("{}/{}", pr.owner, pr.repo),
        "number": pr.number,
        "title": pr.title,
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use review_core::fakes::sample_pr;

    use super::*;

    #[test]
    fn any_repository_is_accepted_when_none_is_expected() {
        assert!(ensure_expected_repo(&sample_pr(), None).is_ok());
    }

    #[test]
    fn the_expected_repository_matches_ignoring_case() {
        assert!(ensure_expected_repo(&sample_pr(), Some("octo/widgets")).is_ok());
        assert!(ensure_expected_repo(&sample_pr(), Some("Octo/Widgets")).is_ok());
    }

    #[test]
    fn another_repository_is_refused() {
        let error = ensure_expected_repo(&sample_pr(), Some("octo/gadgets")).unwrap_err();
        let message = error.to_string();
        assert!(message.contains("octo/gadgets"), "{message}");
        assert!(message.contains("octo/widgets"), "{message}");
    }

    #[test]
    fn a_malformed_expected_repository_is_refused() {
        assert!(ensure_expected_repo(&sample_pr(), Some("widgets")).is_err());
    }

    #[test]
    fn prints_the_worktree_and_the_repository() {
        let line = output_line(&sample_pr(), Path::new("/tmp/widgets-worktrees/pr-7"));
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(value["worktree"], "/tmp/widgets-worktrees/pr-7");
        assert_eq!(value["repo"], "octo/widgets");
        assert_eq!(value["number"], 7);
        assert_eq!(value["title"], "Fix the widget");
    }
}
