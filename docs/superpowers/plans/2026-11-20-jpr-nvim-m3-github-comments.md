# jpr-nvim Milestone 3 (GitHub comments) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the reviewer read, write, reply to, edit, delete, resolve, react to, and submit GitHub pull-request comments (line, range, file-level, and PR conversation), including code suggestions, `@` mention completion, offline queueing, and concurrent-edit recovery.

**Architecture:** `review-model` and `review-diff` gain frontend-neutral read models for thread markers, stream thread rows, suggestion hunks, mention candidates, and the submit preview. `review-forge-github` extends its GraphQL queries and mutations (plus the REST replies endpoint for immediate replies on published threads), while `review-core` owns pending-vs-immediate dispatch, the persisted `github.json` v2 mutation queue, and dif's agreed-body conflict rule. Protocol version 3 exposes the comment and review-submission use cases to Lua, which renders signs, virtual-text previews, popups, the compose float, the conversation buffer, and the submit buffer. Spec: milestone 3 of `docs/superpowers/specs/2026-11-19-jpr-nvim-design.md`.

**Tech Stack:** Rust 2024 (`anyhow`, `clap`, `serde`, `serde_json`, `similar`; threads, no async runtime, no new Cargo dependencies), git, the GitHub CLI (`gh`), Neovim 0.11+ Lua (headless `nvim -l` specs).

---

## Scope

| In this milestone | Where in the spec |
| --- | --- |
| Pull full thread metadata (`viewerDidAuthor`, `fullDatabaseId`, reactions), file-level threads, PR conversation comments, and `@` mention candidates | "GitHub sync", "Requirements" |
| Pending-review drafts for line, range, and file comments (`:Jpr comment`); immediate replies on published threads and draft replies on own draft threads; immediate PR conversation comments | "When each action reaches GitHub" |
| Immediate edit, delete, resolve/unresolve, and reactions (`+`), with network failures queued in `github.json` v2 (retried every 20s) and forge rejections marked `failed` with retry/edit | "When each action reaches GitHub", "Error handling" |
| Concurrent edit recovery via dif's agreed-body rule (GitHub wins; local edit kept in `recoverableBody`) | "Error handling" |
| Thread markers (signs + dim end-of-line previews, file-level virtual lines, stream thread rows and markers), inline expand-all (`:Jpr expand`), and `]t` / `[t` in files and the stream | "Comments", "Stream" (deferred from M2) |
| Floating thread popup (`r`, `e`, `d`, `R`, `+`, `X` retry, `q`) | "Comments" |
| Compose Markdown float (`[GitHub draft]`), `<C-s>` save, prefilled ```` ```suggestion ```` block insertion, and `@` completion (`omnifunc` + optional `nvim-cmp` source) | "Comments" |
| `:Jpr suggest` turning a local hunk edit on a changed file into a GitHub draft suggestion and reverting the edit | "Comments: Edit -> suggestion" |
| Panel `Conversation` row, `drafts N` count, and `:Jpr conversation` buffer | "PR tab", "Commands" |
| `:Jpr submit` Markdown summary buffer listing pending drafts (`<CR>` jumps to anchor) and submitting as Comment, Approve, or Request changes (refused while any draft is `pending`, `queued`, or `failed`) | "Submit" |

| Deferred | To | Why |
| --- | --- | --- |
| Local threads (`local.json`), `[Local -> agent]` compose toggle, `<C-g>` / `<M-s>`, `p` promote, `s` send to agent | Milestone 4 | Local comments and the agent loop |
| `:Jpr agent`, `:Jpr send`, `:Jpr prepass`, `jpr-review reply`, `jpr-review guide`, `jpr-review prepass-write`, Unix socket, worktree file watcher | Milestone 4 | Agent loop milestone |
| `:Jpr push`, dirty/ahead/behind (`✏`, `dirty · ↑2 ↓0`), `require("jpr").statusline()` | Milestone 5 | Polish milestone |

## Ground rules for every task

- Work in a worktree on branch `feat/github-comments` (Task 0), created through `wt` (`using-wt` skill, never raw `git worktree`). Commit after every task. Do not push, merge, or open a PR (except the self-contained throwaway smoke test PR in Task 21, which is closed and deleted).
- Run commands from the worktree root unless a step says otherwise.
- `just check` must pass at the end of every task (`cargo fmt --all --check`, `cargo clippy --workspace --all-targets --all-features -- -D warnings`, Rust tests, and `./scripts/test-lua.sh`).
- **The dependency rule:** nothing in `crates/review-*` may depend on Neovim, Lua, a terminal UI library, or `jpr-review`. `crates/jpr-review/tests/dependency_rule.rs` enforces it. No new Cargo dependencies are added in this milestone.
- Keep every function within **45 lines** (`AGENTS.md`), in both Rust and Lua, and keep `.rs` production code well below 400 lines per file (`docs/rules/rust.md`).
- **Never use em dashes** in code comments, docstrings, or documentation (`AGENTS.md`): use a colon (`:`) or a short hyphen (` - `).
- Follow `AGENTS.md` naming rules: `create_*` for object/struct builders, `build_*` for string/primitive builders, `*_from_*` when building from seed data, `*_to_*` for conversions, auxiliary verbs on booleans (`is_*`, `has_*`, `viewer_did_*`), and descriptive nouns instead of `val`, `next`, `prev`, or `n`.
- Every public Rust item gets a `///` doc comment, and every exported Lua function gets a `---` docstring.
- **High-risk tasks** (`super-wrapper` rules): Task 4 (`github.json` v2 persistence format), Task 6 (`GhForge` GraphQL/REST mutations and untrusted inputs), and Task 8 (`ReviewSession` comment sync, offline queue replay, and agreed-body conflict resolution). Run a task-level review (`pro` tier) after the unit reviews pass on each high-risk task, and run a final branch review before finishing the branch.
- `docs/` is part of done: protocol or architecture shape changes update their docs, and Task 20 completes `docs/protocol.md`, `docs/architecture.md`, `docs/decisions.md`, `README.md`, and the `0.3.0` version bump.

## File map

| Path | Responsibility |
| --- | --- |
| `Cargo.toml` | Workspace version bumped to `0.3.0` (Task 20) |
| `crates/review-model/src/review.rs` | New: `ReactionContent`, `Reaction`, `ReviewEvent`, `MentionCandidate`, `SubmitDraft`, `SubmitPreview` |
| `crates/review-model/src/thread.rs` | `Side`/`AnchorKind` parsers, `Anchor` constructors (`side_line`, `range`, `file`, `pr`), richer `Message`, `MarkerKind`, `ThreadPreview`, `create_thread_preview_from_thread` |
| `crates/review-model/src/view.rs` | `SessionView.draft_count`, `SessionView.conversation_count`, `Event::ThreadsChanged` |
| `crates/review-model/src/diff.rs` | `FileDiffView.threads`, `StreamRow::Line.threads`, `StreamRow::Thread`, `SuggestedEdit` |
| `crates/review-diff/src/overlay.rs` | `create_file_diff_view_with_threads` computing `display_line` per thread |
| `crates/review-diff/src/stream.rs` | Places file-level and unplaced threads under file headers and line/range threads on hunk lines |
| `crates/review-diff/src/suggest.rs` | New: `create_suggestion_from_edit` (diff head text vs edited text around cursor, build suggestion + reverted text) |
| `crates/review-core/src/ports.rs` | `ForgeWriteError`, `CreatedReviewThread`, `ReplyRequest`, `QueuedCommentOp`, expanded `SyncRegistry`, `ForgeSnapshot`, and `Forge` comment/review methods |
| `crates/review-core/src/fakes.rs` | `FakeForge` comment/reply/edit/delete/resolve/reaction/submit state and transient-vs-rejected write failure modes |
| `crates/review-core/src/contract.rs` | `check_review_store` covers `github.json` v2 fields |
| `crates/review-core/src/comments.rs` | New, pure: ID remapping, agreed-body reconciliation, pending-vs-immediate rules, `create_submit_preview_from_threads` |
| `crates/review-core/src/presenter.rs` | `session_view` computes `draft_count`, `conversation_count`, file thread counts, and combined `queued_count` |
| `crates/review-core/src/session/comments.rs` | New: `threads`, `mentions`, `comment`, `reply`, `edit_message`, `delete_message`, `set_resolved`, `toggle_reaction`, `retry_message`, queue replay |
| `crates/review-core/src/session/submit.rs` | New: `anchored_lines`, `suggest_from_edit`, `submit_preview`, `submit_review` |
| `crates/review-core/src/session/mod.rs`, `sync.rs`, `diffs.rs`, `viewed.rs` | Loads/saves `registry.threads`, reconciles agreed bodies on pull, passes file threads into `file_diff` and `stream` |
| `crates/review-store-fs/src/format.rs`, `src/lib.rs` | `github.json` v2 (`OLDEST_GITHUB_VERSION = 1`) storing `threads`, `queued_ops`, `agreed_bodies`, `id_map`, `pending_review_id`, `viewer_login`, `mention_candidates` |
| `crates/review-forge-github/src/graphql.rs` | Extended `PENDING_REVIEW` (`viewer.login`), `THREADS` (`fullDatabaseId`, `viewerDidAuthor`, `reactionGroups`), `CONVERSATION`, `MENTIONS` |
| `crates/review-forge-github/src/mutations.rs` | New: GraphQL comment/review/reaction mutation documents, REST reply parser, and `classify_write_error` |
| `crates/review-forge-github/src/lib.rs` | Implements the `Forge` comment, reaction, and review-submission methods on `GhForge` |
| `crates/review-rpc/src/params.rs`, `src/protocol.rs`, `src/server.rs` | Protocol version 3 parameter parsers and request handlers |
| `plugin/jpr.lua`, `lua/jpr/init.lua`, `lua/jpr/rpc.lua`, `lua/jpr/session.lua` | Protocol 3, `:Jpr` range support, `<Plug>` mappings + `setup({ keys = ... })`, comment highlights, subcommands, `threadsChanged` handling |
| `lua/jpr/render/panel.lua`, `lua/jpr/views/panel.lua` | `Conversation (N)` node, `drafts N` count, `<CR>` opening conversation |
| `lua/jpr/render/threads.lua` | New, pure: sign definitions, EOL preview chunks, file-level and inline expanded virtual lines |
| `lua/jpr/views/threads.lua`, `lua/jpr/views/diff.lua` | Buffer signs/extmarks, expand-all toggle, `]t` / `[t`, cursor/visual anchor and thread lookup |
| `lua/jpr/render/stream.lua`, `lua/jpr/views/stream.lua` | `StreamRow::Thread` rendering, line thread previews/inline expansion, `]t` / `[t`, stream-line-to-anchor mapping |
| `lua/jpr/comments/popup.lua` | New: floating thread popup (`r`, `e`, `d`, `R`, `+`, `X`, `q`) |
| `lua/jpr/comments/mentions.lua`, `lua/jpr/comments/compose.lua` | New: `@` omnifunc + optional `nvim-cmp` source, Markdown compose float, suggestion block insertion |
| `lua/jpr/views/conversation.lua`, `lua/jpr/comments/suggest.lua` | New: `:Jpr conversation` buffer and `:Jpr suggest` local-edit-to-suggestion |
| `lua/jpr/render/submit.lua`, `lua/jpr/views/submit.lua` | New: `:Jpr submit` Markdown summary buffer and review submission prompt |
| `tests/lua/fixtures/fake_engine.sh`, `tests/lua/*_spec.lua` | Fake engine updated to protocol 3; new and updated Lua specs |
| `docs/protocol.md`, `docs/architecture.md`, `docs/decisions.md`, `README.md` | Updated documentation |

---

### Task 0: Worktree

- [ ] **Step 1: Create the worktree for `feat/github-comments`**

Load the `using-wt` skill first. From the main checkout:

```bash
cd "$(wt new feat github-comments)"
git branch --show-current
```

Expected: `feat/github-comments`.

- [ ] **Step 2: Restore the agent skills**

```bash
just skills-install
```

Expected: completes with exit code 0.

- [ ] **Step 3: Check the baseline**

```bash
just check
```

Expected: passes (rustfmt, clippy, Rust workspace tests, and Lua specs).

---

### Task 1: Review, reaction, and message models in `review-model`

**Files:**
- Create: `crates/review-model/src/review.rs`
- Modify: `crates/review-model/src/thread.rs`
- Modify: `crates/review-model/src/view.rs`
- Modify: `crates/review-model/src/lib.rs`

- [ ] **Step 1: Write the failing tests in `crates/review-model/src/review.rs`**

Create `crates/review-model/src/review.rs` with tests first:

```rust
//! Review-level types: reactions, review submission events, mention
//! candidates, and the submit preview read model.

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::Anchor;

    #[test]
    fn reaction_contents_parse_and_serialize_as_github_spells_them() {
        for content in ReactionContent::ALL {
            let text = content.as_str();
            assert_eq!(ReactionContent::parse(text), Some(content));
            assert_eq!(serde_json::to_value(content).unwrap(), json!(text));
            assert!(!content.emoji().is_empty());
        }
        assert_eq!(ReactionContent::parse("PARTY"), None);
    }

    #[test]
    fn review_events_parse_and_serialize_in_screaming_snake_case() {
        assert_eq!(ReviewEvent::parse("COMMENT"), Some(ReviewEvent::Comment));
        assert_eq!(ReviewEvent::parse("APPROVE"), Some(ReviewEvent::Approve));
        assert_eq!(
            ReviewEvent::parse("REQUEST_CHANGES"),
            Some(ReviewEvent::RequestChanges)
        );
        assert_eq!(ReviewEvent::parse("DISMISS"), None);
        assert_eq!(
            serde_json::to_value(ReviewEvent::RequestChanges).unwrap(),
            json!("REQUEST_CHANGES")
        );
    }

    #[test]
    fn submit_preview_and_mentions_use_camel_case_keys() {
        let preview = SubmitPreview {
            draft_count: 1,
            drafts: vec![SubmitDraft {
                thread_id: "T1".into(),
                message_id: "M1".into(),
                anchor: Anchor::line("src/a.rs", 4),
                snippet: "nit: rename".into(),
            }],
            can_approve_or_request_changes: true,
            blocked_reason: None,
        };
        let value = serde_json::to_value(&preview).unwrap();
        assert_eq!(value["draftCount"], 1);
        assert_eq!(value["drafts"][0]["threadId"], "T1");
        assert_eq!(value["drafts"][0]["messageId"], "M1");
        assert_eq!(value["drafts"][0]["snippet"], "nit: rename");
        assert_eq!(value["canApproveOrRequestChanges"], true);
        assert!(value["blockedReason"].is_null());

        let candidate = MentionCandidate {
            login: "pablo".into(),
            is_participant: true,
        };
        assert_eq!(
            serde_json::to_value(&candidate).unwrap(),
            json!({ "login": "pablo", "isParticipant": true })
        );
    }
}
```

- [ ] **Step 2: Run `cargo test -p review-model` to confirm failure**

Add `mod review;` to `crates/review-model/src/lib.rs`, then run:

```bash
cargo test -p review-model
```

Expected: FAIL to compile (`cannot find type ReactionContent`, `ReviewEvent`, `SubmitPreview`, `MentionCandidate`).

- [ ] **Step 3: Implement `crates/review-model/src/review.rs` and extend `thread.rs`, `view.rs`, and `lib.rs`**

Put the types above `#[cfg(test)]` in `crates/review-model/src/review.rs`:

```rust
use serde::{Deserialize, Serialize};

use crate::Anchor;

/// One of GitHub's eight comment reactions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ReactionContent {
    /// `+1` thumbs up.
    ThumbsUp,
    /// `-1` thumbs down.
    ThumbsDown,
    /// Laugh face.
    Laugh,
    /// Celebration hooray.
    Hooray,
    /// Confused face.
    Confused,
    /// Heart.
    Heart,
    /// Rocket.
    Rocket,
    /// Eyes.
    Eyes,
}

impl ReactionContent {
    /// Every reaction GitHub supports, in picker order.
    pub const ALL: [Self; 8] = [
        Self::ThumbsUp,
        Self::ThumbsDown,
        Self::Laugh,
        Self::Hooray,
        Self::Confused,
        Self::Heart,
        Self::Rocket,
        Self::Eyes,
    ];

    /// Parses GitHub's `ReactionContent` spelling.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "THUMBS_UP" => Some(Self::ThumbsUp),
            "THUMBS_DOWN" => Some(Self::ThumbsDown),
            "LAUGH" => Some(Self::Laugh),
            "HOORAY" => Some(Self::Hooray),
            "CONFUSED" => Some(Self::Confused),
            "HEART" => Some(Self::Heart),
            "ROCKET" => Some(Self::Rocket),
            "EYES" => Some(Self::Eyes),
            _ => None,
        }
    }

    /// GitHub's GraphQL enum spelling.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ThumbsUp => "THUMBS_UP",
            Self::ThumbsDown => "THUMBS_DOWN",
            Self::Laugh => "LAUGH",
            Self::Hooray => "HOORAY",
            Self::Confused => "CONFUSED",
            Self::Heart => "HEART",
            Self::Rocket => "ROCKET",
            Self::Eyes => "EYES",
        }
    }

    /// Short display glyph for popups and virtual text.
    #[must_use]
    pub const fn emoji(self) -> &'static str {
        match self {
            Self::ThumbsUp => "👍",
            Self::ThumbsDown => "👎",
            Self::Laugh => "😄",
            Self::Hooray => "🎉",
            Self::Confused => "😕",
            Self::Heart => "❤️",
            Self::Rocket => "🚀",
            Self::Eyes => "👀",
        }
    }
}

/// Aggregated count for one reaction kind on a message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reaction {
    /// Which reaction this count represents.
    pub content: ReactionContent,
    /// How many accounts reacted with it.
    pub count: u32,
    /// Whether the current reviewer reacted with it.
    pub viewer_has_reacted: bool,
}

/// The verdict chosen when submitting a pull-request review.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ReviewEvent {
    /// Post general feedback without explicit approval.
    Comment,
    /// Approve merging the pull request.
    Approve,
    /// Request changes before merging.
    RequestChanges,
}

impl ReviewEvent {
    /// Parses `COMMENT`, `APPROVE`, or `REQUEST_CHANGES`.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "COMMENT" => Some(Self::Comment),
            "APPROVE" => Some(Self::Approve),
            "REQUEST_CHANGES" => Some(Self::RequestChanges),
            _ => None,
        }
    }

    /// GitHub's GraphQL `PullRequestReviewEvent` spelling.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Comment => "COMMENT",
            Self::Approve => "APPROVE",
            Self::RequestChanges => "REQUEST_CHANGES",
        }
    }
}

/// An account `@` completion offers while composing a comment.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MentionCandidate {
    /// Handle without a leading `@`, such as `alice` or `renovate[bot]`.
    pub login: String,
    /// Whether the account has already participated in this pull request.
    pub is_participant: bool,
}

/// One draft message shown in the `:Jpr submit` summary buffer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubmitDraft {
    /// The thread holding the draft.
    pub thread_id: String,
    /// The draft message's id.
    pub message_id: String,
    /// Where the draft is attached, so `<CR>` can jump to it.
    pub anchor: Anchor,
    /// One-line snippet of the draft body.
    pub snippet: String,
}

/// What a frontend needs to render `:Jpr submit` and guard submission.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubmitPreview {
    /// Number of pending draft comments in the review.
    pub draft_count: usize,
    /// Every pending draft message, in display order.
    pub drafts: Vec<SubmitDraft>,
    /// False when the authenticated viewer authored the pull request.
    pub can_approve_or_request_changes: bool,
    /// Reason submission must wait (when any comment is still `pending`,
    /// `queued`, or `failed`), or `None` when ready to submit.
    pub blocked_reason: Option<String>,
}
```

Now update `crates/review-model/src/thread.rs` to add `Side`/`AnchorKind` helpers, `Anchor` constructors (`side_line`, `range`, `file`, `pr`), and the new `Message` fields (with `#[serde(default)]` / `skip_serializing_if` so wire format stays minimal):

```rust
use serde::{Deserialize, Serialize};

use crate::Reaction;

/// Where a thread lives, so a frontend can tell a forge thread from one kept
/// only on this machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    /// On the forge (GitHub).
    Github,
    /// Only on this machine, for the agent.
    Local,
}

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
    /// Parses `LEFT` or `RIGHT`.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "LEFT" => Some(Self::Left),
            "RIGHT" => Some(Self::Right),
            _ => None,
        }
    }

    /// GitHub's `DiffSide` spelling.
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
    /// Parses `line`, `range`, `file`, or `pr`.
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
    #[must_use]
    pub fn line(file: &str, line: u64) -> Self {
        Self::side_line(file, Side::Right, line)
    }

    /// A single line on `side` of `file`.
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

    /// Lines `start..=end` on `side` of `file` (collapsed to `Line` when equal).
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

    /// A file-level anchor on `file`.
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

    /// A pull-request conversation anchor.
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

/// Whether a thread still needs attention, so a frontend can fold settled
/// threads away.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThreadState {
    /// Still needs an answer or a fix.
    Open,
    /// Settled.
    Resolved,
}

/// Where a forge message stands, so a frontend can show which messages others
/// can see. Local messages have none.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageSync {
    /// In the reviewer's pending review, visible only to them.
    Draft,
    /// Being written to the forge.
    Pending,
    /// On the forge, visible to everyone who can see the pull request.
    Published,
    /// Writing it to the forge failed.
    Failed,
    /// Waiting for the network.
    Queued,
}

/// One message in a thread, as a frontend draws it in the conversation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    /// Identifies the message on the forge, or on this machine for a local one.
    pub id: String,
    /// The author's login; a bot's ends in `[bot]`.
    pub author: String,
    /// The message text, as the author wrote it.
    pub body: String,
    /// When the message was written, as the forge's timestamp.
    pub created: String,
    /// When the message was last edited, in the same format as `created`.
    pub updated: String,
    /// Where a forge message stands; `None`, and left out of the JSON, for a
    /// local message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sync: Option<MessageSync>,
    /// Whether the current reviewer authored this message.
    #[serde(default)]
    pub viewer_did_author: bool,
    /// Numeric GitHub comment id as a decimal string, for the REST replies API.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub database_id: Option<String>,
    /// Reactions with at least one reactor.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reactions: Vec<Reaction>,
    /// Forge error message when `sync` is `Failed`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sync_error: Option<String>,
    /// Local edit text preserved when a concurrent forge edit won.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recoverable_body: Option<String>,
}

impl Message {
    /// Creates a message with `sync` and default metadata, for tests and local
    /// optimistic placeholders.
    #[must_use]
    pub fn create_with_sync(
        id: &str,
        author: &str,
        body: &str,
        timestamp: &str,
        sync: Option<MessageSync>,
    ) -> Self {
        Self {
            id: id.to_owned(),
            author: author.to_owned(),
            body: body.to_owned(),
            created: timestamp.to_owned(),
            updated: timestamp.to_owned(),
            sync,
            viewer_did_author: false,
            database_id: None,
            reactions: Vec::new(),
            sync_error: None,
            recoverable_body: None,
        }
    }
}

/// A review conversation attached to an [`Anchor`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Thread {
    /// Identifies the thread on the forge, or on this machine for a local one.
    pub id: String,
    /// Whether the thread lives on the forge or only on this machine.
    pub origin: Origin,
    /// Where the thread is attached.
    pub anchor: Anchor,
    /// Whether the thread still needs attention.
    pub state: ThreadState,
    /// The forge says the anchored code changed since the thread was opened.
    #[serde(default)]
    pub outdated: bool,
    /// The messages, in the order the forge reports them.
    pub messages: Vec<Message>,
}
```

Update the `Message` literal in `crates/review-model/src/thread.rs`'s `#[cfg(test)]` block to use `Message::create_with_sync("C1", "bob", "why?", "2026-11-19T00:00:00Z", Some(MessageSync::Draft))`, and add a test checking `Anchor::range`, `Anchor::file`, `Anchor::pr`, `Side::parse`, and `AnchorKind::parse`:

```rust
    #[test]
    fn anchors_and_sides_parse_and_collapse_single_line_ranges() {
        assert_eq!(Side::parse("LEFT"), Some(Side::Left));
        assert_eq!(AnchorKind::parse("file"), Some(AnchorKind::File));
        let single = Anchor::range("a.rs", Side::Left, 5, 5);
        assert_eq!(single.kind, AnchorKind::Line);
        let span = Anchor::range("a.rs", Side::Right, 9, 4);
        assert_eq!((span.kind, span.start, span.end), (AnchorKind::Range, Some(4), Some(9)));
        assert_eq!(Anchor::file("a.rs").kind, AnchorKind::File);
        assert_eq!(Anchor::pr().kind, AnchorKind::Pr);
    }
```

In `crates/review-model/src/view.rs`:
- Add `#[serde(default)] pub draft_count: usize,` and `#[serde(default)] pub conversation_count: usize,` to `SessionView` (after `thread_count`),
- Add `ThreadsChanged { view: Box<SessionView> }` to `Event`,
- Update `events_are_tagged_by_type_and_views_use_camel_case` in `view.rs` to set `draft_count: 1, conversation_count: 2` and assert `json["view"]["draftCount"] == 1`, `json["view"]["conversationCount"] == 2`, and `serde_json::to_value(Event::ThreadsChanged { view: Box::new(view) }).unwrap()["type"] == "threadsChanged"`.

Update `crates/review-model/src/lib.rs` exports:

