//! GitHub GraphQL mutation documents for review threads, conversation
//! comments, reactions, resolution, and review submission.

pub(super) const ADD_PENDING_REVIEW: &str = r"mutation($pr: ID!, $commit: GitObjectID) {
  addPullRequestReview(input: { pullRequestId: $pr, commitOID: $commit }) {
    pullRequestReview { id }
  }
}";

pub(super) const SUBMIT_DIRECT_REVIEW: &str = r"mutation($pr: ID!, $commit: GitObjectID, $event: PullRequestReviewEvent!, $body: String) {
  addPullRequestReview(input: { pullRequestId: $pr, commitOID: $commit, event: $event, body: $body }) {
    pullRequestReview { id }
  }
}";

pub(super) const SUBMIT_PENDING_REVIEW: &str = r"mutation($pr: ID!, $review: ID!, $event: PullRequestReviewEvent!, $body: String) {
  submitPullRequestReview(input: { pullRequestId: $pr, pullRequestReviewId: $review, event: $event, body: $body }) {
    pullRequestReview { id }
  }
}";

pub(super) const ADD_REVIEW_THREAD: &str = r"mutation($input: AddPullRequestReviewThreadInput!) {
  addPullRequestReviewThread(input: $input) {
    thread {
      id isResolved isOutdated subjectType path line startLine diffSide originalLine originalStartLine
      comments(first: 20) {
        nodes {
          id fullDatabaseId body createdAt updatedAt state viewerDidAuthor
          author { login __typename }
          reactionGroups { content viewerHasReacted reactors { totalCount } }
        }
      }
    }
  }
}";

pub(super) const ADD_THREAD_REPLY: &str = r"mutation($review: ID!, $thread: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: { pullRequestReviewId: $review, pullRequestReviewThreadId: $thread, body: $body }) {
    comment {
      id fullDatabaseId body createdAt updatedAt state viewerDidAuthor
      author { login __typename }
      reactionGroups { content viewerHasReacted reactors { totalCount } }
    }
  }
}";

pub(super) const ADD_ISSUE_COMMENT: &str = r"mutation($pr: ID!, $body: String!) {
  addComment(input: { subjectId: $pr, body: $body }) {
    commentEdge {
      node {
        ... on IssueComment {
          id body createdAt updatedAt viewerDidAuthor
          author { login __typename }
          reactionGroups { content viewerHasReacted reactors { totalCount } }
        }
      }
    }
  }
}";

pub(super) const UPDATE_REVIEW_COMMENT: &str = r"mutation($id: ID!, $body: String!) {
  updatePullRequestReviewComment(input: { pullRequestReviewCommentId: $id, body: $body }) {
    pullRequestReviewComment {
      id fullDatabaseId body createdAt updatedAt state viewerDidAuthor
      author { login __typename }
      reactionGroups { content viewerHasReacted reactors { totalCount } }
    }
  }
}";

pub(super) const UPDATE_ISSUE_COMMENT: &str = r"mutation($id: ID!, $body: String!) {
  updateIssueComment(input: { id: $id, body: $body }) {
    issueComment {
      id body createdAt updatedAt viewerDidAuthor
      author { login __typename }
      reactionGroups { content viewerHasReacted reactors { totalCount } }
    }
  }
}";

pub(super) const DELETE_REVIEW_COMMENT: &str = r"mutation($id: ID!) {
  deletePullRequestReviewComment(input: { id: $id }) { clientMutationId }
}";

pub(super) const DELETE_ISSUE_COMMENT: &str = r"mutation($id: ID!) {
  deleteIssueComment(input: { id: $id }) { clientMutationId }
}";

pub(super) const RESOLVE_THREAD: &str = r"mutation($id: ID!) {
  resolveReviewThread(input: { threadId: $id }) { thread { id } }
}";

pub(super) const UNRESOLVE_THREAD: &str = r"mutation($id: ID!) {
  unresolveReviewThread(input: { threadId: $id }) { thread { id } }
}";

pub(super) const ADD_REACTION: &str = r"mutation($id: ID!, $content: ReactionContent!) {
  addReaction(input: { subjectId: $id, content: $content }) {
    reactionGroups { content viewerHasReacted reactors { totalCount } }
  }
}";

pub(super) const REMOVE_REACTION: &str = r"mutation($id: ID!, $content: ReactionContent!) {
  removeReaction(input: { subjectId: $id, content: $content }) {
    reactionGroups { content viewerHasReacted reactors { totalCount } }
  }
}";
