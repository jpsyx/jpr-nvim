use review_model::{Anchor, Event, LocalAnchorUpdate, Origin};

use super::super::test_support::Fakes;

#[test]
fn poll_worktree_files_emits_files_changed_and_reanchors_local_threads() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
    let mut session = fakes.open_synced();
    let (thread, _) = session
        .comment_with_origin(Anchor::line("src/a.rs", 2), "Why 1?", Origin::Local)
        .unwrap();
    assert_eq!(thread.anchor.snapshot.as_deref(), Some("let x = 1;"));
    let events = session.subscribe();

    assert_eq!(session.poll_worktree_files().unwrap(), None);
    fakes
        .workspace
        .write_disk("src/a.rs", b"// h1\n// h2\nfn f() {}\nlet x = 1;\n");

    let changed = session.poll_worktree_files().unwrap();
    assert_eq!(changed, Some(vec!["src/a.rs".to_owned()]));
    let saved_local = &fakes.store.saved().local.threads[0];
    assert_eq!(saved_local.anchor.start, Some(4));
    assert_eq!(saved_local.anchor.end, Some(4));
    assert!(matches!(
        events.try_recv().unwrap(),
        Event::FilesChanged { paths, .. } if paths == vec!["src/a.rs"]
    ));
    assert!(matches!(
        events.try_recv().unwrap(),
        Event::ThreadsChanged { .. }
    ));
    assert_eq!(session.poll_worktree_files().unwrap(), None);
}

#[test]
fn poll_worktree_files_marks_deleted_file_threads_outdated() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
    let mut session = fakes.open_synced();
    session
        .comment_with_origin(Anchor::line("src/a.rs", 2), "Why 1?", Origin::Local)
        .unwrap();
    assert_eq!(session.poll_worktree_files().unwrap(), None);

    fakes.workspace.remove_disk("src/a.rs");
    let changed = session.poll_worktree_files().unwrap();
    assert_eq!(changed, Some(vec!["src/a.rs".to_owned()]));
    assert!(session.threads().last().unwrap().outdated);
    assert!(fakes.store.saved().local.threads[0].outdated);
}

#[test]
fn poll_worktree_files_continues_when_git_diff_or_single_file_read_fails() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
    fakes.workspace.put_disk("src/b.rs", "let b = 1;\n");
    let mut session = fakes.open_synced();
    session
        .comment_with_origin(Anchor::line("src/a.rs", 2), "Why 1?", Origin::Local)
        .unwrap();
    assert_eq!(session.poll_worktree_files().unwrap(), None);

    fakes
        .workspace
        .fail_list_changed_with(Some("git status error"));
    fakes
        .workspace
        .fail_disk_read_with("src/b.rs", Some("permission denied"));
    fakes
        .workspace
        .write_disk("src/a.rs", b"// shifted\nfn f() {}\nlet x = 1;\n");

    let changed = session.poll_worktree_files().unwrap();
    assert_eq!(changed, Some(vec!["src/a.rs".to_owned()]));
    let local = session.threads().last().unwrap();
    assert_eq!(local.anchor.start, Some(3));
    assert!(!local.outdated);
}

#[test]
fn update_local_anchors_updates_line_bounds_and_refreshes_snapshot() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
    let mut session = fakes.open_synced();
    let (thread, _) = session
        .comment_with_origin(Anchor::line("src/a.rs", 2), "Why 1?", Origin::Local)
        .unwrap();
    let events = session.subscribe();

    fakes
        .workspace
        .put_disk("src/a.rs", "// h1\nfn f() {}\nlet x = 2;\n");
    session
        .update_local_anchors(
            "src/a.rs",
            &[LocalAnchorUpdate {
                thread_id: thread.id.clone(),
                start: 3,
                end: 3,
            }],
        )
        .unwrap();

    let updated = session
        .threads()
        .iter()
        .find(|item| item.id == thread.id)
        .unwrap();
    assert_eq!(updated.anchor.start, Some(3));
    assert_eq!(updated.anchor.end, Some(3));
    assert!(!updated.outdated);
    assert_eq!(updated.anchor.snapshot.as_deref(), Some("let x = 2;"));
    assert!(matches!(
        events.try_recv().unwrap(),
        Event::ThreadsChanged { .. }
    ));
}

#[test]
fn update_local_anchors_clears_snapshot_for_binary_and_marks_missing_outdated() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
    let mut session = fakes.open_synced();
    let (thread, _) = session
        .comment_with_origin(Anchor::line("src/a.rs", 2), "Why?", Origin::Local)
        .unwrap();
    let update = LocalAnchorUpdate {
        thread_id: thread.id,
        start: 1,
        end: 1,
    };

    fakes.workspace.write_disk("src/a.rs", b"\x00\x01\x02");
    session
        .update_local_anchors("src/a.rs", std::slice::from_ref(&update))
        .unwrap();
    let binary_updated = session.threads().last().unwrap();
    assert_eq!(binary_updated.anchor.snapshot, None);
    assert!(!binary_updated.outdated);

    fakes.workspace.remove_disk("src/a.rs");
    session.update_local_anchors("src/a.rs", &[update]).unwrap();
    let missing_updated = session.threads().last().unwrap();
    assert_eq!(missing_updated.anchor.snapshot, None);
    assert!(missing_updated.outdated);
}

