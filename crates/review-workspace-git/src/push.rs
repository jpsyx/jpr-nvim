//! Branch-safe `git push` from a PR worktree to the pull request's remote branch.

use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result, bail};

use crate::process::run_bytes_unlocked;
use crate::status::read_head_commit;
use crate::unattended::run_unattended;

/// Pushes `HEAD` in `dir` to `head_ref` on the branch's configured remote (or `origin`)
/// and returns the pushed `HEAD` commit SHA.
pub fn push_head_to_pr_branch(dir: &Path, head_ref: &str, timeout: Duration) -> Result<String> {
    if !is_safe_branch_ref(head_ref) {
        bail!("invalid pull request head branch {head_ref:?}");
    }
    let (remote, merge_ref) = resolve_push_target(dir, head_ref)?;
    let refspec = format!("HEAD:{merge_ref}");
    run_unattended(
        "git",
        &["push", "--porcelain", &remote, &refspec],
        dir,
        timeout,
    )
    .with_context(|| format!("pushing HEAD to {remote} ({merge_ref})"))?;
    read_head_commit(dir)
}

fn resolve_push_target(dir: &Path, head_ref: &str) -> Result<(String, String)> {
    let default_merge_ref = format!("refs/heads/{head_ref}");
    let Some(local_branch) = read_current_branch(dir) else {
        return Ok(("origin".to_owned(), default_merge_ref));
    };
    let remote = read_git_config(dir, &format!("branch.{local_branch}.pushRemote"))
        .or_else(|| read_git_config(dir, &format!("branch.{local_branch}.remote")))
        .unwrap_or_else(|| "origin".to_owned());
    let merge_ref =
        read_git_config(dir, &format!("branch.{local_branch}.merge")).unwrap_or(default_merge_ref);
    validate_push_target(&remote, &merge_ref)?;
    Ok((remote, merge_ref))
}

fn validate_push_target(remote: &str, merge_ref: &str) -> Result<()> {
    let is_remote_safe = !remote.is_empty()
        && !remote.starts_with('-')
        && !remote
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace());
    if !is_remote_safe {
        bail!("invalid git push remote {remote:?}");
    }
    let Some(branch_suffix) = merge_ref.strip_prefix("refs/heads/") else {
        bail!("refusing to push to non-branch ref {merge_ref:?}");
    };
    if !is_safe_branch_ref(branch_suffix) {
        bail!("invalid target branch ref {merge_ref:?}");
    }
    Ok(())
}

fn read_current_branch(dir: &Path) -> Option<String> {
    let output =
        run_bytes_unlocked("git", &["symbolic-ref", "--quiet", "--short", "HEAD"], dir).ok()?;
    let branch = std::str::from_utf8(&output).ok()?.trim();
    (!branch.is_empty()).then(|| branch.to_owned())
}

fn read_git_config(dir: &Path, key: &str) -> Option<String> {
    let output = run_bytes_unlocked("git", &["config", "--get", key], dir).ok()?;
    let value = std::str::from_utf8(&output).ok()?.trim();
    (!value.is_empty()).then(|| value.to_owned())
}

/// Whether `branch` is a safe git branch name (without the `refs/heads/` prefix)
/// that cannot be interpreted as a `git push` flag or invalid ref expression.
#[must_use]
pub fn is_safe_branch_ref(branch: &str) -> bool {
    !branch.is_empty()
        && branch != "@"
        && !branch.starts_with(['-', '/'])
        && !branch.ends_with(['/', '.'])
        && !branch.contains("..")
        && !branch.contains("@{")
        && !branch.bytes().any(is_forbidden_ref_byte)
        && branch.split('/').all(is_safe_branch_segment)
}

const fn is_forbidden_ref_byte(byte: u8) -> bool {
    byte.is_ascii_control()
        || byte.is_ascii_whitespace()
        || matches!(byte, b'\\' | b'~' | b'^' | b':' | b'?' | b'*' | b'[')
}

