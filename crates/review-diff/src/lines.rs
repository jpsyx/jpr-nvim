//! The line diff between two files as blocks of equal and changed lines, and
//! the pairing of a changed block's lines for word highlights.

use std::ops::Range;
use std::time::{Duration, Instant};

use review_model::WordRange;
use similar::{Algorithm, DiffOp, DiffTag, capture_diff_slices_deadline};

use crate::words::create_word_ranges_from_lines;

/// How long one file's line diff may search for the best answer before it
/// settles for a good one, so a huge or pathological file cannot stall the
/// engine.
const DIFF_DEADLINE: Duration = Duration::from_secs(2);

/// A run of lines that is either the same on both sides or changed, as
/// 0-based line indexes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Block {
    /// The same lines on both sides.
    Equal {
        old: Range<usize>,
        new: Range<usize>,
    },
    /// Lines `old` of the old file became lines `new` of the new file; either
    /// side may be empty.
    Change {
        old: Range<usize>,
        new: Range<usize>,
    },
}

/// The line diff of `old` against `new`.
#[must_use]
pub fn create_diff_operations_from_lines(old: &[&str], new: &[&str]) -> Vec<DiffOp> {
    capture_diff_slices_deadline(
        Algorithm::Histogram,
        old,
        new,
        Some(Instant::now() + DIFF_DEADLINE),
    )
}

/// `diff_operations` as blocks, with neighbouring changes merged into one.
#[must_use]
pub fn diff_operations_to_blocks(diff_operations: &[DiffOp]) -> Vec<Block> {
    let mut blocks: Vec<Block> = Vec::new();
    for diff_operation in diff_operations {
        let (tag, old, new) = diff_operation.as_tag_tuple();
        if tag == DiffTag::Equal {
            blocks.push(Block::Equal { old, new });
            continue;
        }
        match blocks.last_mut() {
            Some(Block::Change {
                old: last_old,
                new: last_new,
            }) => {
                last_old.end = old.end;
                last_new.end = new.end;
            }
            _ => blocks.push(Block::Change { old, new }),
        }
    }
    blocks
}

/// One line of a changed block, with the words that changed in it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangedLine<'a> {
    /// The line's 0-based index on its side.
    pub index: usize,
    /// The line's text.
    pub text: &'a str,
    /// The words that changed, against the line it pairs with.
    pub words: Vec<WordRange>,
}

/// The removed and the added lines of a change of `old[old_span]` into
/// `new[new_span]`. The n-th removed line pairs with the n-th added line,
/// and a pair gets word highlights when its two lines are similar.
#[must_use]
pub fn create_changed_lines_from_spans<'a>(
    old: &[&'a str],
    old_span: Range<usize>,
    new: &[&'a str],
    new_span: Range<usize>,
) -> (Vec<ChangedLine<'a>>, Vec<ChangedLine<'a>>) {
    let create_lines_in_span = |lines: &[&'a str], span: Range<usize>| -> Vec<ChangedLine<'a>> {
        span.map(|index| ChangedLine {
            index,
            text: lines[index],
            words: Vec::new(),
        })
        .collect()
    };
    let mut removed = create_lines_in_span(old, old_span);
    let mut added = create_lines_in_span(new, new_span);
    for (removed_line, added_line) in removed.iter_mut().zip(added.iter_mut()) {
        if let Some((old_words, new_words)) =
            create_word_ranges_from_lines(removed_line.text, added_line.text)
        {
            removed_line.words = old_words;
            added_line.words = new_words;
        }
    }
    (removed, added)
}

/// A 0-based line index as a 1-based line number.
#[must_use]
pub fn line_index_to_number(index: usize) -> u64 {
    u64::try_from(index).map_or(u64::MAX, |index| index.saturating_add(1))
}

#[cfg(test)]
mod tests {
    use review_model::WordRange;
    use similar::DiffOp;

    use super::*;

    #[test]
    fn neighbouring_changes_merge_into_one_block() {
        let diff_operations = vec![
            DiffOp::Equal {
                old_index: 0,
                new_index: 0,
                len: 1,
            },
            DiffOp::Delete {
                old_index: 1,
                old_len: 1,
                new_index: 1,
            },
            DiffOp::Insert {
                old_index: 2,
                new_index: 1,
                new_len: 2,
            },
            DiffOp::Equal {
                old_index: 2,
                new_index: 3,
                len: 1,
            },
        ];
        assert_eq!(
            diff_operations_to_blocks(&diff_operations),
            [
                Block::Equal {
                    old: 0..1,
                    new: 0..1
                },
                Block::Change {
                    old: 1..2,
                    new: 1..3
                },
                Block::Equal {
                    old: 2..3,
                    new: 3..4
                },
            ]
        );
    }

    #[test]
    fn diff_operations_find_an_edited_line() {
        let old = ["a", "b", "c"];
        let new = ["a", "B", "c"];
        assert_eq!(
            diff_operations_to_blocks(&create_diff_operations_from_lines(&old, &new)),
            [
                Block::Equal {
                    old: 0..1,
                    new: 0..1
                },
                Block::Change {
                    old: 1..2,
                    new: 1..2
                },
                Block::Equal {
                    old: 2..3,
                    new: 2..3
                },
            ]
        );
    }

    #[test]
    fn changed_lines_pair_up_for_word_highlights() {
        let old = ["let x = 1;", "gone"];
        let new = ["let x = 2;"];
        let (removed, added) = create_changed_lines_from_spans(&old, 0..2, &new, 0..1);
        assert_eq!(removed[0].words, [WordRange { start: 8, end: 9 }]);
        assert!(
            removed[1].words.is_empty(),
            "an unpaired line has no word highlights"
        );
        assert_eq!(added[0].words, [WordRange { start: 8, end: 9 }]);
        assert_eq!((removed[1].index, added[0].index), (1, 0));
    }

    #[test]
    fn line_numbers_count_from_one() {
        assert_eq!(line_index_to_number(0), 1);
        assert_eq!(line_index_to_number(41), 42);
    }
}
