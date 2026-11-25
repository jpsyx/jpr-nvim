//! GitHub GraphQL mutations, REST immediate-reply parsing, and write-error
//! classification.

mod documents;

use anyhow::{Context, Result};
use documents::{
    ADD_ISSUE_COMMENT, ADD_PENDING_REVIEW, ADD_REACTION, ADD_REVIEW_THREAD, ADD_THREAD_REPLY,
    DELETE_ISSUE_COMMENT, DELETE_REVIEW_COMMENT, REMOVE_REACTION, RESOLVE_THREAD,
    SUBMIT_DIRECT_REVIEW, SUBMIT_PENDING_REVIEW, UNRESOLVE_THREAD, UPDATE_ISSUE_COMMENT,
    UPDATE_REVIEW_COMMENT,
};
use review_core::ports::{CreatedReviewThread, ForgeWriteError, ReplyRequest};
use review_model::{
    Anchor, AnchorKind, Message, MessageSync, PullRequest, Reaction, ReactionContent, ReviewEvent,
    Side, Thread,
};
use serde_json::{Map, Value, json};

use crate::GhForge;
use crate::graphql::{
    PENDING_REVIEW, build_author_display_login, is_valid_database_id, parse_comment,
    parse_decimal_database_id, parse_issue_comment_thread, parse_pending_review, parse_reactions,
    parse_thread,
};

fn build_thread_variables(pr_id: &str, review_id: &str, anchor: &Anchor, body: &str) -> Value {
    let mut input = Map::new();
    input.insert("pullRequestId".into(), Value::String(pr_id.to_owned()));
    input.insert(
        "pullRequestReviewId".into(),
        Value::String(review_id.to_owned()),
    );
    input.insert(
        "path".into(),
        Value::String(anchor.file.clone().unwrap_or_default()),
    );
    input.insert("body".into(), Value::String(body.to_owned()));
    if anchor.kind == AnchorKind::File {
        input.insert("subjectType".into(), Value::String("FILE".into()));
        return Value::Object(input);
    }
    let side_label = if anchor.side == Side::Left {
        "LEFT"
    } else {
        "RIGHT"
    };
    input.insert("subjectType".into(), Value::String("LINE".into()));
    input.insert("line".into(), json!(anchor.end.unwrap_or(1)));
    input.insert("side".into(), Value::String(side_label.into()));
    if anchor.kind == AnchorKind::Range
        && let Some(start) = anchor.start
    {
        input.insert("startLine".into(), json!(start));
        input.insert("startSide".into(), Value::String(side_label.into()));
    }
    Value::Object(input)
}

fn is_safe_path_segment(segment: &str) -> bool {
    !segment.is_empty()
        && segment != "."
        && segment != ".."
        && !segment.bytes().any(|byte| {
            matches!(byte, b'/' | b'\\' | b'?' | b'#')
                || byte.is_ascii_whitespace()
                || byte.is_ascii_control()
        })
}

fn build_rest_reply_endpoint(
    pr: &PullRequest,
    root_database_id: &str,
) -> std::result::Result<String, ForgeWriteError> {
    if !is_safe_path_segment(&pr.owner) || !is_safe_path_segment(&pr.repo) {
        return Err(ForgeWriteError::Rejected(format!(
            "invalid repository path segment: {}/{}",
            pr.owner, pr.repo
        )));
    }
    if !is_valid_database_id(root_database_id) {
        return Err(ForgeWriteError::Rejected(format!(
            "invalid pull request comment database id: {root_database_id}"
        )));
    }
    Ok(format!(
        "repos/{}/{}/pulls/{}/comments/{root_database_id}/replies",
        pr.owner, pr.repo, pr.number
    ))
}

fn classify_write_error(error: &anyhow::Error) -> ForgeWriteError {
    let text = format!("{error:#}");
    if review_core::is_auth_error(error) || review_core::is_gh_auth_failure_text(&text) {
        return ForgeWriteError::AuthRequired(text);
    }
    let lower = text.to_lowercase();
    let is_transient = [
        "timed out",
        "connecting",
        "connection",
        "network",
        "temporary",
        "eof",
        "reset by peer",
        "http 500",
        "http 502",
        "http 503",
        "http 504",
        "http 5",
        "http 429",
        "too many requests",
        "rate limit",
        "is the github cli installed",
    ]
    .iter()
    .any(|needle| lower.contains(needle));
    if is_transient {
        ForgeWriteError::Transient(text)
    } else {
        ForgeWriteError::Rejected(text)
    }
}

fn is_pending_review_rest_conflict(message: &str) -> bool {
    let has_validation_code = message.contains("422") || message.contains("Validation Failed");
    has_validation_code && message.to_lowercase().contains("pending review")
}

