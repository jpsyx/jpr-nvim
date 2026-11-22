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

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use review_core::ports::{LocalStoreState, ReviewStore, StoreSnapshot};
use review_model::AgentRound;

pub use format::{
    GITHUB_VERSION, LOCAL_VERSION, OLDEST_GITHUB_VERSION, OLDEST_SESSION_VERSION, SESSION_VERSION,
    VIEWED_VERSION,
};
pub use lock::LOCAL_LOCK_FILE;
pub use paths::state_dir;

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

    /// Acquires `local.lock`, loads `local.json` (or default when absent),
    /// applies `mutator`, and writes `local.json` atomically before releasing
    /// the lock.
    pub fn mutate_local_locked<T>(
        &self,
        mutator: impl FnOnce(&mut LocalStoreState) -> Result<T>,
    ) -> Result<T> {
        lock::with_local_lock(&self.dir, || {
            let local_path = self.dir.join(LOCAL_FILE);
            refuse_newer_file(&local_path, LOCAL_VERSION)?;
            let mut local = load_file(&local_path, format::decode_local)?.unwrap_or_default();
            let output = mutator(&mut local)?;
            atomic::write_atomic(&self.dir, LOCAL_FILE, &format::encode_local(&local)?)?;
            Ok(output)
        })
    }
}

impl ReviewStore for FsStore {
    fn load(&self) -> Result<StoreSnapshot> {
        let session = load_file(&self.dir.join(SESSION_FILE), format::decode_session)?;
        let files = load_file(&self.dir.join(VIEWED_FILE), format::decode_files)?;
        let registry = load_file(&self.dir.join(GITHUB_FILE), format::decode_registry)?;
        let local = load_file(&self.dir.join(LOCAL_FILE), format::decode_local)?;
        Ok(StoreSnapshot {
            session: session.unwrap_or_default(),
            files: files.unwrap_or_default(),
            registry: registry.unwrap_or_default(),
            local: local.unwrap_or_default(),
        })
    }

    fn save(&self, snapshot: &StoreSnapshot) -> Result<()> {
        // Check every file before writing any, so a refusal changes nothing.
        refuse_newer_file(&self.dir.join(SESSION_FILE), SESSION_VERSION)?;
        refuse_newer_file(&self.dir.join(VIEWED_FILE), VIEWED_VERSION)?;
        refuse_newer_file(&self.dir.join(GITHUB_FILE), GITHUB_VERSION)?;
        refuse_newer_file(&self.dir.join(LOCAL_FILE), LOCAL_VERSION)?;
        let [github, session, viewed, local] = snapshot_to_encoded_files(snapshot)?;
        fs::create_dir_all(&self.dir)
            .with_context(|| format!("creating {}", self.dir.display()))?;
        for (name, bytes) in [github, session, viewed] {
            atomic::write_atomic(&self.dir, name, &bytes)?;
        }
        lock::with_local_lock(&self.dir, || {
            refuse_newer_file(&self.dir.join(LOCAL_FILE), LOCAL_VERSION)?;
            atomic::write_atomic(&self.dir, local.0, &local.1)
        })
    }

    fn append_round(&self, round: &AgentRound) -> Result<()> {
        let path = self.dir.join(ROUNDS_FILE);
        let mut line = serde_json::to_string(round)
            .with_context(|| format!("encoding round for {}", path.display()))?;
        line.push('\n');
        lock::with_local_lock(&self.dir, || {
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
            atomic::sync_dir(&self.dir)
        })
    }

