//! Unlocked git `HEAD` and worktree dirty/divergence inspection.

use std::collections::BTreeSet;
use std::path::Path;

use anyhow::{Context, Result, bail};
use review_core::ports::WorktreeStatus;

use crate::git_output::{is_commit_id, parse_porcelain_z_paths};
use crate::process::run_bytes_unlocked;
use crate::worktree_path::path_to_safe_relative;

/// Reads the full commit SHA of `HEAD` without acquiring `.git/index.lock`.
pub fn read_head_commit(dir: &Path) -> Result<String> {
    let stdout =
        run_bytes_unlocked("git", &["rev-parse", "HEAD"], dir).context("reading HEAD commit")?;
    let head_sha = String::from_utf8_lossy(&stdout).trim().to_owned();
    if !is_commit_id(&head_sha) {
        bail!("git rev-parse HEAD returned unexpected commit id {head_sha:?}");
    }
    Ok(head_sha)
}

/// Reads dirty/untracked paths and ahead/behind counts relative to `remote_head_sha`.
pub fn read_worktree_status(dir: &Path, remote_head_sha: Option<&str>) -> Result<WorktreeStatus> {
    let status_output = run_bytes_unlocked(
        "git",
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        dir,
    )
    .context("reading worktree status")?;
    let raw_paths = parse_porcelain_z_paths(&status_output);
    let has_dirty_entries = !raw_paths.is_empty() || !status_output.is_empty();
    let modified_paths: Vec<String> = raw_paths
        .into_iter()
        .filter(|path| path_to_safe_relative(path).is_ok())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let (behind, ahead) = read_behind_ahead_counts(dir, remote_head_sha);
    Ok(WorktreeStatus {
        is_dirty: has_dirty_entries,
        ahead,
        behind,
        modified_paths,
    })
}

fn read_behind_ahead_counts(dir: &Path, remote_head_sha: Option<&str>) -> (usize, usize) {
    if let Some(sha) = remote_head_sha.filter(|sha| is_commit_id(sha)) {
        let commit_object = format!("{sha}^{{commit}}");
        if run_bytes_unlocked("git", &["cat-file", "-e", &commit_object], dir).is_ok() {
            let range = format!("{sha}...HEAD");
            if let Some(counts) = read_rev_list_counts(dir, &range) {
                return counts;
            }
        }
    }
    read_rev_list_counts(dir, "@{upstream}...HEAD").unwrap_or((0, 0))
}

fn read_rev_list_counts(dir: &Path, range: &str) -> Option<(usize, usize)> {
    let output =
        run_bytes_unlocked("git", &["rev-list", "--left-right", "--count", range], dir).ok()?;
    parse_left_right_counts(&output)
}

