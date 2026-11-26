//! Reading a request's params. A param that is missing or of the wrong type
//! is an invalid-params error that says what was expected.

use review_core::PathRename;
use review_model::{
    AgentKind, AgentRoundKind, Anchor, LocalAnchorUpdate, Origin, PrepassFinding, ReactionContent,
    ReviewEvent, ViewMode,
};
use serde::Deserialize;
use serde_json::Value;

use crate::protocol::RpcError;

/// The string param `name`.
pub fn get_string_from_params<'a>(params: &'a Value, name: &str) -> Result<&'a str, RpcError> {
    params
        .get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| create_invalid_params_error(&format!("expected a string \"{name}\"")))
}

/// Extracts optional string param `name`, returning `Ok(None)` when omitted or
/// `null` and `RpcError::INVALID_PARAMS` otherwise, for example for
/// `commentBody` or `submitReview`'s `body`.
pub fn get_optional_string_from_params<'a>(
    params: &'a Value,
    name: &str,
) -> Result<Option<&'a str>, RpcError> {
    ensure_object_or_null(params)?;
    match params.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value.as_str().map(Some).ok_or_else(|| {
            create_invalid_params_error(&format!("expected \"{name}\" to be a string or null"))
        }),
    }
}

/// The boolean param `name`.
pub fn get_bool_from_params(params: &Value, name: &str) -> Result<bool, RpcError> {
    params
        .get(name)
        .and_then(Value::as_bool)
        .ok_or_else(|| create_invalid_params_error(&format!("expected a boolean \"{name}\"")))
}

/// Extracts unsigned integer param `name` or returns `RpcError::INVALID_PARAMS`
/// when missing or non-numeric, for example for `suggestFromEdit`'s
/// `cursorLine`.
pub fn get_u64_from_params(params: &Value, name: &str) -> Result<u64, RpcError> {
    params
        .get(name)
        .and_then(Value::as_u64)
        .ok_or_else(|| create_invalid_params_error(&format!("expected an integer \"{name}\"")))
}

/// The `mode` param: `unified` or `split`.
pub fn get_mode_from_params(params: &Value) -> Result<ViewMode, RpcError> {
    params
        .get("mode")
        .and_then(Value::as_str)
        .and_then(ViewMode::parse)
        .ok_or_else(|| {
            create_invalid_params_error("expected \"mode\" to be \"unified\" or \"split\"")
        })
}

/// Deserializes the `anchor` object param into an [`Anchor`] or returns
/// `RpcError::INVALID_PARAMS` when missing or malformed, for example in
/// `comment` and `anchoredLines` requests.
pub fn get_anchor_from_params(params: &Value) -> Result<Anchor, RpcError> {
    let raw = params
        .get("anchor")
        .ok_or_else(|| create_invalid_params_error("expected an \"anchor\" object"))?;
    Anchor::deserialize(raw)
        .map_err(|error| create_invalid_params_error(&format!("invalid \"anchor\": {error}")))
}

/// Extracts and validates the `content` reaction param (such as `THUMBS_UP` or
/// `HEART`) or returns `RpcError::INVALID_PARAMS`, for example in
/// `toggleReaction` requests.
pub fn get_reaction_from_params(params: &Value) -> Result<ReactionContent, RpcError> {
    let raw = get_string_from_params(params, "content")?;
    ReactionContent::parse(raw)
        .ok_or_else(|| create_invalid_params_error(&format!("unknown reaction \"{raw}\"")))
}

/// Extracts and validates the `event` review submission param (`COMMENT`,
/// `APPROVE`, or `REQUEST_CHANGES`) or returns `RpcError::INVALID_PARAMS`, for
/// example in `submitReview` requests.
pub fn get_review_event_from_params(params: &Value) -> Result<ReviewEvent, RpcError> {
    let raw = get_string_from_params(params, "event")?;
    ReviewEvent::parse(raw)
        .ok_or_else(|| create_invalid_params_error(&format!("unknown review event \"{raw}\"")))
}

/// Extracts optional `origin` (`"github"` or `"local"`), defaulting to
/// [`Origin::Github`] when omitted or `null`.
pub fn get_origin_from_params(params: &Value) -> Result<Origin, RpcError> {
    match get_optional_string_from_params(params, "origin")? {
        None | Some("github") => Ok(Origin::Github),
        Some("local") => Ok(Origin::Local),
        Some(other) => Err(create_invalid_params_error(&format!(
            "expected \"origin\" to be \"github\" or \"local\", got \"{other}\""
        ))),
    }
}

