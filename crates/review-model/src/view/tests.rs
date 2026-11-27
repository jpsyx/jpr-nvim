use std::collections::BTreeSet;

use super::*;

#[test]
fn sync_states_are_tagged_by_state() {
    assert_eq!(
        serde_json::to_value(SyncState::Never).unwrap(),
        serde_json::json!({ "state": "never" })
    );
    assert_eq!(
        serde_json::to_value(SyncState::Synced { at: 5 }).unwrap(),
        serde_json::json!({ "state": "synced", "at": 5 })
    );
    assert_eq!(
        serde_json::to_value(SyncState::Failed {
            at: 6,
            message: "offline".into()
        })
        .unwrap(),
        serde_json::json!({ "state": "failed", "at": 6, "message": "offline" })
    );
}

fn create_sample_view() -> SessionView {
    SessionView {
        pr: None,
        local_context: None,
        files: vec![FileRow {
            path: "a.rs".into(),
            additions: 1,
            deletions: 2,
            viewed: ViewedState::Viewed,
            threads: 3,
            is_modified: false,
            local_threads: 0,
            is_local_only: false,
        }],
        tree: Vec::new(),
        viewed_count: 1,
        thread_count: 3,
        draft_count: 1,
        conversation_count: 2,
        local_unsent_count: 4,
        queued_count: 2,
        sync: SyncState::Never,
        worktree_status: WorktreeStatus::default(),
        collapsed_dirs: BTreeSet::new(),
    }
}

#[test]
fn session_view_omits_empty_collapsed_dirs_and_serializes_a_sorted_set() {
    let mut view = create_sample_view();
    let empty = serde_json::to_value(&view).unwrap();
    assert!(empty.get("collapsedDirs").is_none());
    let decoded: SessionView = serde_json::from_value(empty).unwrap();
    assert!(decoded.collapsed_dirs.is_empty());

    view.collapsed_dirs = BTreeSet::from(["src".to_owned(), "docs/x".to_owned()]);
    let json = serde_json::to_value(&view).unwrap();
    assert_eq!(json["collapsedDirs"], serde_json::json!(["docs/x", "src"]));
}

#[test]
fn synced_event_uses_camel_case_view_fields() {
    let view = create_sample_view();
    let json = serde_json::to_value(Event::Synced {
        view: Box::new(view),
    })
    .unwrap();
    assert_eq!(json["type"], "synced");
    assert_eq!(json["view"]["viewedCount"], 1);
    assert_eq!(json["view"]["threadCount"], 3);
    assert_eq!(json["view"]["draftCount"], 1);
    assert_eq!(json["view"]["conversationCount"], 2);
    assert_eq!(json["view"]["localUnsentCount"], 4);
    assert_eq!(json["view"]["queuedCount"], 2);
    assert_eq!(json["view"]["files"][0]["viewed"], "VIEWED");
}

#[test]
fn delta_and_failure_events_are_tagged_by_type() {
    let view = create_sample_view();
    let threads_changed = serde_json::to_value(Event::ThreadsChanged {
        view: Box::new(view.clone()),
    })
    .unwrap();
    assert_eq!(threads_changed["type"], "threadsChanged");
    let files_changed = serde_json::to_value(Event::FilesChanged {
        paths: vec!["src/lib.rs".into()],
        view: Box::new(view.clone()),
    })
    .unwrap();
    assert_eq!(files_changed["type"], "filesChanged");
    assert_eq!(files_changed["paths"], serde_json::json!(["src/lib.rs"]));
    let agent_round = serde_json::to_value(Event::AgentRound {
        round: crate::AgentRound {
            round: 1,
            kind: crate::AgentRoundKind::Send,
            thread_ids: vec!["loc-1".into()],
            prompt: "prompt".into(),
            sent_at: 99,
        },
        view: Box::new(view),
    })
    .unwrap();
    assert_eq!(agent_round["type"], "agentRound");
    assert_eq!(agent_round["round"]["round"], 1);
    let failed = serde_json::to_value(Event::SyncFailed {
        message: "offline".into(),
        auth_required: false,
        is_background: false,
    })
    .unwrap();
    assert_eq!(
        failed,
        serde_json::json!({
            "type": "syncFailed",
            "message": "offline",
            "authRequired": false,
            "isBackground": false
        })
    );
}

#[test]
fn sync_failed_event_serializes_auth_and_background_flags_with_legacy_defaults() {
    let auth_failed = serde_json::to_value(Event::SyncFailed {
        message: "bad credentials".into(),
        auth_required: true,
        is_background: true,
    })
    .unwrap();
    assert_eq!(auth_failed["authRequired"], true);
    assert_eq!(auth_failed["isBackground"], true);
    let legacy: Event =
        serde_json::from_value(serde_json::json!({ "type": "syncFailed", "message": "old" }))
            .unwrap();
    assert_eq!(
        legacy,
        Event::SyncFailed {
            message: "old".into(),
            auth_required: false,
            is_background: false,
        }
    );
}

