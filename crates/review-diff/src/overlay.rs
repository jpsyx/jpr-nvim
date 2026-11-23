//! One file's diff as an overlay on the file itself: the lines that were
//! added, and which removed lines to draw above which line.

use std::ops::Range;

use review_model::{
    AddedLine, AnchorKind, FileDiffView, RemovedBlock, RemovedLine, Side, Thread, ThreadPreview,
    create_thread_preview_from_thread,
};

use crate::lines::{
    Block, create_changed_lines_from_spans, create_diff_operations_from_lines,
    diff_operations_to_blocks, line_index_to_number,
};
use crate::text::FileText;

/// The diff of `path` from `base` to `current`, for a frontend that draws a
/// single file.
///
/// It holds the added lines to mark, the removed lines to show above the
/// line that replaced them, and the base text for a split view.
#[must_use]
pub fn create_file_diff_view_from_texts(
    path: &str,
    base: &FileText,
    current: &FileText,
) -> FileDiffView {
    create_file_diff_view_with_threads(path, base, current, &[])
}

/// Builds a [`FileDiffView`] of `path` from `base` to `current` with every
/// thread on `path` placed at its current-file `display_line` (`0` for
/// file-level threads).
///
/// Use it for single-file diff views that also render inline comment markers
/// and thread previews, for example on an open file buffer.
#[must_use]
pub fn create_file_diff_view_with_threads(
    path: &str,
    base: &FileText,
    current: &FileText,
    threads: &[Thread],
) -> FileDiffView {
    let mut view = FileDiffView {
        path: path.to_owned(),
        binary: base.is_binary() || current.is_binary(),
        base_text: None,
        added: Vec::new(),
        removed: Vec::new(),
        threads: Vec::new(),
    };
    let mut removed_spans: Vec<(Range<usize>, u64)> = Vec::new();
    if !view.binary {
        view.base_text = base.as_text().map(str::to_owned);
        let old = base.lines();
        let new = current.lines();
        for block in diff_operations_to_blocks(&create_diff_operations_from_lines(&old, &new)) {
            if let Block::Change {
                old: old_span,
                new: new_span,
            } = block
            {
                let above = line_index_to_number(new_span.start);
                if !old_span.is_empty() {
                    removed_spans.push((old_span.clone(), above));
                }
                add_change(&mut view, (&old, old_span), (&new, new_span));
            }
        }
    }
    view.threads = create_overlay_previews(path, threads, &removed_spans);
    view
}

fn create_overlay_previews(
    path: &str,
    threads: &[Thread],
    removed_spans: &[(Range<usize>, u64)],
) -> Vec<ThreadPreview> {
    threads
        .iter()
        .filter(|thread| thread.anchor.file.as_deref() == Some(path))
        .filter_map(|thread| {
            let display_line = match thread.anchor.kind {
                AnchorKind::Pr => return None,
                AnchorKind::File => 0,
                AnchorKind::Line | AnchorKind::Range => match thread.anchor.side {
                    Side::Right => thread.anchor.end.unwrap_or(1),
                    Side::Left => left_line_to_above(thread.anchor.end.unwrap_or(1), removed_spans),
                },
            };
            Some(create_thread_preview_from_thread(thread, display_line))
        })
        .collect()
}

fn left_line_to_above(left_line: u64, removed_spans: &[(Range<usize>, u64)]) -> u64 {
    let Some(old_index) = usize::try_from(left_line.saturating_sub(1)).ok() else {
        return left_line;
    };
    removed_spans
        .iter()
        .find_map(|(span, above)| span.contains(&old_index).then_some(*above))
        .unwrap_or(left_line)
}

/// Adds one changed block's added lines and removed lines to `view`.
fn add_change(
    view: &mut FileDiffView,
    (old, old_span): (&[&str], Range<usize>),
    (new, new_span): (&[&str], Range<usize>),
) {
    let above = line_index_to_number(new_span.start);
    let (removed, added) = create_changed_lines_from_spans(old, old_span, new, new_span);
    view.added.extend(added.into_iter().map(|line| AddedLine {
        line: line_index_to_number(line.index),
        words: line.words,
    }));
    if !removed.is_empty() {
        view.removed.push(RemovedBlock {
            above,
            lines: removed
                .into_iter()
                .map(|line| RemovedLine {
                    text: line.text.to_owned(),
                    words: line.words,
                })
                .collect(),
        });
    }
}

