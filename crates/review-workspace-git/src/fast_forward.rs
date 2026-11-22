//! Dirty-worktree auto-stash, `--ff-only` fast-forward, and stash-pop conflict detection.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use review_core::ports::FastForwardOutcome;

use crate::GitWorkspace;
use crate::git_output::parse_nul_paths;
use crate::process::{create_command, run, run_bytes_unlocked};
use crate::status::read_head_commit;
use crate::workspace::require_commit_id;
use crate::worktree_path::path_to_safe_relative;

const STASH_IDENTITY_ARGS: [&str; 4] = [
    "-c",
    "user.name=jpr-review",
    "-c",
    "user.email=jpr-review@localhost",
];

const ACTIVE_GIT_STATE_NAMES: [&str; 5] = [
    "rebase-merge",
    "rebase-apply",
    "MERGE_HEAD",
    "CHERRY_PICK_HEAD",
    "REVERT_HEAD",
];

/// Attempts to fast-forward the worktree at `dir` to `target_sha`, stashing and
/// restoring dirty tracked and untracked changes when needed.
pub fn fast_forward_worktree(
    workspace: &GitWorkspace,
    dir: &Path,
    target_sha: &str,
) -> Result<FastForwardOutcome> {
    require_commit_id(target_sha)?;
    let previous_sha = read_head_commit(dir)?;
    if previous_sha == target_sha {
        return Ok(FastForwardOutcome::AlreadyAtTarget {
            head_sha: previous_sha,
        });
    }
    workspace.ensure_commit(target_sha)?;
    if is_ancestor(dir, target_sha, &previous_sha)? {
        return Ok(FastForwardOutcome::AheadOfTarget {
            head_sha: previous_sha,
            target_sha: target_sha.to_owned(),
        });
    }
    if !is_ancestor(dir, &previous_sha, target_sha)? {
        return Ok(FastForwardOutcome::Diverged {
            head_sha: previous_sha,
            target_sha: target_sha.to_owned(),
        });
    }
    ensure_no_active_git_operation(dir)?;
    if !is_worktree_dirty(dir)? {
        merge_fast_forward_only(dir, target_sha)?;
        return Ok(FastForwardOutcome::FastForwarded {
            previous_sha,
            head_sha: read_head_commit(dir)?,
        });
    }
    stash_fast_forward_and_restore(dir, &previous_sha, target_sha)
}

fn ensure_no_active_git_operation(dir: &Path) -> Result<()> {
    let mut args = vec!["rev-parse"];
    for state_name in ACTIVE_GIT_STATE_NAMES {
        args.extend(["--git-path", state_name]);
    }
    let output = run_bytes_unlocked("git", &args, dir)
        .context("checking for in-progress git operations before fast-forward")?;
    let resolved_text =
        std::str::from_utf8(&output).context("decoding git-path output as UTF-8")?;
    for (state_name, resolved_line) in ACTIVE_GIT_STATE_NAMES
        .into_iter()
        .zip(resolved_text.lines())
    {
        if fs::symlink_metadata(dir.join(resolved_line.trim())).is_ok() {
            bail!("cannot fast-forward worktree while git operation ({state_name}) is in progress");
        }
    }
    Ok(())
}

fn is_ancestor(dir: &Path, ancestor: &str, descendant: &str) -> Result<bool> {
    let args = ["merge-base", "--is-ancestor", ancestor, descendant];
    let output = create_command("git", &args, dir)
        .output()
        .context("checking commit ancestry with git merge-base")?;
    match output.status.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let detail = stderr.trim();
            if detail.is_empty() {
                bail!("git {} failed with {}", args.join(" "), output.status);
            }
            bail!("git merge-base --is-ancestor failed: {detail}");
        }
    }
}

fn is_worktree_dirty(dir: &Path) -> Result<bool> {
    let status_output = run_bytes_unlocked(
        "git",
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        dir,
    )
    .context("checking worktree dirty state before fast-forward")?;
    Ok(!status_output.is_empty())
}

fn merge_fast_forward_only(dir: &Path, target_sha: &str) -> Result<()> {
    run("git", &["merge", "--ff-only", target_sha], dir)
        .with_context(|| format!("fast-forwarding HEAD to {target_sha}"))?;
    Ok(())
}

