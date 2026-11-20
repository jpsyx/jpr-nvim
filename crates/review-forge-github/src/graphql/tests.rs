//! Parsing GitHub's GraphQL answers, and the shape of the documents sent.

use review_model::{AnchorKind, MessageSync, Side, ThreadState, ViewedState};
use serde_json::json;

use super::*;

fn comment(id: &str, login: &str, kind: &str, state: &str) -> Value {
    json!({ "id": id, "body": "why?", "url": "u", "createdAt": "c", "updatedAt": "u",
            "state": state, "viewerDidAuthor": false, "author": { "login": login, "__typename": kind } })
}

/// One parsed `THREADS` page holding, in order, a line, a range, an
/// outdated and a file thread.
fn parsed_threads_page() -> ThreadsPage {
    let data = json!({ "node": {
        "headRefOid": "head1",
        "reviewThreads": {
            "pageInfo": { "hasNextPage": true, "endCursor": "CUR" },
            "nodes": [
                { "id": "T1", "isResolved": false, "isOutdated": false, "subjectType": "LINE", "path": "a.rs",
                  "line": 12, "startLine": null, "diffSide": "RIGHT", "originalLine": 12, "originalStartLine": null,
                  "comments": { "nodes": [comment("C1", "bob", "User", "SUBMITTED")] } },
                { "id": "T2", "isResolved": true, "isOutdated": false, "subjectType": "LINE", "path": "a.rs",
                  "line": 20, "startLine": 18, "diffSide": "LEFT", "originalLine": 20, "originalStartLine": 18,
                  "comments": { "nodes": [comment("C2", "dependabot", "Bot", "PENDING")] } },
                { "id": "T3", "isResolved": false, "isOutdated": true, "subjectType": "LINE", "path": "b.rs",
                  "line": null, "startLine": null, "diffSide": "RIGHT", "originalLine": 4, "originalStartLine": null,
                  "comments": { "nodes": [] } },
                { "id": "T4", "isResolved": false, "isOutdated": false, "subjectType": "FILE", "path": "c.rs",
                  "line": null, "startLine": null, "diffSide": "RIGHT", "originalLine": null, "originalStartLine": null,
                  "comments": { "nodes": [] } }
            ]
        }
    } });
    parse_threads_page(&data).unwrap()
}

#[test]
fn parses_the_head_commit_and_the_next_cursor() {
    let (head, _, cursor) = parsed_threads_page();
    assert_eq!(head, "head1");
    assert_eq!(cursor.as_deref(), Some("CUR"));
}

#[test]
fn parses_a_line_thread() {
    let (_, threads, _) = parsed_threads_page();
    let line = &threads[0];
    assert_eq!(
        (line.anchor.kind, line.anchor.start, line.anchor.end),
        (AnchorKind::Line, Some(12), Some(12))
    );
    assert_eq!(line.messages[0].sync, Some(MessageSync::Published));
}

#[test]
fn parses_a_resolved_range_thread_with_a_bot_draft() {
    let (_, threads, _) = parsed_threads_page();
    let range = &threads[1];
    assert_eq!(
        (
            range.anchor.kind,
            range.anchor.side,
            range.anchor.start,
            range.anchor.end
        ),
        (AnchorKind::Range, Side::Left, Some(18), Some(20))
    );
    assert_eq!(range.state, ThreadState::Resolved);
    assert_eq!(range.messages[0].author, "dependabot[bot]");
    assert_eq!(range.messages[0].sync, Some(MessageSync::Draft));
}

#[test]
fn parses_an_outdated_thread_at_its_original_line() {
    let (_, threads, _) = parsed_threads_page();
    let outdated = &threads[2];
    assert!(outdated.outdated);
    assert_eq!(
        (outdated.anchor.kind, outdated.anchor.end),
        (AnchorKind::Line, Some(4))
    );
}

#[test]
fn parses_a_file_thread() {
    let (_, threads, _) = parsed_threads_page();
    let file = &threads[3];
    assert_eq!(
        (
            file.anchor.kind,
            file.anchor.file.as_deref(),
            file.anchor.start
        ),
        (AnchorKind::File, Some("c.rs"), None)
    );
}

#[test]
fn parses_files_with_counts_and_viewed_state() {
    let data = json!({ "node": { "files": {
        "pageInfo": { "hasNextPage": false, "endCursor": "X" },
        "nodes": [
            { "path": "a.rs", "additions": 12, "deletions": 3, "viewerViewedState": "VIEWED" },
            { "path": "b.rs", "additions": 1, "deletions": 0, "viewerViewedState": "DISMISSED" }
        ]
    } } });
    let (files, cursor) = parse_files_page(&data).unwrap();
    assert_eq!(cursor, None);
    assert_eq!(
        (
            files[0].path.as_str(),
            files[0].additions,
            files[0].deletions,
            files[0].viewed
        ),
        ("a.rs", 12, 3, ViewedState::Viewed)
    );
    assert_eq!(files[1].viewed, ViewedState::Dismissed);
}

#[test]
fn finds_only_the_viewers_pending_review() {
    let data = json!({ "node": { "reviews": { "nodes": [
        { "id": "R1", "viewerDidAuthor": false },
        { "id": "R2", "viewerDidAuthor": true }
    ] } } });
    assert_eq!(parse_pending_review(&data).as_deref(), Some("R2"));
    assert_eq!(
        parse_pending_review(&json!({ "node": { "reviews": { "nodes": [] } } })),
        None
    );
}

#[test]
fn viewed_marks_use_github_s_viewed_mutations() {
    assert!(viewed_flag_to_mutation(true).contains("markFileAsViewed"));
    assert!(!viewed_flag_to_mutation(true).contains("unmark"));
    assert!(viewed_flag_to_mutation(false).contains("unmarkFileAsViewed"));
}

#[test]
fn viewed_mutations_take_the_pull_request_and_path_as_variables() {
    for viewed in [true, false] {
        let mutation = viewed_flag_to_mutation(viewed);
        assert!(
            mutation.contains("mutation($pr: ID!, $path: String!)"),
            "{mutation}"
        );
        assert!(
            mutation.contains("pullRequestId: $pr, path: $path"),
            "{mutation}"
        );
    }
}

#[test]
fn reports_graphql_errors() {
    let answer = r#"{"errors":[{"message":"Could not resolve to a node"}]}"#;
    assert_eq!(
        parse_data_from_answer(answer).unwrap_err().to_string(),
        "Could not resolve to a node"
    );
    assert_eq!(
        error_message(answer).as_deref(),
        Some("Could not resolve to a node")
    );
    assert_eq!(error_message("not json"), None);
    assert_eq!(
        parse_data_from_answer(r#"{"data":{"ok":1}}"#).unwrap()["ok"],
        1
    );
}