    fn rounds(&self) -> Result<Vec<AgentRound>> {
        let path = self.dir.join(ROUNDS_FILE);
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
fn open_rounds_append(path: &Path) -> Result<fs::File> {
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
    use review_model::{
        AgentRoundKind, AgentThreadState, Anchor, Message, Origin, Thread, ThreadState, ViewedState,
    };

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
        snapshot.registry.queued_viewed = (0..round % 5)
            .map(|index| (format!("src/{index}.rs"), index % 2 == 0))
            .collect();
        snapshot
    }

    fn create_sample_local_thread(index: u64) -> Thread {
        Thread {
            id: format!("loc-{index}"),
            origin: Origin::Local,
            anchor: Anchor::line("src/lib.rs", index),
            state: ThreadState::Open,
            outdated: false,
            messages: vec![Message::create_with_sync(
                &format!("loc-m-{index}"),
                "reviewer",
                "Check invariant",
                "2026-11-21T00:00:00Z",
                None,
            )],
            agent: Some(AgentThreadState::Unsent),
            promoted_to: None,
        }
    }

    #[test]
    fn the_queue_is_written_before_the_files_it_corrects() {
        let encoded = snapshot_to_encoded_files(&StoreSnapshot::default()).unwrap();
        let names = encoded.map(|(name, _)| name);
        assert_eq!(names[0], GITHUB_FILE);
        let mut sorted = names;
        sorted.sort_unstable();
        assert_eq!(sorted, [GITHUB_FILE, LOCAL_FILE, SESSION_FILE, VIEWED_FILE]);
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
        assert!(format!("{error:#}").contains(SESSION_FILE), "{error:#}");
    }

    #[test]
    fn save_leaves_no_temporary_files() {
        let dir = tempfile::tempdir().unwrap();
        FsStore::new(dir.path())
            .save(&StoreSnapshot::default())
            .unwrap();
        assert_eq!(
            file_names(dir.path()),
            [GITHUB_FILE, LOCAL_FILE, SESSION_FILE, VIEWED_FILE]
        );
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
        assert!(message.contains(VIEWED_FILE), "{message}");
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
        assert!(!dir.path().join(GITHUB_FILE).exists());
        assert!(!dir.path().join(LOCAL_FILE).exists());
    }

    #[test]
    fn save_refuses_newer_local_file_without_writing_other_files() {
        let dir = tempfile::tempdir().unwrap();
        let newer = r#"{"version": 9, "nextLocalId": 50}"#;
        fs::write(dir.path().join(LOCAL_FILE), newer).unwrap();
        let error = FsStore::new(dir.path())
            .save(&StoreSnapshot::default())
            .unwrap_err();
        let message = format!("{error:#}");
        assert!(
            message.contains("version 9") && message.contains(LOCAL_FILE),
            "{message}"
        );
        assert_eq!(
            fs::read_to_string(dir.path().join(LOCAL_FILE)).unwrap(),
            newer
        );
        assert!(!dir.path().join(GITHUB_FILE).exists());
        assert!(!dir.path().join(SESSION_FILE).exists());
        assert!(!dir.path().join(VIEWED_FILE).exists());
        assert!(!dir.path().join(LOCAL_LOCK_FILE).exists());
    }

    #[test]
    fn a_newer_github_file_blocks_every_write() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(GITHUB_FILE), r#"{"version": 9}"#).unwrap();
        let error = FsStore::new(dir.path())
            .save(&StoreSnapshot::default())
            .unwrap_err();
        assert!(format!("{error:#}").contains(GITHUB_FILE), "{error:#}");
        assert!(!dir.path().join(SESSION_FILE).exists());
    }

    #[test]
    fn rounds_jsonl_appends_one_json_line_per_round_and_ignores_blank_lines() {
        let dir = tempfile::tempdir().unwrap();
        let store = FsStore::new(dir.path());
        assert!(store.rounds().unwrap().is_empty());

        let round_1 = AgentRound {
            round: 1,
            kind: AgentRoundKind::Send,
            thread_ids: vec!["loc-1".into()],
            prompt: "Address loc-1".into(),
            sent_at: 100,
        };
        let round_2 = AgentRound {
            round: 2,
            kind: AgentRoundKind::Prepass,
            thread_ids: Vec::new(),
            prompt: "Prepass PR".into(),
            sent_at: 200,
        };
        store.append_round(&round_1).unwrap();
        store.append_round(&round_2).unwrap();

        let rounds_path = dir.path().join(ROUNDS_FILE);
        let mut contents = fs::read_to_string(&rounds_path).unwrap();
        assert_eq!(contents.lines().count(), 2);
        contents.push_str("\n   \n");
        fs::write(&rounds_path, contents).unwrap();

        assert_eq!(store.rounds().unwrap(), vec![round_1, round_2]);

        fs::write(&rounds_path, "{corrupt json\n").unwrap();
        let error = store.rounds().unwrap_err();
        let message = format!("{error:#}");
        assert!(message.contains(ROUNDS_FILE), "{message}");
    }

