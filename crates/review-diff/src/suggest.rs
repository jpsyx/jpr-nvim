//! Turning one locally edited hunk into a GitHub `suggestion` block and the
//! text that reverts that hunk.

use std::ops::Range;

use review_model::{Anchor, Side, SuggestedEdit};

use crate::lines::{
    Block, create_diff_operations_from_lines, diff_operations_to_blocks, line_index_to_number,
};

/// Turns the edited hunk touching 1-based `cursor_line` of `edited_text`
/// (compared against `head_text`) into a [`SuggestedEdit`].
///
/// Returns `None` when `head_text` is empty, `cursor_line` is out of bounds,
/// or no changed hunk touches `cursor_line`, for example when a reviewer edits
/// a working buffer to propose a fenced suggestion while restoring `head_text`.
#[must_use]
pub fn create_suggestion_from_edit(
    path: &str,
    head_text: &str,
    edited_text: &str,
    cursor_line: u64,
) -> Option<SuggestedEdit> {
    let head_lines: Vec<&str> = head_text.lines().collect();
    let edited_lines: Vec<&str> = edited_text.lines().collect();
    if head_lines.is_empty() {
        return None;
    }
    let cursor_index = cursor_line_to_index(cursor_line, edited_lines.len())?;
    let blocks = diff_operations_to_blocks(&create_diff_operations_from_lines(
        &head_lines,
        &edited_lines,
    ));
    let (raw_old, raw_new) = find_change_at_cursor(&blocks, cursor_index)?;
    let (old_span, new_span) = anchorable_spans(
        raw_old.clone(),
        raw_new.clone(),
        head_lines.len(),
        edited_lines.len(),
    )?;
    let suggestion_body = build_suggestion_fence(edited_lines.get(new_span)?);
    let has_trailing_newline = if raw_new.end < edited_lines.len() {
        edited_text
    } else {
        head_text
    }
    .ends_with('\n');
    Some(SuggestedEdit {
        anchor: create_head_anchor(path, &old_span),
        suggestion_body,
        reverted_text: build_reverted_text(
            &head_lines,
            &edited_lines,
            raw_old,
            raw_new,
            has_trailing_newline,
        ),
    })
}

fn create_head_anchor(path: &str, old_span: &Range<usize>) -> Anchor {
    Anchor::range(
        path,
        Side::Right,
        line_index_to_number(old_span.start),
        line_index_to_number(old_span.end - 1),
    )
}

fn cursor_line_to_index(cursor_line: u64, edited_len: usize) -> Option<usize> {
    let cursor_index = usize::try_from(cursor_line.checked_sub(1)?).ok()?;
    (cursor_index < edited_len.max(1)).then_some(cursor_index)
}

fn find_change_at_cursor(
    blocks: &[Block],
    cursor_index: usize,
) -> Option<(Range<usize>, Range<usize>)> {
    blocks.iter().find_map(|block| match block {
        Block::Change { old, new } if span_touches_cursor(new, cursor_index) => {
            Some((old.clone(), new.clone()))
        }
        _ => None,
    })
}

fn span_touches_cursor(new_span: &Range<usize>, cursor_index: usize) -> bool {
    if new_span.is_empty() {
        cursor_index == new_span.start || cursor_index.saturating_add(1) == new_span.start
    } else {
        cursor_index >= new_span.start && cursor_index < new_span.end
    }
}

/// Returns `(old_span, new_span)` widened onto an adjacent line when
/// `old_span` is empty, or `None` when `head_len` has no line to anchor to.
///
/// Called by `create_suggestion_from_edit` because GitHub suggestions must
/// replace at least one existing head line.
fn anchorable_spans(
    old_span: Range<usize>,
    new_span: Range<usize>,
    head_len: usize,
    edited_len: usize,
) -> Option<(Range<usize>, Range<usize>)> {
    if !old_span.is_empty() {
        return Some((old_span, new_span));
    }
    if old_span.start < head_len && new_span.end < edited_len {
        Some((
            old_span.start..old_span.start + 1,
            new_span.start..new_span.end + 1,
        ))
    } else if old_span.start > 0 && new_span.start > 0 {
        Some((
            old_span.start - 1..old_span.start,
            new_span.start - 1..new_span.end,
        ))
    } else {
        None
    }
}

fn longest_backtick_run(lines: &[&str]) -> usize {
    let mut max_run = 0;
    for line in lines {
        let mut current_run = 0;
        for byte in line.bytes() {
            if byte == b'`' {
                current_run += 1;
                max_run = max_run.max(current_run);
            } else {
                current_run = 0;
            }
        }
    }
    max_run
}

fn build_suggestion_fence(lines: &[&str]) -> String {
    let fence_len = longest_backtick_run(lines).saturating_add(1).max(3);
    let fence_marker = "`".repeat(fence_len);
    let mut fence = format!("{fence_marker}suggestion\n");
    for line in lines {
        fence.push_str(line);
        fence.push('\n');
    }
    fence.push_str(&fence_marker);
    fence
}

fn build_reverted_text(
    head_lines: &[&str],
    edited_lines: &[&str],
    old_span: Range<usize>,
    new_span: Range<usize>,
    has_trailing_newline: bool,
) -> String {
    let mut combined: Vec<&str> = Vec::new();
    combined.extend_from_slice(&edited_lines[..new_span.start]);
    combined.extend_from_slice(&head_lines[old_span]);
    combined.extend_from_slice(&edited_lines[new_span.end..]);
    if combined.is_empty() {
        return String::new();
    }
    let mut text = combined.join("\n");
    if has_trailing_newline {
        text.push('\n');
    }
    text
}

#[cfg(test)]
mod tests {
    use review_model::{AnchorKind, Side};

    use super::*;

