//! Unit tests for unlinked local worktree review mode on `ReviewSession`.

use review_model::{
    AgentKind, AgentThreadState, Anchor, Event, LocalReviewContext, Origin, PrepassFinding,
    ReviewEvent, SyncState, ViewMode, ViewedState,
};

use super::ReviewSession;
use super::test_support::Fakes;
use crate::fakes::create_fake_ports;

fn sample_local_context() -> LocalReviewContext {
    LocalReviewContext {
        branch: "feat/local-mode".into(),
        base_ref: "develop".into(),
        base_sha: "base000".into(),
        repo: Some("octo/widgets".into()),
    }
}

fn open_local_fakes(fakes: &Fakes) -> ReviewSession {
    let ports = create_fake_ports(&fakes.forge, &fakes.store, &fakes.workspace, &fakes.clock);
    ReviewSession::open_local(sample_local_context(), ports).expect("local session opens")
}

#[test]
fn open_local_populates_files_diffs_stream_and_persists_local_viewed_without_calling_forge() {
    let fakes = Fakes::new(100);
    fakes.forge.fail_with(Some("forge must not be called"));
    fakes.workspace.put_base("src/a.rs", "fn a() {}\n");
    fakes
        .workspace
        .put_disk("src/a.rs", "fn a() {\n    println!(\"hi\");\n}\n");
    fakes
        .workspace
        .put_disk("src/new.rs", "pub const X: u8 = 1;\n");

    let mut session = open_local_fakes(&fakes);
    let events = session.subscribe();
    let view = session.view();
    assert!(!session.is_linked());
    assert!(view.pr.is_none());
    assert_eq!(view.local_context, Some(sample_local_context()));
    assert_eq!(view.sync, SyncState::Never);
    assert_eq!(view.files.len(), 2);
    assert!(view.files.iter().all(|row| row.is_local_only));

    let diff = session.file_diff("src/a.rs").expect("file_diff succeeds");
    assert_ne!(diff.added.len(), 0);
    let stream = session.stream(ViewMode::Unified).expect("stream succeeds");
    assert_ne!(stream.rows.len(), 0);

    let updated = session
        .set_viewed("src/a.rs", true)
        .expect("local set_viewed succeeds");
    let row_a = updated
        .files
        .iter()
        .find(|row| row.path == "src/a.rs")
        .expect("src/a.rs row");
    assert_eq!(row_a.viewed, ViewedState::Viewed);
    assert_eq!(fakes.forge.viewed_calls(), Vec::<(String, bool)>::new());
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
    assert!(matches!(
        events.try_recv().ok(),
        Some(Event::ViewedChanged { .. })
    ));

    // Disk edit transitions local Viewed to Dismissed on refresh.
    fakes
        .workspace
        .put_disk("src/a.rs", "fn a() {\n    println!(\"changed\");\n}\n");
    let refreshed = session.refresh_worktree(&[]).expect("refresh succeeds");
    let row_a_after = refreshed
        .files
        .iter()
        .find(|row| row.path == "src/a.rs")
        .expect("src/a.rs row");
    assert_eq!(row_a_after.viewed, ViewedState::Dismissed);
}

#[test]
fn local_mode_refuses_all_github_only_operations_and_returns_empty_mentions() {
    let fakes = Fakes::new(100);
    fakes.workspace.put_base("src/a.rs", "old\n");
    fakes.workspace.put_disk("src/a.rs", "new\n");
    let mut session = open_local_fakes(&fakes);

    assert_eq!(session.mentions(), []);

    let (local_thread, _) = session
        .comment_with_origin(Anchor::line("src/a.rs", 1), "local note", Origin::Local)
        .expect("local comment succeeds");

    let errors = [
        session
            .comment(Anchor::line("src/a.rs", 1), "github note")
            .unwrap_err()
            .to_string(),
        session
            .promote_thread(&local_thread.id, "promoted")
            .unwrap_err()
            .to_string(),
        session
            .suggest_from_edit("src/a.rs", "fixed\n", 1, None)
            .unwrap_err()
            .to_string(),
        session.submit_preview().unwrap_err().to_string(),
        session
            .submit_review(ReviewEvent::Comment, "lgtm")
            .unwrap_err()
            .to_string(),
        session.push().unwrap_err().to_string(),
        session
            .retry_message(&local_thread.messages[0].id)
            .unwrap_err()
            .to_string(),
        session
            .prepare_conflict_resolution(&["src/a.rs".into()], AgentKind::Claude)
            .unwrap_err()
            .to_string(),
    ];

    for error in errors {
        assert!(
            error.contains("not linked to a GitHub pull request yet"),
            "unexpected error: {error}"
        );
    }
}

