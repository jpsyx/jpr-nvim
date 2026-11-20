//! One file's diff as an overlay on the file itself: the lines that were
//! added, and which removed lines to draw above which line.

use std::ops::Range;

use review_model::{AddedLine, FileDiffView, RemovedBlock, RemovedLine};

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
    let mut view = FileDiffView {
        path: path.to_owned(),
        binary: base.is_binary() || current.is_binary(),
        base_text: None,
        added: Vec::new(),
        removed: Vec::new(),
    };
    if view.binary {
        return view;
    }
    view.base_text = base.as_text().map(str::to_owned);
    let old = base.lines();
    let new = current.lines();
    for block in diff_operations_to_blocks(&create_diff_operations_from_lines(&old, &new)) {
        if let Block::Change {
            old: old_span,
            new: new_span,
        } = block
        {
            add_change(&mut view, (&old, old_span), (&new, new_span));
        }
    }
    view
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
        assert!(view.added.is_empty());
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
        assert!(view.removed.is_empty());
        assert_eq!(view.base_text, None);
    }

    #[test]
    fn a_deleted_file_is_one_removed_block_above_line_one() {
        let view = create_file_diff_view_from_texts(
            "old.rs",
            &create_file_text("a\nb\n"),
            &FileText::Missing,
        );
        assert!(view.added.is_empty());
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
}
