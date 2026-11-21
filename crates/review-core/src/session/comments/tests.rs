mod replay;

use review_model::{Anchor, Event, MessageSync, ReactionContent, ThreadState};

use super::super::test_support::{Fakes, create_snapshot};
use crate::fakes::github_thread;

#[test]
fn comment_on_line_creates_draft_thread_updates_counts_persists_and_announces() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let events = session.subscribe();

    let (thread, view) = session
        .comment(Anchor::line("src/a.rs", 3), "needs a guard")
        .unwrap();

    assert_eq!(thread.messages[0].sync, Some(MessageSync::Draft));
    assert_eq!(thread.messages[0].body, "needs a guard");
    assert_eq!(view.draft_count, 1);
    assert_eq!(view.thread_count, 2);
    assert_eq!(fakes.store.saved().registry.threads.len(), 2);
    assert!(matches!(
        events.try_recv().unwrap(),
        Event::ThreadsChanged { .. }
    ));
}

#[test]
fn comment_on_pr_creates_published_conversation_thread_and_updates_count() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();

    let (thread, view) = session
        .comment(Anchor::pr(), "overall looks solid")
        .unwrap();

    assert_eq!(thread.messages[0].sync, Some(MessageSync::Published));
    assert_eq!(view.conversation_count, 1);
    assert_eq!(view.thread_count, 1);
    assert_eq!(view.draft_count, 0);
}

#[test]
fn reply_publishes_immediately_when_no_pending_review_and_drafts_once_one_exists() {
    let fakes = Fakes::new(100);
    let mut snap = create_snapshot();
    snap.threads[0].messages[0].database_id = Some("55".into());
    fakes.forge.set_snapshot(snap);
    let mut session = fakes.open_synced();

    let (immediate_thread, _) = session.reply("T1", "immediate reply").unwrap();
    assert_eq!(
        immediate_thread.messages[1].sync,
        Some(MessageSync::Published)
    );

    session
        .comment(Anchor::line("src/a.rs", 4), "starts pending review")
        .unwrap();

    let (draft_thread, view) = session.reply("T1", "draft reply").unwrap();
    assert_eq!(draft_thread.messages[2].sync, Some(MessageSync::Draft));
    assert_eq!(view.draft_count, 2);
}

#[test]
fn concurrent_forge_edit_keeps_remote_body_clears_op_and_sets_recoverable_body() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();

    fakes.forge.fail_writes_with(Some("offline"));
    let (edited, view) = session.edit_message("T1-c1", "my offline edit").unwrap();
    assert_eq!(edited.messages[0].sync, Some(MessageSync::Queued));
    assert_eq!(view.queued_count, 1);

    fakes.forge.fail_writes_with(None);
    let mut updated_remote = github_thread("T1", "src/a.rs");
    updated_remote.messages[0].body = "edited on GitHub".into();
    let mut snap = create_snapshot();
    snap.threads = vec![updated_remote];
    fakes.forge.set_snapshot(snap);

    let synced_view = session.sync().unwrap();
    assert_eq!(synced_view.queued_count, 0);
    let message = &session.threads()[0].messages[0];
    assert_eq!(message.body, "edited on GitHub");
    assert_eq!(message.sync, Some(MessageSync::Published));
    assert_eq!(message.recoverable_body.as_deref(), Some("my offline edit"));
}

#[test]
fn set_resolved_persists_announces_and_reverts_on_reject() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let events = session.subscribe();

    let (resolved_thread, _) = session.set_resolved("T1", true).unwrap();
    assert_eq!(resolved_thread.state, ThreadState::Resolved);
    assert_eq!(
        fakes.store.saved().registry.threads[0].state,
        ThreadState::Resolved
    );
    assert!(matches!(
        events.try_recv().unwrap(),
        Event::ThreadsChanged { .. }
    ));

    fakes.forge.reject_writes_with(Some("forbidden"));
    assert!(session.set_resolved("T1", false).is_err());
    assert_eq!(session.threads()[0].state, ThreadState::Resolved);
    assert_eq!(
        fakes.store.saved().registry.threads[0].state,
        ThreadState::Resolved
    );
}

#[test]
fn toggle_reaction_persists_announces_and_reverts_on_reject() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let events = session.subscribe();

    let (reacted_thread, _) = session
        .toggle_reaction("T1-c1", ReactionContent::ThumbsUp)
        .unwrap();
    assert_eq!(reacted_thread.messages[0].reactions.len(), 1);
    assert_eq!(reacted_thread.messages[0].reactions[0].count, 1);
    assert_eq!(
        fakes.store.saved().registry.threads[0].messages[0].reactions[0].count,
        1
    );
    assert!(matches!(
        events.try_recv().unwrap(),
        Event::ThreadsChanged { .. }
    ));

    fakes.forge.reject_writes_with(Some("forbidden"));
    assert!(
        session
            .toggle_reaction("T1-c1", ReactionContent::ThumbsUp)
            .is_err()
    );
    assert_eq!(session.threads()[0].messages[0].reactions[0].count, 1);
    assert_eq!(
        fakes.store.saved().registry.threads[0].messages[0].reactions[0].count,
        1
    );
}

#[test]
fn delete_message_persists_announces_and_preserves_thread_on_reject() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let events = session.subscribe();

    fakes.forge.reject_writes_with(Some("forbidden"));
    assert!(session.delete_message("T1-c1").is_err());
    assert_eq!(session.threads().len(), 1);
    assert_eq!(fakes.store.saved().registry.threads.len(), 1);

    fakes.forge.reject_writes_with(None);
    let deleted_view = session.delete_message("T1-c1").unwrap();
    assert_eq!(deleted_view.thread_count, 0);
    assert!(session.threads().is_empty());
    assert!(fakes.store.saved().registry.threads.is_empty());
    assert!(matches!(
        events.try_recv().unwrap(),
        Event::ThreadsChanged { .. }
    ));
}

#[test]
fn mentions_returns_cached_pull_request_participants_after_sync() {
    let fakes = Fakes::new(100);
    let mut snap = create_snapshot();
    snap.mention_candidates = vec![review_model::MentionCandidate {
        login: "alice".into(),
        is_participant: true,
    }];
    fakes.forge.set_snapshot(snap);
    let session = fakes.open_synced();
    assert_eq!(session.mentions()[0].login, "alice");
    assert!(session.mentions()[0].is_participant);
}
