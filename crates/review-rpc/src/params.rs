//! Reading a request's params. A param that is missing or of the wrong type
//! is an invalid-params error that says what was expected.

use review_model::ViewMode;
use serde_json::Value;

use crate::protocol::RpcError;

/// The string param `name`.
pub fn get_string_from_params<'a>(params: &'a Value, name: &str) -> Result<&'a str, RpcError> {
    params
        .get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| create_invalid_params_error(&format!("expected a string \"{name}\"")))
}

/// The boolean param `name`.
pub fn get_bool_from_params(params: &Value, name: &str) -> Result<bool, RpcError> {
    params
        .get(name)
        .and_then(Value::as_bool)
        .ok_or_else(|| create_invalid_params_error(&format!("expected a boolean \"{name}\"")))
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
}