fn parse_left_right_counts(bytes: &[u8]) -> Option<(usize, usize)> {
    let text = std::str::from_utf8(bytes).ok()?;
    let mut fields = text.split_whitespace();
    let behind = fields.next()?.parse().ok()?;
    let ahead = fields.next()?.parse().ok()?;
    if fields.next().is_some() {
        return None;
    }
    Some((behind, ahead))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, SystemTime};

    use review_core::ports::{Workspace, WorktreeStatus};

    use super::*;
    use crate::GitWorkspace;
    use crate::process::run;
    use crate::test_support::{git, repo};

    fn commit_file(root: &Path, relative_path: &str, content: &str) -> String {
        let full_path = root.join(relative_path);
        if let Some(parent) = full_path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(full_path, content).unwrap();
        git(root, &["add", "."]);
        git(root, &["commit", "-q", "-m", relative_path]);
        run("git", &["rev-parse", "HEAD"], root)
            .unwrap()
            .trim()
            .to_owned()
    }

    fn create_worktree_with_origin() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let dir = repo();
        let root = dir.path().join("widgets");
        let origin = dir.path().join("origin.git");
        git(
            dir.path(),
            &["init", "--bare", "-q", "-b", "main", "origin.git"],
        );
        git(
            &root,
            &["remote", "add", "origin", origin.to_str().unwrap()],
        );
        git(&root, &["push", "-q", "-u", "origin", "main"]);
        (dir, root, origin)
    }

    #[test]
    fn head_commit_returns_forty_hex_sha_without_taking_index_lock() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let an_hour_ago = SystemTime::now() - Duration::from_secs(3600);
        let file = fs::File::options()
            .write(true)
            .open(root.join("a.txt"))
            .unwrap();
        file.set_modified(an_hour_ago).unwrap();
        let index_before = fs::read(root.join(".git/index")).unwrap();

        let head_sha = GitWorkspace::new(root.clone()).head_commit().unwrap();

        assert_eq!(head_sha.len(), 40);
        assert!(is_commit_id(&head_sha));
        assert_eq!(fs::read(root.join(".git/index")).unwrap(), index_before);
        assert!(!root.join(".git/index.lock").exists());
    }

    #[test]
    fn clean_checkout_at_remote_head_reports_clean_zero_divergence() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let head_sha = read_head_commit(&root).unwrap();

        let status = GitWorkspace::new(root)
            .worktree_status(Some(&head_sha))
            .unwrap();

        assert_eq!(
            status,
            WorktreeStatus {
                is_dirty: false,
                ahead: 0,
                behind: 0,
                modified_paths: Vec::new(),
            }
        );
    }

    #[test]
    fn modified_tracked_and_untracked_files_report_dirty_and_sorted_paths() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let head_sha = read_head_commit(&root).unwrap();
        fs::write(root.join("a.txt"), "edited\n").unwrap();
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(root.join("src/z.rs"), "pub fn z() {}\n").unwrap();
        fs::write(root.join("b.txt"), "new\n").unwrap();

        let status = GitWorkspace::new(root.clone())
            .worktree_status(Some(&head_sha))
            .unwrap();

        assert_eq!(
            status,
            WorktreeStatus {
                is_dirty: true,
                ahead: 0,
                behind: 0,
                modified_paths: vec!["a.txt".into(), "b.txt".into(), "src/z.rs".into()],
            }
        );
        assert!(!root.join(".git/index.lock").exists());
    }

    #[test]
    fn local_commit_reports_ahead_and_fetched_origin_commit_reports_behind() {
        let (dir, root, origin) = create_worktree_with_origin();
        let initial_sha = read_head_commit(&root).unwrap();
        let _local_sha = commit_file(&root, "local.txt", "local\n");
        let workspace = GitWorkspace::new(root.clone());

        let ahead_status = workspace.worktree_status(Some(&initial_sha)).unwrap();
        assert_eq!((ahead_status.ahead, ahead_status.behind), (1, 0));
        assert!(!ahead_status.is_dirty);

        let peer = dir.path().join("peer");
        git(
            dir.path(),
            &["clone", "-q", origin.to_str().unwrap(), "peer"],
        );
        let remote_sha = commit_file(&peer, "remote.txt", "remote\n");
        git(&peer, &["push", "-q", "origin", "main"]);
        git(&root, &["reset", "--hard", "-q", &initial_sha]);
        git(&root, &["fetch", "-q", "origin", "main"]);

        let behind_status = workspace.worktree_status(Some(&remote_sha)).unwrap();
        assert_eq!((behind_status.ahead, behind_status.behind), (0, 1));
        let upstream_fallback = workspace.worktree_status(None).unwrap();
        assert_eq!((upstream_fallback.ahead, upstream_fallback.behind), (0, 1));
    }

    #[test]
    fn parses_left_right_counts_and_rejects_malformed_output() {
        assert_eq!(parse_left_right_counts(b"2\t5\n"), Some((2, 5)));
        assert_eq!(parse_left_right_counts(b"0 0\r\n"), Some((0, 0)));
        assert_eq!(parse_left_right_counts(b"1\n"), None);
        assert_eq!(parse_left_right_counts(b"1 2 3\n"), None);
        assert_eq!(parse_left_right_counts(b"x 2\n"), None);
    }
}
