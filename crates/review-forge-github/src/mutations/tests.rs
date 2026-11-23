use review_core::ports::ForgeWriteError;
use review_model::{Anchor, MessageSync, Side};

use super::*;

#[test]
fn thread_variables_use_file_subject_without_lines_and_set_start_line_only_for_ranges() {
    let file_variables = build_thread_variables("PR_1", "PRR_1", &Anchor::file("src/a.rs"), "hi");
    assert_eq!(file_variables["subjectType"], "FILE");
    assert!(file_variables.get("line").is_none());

    let line_variables =
        build_thread_variables("PR_1", "PRR_1", &Anchor::line("src/a.rs", 9), "one");
    assert_eq!(line_variables["subjectType"], "LINE");
    assert_eq!(line_variables["line"], 9);
    assert_eq!(line_variables["side"], "RIGHT");
    assert!(line_variables.get("startLine").is_none());

    let range_variables = build_thread_variables(
        "PR_1",
        "PRR_1",
        &Anchor::range("src/a.rs", Side::Left, 3, 6),
        "span",
    );
    assert_eq!(range_variables["subjectType"], "LINE");
    assert_eq!(range_variables["startLine"], 3);
    assert_eq!(range_variables["line"], 6);
    assert_eq!(range_variables["side"], "LEFT");
    assert_eq!(range_variables["startSide"], "LEFT");
}

#[test]
fn error_classification_separates_transient_network_failures_from_rejections() {
    assert!(matches!(
        classify_write_error(&anyhow::anyhow!("gh timed out after 30s")),
        ForgeWriteError::Transient(_)
    ));
    assert!(matches!(
        classify_write_error(&anyhow::anyhow!("error connecting to api.github.com")),
        ForgeWriteError::Transient(_)
    ));
    assert!(matches!(
        classify_write_error(&anyhow::anyhow!("HTTP 500 Internal Server Error")),
        ForgeWriteError::Transient(_)
    ));
    assert!(matches!(
        classify_write_error(&anyhow::anyhow!("HTTP 502 Bad Gateway")),
        ForgeWriteError::Transient(_)
    ));
    assert!(matches!(
        classify_write_error(&anyhow::anyhow!("HTTP 429 Too Many Requests")),
        ForgeWriteError::Transient(_)
    ));
    assert!(matches!(
        classify_write_error(&anyhow::anyhow!("too many requests")),
        ForgeWriteError::Transient(_)
    ));
    assert!(matches!(
        classify_write_error(&anyhow::anyhow!("API rate limit exceeded")),
        ForgeWriteError::Transient(_)
    ));
    assert!(matches!(
        classify_write_error(&anyhow::anyhow!("Line could not be resolved")),
        ForgeWriteError::Rejected(_)
    ));
    assert!(matches!(
        classify_write_error(&anyhow::anyhow!("HTTP 422: Comment not found")),
        ForgeWriteError::Rejected(_)
    ));
}

#[test]
fn rest_reply_endpoint_rejects_traversal_and_non_digit_database_ids() {
    let mut pr = PullRequest {
        owner: "octo".into(),
        repo: "widgets".into(),
        number: 7,
        title: "Fix".into(),
        url: "https://github.com/octo/widgets/pull/7".into(),
        node_id: "PR_7".into(),
        author: "alice".into(),
        head_ref: "fix".into(),
        head_sha: "abc".into(),
        base_ref: "main".into(),
        base_sha: "base".into(),
        is_cross_repository: false,
    };
    assert_eq!(
        build_rest_reply_endpoint(&pr, "98765").unwrap(),
        "repos/octo/widgets/pulls/7/comments/98765/replies"
    );
    assert!(matches!(
        build_rest_reply_endpoint(&pr, "987/../../x"),
        Err(ForgeWriteError::Rejected(_))
    ));
    assert!(matches!(
        build_rest_reply_endpoint(&pr, ""),
        Err(ForgeWriteError::Rejected(_))
    ));
    pr.owner = "../evil".into();
    assert!(matches!(
        build_rest_reply_endpoint(&pr, "98765"),
        Err(ForgeWriteError::Rejected(_))
    ));
    pr.owner = "octo".into();
    pr.repo = "widgets?x=1".into();
    assert!(matches!(
        build_rest_reply_endpoint(&pr, "98765"),
        Err(ForgeWriteError::Rejected(_))
    ));
}

#[test]
fn rest_reply_marks_comment_published_by_viewer_with_string_database_id() {
    let raw = r#"{
        "id": 98765,
        "node_id": "PRRC_rest",
        "body": "thanks!",
        "created_at": "2026-11-20T03:00:00Z",
        "updated_at": "2026-11-20T03:00:00Z",
        "user": {"login": "pablo", "type": "User"}
    }"#;
    let message = parse_rest_reply(raw).unwrap();
    assert_eq!(message.id, "PRRC_rest");
    assert_eq!(message.author, "pablo");
    assert_eq!(message.body, "thanks!");
    assert_eq!(message.database_id.as_deref(), Some("98765"));
    assert_eq!(message.sync, Some(MessageSync::Published));
    assert!(message.viewer_did_author);
}

#[test]
fn rest_reply_appends_bot_suffix_and_defaults_missing_body_to_empty() {
    let bot_raw = r#"{
        "id": 12,
        "node_id": "PRRC_bot",
        "created_at": "2026-11-20T03:00:00Z",
        "updated_at": "2026-11-20T03:00:00Z",
        "user": {"login": "dependabot", "type": "Bot"}
    }"#;
    let bot_message = parse_rest_reply(bot_raw).unwrap();
    assert_eq!(bot_message.author, "dependabot[bot]");
    assert_eq!(bot_message.body, "");
}

#[test]
fn detects_rest_422_pending_review_conflict() {
    assert!(is_pending_review_rest_conflict(
        "HTTP 422: user_id can only have one pending review per pull request"
    ));
    assert!(is_pending_review_rest_conflict(
        "Validation Failed: User can only have one pending review"
    ));
    assert!(!is_pending_review_rest_conflict("HTTP 404: Not Found"));
    assert!(!is_pending_review_rest_conflict("HTTP 422: Body is empty"));
}
