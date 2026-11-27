//! GitHub GraphQL query and mutation document strings and batch builders.

use std::fmt::Write as _;

use serde_json::{Map, Value};

/// The authenticated viewer's login and pending review on a pull request, if any.
pub const PENDING_REVIEW: &str = r"query($pr: ID!) {
  viewer { login }
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
          nodes {
            id fullDatabaseId body url createdAt updatedAt state viewerDidAuthor
            author { login __typename }
            reactionGroups { content viewerHasReacted reactors { totalCount } }
          }
        }
      }
    }
  } }
}";

/// One page of top-level pull-request conversation comments.
pub const CONVERSATION: &str = r"query($pr: ID!, $after: String) {
  node(id: $pr) { ... on PullRequest {
    comments(first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id body createdAt updatedAt viewerDidAuthor
        author { login __typename }
        reactionGroups { content viewerHasReacted reactors { totalCount } }
      }
    }
  } }
}";

/// Pull-request participants and repository assignable users for `@mention` completion.
pub const MENTIONS: &str = r"query($pr: ID!) {
  node(id: $pr) { ... on PullRequest {
    participants(first: 100) { nodes { login } }
    repository { assignableUsers(first: 100) { nodes { login } } }
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

/// Maximum number of aliased viewed mutations packed into one GraphQL request.
pub const BATCH_VIEWED_CHUNK_SIZE: usize = 50;

/// Builds one parameterized aliased GraphQL mutation marking every path in
/// `paths` viewed (`true`) or unviewed (`false`).
///
/// File paths are placed exclusively in the returned JSON variables map so
/// untrusted filenames never enter the GraphQL document text.
#[must_use]
pub fn build_batch_viewed_mutation(
    pr_node_id: &str,
    paths: &[String],
    viewed: bool,
) -> (String, Value) {
    let field = if viewed {
        "markFileAsViewed"
    } else {
        "unmarkFileAsViewed"
    };
    let mut header = String::from("mutation($pr: ID!");
    let mut body = String::new();
    let mut variables = Map::with_capacity(paths.len() + 1);
    variables.insert("pr".to_owned(), Value::String(pr_node_id.to_owned()));
    for (index, path) in paths.iter().enumerate() {
        let _ = write!(header, ", $p{index}: String!");
        let _ = writeln!(
            body,
            "  f{index}: {field}(input: {{ pullRequestId: $pr, path: $p{index} }}) {{ clientMutationId }}"
        );
        variables.insert(format!("p{index}"), Value::String(path.clone()));
    }
    let query = format!("{header}) {{\n{body}}}");
    (query, Value::Object(variables))
}
