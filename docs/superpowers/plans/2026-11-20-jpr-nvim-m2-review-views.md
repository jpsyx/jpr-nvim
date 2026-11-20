# jpr-nvim Milestone 2 (Review views) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show every file a pull request changes as a GitHub-style diff in Neovim (unified overlays or a native split, flipped with one key and remembered), add the stream of every change beside a file-tree panel, and sync the viewed state both ways, including GitHub's DISMISSED reset.

**Architecture:** A new generic crate, `review-diff`, turns two texts into frontend-neutral read models: `FileDiffView` for one file and `StreamView` for all of them. `ReviewSession` gains a `Workspace` port (git: merge base, base contents, disk contents, renames) and three use cases: `file_diff`, `stream` and `set_viewed`, with a persisted queue for viewed marks GitHub refused. Protocol version 2 exposes them as `fileDiff`, `stream` and `setViewed`. The Lua plugin only draws: extmarks for unified, Neovim's `diff` mode for split, and one or two scroll-bound buffers for the stream. Spec: milestone 2 of `docs/superpowers/specs/2026-11-19-jpr-nvim-design.md`.

**Tech Stack:** Rust 2024 (`similar` 3 for line and word diffs, plus anyhow, serde, serde_json; threads, no async runtime), git, the GitHub CLI (`gh`), Neovim 0.11+ Lua (headless `nvim -l` specs).

**Verified while planning:** the code of Tasks 1 to 5 (`review-model` diff types and `review-diff`) passed its tests, clippy and rustfmt in a scratch clone, and the Lua of Tasks 17 to 22, applied together, passed every Lua spec there. Tasks 6 to 16 (engine wiring, store, git, RPC) were written against the current code but not compiled: expect small fixes.

---

## Scope

| In this milestone | Where in the spec |
| --- | --- |
| Changed files open as diffs: unified extmark overlays, split `diff` mode with a read-only `jpr://base/...` buffer | "Changed files open as diffs" |
| `:Jpr toggle` flips the view globally and remembers it | Requirements: Views |
| The stream (`jpr://stream/<n>`): file headers, hunks, viewed files folded, split mode as two scroll-bound buffers, `<CR>`, `v`, `]f` `[f` `]h` `[h` | "Stream" |
| `:Jpr stream` | "Commands" |
| The panel as a file tree, `v` to toggle viewed, a count of viewed marks waiting for GitHub | "PR tab" |
| Viewed sync: mark and unmark immediately, queue a refused mark, retry every 20 seconds and at every sync, let a queued mark win over a pull, DISMISSED shown and unfolded | "GitHub sync" |

| Deferred | To | Why |
| --- | --- | --- |
| Thread markers in the stream, `]t` / `[t`, file-level threads under headers | Milestone 3 | They are how comments are drawn, which is milestone 3's subject |
| ✎ locally modified, `dirty · ↑2 ↓0` | Milestone 5 | Part of `:Jpr push` status |
| Watching the worktree for edits made outside Neovim | Milestone 4 | Arrives with agent edits; until then a save in Neovim refreshes the diffs |
| Fast-forwarding the worktree when the head moves | Later | Not part of review views |

## Ground rules for every task

- Work in a worktree on branch `feat/review-views` (Task 0). Commit after every task. Do not push, merge or open a PR.
- Run commands from the worktree root unless a step says otherwise.
- `just check` must pass at the end of every task (format, clippy with `-D warnings`, the Rust tests, the Lua specs). If clippy (pedantic + nursery) flags code from this plan, fix the lint without changing behavior and say so in the commit message.
- **The dependency rule:** nothing in `crates/review-*` may depend on Neovim, Lua, a terminal UI library, or `jpr-review`. `crates/jpr-review/tests/dependency_rule.rs` enforces it; `similar` is a plain diff library and passes.
- Functions stay within 45 lines (`CLAUDE.md`), in Rust and in Lua.
- Every public Rust item gets a `///` doc comment that says what it is for (see `docs/rules/rust.md`).
- **High-risk tasks** (persistence formats, and reading files a pull request names): Task 6 (`session.json` v2), Task 7 (`github.json`) and Task 9 (`GitWorkspace`). Each gets a task-level review after its unit reviews.
- `docs/` is part of done: each task that changes a documented shape updates its doc in the same commit; Task 23 rewrites what is left.

## File map

| Path | Responsibility |
| --- | --- |
| `Cargo.toml` | Adds `similar` and `review-diff` to the workspace dependencies; version 0.2.0 (Task 23) |
| `crates/review-model/src/diff.rs` | New: the diff read models (`ViewMode`, `WordRange`, `LineCell`, `StreamRow`, `StreamView`, `FileDiffView` and its parts) |
| `crates/review-model/src/pr.rs` | `PullRequest.base_sha` |
| `crates/review-model/src/view.rs` | `SessionView.tree`, `SessionView.queued_count`, `TreeRow`, `Event::ViewedChanged` |
| `crates/review-diff/` | New crate: `text.rs` (`FileText`), `words.rs` (changed words), `lines.rs` (line diff blocks, line pairing), `overlay.rs` (`file_diff_view`), `stream.rs` (`stream_view`) |
| `crates/review-core/src/ports.rs` | `Workspace` port, `Ports`, `SyncRegistry`, `Forge::set_viewed` |
| `crates/review-core/src/fakes.rs` | `FakeWorkspace`, `fake_ports`, viewed writes on `FakeForge` |
| `crates/review-core/src/contract.rs` | The store contract covers the registry and `base_sha` |
| `crates/review-core/src/session/` | Replaces `session.rs`: `mod.rs` (state), `sync.rs`, `diffs.rs`, `viewed.rs`, `test_support.rs` |
| `crates/review-core/src/viewed.rs` | Pure viewed rules (`viewed_state`, `apply_queued`) |
| `crates/review-core/src/tree.rs` | Pure: changed paths to `TreeRow`s |
| `crates/review-core/src/presenter.rs` | `SessionView` gains the tree and the queue count |
| `crates/review-store-fs/src/format.rs`, `src/lib.rs` | `session.json` v2 (`baseSha`), new `github.json` (the viewed queue) |
| `crates/review-forge-github/src/pr.rs`, `src/graphql.rs`, `src/lib.rs` | `baseRefOid`, the viewed mutations, `GhForge::set_viewed` |
| `crates/review-workspace-git/src/` | `process.rs` (bytes and stdin), new `git_output.rs`, `worktree_path.rs`, `workspace.rs` (`GitWorkspace`) |
| `crates/review-rpc/src/params.rs` | New: reading request params |
| `crates/review-rpc/src/server.rs`, `src/protocol.rs` | Protocol v2 methods, the retrying poller |
| `crates/jpr-review/src/commands/serve.rs` | Wires `GitWorkspace` and the retry interval |
| `lua/jpr/init.lua` | `view` option, `toggle` and `stream` subcommands, diff highlight groups |
| `lua/jpr/rpc.lua` | `PROTOCOL_VERSION = 2` |
| `lua/jpr/view_mode.lua` | New: the global, remembered view mode |
| `lua/jpr/render/overlay.lua` | New, pure: `FileDiffView` to extmarks, base text to lines |
| `lua/jpr/render/stream.lua` | New, pure: `StreamView` to columns, targets, folds and navigation |
| `lua/jpr/render/panel.lua` | The file tree and the queued count |
| `lua/jpr/views/main_window.lua` | New: the window beside the panel, and opening a file in it |
| `lua/jpr/views/diff.lua` | New: unified overlays and split base windows on file buffers |
| `lua/jpr/views/stream.lua` | New: the stream buffers, windows and keys |
| `lua/jpr/views/panel.lua` | Opens files through `main_window`; `v` toggles viewed |
| `lua/jpr/session.lua` | `request`, redraws on `viewedChanged`, `toggle_view`, `stream_current`, wiring of the new views |
| `scripts/test-lua.sh` | Runs specs with a throwaway `XDG_STATE_HOME` |
| `tests/lua/fixtures/fake_engine.sh` | Protocol 2, `fileDiff`, `stream`, `setViewed`, a request log |
| `tests/lua/*_spec.lua` | New: `view_mode`, `overlay_render`, `stream_render`, `diff_view`, `stream_view`; updated: `command`, `panel_render`, `session`, `session_lifecycle` |
| `docs/protocol.md`, `docs/architecture.md`, `docs/decisions.md`, `README.md` | Docs updated to match |

---

### Task 0: Worktree

- [ ] **Step 1: Create the worktree for `feat/review-views`**

Load the `using-wt` skill first (the user's rules require it before touching a worktree). From the main checkout:

```bash
cd "$(wt new feat review-views)"
git branch --show-current
```

Expected: `feat/review-views`.

- [ ] **Step 2: Restore the agent skills**

```bash
just skills-install
```

Expected: completes.

- [ ] **Step 3: Check the baseline**

```bash
just check
```

Expected: passes. If it does not, stop and report: the plan assumes a green `main`.

---
### Task 1: The diff read models in `review-model`

**Files:**
- Create: `crates/review-model/src/diff.rs`
- Modify: `crates/review-model/src/lib.rs`

These are the shapes every frontend draws. They are pure data; `review-diff` (Tasks 2 to 5) builds them.

- [ ] **Step 1: Write the failing tests**

Create `crates/review-model/src/diff.rs` with only the tests for now:

```rust
//! The diff read models: what a frontend draws for one changed file and for
//! the stream of every changed file. Their JSON shape is the wire format in
//! docs/protocol.md.

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
        };
        let json = serde_json::to_value(&view).unwrap();
        assert_eq!(json["baseText"], "old\n");
        assert_eq!(json["removed"][0]["above"], 1);
        assert_eq!(json["added"][0]["line"], 1);
        assert_eq!(json["binary"], false);
    }
}
```

Add the module to `crates/review-model/src/lib.rs` (after `mod pr;`):

```rust
mod diff;
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cargo test -p review-model`
Expected: FAIL to compile: `cannot find type ViewMode`, `StreamRow`, and so on.

- [ ] **Step 3: Write the types**

Put this above the `#[cfg(test)]` block in `crates/review-model/src/diff.rs`:

```rust
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
}
```

Replace the re-exports in `crates/review-model/src/lib.rs` so the file reads:

```rust
//! The review domain: pull requests, changed files, threads, and the read
//! models every frontend draws. Pure data: no IO and no frontend concepts.

mod diff;
mod pr;
mod thread;
mod view;

pub use diff::{
    AddedLine, FileDiffView, LineCell, LineChange, RemovedBlock, RemovedLine, StreamRow,
    StreamView, ViewMode, WordRange,
};
pub use pr::{ChangedFile, PullRequest, ViewedState};
pub use thread::{Anchor, AnchorKind, Message, MessageSync, Origin, Side, Thread, ThreadState};
pub use view::{Event, FileRow, SessionView, SyncState};
```

- [ ] **Step 4: Run the tests**

Run: `cargo test -p review-model`
Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-model
git commit -m "feat(model): add the diff read models"
```

---

### Task 2: The `review-diff` crate and `FileText`

**Files:**
- Modify: `Cargo.toml`
- Create: `crates/review-diff/Cargo.toml`, `crates/review-diff/src/lib.rs`, `crates/review-diff/src/text.rs`

`similar` is the one new dependency of this milestone. Task 23 records the choice in `docs/decisions.md`.

- [ ] **Step 1: Add the crate to the workspace**

In the root `Cargo.toml`, add to `[workspace.dependencies]` (after `tempfile = "3"`):

```toml
# Line and word diffs: Histogram for lines (as git), Myers for words. Only the
# slice API is used, so the text helpers stay off.
similar = { version = "3", default-features = false, features = ["std"] }
```

and, with the other path dependencies:

```toml
review-diff = { path = "crates/review-diff" }
```

Create `crates/review-diff/Cargo.toml`:

```toml
[package]
name = "review-diff"
description = "Line and word diffs between two texts, and the diff read models built from them."
version.workspace = true
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[dependencies]
review-model.workspace = true
similar.workspace = true

[lints]
workspace = true
```

Create `crates/review-diff/src/lib.rs`:

```rust
//! Diffs between two texts, and the read models frontends draw from them.
//! Pure functions: no IO and no frontend concepts.

mod text;

pub use text::FileText;
```

- [ ] **Step 2: Write the failing tests**

Create `crates/review-diff/src/text.rs` with only the tests:

```rust
//! A file's content as the diff sees it: missing, binary, or text.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_bytes_are_a_missing_file() {
        assert_eq!(FileText::from_bytes(None), FileText::Missing);
    }

    #[test]
    fn a_nul_byte_makes_a_file_binary() {
        assert!(FileText::from_bytes(Some(b"PNG\0\x01".to_vec())).is_binary());
    }

    #[test]
    fn text_keeps_its_content_and_splits_into_lines() {
        let text = FileText::from_bytes(Some(b"one\r\ntwo\nthree".to_vec()));
        assert_eq!(text.lines(), ["one", "two", "three"]);
        assert_eq!(text.as_text(), Some("one\r\ntwo\nthree"));
    }

    #[test]
    fn invalid_utf8_is_replaced_not_refused() {
        let text = FileText::from_bytes(Some(vec![b'a', 0xff, b'b']));
        assert_eq!(text.as_text(), Some("a\u{fffd}b"));
    }

    #[test]
    fn a_missing_or_binary_side_has_no_lines() {
        assert!(FileText::Missing.lines().is_empty());
        assert!(FileText::Binary.lines().is_empty());
        assert_eq!(FileText::Binary.as_text(), None);
    }
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cargo test -p review-diff`
Expected: FAIL to compile: `cannot find type FileText`.

- [ ] **Step 4: Implement `FileText`**

Put this above the tests in `crates/review-diff/src/text.rs`:

```rust
/// How many leading bytes are searched for a NUL, as git does, to call a
/// file binary.
const BINARY_PROBE_BYTES: usize = 8000;

/// One side of a file's diff: the file at the base, or on disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileText {
    /// The file does not exist on this side: it was added or deleted.
    Missing,
    /// The file holds bytes that are not text, so it has no line diff.
    Binary,
    /// The file's text. Invalid UTF-8 is replaced, not refused.
    Text(String),
}

impl FileText {
    /// Reads a file's bytes, or `None` when the file does not exist, as a
    /// workspace returns them.
    #[must_use]
    pub fn from_bytes(bytes: Option<Vec<u8>>) -> Self {
        match bytes {
            None => Self::Missing,
            Some(bytes) if bytes.iter().take(BINARY_PROBE_BYTES).any(|byte| *byte == 0) => {
                Self::Binary
            }
            Some(bytes) => Self::Text(
                String::from_utf8(bytes)
                    .unwrap_or_else(|error| String::from_utf8_lossy(error.as_bytes()).into_owned()),
            ),
        }
    }

    /// Whether this side is binary.
    #[must_use]
    pub const fn is_binary(&self) -> bool {
        matches!(self, Self::Binary)
    }

    /// The text, for a side that has some.
    #[must_use]
    pub fn as_text(&self) -> Option<&str> {
        match self {
            Self::Text(text) => Some(text),
            Self::Missing | Self::Binary => None,
        }
    }

