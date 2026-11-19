//! The GitHub GraphQL documents the forge sends, and pure parsing of the
//! answers. Queries address the pull request by its node id.

use anyhow::{Context, Result, anyhow};
use review_model::{
    Anchor, AnchorKind, ChangedFile, Message, MessageSync, Origin, Side, Thread, ThreadState,
    ViewedState,
};
use serde_json::Value;

/// The reviewer's pending review on a pull request, if any.
pub const PENDING_REVIEW: &str = r"query($pr: ID!) {
  node(id: $pr) { ... on PullRequest {
    reviews(states: PENDING, first: 20) { nodes { id viewerDidAuthor } }
  } }
}";

/// One page of review threads (with their comments) and the head commit.
pub const THREADS: &str = r"query($pr: ID!, $after: String) {
  node(id: $pr) { ... on PullRequest {
    headRefOid
    reviewThreads(first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id isResolved isOutdated subjectType path line startLine diffSide originalLine originalStartLine
        comments(first: 100) {
          nodes { id body url createdAt updatedAt state viewerDidAuthor author { login __typename } }
        }
      }
    }
  } }
}";

/// One page of the pull request's files with counts and the viewer's viewed state.
pub const FILES: &str = r"query($pr: ID!, $after: String) {
  node(id: $pr) { ... on PullRequest {
    files(first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { path additions deletions viewerViewedState }
    }
  } }
}";

/// One page of `THREADS`: the head commit, the threads, and the next cursor.
pub type ThreadsPage = (String, Vec<Thread>, Option<String>);

/// One page of `FILES`: the files and the next cursor.
pub type FilesPage = (Vec<ChangedFile>, Option<String>);

/// The `data` of a `gh api graphql` answer, or GitHub's error message.
pub fn parse_data_from_answer(stdout: &str) -> Result<Value> {
    let value: Value = serde_json::from_str(stdout).context("reading GitHub's GraphQL answer")?;
    if let Some(message) = value.pointer("/errors/0/message").and_then(Value::as_str) {
        return Err(anyhow!("{message}"));
    }
    value
        .get("data")
        .cloned()
        .ok_or_else(|| anyhow!("GitHub's answer had no data"))
}

/// GitHub's error message, when `stdout` is a GraphQL error answer.
#[must_use]
pub fn error_message(stdout: &str) -> Option<String> {
    let value: Value = serde_json::from_str(stdout).ok()?;
    value
        .pointer("/errors/0/message")
        .and_then(Value::as_str)
        .map(str::to_owned)
}

/// The viewer's pending review id among `PENDING_REVIEW`'s nodes.
#[must_use]
pub fn parse_pending_review(data: &Value) -> Option<String> {
    data.pointer("/node/reviews/nodes")?
        .as_array()?
        .iter()
        .find(|review| review["viewerDidAuthor"] == Value::Bool(true))
        .and_then(|review| review["id"].as_str())
        .map(str::to_owned)
}

/// Parses one page of `THREADS`.
pub fn parse_threads_page(data: &Value) -> Result<ThreadsPage> {
    let pr = data.get("node").context("the pull request was not found")?;
    let head = pr["headRefOid"].as_str().unwrap_or_default().to_owned();
    let threads = pr
        .pointer("/reviewThreads/nodes")
        .and_then(Value::as_array)
        .context("GitHub returned no review threads")?
        .iter()
        .filter_map(parse_thread)
        .collect();
    Ok((head, threads, next_cursor(&pr["reviewThreads"])))
}

