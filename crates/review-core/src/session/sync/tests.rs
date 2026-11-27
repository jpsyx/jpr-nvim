use std::collections::BTreeSet;

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
        Event::Synced { view, .. } => assert_eq!(*view, head_moved.5),
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
            view: Box::new(view),
            is_background: false,
            delta: None,
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
            message: "gh timed out after 30s".into(),
            auth_required: false,
            is_background: false,
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
fn sync_expands_a_collapsed_parent_when_github_dismisses_a_viewed_file() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    session.set_collapsed("src", true).unwrap();
    session.set_collapsed("lib", true).unwrap();
    let mut snapshot = create_snapshot();
    snapshot.files[0].viewed = ViewedState::Dismissed;
    snapshot
        .files
        .push(crate::fakes::changed_file("lib/c.rs", ViewedState::Viewed));
    fakes.forge.set_snapshot(snapshot);
    let view = session.sync().unwrap();
    let expected = BTreeSet::from(["lib".to_owned()]);
    assert_eq!(view.collapsed_dirs, expected);
    assert_eq!(fakes.store.saved().local.collapsed_dirs, expected);
}

#[test]
fn a_failed_sync_keeps_collapsed_directories() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    session.set_collapsed("src", true).unwrap();
    fakes.forge.fail_with(Some("gh timed out after 30s"));
    assert!(session.sync().is_err());
    assert_eq!(
        session.view().collapsed_dirs,
        BTreeSet::from(["src".to_owned()])
    );
}

#[test]
fn reopening_after_recollapsing_a_dismissed_file_keeps_directory_collapsed() {
    let fakes = Fakes::new(100);
    let mut dismissed_snapshot = create_snapshot();
    dismissed_snapshot.files[0].viewed = ViewedState::Dismissed;
    fakes.forge.set_snapshot(dismissed_snapshot);

    let mut first = fakes.open_synced();
    first.set_collapsed("src", true).unwrap();
    drop(first);

    let mut reopened = fakes.open();
    assert_eq!(
        reopened.view().collapsed_dirs,
        BTreeSet::from(["src".to_owned()])
    );
    let synced = reopened.sync().unwrap();
    assert_eq!(synced.collapsed_dirs, BTreeSet::from(["src".to_owned()]));
}

#[test]
fn sync_keeps_local_only_collapsed_directory_before_merge_base_is_prepared() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("notes/todo.rs", "pub fn todo() {}\n");
    let mut first = fakes.open_synced();
    first.refresh_worktree(&[]).unwrap();
    first.set_collapsed("notes", true).unwrap();
    drop(first);

    let mut reopened = fakes.open();
    let synced = reopened.sync().unwrap();
    assert_eq!(synced.collapsed_dirs, BTreeSet::from(["notes".to_owned()]));
}

#[test]
fn sync_expands_only_ancestors_of_dismissed_file_preserving_collapsed_siblings() {
    let fakes = Fakes::new(100);
    let mut initial = create_snapshot();
    initial.files = vec![
        crate::fakes::changed_file("apps/cli/a.rs", ViewedState::Viewed),
        crate::fakes::changed_file("apps/cli/sub/b.rs", ViewedState::Viewed),
        crate::fakes::changed_file("apps/other/c.rs", ViewedState::Viewed),
    ];
    fakes.forge.set_snapshot(initial.clone());
    let mut session = fakes.open_synced();
    session.set_collapsed("apps/cli/sub", true).unwrap();
    session.set_collapsed("apps/other", true).unwrap();
    session.set_collapsed("apps", true).unwrap();

    let mut updated = initial;
    updated.files[0].viewed = ViewedState::Dismissed;
    fakes.forge.set_snapshot(updated);
    let view = session.sync().unwrap();
    assert_eq!(
        view.collapsed_dirs,
        BTreeSet::from(["apps/cli/sub".to_owned(), "apps/other".to_owned()])
    );
}

#[test]
fn background_sync_emits_delta_for_remote_changes_excluding_own_comments() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let (_, _) = session
        .comment_with_origin(
            review_model::Anchor::line("src/a.rs", 2),
            "my own draft",
            review_model::Origin::Github,
        )
        .unwrap();
    let events = session.subscribe();

    let mut snapshot = create_snapshot();
    snapshot.files.push(crate::fakes::changed_file(
        "src/new.rs",
        ViewedState::Unviewed,
    ));
    // Include both the reviewer's own thread (already in session.threads) and a new external thread.
    let mut external_thread = crate::fakes::github_thread("PRRT_EXT", "src/a.rs");
    external_thread.messages[0].id = "PRRC_EXT".into();
    external_thread.messages[0].body = "external feedback".into();
    external_thread.messages[0].viewer_did_author = false;
    snapshot.threads.push(external_thread);
    for existing in session.threads() {
        if existing.origin == review_model::Origin::Github
            && !snapshot.threads.iter().any(|t| t.id == existing.id)
        {
            snapshot.threads.push(existing.clone());
        }
    }
    fakes.forge.set_snapshot(snapshot);

    session.sync_background().unwrap();
    match events.try_recv().expect("expected Synced event") {
        Event::Synced {
            is_background,
            delta,
            ..
        } => {
            assert!(is_background);
            let delta = delta.expect("expected non-empty delta");
            assert_eq!(delta.files_changed, 1);
            assert_eq!(delta.new_comments, 1);
            assert!(!delta.head_moved);
        }
        other => panic!("expected Synced, got {other:?}"),
    }
}

#[test]
fn sync_after_own_push_omits_file_and_head_delta() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.workspace.set_head_commit("newsha123");
    fakes
        .workspace
        .set_worktree_status(Some(review_model::WorktreeStatus {
            is_dirty: false,
            ahead: 1,
            behind: 0,
            modified_paths: Vec::new(),
        }));
    let mut updated_pr = crate::fakes::sample_pr();
    updated_pr.head_sha = "newsha123".into();
    fakes.forge.set_pr(updated_pr);
    let mut updated_snapshot = create_snapshot();
    updated_snapshot.head_sha = "newsha123".into();
    updated_snapshot.files.push(crate::fakes::changed_file(
        "src/pushed.rs",
        ViewedState::Unviewed,
    ));
    fakes.forge.set_snapshot(updated_snapshot);

    let events = session.subscribe();
    session.push().unwrap();
    let mut synced_delta = None;
    while let Ok(event) = events.try_recv() {
        if let Event::Synced { delta, .. } = event {
            synced_delta = delta;
        }
    }
    assert_eq!(synced_delta, None);
}

#[test]
fn agent_reply_emits_agent_replied_event_with_location() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let (thread, _) = session
        .comment_with_origin(
            review_model::Anchor::line("src/a.rs", 2),
            "please check this",
            review_model::Origin::Local,
        )
        .unwrap();
    let events = session.subscribe();

    session
        .agent_reply(&thread.id, "checked and fixed", Some("claude"))
        .unwrap();

    assert!(matches!(
        events.try_recv().expect("expected ThreadsChanged"),
        Event::ThreadsChanged { .. }
    ));
    match events.try_recv().expect("expected AgentReplied") {
        Event::AgentReplied {
            thread_id,
            author,
            file,
            line,
            ..
        } => {
            assert_eq!(thread_id, thread.id);
            assert_eq!(author, "claude");
            assert_eq!(file.as_deref(), Some("src/a.rs"));
            assert_eq!(line, Some(2));
        }
        other => panic!("expected AgentReplied, got {other:?}"),
    }
}
