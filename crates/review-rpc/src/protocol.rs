//! The wire format: newline-delimited JSON-RPC 2.0. See docs/protocol.md.

use serde_json::{Value, json};

/// Bumped whenever a request, response or event changes shape.
pub const PROTOCOL_VERSION: u32 = 10;

/// A request from the client, as [`parse_request`] reads it off the wire. The
/// server routes it by `method` and answers with its `id`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    /// The id the response echoes; never null.
    pub id: Value,
    /// The method to call, such as `sync`.
    pub method: String,
    /// `null` when the request had none.
    pub params: Value,
}

/// A JSON-RPC error, sent back as a response's `error` when a request cannot
/// be parsed, names an unknown method, or the engine cannot do it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RpcError {
    /// The JSON-RPC error code, one of the constants on this type.
    pub code: i64,
    /// What went wrong, for a person to read.
    pub message: String,
}

impl RpcError {
    /// The line was not valid JSON.
    pub const PARSE_ERROR: i64 = -32700;
    /// The JSON was not a request: it had no string method or no id.
    pub const INVALID_REQUEST: i64 = -32600;
    /// No method has that name.
    pub const METHOD_NOT_FOUND: i64 = -32601;
    /// The params do not fit the method.
    pub const INVALID_PARAMS: i64 = -32602;
    /// The request was valid, but the review engine could not do it.
    pub const ENGINE_ERROR: i64 = -32000;
    /// The request failed because `gh` is not authenticated with GitHub.
    pub const AUTH_REQUIRED: i64 = -32001;

    /// An error with `code` and `message`.
    #[must_use]
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

/// Parses one line into a request, or the id and error to answer with.
pub fn parse_request(line: &str) -> Result<Request, (Value, RpcError)> {
    let value: Value = serde_json::from_str(line).map_err(|error| {
        (
            Value::Null,
            RpcError::new(RpcError::PARSE_ERROR, format!("invalid JSON: {error}")),
        )
    })?;
    let id = value.get("id").cloned().unwrap_or(Value::Null);
    let Some(method) = value.get("method").and_then(Value::as_str) else {
        return Err((
            id,
            RpcError::new(
                RpcError::INVALID_REQUEST,
                "a request needs a string \"method\"",
            ),
        ));
    };
    if id.is_null() {
        return Err((
            Value::Null,
            RpcError::new(RpcError::INVALID_REQUEST, "a request needs an \"id\""),
        ));
    }
    Ok(Request {
        id,
        method: method.to_owned(),
        params: value.get("params").cloned().unwrap_or(Value::Null),
    })
}

/// A success response.
#[must_use]
pub fn success(id: &Value, result: Value) -> Value {
    let mut response = json!({ "jsonrpc": "2.0", "id": id });
    // Moved in rather than copied by `json!`, so a large result is not cloned.
    response["result"] = result;
    response
}

/// An error response.
#[must_use]
pub fn failure(id: &Value, error: &RpcError) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": error.code, "message": error.message } })
}

/// A notification (no id, no response expected).
#[must_use]
pub fn notification(method: &str, params: Value) -> Value {
    let mut message = json!({ "jsonrpc": "2.0", "method": method });
    message["params"] = params;
    message
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_request_with_and_without_params() {
        let request =
            parse_request(r#"{"jsonrpc":"2.0","id":3,"method":"sync","params":{"x":1}}"#).unwrap();
        assert_eq!(
            request,
            Request {
                id: json!(3),
                method: "sync".into(),
                params: json!({ "x": 1 })
            }
        );
        let bare = parse_request(r#"{"id":"a","method":"snapshot"}"#).unwrap();
        assert_eq!(bare.params, Value::Null);
    }

    #[test]
    fn invalid_json_is_a_parse_error_with_a_null_id() {
        let (id, error) = parse_request("{oops").unwrap_err();
        assert_eq!(id, Value::Null);
        assert_eq!(error.code, RpcError::PARSE_ERROR);
    }

    #[test]
    fn a_request_needs_a_method_and_an_id() {
        let (id, error) = parse_request(r#"{"id":4}"#).unwrap_err();
        assert_eq!((id, error.code), (json!(4), RpcError::INVALID_REQUEST));
        let (id, error) = parse_request(r#"{"method":"sync"}"#).unwrap_err();
        assert_eq!((id, error.code), (Value::Null, RpcError::INVALID_REQUEST));
    }

    #[test]
    fn builds_responses_and_notifications() {
        assert_eq!(
            success(&json!(1), json!(true)),
            json!({ "jsonrpc": "2.0", "id": 1, "result": true })
        );
        assert_eq!(
            failure(
                &json!(2),
                &RpcError::new(RpcError::METHOD_NOT_FOUND, "nope")
            ),
            json!({ "jsonrpc": "2.0", "id": 2, "error": { "code": -32601, "message": "nope" } })
        );
        assert_eq!(
            notification("event", json!({ "type": "synced" })),
            json!({ "jsonrpc": "2.0", "method": "event", "params": { "type": "synced" } })
        );
    }
}
