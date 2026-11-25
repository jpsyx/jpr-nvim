use std::env;

use anyhow::{Context, Result};
use review_workspace_git::inspect_local_worktree;

/// Runs `jpr-review state-path` for pull request `number` of `repo` (owner/name).
pub fn run(number: u64, repo: &str) -> Result<()> {
    let (owner, name) = super::parse_repo(repo)?;
    println!("{}", super::state_dir(&owner, &name, number)?.display());
    Ok(())
}

/// Runs `jpr-review state-path --local` for the current worktree and branch.
pub fn run_local(repo: Option<&str>) -> Result<()> {
    let cwd = env::current_dir().context("reading the current directory")?;
    let info = inspect_local_worktree(&cwd, Some("HEAD"))?;
    let effective_repo = repo
        .map(str::to_owned)
        .or_else(|| super::socket_client::infer_repo_from_git_remote(&info.worktree));
    let dir = super::local_state_dir(&info.worktree, &info.branch, effective_repo.as_deref())?;
    println!("{}", dir.display());
    Ok(())
}
