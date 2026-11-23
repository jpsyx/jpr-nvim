//! Real-git tests for `Workspace::fast_forward_to`.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use review_core::ports::{FastForwardOutcome, Workspace};

use crate::GitWorkspace;
use crate::process::run;
use crate::status::read_head_commit;
use crate::test_support::{git, repo};

fn create_origin_and_worktree() -> (tempfile::TempDir, PathBuf, PathBuf) {
    let temp_dir = repo();
    let worktree_dir = temp_dir.path().join("widgets");
    let origin_dir = temp_dir.path().join("origin.git");
    git(
        temp_dir.path(),
        &["init", "--bare", "-q", "-b", "main", "origin.git"],
    );
    git(
        &worktree_dir,
        &["remote", "add", "origin", origin_dir.to_str().unwrap()],
    );
    git(&worktree_dir, &["push", "-q", "-u", "origin", "main"]);
    (temp_dir, worktree_dir, origin_dir)
}

fn create_peer_clone(temp_root: &Path, origin_dir: &Path) -> PathBuf {
    let peer_dir = temp_root.join("peer");
    git(
        temp_root,
        &["clone", "-q", origin_dir.to_str().unwrap(), "peer"],
    );
    peer_dir
}

fn commit_file_change(repo_dir: &Path, relative_path: &str, content: &str) -> String {
    let full_path = repo_dir.join(relative_path);
    if let Some(parent_dir) = full_path.parent() {
        fs::create_dir_all(parent_dir).unwrap();
    }
    fs::write(full_path, content).unwrap();
    git(repo_dir, &["add", "."]);
    git(repo_dir, &["commit", "-q", "-m", relative_path]);
    read_head_commit(repo_dir).unwrap()
}

fn assert_file_text(repo_dir: &Path, relative_path: &str, expected: &str) {
    assert_eq!(
        fs::read_to_string(repo_dir.join(relative_path)).unwrap(),
        expected
    );
}

fn has_stash_ref(repo_dir: &Path) -> bool {
    run("git", &["rev-parse", "--verify", "refs/stash"], repo_dir).is_ok()
}

fn read_stash_sha(repo_dir: &Path) -> String {
    run("git", &["rev-parse", "refs/stash"], repo_dir)
        .unwrap()
        .trim()
        .to_owned()
}

fn create_detached_worktree(repo_dir: &Path, name: &str) -> PathBuf {
    let linked_dir = repo_dir.parent().unwrap().join(name);
    git(
        repo_dir,
        &[
            "worktree",
            "add",
            "-q",
            "--detach",
            linked_dir.to_str().unwrap(),
        ],
    );
    linked_dir
}

fn read_git_state_path(worktree_dir: &Path, state_name: &str) -> PathBuf {
    let output = run(
        "git",
        &["rev-parse", "--git-path", state_name],
        worktree_dir,
    )
    .unwrap();
    worktree_dir.join(output.lines().next().unwrap())
}

#[test]
fn already_at_target_is_a_noop() {
    let (_temp_dir, worktree_dir, _origin_dir) = create_origin_and_worktree();
    let initial_sha = read_head_commit(&worktree_dir).unwrap();

    let outcome = GitWorkspace::new(worktree_dir.clone())
        .fast_forward_to(&initial_sha)
        .unwrap();

    assert_eq!(
        outcome,
        FastForwardOutcome::AlreadyAtTarget {
            head_sha: initial_sha.clone(),
        }
    );
    assert_eq!(read_head_commit(&worktree_dir).unwrap(), initial_sha);
}

