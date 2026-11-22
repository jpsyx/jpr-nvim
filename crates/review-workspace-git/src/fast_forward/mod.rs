//! Dirty-worktree auto-stash, `--ff-only` fast-forward, and stash-restore conflict detection.

mod stash;

use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use review_core::ports::FastForwardOutcome;

use crate::GitWorkspace;
use crate::process::{create_command, run, run_bytes_unlocked};
use crate::status::read_head_commit;
use crate::workspace::require_commit_id;

const ACTIVE_GIT_STATE_NAMES: [&str; 7] = [
    "rebase-merge",
    "rebase-apply",
    "MERGE_HEAD",
    "CHERRY_PICK_HEAD",
    "REVERT_HEAD",
    "BISECT_LOG",
    "sequencer",
];

/// Attempts to fast-forward the worktree at `dir` to `target_sha`, stashing and
/// restoring dirty tracked and untracked changes when needed.
pub fn fast_forward_worktree(
    workspace: &GitWorkspace,
    dir: &Path,
    target_sha: &str,
) -> Result<FastForwardOutcome> {
    require_commit_id(target_sha)?;
    let previous_sha = read_head_commit(dir)?;
    if previous_sha == target_sha {
        return Ok(FastForwardOutcome::AlreadyAtTarget {
            head_sha: previous_sha,
        });
    }
    workspace.ensure_commit(target_sha)?;
    if is_ancestor(dir, target_sha, &previous_sha)? {
        return Ok(FastForwardOutcome::AheadOfTarget {
            head_sha: previous_sha,
            target_sha: target_sha.to_owned(),
        });
    }
    if !is_ancestor(dir, &previous_sha, target_sha)? {
        return Ok(FastForwardOutcome::Diverged {
            head_sha: previous_sha,
            target_sha: target_sha.to_owned(),
        });
    }
    ensure_no_active_git_operation(dir)?;
    if !is_worktree_dirty(dir)? {
        merge_fast_forward_only(dir, target_sha)?;
        return Ok(FastForwardOutcome::FastForwarded {
            previous_sha,
            head_sha: read_head_commit(dir)?,
        });
    }
    stash::stash_fast_forward_and_restore(dir, &previous_sha, target_sha)
}

fn ensure_no_active_git_operation(dir: &Path) -> Result<()> {
    let mut args = vec!["rev-parse"];
    for state_name in ACTIVE_GIT_STATE_NAMES {
        args.extend(["--git-path", state_name]);
    }
    let output = run_bytes_unlocked("git", &args, dir)
        .context("checking for in-progress git operations before fast-forward")?;
    let resolved_text =
        std::str::from_utf8(&output).context("decoding git-path output as UTF-8")?;
    let resolved_lines: Vec<&str> = resolved_text.lines().collect();
    if resolved_lines.len() != ACTIVE_GIT_STATE_NAMES.len() {
        bail!(
            "git rev-parse --git-path returned {} lines, expected {}",
            resolved_lines.len(),
            ACTIVE_GIT_STATE_NAMES.len()
        );
    }
    for (state_name, resolved_line) in ACTIVE_GIT_STATE_NAMES.into_iter().zip(resolved_lines) {
        if fs::symlink_metadata(dir.join(resolved_line)).is_ok() {
            bail!("cannot fast-forward worktree while git operation ({state_name}) is in progress");
        }
    }
    Ok(())
}

fn is_ancestor(dir: &Path, ancestor: &str, descendant: &str) -> Result<bool> {
    let args = ["merge-base", "--is-ancestor", ancestor, descendant];
    let output = create_command("git", &args, dir)
        .output()
        .context("checking commit ancestry with git merge-base")?;
    match output.status.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let detail = stderr.trim();
            if detail.is_empty() {
                bail!("git {} failed with {}", args.join(" "), output.status);
            }
            bail!("git merge-base --is-ancestor failed: {detail}");
        }
    }
}

fn is_worktree_dirty(dir: &Path) -> Result<bool> {
    let status_output = run_bytes_unlocked(
        "git",
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        dir,
    )
    .context("checking worktree dirty state before fast-forward")?;
    Ok(!status_output.is_empty())
}

fn merge_fast_forward_only(dir: &Path, target_sha: &str) -> Result<()> {
    run(
        "git",
        &["merge", "--ff-only", "--no-overwrite-ignore", target_sha],
        dir,
    )
    .with_context(|| format!("fast-forwarding HEAD to {target_sha}"))?;
    Ok(())
}

#[cfg(test)]
mod tests;
