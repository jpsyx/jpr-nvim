use review_model::{Event, HeadMoveOutcome, SessionView, SyncState, ViewedState};

use super::super::test_support::{Fakes, create_snapshot};

pub(super) fn advance_remote_head(fakes: &Fakes, head_sha: &str) {
    let mut updated_pr = crate::fakes::sample_pr();
    updated_pr.head_sha = head_sha.to_owned();
    fakes.forge.set_pr(updated_pr);
    let mut updated_snapshot = create_snapshot();
    updated_snapshot.head_sha = head_sha.to_owned();
    fakes.forge.set_snapshot(updated_snapshot);
}

pub(super) fn take_head_moved_and_synced(
    events: &std::sync::mpsc::Receiver<Event>,
) -> (
    String,
    String,
    HeadMoveOutcome,
    Vec<String>,
    Option<String>,
    SessionView,
) {
    let head_moved = match events.try_recv().expect("expected HeadMoved event") {
        Event::HeadMoved {
            previous_sha,
            head_sha,
            outcome,
            conflicted_paths,
            message,
            view,
        } => (
            previous_sha,
            head_sha,
            outcome,
            conflicted_paths,
            message,
            *view,
        ),
        other => panic!("expected HeadMoved, got {other:?}"),
    };
    match events.try_recv().expect("expected Synced event") {
        Event::Synced { view } => assert_eq!(*view, head_moved.5),
        other => panic!("expected Synced, got {other:?}"),
    }
    head_moved
}

#[test]
fn sync_pulls_saves_and_announces() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open();
    let events = session.subscribe();
    let view = session.sync().expect("the sync succeeds");
    assert_eq!(view.files.len(), 2);
    assert_eq!(view.thread_count, 1);
    assert_eq!(view.viewed_count, 1);
    assert_eq!(view.sync, SyncState::Synced { at: 100 });
    let saved = fakes.store.saved();
    assert_eq!(saved.session.pr.map(|pr| pr.number), Some(7));
    assert_eq!(saved.session.last_synced_at, Some(100));
    assert_eq!(saved.files.len(), 2);
    assert_eq!(
        events.try_recv().expect("an event was sent"),
        Event::Synced {
            view: Box::new(view)
        }
    );
}

#[test]
fn a_reopened_session_shows_the_saved_files_before_syncing() {
    let fakes = Fakes::new(100);
    fakes.open_synced();
    let view = fakes.open().view();
    assert_eq!(view.files.len(), 2);
    assert_eq!(
        view.pr.map(|pr| pr.title),
        Some("Fix the widget".to_owned())
    );
    assert_eq!(view.sync, SyncState::Synced { at: 100 });
}

#[test]
fn a_failed_sync_keeps_the_last_view_and_announces_the_failure() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let events = session.subscribe();
    fakes.forge.fail_with(Some("gh timed out after 30s"));
    fakes.clock.set(160);
    let error = session.sync().expect_err("the forge fails");
    assert!(error.to_string().contains("timed out"));
    let view = session.view();
    assert_eq!(view.files.len(), 2, "the last synced files are kept");
    assert_eq!(
        view.sync,
        SyncState::Failed {
            at: 160,
            message: "gh timed out after 30s".into()
        }
    );
    assert_eq!(
        events.try_recv().expect("an event was sent"),
        Event::SyncFailed {
            message: "gh timed out after 30s".into()
        }
    );
    assert_eq!(
        fakes.store.saved().session.last_synced_at,
        Some(100),
        "a failure saves nothing"
    );
}

#[test]
fn a_failed_pull_still_saves_and_announces_the_marks_it_sent() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.fail_writes_with(Some("offline"));
    session.set_viewed("src/a.rs", false).unwrap();
    fakes.forge.fail_writes_with(None);
    fakes.forge.fail_reads_with(Some("gh timed out after 30s"));
    let events = session.subscribe();
    let error = session.sync().expect_err("the pull fails");
    assert!(error.to_string().contains("timed out"));
    assert_eq!(fakes.forge.viewed_calls(), [("src/a.rs".to_owned(), false)]);
    assert!(fakes.store.saved().registry.queued_viewed.is_empty());
    match events.try_recv().expect("a viewedChanged event") {
        Event::ViewedChanged { view } => assert_eq!(view.queued_count, 0),
        other => panic!("expected viewedChanged, got {other:?}"),
    }
    assert!(matches!(
        events.try_recv().expect("a syncFailed event"),
        Event::SyncFailed { .. }
    ));
}

#[test]
fn github_resetting_a_viewed_file_reaches_the_view() {
    let fakes = Fakes::new(1);
    let mut session = fakes.open_synced();
    let mut changed = create_snapshot();
    changed.files[0].viewed = ViewedState::Dismissed;
    fakes.forge.set_snapshot(changed);
    let view = session.sync().expect("the second sync succeeds");
    assert_eq!(view.files[0].viewed, ViewedState::Dismissed);
    assert_eq!(view.viewed_count, 0);
}

#[test]
fn sync_fast_forwards_when_remote_head_moves_reanchors_local_threads_and_emits_head_moved() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
    let mut session = fakes.open_synced();
    session
        .comment_with_origin(
            review_model::Anchor::line("src/a.rs", 2),
            "Why 1?",
            review_model::Origin::Local,
        )
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