#[cfg(test)]
mod tests {
    use review_model::{AddedLine, RemovedBlock, RemovedLine, WordRange};

    use super::*;

    fn create_file_text(content: &str) -> FileText {
        FileText::Text(content.to_owned())
    }

    #[test]
    fn an_edited_line_is_added_with_its_old_text_above_it() {
        let view = create_file_diff_view_from_texts(
            "a.rs",
            &create_file_text("fn main() {\nlet x = 1;\n}\n"),
            &create_file_text("fn main() {\nlet x = 2;\n}\n"),
        );
        let word = vec![WordRange { start: 8, end: 9 }];
        assert_eq!(
            view.added,
            [AddedLine {
                line: 2,
                words: word.clone()
            }]
        );
        assert_eq!(
            view.removed,
            [RemovedBlock {
                above: 2,
                lines: vec![RemovedLine {
                    text: "let x = 1;".into(),
                    words: word
                }],
            }]
        );
        assert_eq!(
            view.base_text.as_deref(),
            Some("fn main() {\nlet x = 1;\n}\n")
        );
        assert!(!view.binary);
    }

    #[test]
    fn lines_removed_at_the_end_sit_one_past_the_last_line() {
        let view = create_file_diff_view_from_texts(
            "a.rs",
            &create_file_text("a\nb\n"),
            &create_file_text("a\n"),
        );
        assert_eq!(view.added, Vec::new());
        assert_eq!(view.removed.len(), 1);
        assert_eq!(view.removed[0].above, 2);
    }

    #[test]
    fn an_added_file_is_all_added_lines_with_no_base() {
        let view = create_file_diff_view_from_texts(
            "new.rs",
            &FileText::Missing,
            &create_file_text("a\nb\n"),
        );
        let lines: Vec<u64> = view.added.iter().map(|line| line.line).collect();
        assert_eq!(lines, [1, 2]);
        assert_eq!(view.removed, Vec::new());
        assert_eq!(view.base_text, None);
    }

    #[test]
    fn a_deleted_file_is_one_removed_block_above_line_one() {
        let view = create_file_diff_view_from_texts(
            "old.rs",
            &create_file_text("a\nb\n"),
            &FileText::Missing,
        );
        assert_eq!(view.added, Vec::new());
        assert_eq!(view.removed[0].above, 1);
        assert_eq!(view.removed[0].lines.len(), 2);
    }

    #[test]
    fn a_binary_file_has_no_lines() {
        let view =
            create_file_diff_view_from_texts("logo.png", &FileText::Binary, &FileText::Binary);
        assert!(view.binary);
        assert!(view.added.is_empty() && view.removed.is_empty());
        assert_eq!(view.base_text, None);
    }

    #[test]
    fn threads_attach_to_file_header_right_lines_and_removed_block_above() {
        use review_model::{Anchor, Message, MessageSync, Origin, Side, Thread, ThreadState};
        let make_thread = |id: &str, anchor: Anchor| Thread {
            id: id.into(),
            origin: Origin::Github,
            anchor,
            state: ThreadState::Open,
            outdated: false,
            messages: vec![Message::create_with_sync(
                "M1",
                "alice",
                "check this",
                "2026-11-20T00:00:00Z",
                Some(MessageSync::Published),
            )],
            agent: None,
            promoted_to: None,
        };
        let threads = vec![
            make_thread("T-file", Anchor::file("a.rs")),
            make_thread("T-right", Anchor::side_line("a.rs", Side::Right, 2)),
            make_thread("T-left", Anchor::side_line("a.rs", Side::Left, 2)),
            make_thread("T-other", Anchor::line("other.rs", 1)),
        ];
        let view = create_file_diff_view_with_threads(
            "a.rs",
            &create_file_text("fn main() {\nold_one\nold_two\n}\n"),
            &create_file_text("fn main() {\nnew_one\n}\n"),
            &threads,
        );
        let placed: Vec<(&str, u64)> = view
            .threads
            .iter()
            .map(|preview| (preview.thread_id.as_str(), preview.display_line))
            .collect();
        assert_eq!(placed, [("T-file", 0), ("T-right", 2), ("T-left", 2)]);
    }
}
