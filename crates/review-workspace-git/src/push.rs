//! Branch-safe `git push` from a PR worktree to the pull request's remote branch.

use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use review_core::ports::PullRequest;

use crate::process::run_bytes_unlocked;
use crate::status::read_head_commit;
use crate::unattended::run_unattended;

#[derive(Default)]
struct BranchPushConfig {
    local_branch: Option<String>,
    push_remote: Option<String>,
    branch_remote: Option<String>,
    merge_ref: Option<String>,
}

/// Pushes `HEAD` in `dir` to `pr.head_ref` on the branch's configured remote
/// (or `origin` for same-repository pull requests) and returns the pushed `HEAD` commit SHA.
pub fn push_head_to_pr_branch(dir: &Path, pr: &PullRequest, timeout: Duration) -> Result<String> {
    let head_ref = pr.head_ref.as_str();
    if !is_safe_branch_ref(head_ref) {
        bail!("invalid pull request head branch {head_ref:?}");
    }
    let config = read_branch_push_config(dir);
    let (remote, merge_ref) = resolve_push_target_from_config(&config, pr)?;
    if pr.is_cross_repository {
        verify_cross_repo_push_urls(dir, &remote, pr)?;
    }
    let refspec = format!("HEAD:{merge_ref}");
    run_unattended(
        "git",
        &["push", "--porcelain", "--", &remote, &refspec],
        dir,
        timeout,
    )
    .with_context(|| format!("pushing HEAD to {remote} ({merge_ref})"))?;
    read_head_commit(dir)
}

fn read_branch_push_config(dir: &Path) -> BranchPushConfig {
    let Some(local_branch) = read_current_branch(dir) else {
        return BranchPushConfig::default();
    };
    let push_remote = read_git_config(dir, &format!("branch.{local_branch}.pushRemote"));
    let branch_remote = read_git_config(dir, &format!("branch.{local_branch}.remote"));
    let merge_ref = read_git_config(dir, &format!("branch.{local_branch}.merge"));
    BranchPushConfig {
        local_branch: Some(local_branch),
        push_remote,
        branch_remote,
        merge_ref,
    }
}

fn resolve_push_target_from_config(
    config: &BranchPushConfig,
    pr: &PullRequest,
) -> Result<(String, String)> {
    let default_merge_ref = format!("refs/heads/{}", pr.head_ref);
    let (local_branch, remote, merge_ref) = if pr.is_cross_repository {
        resolve_cross_repo_branch_config(config, &default_merge_ref)?
    } else {
        let Some(branch) = config.local_branch.as_deref() else {
            return Ok(("origin".to_owned(), default_merge_ref));
        };
        let target_remote = config
            .push_remote
            .as_ref()
            .or(config.branch_remote.as_ref())
            .cloned()
            .unwrap_or_else(|| "origin".to_owned());
        let target_merge = config
            .merge_ref
            .clone()
            .unwrap_or_else(|| default_merge_ref.clone());
        (branch, target_remote, target_merge)
    };
    validate_push_target(&remote, &merge_ref)?;
    if merge_ref != default_merge_ref {
        bail!(
            "branch {local_branch:?} tracks {merge_ref:?}, which does not match pull request head branch {default_merge_ref:?}"
        );
    }
    Ok((remote, merge_ref))
}

fn resolve_cross_repo_branch_config<'a>(
    config: &'a BranchPushConfig,
    default_merge_ref: &str,
) -> Result<(&'a str, String, String)> {
    let Some(local_branch) = config.local_branch.as_deref() else {
        bail!(
            "refusing to push cross-repository (fork) pull request from detached HEAD: check out the fork branch with explicit remote tracking configured"
        );
    };
    let Some(remote) = config
        .push_remote
        .as_ref()
        .or(config.branch_remote.as_ref())
    else {
        bail!(
            "refusing to push cross-repository (fork) pull request: branch {local_branch:?} has no configured fork remote"
        );
    };
    if config.push_remote.is_none() && config.merge_ref.is_none() {
        bail!(
            "refusing to push cross-repository (fork) pull request: branch {local_branch:?} has no configured upstream merge ref"
        );
    }
    let merge_ref = config
        .merge_ref
        .clone()
        .unwrap_or_else(|| default_merge_ref.to_owned());
    Ok((local_branch, remote.clone(), merge_ref))
}

