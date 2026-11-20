//! The stream: every changed file's hunks as rows, laid out unified or split.

use std::ops::Range;

use review_model::{
    ChangedFile, LineCell, LineChange, StreamRow, StreamView, ViewMode, ViewedState, WordRange,
};
use similar::group_diff_ops;

use crate::lines::{
    Block, ChangedLine, create_changed_lines_from_spans, create_diff_operations_from_lines,
    diff_operations_to_blocks, line_index_to_number,
};
use crate::text::FileText;

/// Unchanged lines shown around each change, as on GitHub.
pub const CONTEXT_LINES: usize = 3;

/// One changed file for the stream: what the forge reports about it, and its
/// two sides, or why they could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamInput {
    /// The file as the forge reports it.
    pub file: ChangedFile,
    /// The base and the current text, or why they could not be read.
    pub content: Result<(FileText, FileText), String>,
}

/// Every file of `inputs`, in order, laid out for `mode`.
#[must_use]
pub fn create_stream_view_from_inputs(inputs: &[StreamInput], mode: ViewMode) -> StreamView {
    let rows = inputs
        .iter()
        .flat_map(|input| create_file_rows_from_input(input, mode))
        .collect();
    StreamView { mode, rows }
}

/// One file's rows: its header, then its hunks or a note saying why it has
/// none.
fn create_file_rows_from_input(input: &StreamInput, mode: ViewMode) -> Vec<StreamRow> {
    let file = &input.file;
    let mut rows = vec![StreamRow::File {
        path: file.path.clone(),
        additions: file.additions,
        deletions: file.deletions,
        viewed: file.viewed,
        folded: file.viewed == ViewedState::Viewed,
    }];
    let create_note_row = |text: String| StreamRow::Note {
        path: file.path.clone(),
        text,
    };
    match &input.content {
        Err(message) => rows.push(create_note_row(format!(
            "could not read this file: {message}"
        ))),
        Ok((base, current)) if base.is_binary() || current.is_binary() => {
            rows.push(create_note_row("binary file".to_owned()));
        }
        Ok((base, current)) => {
            let writer = HunkWriter {
                path: &file.path,
                old: base.lines(),
                new: current.lines(),
                mode,
            };
            let hunks = writer.to_rows();
            if hunks.is_empty() {
                rows.push(create_note_row("no changes against the base".to_owned()));
            }
            rows.extend(hunks);
        }
    }
    rows
}

/// Writes one text file's hunks as rows.
struct HunkWriter<'a> {
    path: &'a str,
    old: Vec<&'a str>,
    new: Vec<&'a str>,
    mode: ViewMode,
}

impl HunkWriter<'_> {
    fn to_rows(&self) -> Vec<StreamRow> {
        let mut rows = Vec::new();
        for group in group_diff_ops(
            create_diff_operations_from_lines(&self.old, &self.new),
            CONTEXT_LINES,
        ) {
            let (Some(first_operation), Some(last_operation)) = (group.first(), group.last())
            else {
                continue;
            };
            let old_span = first_operation.old_range().start..last_operation.old_range().end;
            let new_span = first_operation.new_range().start..last_operation.new_range().end;
            rows.push(StreamRow::Hunk {
                path: self.path.to_owned(),
                header: build_hunk_header_from_spans(&old_span, &new_span),
                target: self.index_to_target(new_span.start),
            });
            for block in diff_operations_to_blocks(&group) {
                match block {
                    Block::Equal { old, new } => self.push_context(&mut rows, old, new),
                    Block::Change { old, new } => self.push_change(&mut rows, old, new),
                }
            }
        }
        rows
    }

    fn push_context(&self, rows: &mut Vec<StreamRow>, old: Range<usize>, new: Range<usize>) {
        for (old_index, new_index) in old.zip(new) {
            let left_cell = create_line_cell(
                old_index,
                self.old[old_index],
                LineChange::Context,
                Vec::new(),
            );
            let right_cell = create_line_cell(
                new_index,
                self.new[new_index],
                LineChange::Context,
                Vec::new(),
            );
            rows.push(self.create_line_row(
                Some(left_cell),
                Some(right_cell),
                line_index_to_number(new_index),
            ));
        }
    }

    fn push_change(&self, rows: &mut Vec<StreamRow>, old: Range<usize>, new: Range<usize>) {
        let target = self.index_to_target(new.start);
        let (removed, added) = create_changed_lines_from_spans(&self.old, old, &self.new, new);
        let removed: Vec<LineCell> = removed
            .into_iter()
            .map(|line| changed_line_to_cell(line, LineChange::Removed))
            .collect();
        let added: Vec<LineCell> = added
            .into_iter()
            .map(|line| changed_line_to_cell(line, LineChange::Added))
            .collect();
        match self.mode {
            ViewMode::Unified => {
                rows.extend(
                    removed
                        .into_iter()
                        .map(|removed_cell| self.create_line_row(Some(removed_cell), None, target)),
                );
                rows.extend(added.into_iter().map(|added_cell| {
                    let line = added_cell.line;
                    self.create_line_row(None, Some(added_cell), line)
                }));
            }
            ViewMode::Split => {
                for index in 0..removed.len().max(added.len()) {
                    let right = added.get(index).cloned();
                    let row_target = right.as_ref().map_or(target, |cell| cell.line);
                    rows.push(self.create_line_row(removed.get(index).cloned(), right, row_target));
                }
            }
        }
    }

    fn create_line_row(
        &self,
        left: Option<LineCell>,
        right: Option<LineCell>,
        target: u64,
    ) -> StreamRow {
        StreamRow::Line {
            path: self.path.to_owned(),
            left,
            right,
            target,
        }
    }

    /// The new-side line a row at new index `index` jumps to: that line, or
    /// the last line when the change sits past the end of the file.
    fn index_to_target(&self, index: usize) -> u64 {
        line_index_to_number(index.min(self.new.len().saturating_sub(1)))
    }
}

fn create_line_cell(
    index: usize,
    text: &str,
    change: LineChange,
    words: Vec<WordRange>,
) -> LineCell {
    LineCell {
        line: line_index_to_number(index),
        text: text.to_owned(),
        change,
        words,
    }
}

fn changed_line_to_cell(line: ChangedLine<'_>, change: LineChange) -> LineCell {
    create_line_cell(line.index, line.text, change, line.words)
}

/// The `@@ -a,b +c,d @@` header of a hunk spanning `old` and `new`.
fn build_hunk_header_from_spans(old: &Range<usize>, new: &Range<usize>) -> String {
    format!(
        "@@ -{} +{} @@",
        span_to_range_label(old),
        span_to_range_label(new)
    )
}

/// `start,count` with a 1-based start, or git's `n,0` for an empty side,
/// where `n` is the line before it.
fn span_to_range_label(span: &Range<usize>) -> String {
    if span.is_empty() {
        format!("{},0", span.start)
    } else {
        format!("{},{}", span.start + 1, span.len())
    }
}

#[cfg(test)]
mod tests;
