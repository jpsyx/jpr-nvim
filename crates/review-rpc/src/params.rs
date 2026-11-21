//! Reading a request's params. A param that is missing or of the wrong type
//! is an invalid-params error that says what was expected.

use review_model::{Anchor, ReactionContent, ReviewEvent, ViewMode};
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
        .cloned()
        .ok_or_else(|| create_invalid_params_error("expected an \"anchor\" object"))?;
    serde_json::from_value(raw)
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
}
