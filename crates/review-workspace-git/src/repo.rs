use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

use crate::process::run;

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{git, repo};

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
}