#[test]
fn clean_worktree_fast_forwards_fetching_missing_commit_from_origin() {
    let (temp_dir, worktree_dir, origin_dir) = create_origin_and_worktree();
    let initial_sha = read_head_commit(&worktree_dir).unwrap();
    let peer_dir = create_peer_clone(temp_dir.path(), &origin_dir);
    fs::write(peer_dir.join("a.txt"), "updated a\n").unwrap();
    let target_sha = commit_file_change(&peer_dir, "b.txt", "new from origin\n");
    git(&peer_dir, &["push", "-q", "origin", "main"]);
    let target_commit_object = format!("{target_sha}^{{commit}}");
    assert!(
        run(
            "git",
            &["cat-file", "-e", &target_commit_object],
            &worktree_dir
        )
        .is_err()
    );

    let outcome = GitWorkspace::new(worktree_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap();

    assert_eq!(
        outcome,
        FastForwardOutcome::FastForwarded {
            previous_sha: initial_sha,
            head_sha: target_sha.clone(),
        }
    );
    assert_eq!(read_head_commit(&worktree_dir).unwrap(), target_sha);
    assert_file_text(&worktree_dir, "a.txt", "updated a\n");
    assert_file_text(&worktree_dir, "b.txt", "new from origin\n");
}

fn run_isolated_without_git_identity(test_name: &str) {
    let output = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", test_name, "--quiet"])
        .env("JPR_TEST_ISOLATED_GIT_CONFIG", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env_remove("GIT_AUTHOR_NAME")
        .env_remove("GIT_AUTHOR_EMAIL")
        .env_remove("GIT_COMMITTER_NAME")
        .env_remove("GIT_COMMITTER_EMAIL")
        .env_remove("EMAIL")
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "{stdout}\n{stderr}");
    assert!(stdout.contains(" 1 passed;"), "{stdout}");
}

#[test]
fn dirty_worktree_stashes_tracked_and_untracked_fast_forwards_and_restores() {
    if std::env::var_os("JPR_TEST_ISOLATED_GIT_CONFIG").is_none() {
        run_isolated_without_git_identity(
            "fast_forward::tests::dirty_worktree_stashes_tracked_and_untracked_fast_forwards_and_restores",
        );
        return;
    }
    let (temp_dir, worktree_dir, origin_dir) = create_origin_and_worktree();
    let initial_sha = commit_file_change(&worktree_dir, "tracked.txt", "before\n");
    git(&worktree_dir, &["push", "-q", "origin", "main"]);
    git(&worktree_dir, &["config", "user.useConfigOnly", "true"]);
    let peer_dir = create_peer_clone(temp_dir.path(), &origin_dir);
    let target_sha = commit_file_change(&peer_dir, "a.txt", "upstream edit\n");
    git(&peer_dir, &["push", "-q", "origin", "main"]);
    fs::write(worktree_dir.join("tracked.txt"), "local tracked edit\n").unwrap();
    fs::write(worktree_dir.join("untracked.txt"), "local untracked\n").unwrap();

    let outcome = GitWorkspace::new(worktree_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap();

    assert_eq!(
        outcome,
        FastForwardOutcome::FastForwarded {
            previous_sha: initial_sha,
            head_sha: target_sha.clone(),
        }
    );
    assert_eq!(read_head_commit(&worktree_dir).unwrap(), target_sha);
    assert_file_text(&worktree_dir, "a.txt", "upstream edit\n");
    assert_file_text(&worktree_dir, "tracked.txt", "local tracked edit\n");
    assert_file_text(&worktree_dir, "untracked.txt", "local untracked\n");
    assert!(!has_stash_ref(&worktree_dir));
}

#[test]
fn conflicting_stash_restore_keeps_conflict_markers_and_stash_entry_and_lists_paths() {
    let (temp_dir, worktree_dir, origin_dir) = create_origin_and_worktree();
    let initial_sha = read_head_commit(&worktree_dir).unwrap();
    let peer_dir = create_peer_clone(temp_dir.path(), &origin_dir);
    let target_sha = commit_file_change(&peer_dir, "a.txt", "remote conflicting line\n");
    git(&peer_dir, &["push", "-q", "origin", "main"]);
    fs::write(worktree_dir.join("a.txt"), "local conflicting line\n").unwrap();

    let outcome = GitWorkspace::new(worktree_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap();

    assert_eq!(
        outcome,
        FastForwardOutcome::RestoreConflict {
            previous_sha: initial_sha,
            head_sha: target_sha.clone(),
            conflicted_paths: vec!["a.txt".to_owned()],
        }
    );
    assert_eq!(read_head_commit(&worktree_dir).unwrap(), target_sha);
    let disk_content = fs::read_to_string(worktree_dir.join("a.txt")).unwrap();
    assert!(disk_content.contains("<<<<<<<"), "{disk_content}");
    assert!(has_stash_ref(&worktree_dir));
}

#[test]
fn local_commits_ahead_of_target_are_never_rewound() {
    let (_temp_dir, worktree_dir, _origin_dir) = create_origin_and_worktree();
    let target_sha = read_head_commit(&worktree_dir).unwrap();
    let local_sha = commit_file_change(&worktree_dir, "local.txt", "ahead\n");

    let outcome = GitWorkspace::new(worktree_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap();

    assert_eq!(
        outcome,
        FastForwardOutcome::AheadOfTarget {
            head_sha: local_sha.clone(),
            target_sha,
        }
    );
    assert_eq!(read_head_commit(&worktree_dir).unwrap(), local_sha);
}

#[test]
fn diverged_force_pushed_target_leaves_head_and_dirty_files_untouched() {
    let (temp_dir, worktree_dir, origin_dir) = create_origin_and_worktree();
    let peer_dir = create_peer_clone(temp_dir.path(), &origin_dir);
    let origin_sha = commit_file_change(&peer_dir, "remote.txt", "remote branch\n");
    git(&peer_dir, &["push", "-q", "--force", "origin", "main"]);
    let local_sha = commit_file_change(&worktree_dir, "local.txt", "local branch\n");
    fs::write(worktree_dir.join("a.txt"), "dirty tracked\n").unwrap();
    fs::write(worktree_dir.join("scratch.txt"), "dirty untracked\n").unwrap();

    let outcome = GitWorkspace::new(worktree_dir.clone())
        .fast_forward_to(&origin_sha)
        .unwrap();

    assert_eq!(
        outcome,
        FastForwardOutcome::Diverged {
            head_sha: local_sha.clone(),
            target_sha: origin_sha,
        }
    );
    assert_eq!(read_head_commit(&worktree_dir).unwrap(), local_sha);
    assert_file_text(&worktree_dir, "a.txt", "dirty tracked\n");
    assert_file_text(&worktree_dir, "scratch.txt", "dirty untracked\n");
    assert!(!has_stash_ref(&worktree_dir));
}

#[test]
fn rejects_invalid_commit_ids() {
    let non_repo_dir = tempfile::tempdir().unwrap();
    let workspace = GitWorkspace::new(non_repo_dir.path().to_path_buf());
    let non_hex_sha = "g".repeat(40);
    let invalid_ids = ["", "-q", "--help", "main", "abc123", non_hex_sha.as_str()];

    for invalid_id in invalid_ids {
        let error = workspace.fast_forward_to(invalid_id).unwrap_err();
        let message = format!("{error:#}");
        assert!(
            message.contains("is not a commit id"),
            "unexpected error for {invalid_id:?}: {message}"
        );
    }
}

#[test]
fn mixed_untracked_stash_reports_only_colliding_paths_and_preserves_stash() {
    let (temp_dir, worktree_dir, origin_dir) = create_origin_and_worktree();
    let initial_sha = read_head_commit(&worktree_dir).unwrap();
    let peer_dir = create_peer_clone(temp_dir.path(), &origin_dir);
    let target_sha = commit_file_change(&peer_dir, "collided.txt", "remote tracked\n");
    git(&peer_dir, &["push", "-q", "origin", "main"]);
    fs::write(worktree_dir.join("collided.txt"), "local untracked\n").unwrap();
    fs::write(worktree_dir.join("scratch.txt"), "unrelated local note\n").unwrap();

    let outcome = GitWorkspace::new(worktree_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap();

    assert_eq!(
        outcome,
        FastForwardOutcome::RestoreConflict {
            previous_sha: initial_sha,
            head_sha: target_sha.clone(),
            conflicted_paths: vec!["collided.txt".to_owned()],
        }
    );
    assert_eq!(read_head_commit(&worktree_dir).unwrap(), target_sha);
    assert!(has_stash_ref(&worktree_dir));
}

mod edge_cases;
