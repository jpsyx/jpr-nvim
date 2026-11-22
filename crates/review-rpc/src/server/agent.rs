//! RPC method routing for local-comment agent loops, pre-pass writes,
//! thread promotion, and live anchor updates.

use std::sync::Mutex;

use review_core::ReviewSession;
use serde_json::{Value, json};

use super::comments::thread_view_result_to_rpc;
use super::{engine_result_to_rpc, lock, to_value};
use crate::params::{
    get_agent_kind_from_params, get_anchor_updates_from_params, get_optional_string_from_params,
    get_prepass_findings_from_params, get_round_kind_from_params, get_string_from_params,
    get_string_vec_from_params, get_u64_from_params,
};
use crate::protocol::RpcError;

pub(super) fn handle_agent_method(
    session: &Mutex<ReviewSession>,
    method: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    match method {
        "agentReply" => {
            let thread_id = get_string_from_params(params, "threadId")?;
            let body = get_string_from_params(params, "body")?;
            let author = get_optional_string_from_params(params, "author")?;
            thread_view_result_to_rpc(lock(session)?.agent_reply(thread_id, body, author))
        }
        "promoteThread" => {
            let thread_id = get_string_from_params(params, "threadId")?;
            let body = get_string_from_params(params, "body")?;
            thread_view_result_to_rpc(lock(session)?.promote_thread(thread_id, body))
        }
        "prepareAgentLaunch" => {
            let kind = get_agent_kind_from_params(params)?;
            to_value(&engine_result_to_rpc(
                lock(session)?.prepare_agent_launch(kind),
            )?)
        }
        "prepareSend" => {
            let thread_id = get_optional_string_from_params(params, "threadId")?;
            let kind = get_agent_kind_from_params(params)?;
            to_value(&engine_result_to_rpc(
                lock(session)?.prepare_send(thread_id, kind),
            )?)
        }
        _ => handle_prepass_and_anchor_method(session, method, params),
    }
}

fn handle_prepass_and_anchor_method(
    session: &Mutex<ReviewSession>,
    method: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    match method {
        "confirmSend" => {
            let round = get_u64_from_params(params, "round")?;
            let kind = get_round_kind_from_params(params)?;
            let thread_ids = get_string_vec_from_params(params, "threadIds")?;
            let prompt = get_string_from_params(params, "prompt")?;
            let (entry, view) = engine_result_to_rpc(lock(session)?.confirm_send(
                round,
                kind,
                &thread_ids,
                prompt,
            ))?;
            Ok(json!({ "round": entry, "view": view }))
        }
        "preparePrepass" => {
            let kind = get_agent_kind_from_params(params)?;
            to_value(&engine_result_to_rpc(lock(session)?.prepare_prepass(kind))?)
        }
        "prepassWrite" => {
            let findings = get_prepass_findings_from_params(params)?;
            let (threads, view) = engine_result_to_rpc(lock(session)?.prepass_write(findings))?;
            Ok(json!({ "threads": threads, "view": view }))
        }
        "updateLocalAnchors" => {
            let path = get_string_from_params(params, "path")?;
            let updates = get_anchor_updates_from_params(params)?;
            to_value(&engine_result_to_rpc(
                lock(session)?.update_local_anchors(path, &updates),
            )?)
        }
        other => Err(RpcError::new(
            RpcError::METHOD_NOT_FOUND,
            format!("unknown method {other:?}"),
        )),
    }
}
