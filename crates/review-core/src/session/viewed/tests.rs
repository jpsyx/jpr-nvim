use review_model::{Event, ViewedState};

use super::super::test_support::{Fakes, create_snapshot};
use crate::ports::ReviewStore;

#[test]
fn marking_a_file_viewed_reaches_the_forge_and_is_announced() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let events = session.subscribe();
    let view = session.set_viewed("src/b.rs", true).unwrap();
    assert_eq!(fakes.forge.viewed_calls(), [("src/b.rs".to_owned(), true)]);
    assert_eq!(view.files[1].viewed, ViewedState::Viewed);
    assert_eq!(view.viewed_count, 2);
    assert_eq!(fakes.store.saved().files[1].viewed, ViewedState::Viewed);
    assert_eq!(
        events.try_recv().unwrap(),
        Event::ViewedChanged {
            view: Box::new(view)
        }
    );
}

#[test]
fn a_dismissed_file_marked_viewed_counts_as_viewed() {
    let fakes = Fakes::new(100);
    let mut changed = create_snapshot();
    changed.files[1].viewed = ViewedState::Dismissed;
    fakes.forge.set_snapshot(changed);
    let mut session = fakes.open_synced();
    assert_eq!(
        session.set_viewed("src/b.rs", true).unwrap().viewed_count,
        2
    );
}

#[test]
fn a_mark_the_forge_refuses_stands_here_and_is_queued() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.fail_writes_with(Some("offline"));
    let view = session.set_viewed("src/a.rs", false).unwrap();
    assert_eq!(view.files[0].viewed, ViewedState::Unviewed);
    assert_eq!(view.queued_count, 1);
    assert!(session.has_queued());
    assert_eq!(
        fakes.store.saved().registry.queued_viewed.get("src/a.rs"),
        Some(&false)
    );
}

#[test]
fn a_queued_mark_survives_a_pull_until_it_lands() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.fail_writes_with(Some("offline"));
    session.set_viewed("src/a.rs", false).unwrap();
    let view = session.sync().unwrap();
    assert_eq!(
        view.files[0].viewed,
        ViewedState::Unviewed,
        "the forge still says viewed, but the queued mark wins"
    );
    fakes.forge.fail_writes_with(None);
    let view = session.sync().unwrap();
    assert_eq!(fakes.forge.viewed_calls(), [("src/a.rs".to_owned(), false)]);
    assert_eq!(view.files[0].viewed, ViewedState::Unviewed);
    assert_eq!(view.queued_count, 0);
}

#[test]
fn a_direct_mark_that_lands_replaces_the_queued_one() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.fail_writes_with(Some("offline"));
    session.set_viewed("src/b.rs", true).unwrap();
    fakes.forge.fail_writes_with(None);
    let view = session.set_viewed("src/b.rs", false).unwrap();
    assert_eq!(view.queued_count, 0);
    assert_eq!(view.files[1].viewed, ViewedState::Unviewed);
    assert!(!session.has_queued());
    assert!(fakes.store.saved().registry.queued_viewed.is_empty());
    assert_eq!(fakes.forge.viewed_calls(), [("src/b.rs".to_owned(), false)]);
}

#[test]
fn a_flush_announces_only_when_a_mark_landed() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.fail_writes_with(Some("offline"));
    session.set_viewed("src/a.rs", false).unwrap();
    let events = session.subscribe();
    assert!(!session.flush_queued().unwrap(), "still offline");
    assert!(events.try_recv().is_err());
    fakes.forge.fail_writes_with(None);
    assert!(session.flush_queued().unwrap());
    assert!(!session.has_queued());
    assert!(matches!(
        events.try_recv().unwrap(),
        Event::ViewedChanged { .. }
    ));
}

#[test]
fn only_changed_files_can_be_marked() {
    let mut session = Fakes::new(100).open_synced();
    assert!(session.set_viewed("nope.rs", true).is_err());
}

#[test]
fn marking_waits_for_the_first_sync() {
    assert!(Fakes::new(1).open().set_viewed("src/a.rs", true).is_err());
}

