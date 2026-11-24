//! Tests for local worktree file merging, viewed lifecycle, origin-split comments, and rename migration.

use review_model::{Anchor, Event, Origin, PrepassFinding, StreamRow, ViewMode, ViewedState};

use super::super::PathRename;
use super::super::test_support::{Fakes, create_snapshot};
use crate::fakes::changed_file;

#[test]
fn local_worktree_files_merge_into_view_and_diffs() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_base("src/a.rs", "one\n");
    fakes.workspace.put_disk("src/a.rs", "one\ntwo\n");
    fakes.workspace.put_base("src/b.rs", "b\n");
    fakes.workspace.put_disk("src/b.rs", "b\n");
    let mut session = fakes.open_synced();

    fakes
        .workspace
        .put_disk("src/new.rs", "fn fresh() {}\nlet x = 1;\n");
    let view = session.refresh_worktree(&[]).unwrap();

    let local_row = view
        .files
        .iter()
        .find(|row| row.path == "src/new.rs")
        .expect("src/new.rs should appear in view.files");
    assert!(local_row.is_local_only);
    assert_eq!(local_row.additions, 2);
    assert_eq!(local_row.deletions, 0);
    assert_eq!(local_row.viewed, ViewedState::Unviewed);

    let diff = session.file_diff("src/new.rs").unwrap();
    assert_eq!(diff.path, "src/new.rs");
    assert_eq!(diff.added.len(), 2);

    let stream = session.stream(ViewMode::Unified).unwrap();
    assert!(
        stream
            .rows
            .iter()
            .any(|row| matches!(row, StreamRow::File { path, .. } if path == "src/new.rs"))
    );
}

#[test]
fn local_only_viewed_never_calls_forge_and_dismisses_on_disk_edit_and_promotes_on_sync() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_base("src/a.rs", "one\n");
    fakes.workspace.put_disk("src/a.rs", "one\n");
    fakes.workspace.put_base("src/b.rs", "b\n");
    fakes.workspace.put_disk("src/b.rs", "b\n");
    let mut session = fakes.open_synced();

    fakes.workspace.put_disk("src/new.rs", "fn v1() {}\n");
    session.refresh_worktree(&[]).unwrap();

    let viewed_view = session.set_viewed("src/new.rs", true).unwrap();
    let row = viewed_view
        .files
        .iter()
        .find(|row| row.path == "src/new.rs")
        .unwrap();
    assert_eq!(row.viewed, ViewedState::Viewed);
    assert_eq!(fakes.forge.viewed_calls(), Vec::<(String, bool)>::new());
    assert_eq!(
        fakes.store.saved().local.local_viewed.get("src/new.rs"),
        Some(&ViewedState::Viewed)
    );

    fakes.workspace.put_disk("src/new.rs", "fn v2() {}\n");
    let changed = session.poll_worktree_files().unwrap();
    assert!(
        changed
            .as_deref()
            .is_some_and(|paths| paths.contains(&"src/new.rs".to_owned()))
    );
    assert_eq!(
        fakes.store.saved().local.local_viewed.get("src/new.rs"),
        Some(&ViewedState::Dismissed)
    );
    let dismissed_view = session.view();
    assert_eq!(
        dismissed_view
            .files
            .iter()
            .find(|row| row.path == "src/new.rs")
            .unwrap()
            .viewed,
        ViewedState::Dismissed
    );

    session.set_viewed("src/new.rs", true).unwrap();
    assert_eq!(fakes.forge.viewed_calls(), Vec::<(String, bool)>::new());

    let mut pushed_snapshot = create_snapshot();
    pushed_snapshot
        .files
        .push(changed_file("src/new.rs", ViewedState::Unviewed));
    fakes.forge.set_snapshot(pushed_snapshot);
    let synced_view = session.sync().unwrap();

    assert_eq!(
        fakes.forge.viewed_calls(),
        [("src/new.rs".to_owned(), true)]
    );
    assert!(
        !fakes
            .store
            .saved()
            .local
            .local_viewed
            .contains_key("src/new.rs")
    );
    let promoted_row = synced_view
        .files
        .iter()
        .find(|row| row.path == "src/new.rs")
        .unwrap();
    assert!(!promoted_row.is_local_only);
    assert_eq!(promoted_row.viewed, ViewedState::Viewed);
}

#[test]
fn origin_split_comment_validation() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_disk("src/new.rs", "let x = 1;\n");
    let mut session = fakes.open_synced();
    session.refresh_worktree(&[]).unwrap();

    let (local_thread, _) = session
        .comment_with_origin(Anchor::line("src/new.rs", 1), "local note", Origin::Local)
        .unwrap();
    assert_eq!(local_thread.origin, Origin::Local);

    let (prepass_threads, _) = session
        .prepass_write(vec![PrepassFinding {
            anchor: Anchor::line("src/new.rs", 1),
            body: "prepass note".into(),
            author: None,
        }])
        .unwrap();
    assert_eq!(prepass_threads.len(), 1);

    let github_error = session
        .comment_with_origin(Anchor::line("src/new.rs", 1), "gh note", Origin::Github)
        .unwrap_err();
    assert!(
        github_error
            .to_string()
            .contains("Push this file to GitHub before adding GitHub comments"),
        "{github_error}"
    );

    let promote_error = session
        .promote_thread(&local_thread.id, "promoting")
        .unwrap_err();
    assert!(
        promote_error
            .to_string()
            .contains("Push this file to GitHub before adding GitHub comments"),
        "{promote_error}"
    );

    let suggest_error = session
        .suggest_from_edit("src/new.rs", "let x = 2;\n", 1, None)
        .unwrap_err();
    assert!(
        suggest_error
            .to_string()
            .contains("Push this file to GitHub before adding GitHub comments"),
        "{suggest_error}"
    );
}

