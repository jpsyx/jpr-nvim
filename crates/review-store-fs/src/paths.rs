//! Where a pull request's review state lives on disk.

use std::path::{Path, PathBuf};

use anyhow::{Result, bail};

/// Where a pull request's review state lives:
/// `<state home>/<app>/<owner>/<repo>/pr-<number>`. The state home is
/// `$XDG_STATE_HOME` when it is absolute (the XDG rule), else `~/.local/state`.
///
/// Fails when `owner` or `repo` could not be one directory name, so neither
/// can climb out of the state home.
pub fn state_dir(
    xdg_state_home: Option<&Path>,
    home: &Path,
    app: &str,
    owner: &str,
    repo: &str,
    number: u64,
) -> Result<PathBuf> {
    check_component("owner", owner)?;
    check_component("repository name", repo)?;
    let base = resolve_state_base(xdg_state_home, home).join(app);
    Ok(base.join(owner).join(repo).join(format!("pr-{number}")))
}

/// Where an unlinked local worktree review's state lives on disk.
///
/// Uses `<state home>/<app>/<owner>/<repo>/local-<branch_slug>-<hash8>` when
/// `owner_repo` is known, or
/// `<state home>/<app>/_local/<dir_slug>-<root_hash8>/local-<branch_slug>-<hash8>`
/// when no remote repository name is available.
pub fn local_state_dir(
    xdg_state_home: Option<&Path>,
    home: &Path,
    app: &str,
    owner_repo: Option<(&str, &str)>,
    worktree_root: &Path,
    branch: &str,
) -> Result<PathBuf> {
    let base = resolve_state_base(xdg_state_home, home).join(app);
    let repo_dir = if let Some((owner, repo)) = owner_repo {
        check_component("owner", owner)?;
        check_component("repository name", repo)?;
        base.join(owner).join(repo)
    } else {
        let root_name = worktree_root
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("repo");
        let dir_slug = sanitize_slug(root_name, 32, "repo");
        let root_hash = fnv1a_hash32(worktree_root.as_os_str().as_encoded_bytes());
        base.join("_local")
            .join(format!("{dir_slug}-{root_hash:08x}"))
    };
    let branch_slug = sanitize_slug(branch, 40, "branch");
    let mut hash_input = worktree_root.as_os_str().as_encoded_bytes().to_vec();
    hash_input.push(0);
    hash_input.extend_from_slice(branch.as_bytes());
    let branch_hash = fnv1a_hash32(&hash_input);
    Ok(repo_dir.join(format!("local-{branch_slug}-{branch_hash:08x}")))
}

fn resolve_state_base(xdg_state_home: Option<&Path>, home: &Path) -> PathBuf {
    xdg_state_home
        .filter(|path| path.is_absolute())
        .map_or_else(|| home.join(".local").join("state"), Path::to_path_buf)
}

fn sanitize_slug(raw: &str, max_len: usize, fallback: &str) -> String {
    let mut slug = String::new();
    let mut previous_was_dash = false;
    for ch in raw.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
            slug.push(ch);
            previous_was_dash = false;
        } else if !previous_was_dash {
            slug.push('-');
            previous_was_dash = true;
        }
        if slug.len() >= max_len {
            break;
        }
    }
    let trimmed = slug.trim_matches(['-', '.']);
    if trimmed.is_empty() {
        fallback.to_owned()
    } else {
        trimmed.to_owned()
    }
}

fn fnv1a_hash32(bytes: &[u8]) -> u32 {
    let mut hash = 0x811c_9dc5_u32;
    for &byte in bytes {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(0x0100_0193_u32);
    }
    hash
}

