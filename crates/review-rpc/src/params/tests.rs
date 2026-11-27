//! Unit tests for JSON-RPC parameter extractors.

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
fn viewed_paths_extractor_accepts_single_path_or_non_empty_paths_array() {
    assert_eq!(
        get_viewed_paths_from_params(&json!({ "path": "src/a.rs", "viewed": true })).unwrap(),
        vec!["src/a.rs"]
    );
    assert_eq!(
        get_viewed_paths_from_params(&json!({ "paths": ["src/a.rs", "src/b.rs"], "viewed": true }))
            .unwrap(),
        vec!["src/a.rs", "src/b.rs"]
    );
    for invalid in [
        json!({ "viewed": true }),
        json!({ "path": "src/a.rs", "paths": ["src/b.rs"], "viewed": true }),
        json!({ "paths": [], "viewed": true }),
        json!({ "paths": [1], "viewed": true }),
        json!({ "path": 1, "viewed": true }),
        Value::Null,
    ] {
        assert_eq!(
            get_viewed_paths_from_params(&invalid).unwrap_err().code,
            RpcError::INVALID_PARAMS,
            "{invalid}"
        );
    }
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
fn reaction_and_review_event_extractors_map_known_names_and_reject_unknown() {
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
fn origin_and_agent_kind_default_when_omitted_and_reject_unknown_values() {
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
fn get_round_kind_from_params_maps_known_kinds_and_rejects_unknown() {
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
fn array_extractors_decode_valid_items_and_reject_wrong_shapes() {
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

#[test]
fn get_renames_from_params_defaults_empty_decodes_pairs_and_rejects_non_array() {
    assert_eq!(get_renames_from_params(&Value::Null).unwrap(), Vec::new());
    assert_eq!(get_renames_from_params(&json!({})).unwrap(), Vec::new());
    let renames = get_renames_from_params(&json!({
        "renames": [{ "oldPath": "src/a.rs", "newPath": "src/b.rs" }]
    }))
    .unwrap();
    assert_eq!(renames.len(), 1);
    assert_eq!(renames[0].old_path, "src/a.rs");
    assert_eq!(renames[0].new_path, "src/b.rs");
    assert_eq!(
        get_renames_from_params(&json!({ "renames": "bad" }))
            .unwrap_err()
            .code,
        RpcError::INVALID_PARAMS
    );
}
