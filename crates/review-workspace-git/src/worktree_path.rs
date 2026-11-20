//! Reading a file the pull request names, which is untrusted: it must stay
//! inside the worktree.

use std::fs;
use std::io::ErrorKind;
use std::path::{Component, Path};

use anyhow::{Context, Result, bail};

/// `path` as a relative path inside a worktree, or an error unless it is
/// written the way git names a file: relative, with no empty, `.` or `..`
/// segment, and no `.git` segment in any letter case, which would reach the
/// repository's own files. Git and the disk then both read the same file.
pub fn path_to_safe_relative(path: &str) -> Result<&Path> {
    let relative = Path::new(path);
    let is_plain = path.split('/').all(|segment| {
        !matches!(segment, "" | "." | "..") && !segment.eq_ignore_ascii_case(".git")
    }) && relative
        .components()
        .all(|component| matches!(component, Component::Normal(_)));
    if is_plain {
        Ok(relative)
    } else {
        bail!("{path:?} is not a path inside the worktree")
    }
}

/// The content of `path` in the worktree at `root`, or `None` when no file is
/// there: nothing at all, a directory (such as a submodule), or anything else
/// that is not a file, like a named pipe that would never finish reading.
///
/// A symlink reads as its target's path, which is how git stores it, and is
/// never followed: a pull request cannot make the reviewer's editor show a
/// file from outside the worktree.
pub fn read_in_worktree(root: &Path, path: &str) -> Result<Option<Vec<u8>>> {
    let full_path = root.join(path_to_safe_relative(path)?);
    let metadata = match fs::symlink_metadata(&full_path) {
        Ok(metadata) => metadata,
        // A path under something that is now a file is not there either.
        Err(error) if matches!(error.kind(), ErrorKind::NotFound | ErrorKind::NotADirectory) => {
            return Ok(None);
        }
        Err(error) => return Err(error).with_context(|| format!("reading {path}")),
    };
    if metadata.file_type().is_symlink() {
        // The link is not followed, but the directories on the way to it are:
        // they must not lead out of the worktree either.
        ensure_inside(root, full_path.parent().unwrap_or(root), path)?;
        let target =
            fs::read_link(&full_path).with_context(|| format!("reading the link {path}"))?;
        return Ok(Some(target.to_string_lossy().into_owned().into_bytes()));
    }
    ensure_inside(root, &full_path, path)?;
    if !metadata.is_file() {
        return Ok(None);
    }
    fs::read(&full_path)
        .map(Some)
        .with_context(|| format!("reading {path}"))
}

/// Fails when `full_path` resolves outside `root`, as it does when a
/// directory on the way is a symlink out of the worktree.
fn ensure_inside(root: &Path, full_path: &Path, path: &str) -> Result<()> {
    let root = root
        .canonicalize()
        .with_context(|| format!("resolving {}", root.display()))?;
    let resolved = full_path
        .canonicalize()
        .with_context(|| format!("resolving {path}"))?;
    if resolved.starts_with(&root) {
        Ok(())
    } else {
        bail!("{path} resolves outside the worktree")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_relative_paths_are_safe() {
        assert_eq!(
            path_to_safe_relative("src/a.rs").unwrap(),
            Path::new("src/a.rs")
        );
    }

    #[test]
    fn empty_absolute_and_climbing_paths_are_refused() {
        for path in ["", "/etc/passwd", "../x", "a/../../x", "./a"] {
            assert!(path_to_safe_relative(path).is_err(), "{path:?}");
        }
    }

    #[test]
    fn paths_git_would_not_name_the_same_way_are_refused() {
        for path in ["a/./b", "a//b", "a/", "a/."] {
            assert!(path_to_safe_relative(path).is_err(), "{path:?}");
        }
        assert!(path_to_safe_relative(".github/workflows/ci.yml").is_ok());
    }

    #[test]
    fn the_repositorys_own_files_are_refused() {
        for path in [
            ".git",
            ".git/config",
            "sub/.git/HEAD",
            ".GIT/config",
            ".Git",
        ] {
            assert!(path_to_safe_relative(path).is_err(), "{path:?}");
        }
        for path in [".gitignore", ".github/x", "a/.gitattributes", "git/x"] {
            assert!(path_to_safe_relative(path).is_ok(), "{path:?}");
        }
    }

    #[test]
    fn a_directory_reads_as_nothing() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir(dir.path().join("submodule")).unwrap();
        assert_eq!(read_in_worktree(dir.path(), "submodule").unwrap(), None);
    }

    #[test]
    fn a_path_under_a_file_reads_as_nothing() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("a.txt"), "a").unwrap();
        assert_eq!(read_in_worktree(dir.path(), "a.txt/b.txt").unwrap(), None);
    }

    #[cfg(unix)]
    #[test]
    fn a_named_pipe_reads_as_nothing_instead_of_waiting() {
        let dir = tempfile::tempdir().unwrap();
        let status = std::process::Command::new("mkfifo")
            .arg(dir.path().join("pipe"))
            .status()
            .unwrap();
        assert!(status.success());
        assert_eq!(read_in_worktree(dir.path(), "pipe").unwrap(), None);
    }
}
