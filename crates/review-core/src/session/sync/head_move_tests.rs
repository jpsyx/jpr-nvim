use crate::ports::Workspace;
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
fn reopen_sync_fast_forwards_when_local_head_is_behind_pr_head_on_first_sync() {
    let fakes = Fakes::new(100);
    fakes.workspace.set_head_commit("old000");
    let mut session = fakes.open();
    let events = session.subscribe();

    session.sync().unwrap();
    let (previous_sha, head_sha, outcome, _, _, _) = take_head_moved_and_synced(&events);
    assert_eq!(previous_sha, "old000");
    assert_eq!(head_sha, "abc123");
    assert_eq!(outcome, HeadMoveOutcome::FastForwarded);
    assert_eq!(fakes.workspace.head_commit().unwrap(), "abc123");
}

#[test]
fn reopen_sync_does_not_repeat_ahead_warning_on_subsequent_polls() {
    let fakes = Fakes::new(100);
    fakes.workspace.set_head_commit("local999");
    fakes.workspace.set_fast_forward_outcome(Some(Ok(
        crate::ports::FastForwardOutcome::AheadOfTarget {
            head_sha: "local999".into(),
            target_sha: "abc123".into(),
        },
    )));
    let mut session = fakes.open();
    let events = session.subscribe();

    session.sync().unwrap();
    let (_, _, outcome, _, _, _) = take_head_moved_and_synced(&events);
    assert_eq!(outcome, HeadMoveOutcome::AheadOfTarget);

    // Subsequent poll at the same remote head must emit only Synced, not HeadMoved again.
    session.sync().unwrap();
    assert!(matches!(events.try_recv().ok(), Some(Event::Synced { .. })));
    assert!(events.try_recv().is_err());
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

#[test]
fn sync_fast_forwards_when_remote_head_moves_reanchors_local_threads_and_emits_head_moved() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
    let mut session = fakes.open_synced();
    session
        .comment_with_origin(Anchor::line("src/a.rs", 2), "Why 1?", Origin::Local)
        .unwrap();
    let events = session.subscribe();
    advance_remote_head(&fakes, "def456");
    fakes
        .workspace
        .put_disk("src/a.rs", "// upstream header\nfn f() {}\nlet x = 1;\n");

    let synced_view = session.sync().unwrap();
    let (previous_sha, head_sha, outcome, conflicted_paths, message, moved_view) =
        take_head_moved_and_synced(&events);
    assert_eq!(previous_sha, "abc123");
    assert_eq!(head_sha, "def456");
    assert_eq!(outcome, HeadMoveOutcome::FastForwarded);
    assert_eq!(conflicted_paths, Vec::<String>::new());
    assert!(message.is_none());
    assert_eq!(moved_view, synced_view);
    assert_eq!(session.threads().last().unwrap().anchor.start, Some(3));
    assert_eq!(fakes.store.saved().local.threads[0].anchor.start, Some(3));
}

#[test]
fn sync_emits_restore_conflict_and_diverged_outcomes_without_failing_the_pull() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let events = session.subscribe();

    advance_remote_head(&fakes, "def456");
    fakes.workspace.set_fast_forward_outcome(Some(Ok(
        crate::ports::FastForwardOutcome::RestoreConflict {
            previous_sha: "abc123".into(),
            head_sha: "def456".into(),
            conflicted_paths: vec!["src/a.rs".into()],
        },
    )));
    session.sync().unwrap();
    let (_, _, outcome, conflicted_paths, message, _) = take_head_moved_and_synced(&events);
    assert_eq!(outcome, HeadMoveOutcome::RestoreConflict);
    assert_eq!(conflicted_paths, vec!["src/a.rs"]);
    assert!(message.is_some());

    advance_remote_head(&fakes, "999999");
    fakes.workspace.set_fast_forward_outcome(Some(Ok(
        crate::ports::FastForwardOutcome::Diverged {
            head_sha: "def456".into(),
            target_sha: "999999".into(),
        },
    )));
    session.sync().unwrap();
    let (_, _, outcome, _, message, _) = take_head_moved_and_synced(&events);
    assert_eq!(outcome, HeadMoveOutcome::Diverged);
    assert!(message.unwrap().contains("diverged"));
}

#[test]
fn sync_emits_ahead_and_failed_outcomes_without_failing_the_pull() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let events = session.subscribe();

    advance_remote_head(&fakes, "def456");
    fakes.workspace.set_fast_forward_outcome(Some(Ok(
        crate::ports::FastForwardOutcome::AheadOfTarget {
            head_sha: "local99".into(),
            target_sha: "def456".into(),
        },
    )));
    session.sync().unwrap();
    let (_, _, outcome, _, message, _) = take_head_moved_and_synced(&events);
    assert_eq!(outcome, HeadMoveOutcome::AheadOfTarget);
    assert!(message.unwrap().contains("ahead"));

    advance_remote_head(&fakes, "fedcba");
    fakes
        .workspace
        .set_fast_forward_outcome(Some(Err("fetch timed out".into())));
    let view = session.sync().unwrap();
    assert_eq!(view.pr.unwrap().head_sha, "fedcba");
    let (_, _, outcome, _, message, _) = take_head_moved_and_synced(&events);
    assert_eq!(outcome, HeadMoveOutcome::Failed);
    assert!(message.unwrap().contains("fetch timed out"));
}
