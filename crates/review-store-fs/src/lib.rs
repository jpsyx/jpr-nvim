//! The file-backed review store: one directory per pull request and one JSON
//! file per concern (`session.json`, `viewed.json`, `github.json`,
//! `local.json`) plus an append-only `rounds.jsonl` log. Each JSON file is a
//! versioned envelope (see the `format` module), written atomically: a
//! temporary file unique to the write, then a rename and a directory flush. A
//! crash leaves each file either old or new, never half of either, and
//! concurrent writers never interleave inside one file.

mod atomic;
mod format;
mod lock;
mod paths;
mod retarget;

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};

use anyhow::{Context, Result};
use review_core::ports::{LocalStoreState, ReviewStore, StoreSnapshot};
use review_model::AgentRound;

pub use format::{
    GITHUB_VERSION, LOCAL_VERSION, OLDEST_GITHUB_VERSION, OLDEST_SESSION_VERSION, SESSION_VERSION,
    VIEWED_VERSION,
};
pub use lock::LOCAL_LOCK_FILE;
pub use paths::{local_state_dir, state_dir};
pub use retarget::StateRootConfig;

/// The file, in a pull request's state directory, that holds the daemon and
/// what it last saw.
pub const SESSION_FILE: &str = "session.json";
/// The file, in a pull request's state directory, that holds the changed files
/// and their viewed state.
pub const VIEWED_FILE: &str = "viewed.json";
/// The file, in a pull request's state directory, that holds what the engine
/// still owes GitHub, such as viewed marks it could not send.
pub const GITHUB_FILE: &str = "github.json";
/// The file, in a pull request's state directory, that holds local-only
/// threads and agent dispatch counters.
pub const LOCAL_FILE: &str = "local.json";
/// The append-only JSON Lines log of delivered agent rounds in a pull
/// request's state directory.
pub const ROUNDS_FILE: &str = "rounds.jsonl";

/// A [`ReviewStore`] in one directory, optionally retargetable from a local
/// review directory to a pull request's canonical state directory.
#[derive(Debug, Clone)]
pub struct FsStore {
    dir: Arc<RwLock<PathBuf>>,
    state_root: Option<StateRootConfig>,
    pending_retired_dir: Arc<Mutex<Option<PathBuf>>>,
}

impl FsStore {
    /// A store in `dir`, created on the first save.
    #[must_use]
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self {
            dir: Arc::new(RwLock::new(dir.into())),
            state_root: None,
            pending_retired_dir: Arc::new(Mutex::new(None)),
        }
    }

    /// A store in `dir` that can retarget itself to `pr-<number>` under `state_root`.
    #[must_use]
    pub fn new_with_root(dir: impl Into<PathBuf>, state_root: StateRootConfig) -> Self {
        Self {
            dir: Arc::new(RwLock::new(dir.into())),
            state_root: Some(state_root),
            pending_retired_dir: Arc::new(Mutex::new(None)),
        }
    }

    /// The directory this store currently writes.
    #[must_use]
    pub fn current_dir(&self) -> PathBuf {
        self.dir
            .read()
            .expect("FsStore directory lock is poisoned")
            .clone()
    }

    /// Acquires `local.lock`, loads `local.json` (or default when absent),
    /// applies `mutator`, and writes `local.json` atomically before releasing
    /// the lock.
    pub fn mutate_local_locked<T>(
        &self,
        mutator: impl FnOnce(&mut LocalStoreState) -> Result<T>,
    ) -> Result<T> {
        let dir = self.current_dir();
        lock::with_local_lock(&dir, || {
            let local_path = dir.join(LOCAL_FILE);
            refuse_newer_file(&local_path, LOCAL_VERSION)?;
            let mut local = load_file(&local_path, format::decode_local)?.unwrap_or_default();
            let output = mutator(&mut local)?;
            atomic::write_atomic(&dir, LOCAL_FILE, &format::encode_local(&local)?)?;
            Ok(output)
        })
    }
}

impl ReviewStore for FsStore {
    fn load(&self) -> Result<StoreSnapshot> {
        let dir = self.current_dir();
        load_snapshot_from_dir(&dir)
    }

    fn save(&self, snapshot: &StoreSnapshot) -> Result<()> {
        let dir = self.current_dir();
        // Check every file before writing any, so a refusal changes nothing.
        refuse_newer_file(&dir.join(SESSION_FILE), SESSION_VERSION)?;
        refuse_newer_file(&dir.join(VIEWED_FILE), VIEWED_VERSION)?;
        refuse_newer_file(&dir.join(GITHUB_FILE), GITHUB_VERSION)?;
        refuse_newer_file(&dir.join(LOCAL_FILE), LOCAL_VERSION)?;
        let [github, session, viewed, local] = snapshot_to_encoded_files(snapshot)?;
        fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
        for (name, bytes) in [github, session, viewed] {
            atomic::write_atomic(&dir, name, &bytes)?;
        }
        lock::with_local_lock(&dir, || {
            refuse_newer_file(&dir.join(LOCAL_FILE), LOCAL_VERSION)?;
            atomic::write_atomic(&dir, local.0, &local.1)
        })
    }