fn is_safe_branch_segment(segment: &str) -> bool {
    !segment.is_empty()
        && !segment.starts_with('.')
        && !segment.ends_with('.')
        && !Path::new(segment)
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("lock"))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    use review_core::ports::Workspace;

    use super::*;
    use crate::GitWorkspace;
    use crate::process::run;
    use crate::test_support::{git, repo};

    fn create_origin_and_worktree() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let dir = repo();
        let worktree = dir.path().join("widgets");
        let origin = dir.path().join("origin.git");
        git(
            dir.path(),
            &["init", "--bare", "-q", "-b", "main", "origin.git"],
        );
        git(
            &worktree,
            &["remote", "add", "origin", origin.to_str().unwrap()],
        );
        git(&worktree, &["push", "-q", "origin", "main:refs/heads/main"]);
        git(
            &worktree,
            &["push", "-q", "origin", "main:refs/heads/fix/widget"],
        );
        (dir, worktree, origin)
    }

    fn commit_change(worktree: &Path, name: &str, body: &str) -> String {
        fs::write(worktree.join(name), body).unwrap();
        git(worktree, &["add", name]);
        git(worktree, &["commit", "-q", "-m", name]);
        run("git", &["rev-parse", "HEAD"], worktree)
            .unwrap()
            .trim()
            .to_owned()
    }

    fn read_ref_sha(repo_dir: &Path, reference: &str) -> String {
        run("git", &["rev-parse", reference], repo_dir)
            .unwrap()
            .trim()
            .to_owned()
    }

    #[test]
    fn pushes_mismatched_local_branch_when_merge_config_points_to_pr_branch() {
        let (_dir, worktree, origin) = create_origin_and_worktree();
        let main_sha = read_ref_sha(&origin, "refs/heads/main");
        git(&worktree, &["checkout", "-q", "-b", "pr-7"]);
        git(&worktree, &["config", "branch.pr-7.remote", "origin"]);
        git(
            &worktree,
            &["config", "branch.pr-7.merge", "refs/heads/fix/widget"],
        );
        let expected_sha = commit_change(&worktree, "fix.txt", "patched\n");

        let pushed_sha = GitWorkspace::new(worktree).push_head("fix/widget").unwrap();

        assert_eq!(pushed_sha, expected_sha);
        assert_eq!(read_ref_sha(&origin, "refs/heads/fix/widget"), expected_sha);
        assert_eq!(read_ref_sha(&origin, "refs/heads/main"), main_sha);
    }

    #[test]
    fn pushes_mismatched_local_branch_when_branch_merge_config_is_unset() {
        let (_dir, worktree, origin) = create_origin_and_worktree();
        git(&worktree, &["checkout", "-q", "-b", "pr-7"]);
        git(&worktree, &["config", "branch.pr-7.remote", "origin"]);
        let expected_sha = commit_change(&worktree, "untracked_cfg.txt", "v2\n");

        let pushed_sha = GitWorkspace::new(worktree).push_head("fix/widget").unwrap();

        assert_eq!(pushed_sha, expected_sha);
        assert_eq!(read_ref_sha(&origin, "refs/heads/fix/widget"), expected_sha);
    }

    #[test]
    fn pushes_detached_head_to_pr_branch_on_origin() {
        let (_dir, worktree, origin) = create_origin_and_worktree();
        git(&worktree, &["checkout", "-q", "--detach"]);
        let expected_sha = commit_change(&worktree, "detached.txt", "detached\n");

        let pushed_sha = GitWorkspace::new(worktree).push_head("fix/widget").unwrap();

        assert_eq!(pushed_sha, expected_sha);
        assert_eq!(read_ref_sha(&origin, "refs/heads/fix/widget"), expected_sha);
    }

    #[test]
    fn rejects_invalid_head_refs_before_spawning_git_push() {
        let non_repo = tempfile::tempdir().unwrap();
        let invalid_refs = [
            "",
            "@",
            "-f",
            "--mirror",
            "/fix",
            "fix/",
            "fix.",
            "fix.lock",
            "fix/sub.lock",
            "fix/.hidden",
            "fix//widget",
            "fix..widget",
            "fix@{0}",
            "fix\\widget",
            "fix~1",
            "fix^1",
            "fix:widget",
            "fix?widget",
            "fix*widget",
            "fix[0]",
            "fix widget",
            "fix\twidget",
            "fix\nwidget",
            "fix\0widget",
        ];
        for bad_ref in invalid_refs {
            let error = push_head_to_pr_branch(non_repo.path(), bad_ref, Duration::from_secs(5))
                .unwrap_err();
            let message = format!("{error:#}");
            assert!(
                message.contains("invalid pull request head branch"),
                "unexpected error for {bad_ref:?}: {message}"
            );
        }
    }

    #[test]
    fn prefers_push_remote_over_branch_remote_and_rejects_unsafe_config_targets() {
        let (dir, worktree, _origin) = create_origin_and_worktree();
        let fork = dir.path().join("fork.git");
        git(
            dir.path(),
            &["init", "--bare", "-q", "-b", "main", "fork.git"],
        );
        git(
            &worktree,
            &["remote", "add", "fork", fork.to_str().unwrap()],
        );
        git(&worktree, &["checkout", "-q", "-b", "pr-7"]);
        git(&worktree, &["config", "branch.pr-7.remote", "origin"]);
        git(&worktree, &["config", "branch.pr-7.pushRemote", "fork"]);
        let expected_sha = commit_change(&worktree, "fork.txt", "forked\n");

        let pushed_sha = GitWorkspace::new(worktree.clone())
            .push_head("fix/widget")
            .unwrap();
        assert_eq!(pushed_sha, expected_sha);
        assert_eq!(read_ref_sha(&fork, "refs/heads/fix/widget"), expected_sha);

        git(
            &worktree,
            &["config", "branch.pr-7.pushRemote", "--upload-pack=bad"],
        );
        assert!(
            GitWorkspace::new(worktree.clone())
                .push_head("fix/widget")
                .is_err()
        );

        git(&worktree, &["config", "--unset", "branch.pr-7.pushRemote"]);
        git(&worktree, &["config", "branch.pr-7.merge", "refs/tags/v1"]);
        assert!(GitWorkspace::new(worktree).push_head("fix/widget").is_err());
    }
}
