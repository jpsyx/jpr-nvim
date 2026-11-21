use super::*;

#[test]
fn the_fake_forge_records_viewed_marks_and_can_refuse_them() {
    let forge = FakeForge::new(
        sample_pr(),
        ForgeSnapshot {
            files: vec![changed_file("a.rs", ViewedState::Unviewed)],
            ..ForgeSnapshot::default()
        },
    );
    forge.set_viewed(&sample_pr(), "a.rs", true).unwrap();
    assert_eq!(forge.viewed_calls(), [("a.rs".to_owned(), true)]);
    let fetched = forge.fetch(&sample_pr()).unwrap();
    assert_eq!(
        fetched.files[0].viewed,
        ViewedState::Viewed,
        "the forge remembers the mark"
    );
    forge.fail_writes_with(Some("offline"));
    assert!(forge.set_viewed(&sample_pr(), "a.rs", false).is_err());
    assert!(forge.fetch(&sample_pr()).is_ok(), "reads still work");
    assert_eq!(forge.viewed_calls().len(), 1);
}

#[test]
fn the_fake_forge_publishes_immediate_replies_with_root_database_id() {
    let pr = sample_pr();
    let existing = github_thread("T_pub", "src/a.rs");
    let forge = FakeForge::new(
        pr.clone(),
        ForgeSnapshot {
            threads: vec![existing],
            ..ForgeSnapshot::default()
        },
    );
    let immediate = forge
        .reply_to_thread(
            &pr,
            &ReplyRequest {
                thread_id: "T_pub",
                root_database_id: Some("10"),
                pending_review_id: None,
                body: "immediate",
            },
        )
        .unwrap();
    assert_eq!(immediate.sync, Some(MessageSync::Published));
}

#[test]
fn the_fake_forge_publishes_pending_review_drafts_on_submit() {
    let pr = sample_pr();
    let forge = FakeForge::new(pr.clone(), ForgeSnapshot::default());
    let created = forge
        .create_review_thread(&pr, None, &Anchor::line("src/a.rs", 5), "draft")
        .unwrap();
    assert_eq!(created.pending_review_id, "PRR_fake");
    assert_eq!(created.thread.messages[0].sync, Some(MessageSync::Draft));

    forge
        .submit_review(&pr, Some("PRR_fake"), ReviewEvent::Comment, "lgtm")
        .unwrap();
    let fetched = forge.fetch(&pr).unwrap();
    assert!(!fetched.has_pending_review);
    assert_eq!(
        fetched.threads[0].messages[0].sync,
        Some(MessageSync::Published)
    );
}

#[test]
fn the_fake_forge_adds_and_removes_comment_reactions() {
    let pr = sample_pr();
    let forge = FakeForge::new(
        pr,
        ForgeSnapshot {
            threads: vec![github_thread("T_rx", "src/a.rs")],
            ..ForgeSnapshot::default()
        },
    );
    let added = forge
        .set_reaction("T_rx-c1", ReactionContent::ThumbsUp, true)
        .unwrap();
    assert_eq!(added.len(), 1);
    assert_eq!(added[0].count, 1);

    let removed = forge
        .set_reaction("T_rx-c1", ReactionContent::ThumbsUp, false)
        .unwrap();
    assert!(removed.is_empty());
}

#[test]
fn the_fake_forge_updates_thread_resolution_state() {
    let pr = sample_pr();
    let forge = FakeForge::new(
        pr.clone(),
        ForgeSnapshot {
            threads: vec![github_thread("T_res", "src/a.rs")],
            ..ForgeSnapshot::default()
        },
    );
    forge.set_resolved("T_res", true).unwrap();
    assert_eq!(
        forge.fetch(&pr).unwrap().threads[0].state,
        ThreadState::Resolved
    );

    forge.set_resolved("T_res", false).unwrap();
    assert_eq!(
        forge.fetch(&pr).unwrap().threads[0].state,
        ThreadState::Open
    );
}

#[test]
fn the_fake_forge_separates_transient_and_rejected_write_failures() {
    let pr = sample_pr();
    let forge = FakeForge::new(pr.clone(), ForgeSnapshot::default());
    forge.fail_writes_with(Some("timeout"));
    assert!(matches!(
        forge.create_conversation_comment(&pr, "hi"),
        Err(ForgeWriteError::Transient(_))
    ));
    forge.reject_writes_with(Some("validation failed"));
    assert!(matches!(
        forge.create_conversation_comment(&pr, "hi"),
        Err(ForgeWriteError::Rejected(_))
    ));
}

#[test]
fn the_fake_forge_creates_draft_reply_when_root_database_id_is_missing() {
    let pr = sample_pr();
    let review_thread = github_thread("T_rev", "src/a.rs");
    let forge = FakeForge::new(
        pr.clone(),
        ForgeSnapshot {
            threads: vec![review_thread],
            ..ForgeSnapshot::default()
        },
    );
    let draft_reply = forge
        .reply_to_thread(
            &pr,
            &ReplyRequest {
                thread_id: "T_rev",
                root_database_id: None,
                pending_review_id: None,
                body: "needs pending review",
            },
        )
        .unwrap();
    assert_eq!(draft_reply.sync, Some(MessageSync::Draft));
    let snapshot = forge.fetch(&pr).unwrap();
    assert!(snapshot.has_pending_review);
    assert_eq!(snapshot.pending_review_id.as_deref(), Some("PRR_fake"));
}

#[test]
fn the_fake_forge_rejects_editing_or_deleting_messages_with_mismatched_anchor_kind() {
    let pr = sample_pr();
    let review_thread = github_thread("T_rev", "src/a.rs");
    let forge = FakeForge::new(
        pr.clone(),
        ForgeSnapshot {
            threads: vec![review_thread],
            ..ForgeSnapshot::default()
        },
    );
    let conversation_thread = forge.create_conversation_comment(&pr, "top").unwrap();

    assert!(matches!(
        forge.edit_message(AnchorKind::Pr, "T_rev-c1", "oops"),
        Err(ForgeWriteError::Rejected(_))
    ));
    assert!(matches!(
        forge.delete_message(AnchorKind::Line, &conversation_thread.messages[0].id),
        Err(ForgeWriteError::Rejected(_))
    ));
}
