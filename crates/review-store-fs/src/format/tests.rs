//! The on-disk format's tests: round trips, versions, and defaults.

use std::collections::BTreeMap;

use review_core::fakes::{changed_file, sample_pr};
use review_core::ports::SyncRegistry;
use serde_json::{Value, json};

use super::*;

fn session() -> SessionRecord {
    SessionRecord {
        pid: Some(42),
        worktree: Some("/tmp/widgets-worktrees/pr-7".into()),
        pr: Some(sample_pr()),
        last_synced_at: Some(100),
    }
}

fn as_json(bytes: &[u8]) -> Value {
    serde_json::from_slice(bytes).unwrap()
}

#[test]
fn a_session_round_trips_inside_a_version_2_envelope() {
    let bytes = encode_session(&session()).unwrap();
    assert_eq!(as_json(&bytes)["version"], json!(2));
    assert_eq!(as_json(&bytes)["pr"]["headSha"], json!("abc123"));
    assert_eq!(as_json(&bytes)["pr"]["baseSha"], json!("base000"));
    assert_eq!(decode_session(&bytes).unwrap(), session());
}

#[test]
fn a_version_1_session_loads_without_a_base_commit() {
    let record = decode_session(
        br#"{"version": 1, "pr": {"owner": "octo", "number": 7, "headSha": "abc123"}}"#,
    )
    .unwrap();
    let pr = record.pr.unwrap();
    assert_eq!((pr.head_sha.as_str(), pr.base_sha.as_str()), ("abc123", ""));
}

#[test]
fn the_viewed_file_is_a_version_1_envelope_around_the_files() {
    let files = vec![changed_file("src/a.rs", ViewedState::Viewed)];
    let bytes = encode_files(&files).unwrap();
    assert_eq!(
        as_json(&bytes),
        json!({
            "version": 1,
            "files": [{ "path": "src/a.rs", "additions": 3, "deletions": 1, "viewed": "VIEWED" }],
        })
    );
    assert!(bytes.ends_with(b"}\n"));
    assert_eq!(decode_files(&bytes).unwrap(), files);
}

#[test]
fn the_github_file_is_a_version_1_envelope_around_the_queue() {
    let registry = SyncRegistry {
        queued_viewed: BTreeMap::from([("src/a.rs".to_owned(), false)]),
    };
    let bytes = encode_registry(&registry).unwrap();
    assert_eq!(
        as_json(&bytes),
        json!({ "version": 1, "queuedViewed": { "src/a.rs": false } })
    );
    assert_eq!(decode_registry(&bytes).unwrap(), registry);
}

#[test]
fn a_newer_version_is_refused_naming_both_versions() {
    let error = decode_files(br#"{"version": 2, "files": []}"#).unwrap_err();
    let message = format!("{error:#}");
    assert!(
        message.contains("version 2") && message.contains("version 1"),
        "{message}"
    );
    assert!(!message.contains("delete"), "{message}");
}

#[test]
fn an_unknown_older_version_is_refused() {
    let error = decode_session(br#"{"version": 0}"#).unwrap_err();
    assert!(format!("{error:#}").contains("version 0"), "{error:#}");
    assert!(format!("{error:#}").contains("1 to 2"), "{error:#}");
}

#[test]
fn a_session_newer_than_version_2_is_refused() {
    let error = decode_session(br#"{"version": 3}"#).unwrap_err();
    let message = format!("{error:#}");
    assert!(
        message.contains("version 3") && message.contains("version 2"),
        "{message}"
    );
}

#[test]
fn a_file_without_a_version_is_refused() {
    let error = decode_files(b"[]").unwrap_err();
    assert!(format!("{error:#}").contains("fix or delete"), "{error:#}");
}

#[test]
fn an_old_file_missing_newer_fields_loads_with_defaults() {
    let files = decode_files(br#"{"version": 1, "files": [{"path": "src/a.rs"}]}"#).unwrap();
    assert_eq!(files[0].path, "src/a.rs");
    assert_eq!(
        (files[0].additions, files[0].viewed),
        (0, ViewedState::Unviewed)
    );
    let record =
        decode_session(br#"{"version": 1, "pr": {"owner": "octo", "number": 7}}"#).unwrap();
    let pr = record.pr.unwrap();
    assert_eq!(
        (pr.owner.as_str(), pr.number, pr.node_id.as_str()),
        ("octo", 7, "")
    );
    assert_eq!(record.last_synced_at, None);
}

#[test]
fn stored_version_reads_only_the_version() {
    assert_eq!(
        stored_version(br#"{"version": 3, "files": "anything"}"#).unwrap(),
        3
    );
}

#[test]
fn only_a_newer_version_blocks_an_overwrite() {
    assert!(refuse_newer(2, 1).is_err());
    assert!(refuse_newer(1, 1).is_ok());
    assert!(refuse_newer(0, 1).is_ok());
}
