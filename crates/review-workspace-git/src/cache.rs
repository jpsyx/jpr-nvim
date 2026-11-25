//! Managed XDG clone cache for checking out pull requests outside an existing
//! local git repository.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Context, Result, bail};

use crate::process::run;
use crate::repo::main_repo_root;

static CLONE_STAGE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn validate_path_segment(label: &str, value: &str) -> Result<()> {
    if value.is_empty()
        || value == "."
        || value == ".."
        || value.starts_with('-')
        || value.bytes().any(|byte| {
            matches!(byte, b'/' | b'\\') || byte.is_ascii_whitespace() || byte.is_ascii_control()
        })
    {
        bail!("invalid {label} segment {value:?}");
    }
    Ok(())
}

/// Resolves `<cache_root>/<app>/repos/<owner>/<repo>`, using `xdg_cache_home`
/// when present and absolute, or `<home>/.cache` otherwise.
pub fn managed_repo_dir(
    xdg_cache_home: Option<&Path>,
    home: &Path,
    app: &str,
    owner: &str,
    repo: &str,
) -> Result<PathBuf> {
    validate_path_segment("app", app)?;
    validate_path_segment("owner", owner)?;
    validate_path_segment("repository", repo)?;
    let cache_root = xdg_cache_home
        .filter(|path| !path.as_os_str().is_empty() && path.is_absolute())
        .map_or_else(|| home.join(".cache"), Path::to_path_buf);
    Ok(cache_root.join(app).join("repos").join(owner).join(repo))
}

/// Parses `(owner, repo)` from an HTTPS or SSH GitHub remote URL.
#[must_use]
pub fn parse_owner_repo_from_remote_url(url: &str) -> Option<(String, String)> {
    let trimmed = url.trim().trim_end_matches('/').trim_end_matches(".git");
    let path = if let Some(rest) = trimmed.split("://").nth(1) {
        rest.split_once('/')?.1
    } else if let Some((_, rest)) = trimmed.split_once(':') {
        rest
    } else {
        return None;
    };
    let mut parts = path.split('/').filter(|part| !part.is_empty());
    let owner = parts.next()?;
    let repo = parts.next()?;
    if parts.next().is_some() {
        return None;
    }
    Some((owner.to_owned(), repo.to_owned()))
}

fn verify_existing_clone(repo_dir: &Path, owner: &str, repo: &str) -> Result<PathBuf> {
    let root = main_repo_root(repo_dir).with_context(|| {
        format!(
            "{} already exists but is not a git repository for {owner}/{repo}; inspect or remove it and try again",
            repo_dir.display()
        )
    })?;
    let is_same_root = matches!(
        (root.canonicalize(), repo_dir.canonicalize()),
        (Ok(left), Ok(right)) if left == right
    );
    if !is_same_root {
        bail!(
            "{} already exists inside another git repository; inspect or remove it and try again",
            repo_dir.display()
        );
    }
    let remote_url = run("git", &["remote", "get-url", "origin"], repo_dir).with_context(|| {
        format!(
            "{} has no origin remote matching {owner}/{repo}; inspect or remove it and try again",
            repo_dir.display()
        )
    })?;
    let Some((actual_owner, actual_repo)) = parse_owner_repo_from_remote_url(&remote_url) else {
        bail!(
            "{} has unrecognized origin remote {:?}; expected {owner}/{repo}",
            repo_dir.display(),
            remote_url.trim()
        );
    };
    if !actual_owner.eq_ignore_ascii_case(owner) || !actual_repo.eq_ignore_ascii_case(repo) {
        bail!(
            "{} is a checkout of {actual_owner}/{actual_repo}, not {owner}/{repo}; inspect or remove it and try again",
            repo_dir.display()
        );
    }
    Ok(repo_dir.to_path_buf())
}

/// Ensures a cached clone of `owner/repo` exists at `repo_dir`, cloning with
/// `gh repo clone` when absent and verifying existing checkouts without ever
/// deleting unrelated files.
pub fn ensure_managed_clone(repo_dir: &Path, owner: &str, repo: &str) -> Result<PathBuf> {
    ensure_managed_clone_with(repo_dir, owner, repo, |slug, destination| {
        let parent = destination
            .parent()
            .context("managed repo path has no parent")?;
        let destination_text = destination.to_string_lossy().into_owned();
        run("gh", &["repo", "clone", slug, &destination_text], parent).map(|_| ())
    })
}

fn create_staging_clone_dir(parent: &Path, repo: &str) -> PathBuf {
    let sequence = CLONE_STAGE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let pid = std::process::id();
    parent.join(format!(".{repo}.cloning-{pid}-{sequence}"))
}

/// Ensures a validated cached clone of `owner/repo` exists at `repo_dir` using
/// `clone_fn`, staging fresh clones in a sibling temporary directory so
/// failures or concurrent checkouts never remove an existing repository.
pub fn ensure_managed_clone_with(
    repo_dir: &Path,
    owner: &str,
    repo: &str,
    clone_fn: impl FnOnce(&str, &Path) -> Result<()>,
) -> Result<PathBuf> {
    validate_path_segment("owner", owner)?;
    validate_path_segment("repository", repo)?;
    if repo_dir.symlink_metadata().is_ok() {
        return verify_existing_clone(repo_dir, owner, repo);
    }
    let parent = repo_dir
        .parent()
        .context("managed repo path has no parent")?;
    fs::create_dir_all(parent)
        .with_context(|| format!("creating cache directory {}", parent.display()))?;
    let slug = format!("{owner}/{repo}");
    let staging_dir = create_staging_clone_dir(parent, repo);
    if let Err(error) = clone_fn(&slug, &staging_dir) {
        if staging_dir.symlink_metadata().is_ok() {
            let _ = fs::remove_dir_all(&staging_dir);
        }
        return Err(error.context(format!("cloning {slug} into {}", repo_dir.display())));
    }
    if let Err(rename_error) = fs::rename(&staging_dir, repo_dir) {
        if staging_dir.symlink_metadata().is_ok() {
            let _ = fs::remove_dir_all(&staging_dir);
        }
        if repo_dir.symlink_metadata().is_ok() {
            return verify_existing_clone(repo_dir, owner, repo);
        }
        return Err(anyhow::Error::new(rename_error)
            .context(format!("moving cloned {slug} into {}", repo_dir.display())));
    }
    Ok(repo_dir.to_path_buf())
}
