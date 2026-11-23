use review_model::{
    AgentKind, AgentRoundKind, AgentThreadState, Anchor, AnchorKind, Origin, PrepassFinding, Side,
};

use super::super::test_support::Fakes;

#[test]
fn prepass_write_creates_answered_local_threads_with_snapshots() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
    let mut session = fakes.open_synced();

    let prepass = session.prepare_prepass(AgentKind::Claude).unwrap();
    assert_eq!(prepass.kind, AgentRoundKind::Prepass);
    assert_eq!(prepass.thread_ids, Vec::<String>::new());
    assert!(prepass.prompt.contains("prepass-write"));

    let (created, view) = session
        .prepass_write(vec![
            PrepassFinding {
                anchor: Anchor::line("src/a.rs", 2),
                body: "[high] Unused binding.".into(),
                author: None,
            },
            PrepassFinding {
                anchor: Anchor::pr(),
                body: "[nit] Clarify PR title.".into(),
                author: Some(" claude ".into()),
            },
            PrepassFinding {
                anchor: Anchor::pr(),
                body: "   ".into(),
                author: None,
            },
        ])
        .unwrap();
    assert_eq!(created.len(), 2);
    assert_eq!(created[0].origin, Origin::Local);
    assert_eq!(created[0].messages[0].author, "agent");
    assert!(!created[0].messages[0].viewer_did_author);
    assert_eq!(created[0].agent, Some(AgentThreadState::Answered));
    assert_eq!(created[0].anchor.snapshot.as_deref(), Some("let x = 1;"));
    assert_eq!(created[1].messages[0].author, "claude");
    assert_eq!(view.local_unsent_count, 0);

    let (_, after_reply) = session.reply(&created[0].id, "Please remove it.").unwrap();
    assert_eq!(after_reply.local_unsent_count, 1);
}

#[test]
fn prepare_send_rejects_empty_and_prepass_rejects_unsafe_paths() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    let err = session.prepare_send(None, AgentKind::Claude).unwrap_err();
    assert_eq!(err.to_string(), "no unsent local comments to send");

    let traversal = session.prepass_write(vec![PrepassFinding {
        anchor: Anchor::line("../../etc/passwd", 1),
        body: "[high] Bad path".into(),
        author: None,
    }]);
    assert!(traversal.is_err());
    assert_eq!(fakes.store.saved().local.threads, Vec::new());
}

#[test]
fn prepass_write_rejects_dot_git_and_zero_bounds() {
    let fakes = Fakes::new(100);
    let mut session = fakes.open_synced();
    for bad_anchor in [
        Anchor::line(".git/config", 1),
        Anchor::line("sub/.GIT/HEAD", 1),
        Anchor::line("src/a.rs", 0),
    ] {
        let err = session.prepass_write(vec![PrepassFinding {
            anchor: bad_anchor,
            body: "[high] bad".into(),
            author: None,
        }]);
        assert!(err.is_err());
    }
    assert_eq!(fakes.store.saved().local.threads, Vec::new());
}

#[test]
fn prepass_write_strips_untrusted_snapshot_and_normalizes_file_anchors() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/a.rs", "fn f() {}\nlet x = 1;\n");
    let mut session = fakes.open_synced();

    let mut left_anchor = Anchor::side_line("src/a.rs", Side::Left, 1);
    left_anchor.snapshot = Some("untrusted".into());
    let mut file_anchor = Anchor::file("src/a.rs");
    file_anchor.start = Some(5);
    file_anchor.end = Some(9);
    file_anchor.snapshot = Some("stale".into());

    let (created, _) = session
        .prepass_write(vec![
            PrepassFinding {
                anchor: left_anchor,
                body: "[med] left".into(),
                author: None,
            },
            PrepassFinding {
                anchor: file_anchor,
                body: "[low] file".into(),
                author: None,
            },
        ])
        .unwrap();
    assert_eq!(created[0].anchor.snapshot, None);
    assert_eq!(created[1].anchor.kind, AnchorKind::File);
    assert_eq!(
        (created[1].anchor.start, created[1].anchor.end),
        (None, None)
    );
    assert_eq!(created[1].anchor.snapshot, None);
}

#[test]
fn prepass_write_rejects_non_pr_files_and_accepts_pr_files_and_pr_anchor() {
    let fakes = Fakes::new(100);
    fakes
        .workspace
        .put_disk("src/unchanged.rs", "fn untouched() {}\n");
    let mut session = fakes.open_synced();

    let error = session
        .prepass_write(vec![
            PrepassFinding {
                anchor: Anchor::line("src/a.rs", 1),
                body: "[low] valid file".into(),
                author: None,
            },
            PrepassFinding {
                anchor: Anchor::line("src/unchanged.rs", 1),
                body: "[high] not changed by PR".into(),
                author: None,
            },
        ])
        .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("is not a file this pull request changes"),
        "{error}"
    );
    assert_eq!(fakes.store.saved().local.threads, Vec::new());

    let (created, _) = session
        .prepass_write(vec![
            PrepassFinding {
                anchor: Anchor::line("src/b.rs", 1),
                body: "[med] changed file".into(),
                author: None,
            },
            PrepassFinding {
                anchor: Anchor::pr(),
                body: "[nit] pr note".into(),
                author: None,
            },
        ])
        .unwrap();
    assert_eq!(created.len(), 2);
}