    #[test]
    fn concurrent_append_round_preserves_every_round_without_interleaving() {
        let temp_directory = tempfile::tempdir().unwrap();
        let store = FsStore::new(temp_directory.path());
        let store_ref = &store;
        let errors: Vec<String> = thread::scope(|scope| {
            let workers = [0_u64, 1, 2, 3].map(|worker| {
                scope.spawn(move || {
                    let mut worker_errors = Vec::new();
                    for step in 0..25_u64 {
                        let round = AgentRound {
                            round: worker * 25 + step + 1,
                            kind: AgentRoundKind::Send,
                            thread_ids: vec![format!("loc-{worker}-{step}")],
                            prompt: format!("Prompt for worker {worker} step {step}"),
                            sent_at: 1000 + step,
                        };
                        if let Err(error) = store_ref.append_round(&round) {
                            worker_errors.push(format!("{error:#}"));
                        }
                    }
                    worker_errors
                })
            });
            workers
                .into_iter()
                .flat_map(|handle| handle.join().unwrap())
                .collect()
        });
        assert!(errors.is_empty(), "append_round errors: {errors:?}");
        let mut rounds = store.rounds().unwrap();
        assert_eq!(rounds.len(), 100);
        rounds.sort_by_key(|entry| entry.round);
        let round_numbers: Vec<u64> = rounds.iter().map(|entry| entry.round).collect();
        assert_eq!(round_numbers, (1..=100).collect::<Vec<_>>());
        assert!(!temp_directory.path().join(LOCAL_LOCK_FILE).exists());
    }

    #[test]
    fn concurrent_locked_local_mutations_preserve_every_writer() {
        let temp_directory = tempfile::tempdir().unwrap();
        let store = FsStore::new(temp_directory.path());
        let errors: Vec<String> = thread::scope(|scope| {
            let workers = [0_u64, 1, 2, 3].map(|_worker| {
                scope.spawn(|| {
                    let mut worker_errors = Vec::new();
                    for _step in 0..25_u64 {
                        let result = store.mutate_local_locked(|local| {
                            local.next_local_id += 1;
                            let id = local.next_local_id;
                            local.threads.push(create_sample_local_thread(id));
                            Ok(())
                        });
                        if let Err(error) = result {
                            worker_errors.push(format!("{error:#}"));
                        }
                    }
                    worker_errors
                })
            });
            workers
                .into_iter()
                .flat_map(|handle| handle.join().unwrap())
                .collect()
        });
        assert!(errors.is_empty(), "locked mutation errors: {errors:?}");
        let loaded = store.load().unwrap();
        assert_eq!(loaded.local.next_local_id, 100);
        assert_eq!(loaded.local.threads.len(), 100);
        assert!(!temp_directory.path().join(LOCAL_LOCK_FILE).exists());
    }

    fn mutate_local_counter_rounds(store: &FsStore, rounds: u64) -> Vec<String> {
        (0..rounds)
            .filter_map(|_| {
                store
                    .mutate_local_locked(|local| {
                        local.next_local_id += 1;
                        Ok(())
                    })
                    .err()
            })
            .map(|error| format!("{error:#}"))
            .collect()
    }