/// Parses one page of `FILES`.
pub fn parse_files_page(data: &Value) -> Result<FilesPage> {
    let files = data
        .pointer("/node/files")
        .context("GitHub returned no pull request files")?;
    let parsed = files["nodes"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .filter_map(|file| {
            Some(ChangedFile {
                path: file["path"].as_str()?.to_owned(),
                additions: file["additions"].as_u64().unwrap_or(0),
                deletions: file["deletions"].as_u64().unwrap_or(0),
                viewed: ViewedState::parse(file["viewerViewedState"].as_str()?)?,
            })
        })
        .collect();
    Ok((parsed, next_cursor(files)))
}

fn parse_thread(node: &Value) -> Option<Thread> {
    let path = node["path"].as_str()?.to_owned();
    let side = if node["diffSide"].as_str() == Some("LEFT") {
        Side::Left
    } else {
        Side::Right
    };
    let is_file = node["subjectType"].as_str() == Some("FILE");
    let line = node["line"]
        .as_u64()
        .or_else(|| node["originalLine"].as_u64());
    let anchor = match (is_file, line) {
        (false, Some(end)) => {
            let start = node["startLine"]
                .as_u64()
                .or_else(|| node["originalStartLine"].as_u64())
                .filter(|start| *start != end);
            Anchor {
                file: Some(path),
                kind: if start.is_some() {
                    AnchorKind::Range
                } else {
                    AnchorKind::Line
                },
                side,
                start: Some(start.unwrap_or(end)),
                end: Some(end),
                commit: None,
                snapshot: None,
            }
        }
        _ => Anchor {
            file: Some(path),
            kind: AnchorKind::File,
            side,
            start: None,
            end: None,
            commit: None,
            snapshot: None,
        },
    };
    let comments = node.pointer("/comments/nodes")?.as_array()?;
    Some(Thread {
        id: node["id"].as_str()?.to_owned(),
        origin: Origin::Github,
        anchor,
        state: if node["isResolved"].as_bool().unwrap_or(false) {
            ThreadState::Resolved
        } else {
            ThreadState::Open
        },
        outdated: node["isOutdated"].as_bool().unwrap_or(false),
        messages: comments.iter().filter_map(parse_comment).collect(),
    })
}

fn parse_comment(node: &Value) -> Option<Message> {
    let login = node
        .pointer("/author/login")
        .and_then(Value::as_str)
        .unwrap_or("ghost");
    let is_bot = node.pointer("/author/__typename").and_then(Value::as_str) == Some("Bot");
    Some(Message {
        id: node["id"].as_str()?.to_owned(),
        author: if is_bot && !login.ends_with("[bot]") {
            format!("{login}[bot]")
        } else {
            login.to_owned()
        },
        body: node["body"].as_str().unwrap_or_default().to_owned(),
        created: node["createdAt"].as_str().unwrap_or_default().to_owned(),
        updated: node["updatedAt"].as_str().unwrap_or_default().to_owned(),
        sync: Some(if node["state"].as_str() == Some("PENDING") {
            MessageSync::Draft
        } else {
            MessageSync::Published
        }),
    })
}

fn next_cursor(connection: &Value) -> Option<String> {
    if connection.pointer("/pageInfo/hasNextPage") != Some(&Value::Bool(true)) {
        return None;
    }
    connection
        .pointer("/pageInfo/endCursor")?
        .as_str()
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use review_model::{AnchorKind, MessageSync, Side, ThreadState, ViewedState};
    use serde_json::json;

    use super::*;

    fn comment(id: &str, login: &str, kind: &str, state: &str) -> Value {
        json!({ "id": id, "body": "why?", "url": "u", "createdAt": "c", "updatedAt": "u",
                "state": state, "viewerDidAuthor": false, "author": { "login": login, "__typename": kind } })
    }

    #[test]
    fn parses_line_range_outdated_and_file_threads() {
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
        let (head, threads, cursor) = parse_threads_page(&data).unwrap();
        assert_eq!(head, "head1");
        assert_eq!(cursor.as_deref(), Some("CUR"));
        let line = &threads[0];
        assert_eq!(
            (line.anchor.kind, line.anchor.start, line.anchor.end),
            (AnchorKind::Line, Some(12), Some(12))
        );
        assert_eq!(line.messages[0].sync, Some(MessageSync::Published));
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
        let outdated = &threads[2];
        assert!(outdated.outdated);
        assert_eq!(
            (outdated.anchor.kind, outdated.anchor.end),
            (AnchorKind::Line, Some(4))
        );
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
}
