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
    let (remote, merge_ref) = get_push_target_from_config(&config, pr)?;
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

fn get_push_target_from_config(
    config: &BranchPushConfig,
    pr: &PullRequest,
) -> Result<(String, String)> {
    let default_merge_ref = format!("refs/heads/{}", pr.head_ref);
    let (local_branch, remote, merge_ref) = if pr.is_cross_repository {
        get_cross_repo_branch_from_config(config, &default_merge_ref)?
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

fn get_cross_repo_branch_from_config<'a>(
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
mod tests;
