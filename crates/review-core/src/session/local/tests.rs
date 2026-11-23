use review_model::{AgentThreadState, Anchor, Origin, ReactionContent, Side, Thread, ThreadState};

use super::super::ReviewSession;
use super::super::test_support::Fakes;

pub(super) fn create_local_comment(
    session: &mut ReviewSession,
    path: &str,
    line: u64,
    body: &str,
) -> Thread {
    session
        .comment_with_origin(Anchor::line(path, line), body, Origin::Local)
        .unwrap()
        .0
}

#[test]
fn local_comments_save_to_local_store_without_touching_forge() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes
        .forge
        .fail_writes_with(Some("forge must not be called"));

    let (thread, view) = session
        .comment_with_origin(
            Anchor::line("src/a.rs", 1),
            "Ask agent about lifetime",
            Origin::Local,
        )
        .unwrap();

    assert_eq!(thread.origin, Origin::Local);
    assert_eq!(thread.agent, Some(AgentThreadState::Unsent));
    assert!(thread.messages[0].sync.is_none());
    assert!(thread.messages[0].viewer_did_author);
    assert_eq!(view.local_unsent_count, 1);
    assert_eq!(view.draft_count, 0);
    assert_eq!(fakes.store.saved().local.threads.len(), 1);
    assert!(
        fakes
            .store
            .saved()
            .registry
            .threads
            .iter()
            .all(|item| item.origin == Origin::Github)
    );
}

#[test]
fn local_threads_survive_sync_without_leaking_into_registry() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let thread = create_local_comment(&mut session, "src/a.rs", 1, "Ask agent");

    let synced_view = session.sync().unwrap();

    assert_eq!(synced_view.local_unsent_count, 1);
    assert!(
        session
            .threads()
            .iter()
            .any(|item| item.id == thread.id && item.origin == Origin::Local)
    );
    assert_eq!(fakes.store.saved().local.threads.len(), 1);
    assert!(
        fakes
            .store
            .saved()
            .registry
            .threads
            .iter()
            .all(|item| item.origin == Origin::Github)
    );
}

#[test]
fn agent_reply_refuses_github_threads_optimistic_ids_and_unknown_threads() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();

    for forbidden in ["T1", "PRRT_123", "IC_1", "PRRC_1", "tmp-t-1"] {
        let error = session
            .agent_reply(forbidden, "Done.", None)
            .expect_err("GitHub thread must be refused");
        assert!(
            error.to_string().contains("GitHub thread"),
            "unexpected error for {forbidden}: {error}"
        );
    }

    assert_eq!(
        session
            .agent_reply("loc-999", "Unknown", None)
            .unwrap_err()
            .to_string(),
        "unknown local thread loc-999"
    );
}

#[test]
fn agent_reply_flips_state_to_answered_and_reviewer_reply_reopens_to_unsent() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let local = create_local_comment(&mut session, "src/a.rs", 1, "Why clone here?");

    let (answered, view) = session
        .agent_reply(&local.id, "Done. (abc1234)", Some("   "))
        .unwrap();
    assert_eq!(answered.agent, Some(AgentThreadState::Answered));
    let reply_message = answered.messages.last().unwrap();
    assert_eq!(reply_message.author, "agent");
    assert!(!reply_message.viewer_did_author);
    assert!(reply_message.sync.is_none());
    assert_eq!(view.local_unsent_count, 0);

    let (reopened, view_after_user_reply) = session
        .reply(&local.id, "What about empty slices?")
        .unwrap();
    assert_eq!(reopened.agent, Some(AgentThreadState::Unsent));
    assert!(reopened.messages.last().unwrap().viewer_did_author);
    assert_eq!(view_after_user_reply.local_unsent_count, 1);

    let (custom, _) = session
        .agent_reply(&local.id, "Handled empty slices.", Some(" claude "))
        .unwrap();
    assert_eq!(custom.messages.last().unwrap().author, "claude");
}

#[test]
fn retry_message_refuses_local_messages_without_touching_forge() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let local = create_local_comment(&mut session, "src/a.rs", 1, "Check bounds");
    fakes.forge.fail_with(Some("offline"));

    let error = session
        .retry_message(&local.messages[0].id)
        .expect_err("local message cannot be retried on GitHub");
    assert!(
        error
            .to_string()
            .contains("local comments cannot be retried")
    );
}

#[test]
fn reopening_restores_local_threads_and_allocates_unique_ids() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let first = create_local_comment(&mut session, "src/a.rs", 1, "First question");
    assert_eq!(first.id, "loc-1");
    assert_eq!(first.messages[0].id, "loc-m-1");

    let mut reopened = fakes.open();
    assert_eq!(reopened.view().local_unsent_count, 1);
    let second = create_local_comment(&mut reopened, "src/b.rs", 1, "Second question");
    assert_eq!(second.id, "loc-2");
    assert_eq!(second.messages[0].id, "loc-m-2");
    assert_eq!(reopened.view().local_unsent_count, 2);
}