/// Extracts optional `agent` (`"claude"` or `"codex"`), defaulting to
/// [`AgentKind::Claude`] when omitted or `null`.
pub fn get_agent_kind_from_params(params: &Value) -> Result<AgentKind, RpcError> {
    get_optional_string_from_params(params, "agent")?.map_or(Ok(AgentKind::Claude), |raw| {
        AgentKind::parse(raw).ok_or_else(|| {
            create_invalid_params_error(&format!(
                "expected \"agent\" to be \"claude\" or \"codex\", got \"{raw}\""
            ))
        })
    })
}

/// Extracts required `kind` (`"send"`, `"prepass"`, or `"conflict"`) for
/// `confirmSend`.
pub fn get_round_kind_from_params(params: &Value) -> Result<AgentRoundKind, RpcError> {
    match get_string_from_params(params, "kind")? {
        "send" => Ok(AgentRoundKind::Send),
        "prepass" => Ok(AgentRoundKind::Prepass),
        "conflict" => Ok(AgentRoundKind::Conflict),
        other => Err(create_invalid_params_error(&format!(
            "expected \"kind\" to be \"send\", \"prepass\", or \"conflict\", got \"{other}\""
        ))),
    }
}

/// Extracts a required array of strings at `key`.
pub fn get_string_vec_from_params(params: &Value, key: &str) -> Result<Vec<String>, RpcError> {
    let items = params.get(key).and_then(Value::as_array).ok_or_else(|| {
        create_invalid_params_error(&format!("expected a string array \"{key}\""))
    })?;
    let mut values = Vec::with_capacity(items.len());
    for item in items {
        let text = item.as_str().ok_or_else(|| {
            create_invalid_params_error(&format!("expected strings inside \"{key}\""))
        })?;
        values.push(text.to_owned());
    }
    Ok(values)
}

/// Extracts either a single string `"path"` or a non-empty string array
/// `"paths"` for `setViewed`, rejecting missing, ambiguous, or empty values.
pub fn get_viewed_paths_from_params(params: &Value) -> Result<Vec<String>, RpcError> {
    let has_path = params.get("path").is_some();
    let has_paths = params.get("paths").is_some();
    match (has_path, has_paths) {
        (true, false) => Ok(vec![get_string_from_params(params, "path")?.to_owned()]),
        (false, true) => {
            let paths = get_string_vec_from_params(params, "paths")?;
            if paths.is_empty() {
                return Err(create_invalid_params_error(
                    "expected a non-empty string array \"paths\"",
                ));
            }
            Ok(paths)
        }
        (true, true) => Err(create_invalid_params_error(
            "expected only one of \"path\" or \"paths\"",
        )),
        (false, false) => Err(create_invalid_params_error(
            "expected a string \"path\" or non-empty string array \"paths\"",
        )),
    }
}

/// Extracts and deserializes the `findings` array for `prepassWrite`.
pub fn get_prepass_findings_from_params(params: &Value) -> Result<Vec<PrepassFinding>, RpcError> {
    let raw = params
        .get("findings")
        .filter(|value| value.is_array())
        .ok_or_else(|| create_invalid_params_error("expected a \"findings\" array"))?;
    Vec::<PrepassFinding>::deserialize(raw)
        .map_err(|error| create_invalid_params_error(&format!("invalid \"findings\": {error}")))
}

/// Extracts and deserializes the `updates` array for `updateLocalAnchors`.
pub fn get_anchor_updates_from_params(params: &Value) -> Result<Vec<LocalAnchorUpdate>, RpcError> {
    let raw = params
        .get("updates")
        .filter(|value| value.is_array())
        .ok_or_else(|| create_invalid_params_error("expected an \"updates\" array"))?;
    Vec::<LocalAnchorUpdate>::deserialize(raw)
        .map_err(|error| create_invalid_params_error(&format!("invalid \"updates\": {error}")))
}

/// Extracts optional `renames` array for `refreshWorktree`, defaulting to an
/// empty list when omitted or `null`.
pub fn get_renames_from_params(params: &Value) -> Result<Vec<PathRename>, RpcError> {
    ensure_object_or_null(params)?;
    match params.get("renames") {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(raw) if raw.is_array() => Vec::<PathRename>::deserialize(raw)
            .map_err(|error| create_invalid_params_error(&format!("invalid \"renames\": {error}"))),
        Some(_) => Err(create_invalid_params_error(
            "expected \"renames\" to be an array",
        )),
    }
}

fn ensure_object_or_null(params: &Value) -> Result<(), RpcError> {
    if params.is_object() || params.is_null() {
        Ok(())
    } else {
        Err(create_invalid_params_error(
            "expected params to be an object or null",
        ))
    }
}

fn create_invalid_params_error(message: &str) -> RpcError {
    RpcError::new(RpcError::INVALID_PARAMS, message)
}

#[cfg(test)]
mod tests;
