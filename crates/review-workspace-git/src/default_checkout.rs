//! The default checkout: `git worktree add` beside the main checkout, then
//! `gh pr checkout`, reusing a worktree already on the pull request's branch.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

use crate::process::run;
use crate::repo::main_repo_root;

/// Where the default checkout puts pull request `number`:
/// `<parent>/<repo>-worktrees/pr-<number>`.
#[must_use]
pub fn default_worktree_path(main_root: &Path, number: u64) -> PathBuf {
    let name = main_root.file_name().map_or_else(
        || "repo".to_owned(),
        |name| name.to_string_lossy().into_owned(),
    );
    main_root
        .parent()
        .unwrap_or(main_root)
        .join(format!("{name}-worktrees"))
        .join(format!("pr-{number}"))
}

/// Checks pull request `number` out into its default worktree, for
/// `checkout_pr` with the default command, and returns the worktree's path.
pub fn checkout_default(dir: &Path, number: u64) -> Result<PathBuf> {
    let main = main_repo_root(dir)?;
    reusable_worktree(&main, number)?.map_or_else(|| create_pr_worktree(&main, number), Ok)
}

/// Creates the default worktree for pull request `number`, which must not
/// exist yet, and checks the pull request out in it.
fn create_pr_worktree(main: &Path, number: u64) -> Result<PathBuf> {
    let path = default_worktree_path(main, number);
    let path_text = path.to_string_lossy().into_owned();
    run("git", &["worktree", "add", "--detach", &path_text], main)
        .context("creating the worktree")?;
    let branch = pr_branch(number);
    if let Err(error) = run(
        "gh",
        &["pr", "checkout", &number.to_string(), "-b", &branch],
        &path,
    ) {
        // Remove the empty worktree we just made, so a retry starts clean.
        // Forcing is safe only because this call created it moments ago.
        let context = match force_remove_worktree(main, &path) {
            Ok(()) => format!("checking out pull request #{number}"),
            Err(cleanup) => format!(
                "checking out pull request #{number} (removing the partial worktree also failed: {cleanup:#})"
            ),
        };
        return Err(error.context(context));
    }
    Ok(path)
}

/// The local branch `gh pr checkout` creates for pull request `number`.
fn pr_branch(number: u64) -> String {
    format!("pr-{number}")
}

/// The default worktree for pull request `number`, if it already exists and
/// has the pull request's branch checked out, or `None` if nothing is there.
///
/// Anything else at that path, such as a worktree left detached by an
/// interrupted checkout, is an error and is never removed: it may hold work
/// that git cannot see, such as ignored files, so only a person can decide.
fn reusable_worktree(main: &Path, number: u64) -> Result<Option<PathBuf>> {
    let path = default_worktree_path(main, number);
    if !path.exists() {
        return Ok(None);
    }
    if is_pr_worktree(main, &path, number) {
        return Ok(Some(path));
    }
    bail!(
        "{} already exists but is not a worktree on branch {}: \
         inspect it, remove it yourself, and try again",
        path.display(),
        pr_branch(number)
    )
}

/// Whether `path` is the top of a worktree of `main` with pull request
/// `number`'s branch checked out.
fn is_pr_worktree(main: &Path, path: &Path, number: u64) -> bool {
    let Ok(stdout) = run(
        "git",
        &[
            "rev-parse",
            "--path-format=absolute",
            "--show-toplevel",
            "--git-common-dir",
            "--abbrev-ref",
            "HEAD",
        ],
        path,
    ) else {
        return false;
    };
    let mut lines = stdout.lines();
    let (Some(toplevel), Some(common_dir), Some(branch)) =
        (lines.next(), lines.next(), lines.next())
    else {
        return false;
    };
    is_same_path(Path::new(toplevel), path)
        && is_same_path(Path::new(common_dir), &main.join(".git"))
        && branch == pr_branch(number)
}

/// Whether `left` and `right` resolve to the same existing path.
fn is_same_path(left: &Path, right: &Path) -> bool {
    matches!(
        (left.canonicalize(), right.canonicalize()),
        (Ok(left), Ok(right)) if left == right
    )
}

