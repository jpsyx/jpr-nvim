use review_model::{Anchor, AnchorKind, MessageSync, ReviewEvent, Side};

use super::super::test_support::{Fakes, create_snapshot};
use crate::ports::ReviewStore;

#[test]
fn suggest_from_edit_diffs_against_head_commit_creates_draft_and_returns_reverted_text() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_at("abc123", "src/a.rs", "let a = 1;\nlet b = 2;\n");
    let mut session = fakes.open_synced();

    let (suggested, thread, view) = session
        .suggest_from_edit("src/a.rs", "let a = 10;\nlet b = 2;\n", 1, Some("Use 10:"))
        .unwrap();
    assert_eq!(suggested.reverted_text, "let a = 1;\nlet b = 2;\n");
    assert!(
        thread.messages[0]
            .body
            .contains("Use 10:\n\n```suggestion\nlet a = 10;\n```")
    );
    assert_eq!(view.draft_count, 1);
}

#[test]
fn anchored_lines_reads_left_from_merge_base_and_right_from_disk() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_base("src/a.rs", "old_1\nold_2\n");
    fakes.workspace.put_disk("src/a.rs", "new_1\nnew_2\n");
    let mut session = fakes.open_synced();

    let left = session
        .anchored_lines(&Anchor::range("src/a.rs", Side::Left, 1, 2))
        .unwrap();
    let right = session
        .anchored_lines(&Anchor::side_line("src/a.rs", Side::Right, 2))
        .unwrap();
    assert_eq!(left, "old_1\nold_2");
    assert_eq!(right, "new_2");
}

#[test]
fn submit_review_publishes_all_drafts_and_blocks_self_approval() {
    let fakes = Fakes::new(100);
    let mut snap = create_snapshot();
    snap.viewer_login = Some("alice".into());
    fakes.forge.set_snapshot(snap);
    let mut session = fakes.open_synced();
    session
        .comment(Anchor::line("src/a.rs", 1), "draft note")
        .unwrap();

    let preview = session.submit_preview().unwrap();
    assert_eq!(preview.draft_count, 1);
    assert!(!preview.can_approve_or_request_changes);
    assert!(
        session
            .submit_review(ReviewEvent::Approve, "")
            .unwrap_err()
            .to_string()
            .contains("own pull request")
    );

    let view = session
        .submit_review(ReviewEvent::Comment, "overall summary")
        .unwrap();
    assert_eq!(view.draft_count, 0);
    assert_eq!(
        session.threads().last().unwrap().messages[0].sync,
        Some(MessageSync::Published)
    );
}

#[test]
fn submit_review_refuses_when_queued_or_failed_comment_exists() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.fail_writes_with(Some("offline"));
    session
        .comment(Anchor::line("src/a.rs", 2), "queued note")
        .unwrap();

    let queued_preview = session.submit_preview().unwrap();
    assert!(
        queued_preview
            .blocked_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("queued"))
    );
    let queued_error = session
        .submit_review(ReviewEvent::Comment, "summary")
        .unwrap_err();
    assert!(queued_error.to_string().contains("queued"));

    fakes.forge.reject_writes_with(Some("bad line"));
    session
        .comment(Anchor::line("src/a.rs", 3), "failed note")
        .unwrap();

    let failed_preview = session.submit_preview().unwrap();
    assert!(
        failed_preview
            .blocked_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("failed"))
    );
    let failed_error = session
        .submit_review(ReviewEvent::Comment, "summary")
        .unwrap_err();
    assert!(failed_error.to_string().contains("failed"));
}

#[test]
fn submit_review_queues_on_transient_failure_and_records_agreed_bodies_on_flush() {
    let fakes = Fakes::new(100);
    let mut snap = create_snapshot();
    snap.viewer_login = Some("bob".into());
    fakes.forge.set_snapshot(snap);
    let mut session = fakes.open_synced();
    let (draft_thread, _) = session
        .comment(Anchor::line("src/a.rs", 2), "draft note")
        .unwrap();
    let draft_message_id = draft_thread.messages[0].id.clone();

    fakes.forge.fail_writes_with(Some("offline"));
    let view = session
        .submit_review(ReviewEvent::Approve, "looks good")
        .unwrap();
    assert_eq!(view.queued_count, 1);
    assert_eq!(view.draft_count, 1);

    fakes.forge.fail_writes_with(None);
    assert!(session.flush_queued().unwrap());
    let after = session.view();
    assert_eq!(after.queued_count, 0);
    assert_eq!(after.draft_count, 0);
    assert_eq!(
        session.threads().last().unwrap().messages[0].sync,
        Some(MessageSync::Published)
    );
    let saved = fakes.store.load().unwrap();
    assert!(saved.registry.pending_review_id.is_none());
    assert_eq!(
        saved
            .registry
            .agreed_bodies
            .get(&draft_message_id)
            .map(String::as_str),
        Some("draft note")
    );
}

