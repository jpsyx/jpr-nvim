//! Checking a pull request out with a person's own worktree command.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

use crate::process::run;

/// The last non-blank line of `stdout`, as a path.
#[must_use]
pub fn last_path_line(stdout: &str) -> Option<PathBuf> {
    stdout
        .lines()
        .map(str::trim)
        .rfind(|line| !line.is_empty())
        .map(PathBuf::from)
}

/// Runs the rendered worktree `command` in `dir` and returns the directory it
/// printed last, for `checkout_pr` with a custom command.
pub fn checkout_custom(dir: &Path, command: &str) -> Result<PathBuf> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{WorktreeCommand, checkout_pr};

    #[test]
    fn last_path_line_skips_trailing_blank_lines() {
        assert_eq!(
            last_path_line("noise\n/tmp/wt\n\n"),
            Some(PathBuf::from("/tmp/wt"))
        );
        assert_eq!(last_path_line("\n \n"), None);
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
}
