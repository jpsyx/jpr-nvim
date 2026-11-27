use review_model::{Anchor, Message, MessageSync};

use super::*;

fn file(path: &str, additions: u64, deletions: u64, viewed: ViewedState) -> ChangedFile {
    ChangedFile {
        path: path.to_owned(),
        additions,
        deletions,
        viewed,
    }
}

fn message(id: &str, body: &str, viewer_did_author: bool) -> Message {
    Message {
        id: id.to_owned(),
        author: if viewer_did_author { "me" } else { "alice" }.to_owned(),
        body: body.to_owned(),
        created: "2026-11-27T00:00:00Z".to_owned(),
        updated: "2026-11-27T00:00:00Z".to_owned(),
        sync: Some(MessageSync::Published),
        viewer_did_author,
        database_id: None,
        sync_error: None,
        recoverable_body: None,
        reactions: Vec::new(),
    }
}

fn github_thread(id: &str, state: ThreadState, messages: Vec<Message>) -> Thread {
    Thread {
        id: id.to_owned(),
        origin: Origin::Github,
        anchor: Anchor::line("src/a.rs", 1),
        state,
        outdated: false,
        messages,
        agent: None,
        promoted_to: None,
    }
}

fn local_thread(id: &str, messages: Vec<Message>) -> Thread {
    Thread {
        id: id.to_owned(),
        origin: Origin::Local,
        anchor: Anchor::line("src/a.rs", 1),
        state: ThreadState::Open,
        outdated: false,
        messages,
        agent: None,
        promoted_to: None,
    }
}

#[test]
fn returns_none_on_initial_sync() {
    let before = SyncComparisonSnapshot {
        had_pr: false,
        head_sha: None,
        files: Vec::new(),
        threads: Vec::new(),
    };
    let after = SyncComparisonSnapshot {
        had_pr: true,
        head_sha: Some("abc123".into()),
        files: vec![file("src/a.rs", 5, 1, ViewedState::Unviewed)],
        threads: vec![github_thread(
            "PRRT_1",
            ThreadState::Open,
            vec![message("PRRC_1", "hello", false)],
        )],
    };
    assert_eq!(
        compute_sync_delta(&before, &after, &BTreeMap::new(), false),
        None
    );
}

#[test]
fn returns_none_when_nothing_changed() {
    let snapshot = SyncComparisonSnapshot {
        had_pr: true,
        head_sha: Some("abc123".into()),
        files: vec![file("src/a.rs", 5, 1, ViewedState::Viewed)],
        threads: vec![github_thread(
            "PRRT_1",
            ThreadState::Open,
            vec![message("PRRC_1", "hello", false)],
        )],
    };
    assert_eq!(
        compute_sync_delta(&snapshot, &snapshot, &BTreeMap::new(), false),
        None
    );
}

#[test]
fn counts_added_removed_edited_and_dismissed_files_but_not_own_viewed() {
    let before = SyncComparisonSnapshot {
        had_pr: true,
        head_sha: Some("sha1".into()),
        files: vec![
            file("src/removed.rs", 1, 0, ViewedState::Unviewed),
            file("src/edited.rs", 2, 1, ViewedState::Unviewed),
            file("src/dismissed.rs", 4, 0, ViewedState::Viewed),
            file("src/marked_viewed.rs", 1, 1, ViewedState::Unviewed),
        ],
        threads: Vec::new(),
    };
    let after = SyncComparisonSnapshot {
        had_pr: true,
        head_sha: Some("sha2".into()),
        files: vec![
            file("src/added.rs", 3, 0, ViewedState::Unviewed),
            file("src/edited.rs", 5, 1, ViewedState::Unviewed),
            file("src/dismissed.rs", 4, 0, ViewedState::Dismissed),
            file("src/marked_viewed.rs", 1, 1, ViewedState::Viewed),
        ],
        threads: Vec::new(),
    };
    let delta = compute_sync_delta(&before, &after, &BTreeMap::new(), false)
        .expect("delta should be present");
    assert_eq!(delta.files_changed, 4);
    assert!(delta.head_moved);
}

