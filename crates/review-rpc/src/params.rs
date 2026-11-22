//! Reading a request's params. A param that is missing or of the wrong type
//! is an invalid-params error that says what was expected.

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
mod tests {
    use review_model::{AnchorKind, ReactionContent, ReviewEvent, Side, ViewMode};
    use serde_json::{Value, json};

    use super::*;

    #[test]
    fn reads_strings_booleans_and_modes() {
        let params = json!({ "path": "a.rs", "viewed": true, "mode": "split" });
        assert_eq!(get_string_from_params(&params, "path").unwrap(), "a.rs");
        assert!(get_bool_from_params(&params, "viewed").unwrap());
        assert_eq!(get_mode_from_params(&params).unwrap(), ViewMode::Split);
    }

    #[test]
    fn missing_or_mistyped_params_are_invalid() {
        let params = json!({ "path": 7, "mode": "sideways" });
        for error in [
            get_string_from_params(&params, "path").unwrap_err(),
            get_bool_from_params(&params, "viewed").unwrap_err(),
            get_mode_from_params(&params).unwrap_err(),
            get_string_from_params(&Value::Null, "path").unwrap_err(),
        ] {
            assert_eq!(error.code, RpcError::INVALID_PARAMS, "{}", error.message);
        }
    }

    #[test]
    fn anchor_extractor_deserializes_valid_anchor_and_rejects_malformed_object() {
        let anchor_params = json!({
            "anchor": { "file": "src/a.rs", "kind": "range", "side": "LEFT", "start": 2, "end": 5 },
        });
        let anchor = get_anchor_from_params(&anchor_params).unwrap();
        assert_eq!(anchor.kind, AnchorKind::Range);
        assert_eq!(anchor.side, Side::Left);
        assert_eq!(
            get_anchor_from_params(&json!({ "anchor": 12 }))
                .unwrap_err()
                .code,
            RpcError::INVALID_PARAMS
        );
    }

    #[test]
    fn reaction_and_review_event_extractors_validate_known_wire_names() {
        let react = json!({ "messageId": "C1", "content": "THUMBS_UP" });
        assert_eq!(
            get_reaction_from_params(&react).unwrap(),
            ReactionContent::ThumbsUp
        );
        assert_eq!(
            get_reaction_from_params(&json!({ "content": "SPARKLES" }))
                .unwrap_err()
                .code,
            RpcError::INVALID_PARAMS
        );

        let submit = json!({ "event": "APPROVE" });
        assert_eq!(
            get_review_event_from_params(&submit).unwrap(),
            ReviewEvent::Approve
        );
        assert_eq!(
            get_review_event_from_params(&json!({ "event": "DISMISS" }))
                .unwrap_err()
                .code,
            RpcError::INVALID_PARAMS
        );
    }

    #[test]
    fn optional_string_and_u64_extractors_accept_null_and_unsigned_integers() {
        let params = json!({ "body": "ship it", "cursorLine": 42 });
        assert_eq!(
            get_optional_string_from_params(&params, "body").unwrap(),
            Some("ship it")
        );
        assert_eq!(
            get_optional_string_from_params(&json!({ "body": null }), "body").unwrap(),
            None
        );
        assert_eq!(get_u64_from_params(&params, "cursorLine").unwrap(), 42);
    }

    #[test]
    fn origin_and_agent_kind_default_and_validate() {
        assert_eq!(get_origin_from_params(&json!({})).unwrap(), Origin::Github);
        assert_eq!(
            get_origin_from_params(&Value::Null).unwrap(),
            Origin::Github
        );
        assert_eq!(
            get_origin_from_params(&json!({ "origin": "local" })).unwrap(),
            Origin::Local
        );
        assert_eq!(
            get_origin_from_params(&json!({ "origin": "bad" }))
                .unwrap_err()
                .code,
            RpcError::INVALID_PARAMS
        );
        assert_eq!(
            get_agent_kind_from_params(&json!({})).unwrap(),
            AgentKind::Claude
        );
        assert_eq!(
            get_agent_kind_from_params(&json!({ "agent": "codex" })).unwrap(),
            AgentKind::Codex
        );
        assert_eq!(
            get_agent_kind_from_params(&json!({ "agent": "other" }))
                .unwrap_err()
                .code,
            RpcError::INVALID_PARAMS
        );
    }

