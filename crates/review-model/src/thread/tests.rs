use super::*;

#[test]
fn a_thread_round_trips_through_json_with_its_wire_spellings() {
    let thread = Thread {
        id: "T1".into(),
        origin: Origin::Github,
        anchor: Anchor::line("src/a.rs", 12),
        state: ThreadState::Open,
        outdated: false,
        messages: vec![Message::create_with_sync(
            "C1",
            "bob",
            "why?",
            "2026-11-19T00:00:00Z",
            Some(MessageSync::Draft),
        )],
    };
    let json = serde_json::to_value(&thread).unwrap();
    assert_eq!(json["origin"], "github");
    assert_eq!(json["anchor"]["kind"], "line");
    assert_eq!(json["anchor"]["side"], "RIGHT");
    assert_eq!(json["state"], "open");
    assert_eq!(json["messages"][0]["sync"], "draft");
    let back: Thread = serde_json::from_value(json).unwrap();
    assert_eq!(back, thread);
}

#[test]
fn a_local_message_omits_sync_and_outdated_defaults_to_false() {
    let json = serde_json::json!({
        "id": "L1", "origin": "local",
        "anchor": { "file": null, "kind": "pr", "side": "RIGHT", "start": null, "end": null, "commit": null, "snapshot": null },
        "state": "resolved",
        "messages": [{ "id": "m", "author": "me", "body": "b", "created": "c", "updated": "u" }]
    });
    let thread: Thread = serde_json::from_value(json).unwrap();
    assert!(!thread.outdated);
    assert_eq!(thread.anchor.kind, AnchorKind::Pr);
    assert_eq!(thread.messages[0].sync, None);
    let serialized = serde_json::to_value(&thread).unwrap();
    assert!(serialized["messages"][0].get("sync").is_none());
}

#[test]
fn sides_and_anchor_kinds_map_known_wire_spellings_and_return_none_for_unknown_values() {
    assert_eq!(Side::parse("LEFT"), Some(Side::Left));
    assert_eq!(Side::parse("RIGHT"), Some(Side::Right));
    assert_eq!(Side::parse("CENTER"), None);
    assert_eq!(AnchorKind::parse("line"), Some(AnchorKind::Line));
    assert_eq!(AnchorKind::parse("range"), Some(AnchorKind::Range));
    assert_eq!(AnchorKind::parse("file"), Some(AnchorKind::File));
    assert_eq!(AnchorKind::parse("pr"), Some(AnchorKind::Pr));
    assert_eq!(AnchorKind::parse("hunk"), None);
}

#[test]
fn anchor_range_orders_reversed_bounds_and_collapses_equal_lines_to_line_kind() {
    let single = Anchor::range("a.rs", Side::Left, 5, 5);
    assert_eq!(
        (single.kind, single.start, single.end),
        (AnchorKind::Line, Some(5), Some(5))
    );
    let span = Anchor::range("a.rs", Side::Right, 9, 4);
    assert_eq!(
        (span.kind, span.start, span.end),
        (AnchorKind::Range, Some(4), Some(9))
    );
    assert_eq!(Anchor::file("a.rs").kind, AnchorKind::File);
    assert_eq!(Anchor::pr().kind, AnchorKind::Pr);
}

#[test]
fn thread_preview_ranks_failed_above_draft_above_published_across_messages() {
    let mut thread = Thread {
        id: "T1".into(),
        origin: Origin::Github,
        anchor: Anchor::line("src/a.rs", 7),
        state: ThreadState::Open,
        outdated: false,
        messages: vec![Message::create_with_sync(
            "M1",
            "alice",
            "published root",
            "2026-11-20T00:00:00Z",
            Some(MessageSync::Published),
        )],
    };
    assert_eq!(
        create_thread_preview_from_thread(&thread, 7).kind,
        MarkerKind::Published
    );

    thread.messages.push(Message::create_with_sync(
        "M2",
        "bob",
        "draft reply",
        "2026-11-20T00:01:00Z",
        Some(MessageSync::Draft),
    ));
    assert_eq!(
        create_thread_preview_from_thread(&thread, 7).kind,
        MarkerKind::Draft
    );

    thread.messages.push(Message::create_with_sync(
        "M3",
        "bob",
        "failed reply",
        "2026-11-20T00:02:00Z",
        Some(MessageSync::Failed),
    ));
    assert_eq!(
        create_thread_preview_from_thread(&thread, 7).kind,
        MarkerKind::Failed
    );
}

#[test]
fn thread_preview_snippet_uses_trimmed_first_non_empty_line() {
    let thread = Thread {
        id: "T1".into(),
        origin: Origin::Github,
        anchor: Anchor::line("src/a.rs", 7),
        state: ThreadState::Open,
        outdated: false,
        messages: vec![Message::create_with_sync(
            "M1",
            "alice",
            "\n  first line  \nsecond line",
            "2026-11-20T00:00:00Z",
            Some(MessageSync::Published),
        )],
    };
    let preview = create_thread_preview_from_thread(&thread, 7);
    assert_eq!(preview.snippet, "first line");
    assert_eq!(preview.display_line, 7);
}
