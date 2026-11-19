//! `checkout`: put a pull request in its own worktree and say where.

use std::env;
use std::path::Path;

use anyhow::{Context, Result};
use review_core::ports::Forge;
use review_forge_github::GhForge;
use review_model::PullRequest;
use review_workspace_git::{WorktreeCommand, checkout_pr};
use serde_json::json;

use crate::theme::Theme;

pub fn run(number: u64, worktree_cmd: Option<&str>, theme: Theme) -> Result<()> {
    let cwd = env::current_dir().context("reading the current directory")?;
    super::narrate(theme, &format!("Looking up pull request #{number}..."));
    let pr = GhForge::new(cwd.clone(), None).pull_request(number)?;
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
    fn prints_the_worktree_and_the_repository() {
        let line = output_line(&sample_pr(), Path::new("/tmp/widgets-worktrees/pr-7"));
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(value["worktree"], "/tmp/widgets-worktrees/pr-7");
        assert_eq!(value["repo"], "octo/widgets");
        assert_eq!(value["number"], 7);
        assert_eq!(value["title"], "Fix the widget");
    }
}