```rust
mod diff;
mod pr;
mod review;
mod thread;
mod view;

pub use diff::{
    AddedLine, FileDiffView, LineCell, LineChange, RemovedBlock, RemovedLine, StreamRow,
    StreamView, ViewMode, WordRange,
};
pub use pr::{ChangedFile, PullRequest, ViewedState};
pub use review::{
    MentionCandidate, Reaction, ReactionContent, ReviewEvent, SubmitDraft, SubmitPreview,
};
pub use thread::{Anchor, AnchorKind, Message, MessageSync, Origin, Side, Thread, ThreadState};
pub use view::{Event, FileRow, SessionView, SyncState, TreeRow};
```

Update the two `Message` struct literals in `crates/review-core/src/fakes.rs` (`github_thread`) and `crates/review-forge-github/src/graphql.rs` (`parse_comment`) and `crates/review-core/src/presenter.rs` (`SessionView` construction sets `draft_count: 0, conversation_count: 0` for now; Task 7 computes the real counts).

- [ ] **Step 4: Run workspace tests**

```bash
cargo test --workspace --all-features
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates
git commit -m "feat(model): add reactions, review events, submit preview, and message metadata"
```

---

### Task 2: Thread previews and diff/stream thread markers

**Files:**
- Modify: `crates/review-model/src/thread.rs`
- Modify: `crates/review-model/src/diff.rs`
- Modify: `crates/review-model/src/lib.rs`
- Modify: `crates/review-diff/src/overlay.rs`
- Modify: `crates/review-diff/src/stream.rs`
- Modify: `crates/review-diff/src/stream/tests.rs`
- Modify: `crates/review-diff/src/lib.rs`
- Modify: `crates/review-core/src/session/diffs.rs`

`ThreadPreview` is the frontend-neutral marker shape: its `MarkerKind` (`published`, `draft`, `failed`, `local`), its 1-based `display_line` in a current-file buffer (`0` for file-level threads), a one-line `snippet`, and the thread's `messages` so inline expand-all and the popup never need a second fetch.

- [ ] **Step 1: Write failing tests for `ThreadPreview`, `FileDiffView.threads`, and `StreamRow::Thread`**

Add to `crates/review-model/src/thread.rs` tests:

```rust
    #[test]
    fn thread_preview_picks_failed_then_draft_then_published_and_trims_snippet() {
        let mut thread = Thread {
            id: "T1".into(),
            origin: Origin::Github,
            anchor: Anchor::line("src/a.rs", 7),
            state: ThreadState::Open,
            outdated: false,
            messages: vec![Message::create_with_sync(
                "M1",
                "alice",
                "  first line\nsecond line  ",
                "2026-11-20T00:00:00Z",
                Some(MessageSync::Draft),
            )],
        };
        let draft = create_thread_preview_from_thread(&thread, 7);
        assert_eq!(draft.kind, MarkerKind::Draft);
        assert_eq!(draft.snippet, "first line");
        assert_eq!(draft.display_line, 7);

        thread.messages[0].sync = Some(MessageSync::Failed);
        assert_eq!(
            create_thread_preview_from_thread(&thread, 7).kind,
            MarkerKind::Failed
        );
    }
```

Add to `crates/review-diff/src/overlay.rs` `mod tests`:

```rust
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
```

Update `create_stream_input` and `rows_to_sketch` in `crates/review-diff/src/stream/tests.rs` to initialize `threads: Vec::new()`, render `StreamRow::Thread { thread, target, .. } => format!("thread {} ->{target}", thread.thread_id)`, and append any `threads` on `StreamRow::Line` as ` [t1,t2]`, then add:

```rust
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
```

- [ ] **Step 2: Run `cargo test -p review-model -p review-diff` to see them fail**

```bash
cargo test -p review-model -p review-diff
```

Expected: FAIL to compile (`cannot find type MarkerKind`, `ThreadPreview`, `create_file_diff_view_with_threads`).

- [ ] **Step 3: Implement `MarkerKind`, `ThreadPreview`, and the overlay/stream placement**

In `crates/review-model/src/thread.rs`, add above `#[cfg(test)]`:

```rust
/// How a frontend colors a thread's sign and preview badge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MarkerKind {
    /// Published on the forge.
    Published,
    /// Draft in the pending review, or queued/pending delivery.
    Draft,
    /// Refused by the forge and waiting for retry or edit.
    Failed,
    /// Local thread for the agent.
    Local,
}

/// Compact read model for a thread marker, preview, and inline block.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadPreview {
    /// Identifies the thread.
    pub thread_id: String,
    /// Where the thread is attached.
    pub anchor: Anchor,
    /// 1-based line in the current file where a unified overlay places the
    /// marker, or `0` for a file-level thread.
    pub display_line: u64,
    /// Visual badge category.
    pub kind: MarkerKind,
    /// Open or resolved.
    pub state: ThreadState,
    /// Marked outdated by the forge.
    pub outdated: bool,
    /// Total messages in the thread.
    pub message_count: usize,
    /// First message's author login.
    pub first_author: String,
    /// Trimmed first non-empty line of the first message.
    pub snippet: String,
    /// Full messages for inline expansion and the popup.
    pub messages: Vec<Message>,
}

/// Builds a [`ThreadPreview`] placed at `display_line`.
#[must_use]
pub fn create_thread_preview_from_thread(thread: &Thread, display_line: u64) -> ThreadPreview {
    let kind = thread_to_marker_kind(thread);
    let first_author = thread
        .messages
        .first()
        .map_or_else(String::new, |message| message.author.clone());
    let snippet = thread
        .messages
        .first()
        .map_or_else(String::new, |message| build_snippet_from_body(&message.body));
    ThreadPreview {
        thread_id: thread.id.clone(),
        anchor: thread.anchor.clone(),
        display_line,
        kind,
        state: thread.state,
        outdated: thread.outdated,
        message_count: thread.messages.len(),
        first_author,
        snippet,
        messages: thread.messages.clone(),
    }
}

fn thread_to_marker_kind(thread: &Thread) -> MarkerKind {
    if thread.origin == Origin::Local {
        return MarkerKind::Local;
    }
    if thread
        .messages
        .iter()
        .any(|message| message.sync == Some(MessageSync::Failed))
    {
        return MarkerKind::Failed;
    }
    if thread.messages.iter().any(|message| {
        matches!(
            message.sync,
            Some(MessageSync::Draft | MessageSync::Pending | MessageSync::Queued)
        )
    }) {
        return MarkerKind::Draft;
    }
    MarkerKind::Published
}

fn build_snippet_from_body(body: &str) -> String {
    body.lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default()
        .chars()
        .take(80)
        .collect()
}
```

Re-export `MarkerKind`, `ThreadPreview`, and `create_thread_preview_from_thread` from `crates/review-model/src/lib.rs`.

In `crates/review-model/src/diff.rs`:
- Add `#[serde(default)] pub threads: Vec<crate::ThreadPreview>,` to `FileDiffView` and `StreamRow::Line` (updating existing struct literals in `diff.rs` tests with `threads: Vec::new()`).
- Add `Thread { path: String, thread: crate::ThreadPreview, target: u64 }` to `StreamRow`, and add `Self::Thread { path, .. } => path,` to `StreamRow::path`.

Update `crates/review-diff/src/overlay.rs` and re-export `create_file_diff_view_with_threads` from `crates/review-diff/src/lib.rs`:

```rust
use review_model::{
    AddedLine, AnchorKind, FileDiffView, RemovedBlock, RemovedLine, Side, Thread, ThreadPreview,
    create_thread_preview_from_thread,
};

#[must_use]
pub fn create_file_diff_view_from_texts(
    path: &str,
    base: &FileText,
    current: &FileText,
) -> FileDiffView {
    create_file_diff_view_with_threads(path, base, current, &[])
}

/// Like [`create_file_diff_view_from_texts`], placing every thread on `path`
/// at its current-file `display_line` (`0` for file-level threads).
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
```

Update `crates/review-diff/src/stream.rs` to accept `pub threads: Vec<Thread>` on `StreamInput`, attach line threads inside `HunkWriter::create_line_row`, and emit `StreamRow::Thread` rows right after `StreamRow::File` for file-level and unplaced threads:

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamInput {
    /// The file as the forge reports it.
    pub file: ChangedFile,
    /// The base and the current text, or why they could not be read.
    pub content: Result<(FileText, FileText), String>,
    /// Review threads anchored on this file.
    pub threads: Vec<Thread>,
}
```

And add the placement helpers in `crates/review-diff/src/stream.rs`:

```rust
fn attach_threads_to_file_rows(
    path: &str,
    rows: &mut Vec<StreamRow>,
    threads: &[Thread],
) {
    let mut placed_ids: std::collections::HashSet<String> = std::collections::HashSet::new();
    for row in rows.iter_mut() {
        if let StreamRow::Line {
            left,
            right,
            target,
            threads: line_threads,
            ..
        } = row
        {
            for thread in threads {
                if placed_ids.contains(&thread.id) || !line_row_matches_thread(thread, left.as_ref(), right.as_ref()) {
                    continue;
                }
                placed_ids.insert(thread.id.clone());
                line_threads.push(create_thread_preview_from_thread(thread, *target));
            }
        }
    }
    let header_threads: Vec<StreamRow> = threads
        .iter()
        .filter(|thread| !placed_ids.contains(&thread.id) && thread.anchor.kind != AnchorKind::Pr)
        .map(|thread| {
            let target = thread.anchor.end.unwrap_or(1);
            StreamRow::Thread {
                path: path.to_owned(),
                thread: create_thread_preview_from_thread(thread, target),
                target,
            }
        })
        .collect();
    if !header_threads.is_empty() {
        rows.splice(1..1, header_threads);
    }
}

fn line_row_matches_thread(
    thread: &Thread,
    left: Option<&LineCell>,
    right: Option<&LineCell>,
) -> bool {
    if !matches!(thread.anchor.kind, AnchorKind::Line | AnchorKind::Range) {
        return false;
    }
    let Some(anchor_line) = thread.anchor.end else {
        return false;
    };
    match thread.anchor.side {
        Side::Left => left.is_some_and(|cell| cell.line == anchor_line),
        Side::Right => right.is_some_and(|cell| cell.line == anchor_line),
    }
}
```

Call `attach_threads_to_file_rows(&file.path, &mut rows, &input.threads);` at the end of `create_file_rows_from_input` in `crates/review-diff/src/stream.rs` (initializing `threads: Vec::new()` inside `HunkWriter::create_line_row`).

In `crates/review-core/src/session/diffs.rs`, update `file_diff` and `stream` to pass `&self.threads`:

```rust
    pub fn file_diff(&mut self, path: &str) -> Result<FileDiffView> {
        let (base, current) = self.file_texts(path)?;
        Ok(create_file_diff_view_with_threads(
            path,
            &base,
            &current,
            &self.threads,
        ))
    }

    pub fn stream(&mut self, mode: ViewMode) -> Result<StreamView> {
        self.prepare_base()?;
        let files = self.saved.files.clone();
        let mut inputs = Vec::with_capacity(files.len());
        for file in files {
            let content = self
                .file_texts(&file.path)
                .map_err(|error| format!("{error:#}"));
            let threads = self
                .threads
                .iter()
                .filter(|thread| thread.anchor.file.as_deref() == Some(file.path.as_str()))
                .cloned()
                .collect();
            inputs.push(StreamInput {
                file,
                content,
                threads,
            });
        }
        Ok(create_stream_view_from_inputs(&inputs, mode))
    }
```

- [ ] **Step 4: Run tests**

```bash
cargo test --workspace --all-features
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates
git commit -m "feat(diff): place thread previews on file overlays and stream rows"
```

---

### Task 3: Edit-to-suggestion diff builder in `review-diff`

**Files:**
- Create: `crates/review-diff/src/suggest.rs`
- Modify: `crates/review-model/src/diff.rs`
- Modify: `crates/review-model/src/lib.rs`
- Modify: `crates/review-diff/src/lib.rs`

`:Jpr suggest` turns the reviewer's local uncommitted edit around the cursor into a GitHub ```` ```suggestion ```` block anchored to the PR head's lines, and produces the reverted file text with only that hunk undone.

- [ ] **Step 1: Write the failing tests in `crates/review-diff/src/suggest.rs`**

Add `SuggestedEdit` to `crates/review-model/src/diff.rs` (re-exported in `lib.rs`):

```rust
/// A local edit turned into a GitHub suggestion block, plus the text that
/// restores just that hunk.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SuggestedEdit {
    /// The head-side line or range the suggestion replaces.
    pub anchor: crate::Anchor,
    /// Markdown fenced `suggestion` block holding the edited lines.
    pub suggestion_body: String,
    /// Full file text with this edited hunk reverted back to `head_text`.
    pub reverted_text: String,
}
```

Create `crates/review-diff/src/suggest.rs` with tests first:

```rust
//! Turning one locally edited hunk into a GitHub `suggestion` block and the
//! text that reverts that hunk.

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
    fn an_unedited_cursor_line_returns_none() {
        let head = "one\ntwo\nthree\n";
        let edited = "one\ntwo\nTHREE\n";
        assert!(create_suggestion_from_edit("a.txt", head, edited, 1).is_none());
    }
}
```

- [ ] **Step 2: Run `cargo test -p review-diff` to confirm failure**

Add `mod suggest;` and `pub use suggest::create_suggestion_from_edit;` to `crates/review-diff/src/lib.rs`, then run:

```bash
cargo test -p review-diff
```

Expected: FAIL to compile (`cannot find function create_suggestion_from_edit`).

- [ ] **Step 3: Implement `crates/review-diff/src/suggest.rs`**

Put this above `#[cfg(test)]` in `crates/review-diff/src/suggest.rs`:

```rust
use std::ops::Range;

use review_model::{Anchor, Side, SuggestedEdit};

use crate::lines::{Block, create_diff_operations_from_lines, diff_operations_to_blocks, line_index_to_number};

/// Turns the edited hunk at 1-based `cursor_line` of `edited_text` (compared
/// against `head_text`) into a GitHub suggestion block and the reverted text.
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
    let cursor_index = usize::try_from(cursor_line.saturating_sub(1)).ok()?;
    let blocks = diff_operations_to_blocks(&create_diff_operations_from_lines(&head_lines, &edited_lines));
    let (raw_old, raw_new) = find_change_at_cursor(&blocks, cursor_index)?;
    let (old_span, new_span) = anchorable_spans(raw_old.clone(), raw_new.clone(), head_lines.len(), edited_lines.len());
    let anchor = Anchor::range(
        path,
        Side::Right,
        line_index_to_number(old_span.start),
        line_index_to_number(old_span.end - 1),
    );
    let suggestion_body = build_suggestion_fence(&edited_lines[new_span]);
    let reverted_text = build_reverted_text(&head_lines, &edited_lines, raw_old, raw_new, head_text.ends_with('\n'));
    Some(SuggestedEdit {
        anchor,
        suggestion_body,
        reverted_text,
    })
}

fn find_change_at_cursor(blocks: &[Block], cursor_index: usize) -> Option<(Range<usize>, Range<usize>)> {
    blocks.iter().find_map(|block| match block {
        Block::Change { old, new } if span_touches_cursor(new, cursor_index) => {
            Some((old.clone(), new.clone()))
        }
        _ => None,
    })
}

const fn span_touches_cursor(new_span: &Range<usize>, cursor_index: usize) -> bool {
    if new_span.is_empty() {
        cursor_index == new_span.start || cursor_index.saturating_add(1) == new_span.start
    } else {
        cursor_index >= new_span.start && cursor_index < new_span.end
    }
}

/// Ensures `old_span` covers at least one line of `head_lines`, since GitHub
/// cannot attach a suggestion to zero lines.
const fn anchorable_spans(
    old_span: Range<usize>,
    new_span: Range<usize>,
    head_len: usize,
    edited_len: usize,
) -> (Range<usize>, Range<usize>) {
    if !old_span.is_empty() {
        return (old_span, new_span);
    }
    if old_span.start < head_len && new_span.end < edited_len {
        (old_span.start..old_span.start + 1, new_span.start..new_span.end + 1)
    } else {
        (old_span.start - 1..old_span.start, new_span.start - 1..new_span.end)
    }
}

fn build_suggestion_fence(lines: &[&str]) -> String {
    let mut fence = String::from("```suggestion\n");
    for line in lines {
        fence.push_str(line);
        fence.push('\n');
    }
    fence.push_str("```");
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
```

- [ ] **Step 4: Run `cargo test -p review-diff`**

```bash
cargo test -p review-diff
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-model crates/review-diff
git commit -m "feat(diff): build a GitHub suggestion and reverted text from a local edit"
```

---

### Task 4: Comment ports, `SyncRegistry`, and `github.json` v2 persistence `[HIGH-RISK]`

**Files:**
- Modify: `crates/review-core/src/ports.rs`
- Modify: `crates/review-core/src/contract.rs`
- Modify: `crates/review-store-fs/src/format.rs`
- Modify: `crates/review-store-fs/src/format/tests.rs`
- Modify: `crates/review-store-fs/src/lib.rs`

`SyncRegistry` and `github.json` v2 atomically persist everything the session needs across restarts: `queued_viewed`, `pending_review_id`, `viewer_login`, `next_temp_id`, `id_map`, `agreed_bodies`, `threads`, `queued_ops`, and `mention_candidates`. `OLDEST_GITHUB_VERSION = 1` keeps existing M1/M2 `github.json` v1 files readable with defaults.

- [ ] **Step 1: Write the failing store format and contract tests**

Add to `crates/review-store-fs/src/format/tests.rs`:

```rust
#[test]
fn github_v1_reads_with_default_comment_fields_and_round_trips_as_v2() {
    use review_core::ports::QueuedCommentOp;
    use review_model::{
        Anchor, MentionCandidate, Message, MessageSync, Origin, Reaction, ReactionContent,
        ReviewEvent, Thread, ThreadState,
    };

    let v1 = br#"{"version": 1, "queuedViewed": {"src/a.rs": true}}"#;
    let decoded = decode_registry(v1).expect("v1 github.json still decodes");
    assert_eq!(decoded.queued_viewed.get("src/a.rs"), Some(&true));
    assert!(decoded.threads.is_empty());
    assert!(decoded.queued_ops.is_empty());

    let mut message = Message::create_with_sync(
        "tmp-m-1",
        "alice",
        "nit",
        "2026-11-20T00:00:00Z",
        Some(MessageSync::Queued),
    );
    message.viewer_did_author = true;
    message.reactions.push(Reaction {
        content: ReactionContent::ThumbsUp,
        count: 1,
        viewer_has_reacted: true,
    });
    let mut registry = decoded;
    registry.pending_review_id = Some("PRR_1".into());
    registry.viewer_login = Some("alice".into());
    registry.next_temp_id = 2;
    registry
        .id_map
        .insert("tmp-t-1".into(), "PRRT_real".into());
    registry
        .agreed_bodies
        .insert("IC_1".into(), "original".into());
    registry.threads.push(Thread {
        id: "tmp-t-1".into(),
        origin: Origin::Github,
        anchor: Anchor::line("src/a.rs", 3),
        state: ThreadState::Open,
        outdated: false,
        messages: vec![message],
    });
    registry.queued_ops = vec![
        QueuedCommentOp::CreateReviewThread {
            temp_thread_id: "tmp-t-1".into(),
            temp_message_id: "tmp-m-1".into(),
            anchor: Anchor::line("src/a.rs", 3),
            body: "nit".into(),
        },
        QueuedCommentOp::SubmitReview {
            event: ReviewEvent::Comment,
            body: "looks close".into(),
        },
    ];
    registry.mention_candidates.push(MentionCandidate {
        login: "bob".into(),
        is_participant: true,
    });

    let encoded = encode_registry(&registry).expect("v2 encodes");
    assert_eq!(stored_version(&encoded).unwrap(), 2);
    assert_eq!(decode_registry(&encoded).unwrap(), registry);
}
```

Also enrich `first.registry` in `crates/review-core/src/contract.rs` (`check_review_store`) with a non-empty `pending_review_id`, `threads`, `queued_ops`, and `mention_candidates` so every `ReviewStore` implementation proves full round-trip fidelity.

- [ ] **Step 2: Run `cargo test -p review-store-fs` to verify failure**

```bash
cargo test -p review-store-fs
```

Expected: FAIL to compile (`cannot find type QueuedCommentOp in module ports`, missing fields on `SyncRegistry`).

- [ ] **Step 3: Extend `ports.rs` and `review-store-fs/src/format.rs`**

In `crates/review-core/src/ports.rs`, add the comment write types and expand `ForgeSnapshot` and `SyncRegistry`:

```rust
use review_model::{
    Anchor, AnchorKind, ChangedFile, MentionCandidate, Message, PullRequest, Reaction,
    ReactionContent, ReviewEvent, Thread,
};

/// How a forge write failed: transient errors can be queued and retried,
/// while rejected requests need the reviewer to edit, retry, or delete.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ForgeWriteError {
    /// Network timeout, offline `gh`, HTTP 5xx, or rate limit.
    Transient(String),
    /// Validation error (HTTP 4xx / GraphQL refusal) that retrying unchanged
    /// will not fix.
    Rejected(String),
}

impl std::fmt::Display for ForgeWriteError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Transient(message) | Self::Rejected(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for ForgeWriteError {}

/// Result of creating a new draft review thread on the forge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreatedReviewThread {
    /// Node id of the pending review that owns the draft thread.
    pub pending_review_id: String,
    /// Created review thread with its single draft message.
    pub thread: Thread,
}

/// Parameters for replying to an existing code review thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplyRequest<'a> {
    /// Target review thread node id (`PRRT_...`).
    pub thread_id: &'a str,
    /// Decimal `fullDatabaseId` of the thread's first comment, for REST replies.
    pub root_database_id: Option<&'a str>,
    /// Existing pending review node id (`PRR_...`), when one is active.
    pub pending_review_id: Option<&'a str>,
    /// Markdown reply body.
    pub body: &'a str,
}

/// An offline or transiently failed comment write held in `github.json` until
/// the forge accepts it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum QueuedCommentOp {
    /// Draft review thread anchored to a file, line, or range.
    CreateReviewThread {
        temp_thread_id: String,
        temp_message_id: String,
        anchor: Anchor,
        body: String,
    },
    /// Top-level pull-request conversation comment.
    CreateConversationComment {
        temp_thread_id: String,
        temp_message_id: String,
        body: String,
    },
    /// Reply to a code review thread.
    ReplyToThread {
        thread_id: String,
        root_database_id: Option<String>,
        temp_message_id: String,
        body: String,
    },
    /// Edit a review comment or issue comment.
    EditMessage {
        thread_id: String,
        anchor_kind: AnchorKind,
        message_id: String,
        body: String,
    },
    /// Delete a review comment or issue comment.
    DeleteMessage {
        thread_id: String,
        anchor_kind: AnchorKind,
        message_id: String,
    },
    /// Resolve or unresolve a code review thread.
    SetResolved {
        thread_id: String,
        resolved: bool,
    },
    /// Add or remove a reaction on a comment node.
    SetReaction {
        subject_id: String,
        content: ReactionContent,
        added: bool,
    },
    /// Submit the pending review (or a zero-draft review).
    SubmitReview {
        event: ReviewEvent,
        body: String,
    },
}
```

Update `ForgeSnapshot` and `SyncRegistry` in `crates/review-core/src/ports.rs`:

```rust
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ForgeSnapshot {
    /// The pull request's head commit at the time of the pull.
    pub head_sha: String,
    /// Whether the reviewer has a pending (unsubmitted) review.
    pub has_pending_review: bool,
    /// Node id of the reviewer's pending review, when `has_pending_review` holds.
    pub pending_review_id: Option<String>,
    /// Login of the authenticated `gh` viewer, when reported.
    pub viewer_login: Option<String>,
    /// Every review thread and conversation comment thread on the pull request.
    pub threads: Vec<Thread>,
    /// The changed files, with the reviewer's viewed state.
    pub files: Vec<ChangedFile>,
    /// `@mention` completion candidates, PR participants first.
    pub mention_candidates: Vec<MentionCandidate>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SyncRegistry {
    /// Viewed marks the forge has not accepted yet, by path.
    pub queued_viewed: BTreeMap<String, bool>,
    /// Node id of the reviewer's active pending review on GitHub, if any.
    pub pending_review_id: Option<String>,
    /// Login of the authenticated reviewer.
    pub viewer_login: Option<String>,
    /// Counter for temporary optimistic thread and message ids (`tmp-1`, ...).
    pub next_temp_id: u64,
    /// Temporary id to real GitHub node id mappings learned during replay.
    pub id_map: BTreeMap<String, String>,
    /// Last forge-confirmed body per message id, for concurrent-edit detection.
    pub agreed_bodies: BTreeMap<String, String>,
    /// Persisted threads (published, draft, queued, and failed) so restarts keep
    /// optimistic state before the next sync.
    pub threads: Vec<Thread>,
    /// Comment operations waiting to be sent to GitHub.
    pub queued_ops: Vec<QueuedCommentOp>,
    /// Cached `@mention` candidates from the last sync.
    pub mention_candidates: Vec<MentionCandidate>,
}
```

In `crates/review-store-fs/src/format.rs` (and re-export `OLDEST_GITHUB_VERSION` from `crates/review-store-fs/src/lib.rs`):

```rust
/// The `github.json` shape this build writes. Version 2 adds persisted threads,
/// queued comment operations, pending review metadata, and mention candidates.
pub const GITHUB_VERSION: u32 = 2;
/// The oldest `github.json` shape this build still reads: version 1 only held
/// `queuedViewed`.
pub const OLDEST_GITHUB_VERSION: u32 = 1;

#[derive(Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct GithubFile {
    version: u32,
    #[serde(flatten)]
    registry: SyncRegistry,
}