    #[test]
    fn concurrent_saves_and_locked_local_mutations_never_conflict() {
        let temp_directory = tempfile::tempdir().unwrap();
        let store = FsStore::new(temp_directory.path());
        let store_ref = &store;
        let errors: Vec<String> = thread::scope(|scope| {
            let savers = [0_usize, 1].map(|offset| {
                scope.spawn(move || {
                    (0..30_usize)
                        .filter_map(|round| {
                            store_ref.save(&snapshot_for_round(round + offset)).err()
                        })
                        .map(|error| format!("{error:#}"))
                        .collect::<Vec<_>>()
                })
            });
            let mutators =
                [0_u64, 1].map(|_| scope.spawn(|| mutate_local_counter_rounds(store_ref, 30)));
            savers
                .into_iter()
                .chain(mutators)
                .flat_map(|handle| handle.join().unwrap())
                .collect()
        });
        assert!(
            errors.is_empty(),
            "concurrent save/mutate errors: {errors:?}"
        );
        assert!(store.load().is_ok());
        assert_eq!(
            file_names(temp_directory.path()),
            [GITHUB_FILE, LOCAL_FILE, SESSION_FILE, VIEWED_FILE]
        );
    }

    #[test]
    fn mutate_local_locked_refuses_newer_local_file_and_removes_lock() {
        let temp_directory = tempfile::tempdir().unwrap();
        let newer = r#"{"version": 9, "nextLocalId": 50}"#;
        fs::write(temp_directory.path().join(LOCAL_FILE), newer).unwrap();
        let store = FsStore::new(temp_directory.path());
        let error = store
            .mutate_local_locked(|local| {
                local.next_local_id += 1;
                Ok(())
            })
            .unwrap_err();
        let message = format!("{error:#}");
        assert!(
            message.contains("version 9") && message.contains(LOCAL_FILE),
            "{message}"
        );
        assert_eq!(
            fs::read_to_string(temp_directory.path().join(LOCAL_FILE)).unwrap(),
            newer
        );
        assert!(!temp_directory.path().join(LOCAL_LOCK_FILE).exists());
    }

    /// Saves 100 rounds' snapshots, starting at round `offset`, and returns
    /// the errors of the saves that failed.
    fn save_rounds(store: &FsStore, offset: usize) -> Vec<String> {
        (0..100)
            .filter_map(|round| store.save(&snapshot_for_round(round + offset)).err())
            .map(|error| format!("{error:#}"))
            .collect()
    }

    /// Loads again and again until `is_writing_done` holds, and returns the
    /// errors of the loads that failed.
    fn load_until_done(store: &FsStore, is_writing_done: &AtomicBool) -> Vec<String> {
        let mut errors = Vec::new();
        while !is_writing_done.load(Ordering::Relaxed) {
            if let Err(error) = store.load() {
                errors.push(format!("{error:#}"));
            }
        }
        errors
    }

    #[test]
    fn concurrent_saves_never_tear_a_file_or_leave_temporaries() {
        let dir = tempfile::tempdir().unwrap();
        let store = FsStore::new(dir.path());
        store.save(&snapshot_for_round(0)).unwrap();
        let is_writing_done = AtomicBool::new(false);
        let (save_errors, load_errors) = thread::scope(|scope| {
            let first_writer = scope.spawn(|| save_rounds(&store, 0));
            let second_writer = scope.spawn(|| save_rounds(&store, 1));
            let reader = scope.spawn(|| load_until_done(&store, &is_writing_done));
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
        assert_eq!(
            file_names(dir.path()),
            [GITHUB_FILE, LOCAL_FILE, SESSION_FILE, VIEWED_FILE]
        );
    }

    #[cfg(unix)]
    #[test]
    fn state_files_and_lock_use_owner_only_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let store = FsStore::new(dir.path());
        store.save(&StoreSnapshot::default()).unwrap();
        store
            .append_round(&AgentRound {
                round: 1,
                kind: AgentRoundKind::Send,
                thread_ids: vec!["loc-1".into()],
                prompt: "Address loc-1".into(),
                sent_at: 100,
            })
            .unwrap();
        store
            .mutate_local_locked(|local| {
                let lock_mode = fs::metadata(dir.path().join(LOCAL_LOCK_FILE))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777;
                assert_eq!(lock_mode, 0o600);
                local.next_local_id += 1;
                Ok(())
            })
            .unwrap();

        for name in [SESSION_FILE, LOCAL_FILE, ROUNDS_FILE] {
            let mode = fs::metadata(dir.path().join(name))
                .unwrap()
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(mode, 0o600, "{name} mode was {mode:o}");
        }
    }
}
