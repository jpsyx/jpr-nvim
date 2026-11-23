use review_model::{Anchor, MessageSync, ReactionContent};

use super::super::super::test_support::{Fakes, create_snapshot};

#[test]
fn transient_failure_queues_survives_reopen_and_flushes_with_id_remapping() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.fail_writes_with(Some("offline"));

    let (created_thread, view) = session
        .comment(Anchor::line("src/a.rs", 2), "offline note")
        .unwrap();
    assert_eq!(created_thread.messages[0].sync, Some(MessageSync::Queued));
    assert_eq!(view.queued_count, 1);

    let (replied_thread, view) = session.reply(&created_thread.id, "follow up").unwrap();
    assert_eq!(replied_thread.messages[1].sync, Some(MessageSync::Queued));
    assert_eq!(view.queued_count, 2);

    let (edited_thread, view) = session
        .edit_message(&replied_thread.messages[1].id, "edited follow up")
        .unwrap();
    assert_eq!(edited_thread.messages[1].body, "edited follow up");
    assert_eq!(view.queued_count, 2);

    let mut reopened = fakes.open();
    assert_eq!(reopened.view().queued_count, 2);
    assert_eq!(reopened.threads().len(), 2);

    fakes.forge.fail_writes_with(None);
    assert!(reopened.flush_queued().unwrap());
    assert_eq!(reopened.view().queued_count, 0);
    let flushed_thread = reopened
        .threads()
        .iter()
        .find(|thread| thread.anchor.start == Some(2))
        .unwrap();
    assert!(!flushed_thread.id.starts_with("tmp-"));
    assert_eq!(flushed_thread.messages.len(), 2);
    assert_eq!(flushed_thread.messages[0].sync, Some(MessageSync::Draft));
    assert_eq!(flushed_thread.messages[1].sync, Some(MessageSync::Draft));
    assert_eq!(flushed_thread.messages[1].body, "edited follow up");
}

#[test]
fn rejected_failure_marks_failed_without_queueing_and_succeeds_on_retry() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes
        .forge
        .reject_writes_with(Some("Line could not be resolved"));

    let (thread, view) = session
        .comment(Anchor::line("src/a.rs", 99), "bad line")
        .unwrap();
    let failed_message_id = thread.messages[0].id.clone();
    assert_eq!(thread.messages[0].sync, Some(MessageSync::Failed));
    assert_eq!(
        thread.messages[0].sync_error.as_deref(),
        Some("Line could not be resolved")
    );
    assert_eq!(view.queued_count, 0);
    assert!(!session.has_queued());

    fakes.forge.reject_writes_with(None);
    let retried_view = session.retry_message(&failed_message_id).unwrap();
    assert_eq!(retried_view.queued_count, 0);
    assert_eq!(retried_view.draft_count, 1);
    let retried_thread = session
        .threads()
        .iter()
        .find(|item| item.anchor.start == Some(99))
        .unwrap();
    assert_eq!(retried_thread.messages[0].sync, Some(MessageSync::Draft));
    assert!(retried_thread.messages[0].sync_error.is_none());
}

#[test]
fn deleting_queued_local_message_drops_its_queued_operation() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.fail_writes_with(Some("offline"));

    let (local_thread, view) = session
        .comment(Anchor::line("src/a.rs", 2), "local note")
        .unwrap();
    assert_eq!(view.queued_count, 1);

    let after_delete = session
        .delete_message(&local_thread.messages[0].id)
        .unwrap();
    assert_eq!(after_delete.queued_count, 0);
    assert_eq!(fakes.store.saved().registry.queued_ops, Vec::new());
}

#[test]
fn rejected_queued_operation_marks_message_failed_without_blocking_later_operations() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.fail_writes_with(Some("offline"));

    session.edit_message("T1-c1", "offline edit").unwrap();
    let (pr_thread, _) = session.comment(Anchor::pr(), "still queued").unwrap();
    assert_eq!(pr_thread.messages[0].sync, Some(MessageSync::Queued));
    assert_eq!(session.view().queued_count, 2);

    let mut without_t1 = create_snapshot();
    without_t1.threads.clear();
    fakes.forge.set_snapshot(without_t1);
    fakes.forge.fail_writes_with(None);

    assert!(session.flush_queued().unwrap());
    assert_eq!(session.view().queued_count, 0);
    assert_eq!(
        session.threads()[0].messages[0].sync,
        Some(MessageSync::Failed)
    );
    assert!(session.threads().iter().any(|thread| {
        thread.messages[0].body == "still queued"
            && thread.messages[0].sync == Some(MessageSync::Published)
    }));
}

