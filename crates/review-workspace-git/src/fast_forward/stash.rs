//! Nonce-pinned auto-stash creation, SHA-pinned `stash apply` + guarded `drop`, and conflict inspection.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::process::Output;
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Context, Result, bail};
use review_core::ports::FastForwardOutcome;

use super::merge_fast_forward_only;
use crate::git_output::{is_commit_id, parse_nul_paths, parse_untracked_porcelain_z_paths};
use crate::process::{create_command, run, run_bytes_unlocked};
use crate::status::read_head_commit;
use crate::worktree_path::path_to_safe_relative;

const STASH_IDENTITY_ARGS: [&str; 4] = [
    "-c",
    "user.name=jpr-review",
    "-c",
    "user.email=jpr-review@localhost",
];

static NEXT_STASH_SEQUENCE: AtomicU64 = AtomicU64::new(1);

/// Auto-stashes tracked and untracked changes in `dir`, fast-forwards `HEAD`
/// from `previous_sha` to `target_sha`, and restores the pinned stash entry to
/// produce a [`FastForwardOutcome`].
pub(super) fn stash_fast_forward_and_restore(
    dir: &Path,
    previous_sha: &str,
    target_sha: &str,
) -> Result<FastForwardOutcome> {
    let created_stash = push_auto_stash(dir, previous_sha)?;
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
    let head_sha = read_head_commit(dir).unwrap_or_else(|_| target_sha.to_owned());
    let Some(created_stash_sha) = created_stash else {
        return Ok(FastForwardOutcome::FastForwarded {
            previous_sha: previous_sha.to_owned(),
            head_sha,
        });
    };
    restore_auto_stash_after_fast_forward(dir, previous_sha, &head_sha, &created_stash_sha)
}

fn build_auto_stash_marker() -> String {
    let sequence = NEXT_STASH_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    format!("[{}-{sequence}]", std::process::id())
}

fn push_auto_stash(dir: &Path, previous_sha: &str) -> Result<Option<String>> {
    let marker = build_auto_stash_marker();
    let message = format!("jpr-review auto-stash before fast-forward {marker}");
    let mut args = STASH_IDENTITY_ARGS.to_vec();
    args.extend(["stash", "push", "--include-untracked", "-m", &message]);
    run("git", &args, dir).context("stashing local changes before fast-forward")?;
    find_created_stash_sha(dir, previous_sha, &marker)
}

fn find_created_stash_sha(dir: &Path, previous_sha: &str, marker: &str) -> Result<Option<String>> {
    if read_optional_ref(dir, "refs/stash")?.is_none() {
        return Ok(None);
    }
    let top_output = run_bytes_unlocked(
        "git",
        &["show", "-s", "-z", "--format=%H%x00%P%x00%s", "refs/stash"],
        dir,
    )
    .context("inspecting top git stash commit")?;
    if let Some(matched_sha) = parse_matching_stash_sha(&top_output, previous_sha, marker) {
        return Ok(Some(matched_sha));
    }
    let reflog_output = run_bytes_unlocked(
        "git",
        &[
            "log",
            "-g",
            "--max-count=16",
            "-z",
            "--format=%H%x00%P%x00%s",
            "refs/stash",
        ],
        dir,
    )
    .unwrap_or_default();
    Ok(parse_matching_stash_sha(
        &reflog_output,
        previous_sha,
        marker,
    ))
}

fn parse_matching_stash_sha(bytes: &[u8], previous_sha: &str, marker: &str) -> Option<String> {
    if bytes.is_empty() {
        return None;
    }
    let trimmed = bytes.strip_suffix(b"\0").unwrap_or(bytes);
    let fields: Vec<&[u8]> = trimmed.split(|byte| *byte == 0).collect();
    for record in fields.chunks_exact(3) {
        let [raw_sha, raw_parents, raw_subject] = record else {
            continue;
        };
        let (Ok(commit_sha), Ok(parents), Ok(subject)) = (
            std::str::from_utf8(raw_sha),
            std::str::from_utf8(raw_parents),
            std::str::from_utf8(raw_subject),
        ) else {
            continue;
        };
        let first_parent = parents.split_whitespace().next();
        if is_commit_id(commit_sha)
            && first_parent == Some(previous_sha)
            && subject.ends_with(marker)
        {
            return Some(commit_sha.to_owned());
        }
    }
    None
}

fn read_optional_ref(dir: &Path, reference: &str) -> Result<Option<String>> {
    let mut command = create_command("git", &["rev-parse", "--verify", "--quiet", reference], dir);
    command.env("GIT_OPTIONAL_LOCKS", "0");
    let output = command
        .output()
        .with_context(|| format!("resolving git ref {reference}"))?;
    let stderr = String::from_utf8_lossy(&output.stderr);
    match output.status.code() {
        Some(0) => {
            let resolved_sha = std::str::from_utf8(&output.stdout)
                .context("decoding resolved git ref as UTF-8")?
                .trim();
            if !is_commit_id(resolved_sha) {
                bail!("git rev-parse {reference} returned invalid commit id {resolved_sha:?}");
            }
            Ok(Some(resolved_sha.to_owned()))
        }
        Some(1) if stderr.trim().is_empty() => Ok(None),
        _ => {
            let detail = build_failure_detail_from_output(&output);
            bail!("git rev-parse --verify --quiet {reference} failed: {detail}");
        }
    }
}

