use review_model::{Anchor, Origin, Side, Thread, ThreadState};

use super::*;

fn create_local_line_thread(start: u64, end: u64, snapshot: &str) -> Thread {
    let mut anchor = Anchor::range("src/lib.rs", Side::Right, start, end);
    anchor.snapshot = Some(snapshot.to_owned());
    Thread {
        id: "loc-1".into(),
        origin: Origin::Local,
        anchor,
        state: ThreadState::Open,
        outdated: false,
        messages: Vec::new(),
        agent: None,
        promoted_to: None,
    }
}

#[test]
fn captures_inclusive_line_slice_snapshot() {
    let text = "fn a() {}\nlet count = 1;\nlet total = count + 2;\n";
    let anchor = Anchor::range("src/lib.rs", Side::Right, 2, 3);
    assert_eq!(
        extract_snapshot_from_text(text, &anchor).as_deref(),
        Some("let count = 1;\nlet total = count + 2;")
    );
    assert_eq!(extract_snapshot_from_text(text, &Anchor::pr()), None);
    assert_eq!(
        extract_snapshot_from_text(text, &Anchor::line("src/lib.rs", 99)),
        None
    );
}

#[test]
fn shifts_anchor_down_when_lines_are_inserted_above() {
    let updated_text = "// header\n// second\nfn a() {}\nlet count = 1;\nlet total = count + 2;\n";
    let mut thread = create_local_line_thread(2, 3, "let count = 1;\nlet total = count + 2;");
    let did_change = reanchor_thread_in_text(&mut thread, updated_text);
    assert!(did_change);
    assert_eq!(thread.anchor.start, Some(4));
    assert_eq!(thread.anchor.end, Some(5));
    assert!(!thread.outdated);
}

#[test]
fn falls_back_to_trimmed_match_when_indentation_changes() {
    let reindented_text = "fn wrap() {\n    let count = 1;\n    let total = count + 2;\n}\n";
    let mut thread = create_local_line_thread(1, 2, "let count = 1;\nlet total = count + 2;");
    thread.outdated = true;
    let did_change = reanchor_thread_in_text(&mut thread, reindented_text);
    assert!(did_change);
    assert_eq!(thread.anchor.start, Some(2));
    assert_eq!(thread.anchor.end, Some(3));
    assert!(!thread.outdated);
}

#[test]
fn picks_closest_duplicate_match_and_marks_deleted_snapshot_outdated() {
    let duplicate_text = "return Ok(());\nfn mid() {}\nreturn Ok(());\n";
    let mut thread = create_local_line_thread(3, 3, "return Ok(());");
    assert!(!reanchor_thread_in_text(&mut thread, duplicate_text));
    assert_eq!(thread.anchor.start, Some(3));

    let removed_text = "fn mid() {}\n";
    assert!(reanchor_thread_in_text(&mut thread, removed_text));
    assert!(thread.outdated);
    assert!(!reanchor_thread_in_text(&mut thread, removed_text));
}

#[test]
fn preserves_trailing_blank_line_when_reanchoring_multiline_snapshot() {
    let original = "fn a() {}\nlet count = 1;\n\nfn b() {}\n";
    let anchor = Anchor::range("src/lib.rs", Side::Right, 2, 3);
    let snapshot = extract_snapshot_from_text(original, &anchor).unwrap();
    assert_eq!(snapshot, "let count = 1;\n");

    let shifted = "// added\nfn a() {}\nlet count = 1;\n\nfn b() {}\n";
    let mut thread = create_local_line_thread(2, 3, &snapshot);
    assert!(reanchor_thread_in_text(&mut thread, shifted));
    assert_eq!(thread.anchor.start, Some(3));
    assert_eq!(thread.anchor.end, Some(4));
}

#[test]
fn uses_end_line_when_line_anchor_has_no_start() {
    let text = "return Ok(());\nfn mid() {}\nreturn Ok(());\n";
    let mut thread = create_local_line_thread(3, 3, "return Ok(());");
    thread.anchor.kind = AnchorKind::Line;
    thread.anchor.start = None;
    thread.anchor.end = Some(3);
    assert!(reanchor_thread_in_text(&mut thread, text));
    assert_eq!(thread.anchor.start, Some(3));
    assert_eq!(thread.anchor.end, Some(3));
}

#[test]
fn whitespace_only_snapshot_does_not_match_arbitrary_blank_lines_via_trimmed_fallback() {
    let text = "\nfn a() {}\n    \n";
    let mut thread = create_local_line_thread(3, 3, "  ");
    assert!(reanchor_thread_in_text(&mut thread, text));
    assert!(thread.outdated);
}

#[test]
fn apply_anchor_update_keeps_outdated_when_lines_are_out_of_bounds() {
    let mut thread = create_local_line_thread(2, 2, "old line");
    thread.outdated = true;
    let short_disk = AnchorDiskState::Utf8("only one line\n".to_owned());

    let changed = apply_anchor_update(
        &mut thread,
        &LocalAnchorUpdate {
            thread_id: "loc-1".into(),
            start: 5,
            end: 5,
        },
        &short_disk,
    );
    assert!(changed);
    assert!(thread.outdated);
    assert_eq!(thread.anchor.snapshot, None);

    let cleared = apply_anchor_update(
        &mut thread,
        &LocalAnchorUpdate {
            thread_id: "loc-1".into(),
            start: 1,
            end: 1,
        },
        &short_disk,
    );
    assert!(cleared);
    assert!(!thread.outdated);
    assert_eq!(thread.anchor.snapshot.as_deref(), Some("only one line"));
}

#[test]
fn validate_safe_relative_path_rejects_control_and_bidi_characters() {
    for bad_path in [
        "src/a\nb.rs",
        "src/a\rb.rs",
        "src/a\tb.rs",
        "src/a\x1bb.rs",
        "src/a\u{009b}b.rs",
        "src/a\u{2028}b.rs",
        "src/a\u{202e}b.rs",
        "src/a\u{2066}b.rs",
    ] {
        assert!(
            validate_safe_relative_path(bad_path).is_err(),
            "expected {bad_path:?} to fail validation"
        );
    }
    assert!(validate_safe_relative_path("src/valid_file.rs").is_ok());
}
