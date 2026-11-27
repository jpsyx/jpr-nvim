//! Unit tests for mid-session local-to-PR upgrade and authoritative viewed promotion.

use std::collections::{BTreeMap, BTreeSet};

use review_model::{
    AgentKind, AgentThreadState, Anchor, Event, LocalReviewContext, Message, Origin, SyncState,
    Thread, ThreadState, ViewedState,
};

use super::ReviewSession;
use super::test_support::Fakes;
use crate::fakes::{changed_file, create_fake_ports, sample_pr};
use crate::ports::{ForgeSnapshot, StoreSnapshot};

fn sample_local_context() -> LocalReviewContext {
    LocalReviewContext {
        branch: "fix/widget".into(),
        base_ref: "main".into(),
        base_sha: "base000".into(),
        repo: Some("octo/widgets".into()),
    }
}

fn open_local(fakes: &Fakes) -> ReviewSession {
    let ports = create_fake_ports(&fakes.forge, &fakes.store, &fakes.workspace, &fakes.clock);
    ReviewSession::open_local(sample_local_context(), ports).expect("local session opens")
}

fn unviewed_pr_snapshot() -> ForgeSnapshot {
    ForgeSnapshot {
        head_sha: "abc123".into(),
        files: vec![
            changed_file("src/a.rs", ViewedState::Unviewed),
            changed_file("src/b.rs", ViewedState::Unviewed),
        ],
        ..ForgeSnapshot::default()
    }
}

#[test]
fn sync_in_local_mode_returns_notice_without_sync_failed_when_no_pr_exists() {
    let fakes = Fakes::new(100);
    fakes.forge.set_current_branch_pr(None);
    fakes.workspace.put_base("src/a.rs", "old\n");
    fakes.workspace.put_disk("src/a.rs", "new\n");

    let mut session = open_local(&fakes);
    let events = session.subscribe();
    let error = session.sync().unwrap_err().to_string();
    assert!(error.contains("no open pull request found for branch"));
    assert!(!session.is_linked());
    assert_eq!(session.view().sync, SyncState::Never);
    assert!(events.try_recv().is_err());
}

#[test]
fn sync_in_local_mode_rolls_back_cleanly_on_fetch_or_retarget_failure() {
    let fakes = Fakes::new(100);
    fakes.forge.set_snapshot(unviewed_pr_snapshot());
    fakes.workspace.put_base("src/a.rs", "old\n");
    fakes.workspace.put_disk("src/a.rs", "new\n");

    let mut session = open_local(&fakes);
    session.set_viewed("src/a.rs", true).expect("local viewed");
    session
        .comment_with_origin(Anchor::line("src/a.rs", 1), "note", Origin::Local)
        .expect("local comment");

    // 1. Forge fetch failure must NOT call retarget_to_pr.
    fakes.forge.fail_reads_with(Some("timeout"));
    assert!(session.sync().is_err());
    assert!(!session.is_linked());
    assert_eq!(
        fakes.store.retargeted_prs(),
        Vec::<(String, String, u64)>::new()
    );
    assert_eq!(session.threads().len(), 1);

    // 2. Store retarget failure must leave session unlinked and not finalize.
    fakes.forge.fail_reads_with(None);
    fakes
        .store
        .fail_retarget_with(Some("already serving PR #7"));
    let retarget_error = session.sync().unwrap_err().to_string();
    assert!(retarget_error.contains("already serving PR #7"));
    assert!(!session.is_linked());
    assert_eq!(fakes.store.finalized_retarget_count(), 0);
    assert_eq!(session.threads().len(), 1);
    assert_eq!(
        fakes
            .store
            .saved()
            .local
            .local_viewed
            .get("src/a.rs")
            .copied(),
        Some(ViewedState::Viewed)
    );
}

