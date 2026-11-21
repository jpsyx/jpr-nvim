//! RPC method routing for comment threads, reactions, suggestions, and
//! review submission.

use std::sync::Mutex;

use review_core::ReviewSession;
use serde_json::{Value, json};

use super::{engine_result_to_rpc, lock, to_value};
use crate::params::{
    get_anchor_from_params, get_bool_from_params, get_optional_string_from_params,
    get_reaction_from_params, get_review_event_from_params, get_string_from_params,
    get_u64_from_params,
};
use crate::protocol::RpcError;

pub(super) fn handle_comment_method(
    session: &Mutex<ReviewSession>,
    method: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    match method {
        "threads" => to_value(&json!({ "threads": lock(session)?.threads() })),
        "mentions" => to_value(&json!({ "candidates": lock(session)?.mentions() })),
        "comment" => {
            let anchor = get_anchor_from_params(params)?;
            let body = get_string_from_params(params, "body")?;
            thread_view_result_to_rpc(lock(session)?.comment(anchor, body))
        }
        "reply" => {
            let thread_id = get_string_from_params(params, "threadId")?;
            let body = get_string_from_params(params, "body")?;
            thread_view_result_to_rpc(lock(session)?.reply(thread_id, body))
        }
        "editMessage" => {
            let message_id = get_string_from_params(params, "messageId")?;
            let body = get_string_from_params(params, "body")?;
            thread_view_result_to_rpc(lock(session)?.edit_message(message_id, body))
        }
        "deleteMessage" => {
            let message_id = get_string_from_params(params, "messageId")?;
            to_value(&engine_result_to_rpc(
                lock(session)?.delete_message(message_id),
            )?)
        }
        "setResolved" => {
            let thread_id = get_string_from_params(params, "threadId")?;
            let is_resolved = get_bool_from_params(params, "resolved")?;
            thread_view_result_to_rpc(lock(session)?.set_resolved(thread_id, is_resolved))
        }
        _ => handle_reaction_and_review_method(session, method, params),
    }
}

fn handle_reaction_and_review_method(
    session: &Mutex<ReviewSession>,
    method: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    match method {
        "toggleReaction" => {
            let message_id = get_string_from_params(params, "messageId")?;
            let content = get_reaction_from_params(params)?;
            thread_view_result_to_rpc(lock(session)?.toggle_reaction(message_id, content))
        }
        "retryMessage" => {
            let message_id = get_string_from_params(params, "messageId")?;
            to_value(&engine_result_to_rpc(
                lock(session)?.retry_message(message_id),
            )?)
        }
        "anchoredLines" => {
            let anchor = get_anchor_from_params(params)?;
            let text = engine_result_to_rpc(lock(session)?.anchored_lines(&anchor))?;
            Ok(json!({ "text": text }))
        }
        "suggestFromEdit" => handle_suggest_from_edit(session, params),
        "submitPreview" => to_value(&engine_result_to_rpc(lock(session)?.submit_preview())?),
        "submitReview" => {
            let event = get_review_event_from_params(params)?;
            let body = get_optional_string_from_params(params, "body")?.unwrap_or_default();
            to_value(&engine_result_to_rpc(
                lock(session)?.submit_review(event, body),
            )?)
        }
        other => Err(RpcError::new(
            RpcError::METHOD_NOT_FOUND,
            format!("unknown method {other:?}"),
        )),
    }
}

fn handle_suggest_from_edit(
    session: &Mutex<ReviewSession>,
    params: &Value,
) -> Result<Value, RpcError> {
    let path = get_string_from_params(params, "path")?;
    let edited_text = get_string_from_params(params, "editedText")?;
    let cursor_line = get_u64_from_params(params, "cursorLine")?;
    let comment_body = get_optional_string_from_params(params, "commentBody")?;
    let (suggested, thread, view) = engine_result_to_rpc(lock(session)?.suggest_from_edit(
        path,
        edited_text,
        cursor_line,
        comment_body,
    ))?;
    Ok(json!({ "suggested": suggested, "thread": thread, "view": view }))
}

fn thread_view_result_to_rpc(
    result: anyhow::Result<(review_model::Thread, review_model::SessionView)>,
) -> Result<Value, RpcError> {
    let (thread, view) = engine_result_to_rpc(result)?;
    Ok(json!({ "thread": thread, "view": view }))
}