    #[test]
    fn round_kind_parses_send_prepass_and_conflict_and_rejects_unknown() {
        assert_eq!(
            get_round_kind_from_params(&json!({ "kind": "send" })).unwrap(),
            AgentRoundKind::Send
        );
        assert_eq!(
            get_round_kind_from_params(&json!({ "kind": "prepass" })).unwrap(),
            AgentRoundKind::Prepass
        );
        assert_eq!(
            get_round_kind_from_params(&json!({ "kind": "conflict" })).unwrap(),
            AgentRoundKind::Conflict
        );
        let invalid_error = get_round_kind_from_params(&json!({ "kind": "unknown" })).unwrap_err();
        assert_eq!(invalid_error.code, RpcError::INVALID_PARAMS);
        assert!(
            invalid_error
                .message
                .contains("\"send\", \"prepass\", or \"conflict\""),
            "{}",
            invalid_error.message
        );
    }

    #[test]
    fn string_vec_prepass_findings_and_anchor_updates_parse_arrays() {
        assert_eq!(
            get_string_vec_from_params(&json!({ "threadIds": ["loc-1"] }), "threadIds").unwrap(),
            vec!["loc-1".to_owned()]
        );
        assert_eq!(
            get_string_vec_from_params(&json!({ "threadIds": [1] }), "threadIds")
                .unwrap_err()
                .code,
            RpcError::INVALID_PARAMS
        );
        let findings = get_prepass_findings_from_params(&json!({
            "findings": [{ "anchor": Anchor::line("src/a.rs", 2), "body": "bug" }]
        }))
        .unwrap();
        assert_eq!(findings.len(), 1);
        assert_eq!(
            get_prepass_findings_from_params(&json!({ "findings": {} }))
                .unwrap_err()
                .code,
            RpcError::INVALID_PARAMS
        );
        let updates = get_anchor_updates_from_params(&json!({
            "updates": [{ "threadId": "loc-1", "start": 3, "end": 4 }]
        }))
        .unwrap();
        assert_eq!(updates.len(), 1);
        assert_eq!(updates[0].start, 3);
    }

    #[test]
    fn non_object_and_numeric_edge_cases_are_rejected_as_invalid_params() {
        assert_eq!(
            get_optional_string_from_params(&Value::Null, "origin").unwrap(),
            None
        );
        for bad in [json!([123]), json!(42), json!("local"), json!(true)] {
            assert_eq!(
                get_optional_string_from_params(&bad, "origin")
                    .unwrap_err()
                    .code,
                RpcError::INVALID_PARAMS
            );
            assert_eq!(
                get_origin_from_params(&bad).unwrap_err().code,
                RpcError::INVALID_PARAMS
            );
            assert_eq!(
                get_agent_kind_from_params(&bad).unwrap_err().code,
                RpcError::INVALID_PARAMS
            );
        }
        for bad_round in [json!({ "round": -1 }), json!({ "round": 1.5 })] {
            assert_eq!(
                get_u64_from_params(&bad_round, "round").unwrap_err().code,
                RpcError::INVALID_PARAMS
            );
        }
        assert_eq!(
            get_anchor_updates_from_params(
                &json!({ "updates": [{ "threadId": "loc-1", "start": -2, "end": 1.5 }] })
            )
            .unwrap_err()
            .code,
            RpcError::INVALID_PARAMS
        );
        assert_eq!(
            get_origin_from_params(&json!({ "origin": 123 }))
                .unwrap_err()
                .code,
            RpcError::INVALID_PARAMS
        );
    }
}