#[test]
fn a_pull_drops_queued_marks_for_files_the_pull_request_no_longer_changes() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.fail_writes_with(Some("offline"));
    session.set_viewed("src/a.rs", false).unwrap();
    session.set_viewed("src/b.rs", true).unwrap();
    // A force-push takes src/a.rs out of the pull request, so a mark for
    // it can never land and must not hold up the marks queued after it.
    let mut pushed = create_snapshot();
    pushed.files.remove(0);
    fakes.forge.set_snapshot(pushed);
    let view = session.sync().unwrap();
    assert_eq!(view.queued_count, 1);
    assert_eq!(
        fakes
            .store
            .saved()
            .registry
            .queued_viewed
            .keys()
            .collect::<Vec<_>>(),
        ["src/b.rs"]
    );
    fakes.forge.fail_writes_with(None);
    assert!(session.flush_queued().unwrap());
    assert_eq!(fakes.forge.viewed_calls(), [("src/b.rs".to_owned(), true)]);
}

#[test]
fn a_reopened_session_applies_the_marks_still_queued() {
    let fakes = Fakes::new(100);
    fakes.open_synced();
    // `github.json` is written before `viewed.json`, so a crash between
    // them leaves a queued mark the saved files do not show yet.
    let mut saved = fakes.store.saved();
    saved
        .registry
        .queued_viewed
        .insert("src/a.rs".to_owned(), false);
    fakes.store.save(&saved).unwrap();
    let view = fakes.open().view();
    assert_eq!(view.files[0].viewed, ViewedState::Unviewed);
    assert_eq!(view.queued_count, 1);
}

#[test]
fn batched_viewed_skips_unchanged_remote_files_and_emits_one_event() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let events = session.subscribe();
    let view = session
        .set_viewed_paths(&["src/a.rs".to_owned(), "src/b.rs".to_owned()], true)
        .unwrap();
    assert_eq!(
        fakes.forge.viewed_batch_calls(),
        [(vec!["src/b.rs".to_owned()], true)]
    );
    assert_eq!(view.viewed_count, 2);
    assert_eq!(
        events.try_recv().unwrap(),
        Event::ViewedChanged {
            view: Box::new(view)
        }
    );
    assert!(events.try_recv().is_err(), "only one ViewedChanged event");
}

#[test]
fn batched_viewed_updates_mixed_linked_and_local_only_files_in_one_save() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/local_new.rs", "fn local() {}\n");
    let mut session = fakes.open_synced();
    session.refresh_worktree(&[]).unwrap();
    let events = session.subscribe();
    let view = session
        .set_viewed_paths(
            &["src/b.rs".to_owned(), "src/local_new.rs".to_owned()],
            true,
        )
        .unwrap();
    assert_eq!(
        fakes.forge.viewed_batch_calls(),
        [(vec!["src/b.rs".to_owned()], true)]
    );
    assert_eq!(view.viewed_count, 3);
    assert_eq!(
        fakes
            .store
            .saved()
            .local
            .local_viewed
            .get("src/local_new.rs"),
        Some(&ViewedState::Viewed)
    );
    assert!(matches!(
        events.try_recv().unwrap(),
        Event::ViewedChanged { .. }
    ));
    assert!(events.try_recv().is_err(), "only one ViewedChanged event");
}

#[test]
fn batched_viewed_validates_atomically_and_rejects_empty_or_unknown_paths() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    assert!(session.set_viewed_paths(&[], true).is_err());
    assert!(
        session
            .set_viewed_paths(&["src/b.rs".to_owned(), "nope.rs".to_owned()], true)
            .is_err()
    );
    assert_eq!(fakes.forge.viewed_batch_calls(), Vec::new());
    assert_eq!(session.view().files[1].viewed, ViewedState::Unviewed);
}

#[test]
fn batched_viewed_deduplicates_queues_failures_and_emits_one_auth_event() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.fail_auth_with(Some("gh auth login required"));
    let events = session.subscribe();
    let view = session
        .set_viewed_paths(
            &[
                "src/a.rs".to_owned(),
                "src/a.rs".to_owned(),
                "src/b.rs".to_owned(),
            ],
            false,
        )
        .unwrap();
    assert_eq!(view.viewed_count, 0);
    assert_eq!(view.queued_count, 1);
    assert_eq!(
        fakes.store.saved().registry.queued_viewed.get("src/a.rs"),
        Some(&false)
    );
    assert!(matches!(
        events.try_recv().unwrap(),
        Event::ViewedChanged { .. }
    ));
    assert!(matches!(
        events.try_recv().unwrap(),
        Event::SyncFailed {
            auth_required: true,
            is_background: false,
            ..
        }
    ));
    assert!(events.try_recv().is_err());
}