fn read_optional_ref(dir: &Path, reference: &str) -> Option<String> {
    let output =
        run_bytes_unlocked("git", &["rev-parse", "--verify", "--quiet", reference], dir).ok()?;
    let resolved_sha = std::str::from_utf8(&output).ok()?.trim();
    (!resolved_sha.is_empty()).then(|| resolved_sha.to_owned())
}

fn push_auto_stash(dir: &Path) -> Result<Option<String>> {
    let stash_before = read_optional_ref(dir, "refs/stash");
    let mut args = STASH_IDENTITY_ARGS.to_vec();
    args.extend([
        "stash",
        "push",
        "--include-untracked",
        "-m",
        "jpr-review auto-stash before fast-forward",
    ]);
    run("git", &args, dir).context("stashing local changes before fast-forward")?;
    let stash_after = read_optional_ref(dir, "refs/stash");
    Ok(stash_after.filter(|after_sha| Some(after_sha.as_str()) != stash_before.as_deref()))
}

fn verify_top_stash_matches(dir: &Path, expected_stash_sha: &str) -> Result<()> {
    let current_stash_sha = read_optional_ref(dir, "refs/stash");
    if current_stash_sha.as_deref() == Some(expected_stash_sha) {
        return Ok(());
    }
    bail!(
        "refs/stash moved unexpectedly to {current_stash_sha:?}; refusing to pop another stash while local changes remain saved in git stash {expected_stash_sha}"
    )
}

fn build_failure_detail_from_output(output: &std::process::Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    match (stdout.trim(), stderr.trim()) {
        ("", "") => format!("exited with {}", output.status),
        (only_stdout, "") => only_stdout.to_owned(),
        ("", only_stderr) => only_stderr.to_owned(),
        (both_stdout, both_stderr) => format!("{both_stdout} ({both_stderr})"),
    }
}

fn rollback_auto_stash(dir: &Path, created_stash_sha: &str) -> Result<()> {
    verify_top_stash_matches(dir, created_stash_sha)?;
    let mut rollback_args = STASH_IDENTITY_ARGS.to_vec();
    rollback_args.extend(["stash", "pop"]);
    let output = create_command("git", &rollback_args, dir)
        .output()
        .with_context(|| format!("popping auto-stash {created_stash_sha} during rollback"))?;
    if output.status.success() {
        return Ok(());
    }
    let detail = build_failure_detail_from_output(&output);
    bail!("popping auto-stash {created_stash_sha} during rollback failed: {detail}")
}

fn stash_fast_forward_and_restore(
    dir: &Path,
    previous_sha: &str,
    target_sha: &str,
) -> Result<FastForwardOutcome> {
    let created_stash = push_auto_stash(dir)?;
    if let Err(merge_error) = merge_fast_forward_only(dir, target_sha) {
        if let Some(created_stash_sha) = &created_stash
            && let Err(rollback_error) = rollback_auto_stash(dir, created_stash_sha)
        {
            return Err(merge_error.context(format!(
                "fast-forward failed and rolling back auto-stash {created_stash_sha} also failed: {rollback_error:#}"
            )));
        }
        return Err(merge_error);
    }
    let head_sha = read_head_commit(dir)?;
    let Some(created_stash_sha) = created_stash else {
        return Ok(FastForwardOutcome::FastForwarded {
            previous_sha: previous_sha.to_owned(),
            head_sha,
        });
    };
    restore_auto_stash_after_fast_forward(dir, previous_sha, &head_sha, &created_stash_sha)
}

