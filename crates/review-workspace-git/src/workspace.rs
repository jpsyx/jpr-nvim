//! The git [`Workspace`]: a pull request's worktree and its history.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use review_core::ports::{FastForwardOutcome, Workspace, WorktreeStatus};

use crate::git_output::{
    is_batch_request_safe, is_commit_id, parse_batch_blob, parse_nul_paths,
    parse_porcelain_z_paths, parse_renames,
};
use crate::process::{run, run_bytes, run_bytes_unlocked, run_with_input};
use crate::unattended::run_unattended;
use crate::worktree_path::{path_to_safe_relative, read_in_worktree};

/// [`Workspace`] over git in one worktree, for any frontend reviewing a
/// checked-out pull request.
#[derive(Debug, Clone)]
pub struct GitWorkspace {
    dir: PathBuf,
    fetch_timeout: Duration,
}

/// How long fetching a missing base commit may take before it is stopped.
///
/// Long enough for a slow network, short enough that a fetch stuck at an ssh
/// prompt or a stalled connection does not hold the session for long.
pub const FETCH_TIMEOUT: Duration = Duration::from_secs(90);

impl GitWorkspace {
    /// A workspace over the worktree at `dir`.
    #[must_use]
    pub const fn new(dir: PathBuf) -> Self {
        Self {
            dir,
            fetch_timeout: FETCH_TIMEOUT,
        }
    }

    /// A workspace over the worktree that holds `dir`, which may be one of
    /// its subdirectories: paths are always read from the worktree's root.
    pub fn open(dir: &Path) -> Result<Self> {
        let stdout = run("git", &["rev-parse", "--show-toplevel"], dir)
            .context("finding the worktree's root (is this a git checkout?)")?;
        Ok(Self::new(PathBuf::from(
            stdout.trim_end_matches(['\n', '\r']),
        )))
    }

    /// This workspace with fetches stopped after `timeout` instead of
    /// [`FETCH_TIMEOUT`].
    #[must_use]
    pub const fn with_fetch_timeout(mut self, timeout: Duration) -> Self {
        self.fetch_timeout = timeout;
        self
    }

    /// Fetches `commit` from `origin` unless this repository already has it.
    pub(crate) fn ensure_commit(&self, commit: &str) -> Result<()> {
        let commit_object = format!("{commit}^{{commit}}");
        if run("git", &["cat-file", "-e", &commit_object], &self.dir).is_ok() {
            return Ok(());
        }
        run_unattended(
            "git",
            &["fetch", "--quiet", "--no-tags", "origin", commit],
            &self.dir,
            self.fetch_timeout,
        )
        .with_context(|| format!("fetching commit {commit} from origin"))?;
        Ok(())
    }
}

/// Fails unless `value` is a commit id, so it can never reach git as an option.
pub fn require_commit_id(value: &str) -> Result<()> {
    if is_commit_id(value) {
        Ok(())
    } else {
        bail!("{value:?} is not a commit id")
    }
}

impl Workspace for GitWorkspace {
    fn merge_base(&self, base_sha: &str) -> Result<String> {
        require_commit_id(base_sha)?;
        self.ensure_commit(base_sha)?;
        let stdout = run("git", &["merge-base", base_sha, "HEAD"], &self.dir)
            .context("finding where the pull request branches off its base")?;
        Ok(stdout.trim().to_owned())
    }

    /// `path` as it is in `commit`, or `None` when it is not a file there.
    ///
    /// A missing commit and a missing file both read as `None`, so callers
    /// pass the merge base, a commit [`Workspace::merge_base`] has made sure
    /// this repository holds.
    fn file_at(&self, commit: &str, path: &str) -> Result<Option<Vec<u8>>> {
        require_commit_id(commit)?;
        path_to_safe_relative(path)?;
        if !is_batch_request_safe(path) {
            bail!("{path:?} cannot be read from git: it holds a line break or a NUL byte");
        }
        let request = format!("{commit}:{path}\n");
        let output = run_with_input(
            "git",
            &["cat-file", "--batch"],
            &self.dir,
            request.as_bytes(),
        )
        .with_context(|| format!("reading {path} at {commit} from git"))?;
        parse_batch_blob(output).with_context(|| format!("reading {path} at {commit}"))
    }

    fn file_on_disk(&self, path: &str) -> Result<Option<Vec<u8>>> {
        read_in_worktree(&self.dir, path)
    }

    fn renames(&self, commit: &str) -> Result<Vec<(String, String)>> {
        require_commit_id(commit)?;
        // The plumbing `diff-index`, not `diff`: `diff` refreshes the index
        // and writes it back, which takes `index.lock` in the reviewer's
        // worktree and can make their own `git commit` fail.
        let output = run_bytes(
            "git",
            &["diff-index", "--name-status", "-z", "-M", commit, "--"],
            &self.dir,
        )
        .with_context(|| format!("finding the files renamed since {commit}"))?;
        Ok(parse_renames(&output))
    }

    fn list_changed_files_since(&self, commit: &str) -> Result<Vec<String>> {
        require_commit_id(commit)?;
        let diff_output = run_bytes_unlocked(
            "git",
            &["diff-index", "--name-only", "-z", commit, "--"],
            &self.dir,
        )
        .with_context(|| format!("listing files changed since {commit}"))?;
        let status_output = run_bytes_unlocked(
            "git",
            &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            &self.dir,
        )
        .context("listing worktree status changes")?;
        let mut paths = BTreeSet::new();
        for path in parse_nul_paths(&diff_output)
            .into_iter()
            .chain(parse_porcelain_z_paths(&status_output))
        {
            if path_to_safe_relative(&path).is_ok() {
                paths.insert(path);
            }
        }
        Ok(paths.into_iter().collect())
    }

    fn head_commit(&self) -> Result<String> {
        crate::status::read_head_commit(&self.dir)
    }

    fn worktree_status(&self, remote_head_sha: Option<&str>) -> Result<WorktreeStatus> {
        crate::status::read_worktree_status(&self.dir, remote_head_sha)
    }

    fn push_head(&self, head_ref: &str) -> Result<String> {
        crate::push::push_head_to_pr_branch(&self.dir, head_ref, self.fetch_timeout)
    }

    fn fast_forward_to(&self, target_sha: &str) -> Result<FastForwardOutcome> {
        crate::fast_forward::fast_forward_worktree(self, &self.dir, target_sha)
    }
}

#[cfg(test)]
mod tests;
