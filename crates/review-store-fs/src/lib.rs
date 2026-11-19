//! The file-backed review store: one directory per pull request and one JSON
//! file per concern, each written atomically (temporary file, then rename) so
//! a crash leaves either the old file or the new one, never half of either.

use std::fs;
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use review_core::ports::{ReviewStore, SessionRecord, StoreSnapshot};
use review_model::ChangedFile;
use serde::Serialize;
use serde::de::DeserializeOwned;

/// The daemon and what it last saw.
pub const SESSION_FILE: &str = "session.json";
/// The changed files and their viewed state.
pub const VIEWED_FILE: &str = "viewed.json";

/// Where a pull request's review state lives:
/// `<state home>/<app>/<owner>/<repo>/pr-<number>`. The state home is
/// `$XDG_STATE_HOME` when it is absolute (the XDG rule), else `~/.local/state`.
#[must_use]
pub fn state_dir(
    xdg_state_home: Option<&Path>,
    home: &Path,
    app: &str,
    owner: &str,
    repo: &str,
    number: u64,
) -> PathBuf {
    let base = xdg_state_home
        .filter(|path| path.is_absolute())
        .map_or_else(|| home.join(".local").join("state"), Path::to_path_buf);
    base.join(app)
        .join(owner)
        .join(repo)
        .join(format!("pr-{number}"))
}

/// A [`ReviewStore`] in one directory.
#[derive(Debug, Clone)]
pub struct FsStore {
    dir: PathBuf,
}

impl FsStore {
    /// A store in `dir`, created on the first save.
    #[must_use]
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    /// The directory this store writes.
    #[must_use]
    pub fn dir(&self) -> &Path {
        &self.dir
    }
}

impl ReviewStore for FsStore {
    fn load(&self) -> Result<StoreSnapshot> {
        let session: Option<SessionRecord> = read_json(&self.dir.join(SESSION_FILE))?;
        let files: Option<Vec<ChangedFile>> = read_json(&self.dir.join(VIEWED_FILE))?;
        Ok(StoreSnapshot {
            session: session.unwrap_or_default(),
            files: files.unwrap_or_default(),
        })
    }

    fn save(&self, snapshot: &StoreSnapshot) -> Result<()> {
        fs::create_dir_all(&self.dir)
            .with_context(|| format!("creating {}", self.dir.display()))?;
        write_json_atomic(&self.dir.join(SESSION_FILE), &snapshot.session)?;
        write_json_atomic(&self.dir.join(VIEWED_FILE), &snapshot.files)
    }
}

/// Reads `path` as JSON; a missing file is `None`, a corrupt one an error.
fn read_json<T: DeserializeOwned>(path: &Path) -> Result<Option<T>> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .with_context(|| format!("reading {} (fix or delete the file)", path.display())),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("reading {}", path.display())),
    }
}

/// Writes `value` as pretty JSON to a temporary file beside `path`, then
/// renames it over `path`.
fn write_json_atomic<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let temporary = path.with_extension("json.tmp");
    let mut bytes = serde_json::to_vec_pretty(value).context("encoding review state")?;
    bytes.push(b'\n');
    let mut file =
        fs::File::create(&temporary).with_context(|| format!("writing {}", temporary.display()))?;
    file.write_all(&bytes)
        .with_context(|| format!("writing {}", temporary.display()))?;
    file.sync_all()
        .with_context(|| format!("flushing {}", temporary.display()))?;
    fs::rename(&temporary, path).with_context(|| format!("replacing {}", path.display()))
}

#[cfg(test)]
mod tests {
    use std::fs;

    use review_core::contract::check_review_store;

    use super::*;

    #[test]
    fn passes_the_review_store_contract() {
        let dir = tempfile::tempdir().unwrap();
        check_review_store(&FsStore::new(dir.path().join("pr-7")));
    }

    #[test]
    fn a_missing_directory_loads_as_empty_and_creates_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let store = FsStore::new(dir.path().join("absent"));
        assert_eq!(store.load().unwrap(), StoreSnapshot::default());
        assert!(!dir.path().join("absent").exists());
    }

    #[test]
    fn a_corrupt_file_is_an_error_that_names_it() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(SESSION_FILE), "{not json").unwrap();
        let error = FsStore::new(dir.path()).load().unwrap_err();
        assert!(format!("{error:#}").contains("session.json"), "{error:#}");
    }

    #[test]
    fn save_leaves_no_temporary_files() {
        let dir = tempfile::tempdir().unwrap();
        FsStore::new(dir.path())
            .save(&StoreSnapshot::default())
            .unwrap();
        let mut names: Vec<String> = fs::read_dir(dir.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names, ["session.json", "viewed.json"]);
    }

    #[test]
    fn the_session_file_uses_camel_case_keys() {
        let dir = tempfile::tempdir().unwrap();
        let mut snapshot = StoreSnapshot::default();
        snapshot.session.last_synced_at = Some(5);
        FsStore::new(dir.path()).save(&snapshot).unwrap();
        let text = fs::read_to_string(dir.path().join(SESSION_FILE)).unwrap();
        assert!(text.contains("\"lastSyncedAt\": 5"), "{text}");
    }

    #[test]
    fn state_dir_prefers_an_absolute_xdg_state_home() {
        assert_eq!(
            state_dir(
                Some(Path::new("/x/state")),
                Path::new("/home/u"),
                "jpr",
                "octo",
                "widgets",
                7
            ),
            PathBuf::from("/x/state/jpr/octo/widgets/pr-7")
        );
    }

    #[test]
    fn state_dir_ignores_a_relative_xdg_state_home() {
        assert_eq!(
            state_dir(
                Some(Path::new("rel")),
                Path::new("/home/u"),
                "jpr",
                "octo",
                "widgets",
                7
            ),
            PathBuf::from("/home/u/.local/state/jpr/octo/widgets/pr-7")
        );
    }

    #[test]
    fn state_dir_defaults_under_home() {
        assert_eq!(
            state_dir(None, Path::new("/home/u"), "jpr", "octo", "widgets", 7),
            PathBuf::from("/home/u/.local/state/jpr/octo/widgets/pr-7")
        );
    }
}
