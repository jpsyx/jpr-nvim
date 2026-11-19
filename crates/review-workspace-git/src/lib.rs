//! Checking a pull request out into its own worktree. Generic: it knows git
//! and `gh`, and nothing about any editor.

use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};

/// How to create a pull request's worktree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorktreeCommand {
    /// `git worktree add` beside the repository, then `gh pr checkout`.
    Default,
    /// A shell command that creates the worktree and prints its path as its
    /// last line of output. `{n}` is replaced with the pull request number.
    Custom(String),
}

/// `template` with `{n}` replaced by `number`.
#[must_use]
pub fn render_custom(template: &str, number: u64) -> String {
    template.replace("{n}", &number.to_string())
}

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

/// The last non-blank line of `stdout`, as a path.
#[must_use]
pub fn last_path_line(stdout: &str) -> Option<PathBuf> {
    stdout
        .lines()
        .map(str::trim)
        .rfind(|line| !line.is_empty())
        .map(PathBuf::from)
}

/// The main checkout's root, even when `dir` is inside a linked worktree.
pub fn main_repo_root(dir: &Path) -> Result<PathBuf> {
    let common = run(
        "git",
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
        dir,
    )
    .context("finding the repository (is this a git checkout?)")?;
    let common = PathBuf::from(common.trim());
    if common.file_name().is_some_and(|name| name == ".git") {
        return common
            .parent()
            .map(Path::to_path_buf)
            .context("the git directory has no parent");
    }
    bail!(
        "{} is a bare repository; open the pull request from a checkout",
        common.display()
    )
}

/// Checks pull request `number` out into a worktree and returns its path.
///
/// An existing default worktree is reused only when it is on the pull
/// request's branch; anything else at that path is an error, never removed.
pub fn checkout_pr(dir: &Path, number: u64, command: &WorktreeCommand) -> Result<PathBuf> {
    match command {
        WorktreeCommand::Custom(template) => checkout_custom(dir, &render_custom(template, number)),
        WorktreeCommand::Default => checkout_default(dir, number),
    }
}

fn checkout_custom(dir: &Path, command: &str) -> Result<PathBuf> {
    let stdout = run("sh", &["-c", command], dir)
        .with_context(|| format!("running the worktree command `{command}`"))?;
    let path = last_path_line(&stdout)
        .with_context(|| format!("the worktree command `{command}` printed no path"))?;
    let path = if path.is_absolute() {
        path
    } else {
        dir.join(path)
    };
    if !path.is_dir() {
        bail!(
            "the worktree command `{command}` printed {}, which is not a directory",
            path.display()
        );
    }
    path.canonicalize()
        .with_context(|| format!("resolving {}", path.display()))
}

fn checkout_default(dir: &Path, number: u64) -> Result<PathBuf> {
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
    let (Some(top), Some(common), Some(branch)) = (lines.next(), lines.next(), lines.next()) else {
        return false;
    };
    is_same_path(Path::new(top), path)
        && is_same_path(Path::new(common), &main.join(".git"))
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

/// Runs `program` in `dir` and returns its stdout, or fails with its stderr.
fn run(program: &str, args: &[&str], dir: &Path) -> Result<String> {
    let output = Command::new(program)
        .args(args)
        .current_dir(dir)
        .output()
        .with_context(|| format!("running {program}"))?;
    if output.status.success() {
        return Ok(String::from_utf8_lossy(&output.stdout).into_owned());
    }
    bail!(
        "{program} failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    )
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    fn git(dir: &Path, args: &[&str]) {
        let status = Command::new("git")
            .args(args)
            .current_dir(dir)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@example.com")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@example.com")
            .status()
            .unwrap();
        assert!(status.success(), "git {args:?}");
    }

    /// A temporary directory holding a one-commit repository named `widgets`.
    fn repo() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("widgets");
        fs::create_dir(&root).unwrap();
        git(&root, &["init", "-q", "-b", "main"]);
        fs::write(root.join("a.txt"), "a\n").unwrap();
        git(&root, &["add", "."]);
        git(&root, &["commit", "-q", "-m", "init"]);
        dir
    }

    #[test]
    fn render_custom_substitutes_the_number() {
        assert_eq!(render_custom("wt pr {n}", 42), "wt pr 42");
    }

    #[test]
    fn the_default_path_sits_beside_the_repository() {
        assert_eq!(
            default_worktree_path(Path::new("/src/widgets"), 7),
            PathBuf::from("/src/widgets-worktrees/pr-7")
        );
    }

    #[test]
    fn last_path_line_skips_trailing_blank_lines() {
        assert_eq!(
            last_path_line("noise\n/tmp/wt\n\n"),
            Some(PathBuf::from("/tmp/wt"))
        );
        assert_eq!(last_path_line("\n \n"), None);
    }

    #[test]
    fn main_repo_root_finds_the_main_checkout_from_a_worktree() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let linked = dir.path().join("linked");
        git(
            &root,
            &[
                "worktree",
                "add",
                "-q",
                "--detach",
                linked.to_str().unwrap(),
            ],
        );
        let found = main_repo_root(&linked).unwrap();
        assert_eq!(found.canonicalize().unwrap(), root.canonicalize().unwrap());
    }

    #[test]
    fn main_repo_root_outside_git_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let error = main_repo_root(dir.path()).unwrap_err();
        assert!(format!("{error:#}").contains("git checkout"), "{error:#}");
    }

    #[test]
    fn a_custom_command_returns_the_directory_it_prints() {
        let dir = tempfile::tempdir().unwrap();
        let base = dir.path().display();
        let template =
            format!("mkdir -p '{base}/pr-{{n}}' && echo creating >&2 && echo '{base}/pr-{{n}}'");
        let path = checkout_pr(dir.path(), 9, &WorktreeCommand::Custom(template)).unwrap();
        assert_eq!(path, dir.path().join("pr-9").canonicalize().unwrap());
    }

    #[test]
    fn a_failing_custom_command_reports_its_stderr() {
        let dir = tempfile::tempdir().unwrap();
        let error = checkout_pr(
            dir.path(),
            9,
            &WorktreeCommand::Custom("echo nope >&2; exit 3".into()),
        )
        .unwrap_err();
        assert!(format!("{error:#}").contains("nope"), "{error:#}");
    }

    #[test]
    fn a_custom_command_must_print_a_directory() {
        let dir = tempfile::tempdir().unwrap();
        let error = checkout_pr(
            dir.path(),
            9,
            &WorktreeCommand::Custom("echo /definitely/not/here".into()),
        )
        .unwrap_err();
        assert!(
            format!("{error:#}").contains("not a directory"),
            "{error:#}"
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