#[test]
fn sync_in_local_mode_links_promotes_authoritative_viewed_and_keeps_unpushed_files_local() {
    let fakes = Fakes::new(200);
    fakes.forge.set_snapshot(unviewed_pr_snapshot());
    fakes.workspace.put_base("src/a.rs", "a0\n");
    fakes.workspace.put_disk("src/a.rs", "a1\n");
    fakes.workspace.put_base("src/b.rs", "b0\n");
    fakes.workspace.put_disk("src/b.rs", "b1\n");
    fakes.workspace.put_disk("src/c.rs", "unpushed\n");

    let mut session = open_local(&fakes);
    let events = session.subscribe();
    session.set_viewed("src/a.rs", true).expect("view a");
    session.set_viewed("src/c.rs", true).expect("view c");
    session
        .comment_with_origin(Anchor::line("src/a.rs", 1), "keep me", Origin::Local)
        .expect("local comment");
    let launch = session
        .prepare_agent_launch(AgentKind::Claude)
        .expect("agent launch");
    while events.try_recv().is_ok() {}

    let view = session.sync().expect("upgrade succeeds");
    assert!(session.is_linked());
    assert_eq!(view.pr.as_ref().map(|pr| pr.number), Some(7));
    assert!(view.local_context.is_none());
    assert_eq!(fakes.forge.pinned_repo().as_deref(), Some("octo/widgets"));
    assert_eq!(fakes.forge.viewed_calls(), vec![("src/a.rs".into(), true)]);
    assert_eq!(fakes.store.finalized_retarget_count(), 1);

    let row_a = view.files.iter().find(|f| f.path == "src/a.rs").unwrap();
    let row_b = view.files.iter().find(|f| f.path == "src/b.rs").unwrap();
    let row_c = view.files.iter().find(|f| f.path == "src/c.rs").unwrap();
    assert_eq!(row_a.viewed, ViewedState::Viewed);
    assert!(!row_a.is_local_only);
    assert_eq!(row_b.viewed, ViewedState::Unviewed);
    assert_eq!(row_c.viewed, ViewedState::Viewed);
    assert!(row_c.is_local_only);
    assert_eq!(
        fakes.store.saved().session.agent_session_id.as_deref(),
        Some(launch.session_id.as_str())
    );

    // No Event::HeadMoved emitted on first link.
    while let Ok(event) = events.try_recv() {
        assert!(!matches!(event, Event::HeadMoved { .. }));
    }
}

#[test]
fn sync_in_local_mode_queues_promoted_viewed_when_github_write_fails_transiently() {
    let fakes = Fakes::new(200);
    fakes.forge.set_snapshot(unviewed_pr_snapshot());
    fakes.workspace.put_base("src/a.rs", "a0\n");
    fakes.workspace.put_disk("src/a.rs", "a1\n");

    let mut session = open_local(&fakes);
    session.set_viewed("src/a.rs", true).expect("view a");
    fakes.forge.fail_writes_with(Some("offline"));

    let view = session.sync().expect("link succeeds with queued viewed");
    assert!(session.is_linked());
    assert_eq!(view.queued_count, 1);
    let row_a = view.files.iter().find(|f| f.path == "src/a.rs").unwrap();
    assert_eq!(row_a.viewed, ViewedState::Viewed);
    assert_eq!(
        fakes
            .store
            .saved()
            .registry
            .queued_viewed
            .get("src/a.rs")
            .copied(),
        Some(true)
    );
}

