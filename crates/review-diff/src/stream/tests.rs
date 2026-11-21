//! The stream's tests, read through a one-line sketch of each row.

use review_model::{ChangedFile, LineCell, LineChange, StreamRow, ViewMode, ViewedState};

use super::*;

fn create_stream_input(
    path: &str,
    viewed: ViewedState,
    base: &FileText,
    current: &FileText,
) -> StreamInput {
    StreamInput {
        file: ChangedFile {
            path: path.into(),
            additions: 1,
            deletions: 1,
            viewed,
        },
        content: Ok((base.clone(), current.clone())),
        threads: Vec::new(),
    }
}

fn create_file_text(content: &str) -> FileText {
    FileText::Text(content.to_owned())
}

/// `rows` as short strings, so a test reads like the stream it describes.
fn rows_to_sketch(rows: &[StreamRow]) -> Vec<String> {
    rows.iter()
        .map(|row| match row {
            StreamRow::File { path, folded, .. } => {
                format!("file {path}{}", if *folded { " folded" } else { "" })
            }
            StreamRow::Hunk { header, target, .. } => format!("{header} ->{target}"),
            StreamRow::Note { text, .. } => format!("note {text}"),
            StreamRow::Thread { thread, target, .. } => {
                format!("thread {} ->{target}", thread.thread_id)
            }
            StreamRow::Line {
                left,
                right,
                target,
                threads,
                ..
            } => {
                let suffix = if threads.is_empty() {
                    String::new()
                } else {
                    let ids: Vec<&str> = threads
                        .iter()
                        .map(|preview| preview.thread_id.as_str())
                        .collect();
                    format!(" [{}]", ids.join(","))
                };
                format!(
                    "{} | {} ->{target}{suffix}",
                    cell_to_sketch(left.as_ref()),
                    cell_to_sketch(right.as_ref())
                )
            }
        })
        .collect()
}

fn cell_to_sketch(cell: Option<&LineCell>) -> String {
    cell.map_or_else(
        || "~".to_owned(),
        |cell| {
            let sign = match cell.change {
                LineChange::Context => ' ',
                LineChange::Added => '+',
                LineChange::Removed => '-',
            };
            format!("{}{sign}{}", cell.line, cell.text)
        },
    )
}

fn build_sketch_from_texts(base: &FileText, current: &FileText, mode: ViewMode) -> Vec<String> {
    let inputs = [create_stream_input(
        "a.rs",
        ViewedState::Unviewed,
        base,
        current,
    )];
    rows_to_sketch(&create_stream_view_from_inputs(&inputs, mode).rows)
}

#[test]
fn unified_puts_removed_lines_before_added_ones() {
    assert_eq!(
        build_sketch_from_texts(
            &create_file_text("a\nb\nc\n"),
            &create_file_text("a\nB\nc\n"),
            ViewMode::Unified
        ),
        [
            "file a.rs",
            "@@ -1,3 +1,3 @@ ->1",
            "1 a | 1 a ->1",
            "2-b | ~ ->2",
            "~ | 2+B ->2",
            "3 c | 3 c ->3",
        ]
    );
}

#[test]
fn split_pairs_removed_and_added_lines_side_by_side() {
    assert_eq!(
        build_sketch_from_texts(
            &create_file_text("a\nb\nc\n"),
            &create_file_text("a\nB\nX\nc\n"),
            ViewMode::Split
        ),
        [
            "file a.rs",
            "@@ -1,3 +1,4 @@ ->1",
            "1 a | 1 a ->1",
            "2-b | 2+B ->2",
            "~ | 3+X ->3",
            "3 c | 4 c ->4",
        ]
    );
}

#[test]
fn distant_changes_get_their_own_hunks() {
    let lines: Vec<String> = (1..=10).map(|line| format!("l{line}")).collect();
    let base = lines.join("\n") + "\n";
    let current = base.replace("l1\n", "L1\n").replace("l10\n", "L10\n");
    let headers: Vec<String> = build_sketch_from_texts(
        &create_file_text(&base),
        &create_file_text(&current),
        ViewMode::Unified,
    )
    .into_iter()
    .filter(|row| row.starts_with("@@"))
    .collect();
    assert_eq!(headers, ["@@ -1,4 +1,4 @@ ->1", "@@ -7,4 +7,4 @@ ->7"]);
}