fn restore_auto_stash_after_fast_forward(
    dir: &Path,
    previous_sha: &str,
    head_sha: &str,
    created_stash_sha: &str,
) -> Result<FastForwardOutcome> {
    verify_top_stash_matches(dir, created_stash_sha)
        .with_context(|| format!("HEAD fast-forwarded to {head_sha}"))?;
    let mut pop_args = STASH_IDENTITY_ARGS.to_vec();
    pop_args.extend(["stash", "pop"]);
    let pop_output = create_command("git", &pop_args, dir)
        .output()
        .with_context(|| {
            format!(
                "restoring stashed local changes from git stash {created_stash_sha} after HEAD fast-forwarded to {head_sha}"
            )
        })?;
    if pop_output.status.success() {
        return Ok(FastForwardOutcome::FastForwarded {
            previous_sha: previous_sha.to_owned(),
            head_sha: head_sha.to_owned(),
        });
    }
    let conflicted_paths = read_restore_conflict_paths(dir, created_stash_sha)?;
    if !conflicted_paths.is_empty() {
        return Ok(FastForwardOutcome::RestoreConflict {
            previous_sha: previous_sha.to_owned(),
            head_sha: head_sha.to_owned(),
            conflicted_paths,
        });
    }
    let detail = build_failure_detail_from_output(&pop_output);
    bail!(
        "git stash pop failed ({}): {detail}; HEAD fast-forwarded to {head_sha} and local changes remain saved in git stash {created_stash_sha}",
        pop_output.status
    )
}

