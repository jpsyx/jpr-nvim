//! Local worktree inspection, base-branch auto-detection, and git ref resolution.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

use crate::git_output::is_commit_id;
use crate::process::run_bytes_unlocked;

/// Resolved metadata for reviewing the current worktree without a PR.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalWorktreeInfo {
    /// Canonical root directory of the checked-out worktree.
    pub worktree: PathBuf,
    /// Checked-out branch name, or `detached-<short-sha>` on a detached HEAD.
    pub branch: String,
    /// Base branch or git ref being diffed against.
    pub base_ref: String,
    /// Full 40-character commit SHA resolved from `base_ref`.
    pub base_sha: String,
}

/// Probe interface for default base-branch resolution, faked in unit tests.
pub trait BranchProbe {
    /// Whether `reference` resolves to a valid commit in the repository.
    fn ref_exists(&self, reference: &str) -> bool;
    /// Short symbolic ref for `refs/remotes/origin/HEAD` (for example `origin/trunk`).
    fn symbolic_origin_head(&self) -> Option<String>;
}

struct GitBranchProbe<'a> {
    dir: &'a Path,
}

impl<'a> GitBranchProbe<'a> {
    const fn new(dir: &'a Path) -> Self {
        Self { dir }
    }
}

impl BranchProbe for GitBranchProbe<'_> {
    fn ref_exists(&self, reference: &str) -> bool {
        let target = format!("{reference}^{{commit}}");
        run_bytes_unlocked(
            "git",
            &["rev-parse", "--verify", "--quiet", &target],
            self.dir,
        )
        .is_ok()
    }

    fn symbolic_origin_head(&self) -> Option<String> {
        let bytes = run_bytes_unlocked(
            "git",
            &[
                "symbolic-ref",
                "--quiet",
                "--short",
                "refs/remotes/origin/HEAD",
            ],
            self.dir,
        )
        .ok()?;
        let trimmed = String::from_utf8_lossy(&bytes).trim().to_owned();
        (!trimmed.is_empty()).then_some(trimmed)
    }
}

/// Rejects unsafe or option-like git references before passing them to git.
pub fn validate_git_ref(reference: &str) -> Result<()> {
    if reference.is_empty() {
        bail!("base ref cannot be empty");
    }
    if reference.starts_with('-') {
        bail!("invalid git ref {reference:?}: cannot start with '-'");
    }
    if reference.bytes().any(|byte| byte <= 0x20 || byte == 0x7f) {
        bail!("invalid git ref {reference:?}: contains whitespace or control characters");
    }
    Ok(())
}

/// Resolves the default base branch (`develop` if present, else `main`, with
/// `origin/*`, `origin/HEAD`, and `master` fallbacks).
pub fn resolve_default_base_branch(probe: &impl BranchProbe) -> Result<String> {
    const CANDIDATES: [(&str, &str); 4] = [
        ("refs/heads/develop", "develop"),
        ("refs/remotes/origin/develop", "origin/develop"),
        ("refs/heads/main", "main"),
        ("refs/remotes/origin/main", "origin/main"),
    ];
    for (full_ref, short_name) in CANDIDATES {
        if probe.ref_exists(full_ref) {
            return Ok(short_name.to_owned());
        }
    }
    if let Some(origin_head) = probe.symbolic_origin_head()
        && probe.ref_exists(&origin_head)
    {
        return Ok(origin_head);
    }
    for (full_ref, short_name) in [
        ("refs/heads/master", "master"),
        ("refs/remotes/origin/master", "origin/master"),
    ] {
        if probe.ref_exists(full_ref) {
            return Ok(short_name.to_owned());
        }
    }
    bail!(
        "could not auto-detect a base branch (tried develop, main, origin/HEAD, master); pass --base <ref>"
    )
}

/// Resolves `reference` to a full commit SHA inside `dir` without taking index locks.
pub fn resolve_ref_commit(dir: &Path, reference: &str) -> Result<String> {
    validate_git_ref(reference)?;
    let target = format!("{reference}^{{commit}}");
    let bytes = run_bytes_unlocked("git", &["rev-parse", "--verify", "--quiet", &target], dir)
        .with_context(|| format!("could not resolve base ref {reference:?} to a commit"))?;
    let sha = String::from_utf8_lossy(&bytes).trim().to_owned();
    if !is_commit_id(&sha) {
        bail!("git returned an unexpected commit id {sha:?} for {reference:?}");
    }
    Ok(sha)
}

/// Returns the checked-out branch name in `dir`, or `detached-<short-sha>`.
pub fn read_current_branch(dir: &Path) -> Result<String> {
    let bytes = run_bytes_unlocked("git", &["branch", "--show-current"], dir)
        .context("reading the current git branch")?;
    let name = String::from_utf8_lossy(&bytes).trim().to_owned();
    if !name.is_empty() {
        return Ok(name);
    }
    let short_bytes = run_bytes_unlocked("git", &["rev-parse", "--short", "HEAD"], dir)
        .context("reading short HEAD commit for detached worktree")?;
    let short_sha = String::from_utf8_lossy(&short_bytes).trim().to_owned();
    if short_sha.is_empty() {
        bail!("detached HEAD has no commit yet");
    }
    Ok(format!("detached-{short_sha}"))
}

