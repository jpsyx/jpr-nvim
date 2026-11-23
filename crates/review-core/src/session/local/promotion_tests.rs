use review_model::{MessageSync, Origin};

use super::super::test_support::{Fakes, create_snapshot};
use super::tests::create_local_comment;
use crate::ports::ReviewStore;

#[test]
fn promoting_local_thread_creates_github_draft_and_rejects_duplicates() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    assert!(session.promote_thread("T1", "Note").is_err());
    assert!(session.promote_thread("loc-999", "Note").is_err());

    let local = create_local_comment(&mut session, "src/a.rs", 1, "Check bounds");
    session.agent_reply(&local.id, "Verified.", None).unwrap();

    let (github_draft, view) = session
        .promote_thread(&local.id, "Polished note for PR author")
        .unwrap();
    assert_eq!(github_draft.origin, Origin::Github);
    assert_eq!(github_draft.messages.len(), 1);
    assert_eq!(github_draft.messages[0].body, "Polished note for PR author");
    assert_eq!(github_draft.messages[0].sync, Some(MessageSync::Draft));
    assert_eq!(view.draft_count, 1);

    let duplicate_error = session
        .promote_thread(&local.id, "Second promotion")
        .expect_err("duplicate promotion must be refused");
    assert!(duplicate_error.to_string().contains("already promoted"));
}

#[test]
fn promote_thread_emits_single_event_and_clears_snapshot() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_disk("src/a.rs", "let x = 1;\n");
    let mut session = fakes.open_synced();
    let local = create_local_comment(&mut session, "src/a.rs", 1, "Check bounds");
    assert!(local.anchor.snapshot.is_some());

    let events = session.subscribe();
    let (github_draft, _) = session
        .promote_thread(&local.id, "Polished note for PR author")
        .unwrap();

    assert!(github_draft.anchor.snapshot.is_none());
    assert!(matches!(
        events.try_recv().unwrap(),
        review_model::Event::ThreadsChanged { .. }
    ));
    assert!(events.try_recv().is_err());
}

#[test]
fn offline_promote_thread_remaps_promoted_to_on_sync() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let local = create_local_comment(&mut session, "src/a.rs", 1, "Check bounds");

    fakes.forge.fail_writes_with(Some("offline"));
    let (optimistic, _) = session
        .promote_thread(&local.id, "Draft while offline")
        .unwrap();
    assert!(optimistic.id.starts_with("tmp-"));

    fakes.forge.fail_writes_with(None);
    session.sync().unwrap();

    let stored_local = fakes
        .store
        .saved()
        .local
        .threads
        .into_iter()
        .find(|item| item.id == local.id)
        .expect("local thread remains persisted");
    let promoted_id = stored_local.promoted_to.expect("promoted_to stays set");
    assert!(
        !promoted_id.starts_with("tmp-"),
        "expected real GitHub ID, got {promoted_id}"
    );
    assert!(
        session
            .threads()
            .iter()
            .any(|item| item.origin == Origin::Github && item.id == promoted_id)
    );
}

#[test]
fn deleting_offline_promoted_draft_clears_promoted_to_for_repromotion() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let local = create_local_comment(&mut session, "src/a.rs", 1, "Check bounds");

    fakes.forge.fail_writes_with(Some("offline"));
    let (optimistic, _) = session
        .promote_thread(&local.id, "Draft while offline")
        .unwrap();
    let draft_message_id = &optimistic.messages[0].id;

    session.delete_message(draft_message_id).unwrap();
    let cleared = session
        .threads()
        .iter()
        .find(|item| item.id == local.id)
        .unwrap();
    assert!(cleared.promoted_to.is_none());
    assert!(fakes.store.saved().local.threads[0].promoted_to.is_none());

    fakes.forge.fail_writes_with(None);
    let (repromoted, _) = session.promote_thread(&local.id, "Second try").unwrap();
    assert_eq!(repromoted.origin, Origin::Github);
}

#[test]
fn deleting_online_promoted_thread_clears_promoted_to_after_last_message() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let local = create_local_comment(&mut session, "src/a.rs", 1, "Check bounds");

    let (promoted, _) = session.promote_thread(&local.id, "Draft note").unwrap();
    let (with_reply, _) = session.reply(&promoted.id, "Extra detail").unwrap();
    session.delete_message(&with_reply.messages[1].id).unwrap();
    assert_eq!(
        session
            .threads()
            .iter()
            .find(|item| item.id == local.id)
            .unwrap()
            .promoted_to
            .as_deref(),
        Some(promoted.id.as_str())
    );

    session.delete_message(&with_reply.messages[0].id).unwrap();
    let cleared = session
        .threads()
        .iter()
        .find(|item| item.id == local.id)
        .unwrap();
    assert!(cleared.promoted_to.is_none());
    assert!(fakes.store.saved().local.threads[0].promoted_to.is_none());

    let (repromoted, _) = session.promote_thread(&local.id, "Second try").unwrap();
    assert_eq!(repromoted.origin, Origin::Github);
    assert_ne!(repromoted.id, promoted.id);
}

#[test]
fn deleting_transient_queued_promoted_thread_and_reconcile_clears_promoted_to() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let local = create_local_comment(&mut session, "src/a.rs", 1, "Check bounds");
    let (promoted, _) = session.promote_thread(&local.id, "Draft note").unwrap();

    let mut remote_snapshot = create_snapshot();
    remote_snapshot.threads.push(promoted.clone());
    fakes.forge.set_snapshot(remote_snapshot);

    fakes.forge.fail_writes_with(Some("offline"));
    session.delete_message(&promoted.messages[0].id).unwrap();
    assert!(
        session
            .threads()
            .iter()
            .find(|item| item.id == local.id)
            .unwrap()
            .promoted_to
            .is_none()
    );
    assert!(fakes.store.saved().local.threads[0].promoted_to.is_none());

    let mut stale_saved = fakes.store.saved();
    stale_saved.local.threads[0].promoted_to = Some(promoted.id.clone());
    fakes.store.save(&stale_saved).unwrap();
    let mut reopened = fakes.open();
    reopened.sync().unwrap();
    assert!(
        reopened
            .threads()
            .iter()
            .find(|item| item.id == local.id)
            .unwrap()
            .promoted_to
            .is_none()
    );
    assert!(fakes.store.saved().local.threads[0].promoted_to.is_none());

    fakes.forge.fail_writes_with(None);
    let (repromoted, _) = reopened.promote_thread(&local.id, "Second try").unwrap();
    assert_eq!(repromoted.origin, Origin::Github);
}