fn verify_cross_repo_push_urls(dir: &Path, remote: &str, pr: &PullRequest) -> Result<()> {
    let resolved_urls = read_remote_push_urls(dir, remote);
    if resolved_urls.is_empty() {
        return ensure_url_is_not_base_repo(remote, remote, &pr.owner, &pr.repo);
    }
    for url in &resolved_urls {
        ensure_url_is_not_base_repo(remote, url, &pr.owner, &pr.repo)?;
    }
    Ok(())
}

fn ensure_url_is_not_base_repo(
    remote: &str,
    url: &str,
    base_owner: &str,
    base_repo: &str,
) -> Result<()> {
    if does_remote_url_target_repo(url, base_owner, base_repo) {
        bail!(
            "refusing to push cross-repository (fork) pull request to base repository {base_owner}/{base_repo}: configure push remote {remote:?} to point to the fork repository"
        );
    }
    Ok(())
}

fn does_remote_url_target_repo(url: &str, base_owner: &str, base_repo: &str) -> bool {
    parse_owner_repo_from_remote_url(url).is_some_and(|(owner, repo)| {
        owner.eq_ignore_ascii_case(base_owner) && repo.eq_ignore_ascii_case(base_repo)
    })
}

fn parse_owner_repo_from_remote_url(url: &str) -> Option<(String, String)> {
    let trimmed = strip_git_suffix(url.trim().trim_end_matches('/'));
    let path_part = if let Some((scheme, after_scheme)) = trimmed.split_once("://") {
        let is_supported_scheme = matches!(
            scheme.to_ascii_lowercase().as_str(),
            "http" | "https" | "ssh" | "git" | "git+ssh"
        );
        if !is_supported_scheme {
            return None;
        }
        let (host, path) = after_scheme.split_once('/')?;
        if host.is_empty() {
            return None;
        }
        path
    } else if let Some((host, path)) = trimmed.split_once(':') {
        if host.len() <= 1 || host.contains(['/', '\\']) {
            return None;
        }
        path
    } else {
        return None;
    };
    let mut segments = path_part.trim_start_matches('/').split('/');
    let owner = segments.next().filter(|part| is_plain_repo_segment(part))?;
    let repo = segments.next().filter(|part| is_plain_repo_segment(part))?;
    segments
        .next()
        .is_none()
        .then(|| (owner.to_owned(), repo.to_owned()))
}

fn strip_git_suffix(value: &str) -> &str {
    if value.len() > 4
        && value.as_bytes()[value.len() - 4..].eq_ignore_ascii_case(b".git")
        && let Some(prefix) = value.get(..value.len() - 4)
    {
        prefix
    } else {
        value
    }
}

fn is_plain_repo_segment(segment: &str) -> bool {
    !segment.is_empty() && segment != "." && segment != ".."
}