/// Refuses a value that `Path::join` would not treat as one plain directory:
/// empty, `.`, `..`, or anything holding a path separator (an absolute value
/// would even replace the base).
fn check_component(label: &str, value: &str) -> Result<()> {
    let is_one_plain_name = !matches!(value, "" | "." | "..") && !value.contains(['/', '\\']);
    if !is_one_plain_name {
        bail!("the {label} {value:?} is not a plain name, so it cannot name a state directory");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn widgets_dir(xdg_state_home: Option<&Path>) -> PathBuf {
        state_dir(
            xdg_state_home,
            Path::new("/home/u"),
            "jpr",
            "octo",
            "widgets",
            7,
        )
        .unwrap()
    }

    fn error_for(owner: &str, repo: &str) -> String {
        let error = state_dir(None, Path::new("/home/u"), "jpr", owner, repo, 7).unwrap_err();
        format!("{error:#}")
    }

    #[test]
    fn state_dir_prefers_an_absolute_xdg_state_home() {
        assert_eq!(
            widgets_dir(Some(Path::new("/x/state"))),
            PathBuf::from("/x/state/jpr/octo/widgets/pr-7")
        );
    }

    #[test]
    fn state_dir_ignores_a_relative_xdg_state_home() {
        assert_eq!(
            widgets_dir(Some(Path::new("rel"))),
            PathBuf::from("/home/u/.local/state/jpr/octo/widgets/pr-7")
        );
    }

    #[test]
    fn state_dir_defaults_under_home() {
        assert_eq!(
            widgets_dir(None),
            PathBuf::from("/home/u/.local/state/jpr/octo/widgets/pr-7")
        );
    }

    #[test]
    fn state_dir_rejects_components_that_escape_or_vanish() {
        for owner in ["", ".", "..", "a/b", "/etc", "a\\b"] {
            assert!(error_for(owner, "widgets").contains("owner"), "{owner:?}");
        }
        for repo in ["", ".", "..", "x/..", "/etc"] {
            assert!(
                error_for("octo", repo).contains("repository name"),
                "{repo:?}"
            );
        }
    }

    #[test]
    fn state_dir_names_the_rejected_component() {
        assert!(
            error_for("..", "widgets").contains("\"..\""),
            "{}",
            error_for("..", "widgets")
        );
    }

    #[test]
    fn state_dir_accepts_dotted_names() {
        assert!(state_dir(None, Path::new("/h"), "jpr", "octo.org", ".github", 1).is_ok());
    }

    #[test]
    fn local_state_dir_places_repo_scoped_and_remote_less_worktrees_in_collision_free_paths() {
        let with_repo = local_state_dir(
            Some(Path::new("/x/state")),
            Path::new("/home/u"),
            "jpr",
            Some(("octo", "widgets")),
            Path::new("/work/widgets"),
            "feat/auth",
        )
        .unwrap();
        let with_repo_text = with_repo.to_string_lossy();
        assert!(
            with_repo_text.starts_with("/x/state/jpr/octo/widgets/local-feat-auth-"),
            "{with_repo_text}"
        );

        let different_case = local_state_dir(
            Some(Path::new("/x/state")),
            Path::new("/home/u"),
            "jpr",
            Some(("octo", "widgets")),
            Path::new("/work/widgets"),
            "feat/Auth",
        )
        .unwrap();
        assert_ne!(with_repo, different_case);

        let different_worktree = local_state_dir(
            Some(Path::new("/x/state")),
            Path::new("/home/u"),
            "jpr",
            Some(("octo", "widgets")),
            Path::new("/work/widgets-2"),
            "feat/auth",
        )
        .unwrap();
        assert_ne!(with_repo, different_worktree);

        let without_repo = local_state_dir(
            Some(Path::new("/x/state")),
            Path::new("/home/u"),
            "jpr",
            None,
            Path::new("/work/my repo"),
            "///",
        )
        .unwrap();
        let without_repo_text = without_repo.to_string_lossy();
        assert!(
            without_repo_text.contains("/_local/my-repo-")
                && without_repo_text.contains("/local-branch-"),
            "{without_repo_text}"
        );

        assert!(
            local_state_dir(
                None,
                Path::new("/h"),
                "jpr",
                Some(("..", "widgets")),
                Path::new("/w"),
                "main",
            )
            .is_err()
        );
    }
}