#[test]
fn lines_removed_at_the_end_jump_to_the_last_line() {
    assert_eq!(
        build_sketch_from_texts(
            &create_file_text("a\nb\n"),
            &create_file_text("a\n"),
            ViewMode::Unified
        ),
        [
            "file a.rs",
            "@@ -1,2 +1,1 @@ ->1",
            "1 a | 1 a ->1",
            "2-b | ~ ->1"
        ]
    );
}

#[test]
fn an_added_file_starts_from_an_empty_side() {
    assert_eq!(
        build_sketch_from_texts(
            &FileText::Missing,
            &create_file_text("a\nb\n"),
            ViewMode::Unified
        ),
        [
            "file a.rs",
            "@@ -0,0 +1,2 @@ ->1",
            "~ | 1+a ->1",
            "~ | 2+b ->2"
        ]
    );
}

#[test]
fn viewed_files_are_folded_and_dismissed_ones_are_not() {
    let inputs = [
        create_stream_input(
            "a.rs",
            ViewedState::Viewed,
            &create_file_text("a\n"),
            &create_file_text("b\n"),
        ),
        create_stream_input(
            "b.rs",
            ViewedState::Dismissed,
            &create_file_text("a\n"),
            &create_file_text("b\n"),
        ),
    ];
    let headers: Vec<String> =
        rows_to_sketch(&create_stream_view_from_inputs(&inputs, ViewMode::Unified).rows)
            .into_iter()
            .filter(|row| row.starts_with("file"))
            .collect();
    assert_eq!(headers, ["file a.rs folded", "file b.rs"]);
}

#[test]
fn files_without_lines_get_a_note() {
    let binary = create_stream_input(
        "logo.png",
        ViewedState::Unviewed,
        &FileText::Binary,
        &FileText::Binary,
    );
    let same = create_stream_input(
        "same.rs",
        ViewedState::Unviewed,
        &create_file_text("a\n"),
        &create_file_text("a\n"),
    );
    let mut unreadable = create_stream_input(
        "gone.rs",
        ViewedState::Unviewed,
        &create_file_text(""),
        &create_file_text(""),
    );
    unreadable.content = Err("permission denied".into());
    let rows = rows_to_sketch(
        &create_stream_view_from_inputs(&[binary, same, unreadable], ViewMode::Split).rows,
    );
    assert_eq!(
        rows,
        [
            "file logo.png",
            "note binary file",
            "file same.rs",
            "note no changes against the base",
            "file gone.rs",
            "note could not read this file: permission denied",
        ]
    );
}

#[test]
fn the_view_keeps_its_mode() {
    assert_eq!(
        create_stream_view_from_inputs(&[], ViewMode::Split).mode,
        ViewMode::Split
    );
}

#[test]
fn stream_places_file_line_and_outdated_threads_without_duplicating() {
    use review_model::{Anchor, Message, MessageSync, Origin, Side, Thread, ThreadState};
    let make_thread = |id: &str, anchor: Anchor| Thread {
        id: id.into(),
        origin: Origin::Github,
        anchor,
        state: ThreadState::Open,
        outdated: id == "T-outdated",
        messages: vec![Message::create_with_sync(
            "M1",
            "alice",
            "note",
            "2026-11-20T00:00:00Z",
            Some(MessageSync::Published),
        )],
    };
    let mut input = create_stream_input(
        "a.rs",
        ViewedState::Unviewed,
        &create_file_text("same\nold\n"),
        &create_file_text("same\nnew\n"),
    );
    input.threads = vec![
        make_thread("T-file", Anchor::file("a.rs")),
        make_thread("T-context", Anchor::side_line("a.rs", Side::Right, 1)),
        make_thread("T-added", Anchor::side_line("a.rs", Side::Right, 2)),
        make_thread("T-outdated", Anchor::side_line("a.rs", Side::Right, 99)),
    ];
    let rows = create_stream_view_from_inputs(&[input], ViewMode::Unified).rows;
    assert_eq!(
        rows_to_sketch(&rows),
        vec![
            "file a.rs",
            "thread T-file ->1",
            "thread T-outdated ->99",
            "@@ -1,2 +1,2 @@ ->1",
            "1 same | 1 same ->1 [T-context]",
            "2-old | ~ ->2",
            "~ | 2+new ->2 [T-added]",
        ]
    );
}
