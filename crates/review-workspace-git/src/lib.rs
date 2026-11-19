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

/// Checks pull request `number` out into a worktree and returns its path. An
/// existing default worktree is reused as it is.
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
    let path = default_worktree_path(&main, number);
    if path.is_dir() {
        return Ok(path);
    }
    let path_text = path.to_string_lossy().into_owned();
    run("git", &["worktree", "add", "--detach", &path_text], &main)
        .context("creating the worktree")?;
    let branch = format!("pr-{number}");
    if let Err(error) = run(
        "gh",
        &["pr", "checkout", &number.to_string(), "-b", &branch],
        &path,
    ) {
        // Remove the empty worktree we just made, so a retry starts clean.
        let _ = run("git", &["worktree", "remove", "--force", &path_text], &main);
        return Err(error.context(format!("checking out pull request #{number}")));
    }
    Ok(path)
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
        fs::create_dir_all(&existing).unwrap();
        let path = checkout_pr(&root, 5, &WorktreeCommand::Default).unwrap();
        assert_eq!(
            path.canonicalize().unwrap(),
            existing.canonicalize().unwrap()
        );
    }
}