#[test]
fn ignores_file_and_head_changes_for_own_push_while_keeping_external_comments() {
    let before = SyncComparisonSnapshot {
        had_pr: true,
        head_sha: Some("sha1".into()),
        files: vec![file("src/a.rs", 1, 0, ViewedState::Viewed)],
        threads: Vec::new(),
    };
    let after = SyncComparisonSnapshot {
        had_pr: true,
        head_sha: Some("sha2".into()),
        files: vec![
            file("src/a.rs", 10, 0, ViewedState::Dismissed),
            file("src/b.rs", 2, 0, ViewedState::Unviewed),
        ],
        threads: vec![github_thread(
            "PRRT_1",
            ThreadState::Open,
            vec![message("PRRC_1", "nice push", false)],
        )],
    };
    let delta = compute_sync_delta(&before, &after, &BTreeMap::new(), true)
        .expect("external comment should still be reported");
    assert_eq!(delta.files_changed, 0);
    assert!(!delta.head_moved);
    assert_eq!(delta.new_comments, 1);
}

#[test]
fn filters_out_own_optimistic_and_mapped_comments_via_id_map() {
    let before = SyncComparisonSnapshot {
        had_pr: true,
        head_sha: Some("sha1".into()),
        files: Vec::new(),
        threads: vec![github_thread(
            "tmp-t-1",
            ThreadState::Open,
            vec![message("tmp-m-1", "my queued comment", true)],
        )],
    };
    let after = SyncComparisonSnapshot {
        had_pr: true,
        head_sha: Some("sha1".into()),
        files: Vec::new(),
        threads: vec![github_thread(
            "PRRT_99",
            ThreadState::Open,
            vec![
                message("PRRC_99", "my queued comment", true),
                message("PRRC_100", "external reply", false),
            ],
        )],
    };
    let id_map = BTreeMap::from([
        ("tmp-t-1".to_owned(), "PRRT_99".to_owned()),
        ("tmp-m-1".to_owned(), "PRRC_99".to_owned()),
    ]);
    let delta = compute_sync_delta(&before, &after, &id_map, false).expect("external reply exists");
    assert_eq!(delta.new_comments, 1);
    assert_eq!(delta.updated_comments, 0);
}

#[test]
fn counts_updated_comments_and_thread_state_transitions_for_github_threads_only() {
    let before = SyncComparisonSnapshot {
        had_pr: true,
        head_sha: Some("sha1".into()),
        files: Vec::new(),
        threads: vec![
            github_thread(
                "PRRT_1",
                ThreadState::Open,
                vec![message("PRRC_1", "old body", false)],
            ),
            github_thread(
                "PRRT_2",
                ThreadState::Resolved,
                vec![message("PRRC_2", "resolved body", false)],
            ),
            local_thread("loc-1", vec![message("loc-m-1", "local", true)]),
        ],
    };
    let after = SyncComparisonSnapshot {
        had_pr: true,
        head_sha: Some("sha1".into()),
        files: Vec::new(),
        threads: vec![
            github_thread(
                "PRRT_1",
                ThreadState::Resolved,
                vec![message("PRRC_1", "edited body", false)],
            ),
            github_thread(
                "PRRT_2",
                ThreadState::Open,
                vec![message("PRRC_2", "resolved body", false)],
            ),
            local_thread(
                "loc-1",
                vec![
                    message("loc-m-1", "local", true),
                    message("loc-m-2", "agent reply", false),
                ],
            ),
        ],
    };
    let delta = compute_sync_delta(&before, &after, &BTreeMap::new(), false)
        .expect("delta should be present");
    assert_eq!(delta.new_comments, 0);
    assert_eq!(delta.updated_comments, 1);
    assert_eq!(delta.resolved_threads, 1);
    assert_eq!(delta.reopened_threads, 1);
}