#[test]
fn retrying_failed_pr_comment_publishes_conversation_thread() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.reject_writes_with(Some("rejected"));

    let (failed_thread, _) = session.comment(Anchor::pr(), "pr note 1").unwrap();
    assert_eq!(failed_thread.messages[0].sync, Some(MessageSync::Failed));

    fakes.forge.reject_writes_with(None);
    let retry_view = session
        .retry_message(&failed_thread.messages[0].id)
        .unwrap();
    assert_eq!(retry_view.conversation_count, 1);
    assert_eq!(retry_view.draft_count, 0);
    assert_eq!(
        session.threads()[1].messages[0].sync,
        Some(MessageSync::Published)
    );
}

#[test]
fn editing_failed_pr_comment_publishes_updated_conversation_thread() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.reject_writes_with(Some("rejected"));

    let (failed_thread, _) = session.comment(Anchor::pr(), "pr note 2").unwrap();
    fakes.forge.reject_writes_with(None);

    let (edited_thread, edit_view) = session
        .edit_message(&failed_thread.messages[0].id, "fixed pr note 2")
        .unwrap();
    assert!(edited_thread.id.starts_with("IC_fake_"));
    assert_eq!(edited_thread.messages[0].body, "fixed pr note 2");
    assert_eq!(edited_thread.messages[0].sync, Some(MessageSync::Published));
    assert_eq!(edit_view.conversation_count, 1);
    assert_eq!(edit_view.draft_count, 0);
}

#[test]
fn offline_reaction_survives_sync_pull_while_write_offline() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.fail_writes_with(Some("offline"));

    session
        .toggle_reaction("T1-c1", ReactionContent::ThumbsUp)
        .unwrap();
    let view = session.sync().unwrap();
    assert_eq!(view.queued_count, 1);
    assert_eq!(session.threads()[0].messages[0].reactions.len(), 1);
    assert!(session.threads()[0].messages[0].reactions[0].viewer_has_reacted);

    fakes.forge.fail_writes_with(None);
    assert!(session.flush_queued().unwrap());
    assert_eq!(session.view().queued_count, 0);
    assert_eq!(session.threads()[0].messages[0].reactions[0].count, 1);
}

#[test]
fn delete_failed_edited_real_message_calls_forge_and_prunes_stale_resolve() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.reject_writes_with(Some("rejected edit"));
    let (edited, _) = session.edit_message("T1-c1", "bad edit").unwrap();
    assert_eq!(edited.messages[0].sync, Some(MessageSync::Failed));

    fakes.forge.reject_writes_with(None);
    fakes.forge.fail_writes_with(Some("offline"));
    session.set_resolved("T1", true).unwrap();
    let del_view = session.delete_message("T1-c1").unwrap();
    assert_eq!(del_view.queued_count, 1);
    assert_eq!(fakes.store.saved().registry.queued_ops.len(), 1);

    fakes.forge.fail_writes_with(None);
    assert!(session.flush_queued().unwrap());
    assert_eq!(session.view().queued_count, 0);
    assert_eq!(session.threads(), &[]);
    assert_eq!(session.sync().unwrap().files.len(), 2);
    assert_eq!(session.threads(), &[]);
}

#[test]
fn deleting_root_of_queued_thread_promotes_first_reply_to_create_thread() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.fail_writes_with(Some("offline"));

    let (thread, _) = session
        .comment(Anchor::line("src/a.rs", 2), "root")
        .unwrap();
    let (thread, _) = session.reply(&thread.id, "first reply").unwrap();
    let (thread, _) = session.reply(&thread.id, "second reply").unwrap();
    let del_view = session.delete_message(&thread.messages[0].id).unwrap();
    assert_eq!(del_view.queued_count, 2);

    fakes.forge.fail_writes_with(None);
    assert!(session.flush_queued().unwrap());
    assert_eq!(session.view().queued_count, 0);
    let created = session
        .threads()
        .iter()
        .find(|item| item.anchor.start == Some(2))
        .unwrap();
    assert!(!created.id.starts_with("tmp-"));
    assert_eq!(created.messages.len(), 2);
    assert_eq!(created.messages[0].body, "first reply");
    assert_eq!(created.messages[1].body, "second reply");
    assert_eq!(created.messages[0].sync, Some(MessageSync::Draft));
    assert_eq!(created.messages[1].sync, Some(MessageSync::Draft));
}