/// Removes the worktree at `path`, discarding everything in it.
fn force_remove_worktree(main: &Path, path: &Path) -> Result<()> {
    let path_text = path.to_string_lossy().into_owned();
    run("git", &["worktree", "remove", "--force", &path_text], main)
        .with_context(|| format!("removing the worktree at {}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::process::Command;

    use super::*;
    use crate::test_support::{git, repo};
    use crate::{WorktreeCommand, checkout_pr};

    #[test]
    fn the_default_path_sits_beside_the_repository() {
        assert_eq!(
            default_worktree_path(Path::new("/src/widgets"), 7),
            PathBuf::from("/src/widgets-worktrees/pr-7")
        );
    }

    #[test]
    fn the_default_checkout_reuses_an_existing_worktree() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let existing = dir.path().join("widgets-worktrees").join("pr-5");
        git(
            &root,
            &[
                "worktree",
                "add",
                "-q",
                "-b",
                "pr-5",
                existing.to_str().unwrap(),
            ],
        );
        let path = checkout_pr(&root, 5, &WorktreeCommand::Default).unwrap();
        assert_eq!(
            path.canonicalize().unwrap(),
            existing.canonicalize().unwrap()
        );
    }

    /// Whether `git worktree list` in `root` mentions `path`.
    fn is_listed_worktree(root: &Path, path: &Path) -> bool {
        let output = Command::new("git")
            .args(["worktree", "list", "--porcelain"])
            .current_dir(root)
            .output()
            .unwrap();
        let listing = String::from_utf8_lossy(&output.stdout).into_owned();
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        listing
            .lines()
            .any(|line| line.starts_with("worktree ") && line.ends_with(&name))
    }

    #[test]
    fn nothing_is_reusable_when_the_worktree_is_missing() {
        let dir = repo();
        let root = dir.path().join("widgets");
        assert_eq!(reusable_worktree(&root, 5).unwrap(), None);
    }

    #[test]
    fn a_clean_detached_leftover_worktree_is_an_error_and_is_kept() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let leftover = dir.path().join("widgets-worktrees").join("pr-5");
        git(
            &root,
            &[
                "worktree",
                "add",
                "-q",
                "--detach",
                leftover.to_str().unwrap(),
            ],
        );
        assert_kept_with_guidance(&root, &leftover);
    }

    #[test]
    fn a_clean_worktree_on_another_branch_is_an_error_and_is_kept() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let leftover = dir.path().join("widgets-worktrees").join("pr-5");
        git(
            &root,
            &[
                "worktree",
                "add",
                "-q",
                "-b",
                "other",
                leftover.to_str().unwrap(),
            ],
        );
        assert_kept_with_guidance(&root, &leftover);
    }

    #[test]
    fn a_worktree_holding_only_an_ignored_file_is_an_error_and_is_kept() {
        let dir = repo();
        let root = dir.path().join("widgets");
        fs::write(root.join(".gitignore"), ".env\n").unwrap();
        git(&root, &["add", ".gitignore"]);
        git(&root, &["commit", "-q", "-m", "ignore .env"]);
        let leftover = dir.path().join("widgets-worktrees").join("pr-5");
        git(
            &root,
            &[
                "worktree",
                "add",
                "-q",
                "--detach",
                leftover.to_str().unwrap(),
            ],
        );
        fs::write(leftover.join(".env"), "SECRET=1\n").unwrap();
        assert_kept_with_guidance(&root, &leftover);
        assert_eq!(
            fs::read_to_string(leftover.join(".env")).unwrap(),
            "SECRET=1\n"
        );
    }

    #[test]
    fn a_directory_that_is_not_a_worktree_is_an_error_and_is_kept() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let stray = dir.path().join("widgets-worktrees").join("pr-5");
        fs::create_dir_all(&stray).unwrap();
        fs::write(stray.join("notes.txt"), "mine\n").unwrap();
        let error = checkout_pr(&root, 5, &WorktreeCommand::Default).unwrap_err();
        let message = format!("{error:#}");
        assert!(message.contains("inspect it"), "{message}");
        assert!(message.contains("pr-5"), "{message}");
        assert!(stray.join("notes.txt").exists());
    }

    /// Asserts that `reusable_worktree` failed instead of reusing or removing
    /// `kept`, and said which path to look at.
    fn assert_kept_with_guidance(root: &Path, kept: &Path) {
        let error = reusable_worktree(root, 5).unwrap_err();
        let message = format!("{error:#}");
        assert!(message.contains(&kept.display().to_string()), "{message}");
        assert!(message.contains("inspect it"), "{message}");
        assert!(is_listed_worktree(root, kept));
    }

    #[test]
    fn a_dirty_worktree_on_another_branch_is_an_error_and_is_kept() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let leftover = dir.path().join("widgets-worktrees").join("pr-5");
        git(
            &root,
            &[
                "worktree",
                "add",
                "-q",
                "-b",
                "other",
                leftover.to_str().unwrap(),
            ],
        );
        fs::write(leftover.join("a.txt"), "edited\n").unwrap();
        fs::write(leftover.join("notes.txt"), "mine\n").unwrap();
        assert_kept_with_guidance(&root, &leftover);
        assert_eq!(
            fs::read_to_string(leftover.join("a.txt")).unwrap(),
            "edited\n"
        );
        assert!(leftover.join("notes.txt").exists());
    }

    #[test]
    fn a_detached_worktree_with_unreferenced_commits_is_an_error_and_is_kept() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let leftover = dir.path().join("widgets-worktrees").join("pr-5");
        git(
            &root,
            &[
                "worktree",
                "add",
                "-q",
                "--detach",
                leftover.to_str().unwrap(),
            ],
        );
        fs::write(leftover.join("a.txt"), "work\n").unwrap();
        git(
            &leftover,
            &["commit", "-q", "-am", "only reachable from this HEAD"],
        );
        assert_kept_with_guidance(&root, &leftover);
        assert_eq!(
            fs::read_to_string(leftover.join("a.txt")).unwrap(),
            "work\n"
        );
    }
}
