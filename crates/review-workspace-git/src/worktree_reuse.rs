//! Discovery of an existing git worktree already checked out on a pull request's
//! branch so reopening a review skips `gh pr checkout` and custom worktree commands.

use std::path::{Path, PathBuf};

use crate::process::run;
use crate::repo::main_repo_root;

/// One non-bare worktree entry parsed from `git worktree list --porcelain`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorktreeEntry {
    /// Absolute filesystem path to the worktree root.
    pub path: PathBuf,
    /// Checked-out local branch name (without `refs/heads/`), or `None` when detached.
    pub branch: Option<String>,
    /// Whether this entry is a bare repository rather than a checkout.
    pub is_bare: bool,
}

/// Parses `git worktree list --porcelain` output into [`WorktreeEntry`] records.
#[must_use]
pub fn parse_worktree_list_porcelain(stdout: &str) -> Vec<WorktreeEntry> {
    let mut entries = Vec::new();
    let mut current: Option<WorktreeEntry> = None;

    for raw_line in stdout.lines() {
        let line = raw_line.trim_end_matches('\r');
        if line.is_empty() {
            if let Some(entry) = current.take() {
                entries.push(entry);
            }
            continue;
        }
        if let Some(path) = line.strip_prefix("worktree ") {
            if let Some(entry) = current.take() {
                entries.push(entry);
            }
            current = Some(WorktreeEntry {
                path: PathBuf::from(path),
                branch: None,
                is_bare: false,
            });
        } else if let Some(entry) = current.as_mut() {
            if let Some(branch_ref) = line.strip_prefix("branch ") {
                entry.branch = branch_ref.strip_prefix("refs/heads/").map(str::to_owned);
            } else if line == "bare" {
                entry.is_bare = true;
            }
        }
    }
    if let Some(entry) = current {
        entries.push(entry);
    }
    entries
}

/// Picks the best existing worktree matching pull request `number` (and, for
/// same-repository pull requests, `head_ref`), preferring `preferred_worktree`
/// when it still matches.
#[must_use]
pub fn select_reusable_worktree(
    entries: &[WorktreeEntry],
    number: u64,
    head_ref: Option<&str>,
    is_cross_repository: bool,
    preferred_worktree: Option<&Path>,
) -> Option<PathBuf> {
    let pr_branch_name = format!("pr-{number}");
    let matches_branch = |entry: &WorktreeEntry| -> bool {
        if entry.is_bare {
            return false;
        }
        let Some(branch) = entry.branch.as_deref() else {
            return false;
        };
        if branch == pr_branch_name {
            return true;
        }
        !is_cross_repository && head_ref.is_some_and(|expected| branch == expected)
    };

    if let Some(preferred) = preferred_worktree
        && let Some(entry) = entries
            .iter()
            .find(|entry| matches_branch(entry) && paths_equal(&entry.path, preferred))
    {
        return Some(entry.path.clone());
    }
    if let Some(entry) = entries
        .iter()
        .find(|entry| !entry.is_bare && entry.branch.as_deref() == Some(pr_branch_name.as_str()))
    {
        return Some(entry.path.clone());
    }
    entries
        .iter()
        .find(|entry| matches_branch(entry))
        .map(|entry| entry.path.clone())
}

/// Finds an existing worktree already checked out on pull request `number`'s branch.
///
/// Prefers `preferred_worktree` (from `session.json`) when it still points to a matching worktree.
#[must_use]
pub fn find_existing_pr_worktree(
    dir: &Path,
    number: u64,
    head_ref: Option<&str>,
    is_cross_repository: bool,
    preferred_worktree: Option<&Path>,
) -> Option<PathBuf> {
    let main = main_repo_root(dir).ok()?;
    let stdout = run("git", &["worktree", "list", "--porcelain"], &main).ok()?;
    let entries: Vec<WorktreeEntry> = parse_worktree_list_porcelain(&stdout)
        .into_iter()
        .filter(|entry| entry.path.exists())
        .collect();
    select_reusable_worktree(
        &entries,
        number,
        head_ref,
        is_cross_repository,
        preferred_worktree,
    )
}

fn paths_equal(left: &Path, right: &Path) -> bool {
    if left == right {
        return true;
    }
    matches!(
        (left.canonicalize(), right.canonicalize()),
        (Ok(left), Ok(right)) if left == right
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{git, repo};

    #[test]
    fn parses_porcelain_worktree_entries_including_bare_and_detached() {
        let porcelain = "\
worktree /src/app
HEAD 1111111
branch refs/heads/main

worktree /src/wt/feat-auth
HEAD 2222222
branch refs/heads/feat/auth

worktree /src/wt/detached
HEAD 3333333
detached

worktree /src/bare.git
bare
";
        let entries = parse_worktree_list_porcelain(porcelain);
        assert_eq!(entries.len(), 4);
        assert_eq!(entries[0].branch.as_deref(), Some("main"));
        assert_eq!(entries[1].branch.as_deref(), Some("feat/auth"));
        assert_eq!(entries[2].branch, None);
        assert!(entries[3].is_bare);
    }

    #[test]
    fn selects_preferred_then_pr_branch_then_same_repo_head_ref_and_skips_cross_repo_head_ref() {
        let entries = vec![
            WorktreeEntry {
                path: PathBuf::from("/wt/main"),
                branch: Some("main".into()),
                is_bare: false,
            },
            WorktreeEntry {
                path: PathBuf::from("/wt/feat-auth"),
                branch: Some("feat/auth".into()),
                is_bare: false,
            },
            WorktreeEntry {
                path: PathBuf::from("/wt/pr-7"),
                branch: Some("pr-7".into()),
                is_bare: false,
            },
        ];

        assert_eq!(
            select_reusable_worktree(
                &entries,
                7,
                Some("feat/auth"),
                false,
                Some(Path::new("/wt/feat-auth")),
            ),
            Some(PathBuf::from("/wt/feat-auth"))
        );
        assert_eq!(
            select_reusable_worktree(&entries, 7, Some("feat/auth"), false, None),
            Some(PathBuf::from("/wt/pr-7"))
        );
        assert_eq!(
            select_reusable_worktree(&entries, 99, Some("feat/auth"), false, None),
            Some(PathBuf::from("/wt/feat-auth"))
        );
        // Cross-repository fork PR must not blindly reuse a local branch by head_ref alone.
        assert_eq!(
            select_reusable_worktree(&entries, 99, Some("feat/auth"), true, None),
            None
        );
    }

    #[test]
    fn find_existing_pr_worktree_discovers_checked_out_head_ref_worktree() {
        let dir = repo();
        let main = dir.path().join("widgets");
        let wt_path = dir.path().join("wt-feature");
        git(
            &main,
            &[
                "worktree",
                "add",
                "-q",
                "-b",
                "feat/reuse-me",
                wt_path.to_str().unwrap(),
            ],
        );

        let found = find_existing_pr_worktree(&main, 42, Some("feat/reuse-me"), false, None)
            .expect("should find existing worktree");
        assert!(paths_equal(&found, &wt_path));
    }
}
