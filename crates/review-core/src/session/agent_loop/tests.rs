use review_model::{AgentKind, AgentRoundKind, AgentThreadState, Anchor, Event, Origin};

use super::super::test_support::Fakes;
use crate::ports::ReviewStore;

fn assert_rfc4122_v4_uuid(value: &str) {
    assert_eq!(value.len(), 36, "expected 36-char UUID, got {value}");
    let bytes = value.as_bytes();
    for index in [8, 13, 18, 23] {
        assert_eq!(bytes[index], b'-', "expected hyphen at {index} in {value}");
    }
    assert_eq!(bytes[14], b'4', "expected v4 nibble in {value}");
    assert!(
        matches!(bytes[19], b'8' | b'9' | b'a' | b'b'),
        "expected RFC 4122 variant nibble in {value}"
    );
    assert!(
        value
            .chars()
            .enumerate()
            .all(|(index, ch)| [8, 13, 18, 23].contains(&index) || ch.is_ascii_hexdigit()),
        "expected hex digits in {value}"
    );
}

#[test]
fn prepare_agent_launch_assigns_v4_uuid_once_and_marks_later_launches_as_resume() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    session
        .record_daemon_with_socket(4242, "/tmp/wt", Some("/tmp/jpr.sock"))
        .unwrap();

    let first = session.prepare_agent_launch(AgentKind::Claude).unwrap();
    assert!(!first.is_resume);
    assert_eq!(first.kind, AgentKind::Claude);
    assert_eq!(first.socket.as_deref(), Some("/tmp/jpr.sock"));
    assert_rfc4122_v4_uuid(&first.session_id);
    assert_eq!(
        fakes.store.saved().session.agent_session_id.as_deref(),
        Some(first.session_id.as_str())
    );

    let resumed = session.prepare_agent_launch(AgentKind::Claude).unwrap();
    assert!(resumed.is_resume);
    assert_eq!(resumed.session_id, first.session_id);

    let codex = session.prepare_agent_launch(AgentKind::Codex).unwrap();
    assert!(!codex.is_resume);
    assert_eq!(codex.kind, AgentKind::Codex);
    assert_ne!(codex.session_id, first.session_id);
    assert_rfc4122_v4_uuid(&codex.session_id);
}

#[test]
fn two_phase_send_keeps_threads_unsent_until_confirm_send_records_round() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let (thread, _) = session
        .comment_with_origin(Anchor::line("src/a.rs", 1), "Check clone", Origin::Local)
        .unwrap();
    let events = session.subscribe();

    let dispatch = session.prepare_send(None, AgentKind::Claude).unwrap();
    assert_eq!(dispatch.round, 1);
    assert_eq!(dispatch.thread_ids, vec![thread.id.clone()]);
    assert!(dispatch.prompt.contains(&thread.id));
    assert_eq!(
        session.threads().last().unwrap().agent,
        Some(AgentThreadState::Unsent)
    );
    assert_eq!(fakes.store.rounds().unwrap(), Vec::new());

    let (ids, prompt) = (&dispatch.thread_ids, &dispatch.prompt);
    let (recorded, view) = session
        .confirm_send(1, AgentRoundKind::Send, ids, prompt)
        .unwrap();
    assert_eq!((recorded.round, view.local_unsent_count), (1, 0));
    assert_eq!(
        session.threads().last().unwrap().agent,
        Some(AgentThreadState::Sent { round: 1 })
    );
    assert_eq!(fakes.store.rounds().unwrap().len(), 1);
    assert!(matches!(
        events.try_recv().unwrap(),
        Event::ThreadsChanged { .. }
    ));
    assert!(matches!(
        events.try_recv().unwrap(),
        Event::AgentRound { round, .. } if round.round == 1
    ));

    session.reply(&thread.id, "Follow-up").unwrap();
    let second_dispatch = session.prepare_send(None, AgentKind::Claude).unwrap();
    assert_eq!(second_dispatch.round, 2);
}

