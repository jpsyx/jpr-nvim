//! Hook failure, stash isolation, gitignore, submodule, and linked-worktree
//! edge-case tests for `Workspace::fast_forward_to`.

use std::fs;
use std::path::Path;

use review_core::ports::{FastForwardOutcome, Workspace};

use super::*;
use crate::GitWorkspace;
use crate::process::run;
use crate::status::read_head_commit;
use crate::test_support::git;

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
    let bisect_path = read_git_state_path(&linked_dir, "BISECT_LOG");
    fs::write(&bisect_path, "git bisect start\n").unwrap();

    let bisect_error = GitWorkspace::new(linked_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap_err();
    assert!(format!("{bisect_error:#}").contains("BISECT_LOG"));
    assert_eq!(read_head_commit(&linked_dir).unwrap(), initial_sha);

    fs::remove_file(&bisect_path).unwrap();
    let sequencer_path = read_git_state_path(&linked_dir, "sequencer");
    fs::create_dir_all(&sequencer_path).unwrap();

    let sequencer_error = GitWorkspace::new(linked_dir.clone())
        .fast_forward_to(&target_sha)
        .unwrap_err();
    assert!(format!("{sequencer_error:#}").contains("sequencer"));
    assert_eq!(read_head_commit(&linked_dir).unwrap(), initial_sha);
}
