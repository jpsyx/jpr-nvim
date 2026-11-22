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

fn resolve_git_state_path(worktree_dir: &Path, state_name: &str) -> PathBuf {
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

#[cfg(unix)]
fn write_executable_hook(worktree_dir: &Path, hook_name: &str, script: &str) {
    use std::os::unix::fs::PermissionsExt;

    let hooks_dir = worktree_dir.join(".git/hooks");
    fs::create_dir_all(&hooks_dir).unwrap();
    let hook_path = hooks_dir.join(hook_name);
    fs::write(&hook_path, script).unwrap();
    fs::set_permissions(&hook_path, fs::Permissions::from_mode(0o755)).unwrap();
}

#[cfg(unix)]
#[test]
fn non_conflict_stash_pop_failure_returns_error_naming_head_and_stash() {
    let (temp_dir, worktree_dir, origin_dir) = create_origin_and_worktree();
    let _initial_sha = commit_file_change(&worktree_dir, "tracked.txt", "before\n");
    git(&worktree_dir, &["push", "-q", "origin", "main"]);
    let peer_dir = create_peer_clone(temp_dir.path(), &origin_dir);
    let target_sha = commit_file_change(&peer_dir, "a.txt", "upstream\n");
    git(&peer_dir, &["push", "-q", "origin", "main"]);
    fs::write(worktree_dir.join("tracked.txt"), "local dirty\n").unwrap();
    write_executable_hook(
        &worktree_dir,
        "post-merge",
        "#!/bin/sh\n: > \"$(git rev-parse --git-dir)/index.lock\"\n",
    );

    let error = GitWorkspace::new(worktree_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap_err();

    let stash_sha = read_stash_sha(&worktree_dir);
    let message = format!("{error:#}");
    assert_eq!(read_head_commit(&worktree_dir).unwrap(), target_sha);
    assert!(message.contains("git stash apply failed"), "{message}");
    assert!(message.contains("HEAD"), "{message}");
    assert!(message.contains(&target_sha), "{message}");
    assert!(message.contains("stash"), "{message}");
    assert!(message.contains(&stash_sha), "{message}");
}

#[cfg(unix)]
#[test]
fn concurrent_shared_stash_push_applies_pinned_stash_without_dropping_other_stash() {
    let (temp_dir, worktree_dir, origin_dir) = create_origin_and_worktree();
    let initial_sha = commit_file_change(&worktree_dir, "tracked.txt", "before\n");
    git(&worktree_dir, &["push", "-q", "origin", "main"]);
    let linked_dir = create_detached_worktree(&worktree_dir, "linked");
    fs::write(linked_dir.join("other.txt"), "other worktree stash\n").unwrap();
    let peer_dir = create_peer_clone(temp_dir.path(), &origin_dir);
    let target_sha = commit_file_change(&peer_dir, "a.txt", "upstream\n");
    git(&peer_dir, &["push", "-q", "origin", "main"]);
    fs::write(worktree_dir.join("tracked.txt"), "local dirty\n").unwrap();
    let hook_script = format!(
        "#!/bin/sh\ngit -C '{}' -c user.name=other -c user.email=other@localhost stash push -u -q -m other-worktree\n",
        linked_dir.display()
    );
    write_executable_hook(&worktree_dir, "post-merge", &hook_script);

    let outcome = GitWorkspace::new(worktree_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap();

    assert_eq!(
        outcome,
        FastForwardOutcome::FastForwarded {
            previous_sha: initial_sha,
            head_sha: target_sha,
        }
    );
    assert_file_text(&worktree_dir, "tracked.txt", "local dirty\n");
    assert!(!worktree_dir.join("other.txt").exists());
    let top_subject = run(
        "git",
        &["show", "-s", "--format=%s", "refs/stash"],
        &worktree_dir,
    )
    .unwrap();
    assert!(top_subject.contains("other-worktree"), "{top_subject}");
}

#[cfg(unix)]
#[test]
fn surfaces_rollback_error_when_fast_forward_and_stash_rollback_both_fail() {
    let (temp_dir, worktree_dir, origin_dir) = create_origin_and_worktree();
    let initial_sha = commit_file_change(&worktree_dir, "tracked.txt", "before\n");
    git(&worktree_dir, &["push", "-q", "origin", "main"]);
    let peer_dir = create_peer_clone(temp_dir.path(), &origin_dir);
    let target_sha = commit_file_change(&peer_dir, "a.txt", "upstream\n");
    git(&peer_dir, &["push", "-q", "origin", "main"]);
    fs::write(worktree_dir.join("tracked.txt"), "local dirty\n").unwrap();
    let hook_script = format!(
        "#!/bin/sh\nif [ \"$1\" = \"prepared\" ] && grep -q '{target_sha} refs/heads/main'; then\n  : > \"$(git rev-parse --git-dir)/index.lock\"\n  exit 1\nfi\n"
    );
    write_executable_hook(&worktree_dir, "reference-transaction", &hook_script);

    let error = GitWorkspace::new(worktree_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap_err();

    let stash_sha = read_stash_sha(&worktree_dir);
    let message = format!("{error:#}");
    assert_eq!(read_head_commit(&worktree_dir).unwrap(), initial_sha);
    assert!(message.contains("rolling back auto-stash"), "{message}");
    assert!(message.contains(&stash_sha), "{message}");
}

#[test]
fn refuses_fast_forward_when_rebase_is_in_progress_on_detached_head() {
    let (_temp_dir, worktree_dir, _origin_dir) = create_origin_and_worktree();
    let ancestor_sha = commit_file_change(&worktree_dir, "step1.txt", "one\n");
    let target_sha = commit_file_change(&worktree_dir, "step2.txt", "two\n");
    git(&worktree_dir, &["push", "-q", "origin", "main"]);
    git(
        &worktree_dir,
        &["checkout", "-q", "--detach", &ancestor_sha],
    );
    fs::create_dir_all(worktree_dir.join(".git/rebase-merge")).unwrap();

    let error = GitWorkspace::new(worktree_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap_err();

    let message = format!("{error:#}");
    assert!(message.contains("rebase-merge"), "{message}");
    assert_eq!(read_head_commit(&worktree_dir).unwrap(), ancestor_sha);
}

#[test]
fn preserves_preexisting_user_stash_entry_across_auto_stash_and_restore() {
    let (temp_dir, worktree_dir, origin_dir) = create_origin_and_worktree();
    let initial_sha = read_head_commit(&worktree_dir).unwrap();
    fs::write(worktree_dir.join("saved.txt"), "older stash\n").unwrap();
    git(
        &worktree_dir,
        &["stash", "push", "--include-untracked", "-q"],
    );
    let preexisting_stash_sha = read_stash_sha(&worktree_dir);
    let peer_dir = create_peer_clone(temp_dir.path(), &origin_dir);
    let target_sha = commit_file_change(&peer_dir, "a.txt", "upstream\n");
    git(&peer_dir, &["push", "-q", "origin", "main"]);
    fs::write(worktree_dir.join("draft.txt"), "active draft\n").unwrap();

    let outcome = GitWorkspace::new(worktree_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap();

    assert_eq!(
        outcome,
        FastForwardOutcome::FastForwarded {
            previous_sha: initial_sha,
            head_sha: target_sha,
        }
    );
    assert_file_text(&worktree_dir, "draft.txt", "active draft\n");
    assert_eq!(read_stash_sha(&worktree_dir), preexisting_stash_sha);
}

#[test]
fn parent_file_collision_with_nested_untracked_stash_reports_only_nested_path() {
    let (temp_dir, worktree_dir, origin_dir) = create_origin_and_worktree();
    let initial_sha = read_head_commit(&worktree_dir).unwrap();
    let peer_dir = create_peer_clone(temp_dir.path(), &origin_dir);
    let target_sha = commit_file_change(&peer_dir, "nested", "upstream regular file\n");
    git(&peer_dir, &["push", "-q", "origin", "main"]);
    fs::create_dir_all(worktree_dir.join("nested")).unwrap();
    fs::write(worktree_dir.join("nested/child.txt"), "local nested\n").unwrap();
    fs::write(worktree_dir.join("scratch.txt"), "safe note\n").unwrap();

    let outcome = GitWorkspace::new(worktree_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap();

    assert_eq!(
        outcome,
        FastForwardOutcome::RestoreConflict {
            previous_sha: initial_sha,
            head_sha: target_sha,
            conflicted_paths: vec!["nested/child.txt".to_owned()],
        }
    );
    assert!(has_stash_ref(&worktree_dir));
}

#[test]
fn protects_gitignored_file_in_clean_and_dirty_worktrees_and_rolls_back_stash() {
    let (temp_dir, worktree_dir, origin_dir) = create_origin_and_worktree();
    let _ignore_sha = commit_file_change(&worktree_dir, ".gitignore", "local.env\n");
    let initial_sha = commit_file_change(&worktree_dir, "tracked.txt", "clean\n");
    git(&worktree_dir, &["push", "-q", "origin", "main"]);
    fs::write(worktree_dir.join("local.env"), "SECRET=keep_me\n").unwrap();
    let peer_dir = create_peer_clone(temp_dir.path(), &origin_dir);
    fs::write(peer_dir.join(".gitignore"), "").unwrap();
    let target_sha = commit_file_change(&peer_dir, "local.env", "SECRET=from_pr\n");
    git(&peer_dir, &["push", "-q", "origin", "main"]);

    assert!(
        GitWorkspace::new(worktree_dir.clone())
            .fast_forward_to(&target_sha)
            .is_err()
    );
    assert_eq!(read_head_commit(&worktree_dir).unwrap(), initial_sha);
    assert_file_text(&worktree_dir, "local.env", "SECRET=keep_me\n");

    fs::write(worktree_dir.join("saved.txt"), "user stash\n").unwrap();
    git(
        &worktree_dir,
        &["stash", "push", "--include-untracked", "-q"],
    );
    let preexisting_stash_sha = read_stash_sha(&worktree_dir);
    fs::write(worktree_dir.join("tracked.txt"), "dirty tracked\n").unwrap();
    fs::write(worktree_dir.join("notes.txt"), "dirty untracked\n").unwrap();

    assert!(
        GitWorkspace::new(worktree_dir.clone())
            .fast_forward_to(&target_sha)
            .is_err()
    );
    assert_eq!(read_head_commit(&worktree_dir).unwrap(), initial_sha);
    assert_file_text(&worktree_dir, "local.env", "SECRET=keep_me\n");
    assert_file_text(&worktree_dir, "tracked.txt", "dirty tracked\n");
    assert_file_text(&worktree_dir, "notes.txt", "dirty untracked\n");
    assert_eq!(read_stash_sha(&worktree_dir), preexisting_stash_sha);
}

fn attach_local_submodule(temp_root: &Path, worktree_dir: &Path) {
    let sub_source_dir = temp_root.join("sub-source");
    fs::create_dir_all(&sub_source_dir).unwrap();
    git(&sub_source_dir, &["init", "-q", "-b", "main"]);
    commit_file_change(&sub_source_dir, "sub.txt", "v1\n");
    git(
        worktree_dir,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "-q",
            "add",
            sub_source_dir.to_str().unwrap(),
            "sub",
        ],
    );
    git(worktree_dir, &["commit", "-q", "-m", "add submodule"]);
    git(worktree_dir, &["push", "-q", "origin", "main"]);
}

#[test]
fn dirty_submodule_with_preexisting_stash_fast_forwards_without_popping_user_stash() {
    let (temp_dir, worktree_dir, origin_dir) = create_origin_and_worktree();
    attach_local_submodule(temp_dir.path(), &worktree_dir);
    let initial_sha = read_head_commit(&worktree_dir).unwrap();
    fs::write(worktree_dir.join("saved.txt"), "user stash\n").unwrap();
    git(
        &worktree_dir,
        &["stash", "push", "--include-untracked", "-q"],
    );
    let preexisting_stash_sha = read_stash_sha(&worktree_dir);
    fs::write(worktree_dir.join("sub/sub.txt"), "dirty submodule\n").unwrap();
    let peer_dir = create_peer_clone(temp_dir.path(), &origin_dir);
    let target_sha = commit_file_change(&peer_dir, "a.txt", "upstream\n");
    git(&peer_dir, &["push", "-q", "origin", "main"]);

    let outcome = GitWorkspace::new(worktree_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap();

    assert_eq!(
        outcome,
        FastForwardOutcome::FastForwarded {
            previous_sha: initial_sha,
            head_sha: target_sha,
        }
    );
    assert!(!worktree_dir.join("saved.txt").exists());
    assert_file_text(&worktree_dir, "sub/sub.txt", "dirty submodule\n");
    assert_eq!(read_stash_sha(&worktree_dir), preexisting_stash_sha);
}

#[test]
fn linked_worktree_with_trailing_space_and_bisect_or_sequencer_refuses_fast_forward() {
    let (temp_dir, worktree_dir, origin_dir) = create_origin_and_worktree();
    let initial_sha = read_head_commit(&worktree_dir).unwrap();
    let linked_dir = create_detached_worktree(&worktree_dir, "linked worktree ");
    let peer_dir = create_peer_clone(temp_dir.path(), &origin_dir);
    let target_sha = commit_file_change(&peer_dir, "a.txt", "upstream\n");
    git(&peer_dir, &["push", "-q", "origin", "main"]);
    let bisect_path = resolve_git_state_path(&linked_dir, "BISECT_LOG");
    fs::write(&bisect_path, "git bisect start\n").unwrap();

    let bisect_error = GitWorkspace::new(linked_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap_err();
    assert!(format!("{bisect_error:#}").contains("BISECT_LOG"));
    assert_eq!(read_head_commit(&linked_dir).unwrap(), initial_sha);

    fs::remove_file(&bisect_path).unwrap();
    let sequencer_path = resolve_git_state_path(&linked_dir, "sequencer");
    fs::create_dir_all(&sequencer_path).unwrap();

    let sequencer_error = GitWorkspace::new(linked_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap_err();
    assert!(format!("{sequencer_error:#}").contains("sequencer"));
    assert_eq!(read_head_commit(&linked_dir).unwrap(), initial_sha);
}
