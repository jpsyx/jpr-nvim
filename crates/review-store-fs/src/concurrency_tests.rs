use std::fs;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;

use review_model::{
    AgentRound, AgentRoundKind, AgentThreadState, Anchor, Message, Origin, Thread, ThreadState,
};

use super::tests::{file_names, snapshot_for_round};
use super::*;

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
                    .filter_map(|round| store_ref.save(&snapshot_for_round(round + offset)).err())
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
        "{} failed saves: {:?} ",
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
