use std::fs;
use std::path::Path;

use review_core::contract::check_review_store;
use review_core::fakes::changed_file;
use review_model::{AgentRound, AgentRoundKind, ViewedState};

use super::*;

/// Returns sorted entry names inside `dir`.
pub fn file_names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

/// A snapshot whose size varies with `round`, so a torn file cannot parse.
pub fn snapshot_for_round(round: usize) -> StoreSnapshot {
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
    assert_eq!(store.rounds().unwrap(), Vec::new());

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
