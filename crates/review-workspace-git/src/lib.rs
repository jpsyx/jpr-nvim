//! A pull request's worktree: checking it out, and reading its files and
//! history. Generic: it knows git and gh, and nothing about any editor.

mod cache;
mod checkout;
mod custom;
mod default_checkout;
mod fast_forward;
mod git_output;
mod local_ref;
mod process;
mod push;
mod repo;
mod status;
#[cfg(test)]
mod test_support;
mod unattended;
mod workspace;
mod worktree_path;
mod worktree_reuse;

pub use cache::{ensure_managed_clone, managed_repo_dir, parse_owner_repo_from_remote_url};
pub use checkout::{WorktreeCommand, checkout_pr, render_custom};
pub use custom::last_path_line;
pub use default_checkout::default_worktree_path;
pub use local_ref::{
    BranchProbe, LocalWorktreeInfo, inspect_local_worktree, read_current_branch,
    resolve_default_base_branch, validate_git_ref,
};
pub use repo::main_repo_root;
pub use workspace::{FETCH_TIMEOUT, GitWorkspace};
pub use worktree_reuse::{
    WorktreeEntry, find_existing_pr_worktree, parse_worktree_list_porcelain,
    select_reusable_worktree,
};

#[cfg(test)]
mod cache_tests {
    use std::fs;
    use std::path::{Path, PathBuf};

    use crate::cache::ensure_managed_clone_with;
    use crate::managed_repo_dir;
    use crate::test_support::{git, repo};

    #[test]
    fn managed_repo_dir_uses_absolute_xdg_or_home_cache_and_rejects_unsafe_segments() {
        let home = Path::new("/Users/octo");
        assert_eq!(
            managed_repo_dir(Some(Path::new("/var/cache")), home, "jpr", "acme", "widgets")
                .unwrap(),
            PathBuf::from("/var/cache/jpr/repos/acme/widgets")
        );
        assert_eq!(
            managed_repo_dir(None, home, "jpr", "acme", "widgets").unwrap(),
            PathBuf::from("/Users/octo/.cache/jpr/repos/acme/widgets")
        );
        assert_eq!(
            managed_repo_dir(Some(Path::new("relative")), home, "jpr", "acme", "widgets").unwrap(),
            PathBuf::from("/Users/octo/.cache/jpr/repos/acme/widgets")
        );
        for bad in ["", ".", "..", "a/b", "a\\b", "has space"] {
            assert!(managed_repo_dir(None, home, "jpr", bad, "widgets").is_err());
            assert!(managed_repo_dir(None, home, "jpr", "acme", bad).is_err());
        }
    }

    #[test]
    fn ensure_managed_clone_reuses_matching_repo_and_refuses_unrelated_dirs() {
        let dir = repo();
        let root = dir.path().join("widgets");
        git(
            &root,
            &["remote", "add", "origin", "https://github.com/Acme/Widgets.git"],
        );
        let reused = ensure_managed_clone_with(&root, "acme", "widgets", |_, _| {
            panic!("should reuse existing clone without cloning")
        })
        .unwrap();
        assert_eq!(reused.canonicalize().unwrap(), root.canonicalize().unwrap());

        let wrong = ensure_managed_clone_with(&root, "other", "widgets", |_, _| {
            panic!("should refuse wrong remote without cloning")
        })
        .unwrap_err();
        assert!(format!("{wrong:#}").contains("other/widgets"));
        assert!(root.join("a.txt").exists(), "must not delete wrong-remote repo");

        let stray = dir.path().join("stray");
        fs::create_dir_all(&stray).unwrap();
        fs::write(stray.join("keep.txt"), "mine").unwrap();
        let stray_err = ensure_managed_clone_with(&stray, "acme", "widgets", |_, _| {
            panic!("should refuse non-git directory")
        })
        .unwrap_err();
        assert!(format!("{stray_err:#}").contains(&stray.display().to_string()));
        assert!(stray.join("keep.txt").exists(), "must not delete stray dir");
    }

    #[test]
    fn ensure_managed_clone_cleans_up_newly_created_partial_dir_on_failure() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("repos").join("acme").join("widgets");
        let err = ensure_managed_clone_with(&target, "acme", "widgets", |_slug, dest| {
            fs::create_dir_all(dest)?;
            fs::write(dest.join("partial"), "junk")?;
            anyhow::bail!("simulated clone failure")
        })
        .unwrap_err();
        assert!(format!("{err:#}").contains("simulated clone failure"));
        assert!(!target.exists(), "partial clone dir must be removed on failure");
    }
}
