use std::env;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use review_core::ports::{Forge, ReviewStore};
use review_forge_github::GhForge;
use review_model::PullRequest;
use review_store_fs::FsStore;
use review_workspace_git::{
    WorktreeCommand, checkout_pr, ensure_managed_clone, find_existing_pr_worktree, main_repo_root,
    managed_repo_dir,
};
use serde_json::json;

use crate::theme::Theme;

/// Runs `jpr-review checkout`: returns an existing PR worktree or checks one out.
///
/// Reuses any existing worktree already on the pull request's branch without
/// re-running `gh pr checkout` or `worktree_cmd`, and prints one JSON line on
/// stdout for the Neovim plugin to open. When invoked outside a git repository,
/// `--repo <owner/name>` is required and the repository is cloned on demand
/// into the managed XDG cache directory before creating PR worktrees.
pub fn run(
    number: u64,
    expected_repo: Option<&str>,
    worktree_cmd: Option<&str>,
    theme: Theme,
) -> Result<()> {
    let cwd = env::current_dir().context("reading the current directory")?;
    let (pr, checkout_root) = if main_repo_root(&cwd).is_ok() {
        super::narrate(theme, &format!("Looking up pull request #{number}..."));
        let pr = GhForge::new(cwd.clone(), None).pull_request(number)?;
        // Checked before any worktree exists, so a mismatch leaves nothing behind.
        ensure_expected_repo(&pr, expected_repo)?;
        (pr, cwd)
    } else {
        prepare_managed_checkout_root(&cwd, number, expected_repo, theme)?
    };
    let worktree = checkout_in_root(&checkout_root, &pr, worktree_cmd, theme)?;
    println!("{}", output_line(&pr, &worktree));
    Ok(())
}

fn prepare_managed_checkout_root(
    cwd: &Path,
    number: u64,
    expected_repo: Option<&str>,
    theme: Theme,
) -> Result<(PullRequest, PathBuf)> {
    let (owner, repo) = require_repo_outside_git(expected_repo)?;
    let slug = format!("{owner}/{repo}");
    super::narrate(
        theme,
        &format!("Looking up pull request #{number} in {slug}..."),
    );
    let pr = GhForge::new(cwd.to_path_buf(), Some(slug)).pull_request(number)?;
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME is not set")?;
    let xdg_cache_home = env::var_os("XDG_CACHE_HOME").map(PathBuf::from);
    let cache_dir = managed_repo_dir(
        xdg_cache_home.as_deref(),
        &home,
        crate::STATE_APP,
        &pr.owner,
        &pr.repo,
    )?;
    if !cache_dir.exists() {
        super::narrate(
            theme,
            &format!("Cloning {}/{} into cache...", pr.owner, pr.repo),
        );
    }
    let root = ensure_managed_clone(&cache_dir, &pr.owner, &pr.repo)?;
    Ok((pr, root))
}

fn checkout_in_root(
    root: &Path,
    pr: &PullRequest,
    worktree_cmd: Option<&str>,
    theme: Theme,
) -> Result<PathBuf> {
    let preferred_worktree = load_saved_worktree(pr);
    if let Some(existing) = find_existing_pr_worktree(
        root,
        pr.number,
        Some(&pr.head_ref),
        pr.is_cross_repository,
        preferred_worktree.as_deref(),
    ) {
        super::narrate(
            theme,
            &format!("Reusing worktree for #{} ({})...", pr.number, pr.head_ref),
        );
        return Ok(existing);
    }
    super::narrate(
        theme,
        &format!("Checking out #{} ({})...", pr.number, pr.head_ref),
    );
    let command = worktree_cmd.map_or(WorktreeCommand::Default, |template| {
        WorktreeCommand::Custom(template.to_owned())
    });
    checkout_pr(root, pr.number, &command)
}

/// Validates `--repo <owner/name>` when running `checkout` outside a git repo.
pub fn require_repo_outside_git(expected_repo: Option<&str>) -> Result<(String, String)> {
    let Some(repo) = expected_repo else {
        bail!("not inside a git repository; pass --repo <owner/name> to check out a pull request");
    };
    super::parse_repo(repo)
}

fn load_saved_worktree(pr: &PullRequest) -> Option<PathBuf> {
    let state_dir = super::state_dir(&pr.owner, &pr.repo, pr.number).ok()?;
    let snapshot = FsStore::new(state_dir).load().ok()?;
    snapshot
        .session
        .worktree
        .filter(|path| !path.trim().is_empty())
        .map(PathBuf::from)
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

    #[test]
    fn out_of_repo_checkout_requires_repo_flag() {
        let error = require_repo_outside_git(None).unwrap_err();
        assert!(error.to_string().contains("--repo"), "{error:#}");
        assert_eq!(
            require_repo_outside_git(Some("octo/widgets")).unwrap(),
            ("octo".to_owned(), "widgets".to_owned())
        );
    }
}