fn read_remote_push_urls(dir: &Path, remote: &str) -> Vec<String> {
    let Ok(output) = run_bytes_unlocked(
        "git",
        &["remote", "get-url", "--push", "--all", "--", remote],
        dir,
    ) else {
        return Vec::new();
    };
    let Ok(text) = std::str::from_utf8(&output) else {
        return Vec::new();
    };
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect()
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
            .is_some_and(|extension| extension.eq_ignore_ascii_case("lock"))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    use review_core::ports::PullRequest;
    use review_core::ports::Workspace;

    use super::*;
    use crate::GitWorkspace;
    use crate::process::run;
    use crate::test_support::{git, repo};

    fn create_pr_from_head(head_ref: &str, is_cross_repository: bool) -> PullRequest {
        PullRequest {
            owner: "octo".into(),
            repo: "widgets".into(),
            number: 7,
            title: "Fix the widget".into(),
            url: "https://github.com/octo/widgets/pull/7".into(),
            node_id: "PR_7".into(),
            author: "alice".into(),
            head_ref: head_ref.into(),
            head_sha: "abc123".into(),
            base_ref: "main".into(),
            base_sha: "base000".into(),
            is_cross_repository,
        }
    }

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

        let pr = create_pr_from_head("fix/widget", false);
        let pushed_sha = GitWorkspace::new(worktree).push_head(&pr).unwrap();

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

        let pr = create_pr_from_head("fix/widget", false);
        let pushed_sha = GitWorkspace::new(worktree).push_head(&pr).unwrap();

        assert_eq!(pushed_sha, expected_sha);
        assert_eq!(read_ref_sha(&origin, "refs/heads/fix/widget"), expected_sha);
    }

    #[test]
    fn pushes_detached_head_to_pr_branch_on_origin() {
        let (_dir, worktree, origin) = create_origin_and_worktree();
        git(&worktree, &["checkout", "-q", "--detach"]);
        let expected_sha = commit_change(&worktree, "detached.txt", "detached\n");

        let pr = create_pr_from_head("fix/widget", false);
        let pushed_sha = GitWorkspace::new(worktree).push_head(&pr).unwrap();

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
            let pr = create_pr_from_head(bad_ref, false);
            let error =
                push_head_to_pr_branch(non_repo.path(), &pr, Duration::from_secs(5)).unwrap_err();
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

        let pr = create_pr_from_head("fix/widget", false);
        let pushed_sha = GitWorkspace::new(worktree.clone()).push_head(&pr).unwrap();
        assert_eq!(pushed_sha, expected_sha);
        assert_eq!(read_ref_sha(&fork, "refs/heads/fix/widget"), expected_sha);

        git(
            &worktree,
            &["config", "branch.pr-7.pushRemote", "--upload-pack=bad"],
        );
        assert!(GitWorkspace::new(worktree.clone()).push_head(&pr).is_err());

        git(&worktree, &["config", "--unset", "branch.pr-7.pushRemote"]);
        git(&worktree, &["config", "branch.pr-7.merge", "refs/tags/v1"]);
        assert!(GitWorkspace::new(worktree).push_head(&pr).is_err());
    }

    #[test]
    fn refuses_to_push_when_branch_tracks_different_upstream_branch() {
        let (_dir, worktree, origin) = create_origin_and_worktree();
        let main_sha = read_ref_sha(&origin, "refs/heads/main");
        git(&worktree, &["checkout", "-q", "-b", "pr-7"]);
        git(&worktree, &["config", "branch.pr-7.remote", "origin"]);
        git(
            &worktree,
            &["config", "branch.pr-7.merge", "refs/heads/main"],
        );
        let _local_sha = commit_change(&worktree, "accidental.txt", "do not land on main\n");

        let pr = create_pr_from_head("fix/widget", false);
        let error = GitWorkspace::new(worktree).push_head(&pr).unwrap_err();
        let message = format!("{error:#}");

        assert!(
            message.contains("does not match pull request head branch"),
            "{message}"
        );
        assert_eq!(read_ref_sha(&origin, "refs/heads/main"), main_sha);
    }

    #[test]
    fn refuses_cross_repository_push_from_detached_head_or_untracked_branch() {
        let (_dir, worktree, origin) = create_origin_and_worktree();
        let origin_main_sha = read_ref_sha(&origin, "refs/heads/main");
        let fork_pr = create_pr_from_head("main", true);

        git(&worktree, &["checkout", "-q", "--detach"]);
        let _detached_sha = commit_change(&worktree, "fork_detached.txt", "fork commit\n");
        let detached_error = GitWorkspace::new(worktree.clone())
            .push_head(&fork_pr)
            .unwrap_err();
        assert!(
            format!("{detached_error:#}").contains("cross-repository"),
            "{detached_error:#}"
        );
        assert_eq!(read_ref_sha(&origin, "refs/heads/main"), origin_main_sha);

        git(&worktree, &["checkout", "-q", "-b", "pr-7"]);
        let untracked_error = GitWorkspace::new(worktree.clone())
            .push_head(&fork_pr)
            .unwrap_err();
        assert!(
            format!("{untracked_error:#}").contains("cross-repository"),
            "{untracked_error:#}"
        );
        assert_eq!(read_ref_sha(&origin, "refs/heads/main"), origin_main_sha);

        git(&worktree, &["config", "branch.pr-7.remote", "origin"]);
        let missing_merge_error = GitWorkspace::new(worktree).push_head(&fork_pr).unwrap_err();
        assert!(
            format!("{missing_merge_error:#}").contains("cross-repository"),
            "{missing_merge_error:#}"
        );
        assert_eq!(read_ref_sha(&origin, "refs/heads/main"), origin_main_sha);
    }

    #[test]
    fn refuses_cross_repository_push_when_remote_points_to_base_repository() {
        let (_dir, worktree, _origin) = create_origin_and_worktree();
        let fork_pr = create_pr_from_head("main", true);
        git(&worktree, &["checkout", "-q", "-b", "pr-7"]);
        git(&worktree, &["config", "branch.pr-7.remote", "origin"]);
        git(
            &worktree,
            &["config", "branch.pr-7.merge", "refs/heads/main"],
        );
        let _fork_sha = commit_change(&worktree, "fork_main.txt", "fork commit\n");

        for base_url in [
            "https://github.com/Octo/Widgets.git",
            "git@github.com:octo/WIDGETS.GIT",
            "ssh://git@github.com:22/octo/widgets",
        ] {
            git(&worktree, &["remote", "set-url", "origin", base_url]);
            let error = GitWorkspace::new(worktree.clone())
                .push_head(&fork_pr)
                .unwrap_err();
            let message = format!("{error:#}");
            assert!(
                message.contains("octo/widgets"),
                "expected base repo refusal for {base_url}: {message}"
            );
        }

        git(
            &worktree,
            &[
                "config",
                "branch.pr-7.remote",
                "https://github.com/octo/widgets.git",
            ],
        );
        let direct_url_error = GitWorkspace::new(worktree).push_head(&fork_pr).unwrap_err();
        assert!(
            format!("{direct_url_error:#}").contains("octo/widgets"),
            "{direct_url_error:#}"
        );
    }

    fn create_bare_fork_remote(dir: &Path, worktree: &Path) -> PathBuf {
        let fork = dir.join("contributor-widgets.git");
        git(
            dir,
            &[
                "init",
                "--bare",
                "-q",
                "-b",
                "main",
                "contributor-widgets.git",
            ],
        );
        git(worktree, &["remote", "add", "fork", fork.to_str().unwrap()]);
        git(worktree, &["push", "-q", "fork", "main:refs/heads/main"]);
        fork
    }

    #[test]
    fn pushes_cross_repository_pr_when_explicit_fork_remote_is_configured() {
        let (dir, worktree, origin) = create_origin_and_worktree();
        let origin_main_sha = read_ref_sha(&origin, "refs/heads/main");
        let fork = create_bare_fork_remote(dir.path(), &worktree);

        let fork_pr = create_pr_from_head("main", true);
        git(&worktree, &["checkout", "-q", "-b", "pr-7"]);
        git(&worktree, &["config", "branch.pr-7.remote", "fork"]);
        git(
            &worktree,
            &["config", "branch.pr-7.merge", "refs/heads/main"],
        );
        let first_fork_sha = commit_change(&worktree, "fork_ok.txt", "fork 1\n");

        let pushed_sha = GitWorkspace::new(worktree.clone())
            .push_head(&fork_pr)
            .unwrap();
        assert_eq!(pushed_sha, first_fork_sha);
        assert_eq!(read_ref_sha(&fork, "refs/heads/main"), first_fork_sha);
        assert_eq!(read_ref_sha(&origin, "refs/heads/main"), origin_main_sha);

        git(&worktree, &["config", "--unset", "branch.pr-7.merge"]);
        git(&worktree, &["config", "branch.pr-7.remote", "origin"]);
        git(&worktree, &["config", "branch.pr-7.pushRemote", "fork"]);
        let second_fork_sha = commit_change(&worktree, "fork_ok2.txt", "fork 2\n");
        let pushed_via_push_remote = GitWorkspace::new(worktree).push_head(&fork_pr).unwrap();
        assert_eq!(pushed_via_push_remote, second_fork_sha);
        assert_eq!(read_ref_sha(&fork, "refs/heads/main"), second_fork_sha);
        assert_eq!(read_ref_sha(&origin, "refs/heads/main"), origin_main_sha);
    }
}