#[test]
fn anchored_lines_rejects_binary_files_invalid_bounds_and_non_line_anchors() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_disk("src/a.rs", "first\nsecond\n");
    fakes.workspace.put_disk("src/b.rs", "PNG\0\x01");
    let mut session = fakes.open_synced();

    assert!(
        session
            .anchored_lines(&Anchor::side_line("src/b.rs", Side::Right, 1))
            .unwrap_err()
            .to_string()
            .contains("binary")
    );
    assert!(
        session
            .anchored_lines(&Anchor::side_line("src/a.rs", Side::Right, 0))
            .is_err()
    );
    let reversed_range = Anchor {
        file: Some("src/a.rs".into()),
        kind: AnchorKind::Range,
        side: Side::Right,
        start: Some(3),
        end: Some(1),
        commit: None,
        snapshot: None,
    };
    assert!(session.anchored_lines(&reversed_range).is_err());
    assert!(session.anchored_lines(&Anchor::file("src/a.rs")).is_err());
    assert!(session.anchored_lines(&Anchor::pr()).is_err());
}

#[test]
fn anchored_lines_reads_target_line_when_line_anchor_sets_only_end() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_disk("src/a.rs", "first\nsecond\n");
    let mut session = fakes.open_synced();

    let end_only_line = Anchor {
        file: Some("src/a.rs".into()),
        kind: AnchorKind::Line,
        side: Side::Right,
        start: None,
        end: Some(2),
        commit: None,
        snapshot: None,
    };
    assert_eq!(session.anchored_lines(&end_only_line).unwrap(), "second");
}

#[test]
fn suggest_from_edit_rejects_deleted_and_binary_files() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_base("src/a.rs", "old\n");
    fakes.workspace.put_at("abc123", "src/b.rs", "PNG\0\x01");
    let mut session = fakes.open_synced();

    assert!(
        session
            .suggest_from_edit("src/a.rs", "new\n", 1, None)
            .unwrap_err()
            .to_string()
            .contains("does not exist at head commit")
    );
    assert!(
        session
            .suggest_from_edit("src/b.rs", "text\n", 1, None)
            .unwrap_err()
            .to_string()
            .contains("binary")
    );
}

#[test]
fn suggest_from_edit_creates_draft_and_reverts_head_text_for_added_file() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_at("abc123", "src/a.rs", "let added = 1;\n");
    let mut session = fakes.open_synced();

    let (suggested, _, view) = session
        .suggest_from_edit("src/a.rs", "let added = 2;\n", 1, None)
        .unwrap();
    assert_eq!(suggested.reverted_text, "let added = 1;\n");
    assert_eq!(view.draft_count, 1);
}

#[test]
fn suggest_from_edit_anchors_draft_on_new_path_for_renamed_file() {
    let fakes = Fakes::new(100);
    fakes.workspace.rename("src/old.rs", "src/a.rs");
    fakes.workspace.put_base("src/old.rs", "let x = 1;\n");
    fakes.workspace.put_at("abc123", "src/a.rs", "let x = 1;\n");
    let mut session = fakes.open_synced();

    let (renamed_suggested, _, renamed_view) = session
        .suggest_from_edit("src/a.rs", "let x = 2;\n", 1, None)
        .unwrap();
    assert_eq!(renamed_suggested.anchor.file.as_deref(), Some("src/a.rs"));
    assert_eq!(renamed_view.draft_count, 1);
}

#[test]
fn submit_review_requires_body_for_zero_draft_comment_and_request_changes_but_not_approve() {
    let fakes = Fakes::new(100);
    let mut snap = create_snapshot();
    snap.viewer_login = Some("bob".into());
    fakes.forge.set_snapshot(snap);
    let mut session = fakes.open_synced();

    assert!(session.submit_review(ReviewEvent::Comment, "   ").is_err());
    assert!(
        session
            .submit_review(ReviewEvent::RequestChanges, "   ")
            .is_err()
    );
    let view = session.submit_review(ReviewEvent::Approve, "").unwrap();
    assert_eq!(view.draft_count, 0);
    assert_eq!(view.queued_count, 0);
}

#[test]
fn submit_review_blocks_when_submit_is_already_queued() {
    let fakes = Fakes::new(100);
    let mut snap = create_snapshot();
    snap.viewer_login = Some("bob".into());
    fakes.forge.set_snapshot(snap);
    let mut session = fakes.open_synced();

    fakes.forge.fail_writes_with(Some("offline"));
    let queued_view = session.submit_review(ReviewEvent::Approve, "").unwrap();
    assert_eq!(queued_view.queued_count, 1);

    let preview = session.submit_preview().unwrap();
    assert!(
        preview
            .blocked_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("already queued"))
    );
    assert!(
        session
            .submit_review(ReviewEvent::Approve, "")
            .unwrap_err()
            .to_string()
            .contains("already queued")
    );
}

#[test]
fn submit_review_blocks_when_other_ops_are_queued() {
    let fakes = Fakes::new(100);
    let mut snap = create_snapshot();
    snap.viewer_login = Some("bob".into());
    fakes.forge.set_snapshot(snap);
    let mut session = fakes.open_synced();

    fakes.forge.fail_writes_with(Some("offline"));
    session.set_resolved("T1", true).unwrap();
    let blocked_preview = session.submit_preview().unwrap();
    assert!(
        blocked_preview
            .blocked_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("queued comment changes"))
    );
    assert!(
        session
            .submit_review(ReviewEvent::Approve, "")
            .unwrap_err()
            .to_string()
            .contains("queued comment changes")
    );
}