#[test]
fn sync_in_local_mode_merges_preexisting_pr_snapshot_renumbering_colliding_local_ids() {
    let fakes = Fakes::new(300);
    fakes.forge.set_snapshot(unviewed_pr_snapshot());
    fakes.workspace.put_base("src/a.rs", "a0\n");
    fakes.workspace.put_disk("src/a.rs", "a1\n");

    let mut prior = StoreSnapshot::default();
    prior.session.pr = Some(sample_pr());
    prior.session.socket = Some("/old/pr-7/s.sock".into());
    prior.registry.queued_viewed = BTreeMap::from([("src/a.rs".into(), false)]);
    prior.local.next_local_id = 1;
    prior.local.threads.push(Thread {
        id: "loc-1".into(),
        origin: Origin::Local,
        anchor: Anchor::line("src/b.rs", 1),
        state: ThreadState::Open,
        outdated: false,
        messages: vec![Message::create_with_sync(
            "loc-m-1",
            "you",
            "prior note",
            "2026-11-24T00:00:00Z",
            None,
        )],
        agent: Some(AgentThreadState::Unsent),
        promoted_to: None,
    });
    fakes.store.set_retarget_snapshot(Some(prior));

    let mut session = open_local(&fakes);
    session.set_viewed("src/a.rs", true).expect("view a");
    let (live_thread, _) = session
        .comment_with_origin(Anchor::line("src/a.rs", 1), "live note", Origin::Local)
        .expect("live local comment");
    let launch = session
        .prepare_agent_launch(AgentKind::Codex)
        .expect("live agent");

    let view = session.sync().expect("merge and link succeeds");
    assert!(session.is_linked());
    let local_threads: Vec<&Thread> = session
        .threads()
        .iter()
        .filter(|thread| thread.origin == Origin::Local)
        .collect();
    assert_eq!(local_threads.len(), 2);
    assert_ne!(local_threads[0].id, local_threads[1].id);
    assert_eq!(local_threads[0].id, live_thread.id);
    assert!(fakes.store.saved().local.next_local_id >= 2);

    let row_a = view.files.iter().find(|f| f.path == "src/a.rs").unwrap();
    assert_eq!(row_a.viewed, ViewedState::Viewed);
    assert_eq!(
        fakes.store.saved().session.agent_session_id.as_deref(),
        Some(launch.session_id.as_str())
    );
    assert!(fakes.store.saved().session.socket.is_none());
}

#[test]
fn linking_unions_collapsed_directories_that_still_contain_viewed_files() {
    let fakes = Fakes::new(200);
    let mut snapshot = unviewed_pr_snapshot();
    snapshot.files = vec![
        changed_file("src/kept.rs", ViewedState::Viewed),
        changed_file("lib/kept.rs", ViewedState::Viewed),
    ];
    fakes.forge.set_snapshot(snapshot);
    fakes.workspace.put_base("src/kept.rs", "old\n");
    fakes.workspace.put_disk("src/kept.rs", "new\n");
    fakes.workspace.put_base("lib/kept.rs", "old\n");
    fakes.workspace.put_disk("lib/kept.rs", "new\n");
    let mut prior = StoreSnapshot::default();
    prior.local.collapsed_dirs = BTreeSet::from(["lib".to_owned()]);
    fakes.store.set_retarget_snapshot(Some(prior));

    let mut session = open_local(&fakes);
    session.set_collapsed("src", true).unwrap();
    let view = session.sync().unwrap();
    assert_eq!(
        view.collapsed_dirs,
        BTreeSet::from(["lib".to_owned(), "src".to_owned()])
    );
}

#[test]
fn linking_keeps_collapsed_dirs_with_unviewed_and_already_dismissed_files() {
    let fakes = Fakes::new(200);
    let mut snapshot = unviewed_pr_snapshot();
    snapshot.files = vec![
        changed_file("src/a.rs", ViewedState::Unviewed),
        changed_file("lib/old.rs", ViewedState::Dismissed),
        changed_file("lib/new.rs", ViewedState::Unviewed),
    ];
    fakes.forge.set_snapshot(snapshot);
    fakes.workspace.put_base("src/a.rs", "old\n");
    fakes.workspace.put_disk("src/a.rs", "new\n");
    let mut prior = StoreSnapshot {
        files: vec![
            changed_file("lib/old.rs", ViewedState::Dismissed),
            changed_file("lib/new.rs", ViewedState::Unviewed),
        ],
        ..StoreSnapshot::default()
    };
    prior.local.collapsed_dirs = BTreeSet::from(["lib".to_owned()]);
    fakes.store.set_retarget_snapshot(Some(prior));

    let mut session = open_local(&fakes);
    session.set_collapsed("src", true).unwrap();
    let view = session.sync().unwrap();
    assert_eq!(
        view.collapsed_dirs,
        BTreeSet::from(["lib".to_owned(), "src".to_owned()])
    );
}
