use review_model::{Anchor, Event, HeadMoveOutcome, Origin, SyncState};

use super::super::ReviewSession;
use super::super::test_support::Fakes;
use super::tests::{advance_remote_head, take_head_moved_and_synced};

fn find_thread_state(session: &ReviewSession, thread_id: &str) -> (Option<u64>, bool) {
    let thread = session
        .threads()
        .iter()
        .find(|thread| thread.id == thread_id)
        .unwrap();
    (thread.anchor.start, thread.outdated)
}

#[test]
fn sync_fast_forward_with_warm_digests_updates_digests_without_follow_up_files_changed() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
    let mut session = fakes.open_synced();
    session
        .comment_with_origin(Anchor::line("src/a.rs", 2), "Why 1?", Origin::Local)
        .unwrap();
    assert_eq!(session.poll_worktree_files().unwrap(), None);
    let events = session.subscribe();

    advance_remote_head(&fakes, "def456");
    fakes
        .workspace
        .put_disk("src/a.rs", "// upstream\nfn f() {}\nlet x = 1;\n");
    session.sync().unwrap();
    let (_, _, outcome, _, _, _) = take_head_moved_and_synced(&events);
    assert_eq!(outcome, HeadMoveOutcome::FastForwarded);
    assert_eq!(session.threads().last().unwrap().anchor.start, Some(3));
    assert_eq!(session.poll_worktree_files().unwrap(), None);
    assert!(events.try_recv().is_err());
}

#[test]
fn sync_restore_conflict_skips_reanchoring_conflicted_paths_while_reanchoring_clean_paths() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/a.rs", "fn a() {}\nlet a = 1;\n");
    fakes
        .workspace
        .put_disk("src/b.rs", "fn b() {}\nlet b = 1;\n");
    let mut session = fakes.open_synced();
    let (thread_a, _) = session
        .comment_with_origin(Anchor::line("src/a.rs", 2), "Keep", Origin::Local)
        .unwrap();
    let (thread_b, _) = session
        .comment_with_origin(Anchor::line("src/b.rs", 2), "Shift", Origin::Local)
        .unwrap();

    advance_remote_head(&fakes, "def456");
    fakes.workspace.set_fast_forward_outcome(Some(Ok(
        crate::ports::FastForwardOutcome::RestoreConflict {
            previous_sha: "abc123".into(),
            head_sha: "def456".into(),
            conflicted_paths: vec!["src/a.rs".into()],
        },
    )));
    fakes
        .workspace
        .put_disk("src/a.rs", "<<<<<<<\nfn a_remote() {}\n>>>>>>>\n");
    fakes
        .workspace
        .put_disk("src/b.rs", "// h\nfn b() {}\nlet b = 1;\n");
    session.sync().unwrap();

    assert_eq!(find_thread_state(&session, &thread_a.id), (Some(2), false));
    assert_eq!(find_thread_state(&session, &thread_b.id), (Some(3), false));
}

#[test]
fn poll_worktree_files_after_restore_conflict_waits_for_conflict_resolution_to_reanchor() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/a.rs", "fn a() {}\nlet a = 1;\n");
    let mut session = fakes.open_synced();
    let (thread_a, _) = session
        .comment_with_origin(Anchor::line("src/a.rs", 2), "Keep", Origin::Local)
        .unwrap();

    advance_remote_head(&fakes, "def456");
    fakes.workspace.set_fast_forward_outcome(Some(Ok(
        crate::ports::FastForwardOutcome::RestoreConflict {
            previous_sha: "abc123".into(),
            head_sha: "def456".into(),
            conflicted_paths: vec!["src/a.rs".into()],
        },
    )));
    fakes
        .workspace
        .put_disk("src/a.rs", "<<<<<<<\nfn a_remote() {}\n>>>>>>>\n");
    session.sync().unwrap();

    assert_eq!(session.poll_worktree_files().unwrap(), None);
    assert_eq!(find_thread_state(&session, &thread_a.id), (Some(2), false));
    fakes
        .workspace
        .put_disk("src/a.rs", "// resolved\nfn a() {}\nlet a = 1;\n");
    assert_eq!(
        session.poll_worktree_files().unwrap(),
        Some(vec!["src/a.rs".to_owned()])
    );
    assert_eq!(find_thread_state(&session, &thread_a.id), (Some(3), false));
}

#[test]
fn sync_retries_failed_fast_forward_on_next_sync_at_same_remote_head() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
    let mut session = fakes.open_synced();
    let (thread, _) = session
        .comment_with_origin(Anchor::line("src/a.rs", 2), "Why 1?", Origin::Local)
        .unwrap();
    let events = session.subscribe();

    advance_remote_head(&fakes, "def456");
    fakes
        .workspace
        .set_fast_forward_outcome(Some(Err("index.lock busy".into())));
    session.sync().unwrap();
    let (_, _, first_outcome, _, _, _) = take_head_moved_and_synced(&events);
    assert_eq!(first_outcome, HeadMoveOutcome::Failed);
    assert_eq!(find_thread_state(&session, &thread.id), (Some(2), false));

    fakes.workspace.set_fast_forward_outcome(None);
    fakes
        .workspace
        .put_disk("src/a.rs", "// upstream\nfn f() {}\nlet x = 1;\n");
    session.sync().unwrap();
    let (prior_sha, head_sha, second_outcome, _, _, _) = take_head_moved_and_synced(&events);
    assert_eq!(
        (prior_sha.as_str(), head_sha.as_str()),
        ("abc123", "def456")
    );
    assert_eq!(second_outcome, HeadMoveOutcome::FastForwarded);
    assert_eq!(find_thread_state(&session, &thread.id), (Some(3), false));
}

#[test]
fn sync_marks_failed_and_retries_head_move_when_apply_pull_save_fails() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let events = session.subscribe();

    advance_remote_head(&fakes, "def456");
    fakes.clock.set(200);
    fakes.store.fail_saves_with(Some("disk full"));
    let error = session.sync().unwrap_err();
    assert!(error.to_string().contains("disk full"));
    assert!(matches!(
        session.view().sync,
        SyncState::Failed { at: 200, .. }
    ));
    assert!(matches!(
        events.try_recv().unwrap(),
        Event::SyncFailed { .. }
    ));

    fakes.store.fail_saves_with(None);
    session.sync().unwrap();
    let (prior_sha, head_sha, outcome, _, _, _) = take_head_moved_and_synced(&events);
    assert_eq!(
        (prior_sha.as_str(), head_sha.as_str()),
        ("abc123", "def456")
    );
    assert_eq!(outcome, HeadMoveOutcome::FastForwarded);
}