    #[test]
    fn a_replaced_line_becomes_a_single_line_suggestion_and_reverts_only_that_hunk() {
        let head = "fn a() {\n    let count = 1;\n}\nfn b() {\n    let other = 2;\n}\n";
        let edited = "fn a() {\n    let count = 10;\n    let step = 1;\n}\nfn b() {\n    let other = 99;\n}\n";
        let result = create_suggestion_from_edit("src/a.rs", head, edited, 3).unwrap();
        assert_eq!(result.anchor.kind, AnchorKind::Line);
        assert_eq!(result.anchor.side, Side::Right);
        assert_eq!((result.anchor.start, result.anchor.end), (Some(2), Some(2)));
        assert_eq!(
            result.suggestion_body,
            "```suggestion\n    let count = 10;\n    let step = 1;\n```"
        );
        assert_eq!(
            result.reverted_text,
            "fn a() {\n    let count = 1;\n}\nfn b() {\n    let other = 99;\n}\n"
        );
    }

    #[test]
    fn a_pure_insertion_anchors_to_an_adjacent_head_line_so_github_accepts_it() {
        let head = "one\ntwo\n";
        let edited = "one\ninserted\ntwo\n";
        let result = create_suggestion_from_edit("a.txt", head, edited, 2).unwrap();
        assert_eq!((result.anchor.start, result.anchor.end), (Some(2), Some(2)));
        assert_eq!(result.suggestion_body, "```suggestion\ninserted\ntwo\n```");
        assert_eq!(result.reverted_text, "one\ntwo\n");
    }

    #[test]
    fn a_pure_insertion_at_the_start_of_the_file_anchors_to_line_one() {
        let head = "one\ntwo\n";
        let edited = "zero\none\ntwo\n";
        let result = create_suggestion_from_edit("a.txt", head, edited, 1).unwrap();
        assert_eq!((result.anchor.start, result.anchor.end), (Some(1), Some(1)));
        assert_eq!(result.suggestion_body, "```suggestion\nzero\none\n```");
        assert_eq!(result.reverted_text, "one\ntwo\n");
    }

    #[test]
    fn a_pure_insertion_at_the_end_of_the_file_anchors_to_the_last_head_line() {
        let head = "one\ntwo\n";
        let edited = "one\ntwo\nthree\n";
        let result = create_suggestion_from_edit("a.txt", head, edited, 3).unwrap();
        assert_eq!((result.anchor.start, result.anchor.end), (Some(2), Some(2)));
        assert_eq!(result.suggestion_body, "```suggestion\ntwo\nthree\n```");
        assert_eq!(result.reverted_text, "one\ntwo\n");
    }

    #[test]
    fn a_pure_deletion_builds_an_empty_suggestion_and_restores_deleted_lines() {
        let head = "one\ntwo\nthree\n";
        let edited = "one\nthree\n";
        let result = create_suggestion_from_edit("a.txt", head, edited, 2).unwrap();
        assert_eq!(result.anchor.kind, AnchorKind::Line);
        assert_eq!((result.anchor.start, result.anchor.end), (Some(2), Some(2)));
        assert_eq!(result.suggestion_body, "```suggestion\n```");
        assert_eq!(result.reverted_text, "one\ntwo\nthree\n");
    }

    #[test]
    fn a_pure_deletion_of_every_line_anchors_all_head_lines_with_an_empty_suggestion() {
        let head = "one\ntwo\n";
        let edited = "";
        let result = create_suggestion_from_edit("a.txt", head, edited, 1).unwrap();
        assert_eq!(result.anchor.kind, AnchorKind::Range);
        assert_eq!((result.anchor.start, result.anchor.end), (Some(1), Some(2)));
        assert_eq!(result.suggestion_body, "```suggestion\n```");
        assert_eq!(result.reverted_text, "one\ntwo\n");
    }

    #[test]
    fn an_unedited_cursor_line_returns_none() {
        let head = "one\ntwo\nthree\n";
        let edited = "one\ntwo\nTHREE\n";
        assert!(create_suggestion_from_edit("a.txt", head, edited, 1).is_none());
    }

    #[test]
    fn an_empty_head_file_returns_none() {
        assert!(create_suggestion_from_edit("a.txt", "", "one\n", 1).is_none());
    }

    #[test]
    fn a_line_with_triple_backticks_uses_a_longer_suggestion_fence() {
        let head = "```rust\nlet x = 1;\n```\n";
        let edited = "```rust\nlet x = 2;\n```\n";
        let result = create_suggestion_from_edit("README.md", head, edited, 2).unwrap();
        assert_eq!(result.suggestion_body, "```suggestion\nlet x = 2;\n```");

        let head_fence = "before\n```\nafter\n";
        let edited_fence = "before\n```rust\nafter\n";
        let result_fence =
            create_suggestion_from_edit("README.md", head_fence, edited_fence, 2).unwrap();
        assert_eq!(
            result_fence.suggestion_body,
            "````suggestion\n```rust\n````"
        );
    }

    #[test]
    fn out_of_range_cursor_lines_return_none() {
        let head = "one\ntwo\n";
        let edited = "ONE\ntwo\n";
        assert!(create_suggestion_from_edit("a.txt", head, edited, 0).is_none());

        let deleted_end = "one\n";
        assert!(create_suggestion_from_edit("a.txt", head, deleted_end, 2).is_none());
    }

    #[test]
    fn reverting_a_non_eof_hunk_preserves_the_edited_files_trailing_newline() {
        let head = "one\ntwo\n";
        let edited = "ONE\ntwo";
        let result = create_suggestion_from_edit("a.txt", head, edited, 1).unwrap();
        assert_eq!(result.reverted_text, "one\ntwo");
    }
}
