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
    let base = xdg_state_home
        .filter(|path| path.is_absolute())
        .map_or_else(|| home.join(".local").join("state"), Path::to_path_buf);
    Ok(base
        .join(app)
        .join(owner)
        .join(repo)
        .join(format!("pr-{number}")))
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
}
