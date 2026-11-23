use super::*;

#[test]
fn the_fake_workspace_answers_from_memory() {
    let workspace = FakeWorkspace::default();
    workspace.put_base("src/old.rs", "base\n");
    workspace.put_disk("src/a.rs", "disk\n");
    workspace.rename("src/old.rs", "src/a.rs");
    assert_eq!(workspace.merge_base("base000").unwrap(), FAKE_MERGE_BASE);
    assert_eq!(workspace.merge_base_calls(), 1);
    assert_eq!(
        workspace.file_at(FAKE_MERGE_BASE, "src/old.rs").unwrap(),
        Some(b"base\n".to_vec())
    );
    assert!(workspace.file_at("other", "src/old.rs").is_err());
    assert_eq!(
        workspace.file_on_disk("src/a.rs").unwrap(),
        Some(b"disk\n".to_vec())
    );
    assert_eq!(workspace.file_on_disk("src/b.rs").unwrap(), None);
    assert_eq!(
        workspace.renames(FAKE_MERGE_BASE).unwrap(),
        [("src/old.rs".to_owned(), "src/a.rs".to_owned())]
    );
    workspace.fail_with(Some("no network"));
    assert!(workspace.merge_base("base000").is_err());
}

#[test]
fn list_changed_files_since_detects_modified_untracked_and_deleted_files_sorted() {
    let workspace = FakeWorkspace::default();
    workspace.put_at("head1", "src/unchanged.rs", "same\n");
    workspace.put_at("head1", "src/modified.rs", "old\n");
    workspace.put_at("head1", "src/deleted.rs", "gone\n");
    workspace.write_disk("src/unchanged.rs", b"same\n");
    workspace.write_disk("src/untracked.rs", b"new file\n");
    workspace.write_disk("src/modified.rs", b"updated\n");
    workspace.write_disk("src/deleted.rs", b"gone\n");
    workspace.remove_disk("src/deleted.rs");
    assert_eq!(
        workspace.file_on_disk("src/modified.rs").unwrap(),
        Some(b"updated\n".to_vec())
    );
    assert_eq!(workspace.file_on_disk("src/deleted.rs").unwrap(), None);
    assert_eq!(
        workspace.list_changed_files_since("head1").unwrap(),
        vec!["src/deleted.rs", "src/modified.rs", "src/untracked.rs"]
    );
}

#[test]
fn fake_workspace_derives_dirty_status_and_records_pushed_refs() {
    let workspace = FakeWorkspace::default();
    assert_eq!(workspace.head_commit().unwrap(), "abc123");
    assert_eq!(
        workspace.worktree_status(Some("abc123")).unwrap(),
        review_model::WorktreeStatus::default()
    );

    workspace.put_at("abc123", "src/a.rs", "clean\n");
    workspace.put_disk("src/a.rs", "dirty\n");
    let derived = workspace.worktree_status(Some("abc123")).unwrap();
    assert!(derived.is_dirty);
    assert_eq!(derived.modified_paths, vec!["src/a.rs"]);

    let pr = crate::fakes::sample_pr();
    workspace.set_head_commit("def456");
    workspace.set_worktree_status(Some(review_model::WorktreeStatus {
        is_dirty: false,
        ahead: 2,
        behind: 0,
        modified_paths: Vec::new(),
    }));
    assert_eq!(workspace.push_head(&pr).unwrap(), "def456");
    assert_eq!(
        workspace.pushed_refs(),
        vec![("fix/widget".to_owned(), "def456".to_owned())]
    );
    assert_eq!(workspace.pushed_prs(), vec![pr.clone()]);
    assert_eq!(workspace.worktree_status(Some("def456")).unwrap().ahead, 0);

    workspace.fail_push_with(Some("remote rejected"));
    assert!(workspace.push_head(&pr).is_err());
}

#[test]
fn fast_forward_to_defaults_to_noop_or_advancing_head() {
    let workspace = FakeWorkspace::default();
    assert_eq!(
        workspace.fast_forward_to("abc123").unwrap(),
        FastForwardOutcome::AlreadyAtTarget {
            head_sha: "abc123".into(),
        }
    );
    assert_eq!(workspace.head_commit().unwrap(), "abc123");

    assert_eq!(
        workspace.fast_forward_to("def456").unwrap(),
        FastForwardOutcome::FastForwarded {
            previous_sha: "abc123".into(),
            head_sha: "def456".into(),
        }
    );
    assert_eq!(workspace.head_commit().unwrap(), "def456");
}

#[test]
fn fast_forward_to_override_steers_outcomes_and_syncs_head_commit() {
    let workspace = FakeWorkspace::default();
    let conflict = FastForwardOutcome::RestoreConflict {
        previous_sha: "abc123".into(),
        head_sha: "def456".into(),
        conflicted_paths: vec!["src/a.rs".into()],
    };
    workspace.set_fast_forward_outcome(Some(Ok(conflict.clone())));
    assert_eq!(workspace.fast_forward_to("def456").unwrap(), conflict);
    assert_eq!(workspace.head_commit().unwrap(), "def456");

    let diverged = FastForwardOutcome::Diverged {
        head_sha: "def456".into(),
        target_sha: "999999".into(),
    };
    workspace.set_fast_forward_outcome(Some(Ok(diverged.clone())));
    assert_eq!(workspace.fast_forward_to("999999").unwrap(), diverged);
    assert_eq!(workspace.head_commit().unwrap(), "def456");

    workspace.set_fast_forward_outcome(Some(Err("fetch failed".into())));
    assert!(workspace.fast_forward_to("000111").is_err());
    assert_eq!(workspace.head_commit().unwrap(), "def456");

    workspace.set_fast_forward_outcome(None);
    assert_eq!(
        workspace.fast_forward_to("fedcba").unwrap(),
        FastForwardOutcome::FastForwarded {
            previous_sha: "def456".into(),
            head_sha: "fedcba".into(),
        }
    );
    assert_eq!(workspace.head_commit().unwrap(), "fedcba");
}
