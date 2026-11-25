use review_model::{Anchor, Event, MessageSync, Origin, ReactionContent, ReviewEvent, ViewedState};

use super::test_support::Fakes;
use crate::{ForgeAuthError, is_auth_error, is_gh_auth_failure_text};

#[test]
fn auth_classifier_distinguishes_gh_auth_failures_from_other_errors() {
    for auth_text in [
        "To get started with GitHub CLI, please run:  gh auth login",
        "You are not logged into any GitHub hosts.",
        "gh: HTTP 401: Bad credentials",
        "The token in default is invalid.",
        "authentication required to access this resource",
        "no oauth token found",
        "requires authentication",
        "failed to authenticate with github.com",
    ] {
        assert!(
            is_gh_auth_failure_text(auth_text),
            "expected auth match for {auth_text:?}"
        );
    }
    for non_auth_text in [
        "running gh (is the GitHub CLI installed?): No such file or directory",
        "gh timed out after 30s",
        "gh: HTTP 403 Forbidden",
        "gh: HTTP 422 Validation Failed",
        "gh: HTTP 502 Bad Gateway",
        "no pull requests found for branch \"feat/demo\"",
    ] {
        assert!(
            !is_gh_auth_failure_text(non_auth_text),
            "must not classify {non_auth_text:?} as auth error"
        );
    }
    let wrapped = anyhow::Error::new(ForgeAuthError::new("bad credentials"))
        .context("pulling pull request #7");
    assert!(is_auth_error(&wrapped));
    assert!(!is_auth_error(&anyhow::anyhow!("network timeout")));
}

#[test]
fn foreground_and_background_sync_auth_failures_emit_structured_flags() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.fail_auth_with(Some("gh auth login required"));
    let events = session.subscribe();

    let foreground_error = session.sync().unwrap_err();
    assert!(is_auth_error(&foreground_error));
    assert_eq!(
        events.try_recv().unwrap(),
        Event::SyncFailed {
            message: "gh auth login required".into(),
            auth_required: true,
            is_background: false,
        }
    );

    let background_error = session.sync_background().unwrap_err();
    assert!(is_auth_error(&background_error));
    assert_eq!(
        events.try_recv().unwrap(),
        Event::SyncFailed {
            message: "gh auth login required".into(),
            auth_required: true,
            is_background: true,
        }
    );
}

#[test]
fn set_viewed_and_background_flush_emit_auth_required_without_losing_queue() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.fail_auth_with(Some("gh auth login required"));
    let events = session.subscribe();

    let view = session.set_viewed("src/b.rs", true).unwrap();
    assert_eq!(view.files[1].viewed, ViewedState::Viewed);
    assert_eq!(view.queued_count, 1);
    let first = events.try_recv().unwrap();
    let second = events.try_recv().unwrap();
    assert!(matches!(first, Event::ViewedChanged { .. }));
    assert_eq!(
        second,
        Event::SyncFailed {
            message: "gh auth login required".into(),
            auth_required: true,
            is_background: false,
        }
    );

    assert!(!session.flush_queued_background().unwrap());
    assert!(
        session.has_queued(),
        "queued mark must stay queued on auth error"
    );
    assert_eq!(
        events.try_recv().unwrap(),
        Event::SyncFailed {
            message: "gh auth login required".into(),
            auth_required: true,
            is_background: true,
        }
    );
}

#[test]
fn foreground_comment_mutations_propagate_auth_error_without_queueing() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let (existing_thread, _) = session
        .comment(Anchor::line("src/a.rs", 1), "existing comment")
        .unwrap();
    let existing_message_id = existing_thread.messages[0].id.clone();
    let before_threads = session.threads().to_vec();
    fakes.forge.fail_auth_with(Some("gh auth login required"));

    assert!(is_auth_error(
        &session
            .comment(Anchor::line("src/a.rs", 1), "new draft")
            .unwrap_err()
    ));
    assert!(is_auth_error(
        &session.reply(&existing_thread.id, "new reply").unwrap_err()
    ));
    assert!(is_auth_error(
        &session
            .edit_message(&existing_message_id, "edited body")
            .unwrap_err()
    ));
    assert!(is_auth_error(
        &session.delete_message(&existing_message_id).unwrap_err()
    ));
    assert!(is_auth_error(
        &session.set_resolved(&existing_thread.id, true).unwrap_err()
    ));
    assert!(is_auth_error(
        &session
            .toggle_reaction(&existing_message_id, ReactionContent::ThumbsUp)
            .unwrap_err()
    ));
    assert_eq!(session.threads(), before_threads.as_slice());
    assert!(!session.has_queued());
}

#[test]
fn foreground_promote_and_submit_propagate_auth_error_without_queueing() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let (local_thread, _) = session
        .comment_with_origin(Anchor::line("src/a.rs", 1), "local note", Origin::Local)
        .unwrap();
    let before_threads = session.threads().to_vec();
    fakes.forge.fail_auth_with(Some("gh auth login required"));

    assert!(is_auth_error(
        &session
            .promote_thread(&local_thread.id, "promoted")
            .unwrap_err()
    ));
    assert!(is_auth_error(
        &session
            .submit_review(ReviewEvent::Comment, "summary")
            .unwrap_err()
    ));
    assert_eq!(session.threads(), before_threads.as_slice());
    assert!(!session.has_queued());
}

#[test]
fn retry_message_preserves_failed_state_on_auth_error_and_succeeds_after_login() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    fakes.forge.reject_writes_with(Some("line outdated"));
    let (failed_thread, _) = session
        .comment(Anchor::line("src/a.rs", 1), "retry me")
        .unwrap();
    let failed_message_id = failed_thread.messages[0].id.clone();
    assert_eq!(failed_thread.messages[0].sync, Some(MessageSync::Failed));

    fakes.forge.reject_writes_with(None);
    fakes.forge.fail_auth_with(Some("gh auth login required"));
    let auth_error = session.retry_message(&failed_message_id).unwrap_err();
    assert!(is_auth_error(&auth_error));
    assert!(!session.has_queued());
    let still_failed = session
        .threads()
        .iter()
        .find(|thread| thread.id == failed_thread.id)
        .unwrap();
    assert_eq!(still_failed.messages[0].sync, Some(MessageSync::Failed));

    fakes.forge.fail_auth_with(None);
    let retried_view = session.retry_message(&failed_message_id).unwrap();
    assert_eq!(retried_view.queued_count, 0);
    let retried = session
        .threads()
        .iter()
        .find(|thread| thread.messages[0].body == "retry me")
        .unwrap();
    assert_eq!(retried.messages[0].sync, Some(MessageSync::Draft));
}