fn parse_rest_reply(stdout: &str) -> Result<Message> {
    let node: Value = serde_json::from_str(stdout).context("parsing GitHub REST reply JSON")?;
    let id = node["node_id"]
        .as_str()
        .context("REST reply had no node_id")?
        .to_owned();
    let login = node
        .pointer("/user/login")
        .and_then(Value::as_str)
        .unwrap_or("ghost");
    let is_bot = node.pointer("/user/type").and_then(Value::as_str) == Some("Bot");
    Ok(Message {
        id,
        author: build_author_display_login(login, is_bot),
        body: node["body"].as_str().unwrap_or_default().to_owned(),
        created: node["created_at"].as_str().unwrap_or_default().to_owned(),
        updated: node["updated_at"].as_str().unwrap_or_default().to_owned(),
        sync: Some(MessageSync::Published),
        viewer_did_author: true,
        database_id: parse_decimal_database_id(&node["id"]),
        reactions: Vec::new(),
        sync_error: None,
        recoverable_body: None,
    })
}

impl GhForge {
    fn ensure_pending_review(
        &self,
        pr: &PullRequest,
        existing: Option<&str>,
    ) -> std::result::Result<String, ForgeWriteError> {
        if let Some(review_id) = existing {
            return Ok(review_id.to_owned());
        }
        let variables = json!({
            "pr": pr.node_id,
            "commit": (!pr.head_sha.is_empty()).then_some(pr.head_sha.as_str()),
        });
        let data = self
            .graphql(ADD_PENDING_REVIEW, &variables)
            .map_err(|err| classify_write_error(&err))?;
        data.pointer("/addPullRequestReview/pullRequestReview/id")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| ForgeWriteError::Rejected("GitHub returned no pending review id".into()))
    }

    pub(super) fn create_review_thread_impl(
        &self,
        pr: &PullRequest,
        pending_review_id: Option<&str>,
        anchor: &Anchor,
        body: &str,
    ) -> std::result::Result<CreatedReviewThread, ForgeWriteError> {
        let review_id = self.ensure_pending_review(pr, pending_review_id)?;
        let input = build_thread_variables(&pr.node_id, &review_id, anchor, body);
        let data = self
            .graphql(ADD_REVIEW_THREAD, &json!({ "input": input }))
            .map_err(|err| classify_write_error(&err))?;
        let thread_node = data
            .pointer("/addPullRequestReviewThread/thread")
            .ok_or_else(|| ForgeWriteError::Rejected("GitHub returned no review thread".into()))?;
        let thread = parse_thread(thread_node).ok_or_else(|| {
            ForgeWriteError::Rejected("could not parse created review thread".into())
        })?;
        Ok(CreatedReviewThread {
            pending_review_id: review_id,
            thread,
        })
    }

    pub(super) fn create_conversation_comment_impl(
        &self,
        pr: &PullRequest,
        body: &str,
    ) -> std::result::Result<Thread, ForgeWriteError> {
        let data = self
            .graphql(
                ADD_ISSUE_COMMENT,
                &json!({ "pr": pr.node_id, "body": body }),
            )
            .map_err(|err| classify_write_error(&err))?;
        let node = data
            .pointer("/addComment/commentEdge/node")
            .ok_or_else(|| ForgeWriteError::Rejected("GitHub returned no issue comment".into()))?;
        parse_issue_comment_thread(node)
            .ok_or_else(|| ForgeWriteError::Rejected("could not parse issue comment".into()))
    }

    pub(super) fn reply_to_thread_impl(
        &self,
        pr: &PullRequest,
        request: &ReplyRequest<'_>,
    ) -> std::result::Result<Message, ForgeWriteError> {
        if let Some(review_id) = request.pending_review_id {
            return self.reply_in_pending_review(review_id, request.thread_id, request.body);
        }
        if let Some(root_database_id) = request.root_database_id {
            return self.reply_via_rest(pr, root_database_id, request.thread_id, request.body);
        }
        self.reply_in_fetched_pending_review(pr, request.thread_id, request.body)
    }

    fn reply_in_fetched_pending_review(
        &self,
        pr: &PullRequest,
        thread_id: &str,
        body: &str,
    ) -> std::result::Result<Message, ForgeWriteError> {
        let pending_data = self
            .graphql(PENDING_REVIEW, &json!({ "pr": pr.node_id }))
            .map_err(|err| classify_write_error(&err))?;
        let existing = parse_pending_review(&pending_data);
        let review_id = self.ensure_pending_review(pr, existing.as_deref())?;
        self.reply_in_pending_review(&review_id, thread_id, body)
    }

    fn reply_via_rest(
        &self,
        pr: &PullRequest,
        root_database_id: &str,
        thread_id: &str,
        body: &str,
    ) -> std::result::Result<Message, ForgeWriteError> {
        let endpoint = build_rest_reply_endpoint(pr, root_database_id)?;
        match self.gh.run(
            &["api", &endpoint, "--method", "POST", "--input", "-"],
            Some(&json!({ "body": body })),
        ) {
            Ok(stdout) => parse_rest_reply(&stdout).map_err(|err| classify_write_error(&err)),
            Err(error) if is_pending_review_rest_conflict(&format!("{error:#}")) => {
                self.reply_in_fetched_pending_review(pr, thread_id, body)
            }
            Err(error) => Err(classify_write_error(&error)),
        }
    }

    fn reply_in_pending_review(
        &self,
        review_id: &str,
        thread_id: &str,
        body: &str,
    ) -> std::result::Result<Message, ForgeWriteError> {
        let variables = json!({ "review": review_id, "thread": thread_id, "body": body });
        let data = self
            .graphql(ADD_THREAD_REPLY, &variables)
            .map_err(|err| classify_write_error(&err))?;
        data.pointer("/addPullRequestReviewThreadReply/comment")
            .and_then(parse_comment)
            .ok_or_else(|| ForgeWriteError::Rejected("GitHub returned no reply comment".into()))
    }

    pub(super) fn edit_message_impl(
        &self,
        anchor_kind: AnchorKind,
        message_id: &str,
        body: &str,
    ) -> std::result::Result<Message, ForgeWriteError> {
        let (mutation, pointer) = if anchor_kind == AnchorKind::Pr {
            (UPDATE_ISSUE_COMMENT, "/updateIssueComment/issueComment")
        } else {
            (
                UPDATE_REVIEW_COMMENT,
                "/updatePullRequestReviewComment/pullRequestReviewComment",
            )
        };
        let data = self
            .graphql(mutation, &json!({ "id": message_id, "body": body }))
            .map_err(|err| classify_write_error(&err))?;
        data.pointer(pointer)
            .and_then(parse_comment)
            .ok_or_else(|| ForgeWriteError::Rejected("GitHub returned no updated comment".into()))
    }

    pub(super) fn delete_message_impl(
        &self,
        anchor_kind: AnchorKind,
        message_id: &str,
    ) -> std::result::Result<(), ForgeWriteError> {
        let mutation = if anchor_kind == AnchorKind::Pr {
            DELETE_ISSUE_COMMENT
        } else {
            DELETE_REVIEW_COMMENT
        };
        self.graphql(mutation, &json!({ "id": message_id }))
            .map_err(|err| classify_write_error(&err))?;
        Ok(())
    }

    pub(super) fn set_resolved_impl(
        &self,
        thread_id: &str,
        resolved: bool,
    ) -> std::result::Result<(), ForgeWriteError> {
        let mutation = if resolved {
            RESOLVE_THREAD
        } else {
            UNRESOLVE_THREAD
        };
        self.graphql(mutation, &json!({ "id": thread_id }))
            .map_err(|err| classify_write_error(&err))?;
        Ok(())
    }

    pub(super) fn set_reaction_impl(
        &self,
        subject_id: &str,
        content: ReactionContent,
        added: bool,
    ) -> std::result::Result<Vec<Reaction>, ForgeWriteError> {
        let (mutation, pointer) = if added {
            (ADD_REACTION, "/addReaction")
        } else {
            (REMOVE_REACTION, "/removeReaction")
        };
        let variables = json!({ "id": subject_id, "content": content.as_str() });
        let data = self
            .graphql(mutation, &variables)
            .map_err(|err| classify_write_error(&err))?;
        let container = data
            .pointer(pointer)
            .ok_or_else(|| ForgeWriteError::Rejected("GitHub returned no reactionGroups".into()))?;
        Ok(parse_reactions(container))
    }

    pub(super) fn submit_review_impl(
        &self,
        pr: &PullRequest,
        pending_review_id: Option<&str>,
        event: ReviewEvent,
        body: &str,
    ) -> std::result::Result<(), ForgeWriteError> {
        let optional_body = (!body.trim().is_empty()).then_some(body);
        if let Some(review_id) = pending_review_id {
            let variables = json!({
                "pr": pr.node_id,
                "review": review_id,
                "event": event.as_str(),
                "body": optional_body,
            });
            self.graphql(SUBMIT_PENDING_REVIEW, &variables)
                .map_err(|err| classify_write_error(&err))?;
        } else {
            let variables = json!({
                "pr": pr.node_id,
                "commit": (!pr.head_sha.is_empty()).then_some(pr.head_sha.as_str()),
                "event": event.as_str(),
                "body": optional_body,
            });
            self.graphql(SUBMIT_DIRECT_REVIEW, &variables)
                .map_err(|err| classify_write_error(&err))?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests;
