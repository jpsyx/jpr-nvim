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

/// Marks `$path` viewed by the viewer.
pub const MARK_VIEWED: &str = r"mutation($pr: ID!, $path: String!) {
  markFileAsViewed(input: { pullRequestId: $pr, path: $path }) { clientMutationId }
}";

/// Clears the viewer's viewed mark on `$path`.
pub const UNMARK_VIEWED: &str = r"mutation($pr: ID!, $path: String!) {
  unmarkFileAsViewed(input: { pullRequestId: $pr, path: $path }) { clientMutationId }
}";

/// The mutation that marks a file viewed (`true`) or clears the mark.
#[must_use]
pub const fn viewed_flag_to_mutation(viewed: bool) -> &'static str {
    if viewed { MARK_VIEWED } else { UNMARK_VIEWED }
}

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
    let comments = node.pointer("/comments/nodes")?.as_array()?;
    Some(Thread {
        id: node["id"].as_str()?.to_owned(),
        origin: Origin::Github,
        anchor: parse_anchor(node, path),
        state: if node["isResolved"].as_bool().unwrap_or(false) {
            ThreadState::Resolved
        } else {
            ThreadState::Open
        },
        outdated: node["isOutdated"].as_bool().unwrap_or(false),
        messages: comments.iter().filter_map(parse_comment).collect(),
    })
}

/// Where a `THREADS` node on `path` is attached: its lines when GitHub reports
/// any (an outdated thread's original lines when the current ones are gone),
/// else the whole file.
fn parse_anchor(node: &Value, path: String) -> Anchor {
    let side = if node["diffSide"].as_str() == Some("LEFT") {
        Side::Left
    } else {
        Side::Right
    };
    let is_file = node["subjectType"].as_str() == Some("FILE");
    let line = node["line"]
        .as_u64()
        .or_else(|| node["originalLine"].as_u64());
    match (is_file, line) {
        (false, Some(end)) => parse_line_anchor(node, path, side, end),
        _ => Anchor {
            file: Some(path),
            kind: AnchorKind::File,
            side,
            start: None,
            end: None,
            commit: None,
            snapshot: None,
        },
    }
}

/// A line anchor ending at `end`, or a range anchor when the node starts on
/// an earlier line.
fn parse_line_anchor(node: &Value, path: String, side: Side, end: u64) -> Anchor {
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
        viewer_did_author: false,
        database_id: None,
        reactions: Vec::new(),
        sync_error: None,
        recoverable_body: None,
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
mod tests;