#[test]
fn forge_owner_and_repo_use_camel_case_wire_format() {
    let user = crate::ForgeOwner {
        login: "octo".into(),
        name: Some("Octocat".into()),
        kind: crate::OwnerKind::User,
    };
    let org = crate::ForgeOwner {
        login: "acme".into(),
        name: None,
        kind: crate::OwnerKind::Organization,
    };
    assert_eq!(
        serde_json::to_value(&user).unwrap(),
        serde_json::json!({ "login": "octo", "name": "Octocat", "kind": "user" })
    );
    assert_eq!(
        serde_json::to_value(&org).unwrap(),
        serde_json::json!({ "login": "acme", "kind": "organization" })
    );
    let repo = crate::ForgeRepo {
        name_with_owner: "acme/widgets".into(),
        description: None,
        is_private: true,
        is_archived: false,
        updated_at: "2026-11-24T12:00:00Z".into(),
    };
    assert_eq!(
        serde_json::to_value(&repo).unwrap(),
        serde_json::json!({
            "nameWithOwner": "acme/widgets",
            "isPrivate": true,
            "isArchived": false,
            "updatedAt": "2026-11-24T12:00:00Z"
        })
    );
}

#[test]
fn worktree_status_push_result_and_head_moved_use_camel_case() {
    let mut view = create_sample_view();
    view.files[0].is_modified = true;
    view.files[0].local_threads = 1;
    view.worktree_status = WorktreeStatus {
        is_dirty: true,
        ahead: 2,
        behind: 1,
        modified_paths: vec!["a.rs".into()],
    };
    let push = serde_json::to_value(PushResult {
        is_pushed: true,
        head_sha: "abc1234".into(),
        sync_error: None,
        view: view.clone(),
    })
    .unwrap();
    assert_eq!(push["isPushed"], true);
    assert_eq!(push["headSha"], "abc1234");
    assert!(push.get("syncError").is_none());
    assert_eq!(push["view"]["worktreeStatus"]["isDirty"], true);
    assert_eq!(push["view"]["worktreeStatus"]["ahead"], 2);
    assert_eq!(push["view"]["worktreeStatus"]["behind"], 1);
    assert_eq!(push["view"]["files"][0]["isModified"], true);
    assert_eq!(push["view"]["files"][0]["localThreads"], 1);
    let status_event = serde_json::to_value(Event::WorktreeStatusChanged {
        view: Box::new(view.clone()),
    })
    .unwrap();
    assert_eq!(status_event["type"], "worktreeStatusChanged");
    let moved_event = serde_json::to_value(Event::HeadMoved {
        previous_sha: "old111".into(),
        head_sha: "new222".into(),
        outcome: HeadMoveOutcome::RestoreConflict,
        conflicted_paths: vec!["a.rs".into()],
        message: Some("stash pop conflict".into()),
        view: Box::new(view),
    })
    .unwrap();
    assert_eq!(moved_event["type"], "headMoved");
    assert_eq!(moved_event["previousSha"], "old111");
    assert_eq!(moved_event["headSha"], "new222");
    assert_eq!(moved_event["outcome"], "restoreConflict");
    assert_eq!(moved_event["conflictedPaths"], serde_json::json!(["a.rs"]));
}

#[test]
fn legacy_view_json_without_polish_fields_deserializes_with_defaults() {
    let mut encoded = serde_json::to_value(create_sample_view()).unwrap();
    encoded
        .as_object_mut()
        .unwrap()
        .remove("worktreeStatus")
        .unwrap();
    let row = encoded["files"][0].as_object_mut().unwrap();
    row.remove("isModified").unwrap();
    row.remove("localThreads").unwrap();
    row.remove("isLocalOnly").unwrap();

    let decoded: SessionView = serde_json::from_value(encoded).unwrap();
    assert!(!decoded.files[0].is_modified);
    assert_eq!(decoded.files[0].local_threads, 0);
    assert!(!decoded.files[0].is_local_only);
    assert_eq!(decoded.worktree_status, WorktreeStatus::default());
    assert_eq!(decoded.local_context, None);
}

#[test]
fn local_context_serializes_camel_case_and_is_omitted_when_none() {
    let mut view = create_sample_view();
    let encoded_none = serde_json::to_value(&view).unwrap();
    assert!(encoded_none.get("localContext").is_none());

    view.local_context = Some(LocalReviewContext {
        branch: "feat/local".into(),
        base_ref: "develop".into(),
        base_sha: "abc1234".into(),
        repo: Some("octo/widgets".into()),
    });
    let encoded_some = serde_json::to_value(&view).unwrap();
    assert_eq!(
        encoded_some["localContext"],
        serde_json::json!({
            "branch": "feat/local",
            "baseRef": "develop",
            "baseSha": "abc1234",
            "repo": "octo/widgets",
        })
    );

    view.local_context.as_mut().unwrap().repo = None;
    let encoded_no_repo = serde_json::to_value(&view).unwrap();
    assert!(encoded_no_repo["localContext"].get("repo").is_none());
}
