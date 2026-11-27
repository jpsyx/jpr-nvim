//! Tests for local worktree file merging, viewed lifecycle, origin-split comments, and rename migration.

use std::collections::BTreeSet;

use review_model::{
    Anchor, Event, FileRow, Origin, PrepassFinding, SessionView, StreamRow, ViewMode, ViewedState,
};

use super::super::PathRename;
use super::super::test_support::{Fakes, create_snapshot};
use crate::fakes::changed_file;

fn find_file_row<'a>(view: &'a SessionView, path: &str) -> &'a FileRow {
    view.files
        .iter()
        .find(|row| row.path == path)
        .unwrap_or_else(|| panic!("{path} should appear in view.files"))
}

fn assert_local_only_github_error<T: std::fmt::Debug>(result: anyhow::Result<T>) {
    let error = result.unwrap_err();
    assert!(
        error
            .to_string()
            .contains("Push this file to GitHub before adding GitHub comments"),
        "{error}"
    );
}

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

    let local_row = find_file_row(&view, "src/new.rs");
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
fn local_only_viewed_skips_forge_and_dismisses_on_disk_edit() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_base("src/a.rs", "one\n");
    fakes.workspace.put_disk("src/a.rs", "one\n");
    fakes.workspace.put_disk("src/new.rs", "fn v1() {}\n");
    let mut session = fakes.open_synced();
    session.refresh_worktree(&[]).unwrap();

    let viewed_view = session.set_viewed("src/new.rs", true).unwrap();
    assert_eq!(
        find_file_row(&viewed_view, "src/new.rs").viewed,
        ViewedState::Viewed
    );
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
    assert_eq!(
        find_file_row(&session.view(), "src/new.rs").viewed,
        ViewedState::Dismissed
    );
}

#[test]
fn local_only_viewed_promotes_to_forge_when_file_appears_in_pr() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_disk("src/new.rs", "fn v1() {}\n");
    let mut session = fakes.open_synced();
    session.refresh_worktree(&[]).unwrap();

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
    let promoted_row = find_file_row(&synced_view, "src/new.rs");
    assert!(!promoted_row.is_local_only);
    assert_eq!(promoted_row.viewed, ViewedState::Viewed);
}

#[test]
fn origin_split_allows_local_and_rejects_github_comments_on_local_only_files() {
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

    assert_local_only_github_error(session.comment_with_origin(
        Anchor::line("src/new.rs", 1),
        "gh note",
        Origin::Github,
    ));
    assert_local_only_github_error(session.promote_thread(&local_thread.id, "promoting"));
    assert_local_only_github_error(session.suggest_from_edit(
        "src/new.rs",
        "let x = 2;\n",
        1,
        None,
    ));
}

fn add_local_note(session: &mut super::super::ReviewSession, path: &str, body: &str) -> String {
    session
        .comment_with_origin(Anchor::line(path, 1), body, Origin::Local)
        .unwrap()
        .0
        .id
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
    let api_thread_id = add_local_note(&mut session, "src/api/u.rs", "note u");
    let extra_thread_id = add_local_note(&mut session, "src/api-extra/x.rs", "note x");

    fakes.workspace.remove_disk("src/api/u.rs");
    fakes.workspace.put_disk("src/v2/api/u.rs", "fn u() {}\n");
    let rename = PathRename {
        old_path: "src/api".into(),
        new_path: "src/v2/api".into(),
    };
    let view = session.refresh_worktree(&[rename]).unwrap();

    let threads = session.threads();
    let migrated = threads.iter().find(|t| t.id == api_thread_id).unwrap();
    let untouched = threads.iter().find(|t| t.id == extra_thread_id).unwrap();
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
        find_file_row(&view, "src/v2/api/u.rs").viewed,
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
            assert!(find_file_row(&view, "src/preexisting.rs").is_local_only);
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

    let rename = PathRename {
        old_path: "src/old.rs".into(),
        new_path: "src/moved.rs".into(),
    };
    let view = session.refresh_worktree(&[rename]).unwrap();

    assert_eq!(
        find_file_row(&view, "src/edited.rs").viewed,
        ViewedState::Dismissed
    );
    assert_eq!(
        fakes.store.saved().local.local_viewed.get("src/edited.rs"),
        Some(&ViewedState::Dismissed)
    );
    assert_eq!(
        find_file_row(&view, "src/moved.rs").viewed,
        ViewedState::Viewed
    );
    assert_eq!(
        fakes.store.saved().local.local_viewed.get("src/moved.rs"),
        Some(&ViewedState::Viewed)
    );
}

#[test]
fn refresh_worktree_rewrites_collapsed_directory_prefixes() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/api/nested/keep.rs", "fn keep() {}\n");
    fakes
        .workspace
        .put_disk("src/api-extra/x.rs", "fn x() {}\n");
    let mut session = fakes.open_synced();
    session.set_collapsed("src/api", true).unwrap();
    session.set_collapsed("src/api/nested", true).unwrap();
    session.set_collapsed("src/api-extra", true).unwrap();
    session
        .refresh_worktree(&[PathRename {
            old_path: "src/api".into(),
            new_path: "src/v2/api".into(),
        }])
        .unwrap();
    assert_eq!(
        fakes.store.saved().local.collapsed_dirs,
        BTreeSet::from([
            "src/api-extra".to_owned(),
            "src/v2/api".to_owned(),
            "src/v2/api/nested".to_owned(),
        ])
    );
}
