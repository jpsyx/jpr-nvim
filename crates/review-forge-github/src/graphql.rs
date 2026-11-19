//! The GitHub GraphQL documents the forge sends, and pure parsing of the
//! answers. Queries address the pull request by its node id.

use anyhow::{Context, Result, anyhow};
use serde_json::Value;

/// The `data` of a `gh api graphql` answer, or GitHub's error message.
pub fn parse_data_from_answer(stdout: &str) -> Result<Value> {
    let value: Value = serde_json::from_str(stdout).context("reading GitHub's GraphQL answer")?;
    if let Some(message) = value.pointer("/errors/0/message").and_then(Value::as_str) {
        return Err(anyhow!("{message}"));
    }
    value
        .get("data")
        .cloned()
        .ok_or_else(|| anyhow!("GitHub's answer had no data"))
}

/// GitHub's error message, when `stdout` is a GraphQL error answer.
#[must_use]
pub fn error_message(stdout: &str) -> Option<String> {
    let value: Value = serde_json::from_str(stdout).ok()?;
    value
        .pointer("/errors/0/message")
        .and_then(Value::as_str)
        .map(str::to_owned)
}