pub fn encode_registry(registry: &SyncRegistry) -> Result<Vec<u8>> {
    encode(&GithubFile {
        version: GITHUB_VERSION,
        registry: registry.clone(),
    })
}

pub fn decode_registry(bytes: &[u8]) -> Result<SyncRegistry> {
    let file: GithubFile = decode(bytes, OLDEST_GITHUB_VERSION, GITHUB_VERSION)?;
    Ok(file.registry)
}
```

Also update `ReviewSession::open` in `crates/review-core/src/session/mod.rs` so `threads: saved.registry.threads.clone()` restores persisted threads on startup (before the first sync).

- [ ] **Step 4: Run workspace tests**

```bash
cargo test --workspace --all-features
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-core crates/review-store-fs
git commit -m "feat(store): persist threads, queued comment ops, and metadata in github.json v2"
```

---

### Task 5: GitHub GraphQL queries and parsers for comments, reactions, conversation, and mentions

**Files:**
- Modify: `crates/review-forge-github/src/graphql.rs`
- Modify: `crates/review-forge-github/src/graphql/tests.rs`
- Modify: `crates/review-forge-github/src/lib.rs`

Extend `PENDING_REVIEW` and `THREADS` with the verified GitHub GraphQL v4 fields (`viewer { login }`, `fullDatabaseId`, `viewerDidAuthor`, `reactionGroups { content viewerHasReacted reactors { totalCount } }`), and add `CONVERSATION` (PR issue comments as `AnchorKind::Pr` threads) and `MENTIONS` (`participants` + `repository.assignableUsers`, deduplicated with participants first).

- [ ] **Step 1: Write failing parser tests in `crates/review-forge-github/src/graphql/tests.rs`**

Add tests to `crates/review-forge-github/src/graphql/tests.rs`:

```rust
#[test]
fn pending_review_also_parses_viewer_login() {
    let data = parse_data_from_answer(
        r#"{"data":{"viewer":{"login":"pablo"},"node":{"reviews":{"nodes":[
            {"id":"PRR_other","viewerDidAuthor":false},
            {"id":"PRR_mine","viewerDidAuthor":true}
        ]}}}}"#,
    )
    .unwrap();
    assert_eq!(parse_pending_review(&data).as_deref(), Some("PRR_mine"));
    assert_eq!(parse_viewer_login(&data).as_deref(), Some("pablo"));
}

#[test]
fn thread_comments_parse_full_database_id_authorship_and_non_empty_reactions() {
    let data = parse_data_from_answer(
        r#"{"data":{"node":{"headRefOid":"sha1","reviewThreads":{
            "pageInfo":{"hasNextPage":false,"endCursor":null},
            "nodes":[{
                "id":"PRRT_1","isResolved":false,"isOutdated":false,
                "subjectType":"LINE","path":"src/a.rs","line":4,"startLine":null,
                "diffSide":"RIGHT","originalLine":4,"originalStartLine":null,
                "comments":{"nodes":[{
                    "id":"PRRC_1","fullDatabaseId":"123456789","body":"looks good",
                    "createdAt":"2026-11-20T01:00:00Z","updatedAt":"2026-11-20T01:05:00Z",
                    "state":"SUBMITTED","viewerDidAuthor":true,
                    "author":{"login":"pablo","__typename":"User"},
                    "reactionGroups":[
                        {"content":"THUMBS_UP","viewerHasReacted":true,"reactors":{"totalCount":2}},
                        {"content":"EYES","viewerHasReacted":false,"reactors":{"totalCount":0}}
                    ]
                }]}
            }]
        }}}}"#,
    )
    .unwrap();
    let (_, threads, _) = parse_threads_page(&data).unwrap();
    let comment = &threads[0].messages[0];
    assert!(comment.viewer_did_author);
    assert_eq!(comment.database_id.as_deref(), Some("123456789"));
    assert_eq!(comment.reactions.len(), 1);
    assert_eq!(comment.reactions[0].count, 2);
    assert!(comment.reactions[0].viewer_has_reacted);
}

#[test]
fn conversation_page_wraps_each_issue_comment_as_a_pr_anchored_thread() {
    let data = parse_data_from_answer(
        r#"{"data":{"node":{"comments":{
            "pageInfo":{"hasNextPage":false,"endCursor":null},
            "nodes":[{
                "id":"IC_9","body":"top-level thought",
                "createdAt":"2026-11-20T02:00:00Z","updatedAt":"2026-11-20T02:00:00Z",
                "viewerDidAuthor":false,
                "author":{"login":"alice","__typename":"User"},
                "reactionGroups":[]
            }]
        }}}}"#,
    )
    .unwrap();
    let (threads, next) = parse_conversation_page(&data).unwrap();
    assert!(next.is_none());
    assert_eq!(threads.len(), 1);
    assert_eq!(threads[0].id, "IC_9");
    assert_eq!(threads[0].anchor.kind, review_model::AnchorKind::Pr);
    assert_eq!(threads[0].messages[0].body, "top-level thought");
}

#[test]
fn mentions_put_participants_first_and_deduplicate_assignable_users() {
    let data = parse_data_from_answer(
        r#"{"data":{"node":{
            "participants":{"nodes":[{"login":"bob"},{"login":"alice"}]},
            "repository":{"assignableUsers":{"nodes":[{"login":"carol"},{"login":"bob"},{"login":"dave"}]}}
        }}}"#,
    )
    .unwrap();
    let candidates = parse_mentions(&data);
    let pairs: Vec<(&str, bool)> = candidates
        .iter()
        .map(|item| (item.login.as_str(), item.is_participant))
        .collect();
    assert_eq!(
        pairs,
        [
            ("bob", true),
            ("alice", true),
            ("carol", false),
            ("dave", false),
        ]
    );
}
```

- [ ] **Step 2: Run `cargo test -p review-forge-github` to confirm failure**

```bash
cargo test -p review-forge-github
```

Expected: FAIL to compile (`parse_viewer_login`, `parse_conversation_page`, `parse_mentions` missing).

- [ ] **Step 3: Implement the GraphQL queries and parsers, and wire `GhForge::fetch`**

In `crates/review-forge-github/src/graphql.rs`:

```rust
use std::collections::HashSet;

use review_model::{
    Anchor, AnchorKind, ChangedFile, MentionCandidate, Message, MessageSync, Origin, Reaction,
    ReactionContent, Side, Thread, ThreadState, ViewedState,
};

pub const PENDING_REVIEW: &str = r"query($pr: ID!) {
  viewer { login }
  node(id: $pr) { ... on PullRequest {
    reviews(states: PENDING, first: 20) { nodes { id viewerDidAuthor } }
  } }
}";

pub const THREADS: &str = r"query($pr: ID!, $after: String) {
  node(id: $pr) { ... on PullRequest {
    headRefOid
    reviewThreads(first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id isResolved isOutdated subjectType path line startLine diffSide originalLine originalStartLine
        comments(first: 100) {
          nodes {
            id fullDatabaseId body url createdAt updatedAt state viewerDidAuthor
            author { login __typename }
            reactionGroups { content viewerHasReacted reactors { totalCount } }
          }
        }
      }
    }
  } }
}";

/// One page of top-level pull-request conversation comments.
pub const CONVERSATION: &str = r"query($pr: ID!, $after: String) {
  node(id: $pr) { ... on PullRequest {
    comments(first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id body createdAt updatedAt viewerDidAuthor
        author { login __typename }
        reactionGroups { content viewerHasReacted reactors { totalCount } }
      }
    }
  } }
}";

/// Pull-request participants and repository assignable users for `@mention` completion.
pub const MENTIONS: &str = r"query($pr: ID!) {
  node(id: $pr) { ... on PullRequest {
    participants(first: 100) { nodes { login } }
    repository { assignableUsers(first: 100) { nodes { login } } }
  } }
}";
```

Add the parsing helpers in `crates/review-forge-github/src/graphql.rs` (keeping `parse_thread` and `parse_comment` public to the crate as `pub(crate)` so Task 6's mutation parsers reuse them directly):

```rust
/// The authenticated viewer's login in `PENDING_REVIEW`.
#[must_use]
pub fn parse_viewer_login(data: &Value) -> Option<String> {
    data.pointer("/viewer/login")?
        .as_str()
        .map(str::to_owned)
}