    fn append_round(&self, round: &AgentRound) -> Result<()> {
        let dir = self.current_dir();
        let path = dir.join(ROUNDS_FILE);
        let mut line = serde_json::to_string(round)
            .with_context(|| format!("encoding round for {}", path.display()))?;
        line.push('\n');
        lock::with_local_lock(&dir, || {
            let mut file = open_rounds_append(&path)?;
            let previous_len = file
                .metadata()
                .with_context(|| format!("reading {} metadata", path.display()))?
                .len();
            if let Err(error) = file
                .write_all(line.as_bytes())
                .and_then(|()| file.sync_all())
            {
                let _ = file.set_len(previous_len);
                return Err(error).with_context(|| format!("appending {}", path.display()));
            }
            atomic::sync_dir(&dir)
        })
    }

    fn rounds(&self) -> Result<Vec<AgentRound>> {
        let dir = self.current_dir();
        let path = dir.join(ROUNDS_FILE);
        let Some(bytes) = atomic::read_bytes(&path)? else {
            return Ok(Vec::new());
        };
        let text = String::from_utf8(bytes)
            .with_context(|| format!("reading {} as UTF-8", path.display()))?;
        text.lines()
            .enumerate()
            .filter_map(|(index, line)| {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    return None;
                }
                let line_number = index + 1;
                Some(
                    serde_json::from_str(trimmed)
                        .with_context(|| format!("parsing {} line {line_number}", path.display())),
                )
            })
            .collect()
    }

    fn retarget_to_pr(
        &self,
        owner: &str,
        repo: &str,
        number: u64,
    ) -> Result<Option<StoreSnapshot>> {
        let Some(state_root) = self.state_root.as_ref() else {
            return Ok(None);
        };
        let old_dir = self.current_dir();
        let Some((target_dir, existing)) =
            retarget::prepare_retarget_to_pr(state_root, &old_dir, owner, repo, number)?
        else {
            return Ok(None);
        };
        *self
            .dir
            .write()
            .expect("FsStore directory lock is poisoned") = target_dir;
        *self
            .pending_retired_dir
            .lock()
            .expect("FsStore retired-dir lock is poisoned") = Some(old_dir);
        Ok(existing)
    }

    fn finalize_retarget(&self) -> Result<()> {
        let retired = self
            .pending_retired_dir
            .lock()
            .expect("FsStore retired-dir lock is poisoned")
            .take();
        if let Some(old_dir) = retired {
            retarget::retire_old_local_dir(&old_dir);
        }
        Ok(())
    }
}

pub(crate) fn load_snapshot_from_dir(dir: &Path) -> Result<StoreSnapshot> {
    let session = load_file(&dir.join(SESSION_FILE), format::decode_session)?;
    let files = load_file(&dir.join(VIEWED_FILE), format::decode_files)?;
    let registry = load_file(&dir.join(GITHUB_FILE), format::decode_registry)?;
    let local = load_file(&dir.join(LOCAL_FILE), format::decode_local)?;
    Ok(StoreSnapshot {
        session: session.unwrap_or_default(),
        files: files.unwrap_or_default(),
        registry: registry.unwrap_or_default(),
        local: local.unwrap_or_default(),
    })
}

/// Every file of `snapshot`, encoded before any is written, in the order
/// `save` writes them.
///
/// `github.json` goes first. The queue only shrinks after GitHub accepts a
/// mark and only grows for a mark held locally, so a crash between files can
/// resend a mark but never lose a refused one or revive one the reviewer undid.
fn snapshot_to_encoded_files(snapshot: &StoreSnapshot) -> Result<[(&'static str, Vec<u8>); 4]> {
    Ok([
        (GITHUB_FILE, format::encode_registry(&snapshot.registry)?),
        (SESSION_FILE, format::encode_session(&snapshot.session)?),
        (VIEWED_FILE, format::encode_files(&snapshot.files)?),
        (LOCAL_FILE, format::encode_local(&snapshot.local)?),
    ])
}

/// Opens `path` for append, creating it with owner-only (`0600`) permissions on Unix.
pub(crate) fn open_rounds_append(path: &Path) -> Result<fs::File> {
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
        .open(path)
        .with_context(|| format!("opening {}", path.display()))
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
pub(crate) fn refuse_newer_file(path: &Path, known: u32) -> Result<()> {
    let Some(bytes) = atomic::read_bytes(path)? else {
        return Ok(());
    };
    let Ok(found) = format::stored_version(&bytes) else {
        return Ok(());
    };
    format::refuse_newer(found, known).with_context(|| format!("saving {}", path.display()))
}

#[cfg(test)]
mod concurrency_tests;
#[cfg(test)]
mod tests;
