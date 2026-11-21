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

/// An optional string param `name`: returns `None` when omitted or `null`.
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

/// The unsigned integer param `name`.
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

/// The `anchor` object param, deserialized into an [`Anchor`].
pub fn get_anchor_from_params(params: &Value) -> Result<Anchor, RpcError> {
    let raw = params
        .get("anchor")
        .cloned()
        .ok_or_else(|| create_invalid_params_error("expected an \"anchor\" object"))?;
    serde_json::from_value(raw)
        .map_err(|error| create_invalid_params_error(&format!("invalid \"anchor\": {error}")))
}

/// The `content` reaction param, such as `THUMBS_UP` or `HEART`.
pub fn get_reaction_from_params(params: &Value) -> Result<ReactionContent, RpcError> {
    let raw = get_string_from_params(params, "content")?;
    ReactionContent::parse(raw)
        .ok_or_else(|| create_invalid_params_error(&format!("unknown reaction \"{raw}\"")))
}

/// The `event` review submission param: `COMMENT`, `APPROVE`, or `REQUEST_CHANGES`.
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
    use review_model::ViewMode;
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
    fn parses_anchor_reaction_and_review_event_params() {
        let anchor_params = json!({
            "anchor": { "file": "src/a.rs", "kind": "range", "side": "LEFT", "start": 2, "end": 5 },
            "body": "nit"
        });
        let anchor = get_anchor_from_params(&anchor_params).unwrap();
        assert_eq!(anchor.kind, review_model::AnchorKind::Range);
        assert_eq!(anchor.side, review_model::Side::Left);

        let react = json!({ "messageId": "C1", "content": "THUMBS_UP" });
        assert_eq!(
            get_reaction_from_params(&react).unwrap(),
            review_model::ReactionContent::ThumbsUp
        );

        let submit = json!({ "event": "APPROVE", "body": "ship it" });
        assert_eq!(
            get_review_event_from_params(&submit).unwrap(),
            review_model::ReviewEvent::Approve
        );
        assert_eq!(
            get_optional_string_from_params(&submit, "body").unwrap(),
            Some("ship it")
        );
        assert_eq!(
            get_optional_string_from_params(&json!({ "body": null }), "body").unwrap(),
            None
        );

        let suggest = json!({ "cursorLine": 42 });
        assert_eq!(get_u64_from_params(&suggest, "cursorLine").unwrap(), 42);
    }
}