#[test]
fn refresh_worktree_migrates_local_threads_and_local_viewed_with_prefix_boundary() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_disk("src/api/u.rs", "fn u() {}\n");
    fakes
        .workspace
        .put_disk("src/api-extra/x.rs", "fn x() {}\n");
    let mut session = fakes.open_synced();
    session.refresh_worktree(&[]).unwrap();

    session.set_viewed("src/api/u.rs", true).unwrap();
    session.set_viewed("src/api-extra/x.rs", true).unwrap();
    let (thread_u, _) = session
        .comment_with_origin(Anchor::line("src/api/u.rs", 1), "note u", Origin::Local)
        .unwrap();
    let (thread_x, _) = session
        .comment_with_origin(
            Anchor::line("src/api-extra/x.rs", 1),
            "note x",
            Origin::Local,
        )
        .unwrap();

    fakes.workspace.remove_disk("src/api/u.rs");
    fakes.workspace.put_disk("src/v2/api/u.rs", "fn u() {}\n");

    let view = session
        .refresh_worktree(&[PathRename {
            old_path: "src/api".into(),
            new_path: "src/v2/api".into(),
        }])
        .unwrap();

    let threads = session.threads();
    let migrated = threads.iter().find(|t| t.id == thread_u.id).unwrap();
    let untouched = threads.iter().find(|t| t.id == thread_x.id).unwrap();
    assert_eq!(migrated.anchor.file.as_deref(), Some("src/v2/api/u.rs"));
    assert_eq!(untouched.anchor.file.as_deref(), Some("src/api-extra/x.rs"));

    let saved_local = fakes.store.saved().local;
    assert!(!saved_local.local_viewed.contains_key("src/api/u.rs"));
    assert_eq!(
        saved_local.local_viewed.get("src/v2/api/u.rs"),
        Some(&ViewedState::Viewed)
    );
    assert_eq!(
        saved_local.local_viewed.get("src/api-extra/x.rs"),
        Some(&ViewedState::Viewed)
    );
    assert_eq!(
        view.files
            .iter()
            .find(|row| row.path == "src/v2/api/u.rs")
            .unwrap()
            .viewed,
        ViewedState::Viewed
    );
}

#[test]
fn first_poll_worktree_files_announces_preexisting_local_only_files() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_base("src/a.rs", "one\n");
    fakes.workspace.put_disk("src/a.rs", "one\n");
    fakes
        .workspace
        .put_disk("src/preexisting.rs", "fn pre() {}\n");
    let mut session = fakes.open_synced();
    let events = session.subscribe();

    let changed = session.poll_worktree_files().unwrap();
    assert_eq!(changed, Some(vec!["src/preexisting.rs".to_owned()]));
    let event = events.try_recv().expect("FilesChanged should be published");
    match event {
        Event::FilesChanged { paths, view } => {
            assert_eq!(paths, vec!["src/preexisting.rs".to_owned()]);
            let row = view
                .files
                .iter()
                .find(|file| file.path == "src/preexisting.rs")
                .expect("preexisting local file should be in view");
            assert!(row.is_local_only);
        }
        other => panic!("expected FilesChanged, got {other:?}"),
    }
}

#[test]
fn refresh_worktree_dismisses_in_place_edited_local_viewed_without_dismissing_renamed_file() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_disk("src/edited.rs", "let a = 1;\n");
    fakes.workspace.put_disk("src/old.rs", "let b = 2;\n");
    let mut session = fakes.open_synced();
    session.refresh_worktree(&[]).unwrap();

    session.set_viewed("src/edited.rs", true).unwrap();
    session.set_viewed("src/old.rs", true).unwrap();

    fakes.workspace.put_disk("src/edited.rs", "let a = 99;\n");
    fakes.workspace.remove_disk("src/old.rs");
    fakes.workspace.put_disk("src/moved.rs", "let b = 2;\n");

    let view = session
        .refresh_worktree(&[PathRename {
            old_path: "src/old.rs".into(),
            new_path: "src/moved.rs".into(),
        }])
        .unwrap();

    assert_eq!(
        view.files
            .iter()
            .find(|row| row.path == "src/edited.rs")
            .unwrap()
            .viewed,
        ViewedState::Dismissed
    );
    assert_eq!(
        fakes.store.saved().local.local_viewed.get("src/edited.rs"),
        Some(&ViewedState::Dismissed)
    );
    assert_eq!(
        view.files
            .iter()
            .find(|row| row.path == "src/moved.rs")
            .unwrap()
            .viewed,
        ViewedState::Viewed
    );
    assert_eq!(
        fakes.store.saved().local.local_viewed.get("src/moved.rs"),
        Some(&ViewedState::Viewed)
    );
}