#[test]
fn prepare_agent_launch_and_confirm_send_roll_back_on_save_failure() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let (thread, _) = session
        .comment_with_origin(Anchor::line("src/a.rs", 1), "Check", Origin::Local)
        .unwrap();

    fakes.store.fail_saves_with(Some("disk full"));
    assert!(session.prepare_agent_launch(AgentKind::Claude).is_err());
    assert!(session.saved.session.agent_session_id.is_none());

    assert!(
        session
            .confirm_send(
                1,
                AgentRoundKind::Send,
                std::slice::from_ref(&thread.id),
                "prompt"
            )
            .is_err()
    );
    assert_eq!(
        session.threads().last().unwrap().agent,
        Some(AgentThreadState::Unsent)
    );
    assert_eq!(session.saved.local.next_round, 0);

    fakes.store.fail_saves_with(None);
    let plan = session.prepare_agent_launch(AgentKind::Claude).unwrap();
    assert!(!plan.is_resume);
}

#[test]
fn confirm_send_rejects_stale_rounds_and_kind_thread_id_mismatches() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let (thread, _) = session
        .comment_with_origin(Anchor::line("src/a.rs", 1), "Check", Origin::Local)
        .unwrap();
    let ids = std::slice::from_ref(&thread.id);

    assert!(
        session
            .confirm_send(0, AgentRoundKind::Send, ids, "p")
            .is_err()
    );
    assert!(
        session
            .confirm_send(1, AgentRoundKind::Send, &[], "p")
            .is_err()
    );
    assert!(
        session
            .confirm_send(1, AgentRoundKind::Prepass, ids, "p")
            .is_err()
    );
    let conflict_error = session
        .confirm_send(1, AgentRoundKind::Conflict, ids, "p")
        .unwrap_err();
    assert_eq!(
        conflict_error.to_string(),
        "conflict round cannot include thread IDs"
    );

    session
        .confirm_send(1, AgentRoundKind::Send, ids, "p")
        .unwrap();
    let stale = session.confirm_send(1, AgentRoundKind::Send, ids, "p");
    assert!(
        stale
            .unwrap_err()
            .to_string()
            .contains("stale or duplicate")
    );
}

#[test]
fn prepare_conflict_resolution_rejects_unsynced_empty_and_unsafe_paths() {
    let fakes = Fakes::new(100);
    assert!(
        fakes
            .open()
            .prepare_conflict_resolution(&["src/a.rs".into()], AgentKind::Claude)
            .is_err()
    );
    let session = fakes.open_synced();
    assert!(
        session
            .prepare_conflict_resolution(&[], AgentKind::Claude)
            .is_err()
    );
    for unsafe_path in [
        "../etc/passwd",
        "/abs/file.rs",
        ".git/config",
        "src/a\nb.rs",
        "src/a\rb.rs",
        "src/`evil`.rs",
    ] {
        assert!(
            session
                .prepare_conflict_resolution(&[unsafe_path.into()], AgentKind::Claude)
                .is_err(),
            "expected {unsafe_path:?} to be rejected"
        );
    }
}

#[test]
fn prepare_conflict_resolution_builds_conflict_dispatch_and_confirm_send_records_it() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let events = session.subscribe();

    let paths = vec!["src/a.rs".to_owned(), "src/a.rs".to_owned()];
    let dispatch = session
        .prepare_conflict_resolution(&paths, AgentKind::Claude)
        .unwrap();
    assert_eq!(dispatch.round, 1);
    assert_eq!(dispatch.kind, AgentRoundKind::Conflict);
    assert_eq!(dispatch.thread_ids, Vec::<String>::new());
    assert_eq!(dispatch.prompt.matches("- `src/a.rs`").count(), 1);

    let (recorded, _) = session
        .confirm_send(
            dispatch.round,
            AgentRoundKind::Conflict,
            &[],
            &dispatch.prompt,
        )
        .unwrap();
    assert_eq!(recorded.kind, AgentRoundKind::Conflict);
    assert_eq!(fakes.store.rounds().unwrap(), vec![recorded]);
    assert!(matches!(
        events.try_recv().unwrap(),
        Event::AgentRound { round, .. } if round.kind == AgentRoundKind::Conflict
    ));
}