fn collect_safe_sorted_paths(raw_paths: Vec<String>) -> Vec<String> {
    raw_paths
        .into_iter()
        .filter(|path| path_to_safe_relative(path).is_ok())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

fn parse_untracked_porcelain_z_paths(bytes: &[u8]) -> BTreeSet<String> {
    bytes
        .split(|byte| *byte == 0)
        .filter_map(|entry| entry.strip_prefix(b"?? "))
        .filter_map(|raw_path| std::str::from_utf8(raw_path).ok())
        .filter(|path| !path.is_empty())
        .map(str::to_owned)
        .collect()
}

fn has_worktree_path_collision(dir: &Path, relative_path: &str) -> bool {
    let Ok(safe_relative) = path_to_safe_relative(relative_path) else {
        return false;
    };
    let mut current_path = dir.to_path_buf();
    let mut components = safe_relative.components().peekable();
    while let Some(component) = components.next() {
        current_path.push(component);
        let is_parent_component = components.peek().is_some();
        if is_parent_component {
            if fs::symlink_metadata(&current_path)
                .is_ok_and(|metadata| !metadata.file_type().is_dir())
            {
                return true;
            }
        } else if fs::symlink_metadata(&current_path).is_ok() {
            return true;
        }
    }
    false
}

fn read_colliding_stash_untracked_paths(
    dir: &Path,
    created_stash_sha: &str,
) -> Result<Vec<String>> {
    let untracked_tree = format!("{created_stash_sha}^3");
    let Ok(stash_untracked_output) = run_bytes_unlocked(
        "git",
        &["ls-tree", "-r", "--name-only", "-z", &untracked_tree],
        dir,
    ) else {
        return Ok(Vec::new());
    };
    let status_output = run_bytes_unlocked(
        "git",
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        dir,
    )
    .context("listing worktree status after stash restore failure")?;
    let restored_untracked = parse_untracked_porcelain_z_paths(&status_output);
    let colliding_paths = parse_nul_paths(&stash_untracked_output)
        .into_iter()
        .filter(|path| !restored_untracked.contains(path))
        .filter(|path| has_worktree_path_collision(dir, path))
        .collect();
    Ok(collect_safe_sorted_paths(colliding_paths))
}

fn read_restore_conflict_paths(dir: &Path, created_stash_sha: &str) -> Result<Vec<String>> {
    let unmerged_output = run_bytes_unlocked(
        "git",
        &["diff", "--name-only", "--diff-filter=U", "-z"],
        dir,
    )
    .context("listing unmerged paths after stash restore conflict")?;
    let unmerged_paths = collect_safe_sorted_paths(parse_nul_paths(&unmerged_output));
    if !unmerged_paths.is_empty() {
        return Ok(unmerged_paths);
    }
    read_colliding_stash_untracked_paths(dir, created_stash_sha)
}

#[cfg(test)]
mod tests {
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

    fn assert_file_text(repo_dir: &Path, relative_path: &str, expected: &str) {
        assert_eq!(
            fs::read_to_string(repo_dir.join(relative_path)).unwrap(),
            expected
        );
    }

    fn has_stash_ref(repo_dir: &Path) -> bool {
        run("git", &["rev-parse", "--verify", "refs/stash"], repo_dir).is_ok()
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

        let stash_sha = run("git", &["rev-parse", "refs/stash"], &worktree_dir)
            .unwrap()
            .trim()
            .to_owned();
        let message = format!("{error:#}");
        assert_eq!(read_head_commit(&worktree_dir).unwrap(), target_sha);
        assert!(message.contains("HEAD"), "{message}");
        assert!(message.contains(&target_sha), "{message}");
        assert!(message.contains("stash"), "{message}");
        assert!(message.contains(&stash_sha), "{message}");
        assert!(message.contains("The stash entry is kept"), "{message}");
    }

    #[cfg(unix)]
    #[test]
    fn refuses_to_pop_wrong_stash_when_shared_stash_ref_moves_concurrently() {
        let (temp_dir, worktree_dir, origin_dir) = create_origin_and_worktree();
        let _initial_sha = commit_file_change(&worktree_dir, "tracked.txt", "before\n");
        git(&worktree_dir, &["push", "-q", "origin", "main"]);
        let linked_dir = temp_dir.path().join("linked");
        git(
            &worktree_dir,
            &[
                "worktree",
                "add",
                "-q",
                "--detach",
                linked_dir.to_str().unwrap(),
            ],
        );
        fs::write(linked_dir.join("other.txt"), "other worktree stash\n").unwrap();
        let peer_dir = create_peer_clone(temp_dir.path(), &origin_dir);
        let target_sha = commit_file_change(&peer_dir, "a.txt", "upstream\n");
        git(&peer_dir, &["push", "-q", "origin", "main"]);
        fs::write(worktree_dir.join("tracked.txt"), "local dirty\n").unwrap();
        let hook_script = format!(
            "#!/bin/sh\ngit -C '{}' -c user.name=other -c user.email=other@localhost stash push -u -q\n",
            linked_dir.display()
        );
        write_executable_hook(&worktree_dir, "post-merge", &hook_script);

        let error = GitWorkspace::new(worktree_dir.clone())
            .fast_forward_to(&target_sha)
            .unwrap_err();

        let top_stash_sha = run("git", &["rev-parse", "refs/stash"], &worktree_dir)
            .unwrap()
            .trim()
            .to_owned();
        let previous_stash_sha = run("git", &["rev-parse", "refs/stash@{1}"], &worktree_dir)
            .unwrap()
            .trim()
            .to_owned();
        let message = format!("{error:#}");
        assert!(message.contains("refs/stash"), "{message}");
        assert!(message.contains(&previous_stash_sha), "{message}");
        assert!(!top_stash_sha.is_empty());
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
            "#!/bin/sh\nif [ \"$1\" = \"prepared\" ] && grep -q '{target_sha} refs/heads/main'; then\n  : > \"${{GIT_DIR:-.git}}/index.lock\"\n  exit 1\nfi\n"
        );
        write_executable_hook(&worktree_dir, "reference-transaction", &hook_script);

        let error = GitWorkspace::new(worktree_dir.clone())
            .fast_forward_to(&target_sha)
            .unwrap_err();

        let stash_sha = run("git", &["rev-parse", "refs/stash"], &worktree_dir)
            .unwrap()
            .trim()
            .to_owned();
        let message = format!("{error:#}");
        assert_eq!(read_head_commit(&worktree_dir).unwrap(), initial_sha);
        assert!(message.contains("rolling back auto-stash"), "{message}");
        assert!(message.contains(&stash_sha), "{message}");
        assert!(message.contains("ref updates aborted by hook"), "{message}");
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
        let preexisting_stash_sha = run("git", &["rev-parse", "refs/stash"], &worktree_dir)
            .unwrap()
            .trim()
            .to_owned();
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
        assert_eq!(
            fs::read_to_string(worktree_dir.join("draft.txt")).unwrap(),
            "active draft\n"
        );
        let remaining_stash_sha = run("git", &["rev-parse", "refs/stash"], &worktree_dir)
            .unwrap()
            .trim()
            .to_owned();
        assert_eq!(remaining_stash_sha, preexisting_stash_sha);
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
}