    /// The lines without their endings (`\n` or `\r\n`); none for a missing
    /// or binary side.
    #[must_use]
    pub fn lines(&self) -> Vec<&str> {
        self.as_text()
            .map(|text| text.lines().collect())
            .unwrap_or_default()
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `cargo test -p review-diff`
Expected: PASS.

- [ ] **Step 6: Gate and commit**

```bash
just check
git add Cargo.toml Cargo.lock crates/review-diff
git commit -m "feat(diff): add the review-diff crate and FileText"
```

---

### Task 3: Changed words (`words.rs`)

**Files:**
- Create: `crates/review-diff/src/words.rs`
- Modify: `crates/review-diff/src/lib.rs`

Two lines that pair up in a change get the byte ranges of the words that changed. Tokens are runs of word characters, runs of whitespace, or single other characters, so `foo(bar)` splits at the parentheses as GitHub does.

- [ ] **Step 1: Write the failing tests**

Create `crates/review-diff/src/words.rs` with only the tests:

```rust
//! The words that changed between two versions of one line, as byte ranges.

#[cfg(test)]
mod tests {
    use super::*;

    fn ranges(pairs: &[(usize, usize)]) -> Vec<WordRange> {
        pairs
            .iter()
            .map(|&(start, end)| WordRange { start, end })
            .collect()
    }

    #[test]
    fn a_changed_number_highlights_only_the_number() {
        let (old, new) = word_ranges("let x = 1;", "let x = 2;").unwrap();
        assert_eq!(old, ranges(&[(8, 9)]));
        assert_eq!(new, ranges(&[(8, 9)]));
    }

    #[test]
    fn punctuation_splits_words() {
        let (old, new) = word_ranges("call(alpha, beta)", "call(alpha, gamma)").unwrap();
        assert_eq!(old, ranges(&[(12, 16)]));
        assert_eq!(new, ranges(&[(12, 17)]));
    }

    #[test]
    fn an_insertion_highlights_only_the_new_side() {
        let (old, new) = word_ranges("a + b", "a + b + c").unwrap();
        assert!(old.is_empty());
        assert_eq!(new, ranges(&[(5, 9)]));
    }

    #[test]
    fn lines_with_little_in_common_get_no_word_highlights() {
        assert_eq!(word_ranges("fn alpha() {}", "struct Beta;"), None);
    }

    #[test]
    fn offsets_are_bytes_in_utf8_text() {
        let (old, new) = word_ranges("café = 1", "café = 2").unwrap();
        assert_eq!(old, ranges(&[(8, 9)]));
        assert_eq!(new, ranges(&[(8, 9)]));
    }

    #[test]
    fn identical_lines_have_no_changed_words() {
        assert_eq!(word_ranges("same", "same"), Some((vec![], vec![])));
    }

    #[test]
    fn tokens_group_words_and_spaces_but_not_punctuation() {
        let texts: Vec<&str> = tokens("a_b  (c)")
            .into_iter()
            .map(|token| token.1)
            .collect();
        assert_eq!(texts, ["a_b", "  ", "(", "c", ")"]);
    }
}
```

Add to `crates/review-diff/src/lib.rs`, after `mod text;`:

```rust
// Used by the overlay and stream builders from Task 4 on; until then only its
// tests call it.
#[cfg_attr(not(test), allow(dead_code))]
mod words;
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cargo test -p review-diff`
Expected: FAIL to compile: `cannot find function word_ranges`, `tokens`, type `WordRange`.

- [ ] **Step 3: Implement it**

Put this above the tests in `crates/review-diff/src/words.rs`:

```rust
use std::ops::Range;

use review_model::WordRange;
use similar::{Algorithm, DiffTag, capture_diff_slices, diff_ratio};

/// Below this share of unchanged tokens, two lines count as replaced rather
/// than edited and get no word highlights: marking nearly every word says
/// less than marking none.
const MIN_SIMILARITY: f32 = 0.5;

/// The changed words of `old` and of `new`, or `None` when the two lines are
/// too different for word highlights to help.
#[must_use]
pub fn word_ranges(old: &str, new: &str) -> Option<(Vec<WordRange>, Vec<WordRange>)> {
    let old_tokens = tokens(old);
    let new_tokens = tokens(new);
    let old_words: Vec<&str> = old_tokens.iter().map(|token| token.1).collect();
    let new_words: Vec<&str> = new_tokens.iter().map(|token| token.1).collect();
    let ops = capture_diff_slices(Algorithm::Myers, &old_words, &new_words);
    if diff_ratio(&ops, old_words.len(), new_words.len()) < MIN_SIMILARITY {
        return None;
    }
    let mut old_ranges = Vec::new();
    let mut new_ranges = Vec::new();
    for op in &ops {
        let (tag, old_span, new_span) = op.as_tag_tuple();
        if tag != DiffTag::Equal {
            push_span(&mut old_ranges, &old_tokens, old_span);
            push_span(&mut new_ranges, &new_tokens, new_span);
        }
    }
    Some((old_ranges, new_ranges))
}

/// Adds the bytes `tokens[span]` cover to `ranges`, unless the span is empty.
fn push_span(ranges: &mut Vec<WordRange>, tokens: &[(usize, &str)], span: Range<usize>) {
    if span.is_empty() {
        return;
    }
    let (start, _) = tokens[span.start];
    let (last_start, last) = tokens[span.end - 1];
    ranges.push(WordRange {
        start,
        end: last_start + last.len(),
    });
}

/// What a character is, for splitting a line into tokens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CharClass {
    Word,
    Space,
    Other,
}

impl CharClass {
    fn of(character: char) -> Self {
        if character.is_alphanumeric() || character == '_' {
            Self::Word
        } else if character.is_whitespace() {
            Self::Space
        } else {
            Self::Other
        }
    }
}

/// `text` as tokens with their byte offsets: a run of word characters, a run
/// of whitespace, or any other single character.
fn tokens(text: &str) -> Vec<(usize, &str)> {
    let mut tokens = Vec::new();
    let mut start = 0;
    let mut previous: Option<CharClass> = None;
    for (index, character) in text.char_indices() {
        let class = CharClass::of(character);
        if previous.is_some_and(|previous| previous != class || class == CharClass::Other) {
            tokens.push((start, &text[start..index]));
            start = index;
        }
        previous = Some(class);
    }
    if start < text.len() {
        tokens.push((start, &text[start..]));
    }
    tokens
}
```

- [ ] **Step 4: Run the tests**

Run: `cargo test -p review-diff`
Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-diff
git commit -m "feat(diff): find the words that changed inside a line"
```

---

### Task 4: Line blocks and the file overlay

**Files:**
- Create: `crates/review-diff/src/lines.rs`, `crates/review-diff/src/overlay.rs`
- Modify: `crates/review-diff/src/lib.rs`

`lines.rs` runs the line diff and merges neighbouring changes into blocks; it pairs the n-th removed line of a block with its n-th added line for word highlights. `overlay.rs` builds `FileDiffView`.

- [ ] **Step 1: Write the failing tests for `lines.rs`**

Create `crates/review-diff/src/lines.rs` with only the tests:

```rust
//! The line diff between two files as blocks of equal and changed lines, and
//! the pairing of a changed block's lines for word highlights.

#[cfg(test)]
mod tests {
    use review_model::WordRange;
    use similar::DiffOp;

    use super::*;

    #[test]
    fn neighbouring_changes_merge_into_one_block() {
        let ops = vec![
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
            blocks(&ops),
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
    fn line_ops_find_an_edited_line() {
        let old = ["a", "b", "c"];
        let new = ["a", "B", "c"];
        assert_eq!(
            blocks(&line_ops(&old, &new)),
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
        let (removed, added) = changed_lines(&old, 0..2, &new, 0..1);
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
        assert_eq!(line_number(0), 1);
        assert_eq!(line_number(41), 42);
    }
}
```

- [ ] **Step 2: Write the failing tests for `overlay.rs`**

Create `crates/review-diff/src/overlay.rs` with only the tests:

```rust
//! One file's diff as an overlay on the file itself: the lines that were
//! added, and which removed lines to draw above which line.

#[cfg(test)]
mod tests {
    use review_model::{AddedLine, RemovedBlock, RemovedLine, WordRange};

    use super::*;

    fn text(content: &str) -> FileText {
        FileText::Text(content.to_owned())
    }

    #[test]
    fn an_edited_line_is_added_with_its_old_text_above_it() {
        let view = file_diff_view(
            "a.rs",
            &text("fn main() {\nlet x = 1;\n}\n"),
            &text("fn main() {\nlet x = 2;\n}\n"),
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
        let view = file_diff_view("a.rs", &text("a\nb\n"), &text("a\n"));
        assert!(view.added.is_empty());
        assert_eq!(view.removed.len(), 1);
        assert_eq!(view.removed[0].above, 2);
    }

    #[test]
    fn an_added_file_is_all_added_lines_with_no_base() {
        let view = file_diff_view("new.rs", &FileText::Missing, &text("a\nb\n"));
        let lines: Vec<u64> = view.added.iter().map(|line| line.line).collect();
        assert_eq!(lines, [1, 2]);
        assert!(view.removed.is_empty());
        assert_eq!(view.base_text, None);
    }

    #[test]
    fn a_deleted_file_is_one_removed_block_above_line_one() {
        let view = file_diff_view("old.rs", &text("a\nb\n"), &FileText::Missing);
        assert!(view.added.is_empty());
        assert_eq!(view.removed[0].above, 1);
        assert_eq!(view.removed[0].lines.len(), 2);
    }

    #[test]
    fn a_binary_file_has_no_lines() {
        let view = file_diff_view("logo.png", &FileText::Binary, &FileText::Binary);
        assert!(view.binary);
        assert!(view.added.is_empty() && view.removed.is_empty());
        assert_eq!(view.base_text, None);
    }
}
```

Add both modules to `crates/review-diff/src/lib.rs` and export the builder, so it reads:

```rust
//! Diffs between two texts, and the read models frontends draw from them:
//! one file's overlay ([`file_diff_view`]). Pure functions: no IO and no
//! frontend concepts.

mod lines;
mod overlay;
mod text;
mod words;

pub use overlay::file_diff_view;
pub use text::FileText;
```

(This drops Task 3's temporary `dead_code` allowance: `words` is used now.)

- [ ] **Step 3: Run the tests to see them fail**

Run: `cargo test -p review-diff`
Expected: FAIL to compile: `cannot find function blocks`, `line_ops`, `changed_lines`, `line_number`, `file_diff_view`.

- [ ] **Step 4: Implement `lines.rs`**

Put this above the tests in `crates/review-diff/src/lines.rs`:

```rust
use std::ops::Range;
use std::time::{Duration, Instant};

use review_model::WordRange;
use similar::{Algorithm, DiffOp, DiffTag, capture_diff_slices_deadline};

use crate::words::word_ranges;

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
pub fn line_ops(old: &[&str], new: &[&str]) -> Vec<DiffOp> {
    capture_diff_slices_deadline(
        Algorithm::Histogram,
        old,
        new,
        Some(Instant::now() + DIFF_DEADLINE),
    )
}

/// `ops` as blocks, with neighbouring changes merged into one.
#[must_use]
pub fn blocks(ops: &[DiffOp]) -> Vec<Block> {
    let mut blocks: Vec<Block> = Vec::new();
    for op in ops {
        let (tag, old, new) = op.as_tag_tuple();
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
pub fn changed_lines<'a>(
    old: &[&'a str],
    old_span: Range<usize>,
    new: &[&'a str],
    new_span: Range<usize>,
) -> (Vec<ChangedLine<'a>>, Vec<ChangedLine<'a>>) {
    let side = |lines: &[&'a str], span: Range<usize>| -> Vec<ChangedLine<'a>> {
        span.map(|index| ChangedLine {
            index,
            text: lines[index],
            words: Vec::new(),
        })
        .collect()
    };
    let mut removed = side(old, old_span);
    let mut added = side(new, new_span);
    for (removed_line, added_line) in removed.iter_mut().zip(added.iter_mut()) {
        if let Some((old_words, new_words)) = word_ranges(removed_line.text, added_line.text) {
            removed_line.words = old_words;
            added_line.words = new_words;
        }
    }
    (removed, added)
}

/// A 0-based line index as a 1-based line number.
#[must_use]
pub fn line_number(index: usize) -> u64 {
    u64::try_from(index).map_or(u64::MAX, |index| index.saturating_add(1))
}
```

- [ ] **Step 5: Implement `overlay.rs`**

Put this above the tests in `crates/review-diff/src/overlay.rs`:

```rust
use std::ops::Range;

use review_model::{AddedLine, FileDiffView, RemovedBlock, RemovedLine};

use crate::lines::{Block, blocks, changed_lines, line_number, line_ops};
use crate::text::FileText;

/// The diff of `path` from `base` to `current`, for a frontend that draws a
/// single file.
///
/// It holds the added lines to mark, the removed lines to show above the
/// line that replaced them, and the base text for a split view.
#[must_use]
pub fn file_diff_view(path: &str, base: &FileText, current: &FileText) -> FileDiffView {
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
    for block in blocks(&line_ops(&old, &new)) {
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
    let above = line_number(new_span.start);
    let (removed, added) = changed_lines(old, old_span, new, new_span);
    view.added.extend(added.into_iter().map(|line| AddedLine {
        line: line_number(line.index),
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
```

- [ ] **Step 6: Run the tests**

Run: `cargo test -p review-diff`
Expected: PASS.

- [ ] **Step 7: Gate and commit**

```bash
just check
git add crates/review-diff
git commit -m "feat(diff): build one file's overlay from a line diff"
```

---

### Task 5: The stream rows (`stream.rs`)

**Files:**
- Create: `crates/review-diff/src/stream.rs`
- Modify: `crates/review-diff/src/lib.rs`

The stream is every file in the forge's order: a header (folded when viewed), then hunks with 3 lines of context. Unified rows put the removed lines of a change before its added lines; split rows pair them side by side and leave filler (`None`) where one side runs out.

- [ ] **Step 1: Write the failing tests**

Create `crates/review-diff/src/stream.rs` with only the tests:

```rust
//! The stream: every changed file's hunks as rows, laid out unified or split.

#[cfg(test)]
mod tests {
    use review_model::{ChangedFile, LineCell, LineChange, StreamRow, ViewMode, ViewedState};

    use super::*;

    fn input(path: &str, viewed: ViewedState, base: &FileText, current: &FileText) -> StreamInput {
        StreamInput {
            file: ChangedFile {
                path: path.into(),
                additions: 1,
                deletions: 1,
                viewed,
            },
            content: Ok((base.clone(), current.clone())),
        }
    }

    fn text(content: &str) -> FileText {
        FileText::Text(content.to_owned())
    }

    /// `rows` as short strings, so a test reads like the stream it describes.
    fn sketch(rows: &[StreamRow]) -> Vec<String> {
        rows.iter()
            .map(|row| match row {
                StreamRow::File { path, folded, .. } => {
                    format!("file {path}{}", if *folded { " folded" } else { "" })
                }
                StreamRow::Hunk { header, target, .. } => format!("{header} ->{target}"),
                StreamRow::Note { text, .. } => format!("note {text}"),
                StreamRow::Line {
                    left,
                    right,
                    target,
                    ..
                } => {
                    format!(
                        "{} | {} ->{target}",
                        side(left.as_ref()),
                        side(right.as_ref())
                    )
                }
            })
            .collect()
    }

    fn side(cell: Option<&LineCell>) -> String {
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

    fn rows_for(base: &FileText, current: &FileText, mode: ViewMode) -> Vec<String> {
        let inputs = [input("a.rs", ViewedState::Unviewed, base, current)];
        sketch(&stream_view(&inputs, mode).rows)
    }

    #[test]
    fn unified_puts_removed_lines_before_added_ones() {
        assert_eq!(
            rows_for(&text("a\nb\nc\n"), &text("a\nB\nc\n"), ViewMode::Unified),
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
            rows_for(&text("a\nb\nc\n"), &text("a\nB\nX\nc\n"), ViewMode::Split),
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
        let headers: Vec<String> = rows_for(&text(&base), &text(&current), ViewMode::Unified)
            .into_iter()
            .filter(|row| row.starts_with("@@"))
            .collect();
        assert_eq!(headers, ["@@ -1,4 +1,4 @@ ->1", "@@ -7,4 +7,4 @@ ->7"]);
    }

    #[test]
    fn lines_removed_at_the_end_jump_to_the_last_line() {
        assert_eq!(
            rows_for(&text("a\nb\n"), &text("a\n"), ViewMode::Unified),
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
            rows_for(&FileText::Missing, &text("a\nb\n"), ViewMode::Unified),
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
            input("a.rs", ViewedState::Viewed, &text("a\n"), &text("b\n")),
            input("b.rs", ViewedState::Dismissed, &text("a\n"), &text("b\n")),
        ];
        let headers: Vec<String> = sketch(&stream_view(&inputs, ViewMode::Unified).rows)
            .into_iter()
            .filter(|row| row.starts_with("file"))
            .collect();
        assert_eq!(headers, ["file a.rs folded", "file b.rs"]);
    }

    #[test]
    fn files_without_lines_get_a_note() {
        let binary = input(
            "logo.png",
            ViewedState::Unviewed,
            &FileText::Binary,
            &FileText::Binary,
        );
        let same = input("same.rs", ViewedState::Unviewed, &text("a\n"), &text("a\n"));
        let mut unreadable = input("gone.rs", ViewedState::Unviewed, &text(""), &text(""));
        unreadable.content = Err("permission denied".into());
        let rows = sketch(&stream_view(&[binary, same, unreadable], ViewMode::Split).rows);
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
        assert_eq!(stream_view(&[], ViewMode::Split).mode, ViewMode::Split);
    }
}
```

Add the module and its exports to `crates/review-diff/src/lib.rs`, so it reads:

```rust
//! Diffs between two texts, and the read models frontends draw from them:
//! one file's overlay ([`file_diff_view`]) and the stream of every changed
//! file ([`stream_view`]). Pure functions: no IO and no frontend concepts.

mod lines;
mod overlay;
mod stream;
mod text;
mod words;

pub use overlay::file_diff_view;
pub use stream::{CONTEXT_LINES, StreamInput, stream_view};
pub use text::FileText;
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cargo test -p review-diff`
Expected: FAIL to compile: `cannot find type StreamInput`, `cannot find function stream_view`.

- [ ] **Step 3: Implement it**

Put this above the tests in `crates/review-diff/src/stream.rs`:

```rust
use std::ops::Range;

use review_model::{
    ChangedFile, LineCell, LineChange, StreamRow, StreamView, ViewMode, ViewedState, WordRange,
};
use similar::group_diff_ops;

use crate::lines::{Block, ChangedLine, blocks, changed_lines, line_number, line_ops};
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
pub fn stream_view(inputs: &[StreamInput], mode: ViewMode) -> StreamView {
    let rows = inputs
        .iter()
        .flat_map(|input| file_rows(input, mode))
        .collect();
    StreamView { mode, rows }
}

/// One file's rows: its header, then its hunks or a note saying why it has
/// none.
fn file_rows(input: &StreamInput, mode: ViewMode) -> Vec<StreamRow> {
    let file = &input.file;
    let mut rows = vec![StreamRow::File {
        path: file.path.clone(),
        additions: file.additions,
        deletions: file.deletions,
        viewed: file.viewed,
        folded: file.viewed == ViewedState::Viewed,
    }];
    let note = |text: String| StreamRow::Note {
        path: file.path.clone(),
        text,
    };
    match &input.content {
        Err(message) => rows.push(note(format!("could not read this file: {message}"))),
        Ok((base, current)) if base.is_binary() || current.is_binary() => {
            rows.push(note("binary file".to_owned()));
        }
        Ok((base, current)) => {
            let writer = HunkWriter {
                path: &file.path,
                old: base.lines(),
                new: current.lines(),
                mode,
            };
            let hunks = writer.rows();
            if hunks.is_empty() {
                rows.push(note("no changes against the base".to_owned()));
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
    fn rows(&self) -> Vec<StreamRow> {
        let mut rows = Vec::new();
        for group in group_diff_ops(line_ops(&self.old, &self.new), CONTEXT_LINES) {
            let (Some(first), Some(last)) = (group.first(), group.last()) else {
                continue;
            };
            let old_span = first.old_range().start..last.old_range().end;
            let new_span = first.new_range().start..last.new_range().end;
            rows.push(StreamRow::Hunk {
                path: self.path.to_owned(),
                header: hunk_header(&old_span, &new_span),
                target: self.target(new_span.start),
            });
            for block in blocks(&group) {
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
            let left = cell(
                old_index,
                self.old[old_index],
                LineChange::Context,
                Vec::new(),
            );
            let right = cell(
                new_index,
                self.new[new_index],
                LineChange::Context,
                Vec::new(),
            );
            rows.push(self.line(Some(left), Some(right), line_number(new_index)));
        }
    }

    fn push_change(&self, rows: &mut Vec<StreamRow>, old: Range<usize>, new: Range<usize>) {
        let target = self.target(new.start);
        let (removed, added) = changed_lines(&self.old, old, &self.new, new);
        let removed: Vec<LineCell> = removed
            .into_iter()
            .map(|line| changed_cell(line, LineChange::Removed))
            .collect();
        let added: Vec<LineCell> = added
            .into_iter()
            .map(|line| changed_cell(line, LineChange::Added))
            .collect();
        match self.mode {
            ViewMode::Unified => {
                rows.extend(
                    removed
                        .into_iter()
                        .map(|left| self.line(Some(left), None, target)),
                );
                rows.extend(added.into_iter().map(|right| {
                    let line = right.line;
                    self.line(None, Some(right), line)
                }));
            }
            ViewMode::Split => {
                for index in 0..removed.len().max(added.len()) {
                    let right = added.get(index).cloned();
                    let row_target = right.as_ref().map_or(target, |cell| cell.line);
                    rows.push(self.line(removed.get(index).cloned(), right, row_target));
                }
            }
        }
    }

    fn line(&self, left: Option<LineCell>, right: Option<LineCell>, target: u64) -> StreamRow {
        StreamRow::Line {
            path: self.path.to_owned(),
            left,
            right,
            target,
        }
    }

    /// The new-side line a row at new index `index` jumps to: that line, or
    /// the last line when the change sits past the end of the file.
    fn target(&self, index: usize) -> u64 {
        line_number(index.min(self.new.len().saturating_sub(1)))
    }
}

fn cell(index: usize, text: &str, change: LineChange, words: Vec<WordRange>) -> LineCell {
    LineCell {
        line: line_number(index),
        text: text.to_owned(),
        change,
        words,
    }
}

fn changed_cell(line: ChangedLine<'_>, change: LineChange) -> LineCell {
    cell(line.index, line.text, change, line.words)
}

/// The `@@ -a,b +c,d @@` header of a hunk spanning `old` and `new`.
fn hunk_header(old: &Range<usize>, new: &Range<usize>) -> String {
    format!("@@ -{} +{} @@", range_label(old), range_label(new))
}

/// `start,count` with a 1-based start, or git's `n,0` for an empty side,
/// where `n` is the line before it.
fn range_label(span: &Range<usize>) -> String {
    if span.is_empty() {
        format!("{},0", span.start)
    } else {
        format!("{},{}", span.start + 1, span.len())
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cargo test -p review-diff`
Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-diff
git commit -m "feat(diff): build the stream rows in unified and split layouts"
```

---
### Task 6: The pull request's base commit (HIGH-RISK: persistence format)

**Files:**
- Modify: `crates/review-model/src/pr.rs`
- Modify: `crates/review-core/src/fakes.rs`
- Modify: `crates/review-forge-github/src/pr.rs`
- Modify: `crates/review-store-fs/src/format.rs`
- Modify: `docs/architecture.md`

A diff starts at the merge base of the pull request's head and its base commit. GitHub reports the base commit as `baseRefOid`. It is persisted with the pull request, so a review opened offline can still draw its diffs; that changes `session.json`, so its version goes to 2 and version 1 stays readable (its `baseSha` reads as empty until the next sync).

- [ ] **Step 1: Write the failing tests**

In `crates/review-model/src/pr.rs`, add `base_sha: "base000".into(),` to the `pr()` fixture in the tests (after `base_ref`), and add to `pull_request_uses_camel_case_keys`:

```rust
        assert_eq!(json["baseSha"], "base000");
```

In `crates/review-forge-github/src/pr.rs`, add `"baseRefOid":"base000",` to the `OPEN` fixture (after `"baseRefName":"main",`) and add to `parses_an_open_pull_request`:

```rust
        assert_eq!(pr.base_sha, "base000");
```

In `crates/review-store-fs/src/format.rs` tests, replace `a_session_round_trips_inside_a_version_1_envelope` with these two tests:

```rust
    #[test]
    fn a_session_round_trips_inside_a_version_2_envelope() {
        let bytes = encode_session(&session()).unwrap();
        assert_eq!(as_json(&bytes)["version"], json!(2));
        assert_eq!(as_json(&bytes)["pr"]["headSha"], json!("abc123"));
        assert_eq!(as_json(&bytes)["pr"]["baseSha"], json!("base000"));
        assert_eq!(decode_session(&bytes).unwrap(), session());
    }

    #[test]
    fn a_version_1_session_loads_without_a_base_commit() {
        let record = decode_session(
            br#"{"version": 1, "pr": {"owner": "octo", "number": 7, "headSha": "abc123"}}"#,
        )
        .unwrap();
        let pr = record.pr.unwrap();
        assert_eq!((pr.head_sha.as_str(), pr.base_sha.as_str()), ("abc123", ""));
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cargo test --workspace --all-features`
Expected: FAIL to compile: `PullRequest` has no field `base_sha`.

- [ ] **Step 3: Add the field to the model**

In `crates/review-model/src/pr.rs`, add after `base_ref` in `PullRequest`:

```rust
    /// The base branch's commit the pull request is compared against, for
    /// finding where its changes start. Empty when unknown, as in state an
    /// older build saved.
    #[serde(default)]
    pub base_sha: String,
```

- [ ] **Step 4: Fill it everywhere a pull request is built**

`crates/review-core/src/fakes.rs`, in `sample_pr()`, after `base_ref: "main".into(),`:

```rust
        base_sha: "base000".into(),
```

`crates/review-forge-github/src/pr.rs`: make `PR_FIELDS`

```rust
pub const PR_FIELDS: &str =
    "number,title,url,id,headRefName,headRefOid,state,baseRefName,baseRefOid,author";
```

and in `parse_pr`, after `base_ref: text("/baseRefName")?,`:

```rust
        base_sha: text("/baseRefOid")?,
```

- [ ] **Step 5: Store it in `session.json` v2, still reading v1**

In `crates/review-store-fs/src/format.rs`:

Replace the `SESSION_VERSION` constant with:

```rust
/// The `session.json` shape this build writes. Version 2 added the pull
/// request's `baseSha`.
pub const SESSION_VERSION: u32 = 2;
/// The oldest `session.json` shape this build still reads: version 1 has no
/// `baseSha`, which reads as empty until the next sync fills it.
pub const OLDEST_SESSION_VERSION: u32 = 1;
```

Add `base_sha: String,` as the last field of `StoredPullRequest`, and add `base_sha` to both `From` impls' destructuring and construction (after `base_ref`). The compiler names every place that is missing it.

Change `decode` to take the oldest readable version, and its callers:

```rust
/// `session.json`'s session record.
pub fn decode_session(bytes: &[u8]) -> Result<SessionRecord> {
    let file: SessionFile = decode(bytes, OLDEST_SESSION_VERSION, SESSION_VERSION)?;
    Ok(SessionRecord {
        pid: file.pid,
        worktree: file.worktree,
        pr: file.pr.map(PullRequest::from),
        last_synced_at: file.last_synced_at,
    })
}
```

```rust
/// The changed files in `viewed.json`'s bytes.
pub fn decode_files(bytes: &[u8]) -> Result<Vec<ChangedFile>> {
    let file: ViewedFile = decode(bytes, VIEWED_VERSION, VIEWED_VERSION)?;
    Ok(file.files.into_iter().map(ChangedFile::from).collect())
}
```

```rust
/// Reads a file whose version is between `oldest` and `known`. Every shape in
/// that range must read into the same struct, with defaults for the fields
/// an older version lacks.
fn decode<T: DeserializeOwned>(bytes: &[u8], oldest: u32, known: u32) -> Result<T> {
    let found = stored_version(bytes)?;
    refuse_newer(found, known)?;
    if found < oldest {
        bail!(
            "it is format version {found}, which this build cannot read (it reads {})",
            readable_versions(oldest, known)
        );
    }
    serde_json::from_slice(bytes).context("this is not valid review state (fix or delete the file)")
}

/// `version 1`, or `versions 1 to 2`, for an error message.
fn readable_versions(oldest: u32, known: u32) -> String {
    if oldest == known {
        format!("version {known}")
    } else {
        format!("versions {oldest} to {known}")
    }
}
```

In `crates/review-store-fs/src/lib.rs`, export the new constant next to the others:

```rust
pub use format::{OLDEST_SESSION_VERSION, SESSION_VERSION, VIEWED_VERSION};
```

- [ ] **Step 6: Run the tests**

Run: `cargo test --workspace --all-features`
Expected: PASS, including `an_unknown_older_version_is_refused` (version 0 is still older than the oldest readable) and `loading_a_newer_file_names_it_and_both_versions`.

- [ ] **Step 7: Update the state table in `docs/architecture.md`**

Replace the `session.json` row of the "State on disk" table with:

```markdown
| `session.json` | `{"version":2,"pid","worktree","pr","lastSyncedAt"}`: the daemon's pid, the worktree, the pull request (with its `baseSha`), the last successful sync (Unix seconds). Version 1 still loads, with an empty `baseSha` |
```

- [ ] **Step 8: Gate and commit**

```bash
just check
git add crates docs/architecture.md
git commit -m "feat: keep the pull request's base commit (session.json v2)"
```

---

### Task 7: The viewed queue in `github.json` (HIGH-RISK: persistence format)

**Files:**
- Modify: `crates/review-core/src/ports.rs`, `crates/review-core/src/contract.rs`
- Modify: `crates/review-store-fs/src/format.rs`, `crates/review-store-fs/src/lib.rs`
- Modify: `docs/architecture.md`

The spec puts the offline queues in `github.json`, the sync registry. This milestone adds its first queue: viewed marks GitHub has not accepted yet, as `path → viewed`. Later milestones add the comment queues to the same file.

- [ ] **Step 1: Write the failing tests**

In `crates/review-core/src/contract.rs`, add the registry to the `first` snapshot of `check_review_store` (and its imports: `use std::collections::BTreeMap;` and `SyncRegistry` from `crate::ports`):

```rust
    let first = StoreSnapshot {
        session: SessionRecord {
            pid: Some(42),
            worktree: Some("/tmp/widgets-worktrees/pr-7".into()),
            pr: Some(sample_pr()),
            last_synced_at: Some(100),
        },
        files: vec![
            changed_file("src/a.rs", ViewedState::Viewed),
            changed_file("src/b.rs", ViewedState::Dismissed),
        ],
        registry: SyncRegistry {
            queued_viewed: BTreeMap::from([("src/b.rs".to_owned(), true)]),
        },
    };
```

In `crates/review-store-fs/src/format.rs` tests, add (and `use std::collections::BTreeMap;` plus `use review_core::ports::SyncRegistry;` in the test module):

```rust
    #[test]
    fn the_github_file_is_a_version_1_envelope_around_the_queue() {
        let registry = SyncRegistry {
            queued_viewed: BTreeMap::from([("src/a.rs".to_owned(), false)]),
        };
        let bytes = encode_registry(&registry).unwrap();
        assert_eq!(
            as_json(&bytes),
            json!({ "version": 1, "queuedViewed": { "src/a.rs": false } })
        );
        assert_eq!(decode_registry(&bytes).unwrap(), registry);
    }
```

In `crates/review-store-fs/src/lib.rs` tests:

- in `save_leaves_no_temporary_files` and at the end of `concurrent_saves_never_tear_a_file_or_leave_temporaries`, expect three files: `["github.json", "session.json", "viewed.json"]`;
- in `save_never_overwrites_a_newer_file`, also assert `assert!(!dir.path().join(GITHUB_FILE).exists());`;
- add:

```rust
    #[test]
    fn a_newer_github_file_blocks_every_write() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(GITHUB_FILE), r#"{"version": 9}"#).unwrap();
        let error = FsStore::new(dir.path())
            .save(&StoreSnapshot::default())
            .unwrap_err();
        assert!(format!("{error:#}").contains("github.json"), "{error:#}");
        assert!(!dir.path().join(SESSION_FILE).exists());
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cargo test --workspace --all-features`
Expected: FAIL to compile: no `SyncRegistry`, no `registry` field, no `encode_registry`, no `GITHUB_FILE`.

- [ ] **Step 3: Add `SyncRegistry` to the store snapshot**

In `crates/review-core/src/ports.rs`, add `use std::collections::BTreeMap;` and, above `StoreSnapshot`:

```rust
/// What the engine still owes the forge: changes made while the forge could
/// not be reached, sent again on the next try. Saved with everything else,
/// so a restarted engine still delivers them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SyncRegistry {
    /// Viewed marks the forge has not accepted yet, by path: `true` for
    /// viewed, `false` for unviewed.
    pub queued_viewed: BTreeMap<String, bool>,
}
```

and add the field at the end of `StoreSnapshot`:

```rust
    /// What the engine still owes the forge.
    pub registry: SyncRegistry,
```

- [ ] **Step 4: Encode it as `github.json`**

In `crates/review-store-fs/src/format.rs`, add `use std::collections::BTreeMap;`, import `SyncRegistry` next to `SessionRecord`, and add:

```rust
/// The `github.json` shape this build reads and writes.
pub const GITHUB_VERSION: u32 = 1;

/// `github.json`: what the engine still owes GitHub.
#[derive(Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct GithubFile {
    version: u32,
    queued_viewed: BTreeMap<String, bool>,
}

/// `github.json`'s bytes for `registry`.
pub fn encode_registry(registry: &SyncRegistry) -> Result<Vec<u8>> {
    encode(&GithubFile {
        version: GITHUB_VERSION,
        queued_viewed: registry.queued_viewed.clone(),
    })
}

/// The registry in `github.json`'s bytes.
pub fn decode_registry(bytes: &[u8]) -> Result<SyncRegistry> {
    let file: GithubFile = decode(bytes, GITHUB_VERSION, GITHUB_VERSION)?;
    Ok(SyncRegistry {
        queued_viewed: file.queued_viewed,
    })
}
```

- [ ] **Step 5: Load and save it in `FsStore`**

In `crates/review-store-fs/src/lib.rs`:

```rust
pub use format::{GITHUB_VERSION, OLDEST_SESSION_VERSION, SESSION_VERSION, VIEWED_VERSION};
```

```rust
/// The file, in a pull request's state directory, that holds what the engine
/// still owes GitHub, such as viewed marks it could not send.
pub const GITHUB_FILE: &str = "github.json";
```

Replace the `ReviewStore` impl with:

```rust
impl ReviewStore for FsStore {
    fn load(&self) -> Result<StoreSnapshot> {
        let session = load_file(&self.dir.join(SESSION_FILE), format::decode_session)?;
        let files = load_file(&self.dir.join(VIEWED_FILE), format::decode_files)?;
        let registry = load_file(&self.dir.join(GITHUB_FILE), format::decode_registry)?;
        Ok(StoreSnapshot {
            session: session.unwrap_or_default(),
            files: files.unwrap_or_default(),
            registry: registry.unwrap_or_default(),
        })
    }

    fn save(&self, snapshot: &StoreSnapshot) -> Result<()> {
        // Check every file before writing any, so a refusal changes nothing.
        refuse_newer_file(&self.dir.join(SESSION_FILE), SESSION_VERSION)?;
        refuse_newer_file(&self.dir.join(VIEWED_FILE), VIEWED_VERSION)?;
        refuse_newer_file(&self.dir.join(GITHUB_FILE), GITHUB_VERSION)?;
        fs::create_dir_all(&self.dir)
            .with_context(|| format!("creating {}", self.dir.display()))?;
        let session = format::encode_session(&snapshot.session)?;
        atomic::write_atomic(&self.dir, SESSION_FILE, &session)?;
        let files = format::encode_files(&snapshot.files)?;
        atomic::write_atomic(&self.dir, VIEWED_FILE, &files)?;
        let registry = format::encode_registry(&snapshot.registry)?;
        atomic::write_atomic(&self.dir, GITHUB_FILE, &registry)
    }
}
```

Update the crate doc's first line to say "one JSON file per concern (`session.json`, `viewed.json`, `github.json`)".

- [ ] **Step 6: Run the tests**

Run: `cargo test --workspace --all-features`
Expected: PASS, including `passes_the_review_store_contract` with the registry.

- [ ] **Step 7: Update `docs/architecture.md`**

Add a row to the "State on disk" table:

```markdown
| `github.json` | `{"version":1,"queuedViewed":{"<path>":true}}`: viewed marks GitHub has not accepted yet. Later milestones add the comment queues here |
```

and change "Both files are checked before either is written." to "Every file is checked before any is written." and "The two files are not written atomically as a pair" to "The files are not written atomically as a set".

- [ ] **Step 8: Gate and commit**

```bash
just check
git add crates docs/architecture.md
git commit -m "feat(store): persist viewed marks GitHub has not accepted (github.json)"
```

---

### Task 8: The `Workspace` port and its fake

**Files:**
- Modify: `crates/review-core/src/ports.rs`, `crates/review-core/src/fakes.rs`

The session reads both sides of every diff through this port. Nothing uses it yet; Task 10 wires it in.

- [ ] **Step 1: Write the failing test**

Add at the end of `crates/review-core/src/fakes.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_fake_workspace_answers_from_memory() {
        let workspace = FakeWorkspace::default();
        workspace.put_base("src/old.rs", "base\n");
        workspace.put_disk("src/a.rs", "disk\n");
        workspace.rename("src/old.rs", "src/a.rs");
        assert_eq!(workspace.merge_base("base000").unwrap(), FAKE_MERGE_BASE);
        assert_eq!(workspace.merge_base_calls(), 1);
        assert_eq!(
            workspace.file_at(FAKE_MERGE_BASE, "src/old.rs").unwrap(),
            Some(b"base\n".to_vec())
        );
        assert!(workspace.file_at("other", "src/old.rs").is_err());
        assert_eq!(workspace.file_on_disk("src/a.rs").unwrap(), Some(b"disk\n".to_vec()));
        assert_eq!(workspace.file_on_disk("src/b.rs").unwrap(), None);
        assert_eq!(
            workspace.renames(FAKE_MERGE_BASE).unwrap(),
            [("src/old.rs".to_owned(), "src/a.rs".to_owned())]
        );
        workspace.fail_with(Some("no network"));
        assert!(workspace.merge_base("base000").is_err());
    }
}
```

- [ ] **Step 2: Run the test to see it fail**

Run: `cargo test -p review-core --all-features`
Expected: FAIL to compile: no `FakeWorkspace`, `FAKE_MERGE_BASE`, `Workspace`.

- [ ] **Step 3: Add the port**

In `crates/review-core/src/ports.rs`, after the `Forge` trait:

```rust
/// The reviewer's checkout of the pull request: its git history and the
/// files on disk. The session reads the two sides of every diff through it,
/// so a test can use an in-memory fake instead of a repository.
pub trait Workspace: Send {
    /// The commit the pull request's changes are measured from: where the
    /// checked-out head and `base_sha` diverge.
    fn merge_base(&self, base_sha: &str) -> Result<String>;
    /// `path` as it is in `commit`, or `None` when it does not exist there.
    fn file_at(&self, commit: &str, path: &str) -> Result<Option<Vec<u8>>>;
    /// `path` as it is on disk in the checkout, or `None` when it is not there.
    fn file_on_disk(&self, path: &str) -> Result<Option<Vec<u8>>>;
    /// The files renamed between `commit` and the checkout, as `(old, new)` paths.
    fn renames(&self, commit: &str) -> Result<Vec<(String, String)>>;
}
```

- [ ] **Step 4: Add the fake**

In `crates/review-core/src/fakes.rs`, add `use std::collections::HashMap;`, add `bail` to the anyhow import, add `Workspace` to the ports import, and append (above the tests):

```rust
/// The merge base a [`FakeWorkspace`] reports for any base commit.
pub const FAKE_MERGE_BASE: &str = "merge000";

#[derive(Debug, Default)]
struct WorkspaceState {
    base: HashMap<String, Vec<u8>>,
    disk: HashMap<String, Vec<u8>>,
    renames: Vec<(String, String)>,
    merge_base_calls: usize,
    failure: Option<String>,
}

/// A checkout held in memory, for session and server tests: files at the
/// merge base, files on disk, and renames. Clones share state, so a test
/// keeps one to fill and inspect while the session holds another.
#[derive(Debug, Clone, Default)]
pub struct FakeWorkspace {
    state: Arc<Mutex<WorkspaceState>>,
}

impl FakeWorkspace {
    /// Puts `text` at `path` in the merge base.
    pub fn put_base(&self, path: &str, text: &str) {
        self.lock().base.insert(path.to_owned(), text.as_bytes().to_vec());
    }

    /// Puts `text` at `path` on disk.
    pub fn put_disk(&self, path: &str, text: &str) {
        self.lock().disk.insert(path.to_owned(), text.as_bytes().to_vec());
    }

    /// Records that `old` was renamed to `new` since the merge base.
    pub fn rename(&self, old: &str, new: &str) {
        self.lock().renames.push((old.to_owned(), new.to_owned()));
    }

    /// Makes finding the merge base fail with `message`, or succeed again
    /// with `None`.
    pub fn fail_with(&self, message: Option<&str>) {
        self.lock().failure = message.map(str::to_owned);
    }

    /// How many times the merge base was looked up.
    #[must_use]
    pub fn merge_base_calls(&self) -> usize {
        self.lock().merge_base_calls
    }

    fn lock(&self) -> MutexGuard<'_, WorkspaceState> {
        self.state.lock().expect("the fake workspace lock is poisoned")
    }
}

impl Workspace for FakeWorkspace {
    fn merge_base(&self, _base_sha: &str) -> Result<String> {
        let mut state = self.lock();
        if let Some(message) = &state.failure {
            return Err(anyhow!("{message}"));
        }
        state.merge_base_calls += 1;
        Ok(FAKE_MERGE_BASE.to_owned())
    }

    fn file_at(&self, commit: &str, path: &str) -> Result<Option<Vec<u8>>> {
        if commit != FAKE_MERGE_BASE {
            bail!("the fake workspace has no commit {commit}");
        }
        Ok(self.lock().base.get(path).cloned())
    }

    fn file_on_disk(&self, path: &str) -> Result<Option<Vec<u8>>> {
        Ok(self.lock().disk.get(path).cloned())
    }

    fn renames(&self, commit: &str) -> Result<Vec<(String, String)>> {
        if commit != FAKE_MERGE_BASE {
            bail!("the fake workspace has no commit {commit}");
        }
        Ok(self.lock().renames.clone())
    }
}
```

- [ ] **Step 5: Run the test**

Run: `cargo test -p review-core --all-features`
Expected: PASS.

- [ ] **Step 6: Gate and commit**

```bash
just check
git add crates/review-core
git commit -m "feat(core): add the Workspace port and its fake"
```

---

### Task 9: `GitWorkspace` (HIGH-RISK: reads files a pull request names)

**Files:**
- Modify: `crates/review-workspace-git/Cargo.toml`, `src/lib.rs`, `src/process.rs`
- Create: `crates/review-workspace-git/src/git_output.rs`, `src/worktree_path.rs`, `src/workspace.rs`

Paths and commits come from GitHub, so they are untrusted. A path must stay inside the worktree (no absolute paths, no `..`, no directory symlink out), a symlink reads as its target's path the way git stores it instead of being followed, and a commit must be hex so it can never reach git as an option. Content comes from `git cat-file --batch`, which takes the `commit:path` on stdin, so no path is ever read as a pathspec.

- [ ] **Step 1: Add the dependency**

In `crates/review-workspace-git/Cargo.toml`, add to `[dependencies]`:

```toml
review-core.workspace = true
```

and update its description to `"Checks a pull request out into its own worktree, and reads its files and history."`.

- [ ] **Step 2: Write the failing tests for the pure parts**

Create `crates/review-workspace-git/src/git_output.rs`:

```rust
//! Pure readers of git's output and guards for its input, so the commands
//! that run git stay thin.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commit_ids_are_hex_of_a_sane_length() {
        assert!(is_commit_id("abc123"));
        assert!(is_commit_id(&"f".repeat(40)));
        assert!(!is_commit_id("--help"));
        assert!(!is_commit_id("main"));
        assert!(!is_commit_id("abc"));
    }

    #[test]
    fn reads_a_blob_from_a_batch_answer() {
        assert_eq!(
            parse_batch_blob(b"0123 blob 3\nab\n\n").unwrap(),
            Some(b"ab\n".to_vec())
        );
    }

    #[test]
    fn a_missing_object_or_a_directory_is_none() {
        assert_eq!(parse_batch_blob(b"abc123:x.rs missing\n").unwrap(), None);
        assert_eq!(parse_batch_blob(b"0123 tree 30\nxxxx\n").unwrap(), None);
    }

    #[test]
    fn a_cut_short_answer_is_an_error() {
        assert!(parse_batch_blob(b"0123 blob 10\nab").is_err());
        assert!(parse_batch_blob(b"").is_err());
    }

    #[test]
    fn reads_renames_and_skips_other_changes() {
        let output = b"M\0src/a.rs\0R087\0old/name.rs\0new/name.rs\0C100\0x.rs\0y.rs\0D\0gone.rs\0";
        assert_eq!(
            parse_renames(output),
            [("old/name.rs".to_owned(), "new/name.rs".to_owned())]
        );
    }
}
```

Create `crates/review-workspace-git/src/worktree_path.rs`:

```rust
//! Reading a file the pull request names, which is untrusted: it must stay
//! inside the worktree.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_relative_paths_are_safe() {
        assert_eq!(safe_relative("src/a.rs").unwrap(), Path::new("src/a.rs"));
    }

    #[test]
    fn empty_absolute_and_climbing_paths_are_refused() {
        for path in ["", "/etc/passwd", "../x", "a/../../x", "./a"] {
            assert!(safe_relative(path).is_err(), "{path:?}");
        }
    }
}
```

Add both modules to `crates/review-workspace-git/src/lib.rs` (keep the existing ones):

```rust
mod git_output;
mod worktree_path;
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cargo test -p review-workspace-git`
Expected: FAIL to compile: `cannot find function is_commit_id`, `parse_batch_blob`, `parse_renames`, `safe_relative`.

- [ ] **Step 4: Implement `git_output.rs`**

Put this above its tests:

```rust
use anyhow::{Context, Result};

/// Whether `value` looks like a commit id: 4 to 64 hex digits. Anything else,
/// such as an option like `--output` or a branch name, is refused before it
/// reaches git.
#[must_use]
pub fn is_commit_id(value: &str) -> bool {
    (4..=64).contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// The file in `git cat-file --batch`'s answer to one request, or `None` when
/// the object is missing or is not a file (a directory or a submodule).
pub fn parse_batch_blob(output: &[u8]) -> Result<Option<Vec<u8>>> {
    let header_end = output
        .iter()
        .position(|byte| *byte == b'\n')
        .context("git cat-file printed no header")?;
    let header = std::str::from_utf8(&output[..header_end])
        .context("git cat-file printed a header that is not text")?;
    if header.ends_with(" missing") || header.ends_with(" ambiguous") {
        return Ok(None);
    }
    let mut fields = header.split(' ');
    let (_, kind, size) = (fields.next(), fields.next(), fields.next());
    if kind != Some("blob") {
        return Ok(None);
    }
    let size: usize = size
        .context("git cat-file printed no size")?
        .parse()
        .context("git cat-file printed a size that is not a number")?;
    let body = output
        .get(header_end + 1..header_end + 1 + size)
        .context("git cat-file's answer was cut short")?;
    Ok(Some(body.to_vec()))
}

/// The renamed files in `git diff --name-status -z -M`'s output, as
/// `(old, new)` paths. Copies are not renames: the original still exists.
#[must_use]
pub fn parse_renames(output: &[u8]) -> Vec<(String, String)> {
    let mut fields = output.split(|byte| *byte == 0).filter(|field| !field.is_empty());
    let mut renames = Vec::new();
    while let Some(status) = fields.next() {
        let path_count = if matches!(status.first(), Some(b'R' | b'C')) { 2 } else { 1 };
        let paths: Vec<String> = fields
            .by_ref()
            .take(path_count)
            .map(|path| String::from_utf8_lossy(path).into_owned())
            .collect();
        if let (Some(b'R'), [old, new]) = (status.first(), paths.as_slice()) {
            renames.push((old.clone(), new.clone()));
        }
    }
    renames
}
```

- [ ] **Step 5: Implement `worktree_path.rs`**

Put this above its tests:

```rust
use std::fs;
use std::io::ErrorKind;
use std::path::{Component, Path};

use anyhow::{Context, Result, bail};

/// `path` as a relative path inside a worktree, or an error when it is empty,
/// absolute, or steps outside with `..` or `.`.
pub fn safe_relative(path: &str) -> Result<&Path> {
    let relative = Path::new(path);
    let is_plain = !path.is_empty()
        && relative
            .components()
            .all(|component| matches!(component, Component::Normal(_)));
    if is_plain {
        Ok(relative)
    } else {
        bail!("{path:?} is not a path inside the worktree")
    }
}

/// The content of `path` in the worktree at `root`, or `None` when nothing is
/// there.
///
/// A symlink reads as its target's path, which is how git stores it, and is
/// never followed: a pull request cannot make the reviewer's editor show a
/// file from outside the worktree.
pub fn read_in_worktree(root: &Path, path: &str) -> Result<Option<Vec<u8>>> {
    let full = root.join(safe_relative(path)?);
    let metadata = match fs::symlink_metadata(&full) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error).with_context(|| format!("reading {path}")),
    };
    if metadata.file_type().is_symlink() {
        let target = fs::read_link(&full).with_context(|| format!("reading the link {path}"))?;
        return Ok(Some(target.to_string_lossy().into_owned().into_bytes()));
    }
    ensure_inside(root, &full, path)?;
    fs::read(&full)
        .map(Some)
        .with_context(|| format!("reading {path}"))
}

/// Fails when `full` resolves outside `root`, as it does when a directory on
/// the way is a symlink out of the worktree.
fn ensure_inside(root: &Path, full: &Path, path: &str) -> Result<()> {
    let root = root
        .canonicalize()
        .with_context(|| format!("resolving {}", root.display()))?;
    let resolved = full
        .canonicalize()
        .with_context(|| format!("resolving {path}"))?;
    if resolved.starts_with(&root) {
        Ok(())
    } else {
        bail!("{path} resolves outside the worktree")
    }
}
```

- [ ] **Step 6: Run the pure tests**

Run: `cargo test -p review-workspace-git`
Expected: PASS (the new functions are unused outside tests until Step 9; if clippy reports `dead_code` at the gate, Step 9 fixes it).

- [ ] **Step 7: Let `process.rs` return bytes and take stdin**

Replace `crates/review-workspace-git/src/process.rs` with:

```rust
use std::io::Write;
use std::path::Path;
use std::process::{Command, Output, Stdio};

use anyhow::{Context, Result, bail};

/// Runs `program` in `dir` and returns its stdout as text, or fails with its
/// stderr.
pub fn run(program: &str, args: &[&str], dir: &Path) -> Result<String> {
    run_bytes(program, args, dir).map(|stdout| String::from_utf8_lossy(&stdout).into_owned())
}

/// Runs `program` in `dir` and returns its raw stdout, or fails with its stderr.
pub fn run_bytes(program: &str, args: &[&str], dir: &Path) -> Result<Vec<u8>> {
    let output = Command::new(program)
        .args(args)
        .current_dir(dir)
        .output()
        .with_context(|| format!("running {program}"))?;
    stdout_or_error(program, output)
}

/// Runs `program` in `dir` with `input` on its stdin and returns its raw
/// stdout, or fails with its stderr.
pub fn run_with_input(program: &str, args: &[&str], dir: &Path, input: &[u8]) -> Result<Vec<u8>> {
    let mut child = Command::new(program)
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("running {program}"))?;
    // Dropped at the end of the block, which closes stdin so the program ends.
    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(input)
            .with_context(|| format!("writing to {program}"))?;
    }
    let output = child
        .wait_with_output()
        .with_context(|| format!("running {program}"))?;
    stdout_or_error(program, output)
}

fn stdout_or_error(program: &str, output: Output) -> Result<Vec<u8>> {
    if output.status.success() {
        return Ok(output.stdout);
    }
    bail!(
        "{program} failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    )
}
```

- [ ] **Step 8: Write the failing tests for `GitWorkspace`**

Create `crates/review-workspace-git/src/workspace.rs` with only the tests:

```rust
//! The git [`Workspace`]: a pull request's worktree and its history.

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;

    use review_core::ports::Workspace;

    use super::*;
    use crate::process::run;
    use crate::test_support::{git, repo};

    fn head(dir: &Path) -> String {
        run("git", &["rev-parse", "HEAD"], dir).unwrap().trim().to_owned()
    }

    #[test]
    fn reads_a_file_at_a_commit_and_on_disk() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let base = head(&root);
        fs::write(root.join("a.txt"), "changed\n").unwrap();
        let workspace = GitWorkspace::new(root);
        assert_eq!(workspace.file_at(&base, "a.txt").unwrap(), Some(b"a\n".to_vec()));
        assert_eq!(workspace.file_on_disk("a.txt").unwrap(), Some(b"changed\n".to_vec()));
        assert_eq!(workspace.file_at(&base, "absent.txt").unwrap(), None);
        assert_eq!(workspace.file_on_disk("absent.txt").unwrap(), None);
    }

    #[test]
    fn the_merge_base_is_where_the_branch_left_the_base() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let branched_from = head(&root);
        git(&root, &["checkout", "-q", "-b", "feature"]);
        fs::write(root.join("b.txt"), "b\n").unwrap();
        git(&root, &["add", "."]);
        git(&root, &["commit", "-q", "-m", "feature"]);
        git(&root, &["checkout", "-q", "main"]);
        fs::write(root.join("c.txt"), "c\n").unwrap();
        git(&root, &["add", "."]);
        git(&root, &["commit", "-q", "-m", "main moves on"]);
        let main_tip = head(&root);
        git(&root, &["checkout", "-q", "feature"]);
        assert_eq!(GitWorkspace::new(root).merge_base(&main_tip).unwrap(), branched_from);
    }

    #[test]
    fn finds_renames_against_a_commit() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let base = head(&root);
        git(&root, &["mv", "a.txt", "renamed.txt"]);
        assert_eq!(
            GitWorkspace::new(root).renames(&base).unwrap(),
            [("a.txt".to_owned(), "renamed.txt".to_owned())]
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_reads_as_its_target_and_is_not_followed() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let secret = dir.path().join("secret.txt");
        fs::write(&secret, "secret\n").unwrap();
        std::os::unix::fs::symlink(&secret, root.join("link")).unwrap();
        let content = GitWorkspace::new(root).file_on_disk("link").unwrap().unwrap();
        assert_eq!(String::from_utf8(content).unwrap(), secret.to_string_lossy());
    }

    #[cfg(unix)]
    #[test]
    fn a_directory_symlink_out_of_the_worktree_is_refused() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let outside = dir.path().join("outside");
        fs::create_dir(&outside).unwrap();
        fs::write(outside.join("f.txt"), "x").unwrap();
        std::os::unix::fs::symlink(&outside, root.join("out")).unwrap();
        let error = GitWorkspace::new(root).file_on_disk("out/f.txt").unwrap_err();
        assert!(format!("{error:#}").contains("outside the worktree"), "{error:#}");
    }

    #[test]
    fn climbing_paths_and_options_posing_as_commits_are_refused() {
        let dir = repo();
        let workspace = GitWorkspace::new(dir.path().join("widgets"));
        assert!(workspace.file_on_disk("../secret.txt").is_err());
        assert!(workspace.file_on_disk("/etc/passwd").is_err());
        assert!(workspace.file_at("--output=x", "a.txt").is_err());
        assert!(workspace.merge_base("--help").is_err());
        assert!(workspace.renames("HEAD").is_err());
    }
}
```

Add to `crates/review-workspace-git/src/lib.rs`:

```rust
mod workspace;
```

```rust
pub use workspace::GitWorkspace;
```

and change the crate doc to: `//! A pull request's worktree: checking it out, and reading its files and history. Generic: it knows git and gh, and nothing about any editor.`

Run: `cargo test -p review-workspace-git`
Expected: FAIL to compile: `cannot find type GitWorkspace`.

- [ ] **Step 9: Implement `GitWorkspace`**

Put this above the tests in `crates/review-workspace-git/src/workspace.rs`:

```rust
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use review_core::ports::Workspace;

use crate::git_output::{is_commit_id, parse_batch_blob, parse_renames};
use crate::process::{run, run_bytes, run_with_input};
use crate::worktree_path::read_in_worktree;

/// [`Workspace`] over git in one worktree, for any frontend reviewing a
/// checked-out pull request.
#[derive(Debug, Clone)]
pub struct GitWorkspace {
    dir: PathBuf,
}

impl GitWorkspace {
    /// A workspace over the worktree at `dir`.
    #[must_use]
    pub const fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    /// Fetches `commit` from `origin` unless this repository already has it.
    fn ensure_commit(&self, commit: &str) -> Result<()> {
        let object = format!("{commit}^{{commit}}");
        if run("git", &["cat-file", "-e", &object], &self.dir).is_ok() {
            return Ok(());
        }
        run("git", &["fetch", "--quiet", "--no-tags", "origin", commit], &self.dir)
            .with_context(|| format!("fetching the base commit {commit} from origin"))?;
        Ok(())
    }
}

/// Fails unless `value` is a commit id, so it can never reach git as an option.
fn require_commit_id(value: &str) -> Result<()> {
    if is_commit_id(value) {
        Ok(())
    } else {
        bail!("{value:?} is not a commit id")
    }
}

impl Workspace for GitWorkspace {
    fn merge_base(&self, base_sha: &str) -> Result<String> {
        require_commit_id(base_sha)?;
        self.ensure_commit(base_sha)?;
        let stdout = run("git", &["merge-base", base_sha, "HEAD"], &self.dir)
            .context("finding where the pull request branches off its base")?;
        Ok(stdout.trim().to_owned())
    }

    fn file_at(&self, commit: &str, path: &str) -> Result<Option<Vec<u8>>> {
        require_commit_id(commit)?;
        if path.contains('\n') {
            bail!("{path:?} cannot be read from git: it holds a newline");
        }
        let request = format!("{commit}:{path}\n");
        let output = run_with_input("git", &["cat-file", "--batch"], &self.dir, request.as_bytes())?;
        parse_batch_blob(&output).with_context(|| format!("reading {path} at {commit}"))
    }

    fn file_on_disk(&self, path: &str) -> Result<Option<Vec<u8>>> {
        read_in_worktree(&self.dir, path)
    }

    fn renames(&self, commit: &str) -> Result<Vec<(String, String)>> {
        require_commit_id(commit)?;
        let output = run_bytes(
            "git",
            &["diff", "--name-status", "-z", "-M", commit, "--"],
            &self.dir,
        )?;
        Ok(parse_renames(&output))
    }
}
```

- [ ] **Step 10: Run the tests**

Run: `cargo test -p review-workspace-git`
Expected: PASS.

- [ ] **Step 11: Gate and commit**

```bash
just check
git add crates/review-workspace-git Cargo.lock
git commit -m "feat(workspace-git): read a worktree's files and history safely (GitWorkspace)"
```

---

### Task 10: `Ports`, and the session split into one module per use case

**Files:**
- Modify: `crates/review-core/src/ports.rs`, `crates/review-core/src/fakes.rs`
- Delete: `crates/review-core/src/session.rs`
- Create: `crates/review-core/src/session/mod.rs`, `session/sync.rs`, `session/test_support.rs`
- Modify: `crates/review-rpc/tests/serve.rs`
- Modify: `crates/jpr-review/src/commands/serve.rs`

`session.rs` is about to gain three use cases, which would take it past the size the Rust rules allow. This task moves it into a directory without changing behavior, and replaces the four port arguments of `ReviewSession::open` with one `Ports` value that also carries the workspace. Every existing session test moves unchanged in substance.

- [ ] **Step 1: Add `Ports` and `fake_ports`**

In `crates/review-core/src/ports.rs`, after the `Clock` trait and `SystemClock`:

```rust
/// The adapters a session runs on, one per port. Only a composition root,
/// or a test, builds one.
pub struct Ports {
    /// The forge that hosts the pull request.
    pub forge: Box<dyn Forge>,
    /// Where the session's state is saved.
    pub store: Box<dyn ReviewStore>,
    /// The checkout the diffs are read from.
    pub workspace: Box<dyn Workspace>,
    /// The time.
    pub clock: Box<dyn Clock>,
}
```

In `crates/review-core/src/fakes.rs`, import `Ports` and add after `FixedClock`'s impls:

```rust
/// [`Ports`] over clones of these fakes, so a test keeps handles that share
/// state with what the session holds.
#[must_use]
pub fn fake_ports(
    forge: &FakeForge,
    store: &MemoryStore,
    workspace: &FakeWorkspace,
    clock: &FixedClock,
) -> Ports {
    Ports {
        forge: Box::new(forge.clone()),
        store: Box::new(store.clone()),
        workspace: Box::new(workspace.clone()),
        clock: Box::new(clock.clone()),
    }
}
```

- [ ] **Step 2: Create `session/mod.rs`**

Delete `crates/review-core/src/session.rs` (`git rm`) and create `crates/review-core/src/session/mod.rs`:

```rust
//! One pull request's review session: the facade every frontend talks to.
//! Each use case lives in its own submodule; this one holds the state they
//! share.

mod sync;
#[cfg(test)]
mod test_support;

use std::sync::mpsc::{self, Receiver, Sender};

use anyhow::Result;
use review_model::{Event, SessionView, SyncState, Thread};

use crate::ports::{Ports, StoreSnapshot};
use crate::presenter::session_view;

/// One pull request's review session: the facade every frontend talks to.
///
/// It owns the session state, reaches the outside world only through its
/// [`Ports`], and announces changes as [`Event`]s to its subscribers.
pub struct ReviewSession {
    number: u64,
    ports: Ports,
    saved: StoreSnapshot,
    threads: Vec<Thread>,
    sync: SyncState,
    subscribers: Vec<Sender<Event>>,
}

impl ReviewSession {
    /// Opens pull request `number`'s session from what its store saved.
    /// Nothing talks to the forge until [`sync`](Self::sync).
    pub fn open(number: u64, ports: Ports) -> Result<Self> {
        let saved = ports.store.load()?;
        let sync = saved
            .session
            .last_synced_at
            .map_or(SyncState::Never, |at| SyncState::Synced { at });
        Ok(Self {
            number,
            ports,
            saved,
            threads: Vec::new(),
            sync,
            subscribers: Vec::new(),
        })
    }

    /// Records the process serving this session, so others can find it.
    pub fn record_daemon(&mut self, pid: u32, worktree: &str) -> Result<()> {
        self.saved.session.pid = Some(pid);
        self.saved.session.worktree = Some(worktree.to_owned());
        self.ports.store.save(&self.saved)
    }

    /// A channel that receives every later [`Event`].
    pub fn subscribe(&mut self) -> Receiver<Event> {
        let (sender, receiver) = mpsc::channel();
        self.subscribers.push(sender);
        receiver
    }

    /// The current status view.
    #[must_use]
    pub fn view(&self) -> SessionView {
        session_view(
            self.saved.session.pr.as_ref(),
            &self.saved.files,
            &self.threads,
            &self.sync,
        )
    }

    fn publish(&mut self, event: &Event) {
        self.subscribers
            .retain(|subscriber| subscriber.send(event.clone()).is_ok());
    }
}

#[cfg(test)]
mod tests {
    use review_model::SyncState;

    use super::test_support::Fakes;

    #[test]
    fn a_new_session_has_not_synced() {
        let view = Fakes::new(10).open().view();
        assert_eq!(view.sync, SyncState::Never);
        assert!(view.pr.is_none());
        assert!(view.files.is_empty());
    }

    #[test]
    fn record_daemon_saves_the_pid_and_worktree() {
        let fakes = Fakes::new(1);
        fakes
            .open()
            .record_daemon(4242, "/tmp/widgets-worktrees/pr-7")
            .expect("it saves");
        let saved = fakes.store.saved();
        assert_eq!(saved.session.pid, Some(4242));
        assert_eq!(
            saved.session.worktree.as_deref(),
            Some("/tmp/widgets-worktrees/pr-7")
        );
    }

    #[test]
    fn a_dropped_subscriber_does_not_stop_the_others() {
        let mut session = Fakes::new(1).open();
        drop(session.subscribe());
        let events = session.subscribe();
        session.sync().expect("the sync succeeds");
        assert!(events.try_recv().is_ok());
    }
}
```

- [ ] **Step 3: Create `session/test_support.rs`**

```rust
//! Fixtures shared by the session's tests: a session over fakes that the
//! test keeps handles to.

use review_model::ViewedState;

use super::ReviewSession;
use crate::fakes::{
    FakeForge, FakeWorkspace, FixedClock, MemoryStore, changed_file, fake_ports, github_thread,
    sample_pr,
};
use crate::ports::ForgeSnapshot;

/// The fakes behind a test session. Each is a handle that shares state with
/// the session's copy, so a test steers and inspects them.
#[derive(Clone, Default)]
pub struct Fakes {
    pub forge: FakeForge,
    pub store: MemoryStore,
    pub workspace: FakeWorkspace,
    pub clock: FixedClock,
}

impl Fakes {
    /// Fakes at time `now` whose forge reports [`snapshot`] for the sample
    /// pull request.
    pub fn new(now: u64) -> Self {
        Self {
            forge: FakeForge::new(sample_pr(), snapshot()),
            clock: FixedClock::at(now),
            ..Self::default()
        }
    }

    /// A session for pull request 7 over these fakes.
    pub fn open(&self) -> ReviewSession {
        let ports = fake_ports(&self.forge, &self.store, &self.workspace, &self.clock);
        ReviewSession::open(7, ports).expect("the session opens")
    }

    /// A session for pull request 7 over these fakes, synced once.
    pub fn synced(&self) -> ReviewSession {
        let mut session = self.open();
        session.sync().expect("the sync succeeds");
        session
    }
}

/// What the fake forge reports: one thread, a viewed `src/a.rs` and an
/// unviewed `src/b.rs`.
pub fn snapshot() -> ForgeSnapshot {
    ForgeSnapshot {
        head_sha: "abc123".into(),
        has_pending_review: false,
        threads: vec![github_thread("T1", "src/a.rs")],
        files: vec![
            changed_file("src/a.rs", ViewedState::Viewed),
            changed_file("src/b.rs", ViewedState::Unviewed),
        ],
    }
}
```

- [ ] **Step 4: Create `session/sync.rs`**

```rust
//! Pulling the pull request from the forge.

use anyhow::Result;
use review_model::{Event, PullRequest, SessionView, SyncState};

use super::ReviewSession;
use crate::ports::ForgeSnapshot;

impl ReviewSession {
    /// Pulls the pull request from the forge, saves it, and announces it. A
    /// failure keeps the previous view, announces the failure, and saves
    /// nothing.
    pub fn sync(&mut self) -> Result<SessionView> {
        let now = self.ports.clock.now();
        match self.pull() {
            Ok((pr, snapshot)) => self.apply_pull(pr, snapshot, now),
            Err(error) => {
                let message = format!("{error:#}");
                self.sync = SyncState::Failed {
                    at: now,
                    message: message.clone(),
                };
                self.publish(&Event::SyncFailed { message });
                Err(error)
            }
        }
    }

    fn pull(&self) -> Result<(PullRequest, ForgeSnapshot)> {
        let pr = self.ports.forge.pull_request(self.number)?;
        let snapshot = self.ports.forge.fetch(&pr)?;
        Ok((pr, snapshot))
    }

    /// Keeps what a successful pull reported, saves it, and announces it.
    fn apply_pull(
        &mut self,
        pr: PullRequest,
        snapshot: ForgeSnapshot,
        now: u64,
    ) -> Result<SessionView> {
        self.saved.session.pr = Some(pr);
        self.saved.session.last_synced_at = Some(now);
        self.saved.files = snapshot.files;
        self.threads = snapshot.threads;
        self.sync = SyncState::Synced { at: now };
        self.ports.store.save(&self.saved)?;
        let view = self.view();
        self.publish(&Event::Synced {
            view: Box::new(view.clone()),
        });
        Ok(view)
    }
}

#[cfg(test)]
mod tests {
    use review_model::{Event, SyncState, ViewedState};

    use super::super::test_support::{Fakes, snapshot};

    #[test]
    fn sync_pulls_saves_and_announces() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open();
        let events = session.subscribe();
        let view = session.sync().expect("the sync succeeds");
        assert_eq!(view.files.len(), 2);
        assert_eq!(view.thread_count, 1);
        assert_eq!(view.viewed_count, 1);
        assert_eq!(view.sync, SyncState::Synced { at: 100 });
        let saved = fakes.store.saved();
        assert_eq!(saved.session.pr.map(|pr| pr.number), Some(7));
        assert_eq!(saved.session.last_synced_at, Some(100));
        assert_eq!(saved.files.len(), 2);
        assert_eq!(
            events.try_recv().expect("an event was sent"),
            Event::Synced {
                view: Box::new(view)
            }
        );
    }

    #[test]
    fn a_reopened_session_shows_the_saved_files_before_syncing() {
        let fakes = Fakes::new(100);
        fakes.synced();
        let view = fakes.open().view();
        assert_eq!(view.files.len(), 2);
        assert_eq!(
            view.pr.map(|pr| pr.title),
            Some("Fix the widget".to_owned())
        );
        assert_eq!(view.sync, SyncState::Synced { at: 100 });
    }

    #[test]
    fn a_failed_sync_keeps_the_last_view_and_announces_the_failure() {
        let fakes = Fakes::new(100);
        let mut session = fakes.synced();
        let events = session.subscribe();
        fakes.forge.fail_with(Some("gh timed out after 30s"));
        fakes.clock.set(160);
        let error = session.sync().expect_err("the forge fails");
        assert!(error.to_string().contains("timed out"));
        let view = session.view();
        assert_eq!(view.files.len(), 2, "the last synced files are kept");
        assert_eq!(
            view.sync,
            SyncState::Failed {
                at: 160,
                message: "gh timed out after 30s".into()
            }
        );
        assert_eq!(
            events.try_recv().expect("an event was sent"),
            Event::SyncFailed {
                message: "gh timed out after 30s".into()
            }
        );
        assert_eq!(
            fakes.store.saved().session.last_synced_at,
            Some(100),
            "a failure saves nothing"
        );
    }

    #[test]
    fn github_resetting_a_viewed_file_reaches_the_view() {
        let fakes = Fakes::new(1);
        let mut session = fakes.synced();
        let mut changed = snapshot();
        changed.files[0].viewed = ViewedState::Dismissed;
        fakes.forge.set_snapshot(changed);
        let view = session.sync().expect("the second sync succeeds");
        assert_eq!(view.files[0].viewed, ViewedState::Dismissed);
        assert_eq!(view.viewed_count, 0);
    }
}
```

- [ ] **Step 5: Update the callers of `ReviewSession::open`**

`crates/review-rpc/tests/serve.rs`: import `FakeWorkspace` and `fake_ports` from `review_core::fakes`, and replace `session`:

```rust
/// A checkout where `src/a.rs` gained a body since the merge base.
fn workspace() -> FakeWorkspace {
    let workspace = FakeWorkspace::default();
    workspace.put_base("src/a.rs", "fn a() {}\n");
    workspace.put_disk("src/a.rs", "fn a() { 1 }\n");
    workspace
}

fn session(forge: &FakeForge) -> Arc<Mutex<ReviewSession>> {
    let ports = fake_ports(
        forge,
        &MemoryStore::default(),
        &workspace(),
        &FixedClock::at(100),
    );
    Arc::new(Mutex::new(ReviewSession::open(7, ports).unwrap()))
}
```

`crates/jpr-review/src/commands/serve.rs`: import `review_core::ports::{Ports, SystemClock}` and `review_workspace_git::GitWorkspace`, and build the session with:

```rust
    let ports = Ports {
        forge: Box::new(GhForge::new(cwd.clone(), Some(repo.to_owned()))),
        store: Box::new(FsStore::new(super::state_dir(&owner, &name, number)?)),
        workspace: Box::new(GitWorkspace::new(cwd.clone())),
        clock: Box::new(SystemClock),
    };
    let mut session = ReviewSession::open(number, ports)?;
```

(removing the separate `store` and `forge` bindings above it).

- [ ] **Step 6: Run the tests**

Run: `cargo test --workspace --all-features`
Expected: PASS, with the same session tests as before under their new modules.

- [ ] **Step 7: Gate and commit**

```bash
just check
git add -A crates
git commit -m "refactor(core): open sessions on Ports and split the session by use case"
```

---
### Task 11: The session's diffs (`file_diff` and `stream`)

**Files:**
- Modify: `crates/review-core/Cargo.toml`
- Create: `crates/review-core/src/session/diffs.rs`
- Modify: `crates/review-core/src/session/mod.rs`

The base side is the merge base of the pull request's base commit and the checked-out head, found once per base commit and cached with every base text read since. A renamed file is compared with its old name. The current side is the file on disk, so local edits show as part of the change.

- [ ] **Step 1: Add the dependency**

In `crates/review-core/Cargo.toml`, add to `[dependencies]`:

```toml
review-diff.workspace = true
```

- [ ] **Step 2: Write the failing tests**

Create `crates/review-core/src/session/diffs.rs` with only the tests:

```rust
//! The two sides of every diff: the base from git, the current file from disk.

#[cfg(test)]
mod tests {
    use review_model::{StreamRow, ViewMode};

    use super::super::test_support::Fakes;

    /// Fakes where `src/a.rs` changed its second line and `src/b.rs` did not.
    fn fakes() -> Fakes {
        let fakes = Fakes::new(100);
        fakes.workspace.put_base("src/a.rs", "one\ntwo\n");
        fakes.workspace.put_disk("src/a.rs", "one\n2\n");
        fakes.workspace.put_base("src/b.rs", "b\n");
        fakes.workspace.put_disk("src/b.rs", "b\n");
        fakes
    }

    #[test]
    fn a_file_diff_compares_the_merge_base_with_the_disk() {
        let mut session = fakes().synced();
        let diff = session.file_diff("src/a.rs").unwrap();
        let added: Vec<u64> = diff.added.iter().map(|line| line.line).collect();
        assert_eq!(added, [2]);
        assert_eq!(diff.removed[0].lines[0].text, "two");
        assert_eq!(diff.base_text.as_deref(), Some("one\ntwo\n"));
    }

    #[test]
    fn only_changed_files_have_diffs() {
        let mut session = fakes().synced();
        let error = session.file_diff("../../etc/passwd").unwrap_err();
        assert!(
            error.to_string().contains("not a file this pull request changes"),
            "{error}"
        );
    }

    #[test]
    fn a_renamed_file_is_compared_with_its_old_name() {
        let fakes = Fakes::new(100);
        fakes.workspace.rename("src/old.rs", "src/a.rs");
        fakes.workspace.put_base("src/old.rs", "same\n");
        fakes.workspace.put_disk("src/a.rs", "same\n");
        let diff = fakes.synced().file_diff("src/a.rs").unwrap();
        assert!(diff.added.is_empty() && diff.removed.is_empty(), "{diff:?}");
    }

    #[test]
    fn the_merge_base_is_looked_up_once_per_base_commit() {
        let fakes = fakes();
        let mut session = fakes.synced();
        session.file_diff("src/a.rs").unwrap();
        session.stream(ViewMode::Unified).unwrap();
        assert_eq!(fakes.workspace.merge_base_calls(), 1);
    }

    #[test]
    fn the_stream_has_every_file_in_order_with_viewed_files_folded() {
        let stream = fakes().synced().stream(ViewMode::Split).unwrap();
        let headers: Vec<(&str, bool)> = stream
            .rows
            .iter()
            .filter_map(|row| match row {
                StreamRow::File { path, folded, .. } => Some((path.as_str(), *folded)),
                _ => None,
            })
            .collect();
        assert_eq!(headers, [("src/a.rs", true), ("src/b.rs", false)]);
        assert_eq!(stream.mode, ViewMode::Split);
    }

    #[test]
    fn diffs_wait_for_the_first_sync() {
        let error = fakes().open().stream(ViewMode::Unified).unwrap_err();
        assert!(error.to_string().contains("not synced"), "{error}");
    }

    #[test]
    fn a_merge_base_failure_fails_the_stream() {
        let fakes = fakes();
        let mut session = fakes.synced();
        fakes.workspace.fail_with(Some("fetching the base commit failed"));
        let error = session.stream(ViewMode::Unified).unwrap_err();
        assert!(error.to_string().contains("fetching"), "{error}");
    }
}
```

In `crates/review-core/src/session/mod.rs`, add `mod diffs;` above `mod sync;`.

- [ ] **Step 3: Run the tests to see them fail**

Run: `cargo test -p review-core --all-features`
Expected: FAIL to compile: no method `file_diff` or `stream` on `ReviewSession`.

- [ ] **Step 4: Give the session a base cache and `synced_pr`**

In `crates/review-core/src/session/mod.rs`:

- change the anyhow import to `use anyhow::{Context, Result};` and add `PullRequest` to the `review_model` import;
- add `use diffs::BaseCache;` after the `mod` lines;
- add the field `bases: BaseCache,` at the end of `ReviewSession` and `bases: BaseCache::default(),` in `open`;
- add to `impl ReviewSession`, above `publish`:

```rust
    /// The pull request as last synced, for use cases that need it.
    fn synced_pr(&self) -> Result<&PullRequest> {
        self.saved
            .session
            .pr
            .as_ref()
            .context("the pull request has not synced with GitHub yet")
    }
```

- [ ] **Step 5: Implement the use cases**

Put this above the tests in `crates/review-core/src/session/diffs.rs`:

```rust
use std::collections::HashMap;

use anyhow::{Result, bail};
use review_diff::{FileText, StreamInput, file_diff_view, stream_view};
use review_model::{FileDiffView, StreamView, ViewMode};

use super::ReviewSession;

/// The base side of the diffs, kept while the pull request's base commit
/// stays the same: its merge base, the renames since it, and the base texts
/// read so far.
#[derive(Debug, Default)]
pub(super) struct BaseCache {
    base_sha: String,
    merge_base: String,
    /// New path to old path, for files renamed since the merge base.
    renamed_from: HashMap<String, String>,
    texts: HashMap<String, FileText>,
}

impl ReviewSession {
    /// One changed file's diff, for a frontend that draws it on the file
    /// itself or beside its base.
    pub fn file_diff(&mut self, path: &str) -> Result<FileDiffView> {
        let (base, current) = self.file_texts(path)?;
        Ok(file_diff_view(path, &base, &current))
    }

    /// Every changed file's hunks, in the forge's order, laid out for
    /// `mode`. A file that cannot be read gets a note rather than failing
    /// the whole stream.
    pub fn stream(&mut self, mode: ViewMode) -> Result<StreamView> {
        self.prepare_base()?;
        let files = self.saved.files.clone();
        let mut inputs = Vec::with_capacity(files.len());
        for file in files {
            let content = self
                .file_texts(&file.path)
                .map_err(|error| format!("{error:#}"));
            inputs.push(StreamInput { file, content });
        }
        Ok(stream_view(&inputs, mode))
    }

    /// The base and current text of `path`, which must be a file the pull
    /// request changes: the forge's list is the only way in, so a path
    /// from anywhere else is refused before the disk is touched.
    fn file_texts(&mut self, path: &str) -> Result<(FileText, FileText)> {
        if !self.saved.files.iter().any(|file| file.path == path) {
            bail!("{path} is not a file this pull request changes");
        }
        let base = self.base_text(path)?;
        let current = FileText::from_bytes(self.ports.workspace.file_on_disk(path)?);
        Ok((base, current))
    }

    /// `path` at the merge base, under its old name when it was renamed.
    fn base_text(&mut self, path: &str) -> Result<FileText> {
        self.prepare_base()?;
        if let Some(text) = self.bases.texts.get(path) {
            return Ok(text.clone());
        }
        let old_path = self
            .bases
            .renamed_from
            .get(path)
            .map_or(path, String::as_str);
        let bytes = self
            .ports
            .workspace
            .file_at(&self.bases.merge_base, old_path)?;
        let text = FileText::from_bytes(bytes);
        self.bases.texts.insert(path.to_owned(), text.clone());
        Ok(text)
    }

    /// Finds the merge base for the pull request's base commit, unless it is
    /// already known, and starts a fresh cache for it.
    fn prepare_base(&mut self) -> Result<()> {
        let base_sha = self.synced_pr()?.base_sha.clone();
        if base_sha.is_empty() {
            bail!("the base commit is not known yet; sync with GitHub first");
        }
        if !self.bases.merge_base.is_empty() && self.bases.base_sha == base_sha {
            return Ok(());
        }
        let merge_base = self.ports.workspace.merge_base(&base_sha)?;
        let renamed_from = self
            .ports
            .workspace
            .renames(&merge_base)?
            .into_iter()
            .map(|(old, new)| (new, old))
            .collect();
        self.bases = BaseCache {
            base_sha,
            merge_base,
            renamed_from,
            texts: HashMap::new(),
        };
        Ok(())
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `cargo test -p review-core --all-features`
Expected: PASS.

- [ ] **Step 7: Gate and commit**

```bash
just check
git add crates/review-core Cargo.lock
git commit -m "feat(core): diff each changed file against the merge base"
```

---

### Task 12: `Forge::set_viewed`

**Files:**
- Modify: `crates/review-core/src/ports.rs`, `crates/review-core/src/fakes.rs`
- Modify: `crates/review-forge-github/src/graphql.rs`, `crates/review-forge-github/src/lib.rs`

Marking a file viewed reaches GitHub at once, one call per file, through `markFileAsViewed` and `unmarkFileAsViewed` (the same mutations dif uses).

- [ ] **Step 1: Write the failing tests**

Add to the tests in `crates/review-core/src/fakes.rs`:

```rust
    #[test]
    fn the_fake_forge_records_viewed_marks_and_can_refuse_them() {
        let forge = FakeForge::new(sample_pr(), ForgeSnapshot {
            files: vec![changed_file("a.rs", ViewedState::Unviewed)],
            ..ForgeSnapshot::default()
        });
        forge.set_viewed(&sample_pr(), "a.rs", true).unwrap();
        assert_eq!(forge.viewed_calls(), [("a.rs".to_owned(), true)]);
        let fetched = forge.fetch(&sample_pr()).unwrap();
        assert_eq!(fetched.files[0].viewed, ViewedState::Viewed, "the forge remembers the mark");
        forge.fail_writes_with(Some("offline"));
        assert!(forge.set_viewed(&sample_pr(), "a.rs", false).is_err());
        assert!(forge.fetch(&sample_pr()).is_ok(), "reads still work");
        assert_eq!(forge.viewed_calls().len(), 1);
    }
```

Add to the tests in `crates/review-forge-github/src/graphql.rs`:

```rust
    #[test]
    fn viewed_marks_use_github_s_viewed_mutations() {
        assert!(viewed_mutation(true).contains("markFileAsViewed"));
        assert!(!viewed_mutation(true).contains("unmark"));
        assert!(viewed_mutation(false).contains("unmarkFileAsViewed"));
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cargo test --workspace --all-features`
Expected: FAIL to compile: no `set_viewed`, `viewed_calls`, `fail_writes_with`, `viewed_mutation`.

- [ ] **Step 3: Add the port method**

In `crates/review-core/src/ports.rs`, add to the `Forge` trait:

```rust
    /// Marks `path` viewed (`true`) or unviewed (`false`) for the reviewer on
    /// the forge, at once.
    fn set_viewed(&self, pr: &PullRequest, path: &str, viewed: bool) -> Result<()>;
```

- [ ] **Step 4: Implement it in the fake**

In `crates/review-core/src/fakes.rs`, add two fields to `ForgeState`:

```rust
    write_failure: Option<String>,
    viewed_calls: Vec<(String, bool)>,
```

add to `impl FakeForge`:

```rust
    /// Makes every later write fail with `message` while reads still work, or
    /// lets writes succeed again with `None`. A forge that answers reads but
    /// refuses writes is how a queued change is tested.
    pub fn fail_writes_with(&self, message: Option<&str>) {
        self.lock().write_failure = message.map(str::to_owned);
    }

    /// Every viewed mark the forge accepted, in order.
    #[must_use]
    pub fn viewed_calls(&self) -> Vec<(String, bool)> {
        self.lock().viewed_calls.clone()
    }
```

and to `impl Forge for FakeForge` (import `crate::viewed::viewed_state`, which Task 13 adds; until then write the match inline as below):

```rust
    fn set_viewed(&self, _pr: &PullRequest, path: &str, viewed: bool) -> Result<()> {
        let mut state = self.lock();
        if let Some(message) = state.failure.as_ref().or(state.write_failure.as_ref()) {
            return Err(anyhow!("{message}"));
        }
        state.viewed_calls.push((path.to_owned(), viewed));
        let marked = if viewed {
            ViewedState::Viewed
        } else {
            ViewedState::Unviewed
        };
        for file in &mut state.snapshot.files {
            if file.path == path {
                file.viewed = marked;
            }
        }
        Ok(())
    }
```

- [ ] **Step 5: Implement it for GitHub**

In `crates/review-forge-github/src/graphql.rs`, after `FILES`:

```rust
/// Marks `$path` viewed by the viewer.
pub const MARK_VIEWED: &str = r"mutation($pr: ID!, $path: String!) {
  markFileAsViewed(input: { pullRequestId: $pr, path: $path }) { clientMutationId }
}";

/// Clears the viewer's viewed mark on `$path`.
pub const UNMARK_VIEWED: &str = r"mutation($pr: ID!, $path: String!) {
  unmarkFileAsViewed(input: { pullRequestId: $pr, path: $path }) { clientMutationId }
}";

/// The mutation that marks a file viewed (`true`) or clears the mark.
#[must_use]
pub const fn viewed_mutation(viewed: bool) -> &'static str {
    if viewed { MARK_VIEWED } else { UNMARK_VIEWED }
}
```

In `crates/review-forge-github/src/lib.rs`, change the import to `use anyhow::{Context, Result};` and add to `impl Forge for GhForge`:

```rust
    fn set_viewed(&self, pr: &PullRequest, path: &str, viewed: bool) -> Result<()> {
        let mark = if viewed { "viewed" } else { "unviewed" };
        self.graphql(
            graphql::viewed_mutation(viewed),
            &json!({ "pr": pr.node_id, "path": path }),
        )
        .with_context(|| format!("marking {path} {mark} on GitHub"))?;
        Ok(())
    }
```

Update the crate doc to mention the mutations: `//! The GitHub forge: gh pr view for the pull request, gh api graphql for threads, files and viewed state, and the viewed mutations.`

- [ ] **Step 6: Run the tests**

Run: `cargo test --workspace --all-features`
Expected: PASS.

- [ ] **Step 7: Gate and commit**

```bash
just check
git add crates
git commit -m "feat: mark files viewed on the forge (Forge::set_viewed)"
```

---

### Task 13: Viewed marks in the session, with the queue

**Files:**
- Create: `crates/review-core/src/viewed.rs`, `crates/review-core/src/session/viewed.rs`
- Modify: `crates/review-core/src/lib.rs`, `src/session/mod.rs`, `src/session/sync.rs`, `src/presenter.rs`, `src/fakes.rs`
- Modify: `crates/review-model/src/view.rs`

The rules, from the spec and dif: a mark takes effect here at once and reaches GitHub at once; if GitHub refuses, the mark stands here and is queued; every sync first sends the queue (stopping at the first failure, since the rest would most likely time out the same way) and then lets any mark still queued win over what it pulled; a successful send announces `ViewedChanged`.

- [ ] **Step 1: Add the event and the count to the model**

In `crates/review-model/src/view.rs`, add to `SessionView` (after `thread_count`):

```rust
    /// Viewed marks waiting to reach the forge.
    pub queued_count: usize,
```

add to `Event` (after `SyncFailed`):

```rust
    /// A file was marked viewed or unviewed, or a queued mark reached the
    /// forge.
    ViewedChanged {
        /// The new state.
        view: Box<SessionView>,
    },
```

and, in the test `events_are_tagged_by_type_and_views_use_camel_case`, add `queued_count: 2,` to the `SessionView` literal and `assert_eq!(json["view"]["queuedCount"], 2);`.

- [ ] **Step 2: Write the failing tests for the pure rules**

Create `crates/review-core/src/viewed.rs`:

```rust
//! The viewed rules: what a mark means, and how a queued mark wins over a
//! pull.

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use review_model::ViewedState;

    use super::*;
    use crate::fakes::changed_file;

    #[test]
    fn a_mark_is_viewed_or_unviewed() {
        assert_eq!(viewed_state(true), ViewedState::Viewed);
        assert_eq!(viewed_state(false), ViewedState::Unviewed);
    }

    #[test]
    fn a_queued_mark_wins_over_the_pulled_state() {
        let mut files = vec![
            changed_file("a.rs", ViewedState::Viewed),
            changed_file("b.rs", ViewedState::Dismissed),
            changed_file("c.rs", ViewedState::Viewed),
        ];
        let queued = BTreeMap::from([("a.rs".to_owned(), false), ("b.rs".to_owned(), true)]);
        apply_queued(&mut files, &queued);
        let states: Vec<ViewedState> = files.iter().map(|file| file.viewed).collect();
        assert_eq!(
            states,
            [ViewedState::Unviewed, ViewedState::Viewed, ViewedState::Viewed]
        );
    }
}
```

Add `mod viewed;` to `crates/review-core/src/lib.rs` (after `mod session;`).

- [ ] **Step 3: Write the failing session tests**

Create `crates/review-core/src/session/viewed.rs` with only the tests:

```rust
//! Marking files viewed, and the queue of marks the forge has not accepted.

#[cfg(test)]
mod tests {
    use review_model::{Event, ViewedState};

    use super::super::test_support::{Fakes, snapshot};

    #[test]
    fn marking_a_file_viewed_reaches_the_forge_and_is_announced() {
        let fakes = Fakes::new(100);
        let mut session = fakes.synced();
        let events = session.subscribe();
        let view = session.set_viewed("src/b.rs", true).unwrap();
        assert_eq!(fakes.forge.viewed_calls(), [("src/b.rs".to_owned(), true)]);
        assert_eq!(view.files[1].viewed, ViewedState::Viewed);
        assert_eq!(view.viewed_count, 2);
        assert_eq!(fakes.store.saved().files[1].viewed, ViewedState::Viewed);
        assert_eq!(
            events.try_recv().unwrap(),
            Event::ViewedChanged {
                view: Box::new(view)
            }
        );
    }

    #[test]
    fn a_dismissed_file_marked_viewed_counts_as_viewed() {
        let fakes = Fakes::new(100);
        let mut changed = snapshot();
        changed.files[1].viewed = ViewedState::Dismissed;
        fakes.forge.set_snapshot(changed);
        let mut session = fakes.synced();
        assert_eq!(session.set_viewed("src/b.rs", true).unwrap().viewed_count, 2);
    }

    #[test]
    fn a_mark_the_forge_refuses_stands_here_and_is_queued() {
        let fakes = Fakes::new(100);
        let mut session = fakes.synced();
        fakes.forge.fail_writes_with(Some("offline"));
        let view = session.set_viewed("src/a.rs", false).unwrap();
        assert_eq!(view.files[0].viewed, ViewedState::Unviewed);
        assert_eq!(view.queued_count, 1);
        assert!(session.has_queued());
        assert_eq!(
            fakes.store.saved().registry.queued_viewed.get("src/a.rs"),
            Some(&false)
        );
    }

    #[test]
    fn a_queued_mark_survives_a_pull_until_it_lands() {
        let fakes = Fakes::new(100);
        let mut session = fakes.synced();
        fakes.forge.fail_writes_with(Some("offline"));
        session.set_viewed("src/a.rs", false).unwrap();
        let view = session.sync().unwrap();
        assert_eq!(
            view.files[0].viewed,
            ViewedState::Unviewed,
            "the forge still says viewed, but the queued mark wins"
        );
        fakes.forge.fail_writes_with(None);
        let view = session.sync().unwrap();
        assert_eq!(fakes.forge.viewed_calls(), [("src/a.rs".to_owned(), false)]);
        assert_eq!(view.files[0].viewed, ViewedState::Unviewed);
        assert_eq!(view.queued_count, 0);
    }

    #[test]
    fn a_flush_announces_only_when_a_mark_landed() {
        let fakes = Fakes::new(100);
        let mut session = fakes.synced();
        fakes.forge.fail_writes_with(Some("offline"));
        session.set_viewed("src/a.rs", false).unwrap();
        let events = session.subscribe();
        assert!(!session.flush_queued().unwrap(), "still offline");
        assert!(events.try_recv().is_err());
        fakes.forge.fail_writes_with(None);
        assert!(session.flush_queued().unwrap());
        assert!(!session.has_queued());
        assert!(matches!(events.try_recv().unwrap(), Event::ViewedChanged { .. }));
    }

    #[test]
    fn only_changed_files_can_be_marked() {
        let mut session = Fakes::new(100).synced();
        assert!(session.set_viewed("nope.rs", true).is_err());
    }

    #[test]
    fn marking_waits_for_the_first_sync() {
        assert!(Fakes::new(1).open().set_viewed("src/a.rs", true).is_err());
    }
}
```

Add `mod viewed;` to `crates/review-core/src/session/mod.rs` (after `mod test_support;`).

- [ ] **Step 4: Run the tests to see them fail**

Run: `cargo test --workspace --all-features`
Expected: FAIL to compile: no `viewed_state`, `apply_queued`, `set_viewed`, `has_queued`, `flush_queued`, and `SessionView` is missing `queued_count` in the presenter.

- [ ] **Step 5: Implement the pure rules**

Put this above the tests in `crates/review-core/src/viewed.rs`:

```rust
use std::collections::BTreeMap;

use review_model::{ChangedFile, ViewedState};

/// The state a file is in once marked viewed (`true`) or unviewed (`false`).
#[must_use]
pub const fn viewed_state(viewed: bool) -> ViewedState {
    if viewed {
        ViewedState::Viewed
    } else {
        ViewedState::Unviewed
    }
}

/// Applies the marks still queued for the forge to files just pulled from
/// it, so a pull taken before a mark lands does not undo the mark.
pub fn apply_queued(files: &mut [ChangedFile], queued: &BTreeMap<String, bool>) {
    for file in files {
        if let Some(viewed) = queued.get(&file.path) {
            file.viewed = viewed_state(*viewed);
        }
    }
}
```

In `crates/review-core/src/fakes.rs`, replace the inline `let marked = if viewed { ... }` from Task 12 with `let marked = crate::viewed::viewed_state(viewed);`.

- [ ] **Step 6: Count the queue in the view**

In `crates/review-core/src/presenter.rs`, give `session_view` a fifth parameter and set the field:

```rust
pub fn session_view(
    pr: Option<&PullRequest>,
    files: &[ChangedFile],
    threads: &[Thread],
    sync: &SyncState,
    queued_count: usize,
) -> SessionView {
```

```rust
        queued_count,
```

(add `queued_count` to the `SessionView { ... }` literal, after `thread_count`), and pass `0` in the two presenter tests. In `crates/review-core/src/session/mod.rs`, pass the queue length from `view()`:

```rust
        session_view(
            self.saved.session.pr.as_ref(),
            &self.saved.files,
            &self.threads,
            &self.sync,
            self.saved.registry.queued_viewed.len(),
        )
```

- [ ] **Step 7: Implement the session use cases**

Put this above the tests in `crates/review-core/src/session/viewed.rs`:

```rust
use anyhow::{Context, Result};
use review_model::{Event, SessionView};

use super::ReviewSession;
use crate::viewed::viewed_state;

impl ReviewSession {
    /// Marks `path` viewed (`true`) or unviewed (`false`), here and on the
    /// forge. When the forge cannot take it, the mark stands here and is
    /// queued until a later sync or retry delivers it.
    pub fn set_viewed(&mut self, path: &str, viewed: bool) -> Result<SessionView> {
        let pr = self.synced_pr()?.clone();
        let file = self
            .saved
            .files
            .iter_mut()
            .find(|file| file.path == path)
            .with_context(|| format!("{path} is not a file this pull request changes"))?;
        file.viewed = viewed_state(viewed);
        let queue = &mut self.saved.registry.queued_viewed;
        if self.ports.forge.set_viewed(&pr, path, viewed).is_ok() {
            queue.remove(path);
        } else {
            queue.insert(path.to_owned(), viewed);
        }
        self.save_and_announce_viewed()
    }

    /// Whether any viewed mark is waiting for the forge, so a server knows
    /// to retry before the next sync.
    #[must_use]
    pub fn has_queued(&self) -> bool {
        !self.saved.registry.queued_viewed.is_empty()
    }

    /// Sends the queued viewed marks again, and saves and announces it when
    /// any got through. Returns whether any did.
    pub fn flush_queued(&mut self) -> Result<bool> {
        if !self.send_queued() {
            return Ok(false);
        }
        self.save_and_announce_viewed()?;
        Ok(true)
    }

    /// Sends the queued marks in path order until one fails, dropping each
    /// one that lands, and returns whether any landed. It stops at the
    /// first failure because the rest would most likely time out the same
    /// way.
    pub(super) fn send_queued(&mut self) -> bool {
        let Some(pr) = self.saved.session.pr.clone() else {
            return false;
        };
        let mut has_landed = false;
        for (path, viewed) in self.saved.registry.queued_viewed.clone() {
            if self.ports.forge.set_viewed(&pr, &path, viewed).is_err() {
                break;
            }
            self.saved.registry.queued_viewed.remove(&path);
            has_landed = true;
        }
        has_landed
    }

    fn save_and_announce_viewed(&mut self) -> Result<SessionView> {
        self.ports.store.save(&self.saved)?;
        let view = self.view();
        self.publish(&Event::ViewedChanged {
            view: Box::new(view.clone()),
        });
        Ok(view)
    }
}
```

- [ ] **Step 8: Send the queue before every pull, and let it win after**

In `crates/review-core/src/session/sync.rs`, import `crate::viewed::apply_queued`, and:

- at the top of `sync()`, after `let now = ...;`, add:

```rust
        // Marks that land now are reflected by the pull that follows.
        self.send_queued();
```

- in `apply_pull`, take `mut snapshot` and, before `self.saved.files = snapshot.files;`, add:

```rust
        apply_queued(&mut snapshot.files, &self.saved.registry.queued_viewed);
```

- [ ] **Step 9: Run the tests**

Run: `cargo test --workspace --all-features`
Expected: PASS.

- [ ] **Step 10: Gate and commit**

```bash
just check
git add crates
git commit -m "feat(core): mark files viewed, queueing marks GitHub refuses"
```

---

### Task 14: The file tree in `SessionView`

**Files:**
- Create: `crates/review-core/src/tree.rs`
- Modify: `crates/review-core/src/lib.rs`, `src/presenter.rs`
- Modify: `crates/review-model/src/view.rs`, `crates/review-model/src/lib.rs`

The panel draws the changed files as a tree: directories first, then files, each sorted by name, with a directory that holds only one directory joined to it (`docs/x`). Each file row points at its index in `files`, so a frontend reads the counts from the row it already has.

- [ ] **Step 1: Add `TreeRow` to the model**

In `crates/review-model/src/view.rs`, add above `SessionView`:

```rust
/// One row of the changed files drawn as a tree: a directory, or a file of
/// [`SessionView::files`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TreeRow {
    /// How deep the row is nested; top-level rows are 0.
    pub depth: usize,
    /// A directory's path below its parent row (a directory holding only
    /// one directory is joined to it, as in `src/core`), or a file's name.
    pub name: String,
    /// A file's index in `SessionView::files`; `None` for a directory.
    pub file: Option<usize>,
}
```

add to `SessionView`, after `files`:

```rust
    /// The changed files as a tree, for a file panel.
    pub tree: Vec<TreeRow>,
```

add `tree: Vec::new(),` to the `SessionView` literal in the view test, and export `TreeRow` from `crates/review-model/src/lib.rs`:

```rust
pub use view::{Event, FileRow, SessionView, SyncState, TreeRow};
```

- [ ] **Step 2: Write the failing tests**

Create `crates/review-core/src/tree.rs`:

```rust
//! The changed files as a tree: directories first, then files, each sorted
//! by name, with a directory that holds only one directory joined to it.

#[cfg(test)]
mod tests {
    use super::*;

    fn sketch(rows: &[TreeRow]) -> Vec<String> {
        rows.iter()
            .map(|row| {
                let suffix = row
                    .file
                    .map_or_else(|| "/".to_owned(), |index| format!(" #{index}"));
                format!("{}{}{suffix}", "  ".repeat(row.depth), row.name)
            })
            .collect()
    }

    #[test]
    fn directories_come_first_and_lone_directories_join() {
        let rows = file_tree(["src/a.rs", "src/core/b.rs", "src/core/c.rs", "README.md", "docs/x/y.md"]);
        assert_eq!(
            sketch(&rows),
            [
                "docs/x/",
                "  y.md #4",
                "src/",
                "  core/",
                "    b.rs #1",
                "    c.rs #2",
                "  a.rs #0",
                "README.md #3",
            ]
        );
    }

    #[test]
    fn no_files_is_no_rows() {
        assert!(file_tree([]).is_empty());
    }
}
```

Add `mod tree;` to `crates/review-core/src/lib.rs`.

- [ ] **Step 3: Run the tests to see them fail**

Run: `cargo test -p review-core --all-features`
Expected: FAIL to compile: no `file_tree`; the presenter does not set `tree`.

- [ ] **Step 4: Implement the tree**

Put this above the tests in `crates/review-core/src/tree.rs`:

```rust
use std::collections::BTreeMap;

use review_model::TreeRow;

/// The tree rows for `paths`, in which each file row points back at its
/// index in `paths`.
#[must_use]
pub fn file_tree<'a>(paths: impl IntoIterator<Item = &'a str>) -> Vec<TreeRow> {
    let mut root = Directory::default();
    for (index, path) in paths.into_iter().enumerate() {
        let parts: Vec<&str> = path.split('/').collect();
        root.insert(&parts, index);
    }
    let mut rows = Vec::new();
    root.write_rows(0, &mut rows);
    rows
}

#[derive(Default)]
struct Directory<'a> {
    directories: BTreeMap<&'a str, Directory<'a>>,
    files: BTreeMap<&'a str, usize>,
}

impl<'a> Directory<'a> {
    fn insert(&mut self, parts: &[&'a str], index: usize) {
        match parts {
            [] => {}
            [name] => {
                self.files.insert(*name, index);
            }
            [directory, rest @ ..] => self
                .directories
                .entry(*directory)
                .or_default()
                .insert(rest, index),
        }
    }

    fn write_rows(&self, depth: usize, rows: &mut Vec<TreeRow>) {
        for (name, directory) in &self.directories {
            let (label, contents) = directory.joined(name);
            rows.push(TreeRow {
                depth,
                name: label,
                file: None,
            });
            contents.write_rows(depth + 1, rows);
        }
        for (name, index) in &self.files {
            rows.push(TreeRow {
                depth,
                name: (*name).to_owned(),
                file: Some(*index),
            });
        }
    }

    /// The label for this directory, called `name`, joined with each
    /// directory below it that is its only child, and the directory whose
    /// contents go under that label.
    fn joined(&self, name: &str) -> (String, &Self) {
        let mut label = name.to_owned();
        let mut directory = self;
        while directory.files.is_empty() && directory.directories.len() == 1 {
            let Some((child_name, child)) = directory.directories.iter().next() else {
                break;
            };
            label = format!("{label}/{child_name}");
            directory = child;
        }
        (label, directory)
    }
}
```

In `crates/review-core/src/presenter.rs`, import `crate::tree::file_tree` and add to the `SessionView` literal, after `files: rows,`:

```rust
        tree: file_tree(files.iter().map(|file| file.path.as_str())),
```

- [ ] **Step 5: Run the tests**

Run: `cargo test --workspace --all-features`
Expected: PASS.

- [ ] **Step 6: Gate and commit**

```bash
just check
git add crates
git commit -m "feat(core): give the session view a file tree"
```

---

### Task 15: Protocol version 2

**Files:**
- Create: `crates/review-rpc/src/params.rs`
- Modify: `crates/review-rpc/src/lib.rs`, `src/protocol.rs`, `src/server.rs`
- Modify: `crates/review-rpc/tests/serve.rs`
- Replace: `docs/protocol.md`

Three methods join: `fileDiff`, `stream` and `setViewed`, plus the `viewedChanged` event. Their params are read for the first time, so a bad one is an `-32602` error. The plugin's version moves in Task 17; until then the Lua specs still use the fake engine, so the gate stays green.

- [ ] **Step 1: Write the failing tests**

In `crates/review-rpc/tests/serve.rs`, change the protocol assertion in `initialize_reports_the_protocol_and_server_versions` to `assert_eq!(result["protocolVersion"], 2);`, and add:

```rust
fn request_with(id: u64, method: &str, params: &str) -> String {
    format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"{method}\",\"params\":{params}}}\n")
}

#[test]
fn file_diff_answers_with_the_files_diff() {
    let input = request(1, "sync") + &request_with(2, "fileDiff", r#"{"path":"src/a.rs"}"#);
    let written = run(&input, &forge());
    let diff = &response(&written, 2)["result"];
    assert_eq!(diff["path"], "src/a.rs");
    assert_eq!(diff["added"][0]["line"], 1);
    assert_eq!(diff["baseText"], "fn a() {}\n");
}

#[test]
fn stream_answers_in_the_requested_mode() {
    let input = request(1, "sync") + &request_with(2, "stream", r#"{"mode":"split"}"#);
    let written = run(&input, &forge());
    let stream = &response(&written, 2)["result"];
    assert_eq!(stream["mode"], "split");
    assert_eq!(stream["rows"][0]["kind"], "file");
}

#[test]
fn set_viewed_announces_the_change_before_answering() {
    let input = request(1, "sync")
        + &request_with(2, "setViewed", r#"{"path":"src/a.rs","viewed":false}"#);
    let written = run(&input, &forge());
    let changed = written
        .iter()
        .position(|message| message["params"]["type"] == "viewedChanged")
        .expect("a viewedChanged event");
    let answer = written.iter().position(|message| message["id"] == 2).unwrap();
    assert!(changed < answer, "the event comes first");
    assert_eq!(response(&written, 2)["result"]["files"][0]["viewed"], "UNVIEWED");
}

#[test]
fn bad_params_are_invalid_params_errors() {
    let input = request_with(1, "stream", r#"{"mode":"sideways"}"#)
        + &request_with(2, "fileDiff", "{}")
        + &request_with(3, "setViewed", r#"{"path":"a"}"#);
    let written = run(&input, &forge());
    for id in 1..=3 {
        assert_eq!(response(&written, id)["error"]["code"], -32602, "request {id}");
    }
}

#[test]
fn an_engine_failure_in_a_new_method_is_an_engine_error() {
    let written = run(&request_with(1, "stream", r#"{"mode":"unified"}"#), &forge());
    let error = &response(&written, 1)["error"];
    assert_eq!(error["code"], -32000);
    assert!(error["message"].as_str().unwrap().contains("not synced"), "{error}");
}
```

Create `crates/review-rpc/src/params.rs` with only its tests:

```rust
//! Reading a request's params. A param that is missing or of the wrong type
//! is an invalid-params error that says what was expected.

#[cfg(test)]
mod tests {
    use review_model::ViewMode;
    use serde_json::{Value, json};

    use super::*;

    #[test]
    fn reads_strings_booleans_and_modes() {
        let params = json!({ "path": "a.rs", "viewed": true, "mode": "split" });
        assert_eq!(string_param(&params, "path").unwrap(), "a.rs");
        assert!(bool_param(&params, "viewed").unwrap());
        assert_eq!(mode_param(&params).unwrap(), ViewMode::Split);
    }

    #[test]
    fn missing_or_mistyped_params_are_invalid() {
        let params = json!({ "path": 7, "mode": "sideways" });
        for error in [
            string_param(&params, "path").unwrap_err(),
            bool_param(&params, "viewed").unwrap_err(),
            mode_param(&params).unwrap_err(),
            string_param(&Value::Null, "path").unwrap_err(),
        ] {
            assert_eq!(error.code, RpcError::INVALID_PARAMS, "{}", error.message);
        }
    }
}
```

Add `mod params;` to `crates/review-rpc/src/lib.rs`.

- [ ] **Step 2: Run the tests to see them fail**

Run: `cargo test -p review-rpc`
Expected: FAIL to compile (`string_param` and friends are missing).

- [ ] **Step 3: Implement the params**

Put this above the tests in `crates/review-rpc/src/params.rs`:

```rust
use review_model::ViewMode;
use serde_json::Value;

use crate::protocol::RpcError;

/// The string param `name`.
pub fn string_param<'a>(params: &'a Value, name: &str) -> Result<&'a str, RpcError> {
    params
        .get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(&format!("expected a string \"{name}\"")))
}

/// The boolean param `name`.
pub fn bool_param(params: &Value, name: &str) -> Result<bool, RpcError> {
    params
        .get(name)
        .and_then(Value::as_bool)
        .ok_or_else(|| invalid(&format!("expected a boolean \"{name}\"")))
}

/// The `mode` param: `unified` or `split`.
pub fn mode_param(params: &Value) -> Result<ViewMode, RpcError> {
    params
        .get("mode")
        .and_then(Value::as_str)
        .and_then(ViewMode::parse)
        .ok_or_else(|| invalid("expected \"mode\" to be \"unified\" or \"split\""))
}

fn invalid(message: &str) -> RpcError {
    RpcError::new(RpcError::INVALID_PARAMS, message)
}
```

- [ ] **Step 4: Route the new methods**

In `crates/review-rpc/src/protocol.rs`: `pub const PROTOCOL_VERSION: u32 = 2;`.

In `crates/review-rpc/src/server.rs`, import `crate::params::{bool_param, mode_param, string_param}` and replace `handle` with:

```rust
/// Answers one request. Routing only: every rule lives in the session.
pub fn handle(
    session: &Mutex<ReviewSession>,
    request: &Request,
    server_version: &str,
) -> Result<Value, RpcError> {
    let params = &request.params;
    match request.method.as_str() {
        "initialize" => {
            Ok(json!({ "protocolVersion": PROTOCOL_VERSION, "version": server_version }))
        }
        "snapshot" => to_value(&lock(session)?.view()),
        "sync" => to_value(&engine(lock(session)?.sync())?),
        "fileDiff" => {
            let path = string_param(params, "path")?;
            to_value(&engine(lock(session)?.file_diff(path))?)
        }
        "stream" => {
            let mode = mode_param(params)?;
            to_value(&engine(lock(session)?.stream(mode))?)
        }
        "setViewed" => {
            let (path, viewed) = (string_param(params, "path")?, bool_param(params, "viewed")?);
            to_value(&engine(lock(session)?.set_viewed(path, viewed))?)
        }
        "shutdown" => Ok(Value::Null),
        other => Err(RpcError::new(
            RpcError::METHOD_NOT_FOUND,
            format!("unknown method {other:?}"),
        )),
    }
}

/// An engine failure as an RPC error, with its whole context chain.
fn engine<T>(result: anyhow::Result<T>) -> Result<T, RpcError> {
    result.map_err(|error| RpcError::new(RpcError::ENGINE_ERROR, format!("{error:#}")))
}
```

- [ ] **Step 5: Run the tests**

Run: `cargo test -p review-rpc`
Expected: PASS.

- [ ] **Step 6: Rewrite `docs/protocol.md` for version 2**

Replace the whole file with:

````markdown
# Engine protocol (version 2)

`jpr-review serve` speaks JSON-RPC 2.0, one JSON message per line, UTF-8.
Requests arrive on stdin. Responses and notifications leave on stdout and may
interleave, so clients match responses by `id`. Logs go to stderr.

```
jpr-review serve --pr <number> --repo <owner/name> [--poll <seconds>]
```

Run it in the pull request's worktree. `--poll` defaults to 60 seconds, and
`--poll 0` turns background syncing off. While it polls, the server also
resends viewed marks GitHub refused every 20 seconds. The server does not sync
on its own at startup: until the first sync, `snapshot` returns what was saved
last.

## Handshake

The client sends `initialize` first and compares `protocolVersion` with its
own. On a mismatch it stops the server and tells the user to install the
plugin and the engine from the same checkout.

## Requests

| Method | Params | Result |
| --- | --- | --- |
| `initialize` | `{ "protocolVersion": 2, "client": "..." }` (the server reads neither) | `{ "protocolVersion": 2, "version": "0.2.0" }` |
| `snapshot` | none | `SessionView` |
| `sync` | none | `SessionView`; error `-32000` when GitHub fails, after a `syncFailed` event |
| `fileDiff` | `{ "path": "src/a.rs" }` | `FileDiffView`; error `-32000` for a file the pull request does not change, or before the first sync |
| `stream` | `{ "mode": "unified" \| "split" }` | `StreamView`; error `-32000` before the first sync |
| `setViewed` | `{ "path": "src/a.rs", "viewed": true }` | `SessionView`, after a `viewedChanged` event |
| `shutdown` | none | `null`; the server stops reading and exits |

The server also exits when stdin closes. Methods without params ignore them,
so `null`, `{}` or a missing `params` all work. `setViewed` succeeds even when
GitHub refuses the mark: the mark stands, is counted in `queuedCount`, and is
sent again by later retries and syncs.

## Notifications (server to client)

`event`, with one of:

```json
{ "type": "synced", "view": SessionView }
{ "type": "syncFailed", "message": "gh timed out after 30s" }
{ "type": "viewedChanged", "view": SessionView }
```

Every sync announces `synced` or `syncFailed`, whether a `sync` request or the
background poller started it. `viewedChanged` follows every `setViewed` and
every retry that got a queued mark through. An event is written before the
response to the request that caused it, and every event is written before the
`shutdown` response.

## Types

`SessionView`:

```json
{
  "pr": { "owner": "octo", "repo": "widgets", "number": 7, "title": "Fix the widget",
          "url": "https://github.com/octo/widgets/pull/7", "nodeId": "PR_7", "author": "alice",
          "headRef": "fix/widget", "headSha": "abc123", "baseRef": "main", "baseSha": "base000" },
  "files": [ { "path": "src/a.rs", "additions": 12, "deletions": 3, "viewed": "VIEWED", "threads": 2 } ],
  "tree": [ { "depth": 0, "name": "src", "file": null }, { "depth": 1, "name": "a.rs", "file": 0 } ],
  "viewedCount": 1,
  "threadCount": 2,
  "queuedCount": 0,
  "sync": { "state": "synced", "at": 1763510400 }
}
```

- `pr` is `null` until the first successful sync.
- `viewed` is `VIEWED`, `UNVIEWED` or `DISMISSED` (viewed, then changed on GitHub).
- `tree` lists directories first, then files, each by name; a file row's
  `file` is its index in `files`, a directory's is `null`.
- `queuedCount` counts viewed marks waiting for GitHub.
- `sync` is `{ "state": "never" }`, `{ "state": "synced", "at": <unix seconds> }`
  or `{ "state": "failed", "at": <unix seconds>, "message": "..." }`.

`FileDiffView`, one file against the merge base of its base commit and the
checked-out head; the current side is the file on disk:

```json
{
  "path": "src/a.rs",
  "binary": false,
  "baseText": "fn main() {\nlet x = 1;\n}\n",
  "added": [ { "line": 2, "words": [ { "start": 8, "end": 9 } ] } ],
  "removed": [ { "above": 2, "lines": [ { "text": "let x = 1;", "words": [ { "start": 8, "end": 9 } ] } ] } ]
}
```

- Line numbers count from 1 in the current file. `above` is the line a block
  of removed lines sits above; one past the last line means after the end.
- `words` are byte ranges (`end` exclusive) of the words that changed inside
  an edited line; a line that was replaced rather than edited has none.
- `baseText` is `null` for an added file or a binary one; `binary` files have
  no `added` or `removed` lines.

`StreamView`:

```json
{
  "mode": "split",
  "rows": [
    { "kind": "file", "path": "src/a.rs", "additions": 1, "deletions": 1, "viewed": "UNVIEWED", "folded": false },
    { "kind": "hunk", "path": "src/a.rs", "header": "@@ -1,3 +1,3 @@", "target": 1 },
    { "kind": "line", "path": "src/a.rs", "target": 1,
      "left":  { "line": 1, "text": "fn main() {", "change": "context", "words": [] },
      "right": { "line": 1, "text": "fn main() {", "change": "context", "words": [] } },
    { "kind": "line", "path": "src/a.rs", "target": 2,
      "left":  { "line": 2, "text": "let x = 1;", "change": "removed", "words": [ { "start": 8, "end": 9 } ] },
      "right": { "line": 2, "text": "let x = 2;", "change": "added", "words": [ { "start": 8, "end": 9 } ] } },
    { "kind": "note", "path": "logo.png", "text": "binary file" }
  ]
}
```

- Files come in GitHub's order; each starts with a `file` row. Viewed files
  have `folded: true`.
- Hunks carry 3 lines of context. In `unified` mode a changed block's removed
  rows (only `left`) come before its added rows (only `right`); context rows
  have both. In `split` mode a removed and an added line share a row, and a
  `null` side is filler that keeps the columns aligned.
- `target` is the current-file line a client jumps to from the row.
- A `note` stands in for lines that cannot be shown: `binary file`,
  `no changes against the base`, or `could not read this file: ...`.

## Errors

| Code | Meaning |
| --- | --- |
| -32700 | The line is not JSON (the response `id` is `null`) |
| -32600 | Not a request: no string `method`, or no `id` (the response `id` is `null` when there was none) |
| -32601 | Unknown method |
| -32602 | Invalid params: a missing or mistyped `path`, `viewed` or `mode` |
| -32000 | The engine could not do it; `message` says why |

## Versioning

Change `PROTOCOL_VERSION` in `crates/review-rpc/src/protocol.rs` and
`M.PROTOCOL_VERSION` in `lua/jpr/rpc.lua` together whenever a request, a
result or an event changes shape, and update this document in the same commit.
Version 2 added `fileDiff`, `stream`, `setViewed`, the `viewedChanged` event,
and `tree`, `queuedCount` and `pr.baseSha` in `SessionView`.
````

- [ ] **Step 7: Gate and commit**

```bash
just check
git add crates/review-rpc docs/protocol.md
git commit -m "feat(rpc): protocol 2 with fileDiff, stream and setViewed"
```

(The plugin still speaks version 1 until Task 17; nothing launches the real engine in the Lua specs, so the gate passes.)

---

### Task 16: The poller retries the queue

**Files:**
- Modify: `crates/review-rpc/src/server.rs`, `crates/review-rpc/src/lib.rs`
- Modify: `crates/review-rpc/tests/serve.rs`
- Modify: `crates/jpr-review/src/commands/serve.rs`

The spec retries refused calls every 20 seconds. The poller now wakes at the shorter of the poll and retry intervals and decides, through a pure function, whether to sync, retry the queue, or wait.

- [ ] **Step 1: Write the failing tests**

Add to the end of `crates/review-rpc/src/server.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    const MINUTE: Duration = Duration::from_secs(60);

    #[test]
    fn a_full_interval_since_the_last_sync_means_sync() {
        assert_eq!(poll_step(MINUTE, MINUTE, true), PollStep::Sync);
        assert_eq!(poll_step(MINUTE * 2, MINUTE, false), PollStep::Sync);
    }

    #[test]
    fn between_syncs_a_waiting_queue_is_retried() {
        assert_eq!(poll_step(Duration::from_secs(20), MINUTE, true), PollStep::Retry);
        assert_eq!(poll_step(Duration::from_secs(20), MINUTE, false), PollStep::Wait);
    }

    #[test]
    fn the_poller_wakes_at_the_shorter_interval() {
        let retry = Some(Duration::from_secs(20));
        assert_eq!(poll_tick(MINUTE, retry), Duration::from_secs(20));
        assert_eq!(poll_tick(Duration::from_secs(5), retry), Duration::from_secs(5));
        assert_eq!(poll_tick(MINUTE, None), MINUTE);
    }
}
```

In `crates/review-rpc/tests/serve.rs`, make `options` set the new field:

```rust
fn options(poll_every: Option<Duration>) -> ServeOptions {
    ServeOptions {
        server_version: "9.9.9".into(),
        poll_every,
        retry_every: None,
    }
}
```

and add:

```rust
#[test]
fn the_poller_retries_a_refused_viewed_mark_between_syncs() {
    let forge = forge();
    let shared = session(&forge);
    {
        let mut session = shared.lock().unwrap();
        session.sync().unwrap();
        forge.fail_writes_with(Some("offline"));
        session.set_viewed("src/a.rs", false).unwrap();
    }
    forge.fail_writes_with(None);
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    let watched = forge.clone();
    let reader = BufReader::new(EndsWhen {
        done: move || !watched.viewed_calls().is_empty(),
        deadline: Instant::now() + Duration::from_secs(10),
    });
    let options = ServeOptions {
        retry_every: Some(Duration::from_millis(20)),
        ..options(Some(Duration::from_secs(3600)))
    };
    serve(reader, &output, &shared, &options).unwrap();
    assert_eq!(forge.viewed_calls(), [("src/a.rs".to_owned(), false)]);
    assert_eq!(forge.fetches(), 1, "it retried without syncing again");
    assert!(
        messages(&output)
            .iter()
            .any(|message| message["params"]["type"] == "viewedChanged"),
        "the landed mark is announced"
    );
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cargo test -p review-rpc`
Expected: FAIL to compile: no `retry_every`, `poll_step`, `PollStep`, `poll_tick`.

- [ ] **Step 3: Implement it**

In `crates/review-rpc/src/server.rs`, add `use std::time::Instant;` (next to `Duration`), add the field to `ServeOptions`:

```rust
    /// How often, between syncs, to resend what the forge refused; `None`
    /// waits for the next sync. Only a server that polls retries.
    pub retry_every: Option<Duration>,
```

add the decision functions after `ServeOptions`:

```rust
/// What the poller does when it wakes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PollStep {
    /// Pull from the forge (which sends the queue first).
    Sync,
    /// Resend the queue only.
    Retry,
    /// Nothing to do yet.
    Wait,
}

/// What the poller does `since_sync` after its last sync: sync once a whole
/// `poll_every` has passed, else resend a waiting queue, else wait.
#[must_use]
pub fn poll_step(since_sync: Duration, poll_every: Duration, has_queued: bool) -> PollStep {
    if since_sync >= poll_every {
        PollStep::Sync
    } else if has_queued {
        PollStep::Retry
    } else {
        PollStep::Wait
    }
}

/// How long the poller sleeps between wake-ups: the shorter of the two
/// intervals.
#[must_use]
pub fn poll_tick(poll_every: Duration, retry_every: Option<Duration>) -> Duration {
    retry_every.map_or(poll_every, |retry| retry.min(poll_every))
}
```

In `serve`, pass the tick to the poller:

```rust
    let poller = options.poll_every.map(|every| {
        let shared = (Arc::clone(session), Arc::clone(&events), Arc::clone(writer));
        spawn_poller(shared, stopped, every, poll_tick(every, options.retry_every))
    });
```

and replace `spawn_poller` with:

```rust
/// Wakes every `tick` and, as [`poll_step`] decides, syncs (every `every`)
/// or resends the queue, writing what that announced, until `stopped` fires
/// or disconnects, or the output closes.
fn spawn_poller<W: Write + Send + 'static>(
    (session, events, writer): Shared<W>,
    stopped: Receiver<()>,
    every: Duration,
    tick: Duration,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut last_sync = Instant::now();
        // A message or a disconnect both mean stop.
        while stopped.recv_timeout(tick) == Err(RecvTimeoutError::Timeout) {
            if let Ok(mut session) = session.lock() {
                // A failure is announced as an event by the session.
                match poll_step(last_sync.elapsed(), every, session.has_queued()) {
                    PollStep::Sync => {
                        let _ = session.sync();
                        last_sync = Instant::now();
                    }
                    PollStep::Retry => {
                        let _ = session.flush_queued();
                    }
                    PollStep::Wait => {}
                }
            }
            if write_events(&events, &writer).is_err() {
                break;
            }
        }
    })
}
```

Export the new items from `crates/review-rpc/src/lib.rs`:

```rust
pub use server::{PollStep, ServeOptions, handle, poll_step, poll_tick, serve};
```

- [ ] **Step 4: Set the retry interval in `serve`**

In `crates/jpr-review/src/commands/serve.rs`, add:

```rust
/// Seconds between resends of what GitHub refused, while the server polls.
pub const RETRY_SECONDS: u64 = 20;
```

and set the field where `ServeOptions` is built:

```rust
        retry_every: poll_interval(poll).map(|_| Duration::from_secs(RETRY_SECONDS)),
```

- [ ] **Step 5: Run the tests**

Run: `cargo test --workspace --all-features`
Expected: PASS, including the earlier poller tests (with `retry_every: None` the poller behaves as before).

- [ ] **Step 6: Gate and commit**

```bash
just check
git add crates
git commit -m "feat(rpc): retry refused viewed marks every 20 seconds between syncs"
```

---
### Task 17: The plugin speaks protocol 2, and remembers the view mode

**Files:**
- Modify: `scripts/test-lua.sh`
- Replace: `tests/lua/fixtures/fake_engine.sh`
- Modify: `lua/jpr/rpc.lua`, `lua/jpr/init.lua`, `lua/jpr/session.lua`
- Create: `lua/jpr/view_mode.lua`
- Create: `tests/lua/view_mode_spec.lua`
- Modify: `tests/lua/command_spec.lua`, `tests/lua/session_spec.lua`, `tests/lua/session_lifecycle_spec.lua`

The view mode is global and remembered across Neovim restarts in `stdpath("state")/jpr/view-mode`. It is a frontend preference, not review state, so it lives in Lua; `setup({ view = ... })` picks the starting mode. The specs get their own `XDG_STATE_HOME`, so they never touch the real one.

- [ ] **Step 1: Isolate the specs' state**

In `scripts/test-lua.sh`, after `root=...`:

```bash
# Specs never write the real state directory (the remembered view mode).
XDG_STATE_HOME="$(mktemp -d)"
export XDG_STATE_HOME
```

- [ ] **Step 2: Teach the fake engine protocol 2**

Replace `tests/lua/fixtures/fake_engine.sh` (keep it executable):

```sh
#!/bin/sh
# A stand-in for `jpr-review serve` in the Lua specs: answers by method name and
# ignores its arguments. FAKE_ENGINE_PROTOCOL overrides the protocol version it
# reports (default 2). When FAKE_ENGINE_LOG names a file, every request line is
# appended to it, so a spec can check what the plugin sent.
pr='{"number":7,"title":"Fix the widget","headSha":"head1","baseSha":"base1"}'
tree='[{"depth":0,"name":"README.md","file":0}]'
view_synced='{"pr":'"$pr"',"files":[{"path":"README.md","additions":2,"deletions":1,"viewed":"UNVIEWED","threads":1}],"tree":'"$tree"',"viewedCount":0,"threadCount":1,"queuedCount":0,"sync":{"state":"synced","at":1}}'
view_viewed='{"pr":'"$pr"',"files":[{"path":"README.md","additions":2,"deletions":1,"viewed":"VIEWED","threads":1}],"tree":'"$tree"',"viewedCount":1,"threadCount":1,"queuedCount":0,"sync":{"state":"synced","at":1}}'
view_empty='{"files":[],"tree":[],"viewedCount":0,"threadCount":0,"queuedCount":0,"sync":{"state":"never"}}'
# README.md is "hello\nold\n" at the base and "hello\nnew\n" on disk.
file_diff='{"path":"README.md","binary":false,"baseText":"hello\nold\n","added":[{"line":2,"words":[{"start":0,"end":3}]}],"removed":[{"above":2,"lines":[{"text":"old","words":[{"start":0,"end":3}]}]}]}'
head_rows='{"kind":"file","path":"README.md","additions":2,"deletions":1,"viewed":"UNVIEWED","folded":false},{"kind":"hunk","path":"README.md","header":"@@ -1,2 +1,2 @@","target":1}'
hello='{"kind":"line","path":"README.md","left":{"line":1,"text":"hello","change":"context","words":[]},"right":{"line":1,"text":"hello","change":"context","words":[]},"target":1}'
old='{"line":2,"text":"old","change":"removed","words":[{"start":0,"end":3}]}'
new='{"line":2,"text":"new","change":"added","words":[{"start":0,"end":3}]}'
stream_unified='{"mode":"unified","rows":['"$head_rows,$hello"',{"kind":"line","path":"README.md","left":'"$old"',"right":null,"target":2},{"kind":"line","path":"README.md","left":null,"right":'"$new"',"target":2}]}'
stream_split='{"mode":"split","rows":['"$head_rows,$hello"',{"kind":"line","path":"README.md","left":'"$old"',"right":'"$new"',"target":2}]}'
reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$1"; }
announce() { printf '{"jsonrpc":"2.0","method":"event","params":{"type":"%s","view":%s}}\n' "$1" "$2"; }
while IFS= read -r line; do
  if [ -n "$FAKE_ENGINE_LOG" ]; then printf '%s\n' "$line" >> "$FAKE_ENGINE_LOG"; fi
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*) reply '{"protocolVersion":'"${FAKE_ENGINE_PROTOCOL:-2}"',"version":"test"}' ;;
    *'"method":"snapshot"'*) reply "$view_empty" ;;
    *'"method":"sync"'*) announce synced "$view_synced"; reply "$view_synced" ;;
    *'"method":"fileDiff"'*) reply "$file_diff" ;;
    *'"method":"stream"'*'"split"'*|*'"split"'*'"method":"stream"'*) reply "$stream_split" ;;
    *'"method":"stream"'*) reply "$stream_unified" ;;
    *'"method":"setViewed"'*) announce viewedChanged "$view_viewed"; reply "$view_viewed" ;;
    *'"method":"shutdown"'*) reply null; exit 0 ;;
    *) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"method not found"}}\n' "$id" ;;
  esac
done
```

The synced view now has `README.md` unviewed. In `tests/lua/session_spec.lua`, change the panel assertion to:

```lua
assert(lines[5] == "  README.md  +2 -1 [1]", vim.inspect(lines))
```

In `tests/lua/session_lifecycle_spec.lua`, the protocol-mismatch case must report a version the plugin does not speak: change `vim.env.FAKE_ENGINE_PROTOCOL = "2"` to `vim.env.FAKE_ENGINE_PROTOCOL = "99"`.

In `tests/lua/rpc_spec.lua`, the fake now reports version 2: change `initialize_answer.result.protocolVersion == 1` to `initialize_answer.result.protocolVersion == 2`.

- [ ] **Step 3: Write the failing specs**

Create `tests/lua/view_mode_spec.lua`:

```lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local view_mode = require("jpr.view_mode")

view_mode.path = vim.fn.tempname() .. "/jpr/view-mode"
assert(view_mode.get() == "unified", "unified by default")
jpr.setup({ view = "split" })
view_mode.reset()
assert(view_mode.get() == "split", "setup picks the starting mode")
assert(view_mode.toggle() == "unified", "toggle flips it")
assert(vim.fn.readfile(view_mode.path)[1] == "unified", "and remembers it")
view_mode.reset()
assert(view_mode.get() == "unified", "a remembered choice beats the setup default")
vim.fn.writefile({ "sideways" }, view_mode.path)
view_mode.reset()
assert(view_mode.get() == "split", "a file that names no mode is ignored")

print("view_mode_spec: ok")
```

In `tests/lua/command_spec.lua`, change the completion assertion and add a dispatch check before the final `print`:

```lua
assert(vim.deep_equal(jpr.complete("", "Jpr "), { "open", "sync", "toggle", "close" }), "all subcommands")
```

```lua
local toggled = false
package.loaded["jpr.session"] = {
    toggle_view = function()
        toggled = true
    end,
}
jpr.command({ "toggle" })
assert(toggled, ":Jpr toggle flips the view")
package.loaded["jpr.session"] = nil
```

- [ ] **Step 4: Run the specs to see them fail**

Run: `./scripts/test-lua.sh`
Expected: `view_mode_spec` fails (`module 'jpr.view_mode' not found`), `command_spec` fails (the subcommand list), and `session_spec` and `session_lifecycle_spec` fail on the protocol (the plugin still speaks 1).

- [ ] **Step 5: Implement `view_mode.lua`**

Create `lua/jpr/view_mode.lua`:

```lua
-- The global diff view mode, "unified" or "split", remembered across Neovim
-- restarts. A frontend preference, so it lives here rather than in the engine.
local M = {}

local MODES = { unified = true, split = true }

--- Where the mode is remembered. Specs point it at a temporary file.
M.path = vim.fn.stdpath("state") .. "/jpr/view-mode"

local current

--- The mode in effect: the remembered one, else `setup({ view = ... })`'s.
function M.get()
    if current then
        return current
    end
    local ok, lines = pcall(vim.fn.readfile, M.path)
    local saved = ok and lines[1] or nil
    current = MODES[saved] and saved or require("jpr").config.view
    return current
end

--- Sets `mode` and remembers it for the next Neovim.
function M.set(mode)
    current = mode
    vim.fn.mkdir(vim.fs.dirname(M.path), "p")
    pcall(vim.fn.writefile, { mode }, M.path)
end

--- Flips between unified and split, remembers it, and returns the new mode.
function M.toggle()
    local next_mode = M.get() == "split" and "unified" or "split"
    M.set(next_mode)
    return next_mode
end

--- Forgets the mode read so far, so the next `get` reads the file again.
function M.reset()
    current = nil
end

return M
```

- [ ] **Step 6: Speak protocol 2 and add `:Jpr toggle`**

`lua/jpr/rpc.lua`: `M.PROTOCOL_VERSION = 2`.

`lua/jpr/init.lua`:

- add to `M.defaults`, after `panel_width`:

```lua
    -- The diff view until the reviewer flips it with :Jpr toggle, which is
    -- then remembered: "unified" or "split".
    view = "unified",
```

- `M.subcommands = { "open", "sync", "toggle", "close" }`
- add to the `links` table in `define_highlights`:

```lua
        JprDiffAdd = "DiffAdd",
        JprDiffAddText = "DiffText",
        JprDiffDelete = "DiffDelete",
        JprDiffDeleteText = "DiffText",
        JprDiffFiller = "NonText",
        JprHunk = "Special",
        JprFileHeader = "Title",
```

- add to `M.command`, before the final `else`:

```lua
    elseif subcommand == "toggle" then
        require("jpr.session").toggle_view()
```

`lua/jpr/session.lua`, add before `return M`:

```lua
--- `:Jpr toggle`: flips every review between unified and split views, and
--- remembers the choice.
function M.toggle_view()
    local mode = require("jpr.view_mode").toggle()
    jpr().info(("%s view"):format(mode))
end
```

Update `plugin/jpr.lua`'s `desc` to `"Review a GitHub pull request (open, sync, toggle, close)"`.

- [ ] **Step 7: Run the specs**

Run: `./scripts/test-lua.sh`
Expected: every spec prints `ok`.

- [ ] **Step 8: Gate and commit**

```bash
just check
git add scripts lua plugin tests
git commit -m "feat(nvim): speak protocol 2 and remember the view mode"
```

---

### Task 18: The overlay renderer (pure)

**Files:**
- Create: `lua/jpr/render/overlay.lua`
- Create: `tests/lua/overlay_render_spec.lua`

Turns a `FileDiffView` into extmark specs, so the window code only places them. Removed lines become virtual lines: their text in `JprDiffDelete`, changed words in `JprDiffDeleteText`, padded to the window width so the color spans the line. Virtual text draws a tab as one cell, so tabs are expanded first.

- [ ] **Step 1: Write the failing spec**

Create `tests/lua/overlay_render_spec.lua`:

```lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local overlay = require("jpr.render.overlay")

assert(vim.deep_equal(overlay.text_lines("a\r\nb\n"), { "a", "b" }), "lines without endings")
assert(vim.deep_equal(overlay.text_lines("a\nb"), { "a", "b" }), "no final newline")
assert(vim.deep_equal(overlay.text_lines(nil), {}), "no base")
assert(vim.deep_equal(overlay.text_lines(""), {}), "an empty base")

local chunks = overlay.removed_chunks({ text = "let x = 1;", words = { { start = 8, ["end"] = 9 } } }, { width = 12, tabstop = 4 })
assert(vim.deep_equal(chunks, {
    { "let x = ", "JprDiffDelete" },
    { "1", "JprDiffDeleteText" },
    { ";", "JprDiffDelete" },
    { "  ", "JprDiffDelete" },
}), vim.inspect(chunks))
local tabbed = overlay.removed_chunks({ text = "\tx", words = {} }, { width = 0, tabstop = 4 })
assert(vim.deep_equal(tabbed, { { "    x", "JprDiffDelete" } }), vim.inspect(tabbed))
local empty = overlay.removed_chunks({ text = "", words = {} }, { width = 0, tabstop = 8 })
assert(vim.deep_equal(empty, { { "", "JprDiffDelete" } }), vim.inspect(empty))

local diff = {
    added = { { line = 2, words = { { start = 0, ["end"] = 3 } } } },
    removed = {
        { above = 2, lines = { { text = "old", words = {} } } },
        { above = 4, lines = { { text = "tail", words = {} } } },
    },
}
local marks = overlay.build(diff, 3, { width = 0, tabstop = 8 })
assert(vim.deep_equal(marks[1], { line = 1, col = 0, opts = { line_hl_group = "JprDiffAdd" } }), vim.inspect(marks[1]))
assert(vim.deep_equal(marks[2], { line = 1, col = 0, opts = { end_col = 3, hl_group = "JprDiffAddText" } }), vim.inspect(marks[2]))
assert(marks[3].line == 1 and marks[3].opts.virt_lines_above == true, "a block sits above its line")
assert(marks[3].opts.virt_lines[1][1][1] == "old", vim.inspect(marks[3]))
assert(marks[4].line == 2 and marks[4].opts.virt_lines_above == false, "a block past the end sits below the last line")

print("overlay_render_spec: ok")
```

- [ ] **Step 2: Run it to see it fail**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/overlay_render_spec.lua`
Expected: FAIL: `module 'jpr.render.overlay' not found`.

- [ ] **Step 3: Implement it**

Create `lua/jpr/render/overlay.lua`:

```lua
-- Pure: turns the engine's FileDiffView into extmark specs for a unified
-- overlay, and a base text into buffer lines. No windows or buffers here.
local M = {}

--- `text` as buffer lines: split on newlines, without the empty line a final
--- newline leaves and without carriage returns, as a buffer read with
--- `fileformat=dos` shows none either.
function M.text_lines(text)
    if not text or text == "" then
        return {}
    end
    local lines = vim.split(text, "\n", { plain = true })
    if lines[#lines] == "" then
        lines[#lines] = nil
    end
    for index, line in ipairs(lines) do
        lines[index] = line:gsub("\r$", "")
    end
    return lines
end

--- `text` with tabs expanded to `tabstop` columns, starting at display
--- column `column`; returns the text and the column after it.
local function expand_tabs(text, tabstop, column)
    local parts = {}
    for _, character in ipairs(vim.fn.split(text, "\\zs")) do
        if character == "\t" then
            local spaces = tabstop - (column % tabstop)
            parts[#parts + 1] = (" "):rep(spaces)
            column = column + spaces
        else
            parts[#parts + 1] = character
            column = column + vim.api.nvim_strwidth(character)
        end
    end
    return table.concat(parts), column
end

--- One removed line as virtual-text chunks: the line in the removed color,
--- its changed words in the stronger one, padded to `opts.width` so the color
--- spans the window. opts: { width, tabstop }.
function M.removed_chunks(removed, opts)
    local chunks, column, position = {}, 0, 1
    local function add(text, group)
        if text ~= "" then
            local expanded
            expanded, column = expand_tabs(text, opts.tabstop, column)
            chunks[#chunks + 1] = { expanded, group }
        end
    end
    for _, word in ipairs(removed.words or {}) do
        add(removed.text:sub(position, word.start), "JprDiffDelete")
        add(removed.text:sub(word.start + 1, word["end"]), "JprDiffDeleteText")
        position = word["end"] + 1
    end
    add(removed.text:sub(position), "JprDiffDelete")
    if column < opts.width then
        chunks[#chunks + 1] = { (" "):rep(opts.width - column), "JprDiffDelete" }
    end
    if #chunks == 0 then
        chunks[1] = { "", "JprDiffDelete" }
    end
    return chunks
end

--- The extmarks that draw `diff` on a buffer of `line_count` lines, as
--- { line, col, opts } with 0-based lines and byte columns. opts: { width,
--- tabstop } of the window, for the removed lines.
function M.build(diff, line_count, opts)
    local marks = {}
    for _, added in ipairs(diff.added or {}) do
        local line = added.line - 1
        marks[#marks + 1] = { line = line, col = 0, opts = { line_hl_group = "JprDiffAdd" } }
        for _, word in ipairs(added.words or {}) do
            marks[#marks + 1] =
                { line = line, col = word.start, opts = { end_col = word["end"], hl_group = "JprDiffAddText" } }
        end
    end
    for _, block in ipairs(diff.removed or {}) do
        local virt_lines = {}
        for _, removed in ipairs(block.lines) do
            virt_lines[#virt_lines + 1] = M.removed_chunks(removed, opts)
        end
        local is_past_end = block.above > line_count
        marks[#marks + 1] = {
            line = is_past_end and math.max(line_count - 1, 0) or block.above - 1,
            col = 0,
            opts = { virt_lines = virt_lines, virt_lines_above = not is_past_end },
        }
    end
    return marks
end

return M
```

- [ ] **Step 4: Run it**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/overlay_render_spec.lua`
Expected: `overlay_render_spec: ok`.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add lua/jpr/render/overlay.lua tests/lua/overlay_render_spec.lua
git commit -m "feat(nvim): render a file diff as extmark specs"
```

---

### Task 19: Changed files open as diffs

**Files:**
- Create: `lua/jpr/views/main_window.lua`, `lua/jpr/views/diff.lua`
- Modify: `lua/jpr/session.lua`
- Create: `tests/lua/diff_view_spec.lua`

Whenever a window in the review's tab shows a file the pull request changes, `views/diff` asks the engine for its `fileDiff` and draws it: extmarks in unified mode, or a read-only base window on the left with `diffthis` in split mode. A window that moves on to another buffer is cleared (its base window closes and diff mode goes off). `:Jpr toggle` and a moved head or base redraw every window; a save redraws that buffer's overlay.

Side windows (the panel, a base window, later the stream's left half) carry `vim.w.jpr_side`, so `main_window` can find the window beside the panel where files and the stream show.

- [ ] **Step 1: Write the failing spec**

Create `tests/lua/diff_view_spec.lua`:

```lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local view_mode = require("jpr.view_mode")

view_mode.path = vim.fn.tempname()
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })
local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")
vim.fn.writefile({ "untouched" }, worktree .. "/OTHER.md")

session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "the review syncs")

local win = main_window.find(review)
main_window.edit(review, win, "README.md", 1)
local buf = vim.api.nvim_win_get_buf(win)
local namespace = vim.api.nvim_create_namespace("jpr-diff")

-- Unified: the added line is colored, and the removed line is drawn above it.
assert(vim.wait(3000, function()
    return #vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}) > 0
end), "the overlay is drawn")
local has_added_line, removed_text = false, nil
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
    local details = mark[4]
    if mark[2] == 1 and details.line_hl_group == "JprDiffAdd" then
        has_added_line = true
    end
    if details.virt_lines then
        removed_text = details.virt_lines[1][1][1]
    end
end
assert(has_added_line, "line 2 is an added line")
assert(removed_text == "old", "the removed line sits above it: " .. vim.inspect(removed_text))

-- Split: a read-only base window opens on the left, both in diff mode.
vim.api.nvim_set_current_win(win)
session.toggle_view()
assert(view_mode.get() == "split", "the view is split now")
local function base_window()
    for _, other in ipairs(vim.api.nvim_tabpage_list_wins(review.tab)) do
        if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(other)):find("jpr://base/7/README.md", 1, true) then
            return other
        end
    end
end
assert(vim.wait(3000, function()
    return base_window() ~= nil
end), "a base window opens")
local base = base_window()
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(base), 0, -1, false), { "hello", "old" }), "it shows the base")
assert(vim.wo[base].diff and vim.wo[win].diff, "both windows are in diff mode")
assert(#vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}) == 0, "the unified overlay is gone")
assert(main_window.find(review) == win, "the base window is a side window")

-- Leaving the file closes its base window and turns diff mode off.
vim.cmd.edit(vim.fn.fnameescape(worktree .. "/OTHER.md"))
assert(vim.wait(3000, function()
    return not vim.api.nvim_win_is_valid(base)
end), "the base window closes")
assert(not vim.wo[win].diff, "diff mode is off")

session.toggle_view()
assert(view_mode.get() == "unified", "toggled back")
session.close_current()
print("diff_view_spec: ok")
```

- [ ] **Step 2: Run it to see it fail**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/diff_view_spec.lua`
Expected: FAIL: `module 'jpr.views.main_window' not found`.

- [ ] **Step 3: Implement `main_window.lua`**

Create `lua/jpr/views/main_window.lua`:

```lua
-- The window beside the panel, where the stream and the files show. jpr's
-- side windows (the panel, a base file, the stream's left half) never count.
local M = {}

--- Whether `win` is one of jpr's side windows rather than the main window.
function M.is_side(session, win)
    return (session.panel ~= nil and win == session.panel.win) or vim.w[win].jpr_side == true
end

--- The main window of `session`'s tab, opened right of the panel when there
--- is none.
function M.find(session)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
        if not M.is_side(session, win) then
            return win
        end
    end
    local panel = session.panel
    local anchor = (panel and vim.api.nvim_win_is_valid(panel.win)) and panel.win or vim.api.nvim_get_current_win()
    local placeholder = vim.api.nvim_create_buf(false, true)
    vim.bo[placeholder].bufhidden = "wipe"
    return vim.api.nvim_open_win(placeholder, false, { split = "right", win = anchor })
end

--- Opens `path` (from the pull request, so untrusted) in `win`, focused, at
--- `line` when given.
function M.edit(session, win, path, line)
    vim.api.nvim_set_current_win(win)
    -- Anchored in the worktree, so a leading `+cmd`, `~` or `-` is not
    -- special, and escaped, so `%`, `#` and spaces are taken literally.
    vim.cmd.edit(vim.fn.fnameescape(session.worktree .. "/" .. path))
    if line then
        local last = vim.api.nvim_buf_line_count(0)
        vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(line, last)), 0 })
    end
end

return M
```

- [ ] **Step 4: Implement `views/diff.lua`**

Create `lua/jpr/views/diff.lua`:

```lua
-- Changed files shown as diffs: extmark overlays on the file itself
-- (unified), or Neovim's diff mode beside a read-only base buffer (split).
-- The engine computes every diff; this only draws it and manages the base
-- windows.
local overlay = require("jpr.render.overlay")
local view_mode = require("jpr.view_mode")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-diff")

local function session_module()
    return require("jpr.session")
end

--- `path` with every symlink resolved, even when its last parts do not exist
--- (a file the pull request deletes).
local function real_path(path)
    local real = vim.uv.fs_realpath(path)
    if real then
        return real
    end
    local parent = vim.fs.dirname(path)
    if parent == path then
        return path
    end
    return vim.fs.joinpath(real_path(parent), vim.fs.basename(path))
end

--- `name`'s path relative to `worktree`, or nil when it is not inside it.
function M.relative_path(worktree, name)
    if name == "" then
        return nil
    end
    local root = real_path((vim.fn.fnamemodify(worktree, ":p"):gsub("/+$", "")))
    local full = real_path(vim.fn.fnamemodify(name, ":p"))
    if full:sub(1, #root + 1) ~= root .. "/" then
        return nil
    end
    return full:sub(#root + 2)
end

--- The changed file `buf` shows, as its path in the pull request, or nil.
function M.changed_path(session, buf)
    if vim.bo[buf].buftype ~= "" then
        return nil
    end
    local path = M.relative_path(session.worktree, vim.api.nvim_buf_get_name(buf))
    for _, file in ipairs((session.view and session.view.files) or {}) do
        if file.path == path then
            return path
        end
    end
    return nil
end

--- Shows the file in `win` as a diff in the current mode, unless it already
--- does.
function M.apply(session, win)
    local buf = vim.api.nvim_win_get_buf(win)
    local path = M.changed_path(session, buf)
    local mode = view_mode.get()
    local applied = session.diff.applied[win]
    if not path or not session.client or (applied and applied.buf == buf and applied.mode == mode) then
        return
    end
    local record = { buf = buf, mode = mode }
    session.diff.applied[win] = record
    session_module().request(session, "fileDiff", { path = path }, function(diff)
        local is_wanted = session.diff
            and session.diff.applied[win] == record
            and vim.api.nvim_win_is_valid(win)
            and vim.api.nvim_win_get_buf(win) == buf
        if not is_wanted then
            return
        end
        if diff.binary then
            return require("jpr").info(("%s is a binary file; it has no diff"):format(path))
        end
        if mode == "unified" then
            M.draw_overlay(buf, diff, win)
        else
            M.open_base(session, win, buf, diff)
        end
    end)
end

--- Draws `diff` on `buf` as extmarks: added lines, changed words, and the
--- removed lines as virtual lines.
function M.draw_overlay(buf, diff, win)
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    local opts = { width = vim.api.nvim_win_get_width(win), tabstop = vim.bo[buf].tabstop }
    for _, mark in ipairs(overlay.build(diff, vim.api.nvim_buf_line_count(buf), opts)) do
        -- A buffer edited since its last save can be shorter than the diff.
        local mark_opts = vim.tbl_extend("force", mark.opts, { strict = false })
        pcall(vim.api.nvim_buf_set_extmark, buf, namespace, mark.line, mark.col, mark_opts)
    end
end

--- Opens `diff`'s base in a read-only window left of `win`, and turns on
--- diff mode in both.
function M.open_base(session, win, buf, diff)
    local base_buf = vim.api.nvim_create_buf(false, true)
    -- A second window on the same file makes a second base; the name is only
    -- for display, so a clash is harmless.
    pcall(vim.api.nvim_buf_set_name, base_buf, ("jpr://base/%d/%s"):format(session.number, diff.path))
    vim.api.nvim_buf_set_lines(base_buf, 0, -1, false, overlay.text_lines(diff.baseText))
    vim.bo[base_buf].bufhidden = "wipe"
    vim.bo[base_buf].modifiable = false
    vim.bo[base_buf].filetype = vim.bo[buf].filetype
    local base_win = vim.api.nvim_open_win(base_buf, false, { split = "left", win = win })
    vim.w[base_win].jpr_side = true
    session.diff.splits[win] = { base_win = base_win }
    for _, diff_win in ipairs({ base_win, win }) do
        vim.api.nvim_win_call(diff_win, function()
            vim.cmd("diffthis")
        end)
    end
end

--- Stops showing `win`'s file as a diff: clears the overlay, closes the base
--- window and turns diff mode off.
function M.clear(session, win)
    if not session.diff then
        return
    end
    local applied = session.diff.applied[win]
    session.diff.applied[win] = nil
    if applied and vim.api.nvim_buf_is_valid(applied.buf) then
        vim.api.nvim_buf_clear_namespace(applied.buf, namespace, 0, -1)
    end
    local split = session.diff.splits[win]
    session.diff.splits[win] = nil
    if not split then
        return
    end
    if vim.api.nvim_win_is_valid(split.base_win) then
        pcall(vim.api.nvim_win_close, split.base_win, true)
    end
    if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_call(win, function()
            vim.cmd("diffoff")
        end)
    end
end

--- Brings every window of `session`'s tab in line: one that no longer shows
--- the buffer it was drawn for is cleared, and one showing a changed file
--- gets its diff.
function M.reconcile(session)
    if not session.diff then
        return
    end
    for win, applied in pairs(session.diff.applied) do
        if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= applied.buf then
            M.clear(session, win)
        end
    end
    if not vim.api.nvim_tabpage_is_valid(session.tab) then
        return
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
        M.apply(session, win)
    end
end

--- Draws every diff of `session`'s tab again, for a new view mode or new
--- commits.
function M.redraw_all(session)
    if not session.diff then
        return
    end
    -- Clearing a field while traversing is allowed; adding one is not, so
    -- the redraw happens after the loop.
    for win in pairs(session.diff.applied) do
        M.clear(session, win)
    end
    M.reconcile(session)
end

--- Redraws `buf`'s unified overlays after a save changed it on disk.
function M.refresh_buffer(session, buf)
    local windows = {}
    for win, applied in pairs(session.diff.applied) do
        if applied.buf == buf and applied.mode == "unified" then
            windows[#windows + 1] = win
        end
    end
    for _, win in ipairs(windows) do
        M.clear(session, win)
        M.apply(session, win)
    end
end

--- Keeps `session`'s windows drawn as diffs for as long as it lives.
function M.attach(session)
    local group = vim.api.nvim_create_augroup(("jpr-diff-%d"):format(session.tab), { clear = true })
    session.diff = { applied = {}, splits = {}, group = group }
    vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinClosed" }, {
        group = group,
        callback = function()
            vim.schedule(function()
                if session.diff and vim.api.nvim_get_current_tabpage() == session.tab then
                    M.reconcile(session)
                end
            end)
        end,
    })
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        callback = function(event)
            if session.diff and M.changed_path(session, event.buf) then
                M.refresh_buffer(session, event.buf)
            end
        end,
    })
end

--- Clears every diff of `session` and stops following its windows.
function M.detach(session)
    if not session.diff then
        return
    end
    pcall(vim.api.nvim_del_augroup_by_id, session.diff.group)
    for win in pairs(session.diff.applied) do
        M.clear(session, win)
    end
    session.diff = nil
end

return M
```

- [ ] **Step 5: Wire it into the session**

In `lua/jpr/session.lua`:

Add, after `M.current`:

```lua
--- Sends `method` with `params` to `session`'s engine. `on_result(result)`
--- runs on success; a failure is passed to `on_error`, when given, and
--- reported to the user unless the session is closing (a request still in
--- flight then fails because the engine was stopped on purpose).
function M.request(session, method, params, on_result, on_error)
    if not session.client then
        if on_error then
            on_error()
        end
        return jpr().error(
            ("the review engine for PR #%d is not running; run :Jpr open %d"):format(session.number, session.number)
        )
    end
    session.client:request(method, params, function(err, result)
        if err then
            if on_error then
                on_error(err)
            end
            if session.closing then
                return
            end
            return jpr().error(("%s failed: %s"):format(method, err.message))
        end
        on_result(result)
    end)
end
```

In `forget`, before `panel.close(session)`:

```lua
    require("jpr.views.diff").detach(session)
```

In `M.start`, right after `session.placeholder_buf = vim.api.nvim_get_current_buf()`:

```lua
    require("jpr.views.diff").attach(session)
```

Replace `M.show` with:

```lua
--- Whether the pull request's head or base commit moved between `previous`
--- and `view`, which changes every diff.
function M.commits_changed(previous, view)
    local before, after = previous and previous.pr, view.pr
    if not before or not after then
        return false
    end
    return before.headSha ~= after.headSha or before.baseSha ~= after.baseSha
end

--- Keeps `view` as the session's latest and redraws from it: the panel
--- always, and the diffs once the pull request is known.
function M.show(session, view)
    local previous = session.view
    session.view = view
    panel.render(session, view)
    if not view.pr then
        return
    end
    local diff = require("jpr.views.diff")
    if M.commits_changed(previous, view) then
        diff.redraw_all(session)
    else
        diff.reconcile(session)
    end
end
```

In `M.on_notification`, redraw on `viewedChanged` as on `synced`:

```lua
    if method == "event" and params and (params.type == "synced" or params.type == "viewedChanged") then
        M.show(session, params.view)
```

In `M.toggle_view`, redraw every review's diffs:

```lua
function M.toggle_view()
    local mode = require("jpr.view_mode").toggle()
    for _, session in pairs(M.by_tab) do
        require("jpr.views.diff").redraw_all(session)
    end
    jpr().info(("%s view"):format(mode))
end
```

- [ ] **Step 6: Run the specs**

Run: `./scripts/test-lua.sh`
Expected: every spec prints `ok`, including `diff_view_spec`.

- [ ] **Step 7: Gate and commit**

```bash
just check
git add lua tests
git commit -m "feat(nvim): open changed files as unified or split diffs"
```

---
### Task 20: The stream renderer (pure)

**Files:**
- Create: `lua/jpr/render/stream.lua`
- Create: `tests/lua/stream_render_spec.lua`

Turns a `StreamView` into one column (unified) or two aligned columns (split) of lines and highlights, plus what each line leads to: the file and line `<CR>` opens, the file headers and hunks the navigation keys jump between, and the folds of viewed files. Line gutters: unified `%5s %5s %s ` (old number, new number, sign; 14 bytes), split `%5d %s ` (number, sign; 8 bytes).

- [ ] **Step 1: Write the failing spec**

Create `tests/lua/stream_render_spec.lua`:

```lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local stream = require("jpr.render.stream")

local function cell(line, text, change, words)
    return { line = line, text = text, change = change, words = words or {} }
end
local x_word = { { start = 4, ["end"] = 5 } }
local rows = {
    { kind = "file", path = "a.rs", additions = 1, deletions = 1, viewed = "UNVIEWED", folded = false },
    { kind = "hunk", path = "a.rs", header = "@@ -1,2 +1,2 @@", target = 1 },
    { kind = "line", path = "a.rs", left = cell(1, "keep", "context"), right = cell(1, "keep", "context"), target = 1 },
    { kind = "line", path = "a.rs", left = cell(2, "x = 1", "removed", x_word), target = 2 },
    { kind = "line", path = "a.rs", right = cell(2, "x = 2", "added", x_word), target = 2 },
    { kind = "file", path = "b.rs", additions = 1, deletions = 0, viewed = "VIEWED", folded = true },
    { kind = "hunk", path = "b.rs", header = "@@ -0,0 +1,1 @@", target = 1 },
    { kind = "line", path = "b.rs", right = cell(1, "new", "added"), target = 1 },
    { kind = "file", path = "c.png", additions = 0, deletions = 0, viewed = "DISMISSED", folded = false },
    { kind = "note", path = "c.png", text = "binary file" },
}

local unified = stream.build({ mode = "unified", rows = rows })
local column = unified.columns[1]
assert(#unified.columns == 1, "one column")
assert(vim.deep_equal(column.lines, {
    "▾   a.rs  +1 -1",
    "@@ -1,2 +1,2 @@",
    "    1     1   keep",
    "    2       - x = 1",
    "          2 + x = 2",
    "▸ ✓ b.rs  +1 -0",
    "@@ -0,0 +1,1 @@",
    "          1 + new",
    "▾ ● c.png  +0 -0",
    "  binary file",
}), vim.inspect(column.lines))
assert(column.line_groups[1] == "JprFileHeader" and column.line_groups[2] == "JprHunk", "headers")
assert(column.line_groups[3] == nil, "context is not colored")
assert(column.line_groups[4] == "JprDiffDelete" and column.line_groups[5] == "JprDiffAdd", "changes")
assert(column.line_groups[10] == "JprMuted", "notes are muted")
assert(vim.deep_equal(column.highlights, {
    { line = 3, col_start = 18, col_end = 19, group = "JprDiffDeleteText" },
    { line = 4, col_start = 18, col_end = 19, group = "JprDiffAddText" },
}), vim.inspect(column.highlights))
assert(vim.deep_equal(unified.targets[4], { path = "a.rs", line = 2 }), "a removed line leads to its place")
assert(vim.deep_equal(unified.targets[6], { path = "b.rs", line = 1 }), "a header leads to the top")
assert(unified.targets[10] == nil, "a note leads nowhere")
assert(vim.deep_equal(unified.hunks, { 2, 7 }), vim.inspect(unified.hunks))
assert(vim.deep_equal(unified.folds, { { first = 7, last = 8 } }), "a viewed file's body is folded")
assert(#unified.files == 3 and unified.files[2].line == 6 and unified.files[2].viewed == "VIEWED", vim.inspect(unified.files))

local split = stream.build({
    mode = "split",
    rows = {
        rows[1],
        rows[2],
        rows[3],
        { kind = "line", path = "a.rs", left = cell(2, "x = 1", "removed", x_word), right = cell(2, "x = 2", "added", x_word), target = 2 },
        { kind = "line", path = "a.rs", right = cell(3, "y", "added"), target = 3 },
    },
})
assert(#split.columns == 2, "two columns")
assert(vim.deep_equal(split.columns[1].lines, { "▾   a.rs  +1 -1", "@@ -1,2 +1,2 @@", "    1   keep", "    2 - x = 1", "" }), vim.inspect(split.columns[1].lines))
assert(vim.deep_equal(split.columns[2].lines, { "▾   a.rs  +1 -1", "@@ -1,2 +1,2 @@", "    1   keep", "    2 + x = 2", "    3 + y" }), vim.inspect(split.columns[2].lines))
assert(split.columns[1].line_groups[5] == "JprDiffFiller", "filler keeps the columns aligned")
assert(split.columns[2].highlights[1].col_start == 12, "the split gutter is 8 bytes")

assert(stream.file_at(unified, 5).path == "a.rs" and stream.file_at(unified, 6).path == "b.rs", "file_at")
assert(stream.next_unviewed(unified, 1).path == "c.png", "a viewed file is skipped and a dismissed one is not")
assert(stream.next_unviewed(unified, 9) == nil, "nothing after the last file")
assert(stream.next_line({ 2, 7 }, 2, 1) == 7 and stream.next_line({ 2, 7 }, 7, 1) == nil, "next")
assert(stream.next_line({ 2, 7 }, 7, -1) == 2 and stream.next_line({ 2, 7 }, 2, -1) == nil, "previous")

local view = { pr = { headSha = "h", baseSha = "b" }, files = { { path = "a.rs", additions = 1, deletions = 1, viewed = "UNVIEWED" } } }
local key = stream.key(view)
assert(stream.key(view) == key, "the same view, the same key")
view.files[1].viewed = "VIEWED"
assert(stream.key(view) ~= key, "a viewed change changes the key")

print("stream_render_spec: ok")
```

- [ ] **Step 2: Run it to see it fail**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/stream_render_spec.lua`
Expected: FAIL: `module 'jpr.render.stream' not found`.

- [ ] **Step 3: Implement it**

Create `lua/jpr/render/stream.lua`:

```lua
-- Pure: turns the engine's StreamView into the lines and highlights of one
-- column (unified) or two aligned columns (split), plus what each line
-- leads to. No windows or buffers here.
local one_line = require("jpr.render.panel").one_line

local M = {}

local VIEWED_MARK = { VIEWED = "✓", DISMISSED = "●", UNVIEWED = " " }
local SIGN = { added = "+", removed = "-", context = " " }
local LINE_GROUP = { added = "JprDiffAdd", removed = "JprDiffDelete" }
local WORD_GROUP = { added = "JprDiffAddText", removed = "JprDiffDeleteText" }

--- A file row's header line, such as `▾ ✓ src/a.rs  +12 -3`; `▸` marks a
--- folded file.
function M.file_header(row)
    return ("%s %s %s  +%d -%d"):format(
        row.folded and "▸" or "▾",
        VIEWED_MARK[row.viewed] or " ",
        one_line(row.path),
        row.additions,
        row.deletions
    )
end

local function new_column()
    return { lines = {}, line_groups = {}, highlights = {} }
end

--- Appends `text` to `column`, colored whole by `group` when given.
local function add_line(column, text, group)
    column.lines[#column.lines + 1] = text
    if group then
        column.line_groups[#column.lines] = group
    end
end

--- Highlights `cell`'s changed words on `column`'s last line, after a gutter
--- of `gutter` bytes.
local function add_words(column, cell, gutter)
    for _, word in ipairs(cell.words or {}) do
        column.highlights[#column.highlights + 1] = {
            line = #column.lines - 1,
            col_start = gutter + word.start,
            col_end = gutter + word["end"],
            group = WORD_GROUP[cell.change],
        }
    end
end

--- A unified row: both line numbers, the sign, and the text.
local function add_unified(column, row)
    local cell = row.right or row.left
    local gutter = ("%5s %5s %s "):format(row.left and row.left.line or "", row.right and row.right.line or "", SIGN[cell.change])
    add_line(column, gutter .. cell.text, LINE_GROUP[cell.change])
    add_words(column, cell, #gutter)
end

--- One side of a split row, or a filler line when that side has none.
local function add_split_cell(column, cell)
    if not cell then
        return add_line(column, "", "JprDiffFiller")
    end
    local gutter = ("%5d %s "):format(cell.line, SIGN[cell.change])
    add_line(column, gutter .. cell.text, LINE_GROUP[cell.change])
    add_words(column, cell, #gutter)
end

local function add_to_all(columns, text, group)
    for _, column in ipairs(columns) do
        add_line(column, text, group)
    end
end

--- Folds lines `first` to `last` when a folded file's body has any.
local function close_fold(built, first, last)
    if first and first <= last then
        built.folds[#built.folds + 1] = { first = first, last = last }
    end
end

--- Adds a hunk, note or line row as line `line`.
local function add_body_row(built, row, line)
    if row.kind == "hunk" then
        add_to_all(built.columns, row.header, "JprHunk")
        built.hunks[#built.hunks + 1] = line
    elseif row.kind == "note" then
        add_to_all(built.columns, "  " .. one_line(row.text), "JprMuted")
    elseif #built.columns == 2 then
        add_split_cell(built.columns[1], row.left)
        add_split_cell(built.columns[2], row.right)
    else
        add_unified(built.columns[1], row)
    end
    if row.target then
        built.targets[line] = { path = row.path, line = row.target }
    end
end

--- The lines of `stream` and where each leads:
--- { mode, columns, targets, files, hunks, folds }. `columns` holds one
--- column when unified and two (left, right) when split; a column is
--- { lines, line_groups, highlights } with `line_groups` keyed by 1-based
--- line and `highlights[].line` 0-based. `targets[line]` is the { path, line }
--- the line opens, `files` the { line, path, viewed } of each header,
--- `hunks` the hunk header lines, and `folds` the { first, last } bodies of
--- viewed files.
function M.build(stream)
    local is_split = stream.mode == "split"
    local built = {
        mode = stream.mode,
        columns = is_split and { new_column(), new_column() } or { new_column() },
        targets = {},
        files = {},
        hunks = {},
        folds = {},
    }
    local fold_start
    for _, row in ipairs(stream.rows or {}) do
        local line = #built.columns[1].lines + 1
        if row.kind == "file" then
            close_fold(built, fold_start, line - 1)
            fold_start = row.folded and line + 1 or nil
            add_to_all(built.columns, M.file_header(row), "JprFileHeader")
            built.files[#built.files + 1] = { line = line, path = row.path, viewed = row.viewed }
            built.targets[line] = { path = row.path, line = 1 }
        else
            add_body_row(built, row, line)
        end
    end
    close_fold(built, fold_start, #built.columns[1].lines)
    return built
end

--- The file whose section holds `line`, as an entry of `built.files`.
function M.file_at(built, line)
    local found
    for _, file in ipairs(built.files) do
        if file.line > line then
            break
        end
        found = file
    end
    return found
end

--- The first file after `line` that is not viewed, for moving on once a
--- file is marked viewed.
function M.next_unviewed(built, line)
    for _, file in ipairs(built.files) do
        if file.line > line and file.viewed ~= "VIEWED" then
            return file
        end
    end
    return nil
end

--- The nearest of the sorted `lines` after `line` when `step` is 1, or
--- before it when `step` is -1.
function M.next_line(lines, line, step)
    local found
    for _, candidate in ipairs(lines) do
        if step > 0 and candidate > line then
            return candidate
        end
        if step < 0 and candidate < line then
            found = candidate
        end
    end
    return found
end

--- What the stream is drawn from, as one string: the commits and each
--- file's counts and viewed state. A view with the same key draws the same
--- stream, so it need not be fetched again.
function M.key(view)
    local parts = { view.pr and view.pr.headSha or "", view.pr and view.pr.baseSha or "" }
    for _, file in ipairs(view.files or {}) do
        parts[#parts + 1] = table.concat({ file.path, file.additions, file.deletions, file.viewed }, "\0")
    end
    return table.concat(parts, "\n")
end

return M
```

- [ ] **Step 4: Run it**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/stream_render_spec.lua`
Expected: `stream_render_spec: ok`.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add lua/jpr/render/stream.lua tests/lua/stream_render_spec.lua
git commit -m "feat(nvim): lay the stream out as unified or split columns"
```

---

### Task 21: The stream window

**Files:**
- Create: `lua/jpr/views/stream.lua`
- Modify: `lua/jpr/views/diff.lua`, `lua/jpr/session.lua`, `lua/jpr/init.lua`, `plugin/jpr.lua`
- Create: `tests/lua/stream_view_spec.lua`
- Modify: `tests/lua/command_spec.lua`

The stream opens in the main window once the pull request first syncs, unless the reviewer already put a file there. In split mode it is two buffers, `jpr://stream/<n>/base` on the left and `jpr://stream/<n>` on the right, scroll- and cursor-bound. It is fetched again when its key changes (viewed state, counts, commits), after a save, and on `:Jpr toggle`. Window options are set with `setlocal` scope, so a file opened in the same window later gets its own options back.

| Key | Action |
| --- | --- |
| `<CR>` | Open the real file at that line in the main window (closing the left half) |
| `v` | Toggle viewed, then move to the next unviewed file once the stream redraws |
| `]f` / `[f` | Next / previous file header |
| `]h` / `[h` | Next / previous hunk |

- [ ] **Step 1: Write the failing spec**

Create `tests/lua/stream_view_spec.lua`:

```lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local session = require("jpr.session")
local stream_view = require("jpr.views.stream")
local view_mode = require("jpr.view_mode")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })
local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")

session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
local function main_lines()
    local buf = review.stream and review.stream.buffers.main
    return buf and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or {}
end
assert(vim.wait(3000, function()
    return #main_lines() == 5
end), "the stream opens: " .. vim.inspect(main_lines()))
assert(vim.deep_equal(main_lines(), {
    "▾   README.md  +2 -1",
    "@@ -1,2 +1,2 @@",
    "    1     1   hello",
    "    2       - old",
    "          2 + new",
}), vim.inspect(main_lines()))
local stream_win = vim.fn.win_findbuf(review.stream.buffers.main)[1]
assert(stream_win and stream_win ~= review.panel.win, "it shows in the main window, beside the panel")

-- ]h moves to the hunk, and <CR> opens the real file at that line.
vim.api.nvim_set_current_win(stream_win)
vim.api.nvim_win_set_cursor(stream_win, { 1, 0 })
stream_view.jump(review, "hunks", 1)
assert(vim.api.nvim_win_get_cursor(stream_win)[1] == 2, "]h")
vim.api.nvim_win_set_cursor(stream_win, { 5, 0 })
stream_view.open_target(review)
assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/README.md"), "<CR> opens the file")
assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "at its line")

-- :Jpr stream brings it back; :Jpr toggle splits it into two aligned halves.
session.stream_current()
assert(vim.wait(3000, function()
    return vim.api.nvim_get_current_buf() == review.stream.buffers.main
end), ":Jpr stream shows and focuses the stream")
session.toggle_view()
assert(vim.wait(3000, function()
    return review.stream.left_win ~= nil and vim.api.nvim_win_is_valid(review.stream.left_win)
end), "the left half opens")
local left_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(review.stream.left_win), 0, -1, false)
assert(vim.deep_equal(left_lines, { "▾   README.md  +2 -1", "@@ -1,2 +1,2 @@", "    1   hello", "    2 - old" }), vim.inspect(left_lines))
assert(vim.deep_equal(main_lines(), { "▾   README.md  +2 -1", "@@ -1,2 +1,2 @@", "    1   hello", "    2 + new" }), vim.inspect(main_lines()))
assert(vim.wo[review.stream.left_win].scrollbind, "the halves scroll together")

-- v marks the file viewed on the engine.
vim.api.nvim_set_current_win(vim.fn.win_findbuf(review.stream.buffers.main)[1])
vim.api.nvim_win_set_cursor(0, { 3, 0 })
stream_view.toggle_viewed(review)
assert(vim.wait(3000, function()
    return review.view.viewedCount == 1
end), "the engine's viewedChanged reaches the view")
local sent = table.concat(vim.fn.readfile(log), "\n")
assert(sent:find('"method":"setViewed"', 1, true) and sent:find('"viewed":true', 1, true), sent)
assert(sent:find('"path":"README.md"', 1, true), sent)

session.toggle_view()
session.close_current()
print("stream_view_spec: ok")
```

In `tests/lua/command_spec.lua`, change the completion assertions to:

```lua
assert(vim.deep_equal(jpr.complete("", "Jpr "), { "open", "sync", "toggle", "stream", "close" }), "all subcommands")
assert(vim.deep_equal(jpr.complete("s", "Jpr s"), { "sync", "stream" }), "filtered subcommands")
```

- [ ] **Step 2: Run the specs to see them fail**

Run: `./scripts/test-lua.sh`
Expected: `stream_view_spec` fails (`module 'jpr.views.stream' not found`) and `command_spec` fails (no `stream` subcommand).

- [ ] **Step 3: Implement `views/stream.lua`**

Create `lua/jpr/views/stream.lua`:

```lua
-- The stream: every changed file in one scrolling buffer (unified), or in two
-- scroll-bound buffers padded to align (split), in the window beside the
-- panel. The engine builds the rows; render.stream lays them out.
local main_window = require("jpr.views.main_window")
local render = require("jpr.render.stream")
local view_mode = require("jpr.view_mode")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-stream")

local function session_module()
    return require("jpr.session")
end

--- `session`'s stream state: its buffers, the left window, the last build.
function M.state(session)
    session.stream = session.stream or { buffers = {} }
    return session.stream
end

--- The stream's `main` or `left` buffer, made on first use.
local function stream_buffer(session, key)
    local state = M.state(session)
    local existing = state.buffers[key]
    if existing and vim.api.nvim_buf_is_valid(existing) then
        return existing
    end
    local buf = vim.api.nvim_create_buf(false, true)
    local suffix = key == "left" and "/base" or ""
    pcall(vim.api.nvim_buf_set_name, buf, ("jpr://stream/%d%s"):format(session.number, suffix))
    vim.bo[buf].filetype = "jpr-stream"
    vim.bo[buf].modifiable = false
    M.map_keys(session, buf)
    if key == "main" then
        -- Leaving the stream for a file takes its left half with it.
        vim.api.nvim_create_autocmd("BufWinLeave", {
            buffer = buf,
            callback = function()
                vim.schedule(function()
                    M.close_left(session)
                end)
            end,
        })
    end
    state.buffers[key] = buf
    return buf
end

--- Whether the stream is on screen.
function M.is_visible(session)
    local buf = session.stream and session.stream.buffers.main
    return buf ~= nil and vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0
end

--- Fetches the stream in the current view mode and draws it. opts:
--- `only_if_free` leaves the main window alone when it shows something the
--- reviewer chose; `focus` moves the cursor into the stream.
function M.show(session, opts)
    session_module().request(session, "stream", { mode = view_mode.get() }, function(stream)
        M.draw(session, stream, opts or {})
    end)
end

--- Fetches the stream again if it is on screen and its view changed, or
--- always when `force` is set (a file was saved, or the mode changed). If
--- the reviewer opened a file meanwhile, the answer only fills the buffers.
function M.refresh(session, force)
    local state = session.stream
    if not state or not M.is_visible(session) then
        return
    end
    if force or render.key(session.view or {}) ~= state.key then
        M.show(session, { only_if_free = true })
    end
end

--- Replaces `buf`'s lines and highlights with `column`'s, keeping each
--- window's cursor line.
function M.fill(buf, column)
    local cursors = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        cursors[win] = vim.api.nvim_win_get_cursor(win)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, column.lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    for line, group in pairs(column.line_groups) do
        vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, { line_hl_group = group })
    end
    for _, highlight in ipairs(column.highlights) do
        vim.api.nvim_buf_set_extmark(buf, namespace, highlight.line, highlight.col_start, {
            end_col = highlight.col_end,
            hl_group = highlight.group,
            strict = false,
        })
    end
    for win, cursor in pairs(cursors) do
        pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, math.min(cursor[1], #column.lines)), 0 })
    end
end

--- Whether `win` shows nothing the reviewer chose: an empty unnamed buffer
--- (a new tab's) or the stream itself.
local function is_free(session, win)
    local buf = vim.api.nvim_win_get_buf(win)
    local buffers = session.stream.buffers
    if buf == buffers.main or buf == buffers.left then
        return true
    end
    return vim.api.nvim_buf_get_name(buf) == "" and not vim.bo[buf].modified
end

--- Draws `stream` into its buffers and, unless `opts.only_if_free` finds the
--- main window taken, into the windows beside the panel.
function M.draw(session, stream, opts)
    local state = M.state(session)
    local built = render.build(stream)
    state.built, state.key = built, render.key(session.view or {})
    local main_buf = stream_buffer(session, "main")
    local buffers = #built.columns == 2 and { stream_buffer(session, "left"), main_buf } or { main_buf }
    for index, column in ipairs(built.columns) do
        M.fill(buffers[index], column)
    end
    if opts.only_if_free and not is_free(session, main_window.find(session)) then
        return
    end
    local wins = M.place(session, buffers)
    for _, win in ipairs(wins) do
        M.set_folds(win, built.folds)
    end
    if opts.focus then
        vim.api.nvim_set_current_win(wins[#wins])
    end
    if state.after_draw then
        local after_draw = state.after_draw
        state.after_draw = nil
        after_draw(built)
    end
end

--- The stream's look in `win`, local to the stream's buffer: no wrapping,
--- numbers or sign column, manual folds, and, when `is_bound`, scrolling
--- and the cursor bound to the other half.
local function style(win, is_bound)
    local function set(name, value)
        vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
    end
    set("wrap", false)
    set("number", false)
    set("relativenumber", false)
    set("signcolumn", "no")
    set("cursorline", true)
    set("foldmethod", "manual")
    set("foldenable", true)
    set("scrollbind", is_bound)
    set("cursorbind", is_bound)
end

--- Shows `buffers` (the main one last) beside the panel: the main buffer in
--- the main window and, when split, the left buffer in a bound window on its
--- left. Returns the windows, left to right.
function M.place(session, buffers)
    local state = M.state(session)
    local main_win = main_window.find(session)
    -- Cleared first: a base window's diffoff would undo the stream's options.
    require("jpr.views.diff").clear(session, main_win)
    vim.api.nvim_win_set_buf(main_win, buffers[#buffers])
    if #buffers == 1 then
        M.close_left(session)
        style(main_win, false)
        return { main_win }
    end
    if not (state.left_win and vim.api.nvim_win_is_valid(state.left_win)) then
        state.left_win = vim.api.nvim_open_win(buffers[1], false, { split = "left", win = main_win })
        vim.w[state.left_win].jpr_side = true
    end
    vim.api.nvim_win_set_buf(state.left_win, buffers[1])
    style(state.left_win, true)
    style(main_win, true)
    vim.api.nvim_win_call(main_win, function()
        vim.cmd("syncbind")
    end)
    return { state.left_win, main_win }
end

--- Folds the bodies of viewed files in `win`.
function M.set_folds(win, folds)
    vim.api.nvim_win_call(win, function()
        vim.cmd("silent! normal! zE")
        for _, fold in ipairs(folds) do
            vim.cmd(("%d,%dfold"):format(fold.first, fold.last))
        end
    end)
end

--- Closes the split stream's left window, keeping its buffer.
function M.close_left(session)
    local state = session.stream
    if state and state.left_win and vim.api.nvim_win_is_valid(state.left_win) then
        pcall(vim.api.nvim_win_close, state.left_win, true)
    end
    if state then
        state.left_win = nil
    end
end

--- Closes the stream's windows and wipes its buffers, for a review that ends.
function M.close(session)
    local state = session.stream
    if not state then
        return
    end
    M.close_left(session)
    for _, buf in pairs(state.buffers) do
        if vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end
    session.stream = nil
end

--- Moves the cursor to the next (`step` 1) or previous (-1) file header
--- (`kind` "files") or hunk ("hunks").
function M.jump(session, kind, step)
    local built = session.stream and session.stream.built
    if not built then
        return
    end
    local lines = built.hunks
    if kind == "files" then
        lines = vim.tbl_map(function(file)
            return file.line
        end, built.files)
    end
    local target = render.next_line(lines, vim.api.nvim_win_get_cursor(0)[1], step)
    if target then
        vim.api.nvim_win_set_cursor(0, { target, 0 })
    end
end

--- Opens the real file at the cursor line's place, in the main window.
function M.open_target(session)
    local built = session.stream and session.stream.built
    local target = built and built.targets[vim.api.nvim_win_get_cursor(0)[1]]
    if not target then
        return
    end
    M.close_left(session)
    main_window.edit(session, main_window.find(session), target.path, target.line)
end

--- Marks the file under the cursor viewed, or unviewed again; once the
--- stream redraws, moves to the next file that is not viewed.
function M.toggle_viewed(session)
    local built = session.stream and session.stream.built
    local file = built and render.file_at(built, vim.api.nvim_win_get_cursor(0)[1])
    if not file then
        return
    end
    local win = vim.api.nvim_get_current_win()
    -- The engine's viewedChanged event redraws the stream before it answers.
    session.stream.after_draw = function(new_built)
        local next_file = render.next_unviewed(new_built, file.line)
        if next_file and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_set_cursor, win, { next_file.line, 0 })
        end
    end
    session_module().request(session, "setViewed", { path = file.path, viewed = file.viewed ~= "VIEWED" }, function() end, function()
        if session.stream then
            session.stream.after_draw = nil
        end
    end)
end

--- The stream's keys on `buf`.
function M.map_keys(session, buf)
    local function map(lhs, action, desc)
        vim.keymap.set("n", lhs, function()
            action(session)
        end, { buffer = buf, desc = desc, nowait = true })
    end
    map("<CR>", M.open_target, "Open the file at this line")
    map("v", M.toggle_viewed, "Toggle viewed and go to the next unviewed file")
    map("]f", function(s) M.jump(s, "files", 1) end, "Next file")
    map("[f", function(s) M.jump(s, "files", -1) end, "Previous file")
    map("]h", function(s) M.jump(s, "hunks", 1) end, "Next hunk")
    map("[h", function(s) M.jump(s, "hunks", -1) end, "Previous hunk")
end

return M
```

- [ ] **Step 4: Refresh the stream after a save**

In `lua/jpr/views/diff.lua`, in the `BufWritePost` callback of `M.attach`, after `M.refresh_buffer(session, event.buf)`:

```lua
                require("jpr.views.stream").refresh(session, true)
```

- [ ] **Step 5: Wire it into the session and the commands**

In `lua/jpr/session.lua`:

In `forget`, before `require("jpr.views.diff").detach(session)`:

```lua
    require("jpr.views.stream").close(session)
```

In `M.show`, after the `if not view.pr then return end` guard and before the diff redraw:

```lua
    local stream = require("jpr.views.stream")
    if not session.stream_opened then
        -- The first time only, and never over a file the reviewer opened.
        session.stream_opened = true
        stream.show(session, { only_if_free = true })
    else
        stream.refresh(session)
    end
```

In `M.toggle_view`, inside the loop, after the diff redraw:

```lua
        require("jpr.views.stream").refresh(session, true)
```

Add before `return M`:

```lua
--- `:Jpr stream`: shows the current review's stream beside the panel and
--- focuses it.
function M.stream_current()
    local session = M.current()
    if not session then
        return jpr().error("no pull request is open in this tab")
    end
    require("jpr.views.stream").show(session, { focus = true })
end
```

In `lua/jpr/init.lua`: `M.subcommands = { "open", "sync", "toggle", "stream", "close" }`, and in `M.command`, before the final `else`:

```lua
    elseif subcommand == "stream" then
        require("jpr.session").stream_current()
```

In `plugin/jpr.lua`, set `desc` to `"Review a GitHub pull request (open, sync, toggle, stream, close)"`.

- [ ] **Step 6: Run the specs**

Run: `./scripts/test-lua.sh`
Expected: every spec prints `ok`.

- [ ] **Step 7: Gate and commit**

```bash
just check
git add lua plugin tests
git commit -m "feat(nvim): show every change in the stream beside the panel"
```

---

### Task 22: The panel as a file tree, with `v`

**Files:**
- Modify: `lua/jpr/render/panel.lua`, `lua/jpr/views/panel.lua`
- Modify: `tests/lua/panel_render_spec.lua`

The panel draws the engine's `tree`: directories (muted, with a trailing `/`) and files indented under them. A view without a tree (older test fixtures) falls back to one row per file at the top level. The counts line adds `· N waiting for GitHub` while viewed marks are queued. `v` toggles viewed for the file under the cursor, and `<CR>` opens files through `main_window`, so a file never lands in a side window.

- [ ] **Step 1: Write the failing spec**

In `tests/lua/panel_render_spec.lua`, replace the `view` table, its `built` assertions, and the `highlighted` assertions for the first view (everything from `local view = {` to the `JprTitle` assertion) with:

```lua
local view = {
    pr = { number = 7, title = "Fix the widget" },
    files = {
        { path = "src/a.rs", additions = 12, deletions = 3, viewed = "VIEWED", threads = 2 },
        { path = "src/b.rs", additions = 1, deletions = 0, viewed = "DISMISSED", threads = 0 },
        { path = "docs/x.md", additions = 4, deletions = 4, viewed = "UNVIEWED", threads = 0 },
    },
    tree = {
        { depth = 0, name = "docs" },
        { depth = 1, name = "x.md", file = 2 },
        { depth = 0, name = "src" },
        { depth = 1, name = "a.rs", file = 0 },
        { depth = 1, name = "b.rs", file = 1 },
    },
    viewedCount = 1,
    threadCount = 2,
    queuedCount = 0,
    sync = { state = "synced", at = 100 },
}
local built = panel.build(view, 112)
assert(vim.deep_equal(built.lines, {
    "#7 Fix the widget",
    "viewed 1/3 · threads 2",
    "synced 12s ago",
    "",
    "docs/",
    "    x.md  +4 -4",
    "src/",
    "  ✓ a.rs  +12 -3 [2]",
    "  ● b.rs  +1 -0",
}), vim.inspect(built.lines))
assert(built.paths[6] == "docs/x.md" and built.paths[8] == "src/a.rs" and built.paths[9] == "src/b.rs", vim.inspect(built.paths))
assert(built.paths[5] == nil and built.paths[7] == nil, "directories open nothing")

local function highlighted(result, group)
    local texts = {}
    for _, highlight in ipairs(result.highlights) do
        if highlight.group == group then
            texts[#texts + 1] = result.lines[highlight.line + 1]:sub(highlight.col_start + 1, highlight.col_end)
        end
    end
    return texts
end
assert(vim.deep_equal(highlighted(built, "JprAdded"), { "+4", "+12", "+1" }), vim.inspect(highlighted(built, "JprAdded")))
assert(vim.deep_equal(highlighted(built, "JprRemoved"), { "-4", "-3", "-0" }), vim.inspect(highlighted(built, "JprRemoved")))
assert(vim.deep_equal(highlighted(built, "JprViewed"), { "✓" }), "viewed mark")
assert(vim.deep_equal(highlighted(built, "JprDismissed"), { "●" }), "dismissed mark")
assert(vim.deep_equal(highlighted(built, "JprTitle"), { "#7 Fix the widget" }), "title")
assert(
    vim.deep_equal(highlighted(built, "JprMuted"), { "viewed 1/3 · threads 2", "synced 12s ago", "docs/", "src/" }),
    vim.inspect(highlighted(built, "JprMuted"))
)
local queued = panel.build({ files = {}, queuedCount = 2 }, 0)
assert(queued.lines[2] == "viewed 0/0 · threads 0 · 2 waiting for GitHub", queued.lines[2])
```

Keep the rest of the spec (the failed view, the fresh view, and the multi-line view, which have no `tree` and so test the fallback).

- [ ] **Step 2: Run it to see it fail**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/panel_render_spec.lua`
Expected: FAIL on the lines (the renderer ignores `tree`).

- [ ] **Step 3: Draw the tree**

In `lua/jpr/render/panel.lua`, keep `VIEWED_MARK`, `M.age`, `M.one_line` and `M.sync_text`, and replace `M.build` with:

```lua
--- The counts line: viewed files, threads, and viewed marks still waiting
--- for GitHub.
function M.counts_text(view)
    local text = ("viewed %d/%d · threads %d"):format(view.viewedCount or 0, #(view.files or {}), view.threadCount or 0)
    if (view.queuedCount or 0) > 0 then
        text = text .. (" · %d waiting for GitHub"):format(view.queuedCount)
    end
    return text
end

--- Tree rows for `files` when a view carries no tree: every file at the top
--- level, under its full path.
function M.flat_tree(files)
    local rows = {}
    for index, file in ipairs(files) do
        rows[index] = { depth = 0, name = file.path, file = index - 1 }
    end
    return rows
end

--- Adds one file's line to `built`: indent, viewed mark, name, counts and
--- threads, with their highlights.
local function add_file(built, file, name, indent)
    local mark = VIEWED_MARK[file.viewed] or " "
    local plus = ("+%d"):format(file.additions)
    local stats = ("%s -%d"):format(plus, file.deletions)
    local threads = file.threads > 0 and (" [%d]"):format(file.threads) or ""
    local shown_name = M.one_line(name)
    built.add_line(("%s%s %s  %s%s"):format(indent, mark, shown_name, stats, threads))
    local line = #built.lines - 1
    built.paths[#built.lines] = file.path
    local mark_group = (file.viewed == "VIEWED" and "JprViewed") or (file.viewed == "DISMISSED" and "JprDismissed") or nil
    if mark_group then
        built.highlights[#built.highlights + 1] = { line = line, col_start = #indent, col_end = #indent + #mark, group = mark_group }
    end
    local stats_start = #indent + #mark + 1 + #shown_name + 2
    built.highlights[#built.highlights + 1] = { line = line, col_start = stats_start, col_end = stats_start + #plus, group = "JprAdded" }
    built.highlights[#built.highlights + 1] =
        { line = line, col_start = stats_start + #plus + 1, col_end = stats_start + #stats, group = "JprRemoved" }
end

--- The panel's contents for `view` at time `now` (Unix seconds): its lines,
--- their highlights, and which file each line shows, for the panel window to
--- draw and to open files from.
--- @return table { lines: string[], highlights: { line, col_start, col_end, group }[], paths: table<integer, string> }
--- `line` is 0-based and columns are byte offsets; `paths` is keyed by 1-based line number.
function M.build(view, now)
    local built = { lines = {}, highlights = {}, paths = {} }
    function built.add_line(text, group)
        built.lines[#built.lines + 1] = text
        if group then
            built.highlights[#built.highlights + 1] = { line = #built.lines - 1, col_start = 0, col_end = #text, group = group }
        end
    end
    local pr = view.pr
    built.add_line(pr and ("#%d %s"):format(pr.number, M.one_line(pr.title)) or "Loading pull request…", "JprTitle")
    built.add_line(M.counts_text(view), "JprMuted")
    built.add_line(M.sync_text(view.sync, now))
    built.add_line("")
    local files = view.files or {}
    for _, row in ipairs(view.tree or M.flat_tree(files)) do
        local indent = ("  "):rep(row.depth)
        local file = row.file and files[row.file + 1]
        if file then
            add_file(built, file, row.name, indent)
        else
            built.add_line(indent .. M.one_line(row.name) .. "/", "JprMuted")
        end
    end
    return { lines = built.lines, highlights = built.highlights, paths = built.paths }
end
```

- [ ] **Step 4: Open files through `main_window`, and map `v`**

In `lua/jpr/views/panel.lua`, replace `M.open_file_under_cursor` with:

```lua
--- Opens the file on the cursor line in the main window beside the panel.
function M.open_file_under_cursor(session)
    local panel = session.panel
    local path = panel.paths[vim.api.nvim_win_get_cursor(panel.win)[1]]
    if not path then
        return
    end
    local main_window = require("jpr.views.main_window")
    main_window.edit(session, main_window.find(session), path)
end

--- Marks the file on the cursor line viewed, or unviewed when it is.
function M.toggle_viewed_under_cursor(session)
    local panel = session.panel
    local path = panel.paths[vim.api.nvim_win_get_cursor(panel.win)[1]]
    if not path then
        return
    end
    local viewed
    for _, file in ipairs((session.view and session.view.files) or {}) do
        if file.path == path then
            viewed = file.viewed
        end
    end
    require("jpr.session").request(session, "setViewed", { path = path, viewed = viewed ~= "VIEWED" }, function() end)
end
```

and in `M.open`, after the `<CR>` mapping:

```lua
    vim.keymap.set("n", "v", function()
        M.toggle_viewed_under_cursor(session)
    end, { buffer = buf, desc = "Toggle viewed for the file under the cursor" })
```

- [ ] **Step 5: Run the specs**

Run: `./scripts/test-lua.sh`
Expected: every spec prints `ok` (`untrusted_text_spec` still opens each hostile name as itself, now through `main_window`).

- [ ] **Step 6: Gate and commit**

```bash
just check
git add lua tests
git commit -m "feat(nvim): draw the panel as a file tree and toggle viewed with v"
```

---
### Task 23: Documentation and the version

**Files:**
- Modify: `docs/architecture.md`, `docs/decisions.md`, `README.md`
- Modify: `Cargo.toml` (and `Cargo.lock`)

Tasks 6, 7 and 15 already updated the state table and `docs/protocol.md`. This task brings the rest of the docs up to date and bumps the version for the user-visible addition (`docs/rules/rust.md`: before 1.0, an addition bumps the minor version).

- [ ] **Step 1: Update `docs/architecture.md`**

Replace the layers diagram with:

```
Neovim (lua/jpr)  --JSON-RPC over stdio-->  jpr-review serve (one per PR)
   ^  events                                     | owns the session
   |                                             +--> gh (GitHub)
   +-- draws view models                         +--> git (the worktree)
                                                 +--> state files
```

Replace the generic crates table with:

```markdown
| Crate | Responsibility |
| --- | --- |
| `review-model` | Domain types (pull requests, changed files, threads, anchors, messages) and read models (`SessionView` with its file tree, `FileDiffView`, `StreamView`, `Event`). Pure data. |
| `review-diff` | Line diffs (Histogram) and word diffs (Myers) between two texts through `similar`, and the builders of `FileDiffView` and `StreamView`. Pure functions. |
| `review-core` | The ports (`Forge`, `ReviewStore`, `Workspace`, `Clock`, gathered in `Ports`), the `ReviewSession` facade (one module per use case under `session/`), the viewed rules, and the presenter that builds `SessionView`. The `fakes` feature adds in-memory fakes and the port contract tests. |
| `review-store-fs` | The `ReviewStore` adapter: one directory per PR, three versioned JSON files written atomically (see "State on disk"). |
| `review-forge-github` | The `Forge` adapter: `gh pr view`, `gh api graphql` for threads, files and viewed state, and the viewed mutations, with a 30 second timeout per call. Adapted from dif. |
| `review-workspace-git` | Checks a PR out into a worktree (the default, `git worktree add` plus `gh pr checkout`, or a custom command), and `GitWorkspace`, the `Workspace` adapter: the merge base, files at a commit (`git cat-file --batch`), files on disk, renames. |
| `review-rpc` | The JSON-RPC protocol and a server over any line-based transport, with a background poller that syncs and retries refused viewed marks. |
```

In "Patterns", replace the Presenter bullet with:

```markdown
- **Presenter.** `review_core::session_view` builds the `SessionView` every
  frontend draws, file tree included; `review-diff` builds `FileDiffView`
  (one file) and `StreamView` (every file, laid out unified or split).
```

and the Command/query bullet with:

```markdown
- **Command/query split.** `sync` and `set_viewed` change state; `view`,
  `file_diff` and `stream` read it. The RPC methods follow the same split.
```

Add a subsection at the end of "Process model":

```markdown
### Diffs

A diff compares the merge base of the pull request's base commit
(`baseRefOid`) and the checked-out head with the file on disk, so local edits
show as part of the change. The session finds the merge base once per base
commit (fetching the base commit from `origin` when the repository lacks it)
and caches it with the renames since it and every base text it has read. A
renamed file is compared with its old name. Paths come from GitHub's file
list, so they are untrusted: the session serves diffs only for files that list
names, and `GitWorkspace` refuses absolute paths, `..`, and directory
symlinks out of the worktree, reads a symlink as its target's path instead of
following it, and accepts only hex commit ids.

### Viewed marks

`setViewed` changes the mark at once and sends it to GitHub at once. A mark
GitHub refuses stands, is saved in `github.json`, and is counted in the view's
`queuedCount`. Every sync first resends the queue (stopping at the first
failure) and then lets a still-queued mark win over what it pulled; while the
server polls, it also resends the queue every 20 seconds between syncs. A mark
that lands is announced with `viewedChanged`. GitHub stays the authority:
when a push changes a viewed file, the next sync reports it `DISMISSED`.
```

Change "Later milestones add local threads, the sync registry and agent rounds." to "Later milestones add local threads, the comment queues in `github.json`, and agent rounds."

Replace the Neovim plugin table with:

```markdown
| Module | Responsibility |
| --- | --- |
| `plugin/jpr.lua` | Defines `:Jpr` |
| `jpr` | Config, highlight groups, argument parsing, subcommand dispatch |
| `jpr.rpc` | JSON-RPC client over `jobstart` |
| `jpr.session` | One review per tab: checkout, engine process, requests, redraws, and the one teardown path |
| `jpr.view_mode` | The global view mode (unified or split), remembered in `stdpath("state")/jpr/view-mode` |
| `jpr.render.panel` | Pure: `SessionView` to the panel's tree lines, highlights and paths |
| `jpr.render.overlay` | Pure: `FileDiffView` to extmark specs; a base text to lines |
| `jpr.render.stream` | Pure: `StreamView` to one or two aligned columns, targets, folds and navigation |
| `jpr.views.panel` | The panel window; `<CR>` opens a file, `v` toggles viewed |
| `jpr.views.main_window` | Finds the window beside the panel and opens files in it |
| `jpr.views.diff` | Draws changed files as diffs: extmarks (unified) or a `jpr://base/...` window in diff mode (split) |
| `jpr.views.stream` | The `jpr://stream/<n>` buffers and windows, and their keys |
```

and add to the paragraph after it: "Side windows (the panel, a base window, the stream's left half) are marked with the window variable `jpr_side`, so files and the stream always open in the main window."

- [ ] **Step 2: Add the decisions to `docs/decisions.md`**

Append:

```markdown
## Line and word diffs come from `similar`

**Decision.** `review-diff` uses `similar` 3 (slice API only, default features
off but `std`): Histogram for line diffs, as git uses for code, and Myers over
word tokens for the changed words inside a pair of lines.

**Why.** A diff algorithm with deadlines and grouping into hunks is a lot of
careful code to own; `similar` is small, has no required dependencies, and is
the common choice in Rust. dif computes no diffs itself (its web shell does),
so there was nothing to reuse.

**Consequences.** One file's line diff stops searching after 2 seconds and
settles for a good answer, so a pathological file cannot stall the engine.
Two paired lines get word highlights only when at least half their tokens
match; otherwise the whole line counts as replaced.

**Revisit when.** Diffs need to match GitHub's line for line, or `similar`
stops being maintained.

## The engine computes every diff except the split view's

**Decision.** The unified overlay and the stream are drawn from the engine's
`FileDiffView` and `StreamView`. The split view of a single file uses
Neovim's own `diff` mode on the engine's base text.

**Why.** The spec chose native diff mode for split view: it scrolls, folds and
edits like any Neovim diff, and the reviewer edits the real file in it. The
other views are read models a terminal UI would draw too, so they belong in
the engine.

**Consequences.** In split view the line pairing is Neovim's, which can
differ from the engine's in a few edge cases. Diffs compare against the file
on disk, so a save refreshes them; edits not yet saved are not shown.

## Viewed marks queue in `github.json` and win over a pull

**Decision.** A viewed mark GitHub refuses stands locally, is saved in
`github.json`, and is resent before every sync and every 20 seconds between
syncs. A pull never undoes a mark that is still queued.

**Why.** dif's rules, and the spec's: viewed state must survive a flaky
network without the reviewer redoing it, and GitHub stays the authority once
the mark lands.

**Consequences.** Resending stops at the first failure, so an offline queue
costs one timeout per try, not one per file.

## The view mode is a frontend preference

**Decision.** Unified or split is remembered by the plugin in
`stdpath("state")/jpr/view-mode`, not by the engine. The engine is told the
mode on each `stream` request.

**Why.** The choice is global across pull requests and is about how one
frontend draws, which is not review state.
```

- [ ] **Step 3: Update `README.md`**

Replace the first paragraph with:

```markdown
Review GitHub pull requests in Neovim. `:Jpr open <number>` checks the pull
request out into its own worktree and opens a tab with a file tree of its
changes and a stream of every diff, kept in sync with GitHub. Every changed
file opens as a diff, unified or split.
```

Replace the command table and the line under it with:

```markdown
| Command | What it does |
| --- | --- |
| `:Jpr open <n \| #n \| URL>` | Check the pull request out and open its review tab. A URL must be for the repository Neovim's directory is a checkout of |
| `:Jpr sync` | Sync with GitHub now (it also syncs every minute) |
| `:Jpr toggle` | Flip every diff between unified and split; the choice is remembered |
| `:Jpr stream` | Show the stream of every change beside the panel |
| `:Jpr close` | Stop the engine and close the tab |

In the panel, `<CR>` opens the file under the cursor and `v` toggles it viewed.
In the stream:

| Key | What it does |
| --- | --- |
| `<CR>` | Open the file at that line |
| `v` | Toggle viewed and move to the next unviewed file |
| `]f` / `[f` | Next / previous file |
| `]h` / `[h` | Next / previous hunk |

Viewed files are folded (`zo` opens one). `setup({ view = "split" })` picks
the view until you first toggle it.
```

- [ ] **Step 4: Bump the version**

In the root `Cargo.toml`, set `version = "0.2.0"` under `[workspace.package]`, then:

```bash
cargo build --workspace
```

Expected: builds, and `Cargo.lock` now lists every workspace crate at 0.2.0.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add docs README.md Cargo.toml Cargo.lock
git commit -m "docs: describe the review views; release 0.2.0"
```

---

### Task 24: Smoke test against GitHub

Needs network, a logged-in `gh`, and an open pull request the reviewer owns, preferably a throwaway one in a scratch repository. **Ask the user which repository and pull request to use.** Do not open, push to, or comment on any pull request yourself: the DISMISSED check needs a new commit on the pull request, which the user pushes, or which you push only if the user says so for that pull request.

- [ ] **Step 1: Install the branch build to a scratch directory**

```bash
scratch="$(mktemp -d)"
BIN_DIR="$scratch" ./install.sh
export PATH="$scratch:$PATH"
jpr-review --version
```

Expected: `jpr-review 0.2.0`.

- [ ] **Step 2: Drive the engine from the command line**

From a checkout of the chosen repository (`<repo-checkout>`, PR `<n>`, `<owner/name>`):

```bash
cd "$(jpr-review checkout --pr <n> | tail -n 1 | sed -n 's/.*"worktree":"\([^"]*\)".*/\1/p')"
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
  '{"jsonrpc":"2.0","id":2,"method":"sync"}' \
  '{"jsonrpc":"2.0","id":3,"method":"stream","params":{"mode":"unified"}}' \
  '{"jsonrpc":"2.0","id":4,"method":"shutdown"}' \
  | jpr-review serve --pr <n> --repo <owner/name> --poll 0
```

Expected: `protocolVersion: 2`; the `sync` result with `pr.baseSha` set and a `tree`; a `stream` result whose hunks match the pull request's Files tab on github.com.

- [ ] **Step 3: Drive it from Neovim**

```bash
cd <repo-checkout>
nvim --cmd "set rtp^=<this worktree>" -c "lua require('jpr').setup({})"
```

In Neovim, check each of these and note anything that misbehaves:

| Check | Expected |
| --- | --- |
| `:Jpr open <n>` | The tab shows the panel as a file tree and the stream beside it |
| Stream keys | `]f` `[f` `]h` `[h` move; viewed files are folded; `<CR>` opens the file at the line |
| Unified file | Added lines green, changed words stronger, removed lines as red virtual lines above |
| `:Jpr toggle` | The file shows beside a read-only base in diff mode; the stream splits into two aligned halves; the choice survives a Neovim restart |
| `v` in the stream | The file folds, the cursor moves to the next unviewed file, and github.com shows it viewed after a reload |
| `v` in the panel | The ✓ toggles; github.com agrees |
| Offline mark | With the network off, `v` still toggles and the panel says `1 waiting for GitHub`; with it back, the count clears within 20 seconds |
| DISMISSED | After a new commit on the pull request touches a viewed file (pushed by the user), `:Jpr sync` shows it with `●`, unfolded |
| Save | Editing and writing a changed file redraws its overlay and the stream |

- [ ] **Step 4: Record the result**

Write two or three lines in the final report: the repository and pull request, which checks passed, and anything that misbehaved. Clean up: remove the scratch directory, and remove the pull request's worktree if the user does not want to keep it.

---

## After this plan

- The final branch review runs before finishing the branch (per the execution rules).
- Merging `feat/review-views` and publishing it are the user's call.
- Milestone 3 (GitHub comments) gets its own plan, and takes up the thread markers this milestone deferred (stream markers, `]t` / `[t`, file-level threads under headers).
