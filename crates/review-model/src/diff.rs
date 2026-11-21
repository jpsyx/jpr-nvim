//! The diff read models: what a frontend draws for one changed file and for
//! the stream of every changed file. Their JSON shape is the wire format in
//! docs/protocol.md.

use serde::{Deserialize, Serialize};

use crate::ViewedState;

/// How a frontend lays a change out. The reviewer picks one, and the stream
/// is built for it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ViewMode {
    /// One column: removed lines above the added lines that replace them.
    #[default]
    Unified,
    /// Two columns: the old file on the left, the new file on the right.
    Split,
}

impl ViewMode {
    /// Parses `unified` or `split`, as a request or a frontend spells it.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "unified" => Some(Self::Unified),
            "split" => Some(Self::Split),
            _ => None,
        }
    }
}

/// A byte range of a line's text that changed, so a frontend can highlight
/// the words that changed inside an edited line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct WordRange {
    /// The first byte that changed.
    pub start: usize,
    /// One past the last byte that changed.
    pub end: usize,
}

/// What happened to one line, so a frontend picks its color and sign.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LineChange {
    /// Unchanged, shown around a change.
    Context,
    /// Only in the new file.
    Added,
    /// Only in the old file.
    Removed,
}

/// One side's line in a stream row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LineCell {
    /// The line number on its side, from 1.
    pub line: u64,
    /// The line's text, without its line ending.
    pub text: String,
    /// What happened to the line.
    pub change: LineChange,
    /// The words that changed, when the line was edited rather than replaced.
    pub words: Vec<WordRange>,
}

/// One row of the stream. Rows come in display order: each file's header,
/// then its hunks and their lines.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum StreamRow {
    /// A file's header.
    File {
        /// The file's path from the repository root.
        path: String,
        /// Lines the pull request adds, as the forge counts them.
        additions: u64,
        /// Lines the pull request removes, as the forge counts them.
        deletions: u64,
        /// Whether the reviewer has viewed the file.
        viewed: ViewedState,
        /// Whether a frontend should start with the file's rows folded away.
        folded: bool,
    },
    /// A hunk's header, such as `@@ -10,6 +10,8 @@`.
    Hunk {
        /// The file the hunk belongs to.
        path: String,
        /// The header text.
        header: String,
        /// The new-side line a frontend jumps to from this row.
        target: u64,
    },
    /// A line of a hunk. In unified mode one side is set (both, for
    /// context); in split mode a missing side is filler that keeps the two
    /// columns aligned.
    Line {
        /// The file the line belongs to.
        path: String,
        /// The old file's line.
        left: Option<LineCell>,
        /// The new file's line.
        right: Option<LineCell>,
        /// The new-side line a frontend jumps to from this row.
        target: u64,
        /// Review threads anchored to this line.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        threads: Vec<crate::ThreadPreview>,
    },
    /// A file-level or unplaced thread banner shown beneath the file header.
    Thread {
        /// The file the thread belongs to.
        path: String,
        /// The thread preview to render.
        thread: crate::ThreadPreview,
        /// The current-file line a frontend jumps to from this row.
        target: u64,
    },
    /// A message in place of the lines, such as for a binary file.
    Note {
        /// The file the note is about.
        path: String,
        /// The message, for a person to read.
        text: String,
    },
}

impl StreamRow {
    /// The file this row belongs to.
    #[must_use]
    pub fn path(&self) -> &str {
        match self {
            Self::File { path, .. }
            | Self::Hunk { path, .. }
            | Self::Line { path, .. }
            | Self::Thread { path, .. }
            | Self::Note { path, .. } => path,
        }
    }
}

/// Every changed file as one scrolling view, like the forge's Files tab.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamView {
    /// The layout the rows were built for.
    pub mode: ViewMode,
    /// The rows, in display order.
    pub rows: Vec<StreamRow>,
}

/// A line the change added, for a frontend that marks it in the file itself.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AddedLine {
    /// The line number in the current file, from 1.
    pub line: u64,
    /// The words that changed, when the line was edited rather than replaced.
    pub words: Vec<WordRange>,
}

/// A line the change removed, drawn where it used to be.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemovedLine {
    /// The removed line's text, without its line ending.
    pub text: String,
    /// The words that changed, when the line was edited rather than replaced.
    pub words: Vec<WordRange>,
}

/// Removed lines that sat together, drawn above one line of the current file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemovedBlock {
    /// The current file's line (from 1) the block sits above; one past the
    /// last line means after the end of the file.
    pub above: u64,
    /// The removed lines, in order.
    pub lines: Vec<RemovedLine>,
}

/// One changed file's diff against its base, for a frontend that draws it on
/// the file itself (unified) or beside the base (split).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileDiffView {
    /// The file's path from the repository root.
    pub path: String,
    /// Either side is binary, so there are no lines to show.
    pub binary: bool,
    /// The file at the base, for a split view; `None` for an added or binary file.
    pub base_text: Option<String>,
    /// The lines the change added, in order.
    pub added: Vec<AddedLine>,
    /// The lines the change removed, in blocks, in order.
    pub removed: Vec<RemovedBlock>,
    /// Review threads anchored on this file.
    #[serde(default)]
    pub threads: Vec<crate::ThreadPreview>,
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::ViewedState;

    #[test]
    fn view_modes_parse_and_serialize_in_lowercase() {
        assert_eq!(ViewMode::parse("split"), Some(ViewMode::Split));
        assert_eq!(ViewMode::parse("unified"), Some(ViewMode::Unified));
        assert_eq!(ViewMode::parse("Split"), None);
        assert_eq!(
            serde_json::to_value(ViewMode::Split).unwrap(),
            json!("split")
        );
        assert_eq!(ViewMode::default(), ViewMode::Unified);
    }

    #[test]
    fn stream_rows_are_tagged_by_kind_with_camel_case_fields() {
        let row = StreamRow::Line {
            path: "a.rs".into(),
            left: None,
            right: Some(LineCell {
                line: 3,
                text: "let x = 2;".into(),
                change: LineChange::Added,
                words: vec![WordRange { start: 8, end: 9 }],
            }),
            target: 3,
            threads: Vec::new(),
        };
        assert_eq!(
            serde_json::to_value(&row).unwrap(),
            json!({
                "kind": "line", "path": "a.rs", "left": null,
                "right": { "line": 3, "text": "let x = 2;", "change": "added", "words": [{ "start": 8, "end": 9 }] },
                "target": 3
            })
        );
        let header = StreamRow::File {
            path: "a.rs".into(),
            additions: 1,
            deletions: 2,
            viewed: ViewedState::Dismissed,
            folded: false,
        };
        assert_eq!(serde_json::to_value(&header).unwrap()["kind"], "file");
        assert_eq!(header.path(), "a.rs");
    }

    #[test]
    fn a_file_diff_view_uses_camel_case_keys() {
        let view = FileDiffView {
            path: "a.rs".into(),
            binary: false,
            base_text: Some("old\n".into()),
            added: vec![AddedLine {
                line: 1,
                words: vec![],
            }],
            removed: vec![RemovedBlock {
                above: 1,
                lines: vec![RemovedLine {
                    text: "old".into(),
                    words: vec![],
                }],
            }],
            threads: Vec::new(),
        };
        let json = serde_json::to_value(&view).unwrap();
        assert_eq!(json["baseText"], "old\n");
        assert_eq!(json["removed"][0]["above"], 1);
        assert_eq!(json["added"][0]["line"], 1);
        assert_eq!(json["binary"], false);
    }
}