/// Inspects the worktree containing `dir`, resolving its root, current branch,
/// base ref (explicit or auto-detected), and base commit SHA.
pub fn inspect_local_worktree(
    dir: &Path,
    explicit_base: Option<&str>,
) -> Result<LocalWorktreeInfo> {
    let top_bytes = run_bytes_unlocked("git", &["rev-parse", "--show-toplevel"], dir)
        .context("finding the worktree's root (is this a git checkout?)")?;
    let worktree = PathBuf::from(
        String::from_utf8_lossy(&top_bytes)
            .trim_end_matches(['\n', '\r'])
            .to_owned(),
    );
    let branch = read_current_branch(&worktree)?;
    let base_ref = match explicit_base {
        Some(reference) => {
            validate_git_ref(reference)?;
            reference.to_owned()
        }
        None => resolve_default_base_branch(&GitBranchProbe::new(&worktree))?,
    };
    let base_sha = resolve_ref_commit(&worktree, &base_ref)?;
    Ok(LocalWorktreeInfo {
        worktree,
        branch,
        base_ref,
        base_sha,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{git, repo};
    use crate::workspace::GitWorkspace;
    use review_core::ports::Workspace;

    struct FakeProbe {
        refs: Vec<&'static str>,
        origin_head: Option<&'static str>,
    }

    impl BranchProbe for FakeProbe {
        fn ref_exists(&self, reference: &str) -> bool {
            self.refs.contains(&reference)
        }

        fn symbolic_origin_head(&self) -> Option<String> {
            self.origin_head.map(str::to_owned)
        }
    }

    #[test]
    fn default_base_prefers_develop_then_origin_develop_then_main_then_fallbacks() {
        let with_develop = FakeProbe {
            refs: vec!["refs/heads/develop", "refs/heads/main"],
            origin_head: None,
        };
        assert_eq!(
            resolve_default_base_branch(&with_develop).unwrap(),
            "develop"
        );

        let with_origin_develop = FakeProbe {
            refs: vec!["refs/remotes/origin/develop", "refs/heads/main"],
            origin_head: None,
        };
        assert_eq!(
            resolve_default_base_branch(&with_origin_develop).unwrap(),
            "origin/develop"
        );

        let with_main = FakeProbe {
            refs: vec!["refs/heads/main", "refs/heads/master"],
            origin_head: None,
        };
        assert_eq!(resolve_default_base_branch(&with_main).unwrap(), "main");

        let with_origin_main = FakeProbe {
            refs: vec!["refs/remotes/origin/main"],
            origin_head: None,
        };
        assert_eq!(
            resolve_default_base_branch(&with_origin_main).unwrap(),
            "origin/main"
        );

        let with_origin_head = FakeProbe {
            refs: vec!["origin/trunk", "refs/heads/master"],
            origin_head: Some("origin/trunk"),
        };
        assert_eq!(
            resolve_default_base_branch(&with_origin_head).unwrap(),
            "origin/trunk"
        );

        let with_master = FakeProbe {
            refs: vec!["refs/heads/master"],
            origin_head: None,
        };
        assert_eq!(resolve_default_base_branch(&with_master).unwrap(), "master");

        let empty = FakeProbe {
            refs: Vec::new(),
            origin_head: None,
        };
        let error = resolve_default_base_branch(&empty).unwrap_err();
        assert!(error.to_string().contains("--base"), "{error:#}");
    }

    #[test]
    fn validate_git_ref_rejects_empty_leading_dash_whitespace_and_control_bytes() {
        for bad in ["", "-x", "--all", "a b", "a\nb", "a\0b", "a\tb"] {
            assert!(validate_git_ref(bad).is_err(), "should reject {bad:?}");
        }
        for good in ["develop", "origin/main", "HEAD", "v1.0.0", "HEAD~2"] {
            assert!(validate_git_ref(good).is_ok(), "should accept {good:?}");
        }
    }

    #[test]
    fn inspect_local_worktree_auto_detects_branch_and_resolves_base_sha() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let main_info = inspect_local_worktree(&root, None).unwrap();
        assert_eq!(main_info.branch, "main");
        assert_eq!(main_info.base_ref, "main");
        assert!(is_commit_id(&main_info.base_sha));

        git(&root, &["checkout", "-q", "-b", "develop"]);
        git(&root, &["checkout", "-q", "-b", "feat/local"]);
        let develop_info = inspect_local_worktree(&root, None).unwrap();
        assert_eq!(develop_info.branch, "feat/local");
        assert_eq!(develop_info.base_ref, "develop");

        let head_override = inspect_local_worktree(&root, Some("HEAD")).unwrap();
        assert_eq!(head_override.base_ref, "HEAD");
        assert_eq!(head_override.base_sha, develop_info.base_sha);

        git(&root, &["checkout", "-q", "--detach", "HEAD"]);
        let detached = inspect_local_worktree(&root, None).unwrap();
        assert!(
            detached.branch.starts_with("detached-"),
            "{}",
            detached.branch
        );
    }

    #[test]
    fn git_workspace_resolve_ref_returns_full_commit_sha_and_rejects_flags() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let workspace = GitWorkspace::open(&root).unwrap();
        let head_sha = workspace.resolve_ref("HEAD").unwrap();
        assert_eq!(head_sha, workspace.head_commit().unwrap());
        assert!(workspace.resolve_ref("--verify").is_err());
    }
}