#[test]
fn local_mutations_reject_blank_bodies() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let local = create_local_comment(&mut session, "src/a.rs", 1, "Valid body");
    let message_id = &local.messages[0].id;

    assert!(
        session
            .comment_with_origin(Anchor::line("src/a.rs", 1), "   ", Origin::Local)
            .is_err()
    );
    assert!(session.reply(&local.id, " \n\t ").is_err());
    assert!(session.edit_message(message_id, "").is_err());
    assert!(session.promote_thread(&local.id, "   ").is_err());
}

#[test]
fn local_snapshot_captures_right_side_and_skips_missing_or_out_of_bounds() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/a.rs", "fn a() {}\nlet x = 1;\n");
    let mut session = fakes.open_synced();

    let captured = create_local_comment(&mut session, "src/a.rs", 2, "Line two");
    assert_eq!(captured.anchor.snapshot.as_deref(), Some("let x = 1;"));

    let (left_thread, _) = session
        .comment_with_origin(
            Anchor::side_line("src/a.rs", Side::Left, 1),
            "Base line",
            Origin::Local,
        )
        .unwrap();
    assert!(left_thread.anchor.snapshot.is_none());

    let out_of_bounds = create_local_comment(&mut session, "src/a.rs", 99, "Past EOF");
    assert!(out_of_bounds.anchor.snapshot.is_none());

    let missing_disk = create_local_comment(&mut session, "src/b.rs", 1, "Missing file");
    assert!(missing_disk.anchor.snapshot.is_none());
}

#[test]
fn local_pr_anchor_is_normalized_and_oversized_disk_skips_snapshot() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_disk(
        "src/a.rs",
        &"x\n".repeat(super::super::diffs::MAX_DIFF_BYTES / 2 + 1),
    );
    let mut session = fakes.open_synced();

    let oversized = create_local_comment(&mut session, "src/a.rs", 1, "Too big");
    assert!(oversized.anchor.snapshot.is_none());

    let mut dirty_pr_anchor = Anchor::pr();
    dirty_pr_anchor.file = Some("src/a.rs".into());
    let (normalized, _) = session
        .comment_with_origin(dirty_pr_anchor, "PR note", Origin::Local)
        .unwrap();
    assert!(normalized.anchor.file.is_none());
}

#[test]
fn local_edit_resolve_and_reaction_work_offline_without_forge() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let local = create_local_comment(&mut session, "src/a.rs", 1, "Initial");
    let (conversation_thread, _) = session
        .comment_with_origin(Anchor::pr(), "PR note", Origin::Local)
        .unwrap();

    fakes.forge.fail_with(Some("offline"));
    let mut reopened = fakes.open();
    let message_id = local.messages[0].id.clone();

    let (edited, _) = reopened.edit_message(&message_id, "Edited").unwrap();
    assert_eq!(edited.messages[0].body, "Edited");

    let (reacted, _) = reopened
        .toggle_reaction(&message_id, ReactionContent::ThumbsUp)
        .unwrap();
    assert!(reacted.messages[0].reactions[0].viewer_has_reacted);

    let (resolved, _) = reopened.set_resolved(&local.id, true).unwrap();
    assert_eq!(resolved.state, ThreadState::Resolved);
    let (reopened_thread, _) = reopened.set_resolved(&local.id, false).unwrap();
    assert_eq!(reopened_thread.state, ThreadState::Open);

    assert!(
        reopened
            .set_resolved(&conversation_thread.id, true)
            .is_err()
    );
}

#[test]
fn delete_local_message_reconciles_agent_state_and_drops_empty_thread() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let local = create_local_comment(&mut session, "src/a.rs", 1, "Initial");

    let (answered, _) = session.agent_reply(&local.id, "Fixed.", None).unwrap();
    let (with_followup, _) = session.reply(&local.id, "One more check").unwrap();
    let followup_id = &with_followup.messages[2].id;
    session.delete_message(followup_id).unwrap();
    assert_eq!(
        session.threads().last().unwrap().agent,
        Some(AgentThreadState::Answered)
    );

    let agent_message_id = &answered.messages[1].id;
    session.delete_message(agent_message_id).unwrap();
    assert_eq!(
        session.threads().last().unwrap().agent,
        Some(AgentThreadState::Unsent)
    );

    let view = session.delete_message(&local.messages[0].id).unwrap();
    assert!(session.threads().iter().all(|item| item.id != local.id));
    assert_eq!(fakes.store.saved().local.threads, Vec::new());
    assert_eq!(view.local_unsent_count, 0);
}