/// Parses one page of `CONVERSATION` into `AnchorKind::Pr` threads.
pub fn parse_conversation_page(data: &Value) -> Result<(Vec<Thread>, Option<String>)> {
    let comments = data
        .pointer("/node/comments")
        .context("GitHub returned no pull request conversation comments")?;
    let threads = comments["nodes"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .filter_map(parse_issue_comment_thread)
        .collect();
    Ok((threads, next_cursor(comments)))
}

pub(crate) fn parse_issue_comment_thread(node: &Value) -> Option<Thread> {
    let message = parse_comment(node)?;
    Some(Thread {
        id: message.id.clone(),
        origin: Origin::Github,
        anchor: Anchor::pr(),
        state: ThreadState::Open,
        outdated: false,
        messages: vec![message],
    })
}

/// Parses `MENTIONS`, placing PR participants ahead of other assignable users.
#[must_use]
pub fn parse_mentions(data: &Value) -> Vec<MentionCandidate> {
    let mut seen = HashSet::new();
    let mut candidates = Vec::new();
    let mut push_group = |pointer: &str, is_participant: bool| {
        let Some(nodes) = data.pointer(pointer).and_then(Value::as_array) else {
            return;
        };
        for node in nodes {
            let Some(login) = node["login"].as_str().filter(|login| !login.is_empty()) else {
                continue;
            };
            if seen.insert(login.to_owned()) {
                candidates.push(MentionCandidate {
                    login: login.to_owned(),
                    is_participant,
                });
            }
        }
    };
    push_group("/node/participants/nodes", true);
    push_group("/node/repository/assignableUsers/nodes", false);
    candidates
}

pub(crate) fn parse_reactions(node: &Value) -> Vec<Reaction> {
    node["reactionGroups"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .filter_map(|group| {
            let count_u64 = group.pointer("/reactors/totalCount")?.as_u64()?;
            if count_u64 == 0 {
                return None;
            }
            let content = ReactionContent::parse(group["content"].as_str()?)?;
            Some(Reaction {
                content,
                count: u32::try_from(count_u64).unwrap_or(u32::MAX),
                viewer_has_reacted: group["viewerHasReacted"].as_bool().unwrap_or(false),
            })
        })
        .collect()
}

fn parse_database_id(node: &Value) -> Option<String> {
    if let Some(text) = node["fullDatabaseId"].as_str() {
        return Some(text.to_owned());
    }
    node["fullDatabaseId"].as_u64().map(|num| num.to_string())
}
```

Update `parse_comment` in `crates/review-forge-github/src/graphql.rs` (`pub(crate) fn parse_comment`) to populate `viewer_did_author: node["viewerDidAuthor"].as_bool().unwrap_or(false)`, `database_id: parse_database_id(node)`, `reactions: parse_reactions(node)`, `sync_error: None`, and `recoverable_body: None`.

Update `GhForge::fetch` in `crates/review-forge-github/src/lib.rs` to also pull `CONVERSATION` and `MENTIONS` and set `pending_review_id`, `viewer_login`, and `mention_candidates`:

```rust
    fn fetch(&self, pr: &PullRequest) -> Result<ForgeSnapshot> {
        let mut head_sha = pr.head_sha.clone();
        let mut threads = self.paged(graphql::THREADS, pr, |data| {
            let (page_head_sha, page_threads, next_cursor) = graphql::parse_threads_page(data)?;
            if !page_head_sha.is_empty() {
                head_sha = page_head_sha;
            }
            Ok((page_threads, next_cursor))
        })?;
        threads.extend(self.paged(
            graphql::CONVERSATION,
            pr,
            graphql::parse_conversation_page,
        )?);
        let files = self.paged(graphql::FILES, pr, graphql::parse_files_page)?;
        let pending_data = self.graphql(graphql::PENDING_REVIEW, &json!({ "pr": pr.node_id }))?;
        let pending_review_id = graphql::parse_pending_review(&pending_data);
        let viewer_login = graphql::parse_viewer_login(&pending_data);
        let mentions_data = self.graphql(graphql::MENTIONS, &json!({ "pr": pr.node_id }))?;
        Ok(ForgeSnapshot {
            head_sha,
            has_pending_review: pending_review_id.is_some(),
            pending_review_id,
            viewer_login,
            threads,
            files,
            mention_candidates: graphql::parse_mentions(&mentions_data),
        })
    }
```

- [ ] **Step 4: Run tests**

```bash
cargo test --workspace --all-features
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-forge-github
git commit -m "feat(github): query and parse comment metadata, reactions, conversation, and mentions"
```

---

### Task 6: `Forge` write methods, `FakeForge`, and `GhForge` mutations + REST reply fallback `[HIGH-RISK]`

**Files:**
- Create: `crates/review-forge-github/src/mutations.rs`
- Modify: `crates/review-core/src/ports.rs`
- Modify: `crates/review-core/src/fakes.rs`
- Modify: `crates/review-forge-github/src/gh.rs`
- Modify: `crates/review-forge-github/src/graphql.rs`
- Modify: `crates/review-forge-github/src/lib.rs`

Add the eight comment/review write operations to `Forge`, implement them on `FakeForge` (including transient vs rejected write simulation for session tests), and implement `GhForge` over the verified GitHub GraphQL mutations plus the REST immediate-reply endpoint with automatic HTTP 422 pending-review fallback.

- [ ] **Step 1: Write failing unit tests for `mutations.rs` and `FakeForge`**

Create `crates/review-forge-github/src/mutations.rs` starting with `#[cfg(test)] mod tests` testing:
1. `build_thread_variables` builds `subjectType: "FILE"` for `AnchorKind::File`, `subjectType: "LINE"` with `line` + `side` for `AnchorKind::Line`, and adds `startLine` + `startSide` for `AnchorKind::Range`.
2. `classify_write_error` maps timeouts, DNS/socket failures, HTTP 502/503, and rate limits to `ForgeWriteError::Transient`, and HTTP 422 / `"Line could not be resolved"` / `"Comment not found"` to `ForgeWriteError::Rejected`.
3. `is_pending_review_rest_conflict` returns `true` only when a REST reply error mentions both `422` (or `Validation Failed`) and `pending review`.
4. `parse_rest_reply` converts a GitHub REST pull comment JSON response (`node_id`, `id`, `body`, `created_at`, `updated_at`, `user.login`) into a `MessageSync::Published` `Message` with `viewer_did_author: true`.

```rust
#[cfg(test)]
mod tests {
    use review_core::ports::ForgeWriteError;
    use review_model::{Anchor, MessageSync, Side};

    use super::*;

    #[test]
    fn thread_variables_cover_file_single_line_and_range_anchors() {
        let file_vars = build_thread_variables("PR_1", "PRR_1", &Anchor::file("src/a.rs"), "hi");
        assert_eq!(file_vars["subjectType"], "FILE");
        assert!(file_vars.get("line").is_none());

        let range_vars = build_thread_variables(
            "PR_1",
            "PRR_1",
            &Anchor::range("src/a.rs", Side::Left, 3, 6),
            "span",
        );
        assert_eq!(range_vars["subjectType"], "LINE");
        assert_eq!(range_vars["startLine"], 3);
        assert_eq!(range_vars["line"], 6);
        assert_eq!(range_vars["side"], "LEFT");
        assert_eq!(range_vars["startSide"], "LEFT");
    }

    #[test]
    fn error_classification_separates_transient_network_failures_from_rejections() {
        assert!(matches!(
            classify_write_error(&anyhow::anyhow!("gh timed out after 30s")),
            ForgeWriteError::Transient(_)
        ));
        assert!(matches!(
            classify_write_error(&anyhow::anyhow!("error connecting to api.github.com")),
            ForgeWriteError::Transient(_)
        ));
        assert!(matches!(
            classify_write_error(&anyhow::anyhow!("Line could not be resolved")),
            ForgeWriteError::Rejected(_)
        ));
    }

    #[test]
    fn rest_reply_parser_reads_published_comment_fields() {
        let raw = r#"{
            "id": 98765,
            "node_id": "PRRC_rest",
            "body": "thanks!",
            "created_at": "2026-11-20T03:00:00Z",
            "updated_at": "2026-11-20T03:00:00Z",
            "user": {"login": "pablo", "type": "User"}
        }"#;
        let message = parse_rest_reply(raw).unwrap();
        assert_eq!(message.id, "PRRC_rest");
        assert_eq!(message.database_id.as_deref(), Some("98765"));
        assert_eq!(message.sync, Some(MessageSync::Published));
        assert!(message.viewer_did_author);
    }

    #[test]
    fn detects_rest_422_pending_review_conflict() {
        assert!(is_pending_review_rest_conflict(
            "HTTP 422: user_id can only have one pending review per pull request"
        ));
        assert!(!is_pending_review_rest_conflict("HTTP 404: Not Found"));
    }
}
```

- [ ] **Step 2: Run `cargo test -p review-forge-github` to confirm failure**

Add `mod mutations;` to `crates/review-forge-github/src/lib.rs` and run:

```bash
cargo test -p review-forge-github
```

Expected: FAIL to compile (`build_thread_variables`, `classify_write_error`, `parse_rest_reply`, `is_pending_review_rest_conflict` missing).

- [ ] **Step 3: Extend `Forge`, implement `mutations.rs`, and wire `GhForge` + `FakeForge`**

Add the write methods to `Forge` in `crates/review-core/src/ports.rs`:

```rust
pub trait Forge: Send {
    fn pull_request(&self, number: u64) -> Result<PullRequest>;
    fn fetch(&self, pr: &PullRequest) -> Result<ForgeSnapshot>;
    fn set_viewed(&self, pr: &PullRequest, path: &str, viewed: bool) -> Result<()>;

    /// Creates a draft review thread in `pending_review_id` (creating a pending
    /// review on `pr.head_sha` first when `None`).
    fn create_review_thread(
        &self,
        pr: &PullRequest,
        pending_review_id: Option<&str>,
        anchor: &Anchor,
        body: &str,
    ) -> std::result::Result<CreatedReviewThread, ForgeWriteError>;

    /// Publishes a top-level pull-request conversation comment (`AnchorKind::Pr`).
    fn create_conversation_comment(
        &self,
        pr: &PullRequest,
        body: &str,
    ) -> std::result::Result<Thread, ForgeWriteError>;

    /// Replies to an existing code review thread: publishes immediately via REST
    /// when no pending review blocks it, else adds a draft reply to the pending review.
    fn reply_to_thread(
        &self,
        pr: &PullRequest,
        request: &ReplyRequest<'_>,
    ) -> std::result::Result<Message, ForgeWriteError>;

    /// Updates the body of a review comment or issue comment.
    fn edit_message(
        &self,
        anchor_kind: AnchorKind,
        message_id: &str,
        body: &str,
    ) -> std::result::Result<Message, ForgeWriteError>;

    /// Deletes a review comment or issue comment.
    fn delete_message(
        &self,
        anchor_kind: AnchorKind,
        message_id: &str,
    ) -> std::result::Result<(), ForgeWriteError>;

    /// Resolves or unresolves a code review thread.
    fn set_resolved(
        &self,
        thread_id: &str,
        resolved: bool,
    ) -> std::result::Result<(), ForgeWriteError>;

    /// Adds (`added == true`) or removes (`added == false`) a reaction on `subject_id`,
    /// returning the updated non-empty reactions.
    fn set_reaction(
        &self,
        subject_id: &str,
        content: ReactionContent,
        added: bool,
    ) -> std::result::Result<Vec<Reaction>, ForgeWriteError>;

    /// Submits `pending_review_id` (or creates and submits a new review on
    /// `pr.head_sha` when `pending_review_id` is `None`).
    fn submit_review(
        &self,
        pr: &PullRequest,
        pending_review_id: Option<&str>,
        event: ReviewEvent,
        body: &str,
    ) -> std::result::Result<(), ForgeWriteError>;
}
```

In `crates/review-forge-github/src/gh.rs`, update the non-zero exit path in `Gh::run` so REST error details printed on `stdout` (`{"message": ..., "errors": [{"message": ...}]}`) are included alongside `stderr`:

```rust
        if !output.status.success() {
            if let Some(message) = graphql::error_message(&stdout) {
                bail!("{message}");
            }
            let stderr = String::from_utf8_lossy(&output.stderr);
            if let Some(rest_detail) = graphql::rest_error_message(&stdout) {
                bail!("{}: {rest_detail}", stderr.trim());
            }
            bail!("{}", stderr.trim());
        }
```

And add `rest_error_message` in `crates/review-forge-github/src/graphql.rs`:

```rust
#[must_use]
pub fn rest_error_message(stdout: &str) -> Option<String> {
    let value: Value = serde_json::from_str(stdout).ok()?;
    if let Some(detail) = value.pointer("/errors/0/message").and_then(Value::as_str) {
        return Some(detail.to_owned());
    }
    value["message"].as_str().map(str::to_owned)
}
```

Implement `crates/review-forge-github/src/mutations.rs` with the verified GraphQL mutation strings, variable builders, response parsers, REST reply parser, and `classify_write_error`:

```rust
//! GitHub GraphQL mutations, REST immediate-reply parsing, and write-error
//! classification.

use anyhow::{Context, Result, anyhow};
use review_core::ports::{CreatedReviewThread, ForgeWriteError, ReplyRequest};
use review_model::{
    Anchor, AnchorKind, Message, MessageSync, PullRequest, Reaction, ReactionContent, ReviewEvent,
    Side, Thread,
};
use serde_json::{Map, Value, json};

use crate::GhForge;
use crate::graphql::{parse_comment, parse_issue_comment_thread, parse_reactions, parse_thread};

const ADD_PENDING_REVIEW: &str = r"mutation($pr: ID!, $commit: GitObjectID) {
  addPullRequestReview(input: { pullRequestId: $pr, commitOID: $commit }) {
    pullRequestReview { id }
  }
}";

const SUBMIT_DIRECT_REVIEW: &str = r"mutation($pr: ID!, $commit: GitObjectID, $event: PullRequestReviewEvent!, $body: String) {
  addPullRequestReview(input: { pullRequestId: $pr, commitOID: $commit, event: $event, body: $body }) {
    pullRequestReview { id }
  }
}";

const SUBMIT_PENDING_REVIEW: &str = r"mutation($pr: ID!, $review: ID!, $event: PullRequestReviewEvent!, $body: String) {
  submitPullRequestReview(input: { pullRequestId: $pr, pullRequestReviewId: $review, event: $event, body: $body }) {
    pullRequestReview { id }
  }
}";

const ADD_REVIEW_THREAD: &str = r"mutation($input: AddPullRequestReviewThreadInput!) {
  addPullRequestReviewThread(input: $input) {
    thread {
      id isResolved isOutdated subjectType path line startLine diffSide originalLine originalStartLine
      comments(first: 20) {
        nodes {
          id fullDatabaseId body createdAt updatedAt state viewerDidAuthor
          author { login __typename }
          reactionGroups { content viewerHasReacted reactors { totalCount } }
        }
      }
    }
  }
}";

const ADD_THREAD_REPLY: &str = r"mutation($review: ID!, $thread: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: { pullRequestReviewId: $review, pullRequestReviewThreadId: $thread, body: $body }) {
    comment {
      id fullDatabaseId body createdAt updatedAt state viewerDidAuthor
      author { login __typename }
      reactionGroups { content viewerHasReacted reactors { totalCount } }
    }
  }
}";

const ADD_ISSUE_COMMENT: &str = r"mutation($pr: ID!, $body: String!) {
  addComment(input: { subjectId: $pr, body: $body }) {
    commentEdge {
      node {
        ... on IssueComment {
          id body createdAt updatedAt viewerDidAuthor
          author { login __typename }
          reactionGroups { content viewerHasReacted reactors { totalCount } }
        }
      }
    }
  }
}";

const UPDATE_REVIEW_COMMENT: &str = r"mutation($id: ID!, $body: String!) {
  updatePullRequestReviewComment(input: { pullRequestReviewCommentId: $id, body: $body }) {
    pullRequestReviewComment {
      id fullDatabaseId body createdAt updatedAt state viewerDidAuthor
      author { login __typename }
      reactionGroups { content viewerHasReacted reactors { totalCount } }
    }
  }
}";

const UPDATE_ISSUE_COMMENT: &str = r"mutation($id: ID!, $body: String!) {
  updateIssueComment(input: { id: $id, body: $body }) {
    issueComment {
      id body createdAt updatedAt viewerDidAuthor
      author { login __typename }
      reactionGroups { content viewerHasReacted reactors { totalCount } }
    }
  }
}";

const DELETE_REVIEW_COMMENT: &str = r"mutation($id: ID!) {
  deletePullRequestReviewComment(input: { id: $id }) { clientMutationId }
}";

const DELETE_ISSUE_COMMENT: &str = r"mutation($id: ID!) {
  deleteIssueComment(input: { id: $id }) { clientMutationId }
}";

const RESOLVE_THREAD: &str = r"mutation($id: ID!) {
  resolveReviewThread(input: { threadId: $id }) { thread { id } }
}";

const UNRESOLVE_THREAD: &str = r"mutation($id: ID!) {
  unresolveReviewThread(input: { threadId: $id }) { thread { id } }
}";

const ADD_REACTION: &str = r"mutation($id: ID!, $content: ReactionContent!) {
  addReaction(input: { subjectId: $id, content: $content }) {
    reactionGroups { content viewerHasReacted reactors { totalCount } }
  }
}";

const REMOVE_REACTION: &str = r"mutation($id: ID!, $content: ReactionContent!) {
  removeReaction(input: { subjectId: $id, content: $content }) {
    reactionGroups { content viewerHasReacted reactors { totalCount } }
  }
}";
```

Add the execution functions and `GhForge` methods in `crates/review-forge-github/src/mutations.rs`:

```rust
pub(crate) fn build_thread_variables(
    pr_id: &str,
    review_id: &str,
    anchor: &Anchor,
    body: &str,
) -> Value {
    let mut input = Map::new();
    input.insert("pullRequestId".into(), Value::String(pr_id.to_owned()));
    input.insert("pullRequestReviewId".into(), Value::String(review_id.to_owned()));
    input.insert(
        "path".into(),
        Value::String(anchor.file.clone().unwrap_or_default()),
    );
    input.insert("body".into(), Value::String(body.to_owned()));
    if anchor.kind == AnchorKind::File {
        input.insert("subjectType".into(), Value::String("FILE".into()));
        return Value::Object(input);
    }
    let side_label = if anchor.side == Side::Left { "LEFT" } else { "RIGHT" };
    input.insert("subjectType".into(), Value::String("LINE".into()));
    input.insert("line".into(), json!(anchor.end.unwrap_or(1)));
    input.insert("side".into(), Value::String(side_label.into()));
    if anchor.kind == AnchorKind::Range
        && let Some(start) = anchor.start
    {
        input.insert("startLine".into(), json!(start));
        input.insert("startSide".into(), Value::String(side_label.into()));
    }
    Value::Object(input)
}

pub(crate) fn classify_write_error(error: &anyhow::Error) -> ForgeWriteError {
    let text = format!("{error:#}");
    let lower = text.to_lowercase();
    let is_transient = [
        "timed out",
        "connecting",
        "connection",
        "network",
        "temporary",
        "eof",
        "reset by peer",
        "http 502",
        "http 503",
        "http 504",
        "rate limit",
        "is the github cli installed",
    ]
    .iter()
    .any(|needle| lower.contains(needle));
    if is_transient {
        ForgeWriteError::Transient(text)
    } else {
        ForgeWriteError::Rejected(text)
    }
}

pub(crate) fn is_pending_review_rest_conflict(message: &str) -> bool {
    let has_validation_code = message.contains("422") || message.contains("Validation Failed");
    has_validation_code && message.to_lowercase().contains("pending review")
}

pub(crate) fn parse_rest_reply(stdout: &str) -> Result<Message> {
    let node: Value = serde_json::from_str(stdout).context("parsing GitHub REST reply JSON")?;
    let id = node["node_id"]
        .as_str()
        .context("REST reply had no node_id")?
        .to_owned();
    let login = node
        .pointer("/user/login")
        .and_then(Value::as_str)
        .unwrap_or("ghost");
    let is_bot = node.pointer("/user/type").and_then(Value::as_str) == Some("Bot");
    Ok(Message {
        id,
        author: if is_bot && !login.ends_with("[bot]") {
            format!("{login}[bot]")
        } else {
            login.to_owned()
        },
        body: node["body"].as_str().unwrap_or_default().to_owned(),
        created: node["created_at"].as_str().unwrap_or_default().to_owned(),
        updated: node["updated_at"].as_str().unwrap_or_default().to_owned(),
        sync: Some(MessageSync::Published),
        viewer_did_author: true,
        database_id: node["id"].as_u64().map(|num| num.to_string()),
        reactions: Vec::new(),
        sync_error: None,
        recoverable_body: None,
    })
}

impl GhForge {
    pub(crate) fn ensure_pending_review(
        &self,
        pr: &PullRequest,
        existing: Option<&str>,
    ) -> std::result::Result<String, ForgeWriteError> {
        if let Some(review_id) = existing {
            return Ok(review_id.to_owned());
        }
        let vars = json!({
            "pr": pr.node_id,
            "commit": (!pr.head_sha.is_empty()).then_some(pr.head_sha.as_str()),
        });
        let data = self.graphql(ADD_PENDING_REVIEW, &vars).map_err(|err| classify_write_error(&err))?;
        data.pointer("/addPullRequestReview/pullRequestReview/id")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| ForgeWriteError::Rejected("GitHub returned no pending review id".into()))
    }

    pub(crate) fn create_review_thread_impl(
        &self,
        pr: &PullRequest,
        pending_review_id: Option<&str>,
        anchor: &Anchor,
        body: &str,
    ) -> std::result::Result<CreatedReviewThread, ForgeWriteError> {
        let review_id = self.ensure_pending_review(pr, pending_review_id)?;
        let input = build_thread_variables(&pr.node_id, &review_id, anchor, body);
        let data = self
            .graphql(ADD_REVIEW_THREAD, &json!({ "input": input }))
            .map_err(|err| classify_write_error(&err))?;
        let thread_node = data
            .pointer("/addPullRequestReviewThread/thread")
            .ok_or_else(|| ForgeWriteError::Rejected("GitHub returned no review thread".into()))?;
        let thread = parse_thread(thread_node)
            .ok_or_else(|| ForgeWriteError::Rejected("could not parse created review thread".into()))?;
        Ok(CreatedReviewThread {
            pending_review_id: review_id,
            thread,
        })
    }

    pub(crate) fn create_conversation_comment_impl(
        &self,
        pr: &PullRequest,
        body: &str,
    ) -> std::result::Result<Thread, ForgeWriteError> {
        let data = self
            .graphql(ADD_ISSUE_COMMENT, &json!({ "pr": pr.node_id, "body": body }))
            .map_err(|err| classify_write_error(&err))?;
        let node = data
            .pointer("/addComment/commentEdge/node")
            .ok_or_else(|| ForgeWriteError::Rejected("GitHub returned no issue comment".into()))?;
        parse_issue_comment_thread(node)
            .ok_or_else(|| ForgeWriteError::Rejected("could not parse issue comment".into()))
    }

    pub(crate) fn reply_to_thread_impl(
        &self,
        pr: &PullRequest,
        request: &ReplyRequest<'_>,
    ) -> std::result::Result<Message, ForgeWriteError> {
        if let Some(review_id) = request.pending_review_id {
            return self.reply_in_pending_review(review_id, request.thread_id, request.body);
        }
        if let Some(root_db_id) = request.root_database_id {
            match self.reply_via_rest(pr, root_db_id, request.body) {
                Ok(message) => return Ok(message),
                Err(error) if is_pending_review_rest_conflict(&format!("{error:#}")) => {
                    let pending_data = self
                        .graphql(crate::graphql::PENDING_REVIEW, &json!({ "pr": pr.node_id }))
                        .map_err(|err| classify_write_error(&err))?;
                    let existing = crate::graphql::parse_pending_review(&pending_data);
                    let review_id = self.ensure_pending_review(pr, existing.as_deref())?;
                    return self.reply_in_pending_review(&review_id, request.thread_id, request.body);
                }
                Err(error) => return Err(classify_write_error(&error)),
            }
        }
        let review_id = self.ensure_pending_review(pr, None)?;
        self.reply_in_pending_review(&review_id, request.thread_id, request.body)
    }

    fn reply_via_rest(&self, pr: &PullRequest, root_db_id: &str, body: &str) -> Result<Message> {
        let endpoint = format!(
            "repos/{}/{}/pulls/{}/comments/{root_db_id}/replies",
            pr.owner, pr.repo, pr.number
        );
        let stdout = self.gh.run(
            &["api", &endpoint, "--method", "POST", "--input", "-"],
            Some(&json!({ "body": body })),
        )?;
        parse_rest_reply(&stdout)
    }

    fn reply_in_pending_review(
        &self,
        review_id: &str,
        thread_id: &str,
        body: &str,
    ) -> std::result::Result<Message, ForgeWriteError> {
        let vars = json!({ "review": review_id, "thread": thread_id, "body": body });
        let data = self
            .graphql(ADD_THREAD_REPLY, &vars)
            .map_err(|err| classify_write_error(&err))?;
        data.pointer("/addPullRequestReviewThreadReply/comment")
            .and_then(parse_comment)
            .ok_or_else(|| ForgeWriteError::Rejected("GitHub returned no reply comment".into()))
    }

    pub(crate) fn edit_message_impl(
        &self,
        anchor_kind: AnchorKind,
        message_id: &str,
        body: &str,
    ) -> std::result::Result<Message, ForgeWriteError> {
        let (mutation, pointer) = if anchor_kind == AnchorKind::Pr {
            (UPDATE_ISSUE_COMMENT, "/updateIssueComment/issueComment")
        } else {
            (
                UPDATE_REVIEW_COMMENT,
                "/updatePullRequestReviewComment/pullRequestReviewComment",
            )
        };
        let data = self
            .graphql(mutation, &json!({ "id": message_id, "body": body }))
            .map_err(|err| classify_write_error(&err))?;
        data.pointer(pointer)
            .and_then(parse_comment)
            .ok_or_else(|| ForgeWriteError::Rejected("GitHub returned no updated comment".into()))
    }

    pub(crate) fn delete_message_impl(
        &self,
        anchor_kind: AnchorKind,
        message_id: &str,
    ) -> std::result::Result<(), ForgeWriteError> {
        let mutation = if anchor_kind == AnchorKind::Pr {
            DELETE_ISSUE_COMMENT
        } else {
            DELETE_REVIEW_COMMENT
        };
        self.graphql(mutation, &json!({ "id": message_id }))
            .map_err(|err| classify_write_error(&err))?;
        Ok(())
    }

    pub(crate) fn set_resolved_impl(
        &self,
        thread_id: &str,
        resolved: bool,
    ) -> std::result::Result<(), ForgeWriteError> {
        let mutation = if resolved { RESOLVE_THREAD } else { UNRESOLVE_THREAD };
        self.graphql(mutation, &json!({ "id": thread_id }))
            .map_err(|err| classify_write_error(&err))?;
        Ok(())
    }

    pub(crate) fn set_reaction_impl(
        &self,
        subject_id: &str,
        content: ReactionContent,
        added: bool,
    ) -> std::result::Result<Vec<Reaction>, ForgeWriteError> {
        let (mutation, pointer) = if added {
            (ADD_REACTION, "/addReaction")
        } else {
            (REMOVE_REACTION, "/removeReaction")
        };
        let vars = json!({ "id": subject_id, "content": content.as_str() });
        let data = self
            .graphql(mutation, &vars)
            .map_err(|err| classify_write_error(&err))?;
        let container = data
            .pointer(pointer)
            .ok_or_else(|| ForgeWriteError::Rejected("GitHub returned no reactionGroups".into()))?;
        Ok(parse_reactions(container))
    }

    pub(crate) fn submit_review_impl(
        &self,
        pr: &PullRequest,
        pending_review_id: Option<&str>,
        event: ReviewEvent,
        body: &str,
    ) -> std::result::Result<(), ForgeWriteError> {
        let body_opt = (!body.trim().is_empty()).then_some(body);
        if let Some(review_id) = pending_review_id {
            let vars = json!({
                "pr": pr.node_id,
                "review": review_id,
                "event": event.as_str(),
                "body": body_opt,
            });
            self.graphql(SUBMIT_PENDING_REVIEW, &vars)
                .map_err(|err| classify_write_error(&err))?;
        } else {
            let vars = json!({
                "pr": pr.node_id,
                "commit": (!pr.head_sha.is_empty()).then_some(pr.head_sha.as_str()),
                "event": event.as_str(),
                "body": body_opt,
            });
            self.graphql(SUBMIT_DIRECT_REVIEW, &vars)
                .map_err(|err| classify_write_error(&err))?;
        }
        Ok(())
    }
}
```

Delegate all eight `Forge` trait methods in `crates/review-forge-github/src/lib.rs` directly to those `*_impl` methods on `GhForge`.

In `crates/review-core/src/fakes.rs`, add `rejected_write_failure: Option<String>` and `next_id: u64` to `ForgeState`, add `pub fn reject_writes_with(&self, message: Option<&str>)`, and implement the eight `Forge` methods on `FakeForge`:
- `check_write(&self, state: &ForgeState) -> std::result::Result<(), ForgeWriteError>` returning `Err(ForgeWriteError::Rejected(...))` when `rejected_write_failure` is `Some`, `Err(ForgeWriteError::Transient(...))` when `failure` or `write_failure` is `Some`, else `Ok(())`.
- `create_review_thread` allocates `PRR_fake` (when `pending_review_id` is `None`), creates a `Thread` (`PRRT_fake_{n}`) with one `MessageSync::Draft` message (`PRRC_fake_{n}`, `viewer_did_author: true`, `database_id: Some((1000 + n).to_string())`), pushes it to `state.snapshot.threads`, sets `state.snapshot.has_pending_review = true`, and returns `CreatedReviewThread`.
- `create_conversation_comment` creates an `Anchor::pr()` `Thread` (`IC_fake_{n}`) with `MessageSync::Published` and pushes it to `state.snapshot.threads`.
- `reply_to_thread` appends a `Message` (`PRRC_fake_{n}`) to the matching thread in `state.snapshot.threads` with `MessageSync::Draft` when `request.pending_review_id.is_some()` or `state.snapshot.has_pending_review`, else `MessageSync::Published`.
- `edit_message`, `delete_message`, `set_resolved`, `set_reaction`, and `submit_review` mutate `state.snapshot` in place (with `submit_review` flipping every `MessageSync::Draft` message to `MessageSync::Published` and clearing `has_pending_review` / `pending_review_id`).

- [ ] **Step 4: Run workspace tests**

```bash
cargo test --workspace --all-features
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-core crates/review-forge-github
git commit -m "feat(github): implement comment, reaction, resolve, and review-submission forge writes"
```

---

### Task 7: Pure comment state helpers and `SessionView` counts (`comments.rs` & `presenter.rs`)

**Files:**
- Create: `crates/review-core/src/comments.rs`
- Modify: `crates/review-core/src/presenter.rs`
- Modify: `crates/review-core/src/session/mod.rs`
- Modify: `crates/review-core/src/lib.rs`

Keep ID remapping, concurrent-edit detection, offline placeholder merging, and submit-preview building pure in `crates/review-core/src/comments.rs`, and compute `draft_count`, `conversation_count`, and code-only `thread_count` in `presenter::session_view`.

- [ ] **Step 1: Write failing unit tests in `comments.rs` and `presenter.rs`**

Create `crates/review-core/src/comments.rs` with tests first:

```rust
//! Pure state transitions for threads, queued comment operations, concurrent
//! edit recovery, and review-submission previews.

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use review_model::{Anchor, Message, MessageSync, Origin, Side, Thread, ThreadState};

    use super::*;
    use crate::ports::QueuedCommentOp;

    #[test]
    fn remapping_rewrites_dependent_queued_ops_after_temp_ids_resolve() {
        let mut ops = vec![
            QueuedCommentOp::ReplyToThread {
                thread_id: "tmp-t-1".into(),
                root_database_id: None,
                temp_message_id: "tmp-m-2".into(),
                body: "follow-up".into(),
            },
            QueuedCommentOp::EditMessage {
                thread_id: "tmp-t-1".into(),
                anchor_kind: review_model::AnchorKind::Line,
                message_id: "tmp-m-1".into(),
                body: "edited".into(),
            },
        ];
        remap_queued_ops(&mut ops, "tmp-t-1", "PRRT_9");
        remap_queued_ops(&mut ops, "tmp-m-1", "PRRC_9");
        assert!(matches!(
            &ops[0],
            QueuedCommentOp::ReplyToThread { thread_id, .. } if thread_id == "PRRT_9"
        ));
        assert!(matches!(
            &ops[1],
            QueuedCommentOp::EditMessage { thread_id, message_id, .. }
                if thread_id == "PRRT_9" && message_id == "PRRC_9"
        ));
    }

    #[test]
    fn concurrent_forge_edit_wins_and_preserves_local_edit_as_recoverable_body() {
        let mut remote_threads = vec![Thread {
            id: "PRRT_1".into(),
            origin: Origin::Github,
            anchor: Anchor::line("src/a.rs", 4),
            state: ThreadState::Open,
            outdated: false,
            messages: vec![Message::create_with_sync(
                "PRRC_1",
                "pablo",
                "edited on GitHub web",
                "2026-11-20T00:00:00Z",
                Some(MessageSync::Published),
            )],
        }];
        let mut agreed = BTreeMap::from([("PRRC_1".to_owned(), "original body".to_owned())]);
        let mut ops = vec![QueuedCommentOp::EditMessage {
            thread_id: "PRRT_1".into(),
            anchor_kind: review_model::AnchorKind::Line,
            message_id: "PRRC_1".into(),
            body: "edited offline in nvim".into(),
        }];

        reconcile_concurrent_edits(&mut remote_threads, &mut agreed, &mut ops);

        assert!(ops.is_empty(), "conflicting EditMessage is dropped");
        assert_eq!(remote_threads[0].messages[0].body, "edited on GitHub web");
        assert_eq!(
            remote_threads[0].messages[0].recoverable_body.as_deref(),
            Some("edited offline in nvim")
        );
        assert_eq!(agreed.get("PRRC_1").map(String::as_str), Some("edited on GitHub web"));
    }

    #[test]
    fn submit_preview_collects_drafts_and_disallows_self_approval() {
        let threads = vec![Thread {
            id: "PRRT_1".into(),
            origin: Origin::Github,
            anchor: Anchor::side_line("src/a.rs", Side::Right, 10),
            state: ThreadState::Open,
            outdated: false,
            messages: vec![Message::create_with_sync(
                "PRRC_1",
                "alice",
                "nit here\nmore detail",
                "2026-11-20T00:00:00Z",
                Some(MessageSync::Draft),
            )],
        }];
        let own = create_submit_preview_from_threads("alice", Some("alice"), &threads);
        assert!(!own.can_approve_or_request_changes);
        assert_eq!(own.draft_count, 1);
        assert_eq!(own.drafts[0].snippet, "nit here");

        let peer = create_submit_preview_from_threads("alice", Some("bob"), &threads);
        assert!(peer.can_approve_or_request_changes);
    }
}
```

Update `counts_threads_per_file_and_viewed_files` in `crates/review-core/src/presenter.rs` to also include one `Anchor::pr()` conversation thread and one `MessageSync::Draft` message, asserting `view.thread_count == 3`, `view.conversation_count == 1`, and `view.draft_count == 1`.

- [ ] **Step 2: Run `cargo test -p review-core` to confirm failure**

Add `mod comments;` to `crates/review-core/src/lib.rs`, then run:

```bash
cargo test -p review-core
```

Expected: FAIL (`remap_queued_ops`, `reconcile_concurrent_edits`, `create_submit_preview_from_threads` missing; `presenter.rs` counts fail).

- [ ] **Step 3: Implement `crates/review-core/src/comments.rs` and update `presenter.rs`**

Put this above `#[cfg(test)]` in `crates/review-core/src/comments.rs`:

```rust
use std::collections::{BTreeMap, HashSet};

use review_model::{
    AnchorKind, Message, MessageSync, Reaction, ReactionContent, SubmitDraft, SubmitPreview, Thread,
};

use crate::ports::QueuedCommentOp;

/// Rewrites `from_id` to `to_id` across every queued operation waiting behind
/// a newly created thread or message.
pub(crate) fn remap_queued_ops(ops: &mut [QueuedCommentOp], from_id: &str, to_id: &str) {
    let replace = |target: &mut String| {
        if target == from_id {
            *target = to_id.to_owned();
        }
    };
    for op in ops {
        match op {
            QueuedCommentOp::ReplyToThread { thread_id, .. }
            | QueuedCommentOp::SetResolved { thread_id, .. } => replace(thread_id),
            QueuedCommentOp::EditMessage {
                thread_id,
                message_id,
                ..
            }
            | QueuedCommentOp::DeleteMessage {
                thread_id,
                message_id,
                ..
            } => {
                replace(thread_id);
                replace(message_id);
            }
            QueuedCommentOp::SetReaction { subject_id, .. } => replace(subject_id),
            QueuedCommentOp::CreateReviewThread { .. }
            | QueuedCommentOp::CreateConversationComment { .. }
            | QueuedCommentOp::SubmitReview { .. } => {}
        }
    }
}

/// Remembers the forge-confirmed body of every published or draft message.
pub(crate) fn record_agreed_bodies(
    threads: &[Thread],
    agreed_bodies: &mut BTreeMap<String, String>,
) {
    for thread in threads {
        for message in &thread.messages {
            if matches!(
                message.sync,
                Some(MessageSync::Published | MessageSync::Draft)
            ) {
                agreed_bodies.insert(message.id.clone(), message.body.clone());
            }
        }
    }
}

/// Drops queued `EditMessage` ops whose target message changed on the forge
/// since the edit was queued, preserving the local text in `recoverable_body`.
pub(crate) fn reconcile_concurrent_edits(
    remote_threads: &mut [Thread],
    agreed_bodies: &mut BTreeMap<String, String>,
    ops: &mut Vec<QueuedCommentOp>,
) {
    ops.retain(|op| {
        let QueuedCommentOp::EditMessage {
            message_id, body, ..
        } = op
        else {
            return true;
        };
        let Some(remote_msg) = find_message_mut(remote_threads, message_id) else {
            return true;
        };
        let Some(agreed) = agreed_bodies.get(message_id) else {
            return true;
        };
        if &remote_msg.body == agreed {
            return true;
        }
        remote_msg.recoverable_body = Some(body.clone());
        agreed_bodies.insert(message_id.clone(), remote_msg.body.clone());
        false
    });
}

/// Re-attaches optimistic threads and messages (`Queued` or `Failed`) from
/// `local_threads` onto a freshly pulled `remote_threads` list.
pub(crate) fn merge_unflushed_threads(remote_threads: &mut Vec<Thread>, local_threads: &[Thread]) {
    let known_threads: HashSet<String> = remote_threads.iter().map(|t| t.id.clone()).collect();
    for local in local_threads {
        if !known_threads.contains(&local.id) && has_unflushed_messages(local) {
            remote_threads.push(local.clone());
            continue;
        }
        let Some(remote) = remote_threads.iter_mut().find(|t| t.id == local.id) else {
            continue;
        };
        merge_unflushed_messages(remote, &local.messages);
    }
}

fn has_unflushed_messages(thread: &Thread) -> bool {
    thread.messages.iter().any(|msg| {
        matches!(
            msg.sync,
            Some(MessageSync::Queued | MessageSync::Failed | MessageSync::Pending)
        )
    })
}

fn merge_unflushed_messages(remote: &mut Thread, local_messages: &[Message]) {
    for local_msg in local_messages {
        if let Some(existing) = remote.messages.iter_mut().find(|m| m.id == local_msg.id) {
            if existing.recoverable_body.is_none() && local_msg.recoverable_body.is_some() {
                existing.recoverable_body.clone_from(&local_msg.recoverable_body);
            }
            if matches!(local_msg.sync, Some(MessageSync::Queued | MessageSync::Failed)) {
                *existing = local_msg.clone();
            }
        } else if matches!(local_msg.sync, Some(MessageSync::Queued | MessageSync::Failed)) {
            remote.messages.push(local_msg.clone());
        }
    }
}

/// Optimistically toggles `content` in `reactions`, returning whether the
/// reaction was added (`true`) or removed (`false`).
pub(crate) fn toggle_reaction_in_list(
    reactions: &mut Vec<Reaction>,
    content: ReactionContent,
) -> bool {
    if let Some(index) = reactions.iter().position(|item| item.content == content) {
        if reactions[index].viewer_has_reacted {
            reactions[index].viewer_has_reacted = false;
            reactions[index].count = reactions[index].count.saturating_sub(1);
            if reactions[index].count == 0 {
                reactions.remove(index);
            }
            return false;
        }
        reactions[index].viewer_has_reacted = true;
        reactions[index].count += 1;
        return true;
    }
    reactions.push(Reaction {
        content,
        count: 1,
        viewer_has_reacted: true,
    });
    true
}

/// Builds the `:Jpr submit` preview from the current session threads.
#[must_use]
pub(crate) fn create_submit_preview_from_threads(
    pr_author: &str,
    viewer_login: Option<&str>,
    threads: &[Thread],
) -> SubmitPreview {
    let mut drafts = Vec::new();
    let mut blocked_reason = None;
    for thread in threads {
        for message in &thread.messages {
            match message.sync {
                Some(MessageSync::Draft) => {
                    let snippet = message
                        .body
                        .lines()
                        .map(str::trim)
                        .find(|line| !line.is_empty())
                        .unwrap_or_default()
                        .chars()
                        .take(80)
                        .collect();
                    drafts.push(SubmitDraft {
                        thread_id: thread.id.clone(),
                        message_id: message.id.clone(),
                        anchor: thread.anchor.clone(),
                        snippet,
                    });
                }
                Some(MessageSync::Pending | MessageSync::Queued) if blocked_reason.is_none() => {
                    blocked_reason = Some(
                        "one or more comments are still queued for GitHub; wait for sync first"
                            .to_owned(),
                    );
                }
                Some(MessageSync::Failed) if blocked_reason.is_none() => {
                    blocked_reason = Some(
                        "one or more comments failed to reach GitHub; retry, edit, or delete them first"
                            .to_owned(),
                    );
                }
                _ => {}
            }
        }
    }
    let is_self_review =
        !pr_author.is_empty() && viewer_login.is_some_and(|viewer| viewer == pr_author);
    SubmitPreview {
        draft_count: drafts.len(),
        drafts,
        can_approve_or_request_changes: !is_self_review,
        blocked_reason,
    }
}

pub(crate) fn find_message_mut<'a>(
    threads: &'a mut [Thread],
    message_id: &str,
) -> Option<&'a mut Message> {
    threads
        .iter_mut()
        .flat_map(|thread| thread.messages.iter_mut())
        .find(|message| message.id == message_id)
}

#[must_use]
pub(crate) fn count_code_threads(threads: &[Thread]) -> usize {
    threads
        .iter()
        .filter(|thread| thread.anchor.kind != AnchorKind::Pr)
        .count()
}
```

Update `crates/review-core/src/presenter.rs` to compute `thread_count` (`count_code_threads(threads)`), `conversation_count` (`threads.iter().filter(|t| t.anchor.kind == AnchorKind::Pr).count()`), and `draft_count` (`threads.iter().flat_map(|t| &t.messages).filter(|m| m.sync == Some(MessageSync::Draft)).count()`).

Update `ReviewSession::view` in `crates/review-core/src/session/mod.rs` to pass `self.saved.registry.queued_viewed.len() + self.saved.registry.queued_ops.len()` as `queued_count`.

- [ ] **Step 4: Run `cargo test -p review-core`**

```bash
cargo test -p review-core
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-core
git commit -m "feat(core): add comment queue reconciliation, submit preview, and session counts"
```

---

### Task 8: `ReviewSession` comment operations and offline queue replay `[HIGH-RISK]`

**Files:**
- Create: `crates/review-core/src/session/comments.rs`
- Modify: `crates/review-core/src/session/mod.rs`
- Modify: `crates/review-core/src/session/sync.rs`
- Modify: `crates/review-core/src/session/viewed.rs`

Implement `threads`, `mentions`, `comment`, `reply`, `edit_message`, `delete_message`, `set_resolved`, `toggle_reaction`, `retry_message`, and background/sync replay of `queued_ops`.

- [ ] **Step 1: Write failing session tests in `crates/review-core/src/session/comments.rs`**

Create `crates/review-core/src/session/comments.rs` with comprehensive red-first tests covering:
1. `comment` on `Anchor::line` creates a `MessageSync::Draft` thread, increments `view.draft_count`, saves to `github.json`, and publishes `Event::ThreadsChanged`.
2. `comment` on `Anchor::pr()` creates a `MessageSync::Published` conversation thread and increments `view.conversation_count`.
3. `reply` to an existing published thread publishes immediately (`MessageSync::Published`) when no pending review exists, and drafts (`MessageSync::Draft`) once a pending review exists.
4. Transient forge failure (`fakes.forge.fail_writes_with(Some("offline"))`) marks the optimistic message `MessageSync::Queued`, increments `view.queued_count`, survives a reopen (`fakes.open()`), and flushes on `flush_queued()` once online (`fail_writes_with(None)`), remapping dependent queued replies/edits from `tmp-*` to the real GitHub id.
5. Rejected forge failure (`fakes.forge.reject_writes_with(Some("Line could not be resolved"))`) marks the message `MessageSync::Failed` with `sync_error`, does NOT queue for automatic retry (`queued_count == 0`), and succeeds when `retry_message` is called after clearing the rejection.
6. Concurrent edit recovery: queuing an offline `edit_message` and then syncing a `ForgeSnapshot` where that message's body changed on GitHub keeps GitHub's body, clears the queued op, and populates `recoverable_body`.
7. `delete_message`, `set_resolved`, and `toggle_reaction` update state, persist, and announce `Event::ThreadsChanged`.

- [ ] **Step 2: Run `cargo test -p review-core` to confirm failure**

Add `mod comments;` to `crates/review-core/src/session/mod.rs` and run:

```bash
cargo test -p review-core
```

Expected: FAIL to compile (`session.comment`, `session.reply`, etc. missing).

- [ ] **Step 3: Implement `crates/review-core/src/session/comments.rs` and integrate with `sync.rs` / `viewed.rs`**

Implement the public facade methods on `ReviewSession` in `crates/review-core/src/session/comments.rs` (keeping each helper <= 45 lines):

```rust
use anyhow::{Context, Result, bail};
use review_model::{
    Anchor, AnchorKind, Event, MentionCandidate, Message, MessageSync, Origin, ReactionContent,
    SessionView, Thread, ThreadState,
};

use super::ReviewSession;
use crate::comments::{
    find_message_mut, record_agreed_bodies, remap_queued_ops, toggle_reaction_in_list,
};
use crate::ports::{ForgeWriteError, QueuedCommentOp, ReplyRequest};

impl ReviewSession {
    /// Every review thread and conversation comment currently known.
    #[must_use]
    pub fn threads(&self) -> &[Thread] {
        &self.threads
    }

    /// Cached `@mention` completion candidates, PR participants first.
    #[must_use]
    pub fn mentions(&self) -> &[MentionCandidate] {
        &self.saved.registry.mention_candidates
    }

    /// Creates a draft code thread (`File`/`Line`/`Range`) or a published PR
    /// conversation comment (`Pr`).
    pub fn comment(&mut self, anchor: Anchor, body: &str) -> Result<(Thread, SessionView)> {
        if body.trim().is_empty() {
            bail!("comment body cannot be empty");
        }
        let pr = self.synced_pr()?.clone();
        if anchor.kind == AnchorKind::Pr {
            return self.create_pr_comment(&pr, body);
        }
        self.validate_anchor_file(&anchor)?;
        self.create_code_thread(&pr, anchor, body)
    }

    /// Replies to `thread_id` (immediate via REST when no pending review is
    /// active, else added to the pending review).
    pub fn reply(&mut self, thread_id: &str, body: &str) -> Result<(Thread, SessionView)> {
        if body.trim().is_empty() {
            bail!("reply body cannot be empty");
        }
        let pr = self.synced_pr()?.clone();
        let resolved_id = self.resolve_id(thread_id);
        let root_db_id = self
            .find_thread(&resolved_id)
            .with_context(|| format!("unknown thread {thread_id}"))?
            .messages
            .first()
            .and_then(|msg| msg.database_id.clone());
        let pending_id = self.saved.registry.pending_review_id.clone();
        let request = ReplyRequest {
            thread_id: &resolved_id,
            root_database_id: root_db_id.as_deref(),
            pending_review_id: pending_id.as_deref(),
            body,
        };
        match self.ports.forge.reply_to_thread(&pr, &request) {
            Ok(message) => {
                if message.sync == Some(MessageSync::Draft) && self.saved.registry.pending_review_id.is_none() {
                    self.refresh_pending_review_id(&pr);
                }
                let thread = self.push_reply_message(&resolved_id, message)?;
                let view = self.save_and_announce_threads()?;
                Ok((thread, view))
            }
            Err(error) => self.record_failed_or_queued_reply(&resolved_id, root_db_id, body, error),
        }
    }

    /// Edits `message_id`'s body on the forge (or updates an unflushed local
    /// placeholder in place).
    pub fn edit_message(&mut self, message_id: &str, body: &str) -> Result<(Thread, SessionView)> {
        if body.trim().is_empty() {
            bail!("message body cannot be empty");
        }
        let _ = self.synced_pr()?;
        let resolved_msg_id = self.resolve_id(message_id);
        let (thread_id, anchor_kind, current_sync) = self.locate_message(&resolved_msg_id)?;
        if matches!(current_sync, Some(MessageSync::Queued | MessageSync::Failed))
            && self.update_unflushed_message_body(&resolved_msg_id, body)
        {
            let thread = self.find_thread(&thread_id).unwrap().clone();
            let view = self.save_and_announce_threads()?;
            return Ok((thread, view));
        }
        match self.ports.forge.edit_message(anchor_kind, &resolved_msg_id, body) {
            Ok(updated) => {
                self.saved
                    .registry
                    .agreed_bodies
                    .insert(updated.id.clone(), updated.body.clone());
                let thread = self.replace_message(&thread_id, &resolved_msg_id, updated)?;
                let view = self.save_and_announce_threads()?;
                Ok((thread, view))
            }
            Err(error) => self.record_failed_or_queued_edit(&thread_id, anchor_kind, &resolved_msg_id, body, error),
        }
    }

    /// Deletes `message_id` (removing its thread when it was the sole message).
    pub fn delete_message(&mut self, message_id: &str) -> Result<SessionView> {
        let _ = self.synced_pr()?;
        let resolved_msg_id = self.resolve_id(message_id);
        let (thread_id, anchor_kind, current_sync) = self.locate_message(&resolved_msg_id)?;
        if resolved_msg_id.starts_with("tmp-") || current_sync == Some(MessageSync::Failed) {
            self.drop_local_message_and_ops(&thread_id, &resolved_msg_id);
            return self.save_and_announce_threads();
        }
        match self.ports.forge.delete_message(anchor_kind, &resolved_msg_id) {
            Ok(()) => {
                self.remove_message_from_threads(&thread_id, &resolved_msg_id);
                self.save_and_announce_threads()
            }
            Err(ForgeWriteError::Transient(_)) => {
                self.remove_message_from_threads(&thread_id, &resolved_msg_id);
                self.saved.registry.queued_ops.push(QueuedCommentOp::DeleteMessage {
                    thread_id,
                    anchor_kind,
                    message_id: resolved_msg_id,
                });
                self.save_and_announce_threads()
            }
            Err(ForgeWriteError::Rejected(reason)) => bail!("{reason}"),
        }
    }

    /// Resolves (`true`) or unresolves (`false`) `thread_id`.
    pub fn set_resolved(&mut self, thread_id: &str, resolved: bool) -> Result<(Thread, SessionView)> {
        let _ = self.synced_pr()?;
        let resolved_id = self.resolve_id(thread_id);
        let target_state = if resolved { ThreadState::Resolved } else { ThreadState::Open };
        let thread = self
            .find_thread_mut(&resolved_id)
            .with_context(|| format!("unknown thread {thread_id}"))?;
        if thread.anchor.kind == AnchorKind::Pr {
            bail!("pull-request conversation comments cannot be resolved");
        }
        thread.state = target_state;
        let snapshot_thread = thread.clone();
        match self.ports.forge.set_resolved(&resolved_id, resolved) {
            Ok(()) => {}
            Err(ForgeWriteError::Transient(_)) => {
                self.saved.registry.queued_ops.push(QueuedCommentOp::SetResolved {
                    thread_id: resolved_id,
                    resolved,
                });
            }
            Err(ForgeWriteError::Rejected(reason)) => bail!("{reason}"),
        }
        let view = self.save_and_announce_threads()?;
        Ok((snapshot_thread, view))
    }

    /// Toggles `content` on `message_id` for the viewer.
    pub fn toggle_reaction(
        &mut self,
        message_id: &str,
        content: ReactionContent,
    ) -> Result<(Thread, SessionView)> {
        let _ = self.synced_pr()?;
        let resolved_msg_id = self.resolve_id(message_id);
        let (thread_id, _, _) = self.locate_message(&resolved_msg_id)?;
        let msg = find_message_mut(&mut self.threads, &resolved_msg_id)
            .context("message disappeared")?;
        let added = toggle_reaction_in_list(&mut msg.reactions, content);
        match self.ports.forge.set_reaction(&resolved_msg_id, content, added) {
            Ok(reactions) => {
                if let Some(target) = find_message_mut(&mut self.threads, &resolved_msg_id) {
                    target.reactions = reactions;
                }
            }
            Err(ForgeWriteError::Transient(_)) => {
                self.saved.registry.queued_ops.push(QueuedCommentOp::SetReaction {
                    subject_id: resolved_msg_id,
                    content,
                    added,
                });
            }
            Err(ForgeWriteError::Rejected(reason)) => bail!("{reason}"),
        }
        let thread = self.find_thread(&thread_id).unwrap().clone();
        let view = self.save_and_announce_threads()?;
        Ok((thread, view))
    }

    /// Re-queues a `MessageSync::Failed` message and immediately attempts to
    /// flush the queue.
    pub fn retry_message(&mut self, message_id: &str) -> Result<SessionView> {
        let _ = self.synced_pr()?;
        let resolved_msg_id = self.resolve_id(message_id);
        self.enqueue_failed_message(&resolved_msg_id)?;
        let _ = self.send_queued_comments();
        self.save_and_announce_threads()
    }
}
```

Add the private helpers in `crates/review-core/src/session/comments.rs` (each <= 40 lines):
- `allocate_temp_id(&mut self, prefix: &str) -> String` incrementing `self.saved.registry.next_temp_id`.
- `resolve_id(&self, id: &str) -> String` following `self.saved.registry.id_map`.
- `create_code_thread` and `create_pr_comment` calling `forge.create_review_thread` / `forge.create_conversation_comment`, recording `agreed_bodies`, updating `pending_review_id`, or creating optimistic `Queued` / `Failed` threads (`viewer_login` defaulting to `"you"`).
- `send_queued_comments(&mut self) -> bool` replaying `self.saved.registry.queued_ops` in FIFO order:
  - Stops on `ForgeWriteError::Transient` so later dependent ops stay ordered.
  - Converts `ForgeWriteError::Rejected(reason)` on the failing op's message into `MessageSync::Failed` + `sync_error: Some(reason)` and removes that op from `queued_ops` so it does not block unrelated items behind it.
  - Records `(temp_id -> real_id)` in `self.saved.registry.id_map` and calls `remap_queued_ops` whenever `CreateReviewThread`, `CreateConversationComment`, or `ReplyToThread` lands.
- `save_and_announce_threads(&mut self) -> Result<SessionView>` syncing `self.saved.registry.threads = self.threads.clone()`, calling `record_agreed_bodies(&self.threads, &mut self.saved.registry.agreed_bodies)`, saving via `self.ports.store.save(&self.saved)?`, and publishing `Event::ThreadsChanged { view: Box::new(view.clone()) }`.

Update `crates/review-core/src/session/viewed.rs` and `sync.rs`:
- `has_queued(&self)` returns `!self.saved.registry.queued_viewed.is_empty() || !self.saved.registry.queued_ops.is_empty()`.
- `flush_queued(&mut self)` calls both `self.send_queued()` and `self.send_queued_comments()`, saving and publishing `ViewedChanged` / `ThreadsChanged` for whichever landed.
- `sync(&mut self)` in `session/sync.rs`:
  1. Flushes `send_queued()` (viewed marks).
  2. Pulls `(pr, mut snapshot)` via `self.pull()?`.
  3. Runs `reconcile_concurrent_edits(&mut snapshot.threads, &mut self.saved.registry.agreed_bodies, &mut self.saved.registry.queued_ops)` BEFORE replaying `queued_ops` so concurrent GitHub edits win and save `recoverable_body` instead of being overwritten!
  4. Updates `self.saved.session.pr = Some(pr)`, `pending_review_id`, `viewer_login`, and `mention_candidates`, sets `self.threads = snapshot.threads` merged with unflushed local threads (`merge_unflushed_threads`), then runs `self.send_queued_comments()` so non-conflicting queued ops flush right away, records `agreed_bodies`, saves `self.saved`, and publishes `Event::Synced`.

- [ ] **Step 4: Run workspace tests**

```bash
cargo test --workspace --all-features
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-core
git commit -m "feat(core): implement comment, reply, edit, delete, resolve, react, and queue replay"
```

---

### Task 9: `ReviewSession::suggest_from_edit`, `anchored_lines`, `submit_preview`, and `submit_review`

**Files:**
- Create: `crates/review-core/src/session/submit.rs`
- Modify: `crates/review-core/src/session/mod.rs`
- Modify: `crates/review-core/src/session/diffs.rs`

Wire `:Jpr suggest`, suggestion-fence line lookup (`anchored_lines`), and `:Jpr submit` (`submit_preview` + `submit_review`) on `ReviewSession`.

- [ ] **Step 1: Write failing tests in `crates/review-core/src/session/submit.rs`**

Create `crates/review-core/src/session/submit.rs` with tests first:

```rust
//! Turning local edits into GitHub suggestion drafts, reading anchored code,
//! and submitting reviews.

#[cfg(test)]
mod tests {
    use review_model::{Anchor, MessageSync, ReviewEvent, Side};

    use super::super::test_support::Fakes;

    #[test]
    fn suggest_from_edit_diffs_against_head_commit_creates_draft_and_returns_reverted_text() {
        let fakes = Fakes::new(100);
        fakes.workspace.put_at("abc123", "src/a.rs", "let a = 1;\nlet b = 2;\n");
        let mut session = fakes.open_synced();

        let (suggested, thread, view) = session
            .suggest_from_edit("src/a.rs", "let a = 10;\nlet b = 2;\n", 1, Some("Use 10:"))
            .unwrap();
        assert_eq!(suggested.reverted_text, "let a = 1;\nlet b = 2;\n");
        assert!(thread.messages[0].body.contains("Use 10:\n\n```suggestion\nlet a = 10;\n```"));
        assert_eq!(view.draft_count, 1);
    }

    #[test]
    fn anchored_lines_reads_left_from_merge_base_and_right_from_disk() {
        let fakes = Fakes::new(100);
        fakes.workspace.put_base("src/a.rs", "old_1\nold_2\n");
        fakes.workspace.put_disk("src/a.rs", "new_1\nnew_2\n");
        let mut session = fakes.open_synced();

        let left = session
            .anchored_lines(&Anchor::range("src/a.rs", Side::Left, 1, 2))
            .unwrap();
        let right = session
            .anchored_lines(&Anchor::side_line("src/a.rs", Side::Right, 2))
            .unwrap();
        assert_eq!(left, "old_1\nold_2");
        assert_eq!(right, "new_2");
    }

    #[test]
    fn submit_review_publishes_all_drafts_and_blocks_self_approval() {
        let fakes = Fakes::new(100);
        let mut snap = super::super::test_support::create_snapshot();
        snap.viewer_login = Some("alice".into()); // sample_pr().author == "alice"
        fakes.forge.set_snapshot(snap);
        let mut session = fakes.open_synced();
        session
            .comment(Anchor::line("src/a.rs", 1), "draft note")
            .unwrap();

        let preview = session.submit_preview().unwrap();
        assert_eq!(preview.draft_count, 1);
        assert!(!preview.can_approve_or_request_changes);
        assert!(
            session
                .submit_review(ReviewEvent::Approve, "")
                .unwrap_err()
                .to_string()
                .contains("own pull request")
        );

        let view = session.submit_review(ReviewEvent::Comment, "overall summary").unwrap();
        assert_eq!(view.draft_count, 0);
        assert_eq!(session.threads().last().unwrap().messages[0].sync, Some(MessageSync::Published));
    }
}
```

- [ ] **Step 2: Run `cargo test -p review-core` to confirm failure**

Add `mod submit;` to `crates/review-core/src/session/mod.rs` (and expose `pub(super) fn file_texts` in `session/diffs.rs`), then run:

```bash
cargo test -p review-core
```

Expected: FAIL to compile (`suggest_from_edit`, `anchored_lines`, `submit_preview`, `submit_review` missing).

- [ ] **Step 3: Implement `crates/review-core/src/session/submit.rs`**

Put this above `#[cfg(test)]` in `crates/review-core/src/session/submit.rs`:

```rust
use anyhow::{Context, Result, bail};
use review_diff::{FileText, create_suggestion_from_edit};
use review_model::{
    Anchor, AnchorKind, MessageSync, ReviewEvent, SessionView, Side, SubmitPreview, SuggestedEdit,
    Thread,
};

use super::ReviewSession;
use crate::comments::create_submit_preview_from_threads;
use crate::ports::{ForgeWriteError, QueuedCommentOp};

impl ReviewSession {
    /// Reads the exact lines covered by `anchor` (`Left` from the merge base,
    /// `Right` from disk) so a suggestion fence can prefill them.
    pub fn anchored_lines(&mut self, anchor: &Anchor) -> Result<String> {
        let path = anchor
            .file
            .as_deref()
            .context("anchor has no file path")?;
        if !matches!(anchor.kind, AnchorKind::Line | AnchorKind::Range) {
            bail!("only line and range anchors have anchored code lines");
        }
        let (base, current) = self.file_texts(path)?;
        let source = match anchor.side {
            Side::Left => &base,
            Side::Right => &current,
        };
        let lines = source.lines();
        let start = usize::try_from(anchor.start.unwrap_or(1).saturating_sub(1))?;
        let end = usize::try_from(anchor.end.unwrap_or(1))?.min(lines.len());
        if start >= end || start >= lines.len() {
            return Ok(String::new());
        }
        Ok(lines[start..end].join("\n"))
    }

    /// Turns the uncommitted edit around 1-based `cursor_line` of `edited_text`
    /// (measured against `pr.head_sha`) into a draft suggestion thread and
    /// returns the reverted text for that hunk.
    pub fn suggest_from_edit(
        &mut self,
        path: &str,
        edited_text: &str,
        cursor_line: u64,
        comment_body: Option<&str>,
    ) -> Result<(SuggestedEdit, Thread, SessionView)> {
        let pr = self.synced_pr()?.clone();
        if !self.saved.files.iter().any(|file| file.path == path) {
            bail!("{path} is not a file this pull request changes");
        }
        let head_bytes = self
            .ports
            .workspace
            .file_at(&pr.head_sha, path)?
            .with_context(|| format!("{path} does not exist at head commit {}", pr.head_sha))?;
        let head_text = FileText::from_bytes(Some(head_bytes));
        let head_str = head_text
            .as_text()
            .with_context(|| format!("{path} is binary and cannot take a suggestion"))?;
        let suggested = create_suggestion_from_edit(path, head_str, edited_text, cursor_line)
            .context("no uncommitted edit at the cursor line")?;
        let full_body = match comment_body.map(str::trim).filter(|text| !text.is_empty()) {
            Some(prefix) => format!("{prefix}\n\n{}", suggested.suggestion_body),
            None => suggested.suggestion_body.clone(),
        };
        let (thread, view) = self.comment(suggested.anchor.clone(), &full_body)?;
        Ok((suggested, thread, view))
    }

    /// Preview of pending draft comments and allowed review actions.
    pub fn submit_preview(&self) -> Result<SubmitPreview> {
        let pr = self.synced_pr()?;
        Ok(create_submit_preview_from_threads(
            &pr.author,
            self.saved.registry.viewer_login.as_deref(),
            &self.threads,
        ))
    }

    /// Submits the pending review (or a zero-draft review) with `event` and `body`.
    pub fn submit_review(&mut self, event: ReviewEvent, body: &str) -> Result<SessionView> {
        let pr = self.synced_pr()?.clone();
        let preview = self.submit_preview()?;
        if let Some(reason) = preview.blocked_reason {
            bail!("{reason}");
        }
        if !preview.can_approve_or_request_changes && event != ReviewEvent::Comment {
            bail!("GitHub does not allow approving or requesting changes on your own pull request");
        }
        if event == ReviewEvent::Comment && preview.draft_count == 0 && body.trim().is_empty() {
            bail!("a comment review with zero drafts needs a summary body");
        }
        let pending_id = self.saved.registry.pending_review_id.clone();
        match self
            .ports
            .forge
            .submit_review(&pr, pending_id.as_deref(), event, body)
        {
            Ok(()) => {
                self.mark_drafts_published();
                self.saved.registry.pending_review_id = None;
                self.save_and_announce_threads()
            }
            Err(ForgeWriteError::Transient(_)) => {
                self.saved
                    .registry
                    .queued_ops
                    .push(QueuedCommentOp::SubmitReview {
                        event,
                        body: body.to_owned(),
                    });
                self.save_and_announce_threads()
            }
            Err(ForgeWriteError::Rejected(reason)) => bail!("{reason}"),
        }
    }

    pub(super) fn mark_drafts_published(&mut self) {
        for thread in &mut self.threads {
            for message in &mut thread.messages {
                if message.sync == Some(MessageSync::Draft) {
                    message.sync = Some(MessageSync::Published);
                }
            }
        }
    }
}
```

Also handle `QueuedCommentOp::SubmitReview { event, body }` inside `send_queued_comments` in `crates/review-core/src/session/comments.rs` by calling `self.ports.forge.submit_review(&pr, pending_id.as_deref(), event, &body)` and calling `self.mark_drafts_published()` + clearing `pending_review_id` when it succeeds.

- [ ] **Step 4: Run workspace tests**

```bash
cargo test --workspace --all-features
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-core
git commit -m "feat(core): add suggest_from_edit, anchored_lines, submit_preview, and submit_review"
```

---

### Task 10: JSON-RPC protocol v3 (`review-rpc`)

**Files:**
- Modify: `crates/review-rpc/src/protocol.rs`
- Modify: `crates/review-rpc/src/params.rs`
- Modify: `crates/review-rpc/src/server.rs`
- Modify: `crates/review-rpc/tests/serve.rs`

Bump `PROTOCOL_VERSION` to `3` and route all 13 new M3 methods (`threads`, `mentions`, `comment`, `reply`, `editMessage`, `deleteMessage`, `setResolved`, `toggleReaction`, `retryMessage`, `anchoredLines`, `suggestFromEdit`, `submitPreview`, `submitReview`) plus automatic `threadsChanged` notification streaming.

- [ ] **Step 1: Write failing RPC parameter and server integration tests**

Add tests to `crates/review-rpc/src/params.rs`:

```rust
    #[test]
    fn parses_anchor_reaction_and_review_event_params() {
        let anchor_params = json!({
            "anchor": { "file": "src/a.rs", "kind": "range", "side": "LEFT", "start": 2, "end": 5 },
            "body": "nit"
        });
        let anchor = get_anchor_from_params(&anchor_params).unwrap();
        assert_eq!(anchor.kind, review_model::AnchorKind::Range);
        assert_eq!(anchor.side, review_model::Side::Left);

        let react = json!({ "messageId": "C1", "content": "THUMBS_UP" });
        assert_eq!(
            get_reaction_from_params(&react).unwrap(),
            review_model::ReactionContent::ThumbsUp
        );

        let submit = json!({ "event": "APPROVE", "body": "ship it" });
        assert_eq!(
            get_review_event_from_params(&submit).unwrap(),
            review_model::ReviewEvent::Approve
        );
    }
```

Add an integration test in `crates/review-rpc/tests/serve.rs` verifying:
1. `initialize` reports `"protocolVersion": 3`.
2. `comment`, `reply`, `editMessage`, `setResolved`, `toggleReaction`, `threads`, `mentions`, `anchoredLines`, `suggestFromEdit`, `submitPreview`, and `submitReview` round-trip over JSON-RPC and emit `"type": "threadsChanged"` notifications before each response.

- [ ] **Step 2: Run `cargo test -p review-rpc` to confirm failure**

```bash
cargo test -p review-rpc
```

Expected: FAIL (`get_anchor_from_params` missing, `PROTOCOL_VERSION` still `2`).

- [ ] **Step 3: Implement `params.rs` parsers and `server.rs` routing**

In `crates/review-rpc/src/protocol.rs`, set `pub const PROTOCOL_VERSION: u32 = 3;`.

In `crates/review-rpc/src/params.rs`, add typed readers:

```rust
use review_model::{Anchor, ReactionContent, ReviewEvent, ViewMode};

pub fn get_optional_string_from_params<'a>(
    params: &'a Value,
    name: &str,
) -> Result<Option<&'a str>, RpcError> {
    match params.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value.as_str().map(Some).ok_or_else(|| {
            create_invalid_params_error(&format!("expected \"{name}\" to be a string or null"))
        }),
    }
}

pub fn get_u64_from_params(params: &Value, name: &str) -> Result<u64, RpcError> {
    params
        .get(name)
        .and_then(Value::as_u64)
        .ok_or_else(|| create_invalid_params_error(&format!("expected an integer \"{name}\"")))
}

pub fn get_anchor_from_params(params: &Value) -> Result<Anchor, RpcError> {
    let raw = params
        .get("anchor")
        .cloned()
        .ok_or_else(|| create_invalid_params_error("expected an \"anchor\" object"))?;
    serde_json::from_value(raw)
        .map_err(|error| create_invalid_params_error(&format!("invalid \"anchor\": {error}")))
}

pub fn get_reaction_from_params(params: &Value) -> Result<ReactionContent, RpcError> {
    let raw = get_string_from_params(params, "content")?;
    ReactionContent::parse(raw)
        .ok_or_else(|| create_invalid_params_error(&format!("unknown reaction \"{raw}\"")))
}

pub fn get_review_event_from_params(params: &Value) -> Result<ReviewEvent, RpcError> {
    let raw = get_string_from_params(params, "event")?;
    ReviewEvent::parse(raw)
        .ok_or_else(|| create_invalid_params_error(&format!("unknown review event \"{raw}\"")))
}
```

In `crates/review-rpc/src/server.rs`, keep `handle` under 45 lines by delegating comment/review methods to `handle_comment_method`:

```rust
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
        "sync" => to_value(&engine_result_to_rpc(lock(session)?.sync())?),
        "fileDiff" => {
            let path = get_string_from_params(params, "path")?;
            to_value(&engine_result_to_rpc(lock(session)?.file_diff(path))?)
        }
        "stream" => {
            let mode = get_mode_from_params(params)?;
            to_value(&engine_result_to_rpc(lock(session)?.stream(mode))?)
        }
        "setViewed" => {
            let (path, viewed) = (
                get_string_from_params(params, "path")?,
                get_bool_from_params(params, "viewed")?,
            );
            to_value(&engine_result_to_rpc(
                lock(session)?.set_viewed(path, viewed),
            )?)
        }
        "shutdown" => Ok(Value::Null),
        other => handle_comment_method(session, other, params),
    }
}

fn handle_comment_method(
    session: &Mutex<ReviewSession>,
    method: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    match method {
        "threads" => to_value(&json!({ "threads": lock(session)?.threads() })),
        "mentions" => to_value(&json!({ "candidates": lock(session)?.mentions() })),
        "comment" => {
            let (anchor, body) = (
                get_anchor_from_params(params)?,
                get_string_from_params(params, "body")?,
            );
            let (thread, view) = engine_result_to_rpc(lock(session)?.comment(anchor, body))?;
            Ok(json!({ "thread": thread, "view": view }))
        }
        "reply" => {
            let (thread_id, body) = (
                get_string_from_params(params, "threadId")?,
                get_string_from_params(params, "body")?,
            );
            let (thread, view) = engine_result_to_rpc(lock(session)?.reply(thread_id, body))?;
            Ok(json!({ "thread": thread, "view": view }))
        }
        "editMessage" => {
            let (message_id, body) = (
                get_string_from_params(params, "messageId")?,
                get_string_from_params(params, "body")?,
            );
            let (thread, view) =
                engine_result_to_rpc(lock(session)?.edit_message(message_id, body))?;
            Ok(json!({ "thread": thread, "view": view }))
        }
        "deleteMessage" => {
            let message_id = get_string_from_params(params, "messageId")?;
            to_value(&engine_result_to_rpc(lock(session)?.delete_message(message_id))?)
        }
        "setResolved" => {
            let (thread_id, resolved) = (
                get_string_from_params(params, "threadId")?,
                get_bool_from_params(params, "resolved")?,
            );
            let (thread, view) =
                engine_result_to_rpc(lock(session)?.set_resolved(thread_id, resolved))?;
            Ok(json!({ "thread": thread, "view": view }))
        }
        "toggleReaction" => handle_reaction_and_review_method(session, method, params),
        _ => handle_reaction_and_review_method(session, method, params),
    }
}

fn handle_reaction_and_review_method(
    session: &Mutex<ReviewSession>,
    method: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    match method {
        "toggleReaction" => {
            let (message_id, content) = (
                get_string_from_params(params, "messageId")?,
                get_reaction_from_params(params)?,
            );
            let (thread, view) =
                engine_result_to_rpc(lock(session)?.toggle_reaction(message_id, content))?;
            Ok(json!({ "thread": thread, "view": view }))
        }
        "retryMessage" => {
            let message_id = get_string_from_params(params, "messageId")?;
            to_value(&engine_result_to_rpc(lock(session)?.retry_message(message_id))?)
        }
        "anchoredLines" => {
            let anchor = get_anchor_from_params(params)?;
            let text = engine_result_to_rpc(lock(session)?.anchored_lines(&anchor))?;
            Ok(json!({ "text": text }))
        }
        "suggestFromEdit" => {
            let path = get_string_from_params(params, "path")?;
            let edited_text = get_string_from_params(params, "editedText")?;
            let cursor_line = get_u64_from_params(params, "cursorLine")?;
            let comment_body = get_optional_string_from_params(params, "commentBody")?;
            let (suggested, thread, view) = engine_result_to_rpc(
                lock(session)?.suggest_from_edit(path, edited_text, cursor_line, comment_body),
            )?;
            Ok(json!({ "suggested": suggested, "thread": thread, "view": view }))
        }
        "submitPreview" => to_value(&engine_result_to_rpc(lock(session)?.submit_preview())?),
        "submitReview" => {
            let event = get_review_event_from_params(params)?;
            let body = get_optional_string_from_params(params, "body")?.unwrap_or_default();
            to_value(&engine_result_to_rpc(lock(session)?.submit_review(event, body))?)
        }
        other => Err(RpcError::new(
            RpcError::METHOD_NOT_FOUND,
            format!("unknown method {other:?}"),
        )),
    }
}
```

Update any protocol-version assertions in `crates/review-rpc/tests/serve.rs` from `2` to `3`.

- [ ] **Step 4: Run `cargo test -p review-rpc`**

```bash
cargo test -p review-rpc
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-rpc
git commit -m "feat(rpc): bump protocol to v3 and route comment, suggestion, and submit methods"
```

---

### Task 11: Lua protocol v3, `<Plug>` mappings, configurable keys, highlights, and `:Jpr` subcommands

**Files:**
- Modify: `plugin/jpr.lua`
- Modify: `lua/jpr/rpc.lua`
- Modify: `lua/jpr/init.lua`
- Modify: `lua/jpr/session.lua`
- Modify: `tests/lua/fixtures/fake_engine.sh`
- Modify: `tests/lua/command_spec.lua`
- Modify: `tests/lua/rpc_spec.lua`

Bring the Neovim client up to protocol v3, define thread highlight groups, add `<Plug>(jpr-...)` mappings and `setup({ keys = ... })`, support `:Jpr` visual ranges (`:'<,'>Jpr comment`), and route `threadsChanged` notifications.

- [ ] **Step 1: Write failing Lua assertions in `command_spec.lua` and `rpc_spec.lua`**

Update `tests/lua/command_spec.lua` to assert:
1. `jpr.complete("", "Jpr ")` returns `{ "open", "sync", "toggle", "stream", "comment", "suggest", "expand", "conversation", "submit", "close" }`.
2. `jpr.complete("c", "Jpr c")` returns `{ "comment", "conversation", "close" }`.
3. `:'<,'>Jpr comment` passes `{ line1 = ..., line2 = ..., range = 2 }` to `jpr.command` without raising `E481: No range allowed`.
4. `jpr.defaults.keys` holds default bindings (`comment = "gc"`, `suggest_comment = "gC"`, `file_comment = "gf"`, `thread_popup = "gt"`, `next_thread = "]t"`, `prev_thread = "[t"`), and `jpr.setup({ keys = { comment = false } })` disables an individual key while `<Plug>(jpr-comment)` remains defined.
5. `rpc.PROTOCOL_VERSION == 3` in `tests/lua/rpc_spec.lua`.

- [ ] **Step 2: Run `just test-lua` to confirm failure**

```bash
just test-lua
```

Expected: FAIL (`command_spec.lua` subcommand list and range fail; `rpc_spec.lua` protocol version fails).

- [ ] **Step 3: Update `plugin/jpr.lua`, `rpc.lua`, `init.lua`, `session.lua`, and `fake_engine.sh`**

In `lua/jpr/rpc.lua`, set `M.PROTOCOL_VERSION = 3`.

In `plugin/jpr.lua`, allow ranges on `:Jpr` and register `<Plug>` mappings in normal and visual modes:

```lua
if vim.g.loaded_jpr then
    return
end
vim.g.loaded_jpr = true

vim.api.nvim_create_user_command("Jpr", function(opts)
    require("jpr").command(opts.fargs, opts)
end, {
    nargs = "+",
    range = true,
    desc = "Review a GitHub pull request",
    complete = function(arglead, cmdline)
        return require("jpr").complete(arglead, cmdline)
    end,
})

vim.keymap.set({ "n", "x" }, "<Plug>(jpr-comment)", function()
    require("jpr").action("comment")
end, { desc = "New GitHub draft comment on line or visual range" })
vim.keymap.set({ "n", "x" }, "<Plug>(jpr-suggest-comment)", function()
    require("jpr").action("suggest_comment")
end, { desc = "New GitHub draft comment pre-filled with a suggestion block" })
vim.keymap.set("n", "<Plug>(jpr-file-comment)", function()
    require("jpr").action("file_comment")
end, { desc = "New file-level GitHub draft comment" })
vim.keymap.set("n", "<Plug>(jpr-thread-popup)", function()
    require("jpr").action("thread_popup")
end, { desc = "Open the review thread popup on the cursor line" })
vim.keymap.set("n", "<Plug>(jpr-next-thread)", function()
    require("jpr").action("next_thread")
end, { desc = "Jump to the next review thread in the buffer" })
vim.keymap.set("n", "<Plug>(jpr-prev-thread)", function()
    require("jpr").action("prev_thread")
end, { desc = "Jump to the previous review thread in the buffer" })
```

In `lua/jpr/init.lua`:
- Add `keys` to `M.defaults`:

```lua
    keys = {
        comment = "gc",
        suggest_comment = "gC",
        file_comment = "gf",
        thread_popup = "gt",
        next_thread = "]t",
        prev_thread = "[t",
    },
```

- Expand `M.subcommands`:

```lua
M.subcommands = {
    "open",
    "sync",
    "toggle",
    "stream",
    "comment",
    "suggest",
    "expand",
    "conversation",
    "submit",
    "close",
}
```

- Add highlight links in `M.define_highlights()`:

```lua
        JprThreadPublished = "DiagnosticInfo",
        JprThreadDraft = "DiagnosticWarn",
        JprThreadFailed = "DiagnosticError",
        JprThreadResolved = "Comment",
        JprReactionActive = "DiagnosticOk",
        JprAuthor = "Identifier",
```

- Add `M.bind_buffer_keys(buf)` so diff and stream buffers bind the configured keys to `<Plug>(jpr-...)` (skipping any key set to `false`):

```lua
function M.bind_buffer_keys(buf)
    local keys = M.config.keys or {}
    local map = function(modes, lhs, plug, desc)
        if lhs and lhs ~= false then
            vim.keymap.set(modes, lhs, plug, { buffer = buf, remap = true, silent = true, desc = desc })
        end
    end
    map({ "n", "x" }, keys.comment, "<Plug>(jpr-comment)", "New GitHub draft comment")
    map({ "n", "x" }, keys.suggest_comment, "<Plug>(jpr-suggest-comment)", "New GitHub suggestion comment")
    map("n", keys.file_comment, "<Plug>(jpr-file-comment)", "New file-level GitHub comment")
    map("n", keys.thread_popup, "<Plug>(jpr-thread-popup)", "Open review thread popup")
    map("n", keys.next_thread, "<Plug>(jpr-next-thread)", "Next review thread")
    map("n", keys.prev_thread, "<Plug>(jpr-prev-thread)", "Previous review thread")
end
```

- Route the new subcommands in `M.command(fargs, cmd_opts)` and `M.action(name)` to `require("jpr.session")` (`comment_current`, `suggest_current`, `expand_current`, `conversation_current`, `submit_current`, `popup_current`, `jump_thread_current`).

In `lua/jpr/session.lua`:
- Update `M.on_notification` so `params.type == "threadsChanged"` also calls `M.show(session, params.view)` (and notifies `require("jpr.views.conversation").refresh(session)` when loaded).
- In `forget(session, close_tab)`, close any open conversation, popup, compose, or submit views if their modules are loaded (`package.loaded["jpr.views.conversation"]`, etc.).

In `tests/lua/fixtures/fake_engine.sh`:
- Change `${FAKE_ENGINE_PROTOCOL:-2}` to `${FAKE_ENGINE_PROTOCOL:-3}`.
- Include `"draftCount":0,"conversationCount":1` in `view_synced` / `view_viewed`, `"threads":[...]` on `file_diff`, and canned responses for `threads`, `mentions`, `comment`, `reply`, `editMessage`, `deleteMessage`, `setResolved`, `toggleReaction`, `retryMessage`, `anchoredLines`, `suggestFromEdit`, `submitPreview`, and `submitReview`.

- [ ] **Step 4: Run `just test-lua`**

```bash
just test-lua
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add plugin lua tests/lua
git commit -m "feat(nvim): bump protocol to v3 and add comment keymaps, highlights, and subcommands"
```

---

### Task 12: Panel `Conversation` item and `drafts N` count

**Files:**
- Modify: `lua/jpr/render/panel.lua`
- Modify: `lua/jpr/views/panel.lua`
- Modify: `tests/lua/panel_render_spec.lua`
- Modify: `tests/lua/panel_view_spec.lua`
- Modify: `tests/lua/session_spec.lua`
- Modify: `tests/lua/untrusted_text_spec.lua`

Show `drafts N` in the panel's counts line when `draftCount > 0`, and render a dedicated `Conversation` entry (`  💬 Conversation` or `  💬 Conversation [N]`) at line 5 right above the file tree so `<CR>` opens the PR conversation view. Because adding line 5 shifts file tree lines down by +1, update all four panel-line specs in the same commit.

- [ ] **Step 1: Update `panel_render_spec.lua`, `panel_view_spec.lua`, `session_spec.lua`, and `untrusted_text_spec.lua` with red assertions**

In `tests/lua/panel_render_spec.lua`:
- Add `draftCount = 1, conversationCount = 2` to `view` and assert:
  - Line 2 is `"viewed 1/3 · threads 2 · drafts 1"`.
  - Line 5 is `"  💬 Conversation [2]"` with `built.conversation_line == 5`.
  - `built.paths` keys shift by +1 (`7 -> "docs/x.md"`, `9 -> "src/a.rs"`, `10 -> "src/b.rs"`), and `multi_line.lines[6] == "  new line.md  +3 -1"`, `multi_line.paths[6] == "new\nline.md"`.
- Assert that when `draftCount == 0` and `conversationCount == 0`, line 2 omits `drafts` and line 5 is `"  💬 Conversation"`.

In `tests/lua/panel_view_spec.lua`, `tests/lua/session_spec.lua`, and `tests/lua/untrusted_text_spec.lua`:
- Shift file-row cursor lines by +1 (`5 -> 6`, `{ 5, 6 } -> { 6, 7 }`, `4 + index -> 5 + index`), and add a test in `panel_view_spec.lua` pressing `<CR>` on line 5 verifying it invokes the conversation opener instead of `main_window.edit`.

- [ ] **Step 2: Run `just test-lua` to confirm failure**

```bash
just test-lua
```

Expected: FAIL (`panel_render_spec.lua` missing `Conversation` row and `drafts 1`).

- [ ] **Step 3: Implement `Conversation` and `drafts N` in `render/panel.lua` and `views/panel.lua`**

In `lua/jpr/render/panel.lua`:

```lua
function M.build_counts_text(view)
    local text = ("viewed %d/%d \u{00b7} threads %d"):format(view.viewedCount or 0, #(view.files or {}), view.threadCount or 0)
    if (view.draftCount or 0) > 0 then
        text = text .. (" \u{00b7} drafts %d"):format(view.draftCount)
    end
    if (view.queuedCount or 0) > 0 then
        text = text .. (" \u{00b7} %d waiting for GitHub"):format(view.queuedCount)
    end
    return text
end
```

And in `M.build(view, now)` right after `content.add_line("")`:

```lua
    local conv_count = view.conversationCount or 0
    local conv_suffix = conv_count > 0 and (" [%d]"):format(conv_count) or ""
    content.add_line("  \u{1f4ac} Conversation" .. conv_suffix, "JprTitle")
    local conversation_line = #content.lines
```

Return `{ lines = content.lines, highlights = content.highlights, paths = content.paths, conversation_line = conversation_line }`.

In `lua/jpr/views/panel.lua`:
- Save `panel.conversation_line = built.conversation_line` in `M.render`.
- In `M.open_file_under_cursor(session)`:

```lua
function M.open_file_under_cursor(session)
    local panel = session.panel
    local cursor_line = vim.api.nvim_win_get_cursor(panel.win)[1]
    if cursor_line == panel.conversation_line then
        return require("jpr.session").conversation_current()
    end
    local path = panel.paths[cursor_line]
    if not path then
        return
    end
    local main_window = require("jpr.views.main_window")
    main_window.edit(session, main_window.find(session), path)
end
```

- [ ] **Step 4: Run `just test-lua`**

```bash
just test-lua
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add lua tests/lua
git commit -m "feat(nvim): show Conversation row and draft count in the PR panel"
```

---

### Task 13: Pure thread renderer (`lua/jpr/render/threads.lua`)

**Files:**
- Create: `lua/jpr/render/threads.lua`
- Create: `tests/lua/threads_render_spec.lua`

Keep sign selection, EOL preview virtual text, inline expanded virtual-line blocks, reaction pills, and popup buffer lines pure in `lua/jpr/render/threads.lua`.

- [ ] **Step 1: Write `tests/lua/threads_render_spec.lua`**

Create `tests/lua/threads_render_spec.lua`:

```lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local render = require("jpr.render.threads")

local draft_thread = {
    threadId = "T1",
    displayLine = 4,
    kind = "draft",
    state = "open",
    outdated = false,
    messageCount = 2,
    firstAuthor = "pablo",
    snippet = "consider splitting this helper",
    messages = {
        {
            id = "M1",
            author = "pablo",
            body = "consider splitting this helper",
            created = "2026-11-20T01:00:00Z",
            updated = "2026-11-20T01:00:00Z",
            sync = "draft",
            viewerDidAuthor = true,
            reactions = { { content = "THUMBS_UP", count = 2, viewerHasReacted = true } },
        },
        {
            id = "M2",
            author = "alice",
            body = "good catch\nwill do",
            created = "2026-11-20T01:05:00Z",
            updated = "2026-11-20T01:05:00Z",
            sync = "published",
            viewerDidAuthor = false,
            reactions = {},
        },
    },
}

local sign_text, sign_hl = render.pick_sign({ draft_thread })
assert(sign_text == "✎" and sign_hl == "JprThreadDraft", sign_text .. " " .. sign_hl)

local resolved_thread = vim.tbl_extend("force", vim.deepcopy(draft_thread), { kind = "published", state = "resolved" })
local res_sign, res_hl = render.pick_sign({ resolved_thread })
assert(res_sign == "✓" and res_hl == "JprThreadResolved", res_sign .. " " .. res_hl)

local eol = render.build_eol_chunks({ draft_thread })
assert(eol[1][1]:find("@pablo", 1, true) and eol[1][1]:find("(+1)", 1, true), vim.inspect(eol))

local marks = render.create_extmarks_from_threads({ draft_thread }, 10, { expanded = false })
assert(#marks == 1 and marks[1].line == 3 and marks[1].opts.sign_text == "✎", vim.inspect(marks))

local expanded = render.create_extmarks_from_threads({ draft_thread }, 10, { expanded = true })
assert(#expanded == 2 and expanded[2].opts.virt_lines ~= nil, vim.inspect(expanded))

local popup = render.build_popup({ draft_thread })
assert(#popup.message_ranges == 2, vim.inspect(popup))
assert(popup.message_ranges[1].message_id == "M1" and popup.message_ranges[2].message_id == "M2", vim.inspect(popup))
assert(table.concat(popup.lines, "\n"):find("👍 2*", 1, true) ~= nil, vim.inspect(popup.lines))

print("threads_render_spec: ok")
```

- [ ] **Step 2: Run `just test-lua` to confirm failure**

```bash
just test-lua
```

Expected: FAIL (`module 'jpr.render.threads' not found`).

- [ ] **Step 3: Implement `lua/jpr/render/threads.lua`**

Create `lua/jpr/render/threads.lua`:

```lua
-- Pure: turns ThreadPreview lists into sign + EOL extmarks, expanded virtual
-- lines, reaction pills, and popup buffer layouts. No windows or buffers here.
local one_line = require("jpr.render.panel").one_line

local M = {}

M.REACTION_EMOJI = {
    THUMBS_UP = "👍",
    THUMBS_DOWN = "👎",
    LAUGH = "😄",
    HOORAY = "🎉",
    CONFUSED = "😕",
    HEART = "❤️",
    ROCKET = "🚀",
    EYES = "👀",
}

M.REACTION_ORDER = {
    "THUMBS_UP",
    "THUMBS_DOWN",
    "LAUGH",
    "HOORAY",
    "CONFUSED",
    "HEART",
    "ROCKET",
    "EYES",
}

local SYNC_BADGE = {
    draft = "[draft]",
    queued = "[queued]",
    pending = "[sending]",
    failed = "[failed]",
}

--- Picks the highest-priority sign character and highlight group for `threads`
--- on the same line: failed > draft > open published > resolved.
function M.pick_sign(threads)
    local has_draft, has_open = false, false
    for _, thread in ipairs(threads) do
        if thread.kind == "failed" then
            return "!", "JprThreadFailed"
        elseif thread.kind == "draft" then
            has_draft = true
        elseif thread.state ~= "resolved" then
            has_open = true
        end
    end
    if has_draft then
        return "✎", "JprThreadDraft"
    elseif has_open then
        return "💬", "JprThreadPublished"
    end
    return "✓", "JprThreadResolved"
end

--- Builds the compact end-of-line `virt_text` chunks for `threads` on one line.
function M.build_eol_chunks(threads)
    local first = threads[1]
    local _, group = M.pick_sign(threads)
    local extra_msgs = (first.messageCount or #first.messages) - 1
    local count_tag = extra_msgs > 0 and (" (+%d)"):format(extra_msgs) or ""
    local more_threads = #threads > 1 and (" [+%d threads]"):format(#threads - 1) or ""
    local state_tag = first.state == "resolved" and " [resolved]" or (first.outdated and " [outdated]" or "")
    local label = ("  @%s: %s%s%s%s"):format(
        one_line(first.firstAuthor or ""),
        one_line(first.snippet or ""),
        count_tag,
        state_tag,
        more_threads
    )
    return { { label, group } }
end

--- Formats non-empty reactions on a message as a single line (`👍 2*  👀 1`).
function M.build_reactions_line(reactions)
    local parts = {}
    for _, reaction in ipairs(reactions or {}) do
        if (reaction.count or 0) > 0 then
            local emoji = M.REACTION_EMOJI[reaction.content] or reaction.content
            local mine = reaction.viewerHasReacted and "*" or ""
            parts[#parts + 1] = ("%s %d%s"):format(emoji, reaction.count, mine)
        end
    end
    return table.concat(parts, "  ")
end

--- Builds `virt_lines` for inline expansion (`:Jpr expand`) of `threads`.
function M.build_expanded_virt_lines(threads, above_first)
    local virt_lines = {}
    for _, thread in ipairs(threads) do
        local _, group = M.pick_sign({ thread })
        local header_tag = above_first and "[file thread] " or ""
        local resolved_tag = thread.state == "resolved" and " [resolved]" or ""
        for index, msg in ipairs(thread.messages or {}) do
            local badge = SYNC_BADGE[msg.sync] and (" " .. SYNC_BADGE[msg.sync]) or ""
            local prefix = index == 1 and header_tag or "  ↳ "
            virt_lines[#virt_lines + 1] = {
                { ("  │ %s@%s%s%s"):format(prefix, one_line(msg.author), badge, index == 1 and resolved_tag or ""), group },
            }
            for body_line in (tostring(msg.body or "") .. "\n"):gmatch("(.-)\n") do
                virt_lines[#virt_lines + 1] = { { "  │   " .. body_line:gsub("\r$", ""), "Normal" } }
            end
            local react_text = M.build_reactions_line(msg.reactions)
            if react_text ~= "" then
                virt_lines[#virt_lines + 1] = { { "  │   " .. react_text, "JprReactionActive" } }
            end
        end
    end
    return virt_lines
end

local function group_threads_by_line(threads, line_count)
    local grouped, ordered_lines = {}, {}
    for _, thread in ipairs(threads or {}) do
        local target = math.min(math.max(0, thread.displayLine or 1), math.max(1, line_count))
        if not grouped[target] then
            grouped[target] = {}
            ordered_lines[#ordered_lines + 1] = target
        end
        grouped[target][#grouped[target] + 1] = thread
    end
    table.sort(ordered_lines)
    return grouped, ordered_lines
end

--- Turns `threads` on a file buffer (`line_count` lines) into extmark specs.
function M.create_extmarks_from_threads(threads, line_count, opts)
    local expanded = opts and opts.expanded or false
    local grouped, ordered_lines = group_threads_by_line(threads, line_count)
    local marks = {}
    for _, display_line in ipairs(ordered_lines) do
        local bucket = grouped[display_line]
        local row = math.max(0, display_line - 1)
        local sign_text, sign_hl = M.pick_sign(bucket)
        if display_line == 0 then
            marks[#marks + 1] = {
                line = 0,
                col = 0,
                opts = {
                    virt_lines = M.build_expanded_virt_lines(bucket, true),
                    virt_lines_above = true,
                },
            }
        else
            marks[#marks + 1] = {
                line = row,
                col = 0,
                opts = {
                    sign_text = sign_text,
                    sign_hl_group = sign_hl,
                    virt_text = not expanded and M.build_eol_chunks(bucket) or nil,
                    virt_text_pos = not expanded and "eol" or nil,
                },
            }
            if expanded then
                marks[#marks + 1] = {
                    line = row,
                    col = 0,
                    opts = { virt_lines = M.build_expanded_virt_lines(bucket, false) },
                }
            end
        end
    end
    return marks
end

local function append_popup_message(out, thread, msg)
    local start_line = #out.lines + 1
    local badge = SYNC_BADGE[msg.sync] and (" " .. SYNC_BADGE[msg.sync]) or ""
    local updated = (msg.updated and msg.updated ~= msg.created) and " (edited)" or ""
    out.add(("@%s · %s%s%s"):format(one_line(msg.author), one_line(msg.created or ""), updated, badge), "JprAuthor")
    if msg.syncError then
        out.add("  error: " .. one_line(msg.syncError), "JprError")
    end
    if msg.recoverableBody then
        out.add("  [concurrent edit on GitHub won; press e to recover your offline text]", "JprThreadDraft")
    end
    for body_line in (tostring(msg.body or "") .. "\n"):gmatch("(.-)\n") do
        out.add("  " .. body_line:gsub("\r$", ""))
    end
    local react_text = M.build_reactions_line(msg.reactions)
    if react_text ~= "" then
        out.add("  " .. react_text, "JprReactionActive")
    end
    out.message_ranges[#out.message_ranges + 1] = {
        first = start_line,
        last = #out.lines,
        thread_id = thread.threadId,
        message_id = msg.id,
        message = msg,
        thread = thread,
    }
end

--- Builds the lines, highlights, and cursor-to-message ranges for the thread popup.
function M.build_popup(threads)
    local out = { lines = {}, highlights = {}, message_ranges = {} }
    function out.add(text, group)
        out.lines[#out.lines + 1] = text
        if group then
            out.highlights[#out.highlights + 1] = { line = #out.lines - 1, col_start = 0, col_end = #text, group = group }
        end
    end
    for index, thread in ipairs(threads) do
        if index > 1 then
            out.add(string.rep("─", 48), "JprMuted")
        end
        local status = thread.state == "resolved" and "Resolved" or "Open"
        local outdated = thread.outdated and " · Outdated" or ""
        out.add(("Thread (%s%s)"):format(status, outdated), "JprTitle")
        for _, msg in ipairs(thread.messages or {}) do
            append_popup_message(out, thread, msg)
            out.add("")
        end
    end
    out.add("[r]eply  [e]dit  [d]elete  [R]esolve  [+]react  [X]retry  [q]uit", "JprMuted")
    return out
end

--- Finds the message range containing 1-based `cursor_line`, or falls back to the last one.
function M.find_message_at_line(popup_layout, cursor_line)
    for _, entry in ipairs(popup_layout.message_ranges or {}) do
        if cursor_line >= entry.first and cursor_line <= entry.last then
            return entry
        end
    end
    return popup_layout.message_ranges[#popup_layout.message_ranges]
end

return M
```

- [ ] **Step 4: Run `just test-lua`**

```bash
just test-lua
```

Expected: PASS (`threads_render_spec: ok`).

- [ ] **Step 5: Gate and commit**

```bash
just check
git add lua/jpr/render/threads.lua tests/lua/threads_render_spec.lua
git commit -m "feat(nvim): add pure thread sign, preview, inline-expand, and popup renderer"
```

---

### Task 14: Diff buffer thread markers, `]t`/`[t` navigation, and `:Jpr expand` (`views/threads.lua` & `views/diff.lua`)

**Files:**
- Create: `lua/jpr/views/threads.lua`
- Modify: `lua/jpr/views/diff.lua`
- Modify: `lua/jpr/session.lua`
- Create: `tests/lua/threads_view_spec.lua`

Draw `diff.threads` in both unified and split file diff windows (placing `Side::Left` threads on `base_buf` when in split mode and all threads on `buf` in unified mode), bind buffer comment keys via `jpr.bind_buffer_keys`, support `]t`/`[t` thread jumps, and toggle session-wide inline thread expansion on `:Jpr expand`.

- [ ] **Step 1: Write `tests/lua/threads_view_spec.lua`**

Create `tests/lua/threads_view_spec.lua` verifying:
1. Opening `README.md` from `fake_engine.sh` draws a thread sign + EOL preview extmark in the `jpr-threads` namespace on the anchored line.
2. `]t` and `[t` (`session.jump_thread_current(1)` / `(-1)`) move the cursor to the thread's line.
3. `:Jpr expand` (`session.expand_current()`) flips `session.threads_expanded` and replaces the compact EOL `virt_text` with full `virt_lines`, and running `:Jpr expand` again collapses back to compact EOL previews.
4. Switching to split mode (`:Jpr toggle`) places `right`-side thread signs on the file buffer and `left`-side thread signs on `jpr://base/...`.

- [ ] **Step 2: Run `just test-lua` to confirm failure**

```bash
just test-lua
```

Expected: FAIL (`module 'jpr.views.threads' not found`).

- [ ] **Step 3: Implement `lua/jpr/views/threads.lua` and hook into `views/diff.lua` + `session.lua`**

Create `lua/jpr/views/threads.lua`:

```lua
-- Places thread signs, EOL previews, and expanded blocks on diff buffers, and
-- answers thread queries for `gt`, `]t`, `[t`, and `:Jpr expand`.
local render = require("jpr.render.threads")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-threads")

--- Stores `threads` on `buf` and draws their extmarks.
function M.draw_on_buffer(session, buf, threads)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    session.buf_threads = session.buf_threads or {}
    session.buf_threads[buf] = threads or {}
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    local marks = render.create_extmarks_from_threads(threads or {}, vim.api.nvim_buf_line_count(buf), {
        expanded = session.threads_expanded == true,
    })
    for _, mark in ipairs(marks) do
        local opts = vim.tbl_extend("force", mark.opts, { strict = false })
        pcall(vim.api.nvim_buf_set_extmark, buf, namespace, mark.line, mark.col, opts)
    end
end

--- Draws `diff.threads` for split mode: `LEFT` threads on `base_buf` at their
--- base line, and `RIGHT` + `file` threads on `buf`.
function M.draw_split(session, base_buf, buf, diff)
    local left_threads, right_threads = {}, {}
    for _, thread in ipairs(diff.threads or {}) do
        if thread.anchor and thread.anchor.kind ~= "file" and thread.anchor.side == "LEFT" then
            local copy = vim.deepcopy(thread)
            copy.displayLine = thread.anchor["end"] or 1
            left_threads[#left_threads + 1] = copy
        else
            right_threads[#right_threads + 1] = thread
        end
    end
    M.draw_on_buffer(session, base_buf, left_threads)
    M.draw_on_buffer(session, buf, right_threads)
end

--- Clears thread extmarks and cached thread metadata from `buf`.
function M.clear_buffer(session, buf)
    if session.buf_threads then
        session.buf_threads[buf] = nil
    end
    if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    end
end

--- Returns the threads placed at 1-based `line` in `buf` (including file-level
--- threads when `line == 1`).
function M.threads_at_cursor(session, buf, line)
    local list = (session.buf_threads and session.buf_threads[buf]) or {}
    local matches = {}
    for _, thread in ipairs(list) do
        if thread.displayLine == line or (line == 1 and thread.displayLine == 0) then
            matches[#matches + 1] = thread
        end
    end
    return matches
end

--- Sorted unique 1-based lines holding threads in `buf`.
function M.thread_lines(session, buf)
    local list = (session.buf_threads and session.buf_threads[buf]) or {}
    local seen, lines = {}, {}
    for _, thread in ipairs(list) do
        local line = math.max(1, thread.displayLine or 1)
        if not seen[line] then
            seen[line] = true
            lines[#lines + 1] = line
        end
    end
    table.sort(lines)
    return lines
end

--- Jumps to the next (`step == 1`) or previous (`step == -1`) thread in the current window.
function M.jump(session, step)
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local lines = M.thread_lines(session, buf)
    local cursor = vim.api.nvim_win_get_cursor(win)[1]
    local target = require("jpr.render.stream").find_adjacent_line(lines, cursor, step)
    if target then
        vim.api.nvim_win_set_cursor(win, { target, 0 })
    end
end

return M
```

In `lua/jpr/views/diff.lua`:
- Call `require("jpr").bind_buffer_keys(buf)` when applying a diff to `buf` (and `require("jpr").bind_buffer_keys(base_buf)` in `M.open_base`, setting `vim.b[base_buf].jpr_base_path = diff.path` so `gc` on `base_buf` knows the file path and `Side::Left`!).
- Ensure `vim.wo[win].signcolumn = "yes"` (window-locally or preserving existing signcolumn when `"auto"`/`"yes"`) while a diff has threads, and call `require("jpr.views.threads").draw_on_buffer(session, buf, diff.threads)` in unified mode and `draw_split(session, base_buf, buf, diff)` in `M.open_base`, clearing via `threads.clear_buffer(session, applied.buf)` inside `M.clear`.

In `lua/jpr/session.lua`:
- On `threadsChanged`, update `session.view = params.view`, call `panel.render(session, params.view)`, `require("jpr.views.diff").redraw_all(session)`, and `require("jpr.views.stream").refresh(session, true)`.
- Implement `M.expand_current()` flipping `session.threads_expanded = not session.threads_expanded`, calling `diff.redraw_all(session)` and `stream.refresh(session, true)`.
- Implement `M.jump_thread_current(step)` routing to `require("jpr.views.stream").jump(session, "threads", step)` when the current buffer is a stream buffer, else `require("jpr.views.threads").jump(session, step)`.

- [ ] **Step 4: Run `just test-lua`**

```bash
just test-lua
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add lua tests/lua
git commit -m "feat(nvim): render diff thread signs, EOL previews, jumps, and inline expand"
```

---

### Task 15: Stream thread rows, line previews, jumps, and anchor resolution (`render/stream.lua` & `views/stream.lua`)

**Files:**
- Modify: `lua/jpr/render/stream.lua`
- Modify: `lua/jpr/views/stream.lua`
- Modify: `tests/lua/stream_render_spec.lua`
- Modify: `tests/lua/stream_view_spec.lua`

Render `StreamRow::Thread` (file-level and outdated threads) and `StreamRow::Line.threads` inside the unified and split stream views, expose `layout.threads_by_line`, `layout.thread_lines`, and `layout.anchors[line]` (so `gc`, `gC`, `gf`, `gt`, `]t`, `[t`, and `:Jpr expand` all work identically inside the stream!).

- [ ] **Step 1: Add failing assertions in `tests/lua/stream_render_spec.lua` and `tests/lua/stream_view_spec.lua`**

In `tests/lua/stream_render_spec.lua`, add a stream fixture containing a `kind = "thread"` row and a `kind = "line"` row with `threads = { ... }` and assert:
1. Compact mode (`expanded = false`) renders a one-line thread badge row for `kind = "thread"` and attaches `eol_chunks` + `threads_by_line[line]` on `kind = "line"` rows, recording both line numbers in `layout.thread_lines`.
2. Expanded mode (`expanded = true`) emits full indented message lines in both columns (using filler lines on the opposite split column so split `scrollbind` never drifts!).
3. `layout.anchors[line]` records `{ file = path, side = "LEFT" | "RIGHT", line = cell.line }` so commenting from the stream buffer anchors to the exact diff side and line.
4. `build_key_from_view` changes whenever `threadCount`, `draftCount`, `queuedCount`, or `file.threads` changes.

In `tests/lua/stream_view_spec.lua`, assert `]t` and `[t` jump to `layout.thread_lines` (skipping folded viewed files).

- [ ] **Step 2: Run `just test-lua` to confirm failure**

```bash
just test-lua
```

Expected: FAIL (`stream_render_spec.lua` missing `thread_lines` and `anchors`).

- [ ] **Step 3: Implement thread layout and stream keybindings in `render/stream.lua` and `views/stream.lua`**

In `lua/jpr/render/stream.lua`:
- Pass `opts` (`{ expanded = boolean }`) to `M.create_layout_from_stream(stream, opts)`.
- Add `threads_by_line = {}`, `thread_lines = {}`, `anchors = {}`, and `eol_marks = {}` to `layout` / `column`.
- Handle `row.kind == "thread"`:
  - Render `("  %s @%s: %s"):format(sign, one_line(t.firstAuthor), one_line(t.snippet))` across all columns (plus message body lines when `opts.expanded`), recording `layout.threads_by_line[line] = { row.thread }`, `layout.thread_lines[#layout.thread_lines + 1] = line`, and `layout.anchors[line] = { file = row.path, kind = "file", side = "RIGHT" }`.
- On `row.kind == "line"`:
  - Record `layout.anchors[line]` (`side = "LEFT"` when only `row.left` is present, else `"RIGHT"`, with `left_line = row.left and row.left.line` and `right_line = row.right and row.right.line` so split mode's left window uses `LEFT`!).
  - When `#(row.threads or {}) > 0`, record `layout.threads_by_line[line] = row.threads`, push `line` to `layout.thread_lines`, attach `threads_render.build_eol_chunks(row.threads)` to the rightmost column when not expanded, or emit aligned `build_expanded_virt_lines` rows across columns when `opts.expanded` is true.
- Include `view.threadCount or 0`, `view.draftCount or 0`, `view.queuedCount or 0`, and `file.threads or 0` in `M.build_key_from_view(view)`.

In `lua/jpr/views/stream.lua`:
- Pass `{ expanded = session.threads_expanded == true }` to `render.create_layout_from_stream`.
- Apply `column.eol_marks` as `virt_text_pos = "eol"` extmarks in `M.fill`.
- Call `require("jpr").bind_buffer_keys(buf)` inside `M.map_keys(session, buf)`.
- Support `kind == "threads"` in `M.jump(session, kind, step)` using `layout.thread_lines`, and add `M.threads_at_cursor(session)` + `M.anchor_at_range(session, win, line1, line2)` so stream buffers participate in `gt`, `gc`, `gC`, and `gf`.

- [ ] **Step 4: Run `just test-lua`**

```bash
just test-lua
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add lua/jpr/render/stream.lua lua/jpr/views/stream.lua tests/lua/stream_render_spec.lua tests/lua/stream_view_spec.lua
git commit -m "feat(nvim): render threads, anchors, and ]t/[t jumps in unified and split streams"
```

---

### Task 16: Floating thread popup and inline actions (`lua/jpr/comments/popup.lua`)

**Files:**
- Create: `lua/jpr/comments/popup.lua`
- Modify: `lua/jpr/session.lua`
- Create: `tests/lua/popup_spec.lua`

Open a floating window on `gt` (`<Plug>(jpr-thread-popup)`) showing the full thread(s) on the cursor line, with `[r]`eply, `[e]`dit, `[d]`elete, `[R]`esolve/unresolve, `[+]` reaction picker, `[X]` retry failed message, and `[q]`/`<Esc>` close.

- [ ] **Step 1: Write `tests/lua/popup_spec.lua`**

Create `tests/lua/popup_spec.lua` verifying:
1. Pressing `gt` (`session.popup_current()`) on a line with a thread opens a floating window (`nvim_win_get_config(win).relative ~= ""`) containing all messages and the action footer.
2. Pressing `R` sends `setResolved` (`resolved = true` on an open thread, `false` on a resolved one) to `fake_engine.sh`.
3. Pressing `+` invokes `vim.ui.select` with the 8 GitHub reactions and sends `toggleReaction` for the chosen reaction on the message under the cursor.
4. Pressing `d` on a viewer-authored message confirms via `vim.fn.confirm` and sends `deleteMessage`; pressing `d` or `e` on another user's message reports an error without calling the engine.
5. Pressing `X` on a `sync = "failed"` message sends `retryMessage`.
6. Pressing `q` closes the popup cleanly.

- [ ] **Step 2: Run `just test-lua` to confirm failure**

```bash
just test-lua
```

Expected: FAIL (`module 'jpr.comments.popup' not found`).

- [ ] **Step 3: Implement `lua/jpr/comments/popup.lua` and wire `session.popup_current()`**

Create `lua/jpr/comments/popup.lua` (keeping every function <= 45 lines):

```lua
-- Floating thread inspector at the cursor: renders full messages and dispatches
-- reply (r), edit (e), delete (d), resolve (R), reaction (+), and retry (X).
local render = require("jpr.render.threads")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-popup")

function M.close(session)
    local popup = session and session.popup
    if not popup then
        return
    end
    session.popup = nil
    if vim.api.nvim_win_is_valid(popup.win) then
        pcall(vim.api.nvim_win_close, popup.win, true)
    end
    if vim.api.nvim_buf_is_valid(popup.buf) then
        pcall(vim.api.nvim_buf_delete, popup.buf, { force = true })
    end
end

local function current_entry(session)
    local popup = session.popup
    if not popup or not vim.api.nvim_win_is_valid(popup.win) then
        return nil
    end
    local cursor_line = vim.api.nvim_win_get_cursor(popup.win)[1]
    return render.find_message_at_line(popup.layout, cursor_line)
end

local function pick_reaction(session)
    local entry = current_entry(session)
    if not entry then
        return
    end
    local items = render.REACTION_ORDER
    vim.ui.select(items, {
        prompt = "Toggle reaction:",
        format_item = function(content)
            return ("%s  %s"):format(render.REACTION_EMOJI[content] or "", content)
        end,
    }, function(choice)
        if not choice then
            return
        end
        require("jpr.session").request(session, "toggleReaction", {
            messageId = entry.message_id,
            content = choice,
        }, function(res)
            M.refresh_from_thread(session, res.thread)
        end)
    end)
end

local function toggle_resolved(session)
    local entry = current_entry(session)
    if not entry then
        return
    end
    local next_resolved = entry.thread.state ~= "resolved"
    require("jpr.session").request(session, "setResolved", {
        threadId = entry.thread_id,
        resolved = next_resolved,
    }, function(res)
        M.refresh_from_thread(session, res.thread)
    end)
end

local function delete_current_message(session)
    local entry = current_entry(session)
    if not entry then
        return
    end
    if not entry.message.viewerDidAuthor then
        return require("jpr").error("you can only delete your own comments")
    end
    if vim.fn.confirm("Delete this comment?", "&Yes\n&No", 2) ~= 1 then
        return
    end
    require("jpr.session").request(session, "deleteMessage", { messageId = entry.message_id }, function()
        M.close(session)
    end)
end

local function retry_current_message(session)
    local entry = current_entry(session)
    if not entry or entry.message.sync ~= "failed" then
        return require("jpr").info("this message is not in a failed state")
    end
    require("jpr.session").request(session, "retryMessage", { messageId = entry.message_id }, function()
        M.close(session)
    end)
end

local function bind_popup_keys(session, buf)
    local map = function(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
    map("q", function() M.close(session) end, "Close thread popup")
    map("<Esc>", function() M.close(session) end, "Close thread popup")
    map("R", function() toggle_resolved(session) end, "Resolve or unresolve thread")
    map("+", function() pick_reaction(session) end, "Toggle reaction on message")
    map("d", function() delete_current_message(session) end, "Delete own message")
    map("X", function() retry_current_message(session) end, "Retry failed message")
    map("r", function()
        local entry = current_entry(session)
        if entry then
            M.close(session)
            require("jpr.comments.compose").open_reply(session, entry.thread)
        end
    end, "Reply to thread")
    map("e", function()
        local entry = current_entry(session)
        if not entry then
            return
        end
        if not entry.message.viewerDidAuthor then
            return require("jpr").error("you can only edit your own comments")
        end
        M.close(session)
        require("jpr.comments.compose").open_edit(session, entry.message)
    end, "Edit own message")
end

local function paint_popup(popup, threads)
    local layout = render.build_popup(threads)
    popup.threads, popup.layout = threads, layout
    vim.bo[popup.buf].modifiable = true
    vim.api.nvim_buf_set_lines(popup.buf, 0, -1, false, layout.lines)
    vim.bo[popup.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(popup.buf, namespace, 0, -1)
    for _, hl in ipairs(layout.highlights) do
        vim.api.nvim_buf_set_extmark(popup.buf, namespace, hl.line, hl.col_start, {
            end_col = hl.col_end,
            hl_group = hl.group,
        })
    end
end

function M.refresh_from_thread(session, updated_thread)
    local popup = session.popup
    if not popup or not updated_thread or not vim.api.nvim_buf_is_valid(popup.buf) then
        return
    end
    local updated_list = {}
    for _, item in ipairs(popup.threads) do
        if item.threadId == updated_thread.id then
            updated_list[#updated_list + 1] = vim.tbl_extend("force", item, {
                state = updated_thread.state,
                messages = updated_thread.messages,
                messageCount = #updated_thread.messages,
            })
        else
            updated_list[#updated_list + 1] = item
        end
    end
    paint_popup(popup, updated_list)
end

function M.open(session, threads)
    if not threads or #threads == 0 then
        return require("jpr").info("no review thread on this line")
    end
    M.close(session)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    local popup = { buf = buf, threads = threads }
    paint_popup(popup, threads)
    local width = math.min(84, math.max(52, vim.o.columns - 12))
    local height = math.min(22, math.max(6, #popup.layout.lines))
    popup.win = vim.api.nvim_open_win(buf, true, {
        relative = "cursor",
        row = 1,
        col = 0,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = " Review Thread ",
        title_pos = "center",
    })
    vim.api.nvim_set_option_value("wrap", true, { win = popup.win, scope = "local" })
    session.popup = popup
    bind_popup_keys(session, buf)
end

return M
```

Wire `session.popup_current()` in `lua/jpr/session.lua` to gather threads on the current line from `views/stream.threads_at_cursor(session)` (when in a stream buffer) or `views/threads.threads_at_cursor(session, buf, line)` (when in a diff buffer) and call `popup.open(session, threads)`.

- [ ] **Step 4: Run `just test-lua`**

```bash
just test-lua
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add lua tests/lua
git commit -m "feat(nvim): add floating thread popup with reply, edit, delete, resolve, react, and retry"
```

---

### Task 17: Markdown compose buffer (`[GitHub draft]`) and `@mention` completion (`mentions.lua` & `compose.lua`)

**Files:**
- Create: `lua/jpr/comments/mentions.lua`
- Create: `lua/jpr/comments/compose.lua`
- Modify: `lua/jpr/session.lua`
- Create: `tests/lua/compose_spec.lua`

Provide the markdown scratch editor (`buftype = "nofile"`, `filetype = "markdown"`) labeled `[GitHub draft]` (for code threads and pending-review replies) or `[GitHub comment]` (for PR conversation comments and immediate replies), with `<C-s>` in normal/insert mode to save, `q`/`<Esc>` in normal mode to cancel (confirming when modified), `<C-g>s` in insert mode to insert a ```` ```suggestion ```` block prefilled from `anchoredLines`, and `@mention` completion via both buffer-local `omnifunc` (`<C-x><C-o>`) and an optional `nvim-cmp` source when `cmp` is installed.

- [ ] **Step 1: Write `tests/lua/compose_spec.lua`**

Create `tests/lua/compose_spec.lua` verifying:
1. `mentions.find_start("hello @pa")` returns `6` (0-based `@` byte offset) and `mentions.complete_items(candidates, "@pa")` returns `{ { word = "@pablo", menu = "[PR]" } }` with participants sorted ahead of non-participants.
2. `compose.open_new(session, anchor, { suggest = false })` opens a floating `markdown` buffer whose window title contains `[GitHub draft]` and whose `omnifunc` is wired to `mentions`.
3. Pressing `<C-s>` sends `comment` with the buffer's lines joined by `\n` and closes the compose window.
4. `compose.open_new(session, anchor, { suggest = true })` fetches `anchoredLines` and pre-populates ```` ```suggestion\n<lines>\n``` ````.
5. `compose.open_edit(session, message)` pre-populates `message.recoverableBody or message.body` so concurrent-edit recovery takes one `<C-s>`.

- [ ] **Step 2: Run `just test-lua` to confirm failure**

```bash
just test-lua
```

Expected: FAIL (`module 'jpr.comments.mentions' not found`).

- [ ] **Step 3: Implement `lua/jpr/comments/mentions.lua`, `lua/jpr/comments/compose.lua`, and `session.comment_current`**

Create `lua/jpr/comments/mentions.lua`:

```lua
-- `@mention` completion backed by the engine's `mentions` list: works via
-- `<C-x><C-o>` (`omnifunc`) everywhere and registers an optional `nvim-cmp`
-- source (`jpr_mentions`) when `cmp` is loaded.
local M = {}

local active_candidates = {}

--- Finds the 0-based byte index of `@` before the cursor on `line_to_cursor`,
--- or -1 when the cursor is not completing a mention.
function M.find_start(line_to_cursor)
    local start_idx = line_to_cursor:find("@[%w_%-]*$")
    return start_idx and (start_idx - 1) or -1
end

--- Builds completion items matching `base` (such as `"@pa"` or `"@"`).
function M.complete_items(candidates, base)
    local query = (base or ""):gsub("^@", ""):lower()
    local items = {}
    for _, item in ipairs(candidates or {}) do
        if item.login:lower():find(query, 1, true) == 1 then
            items[#items + 1] = {
                word = "@" .. item.login,
                abbr = "@" .. item.login,
                menu = item.isParticipant and "[PR]" or "[repo]",
                icase = 1,
            }
        end
    end
    return items
end

--- Global omnifunc entry point (`v:lua.require'jpr.comments.mentions'.omnifunc`).
function M.omnifunc(findstart, base)
    if findstart == 1 then
        local col = vim.api.nvim_win_get_cursor(0)[2]
        local line = vim.api.nvim_get_current_line():sub(1, col)
        return M.find_start(line)
    end
    return M.complete_items(active_candidates, base)
end

local cmp_registered = false

local function maybe_register_cmp()
    if cmp_registered then
        return
    end
    local ok, cmp = pcall(require, "cmp")
    if not ok or type(cmp.register_source) ~= "function" then
        return
    end
    cmp_registered = true
    cmp.register_source("jpr_mentions", {
        is_available = function()
            return vim.b.jpr_compose == true
        end,
        get_trigger_characters = function()
            return { "@" }
        end,
        complete = function(_, params, callback)
            local before = params.context.cursor_before_line or ""
            local start_col = M.find_start(before)
            if start_col < 0 then
                return callback({ items = {}, isIncomplete = false })
            end
            local prefix = before:sub(start_col + 1)
            local out = {}
            for idx, item in ipairs(M.complete_items(active_candidates, prefix)) do
                out[#out + 1] = {
                    label = item.word,
                    sortText = ("%04d"):format(idx),
                    detail = item.menu,
                }
            end
            callback({ items = out, isIncomplete = false })
        end,
    })
end

--- Attaches `@mention` completion to compose buffer `buf` for `session`.
function M.attach(session, buf)
    vim.b[buf].jpr_compose = true
    vim.bo[buf].omnifunc = "v:lua.require'jpr.comments.mentions'.omnifunc"
    maybe_register_cmp()
    if session and session.client then
        require("jpr.session").request(session, "mentions", nil, function(res)
            active_candidates = (res and res.candidates) or {}
        end, function() end)
    end
end

return M
```

Create `lua/jpr/comments/compose.lua` (keeping each function <= 45 lines):

```lua
-- Floating markdown compose buffer for new comments, replies, edits, and
-- suggestion blocks. `<C-s>` submits; `q` / `<Esc>` cancels; `<C-g>s` inserts
-- a suggestion fence pre-filled with the anchored lines.
local mentions = require("jpr.comments.mentions")

local M = {}

function M.close(session)
    local compose = session and session.compose
    if not compose then
        return
    end
    session.compose = nil
    if vim.api.nvim_win_is_valid(compose.win) then
        pcall(vim.api.nvim_win_close, compose.win, true)
    end
    if vim.api.nvim_buf_is_valid(compose.buf) then
        pcall(vim.api.nvim_buf_delete, compose.buf, { force = true })
    end
end

local function buffer_body(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function insert_suggestion_fence(session, buf, anchor)
    if not anchor or (anchor.kind ~= "line" and anchor.kind ~= "range") then
        return require("jpr").info("suggestion blocks apply to line or range comments")
    end
    require("jpr.session").request(session, "anchoredLines", { anchor = anchor }, function(res)
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        local fence = { "```suggestion" }
        for line in ((res and res.text or "") .. "\n"):gmatch("(.-)\n") do
            fence[#fence + 1] = line
        end
        fence[#fence + 1] = "```"
        local row = vim.api.nvim_win_get_cursor(0)[1]
        vim.api.nvim_buf_set_lines(buf, row, row, false, fence)
    end)
end

local function bind_compose_keys(session, buf, initial_text, anchor, on_submit)
    local submit = function()
        local text = buffer_body(buf)
        if vim.trim(text) == "" then
            return require("jpr").error("comment body cannot be empty")
        end
        vim.cmd("stopinsert")
        M.close(session)
        on_submit(text)
    end
    local cancel = function()
        if buffer_body(buf) ~= initial_text then
            if vim.fn.confirm("Discard unsaved comment text?", "&Discard\n&Keep editing", 2) ~= 1 then
                return
            end
        end
        M.close(session)
    end
    vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, silent = true, desc = "Save comment" })
    vim.keymap.set("n", "q", cancel, { buffer = buf, nowait = true, silent = true, desc = "Cancel comment" })
    vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, nowait = true, silent = true, desc = "Cancel comment" })
    vim.keymap.set("i", "<C-g>s", function()
        insert_suggestion_fence(session, buf, anchor)
    end, { buffer = buf, silent = true, desc = "Insert GitHub suggestion block" })
end

local function open_editor(session, opts)
    M.close(session)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    local initial_lines = vim.split(opts.initial or "", "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)
    local width = math.min(86, math.max(54, vim.o.columns - 12))
    local height = 12
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(2, math.floor((vim.o.columns - width) / 2)),
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = " " .. opts.title .. " ",
        title_pos = "center",
        footer = " <C-s> save · <C-g>s suggestion · @ mention · q cancel ",
        footer_pos = "center",
    })
    vim.api.nvim_set_option_value("wrap", true, { win = win, scope = "local" })
    session.compose = { buf = buf, win = win }
    mentions.attach(session, buf)
    bind_compose_keys(session, buf, opts.initial or "", opts.anchor, opts.on_submit)
    return buf
end

function M.open_new(session, anchor, opts)
    local is_pr = anchor.kind == "pr"
    local badge = is_pr and "[GitHub comment]" or "[GitHub draft]"
    local location = is_pr and "PR Conversation"
        or (anchor.kind == "file" and anchor.file or ("%s:%d"):format(anchor.file, anchor["end"] or 1))
    local create_buf = function(initial)
        open_editor(session, {
            title = ("%s %s"):format(badge, location),
            initial = initial,
            anchor = anchor,
            on_submit = function(body)
                require("jpr.session").request(session, "comment", { anchor = anchor, body = body }, function() end)
            end,
        })
    end
    if opts and opts.suggest and (anchor.kind == "line" or anchor.kind == "range") then
        return require("jpr.session").request(session, "anchoredLines", { anchor = anchor }, function(res)
            create_buf(("```suggestion\n%s\n```"):format((res and res.text) or ""))
        end)
    end
    create_buf("")
end

function M.open_reply(session, thread)
    local badge = (session.view and (session.view.draftCount or 0) > 0) and "[GitHub draft]" or "[GitHub reply]"
    open_editor(session, {
        title = ("%s Reply"):format(badge),
        initial = "",
        anchor = thread.anchor,
        on_submit = function(body)
            require("jpr.session").request(session, "reply", { threadId = thread.threadId or thread.id, body = body }, function() end)
        end,
    })
end

function M.open_edit(session, message)
    local initial = message.recoverableBody or message.body or ""
    open_editor(session, {
        title = "[Edit GitHub comment]",
        initial = initial,
        on_submit = function(body)
            require("jpr.session").request(session, "editMessage", { messageId = message.id, body = body }, function() end)
        end,
    })
end

return M
```

Wire `M.comment_current(opts)` in `lua/jpr/session.lua` to resolve the current buffer/window's `Anchor` (`stream.anchor_at_range` when in the stream, `side = "LEFT"` when `vim.b[buf].jpr_base_path` is set, else `side = "RIGHT"` on `diff.buffer_to_changed_path(session, buf)`, using visual `'<,'>` or `cmd_opts.line1..cmd_opts.line2` when a range was selected, or `kind = "file"` for `file_comment`) and call `compose.open_new(session, anchor, opts)`.

- [ ] **Step 4: Run `just test-lua`**

```bash
just test-lua
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add lua tests/lua
git commit -m "feat(nvim): add markdown comment compose buffer and @mention completion"
```

---

### Task 18: PR conversation view (`:Jpr conversation`) and edit-to-suggestion (`:Jpr suggest`)

**Files:**
- Create: `lua/jpr/views/conversation.lua`
- Create: `lua/jpr/comments/suggest.lua`
- Modify: `lua/jpr/session.lua`
- Create: `tests/lua/conversation_suggest_spec.lua`

Implement `:Jpr conversation` (top-level PR issue comments rendered in the main window beside the panel, with `c` to post a new PR comment, `e` to edit own, `d` to delete own, `+` to react, and `X` to retry failed) and `:Jpr suggest` (sending unsaved or saved buffer edits at the cursor line to `suggestFromEdit`, updating the buffer + disk with `revertedText` so only that hunk reverts, and showing the new draft suggestion thread).

- [ ] **Step 1: Write `tests/lua/conversation_suggest_spec.lua`**

Create `tests/lua/conversation_suggest_spec.lua` verifying:
1. `:Jpr conversation` (`session.conversation_current()`) opens `jpr://conversation/7` in the main window beside the panel, lists `anchor.kind == "pr"` comments with author headers and reactions, opens `compose` on `c`, edits own on `e`, and toggles reactions on `+`.
2. Editing line 2 of `README.md` in its buffer and running `:Jpr suggest` (`session.suggest_current()`) sends `suggestFromEdit` with the buffer's lines, replaces the buffer contents (and writes the file if it was unmodified or saved) with `suggested.revertedText` while preserving any other edited lines, and clears `modified` when the buffer now matches disk.

- [ ] **Step 2: Run `just test-lua` to confirm failure**

```bash
just test-lua
```

Expected: FAIL (`module 'jpr.views.conversation' not found`).

- [ ] **Step 3: Implement `lua/jpr/views/conversation.lua` and `lua/jpr/comments/suggest.lua`**

Create `lua/jpr/views/conversation.lua` (each function <= 45 lines):
- `M.show(session)` creates or reuses `jpr://conversation/<n>`, places it in `main_window.find(session)` (clearing any diff split first), requests `threads` from the engine, filters to `thread.anchor.kind == "pr"`, and renders them via `jpr.render.threads`'s message formatter (`c` calls `compose.open_new(session, { kind = "pr", side = "RIGHT" })`, `e` calls `compose.open_edit`, `d` confirms and calls `deleteMessage`, `+` calls `vim.ui.select` + `toggleReaction`, `X` calls `retryMessage`).
- `M.refresh(session)` re-fetches and redraws when `session.conversation_buf` is visible.
- `M.close(session)` wipes `session.conversation_buf` on teardown.

Create `lua/jpr/comments/suggest.lua`:

```lua
-- `:Jpr suggest`: turns the reviewer's uncommitted edit at the cursor line into
-- a GitHub `suggestion` draft comment and reverts just that hunk in the buffer
-- and worktree file.
local diff_view = require("jpr.views.diff")

local M = {}

local function write_reverted_text(buf, full_path, reverted_text)
    local lines = vim.split(reverted_text, "\n", { plain = true })
    if lines[#lines] == "" then
        table.remove(lines, #lines)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.fn.writefile(lines, full_path)
    vim.bo[buf].modified = false
end

function M.run(session)
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local path = diff_view.buffer_to_changed_path(session, buf)
    if not path then
        return require("jpr").error(":Jpr suggest must be run inside a changed worktree file")
    end
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
    local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local edited_text = table.concat(buf_lines, "\n") .. "\n"
    local full_path = vim.api.nvim_buf_get_name(buf)
    require("jpr.session").request(session, "suggestFromEdit", {
        path = path,
        editedText = edited_text,
        cursorLine = cursor_line,
    }, function(result)
        if not result or not result.suggested then
            return
        end
        if vim.api.nvim_buf_is_valid(buf) then
            write_reverted_text(buf, full_path, result.suggested.revertedText)
            diff_view.refresh_buffer(session, buf)
        end
        require("jpr").info(("created suggestion draft on %s"):format(path))
    end)
end

return M
```

Wire `M.conversation_current()` and `M.suggest_current()` in `lua/jpr/session.lua`.

- [ ] **Step 4: Run `just test-lua`**

```bash
just test-lua
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add lua tests/lua
git commit -m "feat(nvim): add PR conversation view and :Jpr suggest edit-to-suggestion flow"
```

---

### Task 19: Review submission view (`:Jpr submit`) (`render/submit.lua` & `views/submit.lua`)

**Files:**
- Create: `lua/jpr/render/submit.lua`
- Create: `lua/jpr/views/submit.lua`
- Modify: `lua/jpr/session.lua`
- Create: `tests/lua/submit_spec.lua`

Implement `:Jpr submit` showing the pending draft list, any `blockedReason` warning when comments are still `pending`/`queued`/`failed`, editable review summary body, `<CR>` on a draft line to jump straight to that draft's file/line, and explicit event selector (`COMMENT`, `APPROVE`, `REQUEST_CHANGES`), graying out and refusing `APPROVE` / `REQUEST_CHANGES` when `canApproveOrRequestChanges == false` (own PR).

- [ ] **Step 1: Write `tests/lua/submit_spec.lua`**

Create `tests/lua/submit_spec.lua` verifying:
1. `render_submit.build(preview, "COMMENT", { "Looks solid" })` renders the action selector (`[x] 1. Comment`, `[ ] 2. Approve`, `[ ] 3. Request changes`), any `preview.blockedReason` banner in `JprError`, the draft count + draft locations/snippets (`out.draft_anchors[line]`), and when `canApproveOrRequestChanges == false` marks Approve and Request changes `(unavailable on your own PR)` with `JprMuted`.
2. `:Jpr submit` (`session.submit_current()`) opens the floating submit window, cycles/selects events (`1` = Comment, `2` = Approve, `3` = Request changes, refusing `2`/`3` when disabled), jumps to a draft's file/line when `<CR>` is pressed on a draft row, edits the summary body on `e`, and submits `submitReview` on `<C-s>` (or `<CR>` on non-draft rows, refusing with `jpr.error(preview.blockedReason)` when blocked).

- [ ] **Step 2: Run `just test-lua` to confirm failure**

```bash
just test-lua
```

Expected: FAIL (`module 'jpr.render.submit' not found`).

- [ ] **Step 3: Implement `lua/jpr/render/submit.lua` and `lua/jpr/views/submit.lua`**

Create `lua/jpr/render/submit.lua`:

```lua
-- Pure: formats the :Jpr submit modal from SubmitPreview, chosen event, and
-- summary body.
local one_line = require("jpr.render.panel").one_line

local M = {}

local EVENTS = {
    { id = "COMMENT", key = "1", label = "Comment" },
    { id = "APPROVE", key = "2", label = "Approve" },
    { id = "REQUEST_CHANGES", key = "3", label = "Request changes" },
}

local function append_drafts(out, add, preview)
    add(("Pending Drafts (%d):"):format(preview.draftCount or 0), "JprTitle")
    if (preview.draftCount or 0) == 0 then
        add("  (none - submits review summary only)", "JprMuted")
        return
    end
    for _, draft in ipairs(preview.drafts or {}) do
        local loc = draft.anchor.file or "PR"
        if draft.anchor["end"] then
            loc = ("%s:%d"):format(loc, draft.anchor["end"])
        end
        add(("  • %s: %s"):format(one_line(loc), one_line(draft.snippet)), "JprThreadDraft")
        out.draft_anchors[#out.lines] = draft.anchor
    end
end

function M.build(preview, selected_event, body_lines)
    local out = { lines = {}, highlights = {}, draft_anchors = {} }
    local add = function(text, group)
        out.lines[#out.lines + 1] = text
        if group then
            out.highlights[#out.highlights + 1] = {
                line = #out.lines - 1,
                col_start = 0,
                col_end = #text,
                group = group,
            }
        end
    end
    if preview.blockedReason then
        add("Blocked: " .. one_line(preview.blockedReason), "JprError")
        add("")
    end
    add("Review Action (press 1/2/3):", "JprTitle")
    for _, option in ipairs(EVENTS) do
        local restricted = option.id ~= "COMMENT" and not preview.canApproveOrRequestChanges
        local mark = selected_event == option.id and "[x]" or "[ ]"
        local note = restricted and " (unavailable on your own PR)" or ""
        local group = restricted and "JprMuted" or (selected_event == option.id and "JprViewed" or nil)
        add(("  %s %s. %s%s"):format(mark, option.key, option.label, note), group)
    end
    add("")
    append_drafts(out, add, preview)
    add("")
    add("Summary Body (press e to edit):", "JprTitle")
    local has_body = body_lines and #body_lines > 0 and vim.trim(table.concat(body_lines, "\n")) ~= ""
    if not has_body then
        add("  (optional for Approve / Drafts; required for empty Comment)", "JprMuted")
    else
        for _, line in ipairs(body_lines) do
            add("  " .. line)
        end
    end
    add("")
    add("[1/2/3] action  [e] summary  [<CR>] open draft / submit  [<C-s>] submit  [q] cancel", "JprMuted")
    return out
end

return M
```

Create `lua/jpr/views/submit.lua` (keeping each helper <= 45 lines):
- `M.open(session)` requests `submitPreview`, opens a centered rounded floating window rendered by `render.submit.build`, binds `1` (`COMMENT`), `2` (`APPROVE`), `3` (`REQUEST_CHANGES`, showing `jpr.info("cannot approve or request changes on your own PR")` when `not preview.canApproveOrRequestChanges`), `e` (opens a small markdown summary editor via `compose` callback that returns to the submit modal with `body_lines` updated), `<CR>` (when `rendered.draft_anchors[cursor_line]` is non-nil, closes the modal, opens `anchor.file` via `session.open_file`, and positions the cursor at `anchor["end"] or 1`; otherwise invokes submit), `<C-s>` (sends `submitReview` with `{ event = selected_event, body = summary }` unless `preview.blockedReason` is set, closes the modal on success, or keeps the modal open and shows the error if rejected so drafts and summary text are never lost), and `q`/`<Esc>` to close.

Wire `M.submit_current()` in `lua/jpr/session.lua`.

- [ ] **Step 4: Run `just test-lua`**

```bash
just test-lua
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add lua tests/lua
git commit -m "feat(nvim): add :Jpr submit review modal with draft preview and self-review guard"
```

---

### Task 20: Documentation updates and `0.3.0` workspace version bump

**Files:**
- Modify: `Cargo.toml`
- Modify: `docs/protocol.md`
- Modify: `docs/architecture.md`
- Modify: `docs/decisions.md`
- Modify: `README.md`

Document protocol v3, the `github.json` v2 store envelope, the REST-reply-with-GraphQL-fallback decision, and all new `:Jpr` commands and keybindings, and bump the workspace version from `0.2.0` to `0.3.0`. (Ensure zero em dashes anywhere in docs!)

- [ ] **Step 1: Update `Cargo.toml`, `docs/protocol.md`, `docs/architecture.md`, `docs/decisions.md`, and `README.md`**

1. In `Cargo.toml`, change `version = "0.2.0"` to `version = "0.3.0"`.
2. In `docs/protocol.md`:
   - Change header and examples to `protocolVersion: 3` and `version: "0.3.0"`.
   - Document all 13 new requests (`threads`, `mentions`, `comment`, `reply`, `editMessage`, `deleteMessage`, `setResolved`, `toggleReaction`, `retryMessage`, `anchoredLines`, `suggestFromEdit`, `submitPreview`, `submitReview`), the `threadsChanged` notification, `ThreadPreview`, `SubmitPreview`, and `SessionView`'s `draftCount` and `conversationCount` fields.
3. In `docs/architecture.md`:
   - Update the `review-store-fs` description for `github.json` v2 (persisted threads, queued comment ops, agreed bodies, ID remapping) and the `lua/jpr/comments/` + `lua/jpr/views/` layout.
4. In `docs/decisions.md`, append one concise section at the bottom:
   - `## Immediate thread replies use GitHub REST and fall back to pending-review GraphQL` explaining why `addPullRequestReviewThreadReply` without a review creates a pending review, why REST `POST .../comments/{id}/replies` publishes immediately when no pending review exists, and why HTTP 422 falls back to `addPullRequestReviewThreadReply` when a pending review is active.
5. In `README.md`:
   - Add `:Jpr comment`, `:Jpr suggest`, `:Jpr expand`, `:Jpr conversation`, and `:Jpr submit` to the command table, document default diff/stream comment keys (`gc`, `gC`, `gf`, `gt`, `]t`/`[t`) and `setup({ keys = ... })` / `<Plug>(jpr-...)` customization.

- [ ] **Step 2: Check for accidental em dashes and run `just check`**

```bash
! rg "\x{2014}" README.md docs Cargo.toml crates lua plugin tests
just check
```

Expected: `rg` finds nothing (`! rg` exits 0) and `just check` exits 0.

- [ ] **Step 3: Commit**

```bash
git add Cargo.toml Cargo.lock README.md docs
git commit -m "docs: document protocol v3, comment workflows, and bump workspace to 0.3.0"
```

---

### Task 21: Live GitHub PR smoke test and cleanup

**Files:**
- None committed (live end-to-end verification against `jpsyx/jpr-nvim`, per `AGENTS.md` `Live GitHub smoke tests`)

Exercise every M3 GitHub comment path against a real pull request on `jpsyx/jpr-nvim`, verify `gh` + `jpr-review` + headless Neovim end-to-end, and clean up every remote/local artifact afterward.

- [ ] **Step 1: Install the freshly built `jpr-review` binary and create a throwaway smoke PR**

Follow `AGENTS.md`'s `Live GitHub smoke tests` rules strictly (`wt new chore smoke-comments-m3` from `main`, push, `gh pr create --repo jpsyx/jpr-nvim`):

```bash
just install
wt new chore smoke-comments-m3
```

Inside the `chore/smoke-comments-m3` worktree, make a small multi-line edit to a throwaway file (`SMOKE.md`), commit, push, and open a draft PR:

```bash
printf 'alpha\nbeta\ngamma\n' > SMOKE.md
git add SMOKE.md
git commit -m "chore(smoke): test M3 GitHub comments"
git push -u origin HEAD
SMOKE_PR=$(gh pr create --repo jpsyx/jpr-nvim --draft --title "chore(smoke): M3 comments verification" --body "Temporary smoke PR for M3; will close without merging.")
echo "$SMOKE_PR"
```

- [ ] **Step 2: Exercise M3 end-to-end against the smoke PR via `jpr-review serve` / headless Neovim**

From the `feat/github-comments` worktree, run a scripted smoke session against the smoke PR number (`PR_NUM`) verifying:
1. `sync` fetches `viewer_login`, `files` (`SMOKE.md`), and `mention_candidates` (`pablo` / repo users).
2. `comment` on `SMOKE.md` line 2 creates a real pending review + `Draft` review thread on GitHub (`draftCount == 1`).
3. `comment` on `Anchor::pr()` posts a live PR conversation comment (`conversationCount == 1`).
4. `toggleReaction` (`THUMBS_UP`) adds and removes a real reaction on the conversation comment.
5. `suggestFromEdit` on `SMOKE.md` creates a `suggestion` draft thread and returns the exact `revertedText`.
6. `submitReview` (`COMMENT`, `"M3 smoke review summary"`) submits the pending review (`draftCount == 0`) and rejects `APPROVE` on own PR with the expected self-review guard.
7. `reply` on the now-published code thread (with no pending review active) publishes immediately via REST (`sync == "published"`), `editMessage` updates its body, `setResolved` resolves and unresolves the thread, and `deleteMessage` deletes the reply cleanly.

- [ ] **Step 3: Clean up the smoke PR, remote branch, worktree, and local state directory**

```bash
gh pr close "$SMOKE_PR" --repo jpsyx/jpr-nvim --delete-branch
wt rm chore/smoke-comments-m3
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/jpr/jpsyx/jpr-nvim/pr-${PR_NUM}"
```

Confirm `gh pr view "$SMOKE_PR" --repo jpsyx/jpr-nvim --json state` reports `"CLOSED"` and `just check` still passes in the `feat/github-comments` worktree.

---

## Execution & Review Routing Notes (`super-wrapper` + `finishing-a-development-branch`)

- **Controller gate:** Before dispatching subagents to execute this plan in Antigravity, confirm the controller session runs on `gemini-4-hydrogen-high`.
- **Subagent model tiers:**
  - Use `Model = "inherit"` for implementer tasks and ordinary spec/code-quality reviews (`Tasks 0-3, 5, 7, 9-21`).
  - Use `Model = "pro"` for task-level reviews on the three `[HIGH-RISK]` tasks (**Task 4**, **Task 6**, **Task 8**), for any blocked-implementer escalation, and for the final whole-branch code review before `finishing-a-development-branch`. Never use `flash` or `flash_lite`.
- **Completion:** Once all 22 tasks pass `just check` and the final whole-branch review is clean, follow `finishing-a-development-branch` (remembering `AGENTS.md`: never push `main` unless explicitly asked).
