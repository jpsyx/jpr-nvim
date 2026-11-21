use serde::{Deserialize, Serialize};

/// Which side of the diff a thread is anchored to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum Side {
    /// The old file.
    Left,
    /// The new file.
    Right,
}

impl Side {
    /// Parses `"LEFT"` or `"RIGHT"`, returning `None` for any other string,
    /// for example when decoding diff sides from GraphQL or RPC payloads.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "LEFT" => Some(Self::Left),
            "RIGHT" => Some(Self::Right),
            _ => None,
        }
    }

    /// Returns `"LEFT"` or `"RIGHT"`, for example when building GitHub GraphQL
    /// `DiffSide` inputs.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Left => "LEFT",
            Self::Right => "RIGHT",
        }
    }
}

/// What a thread is attached to. It decides which of an [`Anchor`]'s fields
/// are set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AnchorKind {
    /// One line of a file.
    Line,
    /// A run of lines of a file, from `start` to `end`.
    Range,
    /// A whole file, with no line.
    File,
    /// The pull request as a whole, with no file.
    Pr,
}

impl AnchorKind {
    /// Parses `"line"`, `"range"`, `"file"`, or `"pr"`, returning `None` for
    /// any other string, for example when reading anchor kinds from RPC params.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "line" => Some(Self::Line),
            "range" => Some(Self::Range),
            "file" => Some(Self::File),
            "pr" => Some(Self::Pr),
            _ => None,
        }
    }
}

/// Where a thread is attached. A frontend uses it to place the thread in the
/// diff, and the snapshot lets a thread whose lines moved find them again.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Anchor {
    /// The file, for every kind but `pr`.
    pub file: Option<String>,
    /// What the thread is attached to.
    pub kind: AnchorKind,
    /// Which side of the diff the lines are on.
    pub side: Side,
    /// The first line, for `line` and `range`.
    pub start: Option<u64>,
    /// The last line, for `line` and `range`.
    pub end: Option<u64>,
    /// The commit the line numbers refer to, when known.
    pub commit: Option<String>,
    /// The anchored code, used to re-anchor a thread whose lines moved.
    pub snapshot: Option<String>,
}

impl Anchor {
    /// A single line on the new side of `file`, with no commit or snapshot.
    /// Use it to anchor a thread to one line, for example in a test fixture.
    #[must_use]
    pub fn line(file: &str, line: u64) -> Self {
        Self::side_line(file, Side::Right, line)
    }

    /// A single line on `side` of `file`, with no commit or snapshot.
    /// Use it when composing a comment on either diff side, for example on a
    /// deleted base line.
    #[must_use]
    pub fn side_line(file: &str, side: Side, line: u64) -> Self {
        Self {
            file: Some(file.to_owned()),
            kind: AnchorKind::Line,
            side,
            start: Some(line),
            end: Some(line),
            commit: None,
            snapshot: None,
        }
    }

    /// Inclusive line span `start..=end` on `side` of `file` with no commit or
    /// snapshot, ordering reversed bounds and collapsing equal lines to
    /// [`AnchorKind::Line`]. Use it for visual-selection comments or suggested
    /// edits, for example across a multi-line hunk.
    #[must_use]
    pub fn range(file: &str, side: Side, start: u64, end: u64) -> Self {
        let (first_line, last_line) = if start <= end {
            (start, end)
        } else {
            (end, start)
        };
        Self {
            file: Some(file.to_owned()),
            kind: if first_line == last_line {
                AnchorKind::Line
            } else {
                AnchorKind::Range
            },
            side,
            start: Some(first_line),
            end: Some(last_line),
            commit: None,
            snapshot: None,
        }
    }

    /// A file-level anchor on `file` with no line numbers, commit, or snapshot.
    /// Use it for whole-file comments, for example on a binary or renamed file.
    #[must_use]
    pub fn file(file: &str) -> Self {
        Self {
            file: Some(file.to_owned()),
            kind: AnchorKind::File,
            side: Side::Right,
            start: None,
            end: None,
            commit: None,
            snapshot: None,
        }
    }

    /// A pull-request conversation anchor with no file, lines, commit, or
    /// snapshot. Use it for top-level pull-request discussion comments, for
    /// example in a conversation view.
    #[must_use]
    pub const fn pr() -> Self {
        Self {
            file: None,
            kind: AnchorKind::Pr,
            side: Side::Right,
            start: None,
            end: None,
            commit: None,
            snapshot: None,
        }
    }
}
