//! `jpr-review local`: inspect the current worktree for local review or active
//! PR auto-detection, printing structured JSON to stdout.

use std::env;

use anyhow::{Context, Result};
use review_core::ports::Forge;
use review_forge_github::GhForge;
use review_model::PullRequest;
use review_workspace_git::{LocalWorktreeInfo, inspect_local_worktree};
use serde_json::{Value, json};

use crate::theme::Theme;

/// Output emitted by `jpr-review local`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LocalCommandOutput {
    /// Current branch already has an open PR on GitHub; attach in-place.
    Pr {
        /// Canonical root directory of the current git worktree.
        worktree: String,
        /// `owner/name` repository of the open pull request.
        repo: String,
        /// Pull request number.
        number: u64,
        /// Pull request title.
        title: String,
    },
    /// Open an unlinked local worktree review against `base_ref`.
    Local {
        /// Canonical root directory of the current git worktree.
        worktree: String,
        /// Checked-out branch name (or `detached-<short-sha>`).
        branch: String,
        /// Base git ref being diffed against.
        base_ref: String,
        /// Resolved full commit SHA of `base_ref`.
        base_sha: String,
        /// Inferred or explicit `owner/name` repository, if any.
        repo: Option<String>,
    },
}

impl LocalCommandOutput {
    /// Encodes the command output as wire JSON.
    #[must_use]
    pub fn to_json_value(&self) -> Value {
        match self {
            Self::Pr {
                worktree,
                repo,
                number,
                title,
            } => json!({
                "mode": "pr",
                "worktree": worktree,
                "repo": repo,
                "number": number,
                "title": title,
            }),
            Self::Local {
                worktree,
                branch,
                base_ref,
                base_sha,
                repo,
            } => {
                let mut map = serde_json::Map::new();
                map.insert("mode".into(), json!("local"));
                map.insert("worktree".into(), json!(worktree));
                map.insert("branch".into(), json!(branch));
                map.insert("baseRef".into(), json!(base_ref));
                map.insert("baseSha".into(), json!(base_sha));
                if let Some(repo_name) = repo {
                    map.insert("repo".into(), json!(repo_name));
                }
                Value::Object(map)
            }
        }
    }
}

/// Runs `jpr-review local`, inspecting the current worktree and probing GitHub
/// for an open PR unless `--base` or `--no-pr` was supplied.
pub fn run(base: Option<&str>, repo: Option<&str>, no_pr: bool, theme: Theme) -> Result<()> {
    if let Some(explicit_repo) = repo {
        let _ = super::parse_repo(explicit_repo)?;
    }
    let cwd = env::current_dir().context("reading the current directory")?;
    let info = inspect_local_worktree(&cwd, base)?;
    let inferred_repo = super::socket_client::infer_repo_from_git_remote(&info.worktree);
    // Pass ONLY explicit `--repo` to `GhForge` (never `origin`-inferred repo)
    // so forks resolve upstream PRs and non-GitHub remotes report `Ok(None)`.
    let forge = GhForge::new(info.worktree.clone(), repo.map(str::to_owned));
    let output = resolve_local_output(
        &info,
        base,
        repo,
        inferred_repo.as_deref(),
        no_pr,
        || forge.current_branch_pr(),
        |warning| super::narrate(theme, warning),
    )?;
    println!("{}", serde_json::to_string(&output.to_json_value())?);
    Ok(())
}

/// Decides between attaching to an open PR or staying in local mode.
pub fn resolve_local_output(
    info: &LocalWorktreeInfo,
    base_override: Option<&str>,
    explicit_repo: Option<&str>,
    inferred_repo: Option<&str>,
    no_pr: bool,
    probe_pr: impl FnOnce() -> Result<Option<PullRequest>>,
    warn: impl FnOnce(&str),
) -> Result<LocalCommandOutput> {
    let worktree = info.worktree.to_string_lossy().into_owned();
    if base_override.is_none() && !no_pr {
        match probe_pr() {
            Ok(Some(pr)) => {
                return Ok(LocalCommandOutput::Pr {
                    worktree,
                    repo: format!("{}/{}", pr.owner, pr.repo),
                    number: pr.number,
                    title: pr.title,
                });
            }
            Ok(None) => {}
            Err(error) if review_core::is_auth_error(&error) => return Err(error),
            Err(error) => {
                warn(&format!(
                    "could not check for an open PR ({error:#}); continuing in local mode"
                ));
            }
        }
    }
    Ok(LocalCommandOutput::Local {
        worktree,
        branch: info.branch.clone(),
        base_ref: info.base_ref.clone(),
        base_sha: info.base_sha.clone(),
        repo: explicit_repo.or(inferred_repo).map(str::to_owned),
    })
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, Ordering};

    use anyhow::anyhow;
    use review_core::fakes::sample_pr;

    use super::*;

    fn sample_info() -> LocalWorktreeInfo {
        LocalWorktreeInfo {
            worktree: PathBuf::from("/tmp/wt"),
            branch: "fix/widget".into(),
            base_ref: "develop".into(),
            base_sha: "base123".into(),
        }
    }

    #[test]
    fn explicit_base_bypasses_pr_detection_even_when_open_pr_exists() {
        let probed = AtomicBool::new(false);
        let mut info = sample_info();
        info.base_ref = "HEAD".into();
        let output = resolve_local_output(
            &info,
            Some("HEAD"),
            None,
            Some("fork-user/widgets"),
            false,
            || {
                probed.store(true, Ordering::SeqCst);
                Ok(Some(sample_pr()))
            },
            |_| panic!("unexpected warning"),
        )
        .unwrap();
        assert!(!probed.load(Ordering::SeqCst));
        assert_eq!(
            output,
            LocalCommandOutput::Local {
                worktree: "/tmp/wt".into(),
                branch: "fix/widget".into(),
                base_ref: "HEAD".into(),
                base_sha: "base123".into(),
                repo: Some("fork-user/widgets".into()),
            }
        );
        assert_eq!(output.to_json_value()["baseRef"], json!("HEAD"));
    }

    #[test]
    fn bare_local_attaches_to_open_pr_when_detected() {
        let output = resolve_local_output(
            &sample_info(),
            None,
            None,
            Some("fork-user/widgets"),
            false,
            || Ok(Some(sample_pr())),
            |_| panic!("unexpected warning"),
        )
        .unwrap();
        assert_eq!(
            output,
            LocalCommandOutput::Pr {
                worktree: "/tmp/wt".into(),
                repo: "octo/widgets".into(),
                number: 7,
                title: "Fix the widget".into(),
            }
        );
        assert_eq!(output.to_json_value()["mode"], json!("pr"));
    }

    #[test]
    fn bare_local_falls_back_to_local_with_warning_on_probe_error() {
        let warned = AtomicBool::new(false);
        let output = resolve_local_output(
            &sample_info(),
            None,
            None,
            None,
            false,
            || Err(anyhow!("offline")),
            |message| {
                assert!(message.contains("offline"));
                warned.store(true, Ordering::SeqCst);
            },
        )
        .unwrap();
        assert!(warned.load(Ordering::SeqCst));
        assert!(matches!(output, LocalCommandOutput::Local { .. }));
    }

    #[test]
    fn bare_local_propagates_auth_error_instead_of_falling_back_to_local_mode() {
        let error = resolve_local_output(
            &sample_info(),
            None,
            None,
            None,
            false,
            || {
                Err(anyhow::Error::new(review_core::ForgeAuthError::new(
                    "gh auth login",
                )))
            },
            |_| panic!("must not warn and fall back on auth error"),
        )
        .unwrap_err();
        assert!(review_core::is_auth_error(&error));
    }
}
