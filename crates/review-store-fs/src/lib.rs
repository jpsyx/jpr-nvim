//! The file-backed review store: one directory per pull request and one JSON
//! file per concern. Each file is a versioned envelope (see the `format` module),
//! written atomically: a temporary file unique to the write, then a rename and
//! a directory flush. A crash leaves each file either old or new, never half
//! of either, and concurrent writers never interleave inside one file.

mod atomic;
mod format;
mod paths;

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use review_core::ports::{ReviewStore, StoreSnapshot};

pub use format::{SESSION_VERSION, VIEWED_VERSION};
pub use paths::state_dir;

/// The daemon and what it last saw.
pub const SESSION_FILE: &str = "session.json";
/// The changed files and their viewed state.
pub const VIEWED_FILE: &str = "viewed.json";

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
        let session = load_file(&self.dir.join(SESSION_FILE), format::decode_session)?;
        let files = load_file(&self.dir.join(VIEWED_FILE), format::decode_files)?;
        Ok(StoreSnapshot {
            session: session.unwrap_or_default(),
            files: files.unwrap_or_default(),
        })
    }

    fn save(&self, snapshot: &StoreSnapshot) -> Result<()> {
        // Check both files before writing either, so a refusal changes nothing.
        refuse_newer_file(&self.dir.join(SESSION_FILE), SESSION_VERSION)?;
        refuse_newer_file(&self.dir.join(VIEWED_FILE), VIEWED_VERSION)?;
        fs::create_dir_all(&self.dir)
            .with_context(|| format!("creating {}", self.dir.display()))?;
        let session = format::encode_session(&snapshot.session)?;
        atomic::write_atomic(&self.dir, SESSION_FILE, &session)?;
        let files = format::encode_files(&snapshot.files)?;
        atomic::write_atomic(&self.dir, VIEWED_FILE, &files)
    }
}

/// Decodes `path` with `decode`; a missing file is `None`, a corrupt or
/// newer one an error naming it.
fn load_file<T>(path: &Path, decode: fn(&[u8]) -> Result<T>) -> Result<Option<T>> {
    let Some(bytes) = atomic::read_bytes(path)? else {
        return Ok(None);
    };
    decode(&bytes)
        .map(Some)
        .with_context(|| format!("reading {}", path.display()))
}

/// Fails when a newer build wrote `path`, so saving never drops what it added.
/// A missing file, or one without a readable version, is left for the save to replace.
fn refuse_newer_file(path: &Path, known: u32) -> Result<()> {
    let Some(bytes) = atomic::read_bytes(path)? else {
        return Ok(());
    };
    let Ok(found) = format::stored_version(&bytes) else {
        return Ok(());
    };
    format::refuse_newer(found, known).with_context(|| format!("saving {}", path.display()))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::thread;

    use review_core::contract::check_review_store;
    use review_core::fakes::changed_file;
    use review_model::ViewedState;

    use super::*;

    fn file_names(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    /// A snapshot whose size varies with `round`, so a torn file cannot parse.
    fn snapshot_for_round(round: usize) -> StoreSnapshot {
        let mut snapshot = StoreSnapshot::default();
        snapshot.session.worktree = Some("w".repeat(round % 13));
        snapshot.files = (0..round % 7)
            .map(|index| changed_file(&format!("src/{index}.rs"), ViewedState::Viewed))
            .collect();
        snapshot
    }

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
        assert_eq!(file_names(dir.path()), ["session.json", "viewed.json"]);
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
    fn loading_a_newer_file_names_it_and_both_versions() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(
            dir.path().join(VIEWED_FILE),
            r#"{"version": 9, "files": []}"#,
        )
        .unwrap();
        let message = format!("{:#}", FsStore::new(dir.path()).load().unwrap_err());
        assert!(message.contains("viewed.json"), "{message}");
        assert!(
            message.contains("version 9") && message.contains("version 1"),
            "{message}"
        );
    }

    #[test]
    fn save_never_overwrites_a_newer_file() {
        let dir = tempfile::tempdir().unwrap();
        let newer = r#"{"version": 9, "agentSession": "kept"}"#;
        fs::write(dir.path().join(SESSION_FILE), newer).unwrap();
        let error = FsStore::new(dir.path())
            .save(&StoreSnapshot::default())
            .unwrap_err();
        assert!(format!("{error:#}").contains("version 9"), "{error:#}");
        assert_eq!(
            fs::read_to_string(dir.path().join(SESSION_FILE)).unwrap(),
            newer
        );
        assert!(!dir.path().join(VIEWED_FILE).exists());
    }

    #[test]
    fn concurrent_saves_never_tear_a_file_or_leave_temporaries() {
        let dir = tempfile::tempdir().unwrap();
        let store = FsStore::new(dir.path());
        store.save(&snapshot_for_round(0)).unwrap();
        let is_writing_done = AtomicBool::new(false);
        let (save_errors, load_errors) = thread::scope(|scope| {
            let save_rounds = |offset: usize| {
                let store = &store;
                move || {
                    (0..100)
                        .filter_map(|round| store.save(&snapshot_for_round(round + offset)).err())
                        .map(|error| format!("{error:#}"))
                        .collect::<Vec<_>>()
                }
            };
            let first_writer = scope.spawn(save_rounds(0));
            let second_writer = scope.spawn(save_rounds(1));
            let reader = scope.spawn(|| {
                let mut errors = Vec::new();
                while !is_writing_done.load(Ordering::Relaxed) {
                    if let Err(error) = store.load() {
                        errors.push(format!("{error:#}"));
                    }
                }
                errors
            });
            let mut save_errors = first_writer.join().unwrap();
            save_errors.extend(second_writer.join().unwrap());
            is_writing_done.store(true, Ordering::Relaxed);
            (save_errors, reader.join().unwrap())
        });
        assert!(
            save_errors.is_empty(),
            "{} failed saves: {:?}",
            save_errors.len(),
            save_errors.first()
        );
        assert!(
            load_errors.is_empty(),
            "{} failed loads: {:?}",
            load_errors.len(),
            load_errors.first()
        );
        assert_eq!(file_names(dir.path()), ["session.json", "viewed.json"]);
    }
}