#[test]
fn local_mode_supports_local_comments_agent_launch_bulk_send_and_prepass() {
    let fakes = Fakes::new(200);
    fakes.workspace.put_base("src/a.rs", "fn a() {}\n");
    fakes.workspace.put_disk("src/a.rs", "fn a() { 1 }\n");
    let mut session = open_local_fakes(&fakes);

    let (thread, _) = session
        .comment_with_origin(
            Anchor::line("src/a.rs", 1),
            "please simplify",
            Origin::Local,
        )
        .expect("local comment succeeds");
    assert_eq!(thread.origin, Origin::Local);

    let plan = session
        .prepare_agent_launch(AgentKind::Codex)
        .expect("agent launch plan succeeds");
    assert!(!plan.is_resume);
    assert_ne!(plan.session_id, "");

    let dispatch = session
        .prepare_send(None, AgentKind::Codex)
        .expect("prepare_send succeeds");
    assert_eq!(dispatch.thread_ids, vec![thread.id.clone()]);
    assert!(dispatch.prompt.contains("feat/local-mode"));
    assert!(dispatch.prompt.contains("develop"));
    assert!(
        dispatch
            .prompt
            .contains("Keep edits unstaged in this worktree")
    );

    let (round, _) = session
        .confirm_send(
            dispatch.round,
            dispatch.kind,
            &dispatch.thread_ids,
            &dispatch.prompt,
        )
        .expect("confirm_send succeeds");
    assert_eq!(round.round, 1);
    assert_eq!(
        session.threads()[0].agent,
        Some(AgentThreadState::Sent { round: 1 })
    );

    let (replied_thread, _) = session
        .agent_reply(&thread.id, "Simplified.", None)
        .expect("agent_reply succeeds");
    assert_eq!(replied_thread.agent, Some(AgentThreadState::Answered));

    let prepass = session
        .prepare_prepass(AgentKind::Codex)
        .expect("prepare_prepass succeeds");
    assert!(prepass.prompt.contains("feat/local-mode"));
    assert!(prepass.prompt.contains("develop"));

    let (created, _) = session
        .prepass_write(vec![PrepassFinding {
            anchor: Anchor::line("src/a.rs", 1),
            body: "check edge case".into(),
            author: None,
        }])
        .expect("prepass_write succeeds");
    assert_eq!(created.len(), 1);
}

#[test]
fn local_mode_refreshes_base_sha_when_base_ref_moves() {
    let fakes = Fakes::new(300);
    fakes.workspace.set_ref_sha("develop", "base000");
    fakes.workspace.put_base("src/a.rs", "v1\n");
    fakes.workspace.put_disk("src/a.rs", "v2\n");
    let mut session = open_local_fakes(&fakes);
    assert_eq!(
        session
            .view()
            .local_context
            .as_ref()
            .map(|ctx| ctx.base_sha.as_str()),
        Some("base000")
    );

    fakes.workspace.set_ref_sha("develop", "newbase99");
    let refreshed = session.refresh_worktree(&[]).expect("refresh succeeds");
    assert_eq!(
        refreshed
            .local_context
            .as_ref()
            .map(|ctx| ctx.base_sha.as_str()),
        Some("newbase99")
    );
    assert!(fakes.workspace.merge_base_calls() >= 2);
}