fn build_failure_detail_from_output(output: &Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    match (stdout.trim(), stderr.trim()) {
        ("", "") => format!("exited with {}", output.status),
        (only_stdout, "") => only_stdout.to_owned(),
        ("", only_stderr) => only_stderr.to_owned(),
        (both_stdout, both_stderr) => format!("{both_stdout} ({both_stderr})"),
    }
}

fn drop_stash_if_still_top(dir: &Path, created_stash_sha: &str) {
    if read_optional_ref(dir, "refs/stash")
        .ok()
        .flatten()
        .as_deref()
        == Some(created_stash_sha)
    {
        let _ =
            create_command("git", &["stash", "drop", "--quiet", "refs/stash@{0}"], dir).output();
    }
}

fn rollback_auto_stash(dir: &Path, created_stash_sha: &str) -> Result<()> {
    let mut apply_args = STASH_IDENTITY_ARGS.to_vec();
    apply_args.extend(["stash", "apply", created_stash_sha]);
    let output = create_command("git", &apply_args, dir)
        .output()
        .with_context(|| format!("applying auto-stash {created_stash_sha} during rollback"))?;
    if !output.status.success() {
        let detail = build_failure_detail_from_output(&output);
        bail!("applying auto-stash {created_stash_sha} during rollback failed: {detail}");
    }
    drop_stash_if_still_top(dir, created_stash_sha);
    Ok(())
}

fn restore_auto_stash_after_fast_forward(
    dir: &Path,
    previous_sha: &str,
    head_sha: &str,
    created_stash_sha: &str,
) -> Result<FastForwardOutcome> {
    let mut apply_args = STASH_IDENTITY_ARGS.to_vec();
    apply_args.extend(["stash", "apply", created_stash_sha]);
    let apply_output = create_command("git", &apply_args, dir)
        .output()
        .with_context(|| {
            format!(
                "restoring stashed local changes from git stash {created_stash_sha} after HEAD fast-forwarded to {head_sha}"
            )
        })?;
    if apply_output.status.success() {
        drop_stash_if_still_top(dir, created_stash_sha);
        return Ok(FastForwardOutcome::FastForwarded {
            previous_sha: previous_sha.to_owned(),
            head_sha: head_sha.to_owned(),
        });
    }
    let conflicted_paths = read_restore_conflict_paths(dir, created_stash_sha).with_context(|| {
        format!(
            "inspecting restore conflicts after HEAD fast-forwarded to {head_sha} with local changes saved in git stash {created_stash_sha}"
        )
    })?;
    if !conflicted_paths.is_empty() {
        return Ok(FastForwardOutcome::RestoreConflict {
            previous_sha: previous_sha.to_owned(),
            head_sha: head_sha.to_owned(),
            conflicted_paths,
        });
    }
    let detail = build_failure_detail_from_output(&apply_output);
    bail!(
        "git stash apply failed ({}): {detail}; HEAD fast-forwarded to {head_sha} and local changes remain saved in git stash {created_stash_sha}",
        apply_output.status
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
    use super::*;
    use crate::test_support::repo;

    #[test]
    fn parse_matching_stash_sha_requires_exact_first_parent_and_nonce_marker() {
        let base_sha = "1".repeat(40);
        let other_base = "2".repeat(40);
        let index_sha = "3".repeat(40);
        let wrong_stash = "a".repeat(40);
        let right_stash = "b".repeat(40);
        let payload = format!(
            "{wrong_stash}\0{other_base} {index_sha}\0On main: jpr-review [99-1]\0{right_stash}\0{base_sha} {index_sha}\0On main: jpr-review [99-1]\0"
        );

        assert_eq!(
            parse_matching_stash_sha(payload.as_bytes(), &base_sha, "[99-1]"),
            Some(right_stash)
        );
        assert_eq!(
            parse_matching_stash_sha(payload.as_bytes(), &base_sha, "[99-2]"),
            None
        );
        assert_eq!(parse_matching_stash_sha(b"", &base_sha, "[99-1]"), None);
    }

    #[test]
    fn read_optional_ref_returns_none_for_missing_ref_and_err_outside_git_repo() {
        let temp_repo = repo();
        let worktree_dir = temp_repo.path().join("widgets");
        assert!(read_optional_ref(&worktree_dir, "HEAD").unwrap().is_some());
        assert_eq!(
            read_optional_ref(&worktree_dir, "refs/stash").unwrap(),
            None
        );

        let non_repo = tempfile::tempdir().unwrap();
        assert!(read_optional_ref(non_repo.path(), "refs/stash").is_err());
    }
}