#[test]
fn poll_worktree_files_emits_worktree_status_changed_when_git_status_changes_without_file_edits() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_disk("src/a.rs", "fn f() {}\n");
    let mut session = fakes.open_synced();
    let events = session.subscribe();

    assert_eq!(session.poll_worktree_files().unwrap(), None);
    assert!(events.try_recv().is_err());

    fakes
        .workspace
        .set_worktree_status(Some(review_model::WorktreeStatus {
            is_dirty: false,
            ahead: 1,
            behind: 0,
            modified_paths: Vec::new(),
        }));
    assert_eq!(session.poll_worktree_files().unwrap(), None);
    match events.try_recv().unwrap() {
        Event::WorktreeStatusChanged { view } => {
            assert!(!view.worktree_status.is_dirty);
            assert_eq!(view.worktree_status.ahead, 1);
        }
        other => panic!("expected WorktreeStatusChanged, got {other:?}"),
    }

    assert_eq!(session.poll_worktree_files().unwrap(), None);
    assert!(events.try_recv().is_err());
}

#[test]
fn poll_worktree_files_does_not_repeat_status_after_files_changed_until_commit() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_at("abc123", "src/a.rs", "clean\n");
    fakes.workspace.put_disk("src/a.rs", "clean\n");
    let mut session = fakes.open_synced();
    assert_eq!(session.poll_worktree_files().unwrap(), None);
    let events = session.subscribe();

    fakes.workspace.put_disk("src/a.rs", "edited\n");
    assert_eq!(
        session.poll_worktree_files().unwrap(),
        Some(vec!["src/a.rs".to_owned()])
    );
    match events.try_recv().unwrap() {
        Event::FilesChanged { view, .. } => assert!(view.worktree_status.is_dirty),
        other => panic!("expected FilesChanged, got {other:?}"),
    }
    assert_eq!(session.poll_worktree_files().unwrap(), None);
    assert!(events.try_recv().is_err());

    fakes.workspace.set_head_commit("commit2");
    fakes.workspace.put_at("commit2", "src/a.rs", "edited\n");
    assert_eq!(session.poll_worktree_files().unwrap(), None);
    match events.try_recv().unwrap() {
        Event::WorktreeStatusChanged { view } => assert!(!view.worktree_status.is_dirty),
        other => panic!("expected WorktreeStatusChanged, got {other:?}"),
    }
}

#[test]
fn non_sync_publish_updates_last_worktree_status_avoiding_duplicate_status_event() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_disk("src/a.rs", "fn f() {}\n");
    let mut session = fakes.open_synced();
    assert_eq!(session.poll_worktree_files().unwrap(), None);

    fakes
        .workspace
        .set_worktree_status(Some(review_model::WorktreeStatus {
            is_dirty: false,
            ahead: 1,
            behind: 0,
            modified_paths: Vec::new(),
        }));
    session.set_viewed("src/a.rs", false).unwrap();
    let events = session.subscribe();

    assert_eq!(session.poll_worktree_files().unwrap(), None);
    assert!(events.try_recv().is_err());
}

#[test]
fn poll_worktree_files_rolls_back_threads_and_digests_when_save_fails() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
    let mut session = fakes.open_synced();
    session
        .comment_with_origin(Anchor::line("src/a.rs", 2), "Why 1?", Origin::Local)
        .unwrap();
    assert_eq!(session.poll_worktree_files().unwrap(), None);

    fakes
        .workspace
        .write_disk("src/a.rs", b"// h1\n// h2\nfn f() {}\nlet x = 1;\n");
    fakes.store.fail_saves_with(Some("disk full"));
    assert!(session.poll_worktree_files().is_err());
    assert_eq!(session.threads().last().unwrap().anchor.start, Some(2));

    fakes.store.fail_saves_with(None);
    assert_eq!(
        session.poll_worktree_files().unwrap(),
        Some(vec!["src/a.rs".to_owned()])
    );
    assert_eq!(session.threads().last().unwrap().anchor.start, Some(4));
}

#[test]
fn poll_worktree_files_before_initial_sync_does_not_emit_spurious_files_changed_after_sync() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_disk("src/a.rs", "fn a() {}\n");
    fakes.workspace.put_disk("src/b.rs", "fn b() {}\n");
    let mut session = fakes.open();

    assert_eq!(session.poll_worktree_files().unwrap(), None);
    session.sync().unwrap();

    let events = session.subscribe();
    assert_eq!(session.poll_worktree_files().unwrap(), None);
    assert!(events.try_recv().is_err());

    fakes.workspace.put_base("src/c.rs", "fn c() {}\n");
    fakes.workspace.put_disk("src/c.rs", "fn c() {}\n");
    let mut expanded = super::super::test_support::create_snapshot();
    expanded.files.push(review_model::ChangedFile {
        path: "src/c.rs".into(),
        additions: 1,
        deletions: 0,
        viewed: review_model::ViewedState::Unviewed,
    });
    fakes.forge.set_snapshot(expanded);
    session.sync().unwrap();
    let _ = events.try_recv().unwrap();

    assert_eq!(session.poll_worktree_files().unwrap(), None);
    assert!(events.try_recv().is_err());
}
