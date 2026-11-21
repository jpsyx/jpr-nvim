# jpr-nvim Milestone 4 (Local comments and the agent loop) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the reviewer leave local agent-only threads on lines, ranges, files, or the pull request, toggle comment destinations in compose, run an interactive Claude Code or Codex side panel (`:Jpr agent`), batch-send unsent local threads (`:Jpr send` or popup `s`), receive inline agent replies and pre-pass findings (`jpr-review reply`, `jpr-review prepass-write`, `jpr-review guide`) over a Unix socket or locked `local.json` fallback, promote local root comments to GitHub drafts (`p`), and auto-refresh buffers and re-anchor local threads when worktree files change.

**Architecture:** `review-model` gains frontend-neutral types for local agent thread state (`unsent`, `sent`, `answered`), promotion links, agent profiles (`claude`, `codex`), launch plans, dispatches, rounds, pre-pass findings, and file-change/round events. `review-core` owns snapshot-based local anchor re-anchoring, `dif`'s dispatch eligibility and numbered batch prompt builders, two-phase send confirmation, promotion into GitHub drafts, worktree change detection, and the `jpr-review guide` contract text. `review-store-fs` persists `local.json` v1, `rounds.jsonl`, and `session.json` v3 (`socket`, `agentSessionId`, `agentKind`) plus a `local.lock` atomic fallback writer for CLI calls when no daemon is serving. `review-rpc` bumps to protocol version 4 and serves both stdio and a per-PR Unix domain socket, flushing session events immediately to Neovim when socket clients mutate local threads; `lua/jpr/` adds the compose destination toggle, local thread markers/actions, `BufWritePost` live extmark anchor updates, `checktime` refresh on `filesChanged`, and `lua/jpr/agent.lua` for the side-panel terminal and bracketed-paste delivery. Spec: milestone 4 of `docs/superpowers/specs/2026-11-19-jpr-nvim-design.md`.

**Tech Stack:** Rust 2024 (`anyhow`, `clap`, `serde`, `serde_json`, `similar`, `std::os::unix::net`; threads, no async runtime, no new Cargo dependencies), git, the GitHub CLI (`gh`), Neovim 0.11+ Lua (headless `nvim -l` specs).

---

## Scope

| In this milestone | Where in the spec |
| --- | --- |
| Local threads (`Origin::Local`, `agent`: `unsent` / `sent { round }` / `answered`, `promotedTo`), never sent to GitHub unless promoted | "Data model: Threads", "Requirements: Local comments" |
| Persisted `local.json` v1, `rounds.jsonl`, `session.json` v3 (`socket`, `agentSessionId`, `agentKind`), and locked atomic fallback writes (`local.lock`) when no daemon is running | "Data model: Store", "Architecture" |
| Snapshot-based local anchor re-anchoring in `review-core` on file edits, plus live Neovim extmark position updates (`updateLocalAnchors`) on buffer save | "Data model: Threads", "Agent loop: Agent edits" |
| Daemon Unix domain socket (`JPR_SOCKET` + `session.json`) alongside stdio JSON-RPC (protocol v4), pushing `threadsChanged` / `filesChanged` / `agentRound` events to Neovim | "Architecture", "Agent loop" |
| CLI subcommands: `jpr-review reply <thread-id> --body ...` (refusing GitHub thread IDs), `jpr-review threads`, `jpr-review prepass-write`, and `jpr-review guide` | "Repository layout", "Agent loop: Agent contract", "Agent loop: Pre-pass" |
| Compose destination badge (`[GitHub draft]` vs `[Local -> agent]`, sticky per session), `<C-g>` flip, `<C-s>` save to shown destination, `<M-s>` save to alternate destination | "Decisions: Destination", "Neovim UI: Comments" |
| Local thread sign/highlight (`JprThreadLocal`), status badges, panel `local unsent N` count, popup `p` (promote root comment via compose into GitHub draft) and `s` (send single thread now), Conversation local PR comments | "PR tab", "Neovim UI: Comments", "Decisions: Promotion" |
| `:Jpr agent` right vertical terminal split (`claude` default, `codex` configurable, `JPR_SOCKET` + `JPR_PR`, session resume), `:Jpr send` (bracketed paste + delayed submit key + `confirmSend`), and `:Jpr prepass` | "Agent loop: Side panel", "Sending local comments", "Pre-pass" |
| Worktree file watcher in `review-rpc` emitting `filesChanged` -> Neovim `checktime` + diff/stream redraw | "Agent loop: Agent edits" |

| Deferred | To | Why |
| --- | --- | --- |
| `:Jpr push`, panel dirty/ahead/behind (`dirty`, `pencil` locally modified file mark), `require("jpr").statusline()`, daemon crash auto-restart banner, dirty-worktree fast-forward stash/restore | Milestone 5 | Polish milestone |

## Ground rules for every task

- Work in a worktree on branch `feat/local-comments-agent-loop` (Task 0), created through `wt` (`using-wt` skill, never raw `git worktree`). Commit after every task. Do not push `main` or open unrequested PRs.
- Run commands from the worktree root unless a step says otherwise.
- `just check` must pass at the end of every task (`cargo fmt --all --check`, `cargo clippy --workspace --all-targets --all-features -- -D warnings`, Rust tests, and `./scripts/test-lua.sh`).
- **The dependency rule:** nothing in `crates/review-*` may depend on Neovim, Lua, a terminal UI library, or `jpr-review`. `crates/jpr-review/tests/dependency_rule.rs` enforces it. No new Cargo dependencies and no `unsafe` code (`unsafe_code = "forbid"`) are allowed.
- Keep every function within **45 lines** (`AGENTS.md`), in both Rust and Lua, and keep `.rs` production code well below 400 lines per file (`docs/rules/rust.md`).
- **Never use em dashes** in code comments, docstrings, strings, or documentation (`AGENTS.md`): use a colon (`:`) or a short hyphen (` - `).
- Follow `AGENTS.md` naming rules: `create_*` for object/struct builders, `build_*` for string/primitive builders, `*_from_*` when building from seed data, `*_to_*` for conversions, auxiliary verbs on booleans (`is_*`, `has_*`, `can_*`), and descriptive nouns instead of `val`, `next`, `prev`, or `n`.
- Every public Rust item gets a `///` doc comment, and every exported Lua function gets a `---` docstring.
- **High-risk tasks** (`super-wrapper` rules): Task 4 (`local.json` v1, `session.json` v3, `rounds.jsonl`, and `local.lock` concurrent fallback writer), Task 5 (`ReviewSession` local thread lifecycle, sync preservation, and promotion), Task 8 (`review-rpc` Unix socket server and concurrent event flushing), and Task 9 (`jpr-review` socket/fallback CLI subcommands and untrusted agent inputs). Run a task-level review (`pro` tier) after unit reviews pass on each high-risk task.
- **Mandatory post-implementation gates** (`AGENTS.md`): Task 15 updates `docs/` and bumps the workspace to `0.4.0`; Task 16 runs `/avandar-code-review`, commits fixes, runs the full `/diff-review` skill in Initial mode (never walkthrough-only), and copies `.difit/<stem>-walkthrough.md` to `docs/code-walkthroughs/2026-11-21_m4-local-comments-agent-loop.md` before final whole-branch review.

## File map

| Path | Responsibility |
| --- | --- |
| `Cargo.toml` | Workspace version bumped to `0.4.0` (Task 15) |
| `crates/review-model/src/agent.rs` | New: `AgentThreadState`, `AgentKind`, `PasteStyle`, `SubmitKey`, `AgentProfile`, `AgentLaunchPlan`, `AgentRoundKind`, `AgentRound`, `AgentDispatch`, `PrepassFinding`, `LocalAnchorUpdate` |
| `crates/review-model/src/thread.rs` | `Thread.agent`, `Thread.promoted_to`, `ThreadPreview.origin`, `ThreadPreview.agent`, `ThreadPreview.promoted_to` |
| `crates/review-model/src/view.rs` | `SessionView.local_unsent_count`, `Event::FilesChanged`, `Event::AgentRound` |
| `crates/review-core/src/reanchor.rs` | New, pure: `extract_snapshot_from_text` and `reanchor_thread_in_text` using `Anchor.snapshot` when worktree files change |
| `crates/review-core/src/agent.rs` | New, pure: `is_thread_dispatchable`, `select_dispatchable_threads`, `build_send_prompt_from_threads`, `build_prepass_prompt_from_pr` |
| `crates/review-core/src/guide.rs` | New, pure: `build_agent_guide` returning the full `jpr-review guide` contract text |
| `crates/review-core/src/ports.rs` | `LocalStoreState`, `SessionRecord` (`socket`, `agent_session_id`, `agent_kind`), `StoreSnapshot.local`, `ReviewStore::append_round` / `rounds`, `Workspace::list_changed_files_since` |
| `crates/review-core/src/fakes.rs`, `src/contract.rs` | `MemoryStore` round log, `FakeWorkspace` disk mutation tracking, expanded `check_review_store` / `check_review_store_rounds` |
| `crates/review-core/src/session/local.rs` | New: local `comment_with_origin`, `reply_local_thread`, `agent_reply` (refusing GitHub IDs), local `edit`/`delete`/`set_resolved`, `promote_thread` |
| `crates/review-core/src/session/agent_loop.rs` | New: `prepare_agent_launch`, `prepare_send`, `confirm_send`, `prepare_prepass`, `prepass_write`, `update_local_anchors`, `poll_worktree_files` |
| `crates/review-store-fs/src/lock.rs` | New: `with_local_lock` (`local.lock` via `create_new(true)` with stale-lock recovery and bounded retry) |
| `crates/review-store-fs/src/format.rs`, `src/lib.rs` | `SESSION_VERSION = 3`, `LOCAL_VERSION = 1` (`local.json`), `rounds.jsonl` append/load, `mutate_local_locked`, atomic save ordering |
| `crates/review-workspace-git/src/workspace.rs` | Lock-free `GIT_OPTIONAL_LOCKS=0` worktree dirty-file listing (`list_changed_files_since`) for background file-change detection |
| `crates/review-rpc/src/socket.rs` | New: Unix domain socket listener (`serve_unix_socket`) sharing session + stdout event drain with `serve` |
| `crates/review-rpc/src/params.rs`, `src/protocol.rs`, `src/server.rs`, `src/server/agent.rs` | `PROTOCOL_VERSION = 4`, new RPC handlers (`comment` origin, `agentReply`, `promoteThread`, `prepareAgentLaunch`, `prepareSend`, `confirmSend`, `preparePrepass`, `prepassWrite`, `updateLocalAnchors`), poller file-watch tick |
| `crates/jpr-review/src/cli.rs`, `src/commands/{guide,threads,reply,prepass_write,socket_client}.rs` | New CLI subcommands (`guide`, `threads`, `reply`, `prepass-write`), `serve` Unix socket setup + cleanup |
| `lua/jpr/init.lua`, `lua/jpr/rpc.lua`, `lua/jpr/session/init.lua`, `lua/jpr/session/comments.lua` | Protocol 4, `agent` / `claude_cmd` / `codex_cmd` / `agent_width` options, `JprThreadLocal`, `:Jpr agent` / `send` / `prepass`, `filesChanged` (`checktime`) |
| `lua/jpr/render/panel.lua`, `lua/jpr/render/threads.lua` | `local unsent N` count, local thread sign/badges (`[local · unsent]`, `[local · sent]`, `[local · answered]`, `[promoted]`), local popup footer hints |
| `lua/jpr/comments/compose.lua`, `lua/jpr/comments/popup.lua`, `lua/jpr/views/conversation.lua`, `lua/jpr/views/threads.lua`, `lua/jpr/views/diff/init.lua` | Destination toggle (`<C-g>`, `<C-s>`, `<M-s>`), popup `p` promote & `s` send, Conversation local PR comments, `BufWritePost` live extmark anchor reporting |
| `lua/jpr/agent.lua` | New: right-side terminal split (`JPR_SOCKET`, `JPR_PR`, Claude transcript check for `--resume` vs `--session-id`, Codex resume), sanitized bracketed paste + delayed submit key, `:Jpr send`, `:Jpr prepass` |
| `tests/lua/fixtures/fake_engine.sh`, `tests/lua/*_spec.lua` | Protocol 4 fake engine + headless Lua specs for local badges, compose toggle, promote/send, live re-anchor, and agent terminal |
| `docs/protocol.md`, `docs/architecture.md`, `docs/decisions.md`, `README.md`, `docs/code-walkthroughs/2026-11-21_m4-local-comments-agent-loop.md` | Protocol v4 docs, socket/fallback architecture, decisions, README commands, and archived diff-review walkthrough |

---

### Task 0: Worktree

- [ ] **Step 1: Create the worktree for `feat/local-comments-agent-loop`**

Load the `using-wt` skill first. From the main checkout:

```bash
cd "$(wt new feat local-comments-agent-loop)"
git branch --show-current
```

Expected: `feat/local-comments-agent-loop`.

- [ ] **Step 2: Restore the agent skills and run baseline checks**

```bash
just skills-install
just check
```

Expected: `skills-install` restores `.agents/skills` cleanly and `just check` passes on the clean baseline.

---

### Task 1: Domain types for local threads and the agent loop (`crates/review-model`)

**Files:**
- Create: `crates/review-model/src/agent.rs`
- Modify: `crates/review-model/src/lib.rs`
- Modify: `crates/review-model/src/thread.rs`
- Modify: `crates/review-model/src/thread/tests.rs`
- Modify: `crates/review-model/src/view.rs`
- Modify: `crates/review-core/src/fakes.rs`
- Modify: `crates/review-core/src/fakes/comments.rs`
- Modify: `crates/review-core/src/contract.rs`
- Modify: `crates/review-core/src/comments/tests.rs`
- Modify: `crates/review-core/src/presenter.rs`
- Modify: `crates/review-core/src/session/comments/helpers.rs`
- Modify: `crates/review-diff/src/overlay.rs`
- Modify: `crates/review-diff/src/stream/tests.rs`
- Modify: `crates/review-forge-github/src/graphql.rs`
- Modify: `crates/review-store-fs/src/format/tests.rs`

Add the pure serde types for local thread state, promotion links, agent profiles, launch plans, dispatches, rounds, pre-pass findings, anchor updates, `SessionView.local_unsent_count`, and the `FilesChanged` / `AgentRound` events.

- [ ] **Step 1: Write failing unit tests in `crates/review-model/src/agent.rs`, `thread/tests.rs`, and `view.rs`**

Create `crates/review-model/src/agent.rs` starting with its `#[cfg(test)]` module:

```rust
//! Agent profiles, local thread delivery state, dispatch batches, rounds, and
//! pre-pass inputs. Pure data: no IO and no terminal or editor types.

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::Anchor;

    #[test]
    fn agent_thread_state_serializes_with_state_tag() {
        assert_eq!(
            serde_json::to_value(AgentThreadState::Unsent).unwrap(),
            json!({ "state": "unsent" })
        );
        assert_eq!(
            serde_json::to_value(AgentThreadState::Sent { round: 3 }).unwrap(),
            json!({ "state": "sent", "round": 3 })
        );
        assert_eq!(
            serde_json::to_value(AgentThreadState::Answered).unwrap(),
            json!({ "state": "answered" })
        );
    }

    #[test]
    fn agent_profile_matches_claude_and_codex_submit_conventions() {
        let claude = AgentProfile::from_kind(AgentKind::Claude);
        assert_eq!(claude.paste_style, PasteStyle::Bracketed);
        assert_eq!(claude.submit_key, SubmitKey::Enter);
        assert_eq!(claude.submit_delay_ms, 200);

        let codex = AgentProfile::from_kind(AgentKind::Codex);
        assert_eq!(codex.submit_key, SubmitKey::Tab);
        assert_eq!(AgentKind::parse("claude"), Some(AgentKind::Claude));
        assert_eq!(AgentKind::parse("codex"), Some(AgentKind::Codex));
        assert_eq!(AgentKind::parse("other"), None);
    }

    #[test]
    fn prepass_finding_and_round_use_camel_case() {
        let finding: PrepassFinding = serde_json::from_value(json!({
            "anchor": Anchor::line("src/lib.rs", 12),
            "body": "[high] Missing bounds check.",
        }))
        .unwrap();
        assert_eq!(finding.anchor.start, Some(12));
        assert_eq!(finding.author, None);

        let round = AgentRound {
            round: 1,
            kind: AgentRoundKind::Send,
            thread_ids: vec!["loc-1".into()],
            prompt: "Run jpr-review guide".into(),
            sent_at: 42,
        };
        let encoded = serde_json::to_value(&round).unwrap();
        assert_eq!(encoded["threadIds"], json!(["loc-1"]));
        assert_eq!(encoded["sentAt"], 42);
    }
}
```

In `crates/review-model/src/thread/tests.rs`, add a test verifying `Thread.agent` and `Thread.promoted_to` propagate into `ThreadPreview`:

```rust
#[test]
fn local_thread_preview_carries_origin_agent_state_and_promotion() {
    let thread = Thread {
        id: "loc-1".into(),
        origin: Origin::Local,
        anchor: Anchor::line("src/lib.rs", 8),
        state: ThreadState::Open,
        outdated: false,
        messages: vec![Message::create_with_sync(
            "loc-m-1",
            "reviewer",
            "Should we extract a helper here?",
            "2026-11-21T00:00:00Z",
            None,
        )],
        agent: Some(crate::AgentThreadState::Sent { round: 2 }),
        promoted_to: Some("PRRT_99".into()),
    };
    let preview = create_thread_preview_from_thread(&thread, 8);
    assert_eq!(preview.kind, MarkerKind::Local);
    assert_eq!(preview.origin, Origin::Local);
    assert_eq!(preview.agent, Some(crate::AgentThreadState::Sent { round: 2 }));
    assert_eq!(preview.promoted_to.as_deref(), Some("PRRT_99"));
}
```

In `crates/review-model/src/view.rs`, extend `events_are_tagged_by_type_and_views_use_camel_case` to assert `localUnsentCount`, `Event::FilesChanged`, and `Event::AgentRound` serialize with `"type": "filesChanged"` and `"type": "agentRound"`.

- [ ] **Step 2: Run `cargo test -p review-model` to confirm failure**

Add `mod agent;` to `crates/review-model/src/lib.rs` and run:

```bash
cargo test -p review-model
```

Expected: FAIL (`AgentThreadState`, `AgentKind`, `AgentProfile`, `Thread.agent`, `SessionView.local_unsent_count` missing).

- [ ] **Step 3: Implement `crates/review-model/src/agent.rs` and update `thread.rs`, `view.rs`, `lib.rs`, and workspace `Thread` literals**

Put these types above `#[cfg(test)]` in `crates/review-model/src/agent.rs`:

```rust
use serde::{Deserialize, Serialize};

use crate::Anchor;

/// Delay in milliseconds between bracketed paste and the submit keystroke, so
/// interactive agent TUIs finish ingesting pasted text before submitting.
pub const DEFAULT_SUBMIT_DELAY_MS: u64 = 200;

/// Delivery status of a local thread in the reviewer-agent loop.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum AgentThreadState {
    /// Waiting to be sent to the agent (`:Jpr send` or popup `s`).
    Unsent,
    /// Pasted into the agent panel in `round`, awaiting `jpr-review reply`.
    Sent {
        /// 1-based dispatch round number recorded in `rounds.jsonl`.
        round: u64,
    },
    /// Latest message in the thread is the agent's reply.
    Answered,
}

/// Supported interactive coding-agent CLI kinds.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentKind {
    /// Claude Code (`claude`).
    #[default]
    Claude,
    /// OpenAI Codex (`codex`).
    Codex,
}

impl AgentKind {
    /// Parses `"claude"` or `"codex"`, returning `None` for unknown names.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "claude" => Some(Self::Claude),
            "codex" => Some(Self::Codex),
            _ => None,
        }
    }

    /// Canonical lowercase identifier (`"claude"` or `"codex"`).
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }
}

/// How a frontend wraps multi-line prompt text when writing to an agent PTY.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PasteStyle {
    /// Wrap payload in `\x1b[200~...\x1b[201~` after stripping raw ESC bytes.
    Bracketed,
}

/// Keystroke sent after `submit_delay_ms` to submit a pasted prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SubmitKey {
    /// Carriage return (`\r`), used by Claude Code.
    Enter,
    /// Horizontal tab (`\t`), used by Codex.
    Tab,
}

/// Strategy describing how a frontend delivers prompts to a chosen [`AgentKind`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentProfile {
    /// Selected agent CLI.
    pub kind: AgentKind,
    /// Paste framing mode.
    pub paste_style: PasteStyle,
    /// Trailing submit keystroke.
    pub submit_key: SubmitKey,
    /// Milliseconds to wait between paste completion and `submit_key`.
    pub submit_delay_ms: u64,
}

impl AgentProfile {
    /// Standard delivery profile for `kind`.
    #[must_use]
    pub const fn from_kind(kind: AgentKind) -> Self {
        let submit_key = match kind {
            AgentKind::Claude => SubmitKey::Enter,
            AgentKind::Codex => SubmitKey::Tab,
        };
        Self {
            kind,
            paste_style: PasteStyle::Bracketed,
            submit_key,
            submit_delay_ms: DEFAULT_SUBMIT_DELAY_MS,
        }
    }
}

/// Session identity and profile returned before opening or resuming an agent
/// terminal split.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentLaunchPlan {
    /// Agent CLI kind stored for this pull request.
    pub kind: AgentKind,
    /// Stable UUID-formatted session identifier persisted in `session.json`.
    pub session_id: String,
    /// Whether this PR already launched an agent session earlier (`true` when
    /// `session.json` already held `session_id` for `kind`).
    pub is_resume: bool,
    /// Unix socket path exposed to the agent as `JPR_SOCKET`, when serving.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub socket: Option<String>,
    /// Delivery profile for pasting prompts into the terminal.
    pub profile: AgentProfile,
}

/// Whether an agent round sent reviewer comments or requested a PR pre-pass.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentRoundKind {
    /// Batch or single-thread dispatch of reviewer local comments.
    Send,
    /// Pre-pass review request (`:Jpr prepass`).
    Prepass,
}

/// One persisted agent send entry in `rounds.jsonl`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentRound {
    /// 1-based monotonic round number for this pull request.
    pub round: u64,
    /// Dispatch kind (`send` or `prepass`).
    pub kind: AgentRoundKind,
    /// Local thread IDs included in this round (`Vec::new()` for `prepass`).
    pub thread_ids: Vec<String>,
    /// Exact prompt text sent to the agent.
    pub prompt: String,
    /// Unix timestamp in seconds when delivery was confirmed.
    pub sent_at: u64,
}

/// Prepared prompt and delivery instructions returned before the frontend
/// pastes into the agent terminal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentDispatch {
    /// Candidate 1-based round number to pass back to `confirmSend`.
    pub round: u64,
    /// Dispatch kind (`send` or `prepass`).
    pub kind: AgentRoundKind,
    /// Local thread IDs covered by this dispatch.
    pub thread_ids: Vec<String>,
    /// Formatted prompt text ready for bracketed paste.
    pub prompt: String,
    /// Delivery profile for the configured agent.
    pub profile: AgentProfile,
}

/// One agent-authored finding supplied to `jpr-review prepass-write`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepassFinding {
    /// Where the finding attaches (`line`, `range`, `file`, or `pr`).
    pub anchor: Anchor,
    /// Finding body (for example `[high] Unbounded allocation on untrusted length`).
    pub body: String,
    /// Optional author label; defaults to `"agent"` when omitted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
}

/// Live buffer extmark line span reported on `:write` for an open local thread.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalAnchorUpdate {
    /// Local thread ID (`loc-...`).
    pub thread_id: String,
    /// Updated 1-based start line in the saved buffer.
    pub start: u64,
    /// Updated 1-based end line in the saved buffer.
    pub end: u64,
}
```

Update `crates/review-model/src/thread.rs`:
- Add `#[serde(default, skip_serializing_if = "Option::is_none")] pub agent: Option<crate::AgentThreadState>` and `#[serde(default, skip_serializing_if = "Option::is_none")] pub promoted_to: Option<String>` to `Thread`.
- Add `pub origin: Origin`, `#[serde(default, skip_serializing_if = "Option::is_none")] pub agent: Option<crate::AgentThreadState>`, and `#[serde(default, skip_serializing_if = "Option::is_none")] pub promoted_to: Option<String>` to `ThreadPreview`, copying `thread.origin`, `thread.agent`, and `thread.promoted_to.clone()` inside `create_thread_preview_from_thread`.

Update `crates/review-model/src/view.rs`:
- Add `#[serde(default)] pub local_unsent_count: usize` to `SessionView`.
- Add `FilesChanged { paths: Vec<String>, view: Box<SessionView> }` and `AgentRound { round: crate::AgentRound, view: Box<SessionView> }` to `Event`.

Re-export all new types from `crates/review-model/src/lib.rs`, add `agent: None, promoted_to: None` to the existing GitHub `Thread { ... }` literals across `crates/`, and set `local_unsent_count: 0` in `presenter::session_view` for now (Task 5 computes the live count).

- [ ] **Step 4: Run workspace Rust tests**

```bash
cargo test --workspace --all-features
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates
git commit -m "feat(model): add local thread agent states, dispatch models, and protocol v4 events"
```

---

### Task 2: Pure local re-anchoring, agent prompt builders, and `guide` contract (`crates/review-core`)

**Files:**
- Create: `crates/review-core/src/reanchor.rs`
- Create: `crates/review-core/src/agent.rs`
- Create: `crates/review-core/src/guide.rs`
- Modify: `crates/review-core/src/lib.rs`

Implement three pure, zero-IO modules in `review-core`:
1. `reanchor.rs`: extracts `Anchor.snapshot` from file text and re-anchors `Origin::Local` `Side::Right` `Line`/`Range` threads when lines shift above or around them (searching exact multi-line slice matches closest to the previous `start` line, or trimmed matches if indentation changed, leaving `outdated = true` only when the anchored lines vanished).
2. `agent.rs`: ports `dif`'s `inject/dispatch.rs` and `inject/prompt.rs` eligibility rules (open `Origin::Local` threads with `agent == Some(AgentThreadState::Unsent)` whose last message has `viewer_did_author == true`) and single-vs-numbered batch prompt formatting (`file:L7`, `file:L7-9`, `file`, or `PR`, prior thread messages indented under `Thread so far:`, latest message, and footer instructing the agent to run `jpr-review guide` first and reply with `jpr-review reply <thread-id> --body "..."`), plus `build_prepass_prompt_from_pr`.
3. `guide.rs`: builds the `jpr-review guide` text adapted from `diff-review`'s Continue mode, PR-review mode, `reply-style.md`, and `review-comment-style.md` (question vs change classification, commit in PR worktree, reply on every thread via `jpr-review reply <thread-id> --body ...`, default `Done. (<sha>)`, never push and never touch GitHub, and pre-pass `jpr-review prepass-write` JSON schema).

- [ ] **Step 1: Write failing unit tests in `reanchor.rs`, `agent.rs`, and `guide.rs`**

Create `crates/review-core/src/reanchor.rs` with tests first:

```rust
//! Snapshot capture and line-shift re-anchoring for local threads.

#[cfg(test)]
mod tests {
    use review_model::{Anchor, Origin, Side, Thread, ThreadState};

    use super::*;

    fn create_local_line_thread(start: u64, end: u64, snapshot: &str) -> Thread {
        let mut anchor = Anchor::range("src/lib.rs", Side::Right, start, end);
        anchor.snapshot = Some(snapshot.to_owned());
        Thread {
            id: "loc-1".into(),
            origin: Origin::Local,
            anchor,
            state: ThreadState::Open,
            outdated: false,
            messages: Vec::new(),
            agent: None,
            promoted_to: None,
        }
    }

    #[test]
    fn captures_inclusive_line_slice_snapshot() {
        let text = "fn a() {}\nlet count = 1;\nlet total = count + 2;\n";
        let anchor = Anchor::range("src/lib.rs", Side::Right, 2, 3);
        assert_eq!(
            extract_snapshot_from_text(text, &anchor).as_deref(),
            Some("let count = 1;\nlet total = count + 2;")
        );
    }

    #[test]
    fn shifts_anchor_down_when_lines_are_inserted_above() {
        let updated_text = "// header\n// second\nfn a() {}\nlet count = 1;\nlet total = count + 2;\n";
        let mut thread = create_local_line_thread(2, 3, "let count = 1;\nlet total = count + 2;");
        let did_change = reanchor_thread_in_text(&mut thread, updated_text);
        assert!(did_change);
        assert_eq!(thread.anchor.start, Some(4));
        assert_eq!(thread.anchor.end, Some(5));
        assert!(!thread.outdated);
    }

    #[test]
    fn picks_closest_duplicate_match_and_marks_deleted_snapshot_outdated() {
        let duplicate_text = "return Ok(());\nfn mid() {}\nreturn Ok(());\n";
        let mut thread = create_local_line_thread(3, 3, "return Ok(());");
        assert!(!reanchor_thread_in_text(&mut thread, duplicate_text));
        assert_eq!(thread.anchor.start, Some(3));

        let removed_text = "fn mid() {}\n";
        assert!(reanchor_thread_in_text(&mut thread, removed_text));
        assert!(thread.outdated);
    }
}
```

Create `crates/review-core/src/agent.rs` with tests first:

```rust
//! Eligibility filtering and prompt builders for the interactive agent loop.

#[cfg(test)]
mod tests {
    use review_model::{
        AgentThreadState, Anchor, Message, Origin, PullRequest, Side, Thread, ThreadState,
    };

    use super::*;
    use crate::fakes::sample_pr;

    fn create_local_thread(
        id: &str,
        anchor: Anchor,
        state: ThreadState,
        agent: AgentThreadState,
        messages: Vec<Message>,
    ) -> Thread {
        Thread {
            id: id.into(),
            origin: Origin::Local,
            anchor,
            state,
            outdated: false,
            messages,
            agent: Some(agent),
            promoted_to: None,
        }
    }

    fn create_message(author: &str, body: &str, viewer_did_author: bool) -> Message {
        let mut message = Message::create_with_sync("m", author, body, "2026-11-21T00:00:00Z", None);
        message.viewer_did_author = viewer_did_author;
        message
    }

    #[test]
    fn selects_only_open_unsent_local_threads_ending_with_reviewer_message() {
        let eligible = create_local_thread(
            "loc-1",
            Anchor::line("src/a.rs", 7),
            ThreadState::Open,
            AgentThreadState::Unsent,
            vec![create_message("pablo", "Why clone here?", true)],
        );
        let answered = create_local_thread(
            "loc-2",
            Anchor::line("src/a.rs", 9),
            ThreadState::Open,
            AgentThreadState::Answered,
            vec![
                create_message("pablo", "Why?", true),
                create_message("agent", "Needed for Send.", false),
            ],
        );
        let resolved = create_local_thread(
            "loc-3",
            Anchor::line("src/a.rs", 12),
            ThreadState::Resolved,
            AgentThreadState::Unsent,
            vec![create_message("pablo", "Skip", true)],
        );
        let threads = vec![eligible, answered, resolved];
        let selected = select_dispatchable_threads(&threads, None);
        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0].id, "loc-1");
    }

    #[test]
    fn builds_numbered_batch_prompt_with_history_anchors_and_guide_command() {
        let first = create_local_thread(
            "loc-1",
            Anchor::range("src/a.rs", Side::Right, 7, 9),
            ThreadState::Open,
            AgentThreadState::Unsent,
            vec![
                create_message("pablo", "Extract this?", true),
                create_message("agent", "Done in abc1234.", false),
                create_message("pablo", "Also rename the parameter.", true),
            ],
        );
        let second = create_local_thread(
            "loc-2",
            Anchor::pr(),
            ThreadState::Open,
            AgentThreadState::Unsent,
            vec![create_message("pablo", "Summarize migration risk.", true)],
        );
        let prompt = build_send_prompt_from_threads(&sample_pr(), &[&first, &second]);
        assert!(prompt.contains("jpr-review guide"), "{prompt}");
        assert!(prompt.contains("1. [loc-1] src/a.rs:L7-9"), "{prompt}");
        assert!(prompt.contains("Thread so far:"), "{prompt}");
        assert!(prompt.contains("New comment: Also rename the parameter."), "{prompt}");
        assert!(prompt.contains("2. [loc-2] PR"), "{prompt}");
        assert!(prompt.contains("jpr-review reply <thread-id> --body"), "{prompt}");
    }

    #[test]
    fn prepass_prompt_references_guide_and_prepass_write() {
        let PullRequest { number, .. } = sample_pr();
        let prompt = build_prepass_prompt_from_pr(&sample_pr());
        assert!(prompt.contains(&format!("PR #{number}")), "{prompt}");
        assert!(prompt.contains("jpr-review guide"), "{prompt}");
        assert!(prompt.contains("jpr-review prepass-write"), "{prompt}");
    }
}
```

Create `crates/review-core/src/guide.rs` with tests first:

```rust
//! The agent contract printed by `jpr-review guide`.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guide_states_classification_reply_commit_prepass_and_github_prohibition() {
        let guide = build_agent_guide();
        assert!(guide.contains("jpr-review reply <thread-id> --body"), "{guide}");
        assert!(guide.contains("Done."), "{guide}");
        assert!(guide.contains("Never push"), "{guide}");
        assert!(guide.contains("Never touch GitHub"), "{guide}");
        assert!(guide.contains("jpr-review prepass-write"), "{guide}");
        assert!(!guide.contains('\u{2014}'), "guide must not contain em dashes");
    }
}
```

- [ ] **Step 2: Run `cargo test -p review-core` to confirm failure**

Declare `pub mod agent; pub mod guide; pub(crate) mod reanchor;` in `crates/review-core/src/lib.rs`, then run:

```bash
cargo test -p review-core
```

Expected: FAIL (missing functions in `reanchor`, `agent`, and `guide`).

- [ ] **Step 3: Implement `reanchor.rs`, `agent.rs`, and `guide.rs`**

In `crates/review-core/src/reanchor.rs` (keeping every function `<= 45` lines):

```rust
use review_model::{Anchor, AnchorKind, Origin, Side, Thread};

/// Extracts the exact lines covered by `anchor` (`start..=end`, 1-based) from
/// `text`, returning `None` for non-line anchors or out-of-bounds spans.
#[must_use]
pub(crate) fn extract_snapshot_from_text(text: &str, anchor: &Anchor) -> Option<String> {
    if !matches!(anchor.kind, AnchorKind::Line | AnchorKind::Range) {
        return None;
    }
    let start = usize::try_from(anchor.start?).ok()?;
    let end = usize::try_from(anchor.end?).ok()?;
    if start == 0 || end < start {
        return None;
    }
    let lines: Vec<&str> = text.lines().collect();
    let slice = lines.get((start - 1)..end)?;
    Some(slice.join("\n"))
}

/// Re-anchors a local `Side::Right` line or range thread against `updated_text`
/// using its saved `snapshot`. Returns `true` when `anchor` or `outdated` changed.
pub(crate) fn reanchor_thread_in_text(thread: &mut Thread, updated_text: &str) -> bool {
    if thread.origin != Origin::Local
        || thread.anchor.side != Side::Right
        || !matches!(thread.anchor.kind, AnchorKind::Line | AnchorKind::Range)
    {
        return false;
    }
    let Some(snapshot) = thread.anchor.snapshot.as_deref() else {
        return false;
    };
    if snapshot.is_empty() {
        return false;
    }
    let current_start = usize::try_from(thread.anchor.start.unwrap_or(1)).unwrap_or(1);
    let file_lines: Vec<&str> = updated_text.lines().collect();
    let target_lines: Vec<&str> = snapshot.lines().collect();
    let matched_start = find_closest_window(&file_lines, &target_lines, current_start, false)
        .or_else(|| find_closest_window(&file_lines, &target_lines, current_start, true));
    let Some(new_start_index) = matched_start else {
        let was_outdated = thread.outdated;
        thread.outdated = true;
        return !was_outdated;
    };
    let new_start = (new_start_index + 1) as u64;
    let new_end = (new_start_index + target_lines.len()) as u64;
    let changed =
        thread.anchor.start != Some(new_start) || thread.anchor.end != Some(new_end) || thread.outdated;
    thread.anchor.start = Some(new_start);
    thread.anchor.end = Some(new_end);
    thread.outdated = false;
    changed
}

fn find_closest_window(
    haystack: &[&str],
    needle: &[&str],
    preferred_one_based: usize,
    use_trimmed: bool,
) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    let preferred_index = preferred_one_based.saturating_sub(1);
    (0..=(haystack.len() - needle.len()))
        .filter(|&start| windows_equal(&haystack[start..(start + needle.len())], needle, use_trimmed))
        .min_by_key(|&start| start.abs_diff(preferred_index))
}

fn windows_equal(left: &[&str], right: &[&str], use_trimmed: bool) -> bool {
    left.iter().zip(right).all(|(left_line, right_line)| {
        if use_trimmed {
            left_line.trim() == right_line.trim()
        } else {
            left_line == right_line
        }
    })
}
```

In `crates/review-core/src/agent.rs`:

```rust
use std::fmt::Write;

use review_model::{
    AgentThreadState, Anchor, AnchorKind, Origin, PullRequest, Side, Thread, ThreadState,
};

/// Whether `thread` should be sent on `:Jpr send`: local, open, `Unsent`, and
/// ending with a reviewer-authored message.
#[must_use]
pub fn is_thread_dispatchable(thread: &Thread) -> bool {
    thread.origin == Origin::Local
        && thread.state == ThreadState::Open
        && thread.agent == Some(AgentThreadState::Unsent)
        && thread
            .messages
            .last()
            .is_some_and(|message| message.viewer_did_author)
}

/// Selects dispatchable local threads, or only `only_thread_id` when given
/// (for popup `s`, allowing an open local thread with a reviewer message to be
/// sent or re-sent on demand).
#[must_use]
pub fn select_dispatchable_threads<'a>(
    threads: &'a [Thread],
    only_thread_id: Option<&str>,
) -> Vec<&'a Thread> {
    if let Some(target_id) = only_thread_id {
        return threads
            .iter()
            .filter(|thread| {
                thread.id == target_id
                    && thread.origin == Origin::Local
                    && thread.state == ThreadState::Open
                    && !thread.messages.is_empty()
            })
            .collect();
    }
    threads
        .iter()
        .filter(|thread| is_thread_dispatchable(thread))
        .collect()
}

/// Formats an [`Anchor`] as `file:L7`, `file:L7-9` (with ` (base)` for `LEFT`),
/// `file`, or `PR`.
#[must_use]
pub fn build_anchor_label_from_anchor(anchor: &Anchor) -> String {
    let side_suffix = if anchor.side == Side::Left { " (base)" } else { "" };
    match anchor.kind {
        AnchorKind::Pr => "PR".to_owned(),
        AnchorKind::File => anchor.file.clone().unwrap_or_else(|| "file".to_owned()),
        AnchorKind::Line => format!(
            "{}:L{}{side_suffix}",
            anchor.file.as_deref().unwrap_or("file"),
            anchor.end.or(anchor.start).unwrap_or(1)
        ),
        AnchorKind::Range => format!(
            "{}:L{}-{}{side_suffix}",
            anchor.file.as_deref().unwrap_or("file"),
            anchor.start.unwrap_or(1),
            anchor.end.or(anchor.start).unwrap_or(1)
        ),
    }
}

/// Builds the single-item or numbered-batch prompt for `threads` on `pr`.
#[must_use]
pub fn build_send_prompt_from_threads(pr: &PullRequest, threads: &[&Thread]) -> String {
    let mut output = String::new();
    let count = threads.len();
    let noun = if count == 1 { "comment" } else { "comments" };
    let _ = writeln!(
        output,
        "Address {count} local review {noun} on PR #{} ({}/{}).",
        pr.number, pr.owner, pr.repo
    );
    output.push_str("First run `jpr-review guide` and follow every rule in that contract.\n\n");
    for (index, thread) in threads.iter().enumerate() {
        append_thread_item(&mut output, index + 1, thread);
    }
    output.push_str(
        "Reply to every item above with `jpr-review reply <thread-id> --body \"...\"`. Never push and never touch GitHub.",
    );
    output
}

fn append_thread_item(output: &mut String, item_number: usize, thread: &Thread) {
    let label = build_anchor_label_from_anchor(&thread.anchor);
    let _ = writeln!(output, "{item_number}. [{}] {label}", thread.id);
    if let Some(snapshot) = thread.anchor.snapshot.as_deref()
        && !snapshot.is_empty()
    {
        for code_line in snapshot.lines() {
            let _ = writeln!(output, "   > {code_line}");
        }
    }
    if thread.messages.len() > 1 {
        output.push_str("   Thread so far:\n");
        for prior in &thread.messages[..thread.messages.len() - 1] {
            let _ = writeln!(output, "     @{}: {}", prior.author, prior.body.trim());
        }
    }
    if let Some(latest) = thread.messages.last() {
        let _ = writeln!(output, "   New comment: {}\n", latest.body.trim());
    }
}

/// Builds the `:Jpr prepass` prompt instructing the agent to critique `pr` and
/// record findings as local threads through `jpr-review prepass-write`.
#[must_use]
pub fn build_prepass_prompt_from_pr(pr: &PullRequest) -> String {
    format!(
        "Run a local pre-pass code review of PR #{} ({}/{}: {:?}, base `{}` -> head `{}`).\n\
         1. Run `jpr-review guide` first and follow the Pre-pass section.\n\
         2. Inspect the diff against `{}` in this worktree and verify surrounding callers before flagging anything.\n\
         3. Write only high-signal findings (`[critical]`, `[high]`, `[medium]`, `[low]`, or `[nit]`) as JSON to `jpr-review prepass-write`.\n\
         4. Never push and never touch GitHub.",
        pr.number, pr.owner, pr.repo, pr.title, pr.base_ref, pr.head_ref, pr.base_sha
    )
}
```

In `crates/review-core/src/guide.rs`, implement `pub fn build_agent_guide() -> &'static str` returning the crisp markdown contract covering:
1. **Role & Hard Boundaries:** You are working inside the checked-out PR worktree. Never push (`git push` is forbidden) and never touch GitHub (`gh pr comment`, `gh pr review`, `gh api` mutations are forbidden; `jpr-review reply` refuses GitHub thread IDs).
2. **Handling Reviewer Comments (`:Jpr send`):**
   - Classify each numbered `[loc-...]` item as either a **Question** (answer directly with file/symbol references; make no code edits) or a **Change Request** (make the minimal focused edit in the worktree, run relevant checks/tests, and create a local git commit).
   - Reply to **every** item using `jpr-review reply <thread-id> --body "<reply>"` (using `$JPR_SOCKET` automatically when set).
   - Reply style: direct, matter-of-fact, 1-3 sentences. Default reply for a completed change is `Done. (<short-sha>)` plus one short sentence only if non-obvious behavior changed.
3. **Running a Pre-pass Review (`:Jpr prepass`):**
   - Inspect `git diff <base>..HEAD` and read surrounding context before flagging anything.
   - Prefix each finding body with `[critical]`, `[high]`, `[medium]`, `[low]`, or `[nit]`, state the concrete failure mode or trade-off in 1-4 sentences, and pass a JSON array on stdin (`jpr-review prepass-write <<'EOF' ... EOF`) with schema `[{"anchor": {"file": "path/to/file", "kind": "line"|"range"|"file"|"pr", "side": "RIGHT"|"LEFT", "start": 10, "end": 12}, "body": "[high] ..."}]` (if zero issues stand up to verification, write `[]` and say so briefly).

Re-export `build_agent_guide` from `crates/review-core/src/lib.rs`.

- [ ] **Step 4: Run `cargo test -p review-core`**

```bash
cargo test -p review-core
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-core
git commit -m "feat(core): add local snapshot re-anchoring, agent prompt builders, and guide contract"
```

---

### Task 3: Ports, fakes, and contract updates for local state, rounds, and worktree watching (`crates/review-core`)

**Files:**
- Modify: `crates/review-core/src/ports.rs`
- Modify: `crates/review-core/src/fakes.rs`
- Modify: `crates/review-core/src/fakes/workspace.rs`
- Modify: `crates/review-core/src/contract.rs`

Extend `SessionRecord`, `StoreSnapshot`, `ReviewStore`, and `Workspace` so `ReviewSession` can persist local threads (`LocalStoreState`), append/load `rounds.jsonl` (`ReviewStore::append_round`, `ReviewStore::rounds`), remember `socket` / `agent_session_id` / `agent_kind` in `session.json`, and inspect modified/untracked worktree file paths without touching git's index lock.

- [ ] **Step 1: Write failing contract tests in `crates/review-core/src/contract.rs`**

Add `pub fn check_review_store_rounds(store: &dyn ReviewStore)` in `crates/review-core/src/contract.rs` and call it from `the_memory_store_passes_the_contract` (Task 4 wires it into `check_review_store` once `FsStore` persists `local.json`, `session.json` v3, and `rounds.jsonl`):
- Verify `store.rounds()` starts empty, `store.append_round(&round_1)` and `store.append_round(&round_2)` append in order, and `store.rounds()` returns `[round_1, round_2]` intact even after a subsequent `store.save(&second)`.
- Also test `MemoryStore` round-tripping `session.socket`, `session.agent_session_id`, `session.agent_kind`, and `snapshot.local` (`LocalStoreState { next_local_id: 3, next_round: 2, threads: vec![local_thread] }`).

- [ ] **Step 2: Run `cargo test -p review-core` to confirm failure**

```bash
cargo test -p review-core
```

Expected: FAIL (`LocalStoreState`, `SessionRecord.socket`, `ReviewStore::append_round`, `ReviewStore::rounds` missing).

- [ ] **Step 3: Update `ports.rs`, `fakes.rs`, `fakes/workspace.rs`, and `contract.rs`**

In `crates/review-core/src/ports.rs`:
- Add to `SessionRecord`:
  ```rust
  /// Unix domain socket path where the running daemon accepts CLI requests.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub socket: Option<String>,
  /// Stable session identifier for resuming Claude Code or Codex on this PR.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub agent_session_id: Option<String>,
  /// Agent kind (`claude` or `codex`) associated with `agent_session_id`.
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub agent_kind: Option<review_model::AgentKind>,
  ```
- Define `LocalStoreState`:
  ```rust
  /// Local-only threads and counters persisted in `local.json`.
  #[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
  #[serde(rename_all = "camelCase", default)]
  pub struct LocalStoreState {
      /// Next numeric suffix for `loc-<id>` threads and `loc-m-<id>` messages.
      pub next_local_id: u64,
      /// Next 1-based dispatch round counter.
      pub next_round: u64,
      /// Every `Origin::Local` thread on this pull request.
      pub threads: Vec<Thread>,
  }
  ```
- Add `pub local: LocalStoreState` to `StoreSnapshot`.
- Add `append_round(&self, round: &review_model::AgentRound) -> Result<()>` and `rounds(&self) -> Result<Vec<review_model::AgentRound>>` to `ReviewStore`.
- Add `fn list_changed_files_since(&self, commit: &str) -> Result<Vec<String>>` to `Workspace` (returning sorted repo-relative paths whose worktree content differs from `commit` or are untracked, so `ReviewSession` can detect external edits by the agent).

Update `MemoryStore` in `crates/review-core/src/fakes.rs` to hold `(StoreSnapshot, Vec<AgentRound>)` inside its `Arc<Mutex<...>>` and implement `append_round` and `rounds`.

Update `FakeWorkspace` in `crates/review-core/src/fakes/workspace.rs` to implement `list_changed_files_since` by comparing `disk` against `commits.get(commit)` and returning sorted differing paths, plus expose `pub fn write_disk(&self, path: &str, bytes: impl Into<Vec<u8>>)` so session tests can simulate agent edits on disk.

Add default pass-through methods on `FsStore` (`append_round` -> `Ok(())`, `rounds` -> `Ok(Vec::new())`, replaced in Task 4) and `GitWorkspace` (`list_changed_files_since` -> `Ok(Vec::new())`, replaced in Task 7) so `just check` stays green across the entire workspace at the end of Task 3.

- [ ] **Step 4: Run `cargo test --workspace --all-features`**

Run:

```bash
cargo test --workspace --all-features
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-core crates/review-store-fs crates/review-workspace-git
git commit -m "feat(core): extend store and workspace ports for local threads, rounds, and file watching"
```

---

### Task 4: `local.json` v1, `session.json` v3, `rounds.jsonl`, and locked fallback writes (`crates/review-store-fs`) `[HIGH-RISK]`

**Files:**
- Create: `crates/review-store-fs/src/lock.rs`
- Modify: `crates/review-store-fs/src/format.rs`
- Modify: `crates/review-store-fs/src/format/tests.rs`
- Modify: `crates/review-store-fs/src/lib.rs`
- Modify: `crates/review-core/src/contract.rs`

Persist `local.json` (version 1), `session.json` (version 3, backward-compatible with v1 and v2), `rounds.jsonl` (one JSON object per line), and `FsStore::mutate_local_locked` using an exclusive `local.lock` file (`OpenOptions::new().write(true).create_new(true)`) so `jpr-review reply` and `jpr-review prepass-write` safely update `local.json` when no daemon is running.

- [ ] **Step 1: Write failing round-trip, version-guard, JSONL, and concurrent-lock tests**

In `crates/review-core/src/contract.rs`, call `check_review_store_rounds(store)` from `check_review_store(store)` so `FsStore` must pass full `LocalStoreState`, `SessionRecord` v3, and `rounds.jsonl` round-trips.

In `crates/review-store-fs/src/format/tests.rs`, add tests verifying:
1. `session.json` v1 and v2 decode cleanly with `socket == None`, `agent_session_id == None`, `agent_kind == None`, and v3 encodes `"socket"`, `"agentSessionId"`, `"agentKind"`.
2. `local.json` v1 round-trips `LocalStoreState` (`nextLocalId`, `nextRound`, `threads` with `agent` and `promotedTo`) and refuses `version: 9`.

In `crates/review-store-fs/src/lib.rs` tests, add:
1. `rounds_jsonl_appends_one_json_line_per_round_and_ignores_blank_lines`.
2. `concurrent_locked_local_mutations_preserve_every_writer` spawning 4 threads that each run 25 `store.mutate_local_locked(|local| { local.next_local_id += 1; ... })` calls concurrently and asserting `local.next_local_id == 100`, `local.threads.len() == 100`, and no `local.lock` file remains afterward.

- [ ] **Step 2: Run `cargo test -p review-store-fs` to confirm failure**

```bash
cargo test -p review-store-fs
```

Expected: FAIL (`check_review_store` fails on `local`, `socket`, and `rounds`; `mutate_local_locked` missing).

- [ ] **Step 3: Implement `format.rs`, `lock.rs`, and `lib.rs` in `crates/review-store-fs`**

In `crates/review-store-fs/src/format.rs`:
- Bump `pub const SESSION_VERSION: u32 = 3;` (keeping `OLDEST_SESSION_VERSION = 1`). Add `socket`, `agent_session_id`, and `agent_kind` to `SessionFile`, `encode_session`, and `decode_session`.
- Add `pub const LOCAL_VERSION: u32 = 1;` and:
  ```rust
  #[derive(Serialize, Deserialize, Default)]
  #[serde(rename_all = "camelCase", default)]
  struct LocalFile {
      version: u32,
      #[serde(flatten)]
      local: LocalStoreState,
  }

  /// `local.json`'s bytes for `local`.
  pub fn encode_local(local: &LocalStoreState) -> Result<Vec<u8>> {
      encode(&LocalFile {
          version: LOCAL_VERSION,
          local: local.clone(),
      })
  }

  /// `local.json`'s state.
  pub fn decode_local(bytes: &[u8]) -> Result<LocalStoreState> {
      let file: LocalFile = decode(bytes, LOCAL_VERSION, LOCAL_VERSION)?;
      Ok(file.local)
  }
  ```

Create `crates/review-store-fs/src/lock.rs` (pure safe Rust, zero `unsafe`, every function `<= 45` lines):

```rust
//! Advisory lock file (`local.lock`) for fallback CLI writes to `local.json`
//! when no `jpr-review serve` daemon is running.

use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

/// Lock file name inside the pull request's state directory.
pub const LOCAL_LOCK_FILE: &str = "local.lock";

const LOCK_TIMEOUT: Duration = Duration::from_secs(5);
const LOCK_POLL: Duration = Duration::from_millis(15);
const STALE_LOCK_AGE: Duration = Duration::from_secs(30);

struct LockGuard {
    path: PathBuf,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

/// Acquires `<dir>/local.lock` exclusively, runs `operation`, and removes the
/// lock file on return.
pub(crate) fn with_local_lock<T>(dir: &Path, operation: impl FnOnce() -> Result<T>) -> Result<T> {
    fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    let guard = acquire_lock(&dir.join(LOCAL_LOCK_FILE))?;
    let result = operation();
    drop(guard);
    result
}

fn acquire_lock(lock_path: &Path) -> Result<LockGuard> {
    let deadline = Instant::now() + LOCK_TIMEOUT;
    loop {
        match try_create_lock(lock_path) {
            Ok(guard) => return Ok(guard),
            Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                evict_stale_lock(lock_path);
                if Instant::now() >= deadline {
                    bail!(
                        "timed out waiting for {} (another jpr-review process is writing local state)",
                        lock_path.display()
                    );
                }
                thread::sleep(LOCK_POLL);
            }
            Err(error) => {
                return Err(error).with_context(|| format!("creating {}", lock_path.display()));
            }
        }
    }
}

fn try_create_lock(lock_path: &Path) -> std::io::Result<LockGuard> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(lock_path)?;
    let _ = writeln!(file, "{}", std::process::id());
    Ok(LockGuard {
        path: lock_path.to_path_buf(),
    })
}

fn evict_stale_lock(lock_path: &Path) {
    let is_stale = fs::metadata(lock_path)
        .and_then(|meta| meta.modified())
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|age| age > STALE_LOCK_AGE);
    if is_stale {
        let _ = fs::remove_file(lock_path);
    }
}
```

In `crates/review-store-fs/src/lib.rs`:
- Export `LOCAL_VERSION`, `pub const LOCAL_FILE: &str = "local.json";`, and `pub const ROUNDS_FILE: &str = "rounds.jsonl";`.
- Load `local` from `LOCAL_FILE` in `ReviewStore::load`, check `refuse_newer_file(&self.dir.join(LOCAL_FILE), LOCAL_VERSION)?` in `ReviewStore::save`, and write `[GITHUB_FILE, LOCAL_FILE, SESSION_FILE, VIEWED_FILE]` atomically (update `save_leaves_no_temporary_files` and `concurrent_saves_never_tear_a_file_or_leave_temporaries` expected file list to include `"local.json"`).
- Implement `append_round` (creating `self.dir`, serializing `round` as one compact JSON line + `\n`, opening `ROUNDS_FILE` with `create(true).append(true)`, `write_all`, `sync_data`) and `rounds` (returning `Ok(Vec::new())` when `ROUNDS_FILE` is absent, otherwise parsing each non-empty line with `serde_json::from_str` with file context).
- Add `pub fn mutate_local_locked<T>(&self, mutator: impl FnOnce(&mut LocalStoreState) -> Result<T>) -> Result<T>` on `FsStore`: acquires `lock::with_local_lock(&self.dir, || { refuse_newer_file(...)?; let mut local = load_file(&self.dir.join(LOCAL_FILE), format::decode_local)?.unwrap_or_default(); let out = mutator(&mut local)?; atomic::write_atomic(&self.dir, LOCAL_FILE, &format::encode_local(&local)?)?; Ok(out) })`.

- [ ] **Step 4: Run `cargo test --workspace --all-features`**

```bash
cargo test --workspace --all-features
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-core/src/contract.rs crates/review-store-fs
git commit -m "feat(store): persist local.json v1, session.json v3, rounds.jsonl, and locked fallback writes"
```

---

### Task 5: `ReviewSession` local threads, sync isolation, `agent_reply` guard, and promotion (`crates/review-core`) `[HIGH-RISK]`

**Files:**
- Create: `crates/review-core/src/session/local.rs`
- Modify: `crates/review-core/src/session/mod.rs`
- Modify: `crates/review-core/src/session/comments.rs`
- Modify: `crates/review-core/src/session/sync.rs`
- Modify: `crates/review-core/src/presenter.rs`

Keep local threads (`Origin::Local`) completely isolated from GitHub forge calls and `github.json` while rendering them through the exact same `Thread` / `ThreadPreview` / `SessionView` read models. Support local creation (`comment_with_origin`), reviewer replies (resetting `agent` to `Unsent`), `agent_reply` (refusing GitHub thread IDs and marking `Answered`), local edit/delete/resolve, `promote_thread` (turning an edited root comment into a GitHub draft and setting `promoted_to`), and `SessionView.local_unsent_count`.

- [ ] **Step 1: Write failing unit tests in `crates/review-core/src/session/local.rs` and `presenter.rs`**

Create `crates/review-core/src/session/local.rs` starting with `#[cfg(test)]`:

```rust
//! Local-only threads, agent reply guards, and promotion into GitHub drafts.

#[cfg(test)]
mod tests {
    use review_model::{AgentThreadState, Anchor, MessageSync, Origin, ThreadState};

    use crate::session::test_support::Fakes;

    #[test]
    fn local_comments_save_to_local_store_never_touch_forge_and_survive_sync() {
        let fakes = Fakes::new(100);
        fakes.forge.fail_writes_with(Some("forge must not be called"));
        let mut session = fakes.open_synced();

        let (thread, view) = session
            .comment_with_origin(Anchor::line("src/a.rs", 1), "Ask agent about lifetime", Origin::Local)
            .expect("local comment succeeds even while forge writes fail");
        assert_eq!(thread.origin, Origin::Local);
        assert_eq!(thread.agent, Some(AgentThreadState::Unsent));
        assert!(thread.messages[0].sync.is_none());
        assert_eq!(view.local_unsent_count, 1);
        assert_eq!(view.draft_count, 0);
        assert_eq!(fakes.store.saved().local.threads.len(), 1);
        assert!(
            fakes
                .store
                .saved()
                .registry
                .threads
                .iter()
                .all(|item| item.origin == Origin::Github)
        );

        fakes.forge.fail_writes_with(None);
        let synced_view = session.sync().expect("sync succeeds");
        assert_eq!(synced_view.local_unsent_count, 1);
        assert!(session.threads().iter().any(|item| item.id == thread.id));
    }

    #[test]
    fn agent_reply_refuses_github_threads_and_flips_local_thread_to_answered() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let github_error = session
            .agent_reply("T1", "Done.", None)
            .expect_err("GitHub thread must be refused");
        assert!(github_error.to_string().contains("GitHub thread"), "{github_error:#}");

        let (local, _) = session
            .comment_with_origin(Anchor::line("src/a.rs", 1), "Fix unwrap", Origin::Local)
            .unwrap();
        let (answered, view) = session
            .agent_reply(&local.id, "Done. (abc1234)", None)
            .expect("local thread accepts agent reply");
        assert_eq!(answered.agent, Some(AgentThreadState::Answered));
        assert_eq!(answered.messages.last().unwrap().author, "agent");
        assert!(!answered.messages.last().unwrap().viewer_did_author);
        assert_eq!(view.local_unsent_count, 0);

        let (reopened_turn, view_after_user_reply) =
            session.reply(&local.id, "What about empty slices?").unwrap();
        assert_eq!(reopened_turn.agent, Some(AgentThreadState::Unsent));
        assert_eq!(view_after_user_reply.local_unsent_count, 1);
    }

    #[test]
    fn promoting_local_thread_creates_github_draft_without_agent_replies() {
        let fakes = Fakes::new(100);
        let mut session = fakes.open_synced();
        let (local, _) = session
            .comment_with_origin(Anchor::line("src/a.rs", 1), "rough note", Origin::Local)
            .unwrap();
        session.agent_reply(&local.id, "Confirmed bug in parser.", None).unwrap();

        let (github_draft, view) = session
            .promote_thread(&local.id, "Polished note for PR author")
            .expect("promotion creates GitHub draft");
        assert_eq!(github_draft.origin, Origin::Github);
        assert_eq!(github_draft.messages.len(), 1);
        assert_eq!(github_draft.messages[0].body, "Polished note for PR author");
        assert_eq!(github_draft.messages[0].sync, Some(MessageSync::Draft));
        assert_eq!(view.draft_count, 1);

        let updated_local = session
            .threads()
            .iter()
            .find(|item| item.id == local.id)
            .unwrap();
        assert_eq!(updated_local.promoted_to.as_deref(), Some(github_draft.id.as_str()));
    }
}
```

In `crates/review-core/src/presenter.rs` tests, add an `Origin::Local` unsent thread and assert `view.local_unsent_count == 1`.

- [ ] **Step 2: Run `cargo test -p review-core` to confirm failure**

Declare `mod local;` in `crates/review-core/src/session/mod.rs` and run:

```bash
cargo test -p review-core
```

Expected: FAIL (`comment_with_origin`, `agent_reply`, and `promote_thread` missing).

- [ ] **Step 3: Implement `session/local.rs` and wire `mod.rs`, `comments.rs`, `sync.rs`, and `presenter.rs`**

1. In `crates/review-core/src/presenter.rs`, compute:
   ```rust
   local_unsent_count: threads
       .iter()
       .filter(|thread| crate::agent::is_thread_dispatchable(thread))
       .count(),
   ```
2. In `crates/review-core/src/session/mod.rs`:
   - On `ReviewSession::open`, initialize `let mut threads = saved.registry.threads.clone(); threads.extend(saved.local.threads.clone());`.
   - Add a helper `pub(super) fn split_and_save_threads(&mut self) -> Result<()>` that updates `self.saved.registry.threads` with `self.threads.iter().filter(|t| t.origin == Origin::Github).cloned().collect()` and `self.saved.local.threads` with `self.threads.iter().filter(|t| t.origin == Origin::Local).cloned().collect()`, then calls `self.ports.store.save(&self.saved)` (use this in `save_and_announce_threads` and `sync::apply_pull` so `github.json` and `local.json` stay strictly partitioned).
3. In `crates/review-core/src/session/sync.rs`:
   - Before replacing `self.threads = snapshot.threads`, retain `let local_threads: Vec<Thread> = self.threads.iter().filter(|t| t.origin == Origin::Local).cloned().collect();`, and after GitHub reconciliation extend `self.threads.extend(local_threads);` before saving.
4. In `crates/review-core/src/session/comments.rs`:
   - Delegate `comment(&mut self, anchor: Anchor, body: &str)` to `self.comment_with_origin(anchor, body, Origin::Github)`.
   - In `reply`, `edit_message`, `delete_message`, `set_resolved`, and `toggle_reaction`, check first whether the target thread/message belongs to an `Origin::Local` thread and route to the local methods in `session/local.rs` so no local thread ever invokes `self.ports.forge`.
5. In `crates/review-core/src/session/local.rs` (keeping each function `<= 45` lines):
   - `comment_with_origin(&mut self, mut anchor: Anchor, body: &str, origin: Origin) -> Result<(Thread, SessionView)>`: routes `Origin::Github` to the existing forge path; for `Origin::Local`, validates `body` and `anchor` (`validate_anchor_file` when `anchor.kind != AnchorKind::Pr`), fills `anchor.snapshot` from `self.anchored_lines(&anchor).ok()` when `anchor.snapshot.is_none()` and `anchor.side == Side::Right`, allocates `loc-{n}` / `loc-m-{n}`, sets `agent: Some(AgentThreadState::Unsent)`, pushes to `self.threads`, saves, and announces `Event::ThreadsChanged`.
   - `reply_local_thread(&mut self, thread_id: &str, body: &str) -> Result<(Thread, SessionView)>`: appends reviewer message (`viewer_did_author: true`, `sync: None`), sets `thread.agent = Some(AgentThreadState::Unsent)`, saves, and announces `Event::ThreadsChanged`.
   - `agent_reply(&mut self, thread_id: &str, body: &str, author: Option<&str>) -> Result<(Thread, SessionView)>`: checks `body.trim()` non-empty; if `self.find_thread(thread_id)` is `Some(t)` with `t.origin == Origin::Github`, or if `thread_id` looks like a GitHub/optimistic ID (`PRRT_`, `IC_`, `PRRC_`, `tmp-`), bails with `"refusing to reply to GitHub thread {thread_id}: agent replies are allowed only on local threads"`; appends message (`author: author.unwrap_or("agent")`, `viewer_did_author: false`, `sync: None`), sets `thread.agent = Some(AgentThreadState::Answered)`, saves, and announces `Event::ThreadsChanged`.
   - `edit_local_message`, `delete_local_message`, and `set_local_resolved`: mutate local thread in place, save, and announce `Event::ThreadsChanged`.
   - `promote_thread(&mut self, thread_id: &str, body: &str) -> Result<(Thread, SessionView)>`: verifies `thread_id` is `Origin::Local`, clones `anchor`, calls `self.comment_with_origin(anchor, body, Origin::Github)?`, sets `local_thread.promoted_to = Some(github_thread.id.clone())`, saves, announces `Event::ThreadsChanged`, and returns `(github_thread, view)`.

- [ ] **Step 4: Run `cargo test -p review-core`**

```bash
cargo test -p review-core
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-core
git commit -m "feat(core): implement local threads, sync isolation, agent_reply guard, and promotion"
```

---

### Task 6: `ReviewSession` agent launch, two-phase send, pre-pass, and worktree file watching (`crates/review-core`)

**Files:**
- Create: `crates/review-core/src/session/agent_loop.rs`
- Modify: `crates/review-core/src/session/mod.rs`

Add the facade methods for `:Jpr agent` (`prepare_agent_launch`), `:Jpr send` / popup `s` (`prepare_send` + `confirm_send`), `:Jpr prepass` (`prepare_prepass` + `prepass_write`), live buffer save anchor updates (`update_local_anchors`), and background worktree file-change detection + snapshot re-anchoring (`poll_worktree_files`).

- [ ] **Step 1: Write failing unit tests in `crates/review-core/src/session/agent_loop.rs`**

Create `crates/review-core/src/session/agent_loop.rs` starting with `#[cfg(test)]` covering:
1. `prepare_agent_launch_assigns_v4_uuid_once_and_marks_later_launches_as_resume`: first call with `AgentKind::Claude` sets `is_resume == false` and saves `agent_session_id` (36-char RFC 4122 v4 UUID) in `session.json`; second call returns the identical `session_id` with `is_resume == true`; switching to `AgentKind::Codex` allocates a fresh session ID with `is_resume == false`.
2. `two_phase_send_keeps_threads_unsent_until_confirm_send_records_round`: `prepare_send(None, AgentKind::Claude)` returns `round == 1` and the prompt while leaving `thread.agent == Some(AgentThreadState::Unsent)` and `store.rounds().is_empty()`; calling `confirm_send(1, AgentRoundKind::Send, &dispatch.thread_ids, &dispatch.prompt)` flips the thread to `Sent { round: 1 }`, appends `round == 1` to `store.rounds()`, and emits `Event::AgentRound`.
3. `prepass_write_creates_answered_local_threads_with_snapshots`: `prepass_write` with two findings creates two `Origin::Local` threads authored by `"agent"` (`viewer_did_author == false`, `agent == Some(AgentThreadState::Answered)`), so `local_unsent_count == 0` until the reviewer replies to one.
4. `poll_worktree_files_emits_files_changed_and_reanchors_local_threads`: after opening a synced session with a local thread on line 2 (`snapshot == "let x = 1;"`), writing two header lines above line 2 via `fakes.workspace.write_disk("src/a.rs", ...)` causes `poll_worktree_files()` to move `anchor.start` and `anchor.end` to `4`, emit `Event::FilesChanged { paths: vec!["src/a.rs"], .. }`, and return `None` on an immediate second poll when nothing else changed.
5. `update_local_anchors_updates_line_bounds_and_refreshes_snapshot`: `update_local_anchors("src/a.rs", &[LocalAnchorUpdate { thread_id, start: 3, end: 3 }])` updates `anchor.start`/`end` and refreshes `anchor.snapshot` from disk.

- [ ] **Step 2: Run `cargo test -p review-core` to confirm failure**

Declare `mod agent_loop;` in `crates/review-core/src/session/mod.rs` and run:

```bash
cargo test -p review-core
```

Expected: FAIL (methods not yet implemented on `ReviewSession`).

- [ ] **Step 3: Implement `crates/review-core/src/session/agent_loop.rs` and update `session/mod.rs`**

In `crates/review-core/src/session/mod.rs`:
- Add `disk_digests: Option<std::collections::BTreeMap<String, u64>>` to `ReviewSession` (initialized to `None` in `open`).
- Add `pub fn record_daemon_with_socket(&mut self, pid: u32, worktree: &str, socket: Option<&str>) -> Result<()>` updating `pid`, `worktree`, and `socket` (`socket.map(str::to_owned)`), and delegate `record_daemon(pid, worktree)` to `self.record_daemon_with_socket(pid, worktree, None)`.

In `crates/review-core/src/session/agent_loop.rs` (keeping every function `<= 45` lines):
- Pure helper `build_uuid_v4_from_seed(pr_number: u64, timestamp: u64, counter: u64) -> String`: mixes two 64-bit FNV-1a / splitmix64 lanes from `(pr_number, timestamp, counter)`, sets RFC 4122 version nibble `4` and variant bits `0b10`, and formats `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` (36 chars, accepted by `claude --session-id`).
- `prepare_agent_launch(&mut self, kind: AgentKind) -> Result<AgentLaunchPlan>`: reuses `(agent_session_id, is_resume = true)` when `self.saved.session.agent_kind == Some(kind)` and `agent_session_id` is `Some`; otherwise generates a new UUID via `build_uuid_v4_from_seed`, stores `agent_session_id` and `agent_kind = Some(kind)`, saves `self.saved`, and returns `is_resume = false`.
- `prepare_send(&self, only_thread_id: Option<&str>, kind: AgentKind) -> Result<AgentDispatch>`: selects threads with `select_dispatchable_threads(&self.threads, only_thread_id)`, bails with `"no unsent local comments to send"` when empty, builds prompt with `build_send_prompt_from_threads`, and returns `AgentDispatch` with `round = self.saved.local.next_round.max(1)`.
- `confirm_send(&mut self, round: u64, kind: AgentRoundKind, thread_ids: &[String], prompt: &str) -> Result<(AgentRound, SessionView)>`: marks matching local threads `Sent { round }`, bumps `next_round`, appends `AgentRound` via `self.ports.store.append_round(&entry)?`, saves `self.saved`, publishes `Event::ThreadsChanged` (when `!thread_ids.is_empty()`) and `Event::AgentRound`, and returns `(entry, view)`.
- `prepare_prepass(&self, kind: AgentKind) -> Result<AgentDispatch>`: requires `pr = self.synced_pr()?` and returns `AgentDispatch` (`AgentRoundKind::Prepass`, empty `thread_ids`, `build_prepass_prompt_from_pr(pr)`).
- `prepass_write(&mut self, findings: Vec<PrepassFinding>) -> Result<(Vec<Thread>, SessionView)>`: appends each non-empty finding as an `Origin::Local` thread (`author = finding.author.unwrap_or("agent")`, `viewer_did_author = false`, `agent = Some(AgentThreadState::Answered)`), captures `snapshot` when `anchor.side == Side::Right`, saves, publishes `Event::ThreadsChanged`, and returns `(created_threads, view)`.
- `update_local_anchors(&mut self, path: &str, updates: &[LocalAnchorUpdate]) -> Result<SessionView>`: reads current disk text for `path` via `self.ports.workspace.file_on_disk(path)?`, updates `start` / `end` (ordered) and `snapshot` (`extract_snapshot_from_text`) on matching `Origin::Local` threads, clears `outdated`, saves, and publishes `Event::ThreadsChanged`.
- `poll_worktree_files(&mut self) -> Result<Option<Vec<String>>>`: computes FNV-1a 64-bit hashes of `file_on_disk(path)` for every tracked file in `self.saved.files` plus `list_changed_files_since(&merge_base)`. If `self.disk_digests.is_none()`, stores the map and returns `Ok(None)`. Otherwise collects sorted paths whose digest changed, runs `reanchor_thread_in_text` on local threads for those paths, saves if any local thread changed, updates `self.disk_digests`, publishes `Event::FilesChanged` (and `Event::ThreadsChanged` if re-anchored), and returns `Ok(Some(changed_paths))` (or `Ok(None)` when empty).

- [ ] **Step 4: Run `cargo test -p review-core`**

```bash
cargo test -p review-core
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-core
git commit -m "feat(core): add agent launch plans, two-phase send, prepass-write, and file re-anchoring"
```

---

### Task 7: Lock-free worktree change listing in `GitWorkspace` (`crates/review-workspace-git`)

**Files:**
- Modify: `crates/review-workspace-git/src/process.rs`
- Modify: `crates/review-workspace-git/src/git_output.rs`
- Modify: `crates/review-workspace-git/src/workspace.rs`
- Modify: `crates/review-workspace-git/src/workspace/tests.rs`

Implement `Workspace::list_changed_files_since` on `GitWorkspace` using `GIT_OPTIONAL_LOCKS=0` so background polling detects agent commits, unstaged edits, and new untracked files without ever contending on `.git/index.lock`.

- [ ] **Step 1: Write failing temporary-repo tests in `crates/review-workspace-git/src/workspace/tests.rs`**

Add a test `lists_committed_unstaged_and_untracked_changes_without_index_lock` that:
1. Creates a temporary git repository with a `base` commit (`src/lib.rs`), a `head` commit modifying `src/lib.rs`, an unstaged edit on `src/extra.rs`, and an untracked `src/new_file.rs`.
2. Calls `workspace.list_changed_files_since(&base_sha)`.
3. Asserts the returned list equals `["src/extra.rs", "src/lib.rs", "src/new_file.rs"]` and `!<repo>/.git/index.lock` exists.

- [ ] **Step 2: Run `cargo test -p review-workspace-git` to confirm failure**

```bash
cargo test -p review-workspace-git
```

Expected: FAIL (`list_changed_files_since` returns empty `Vec`).

- [ ] **Step 3: Implement lock-free `list_changed_files_since` in `process.rs`, `git_output.rs`, and `workspace.rs`**

1. In `crates/review-workspace-git/src/process.rs`, set `.env("GIT_OPTIONAL_LOCKS", "0")` on read-only git invocations (or add `pub(crate) fn run_bytes_unlocked(program: &str, args: &[&str], cwd: &Path) -> Result<Vec<u8>>`).
2. In `crates/review-workspace-git/src/git_output.rs`, add pure parsers:
   - `parse_nul_paths(bytes: &[u8]) -> Vec<String>` splitting NUL-terminated `diff-index --name-only -z` output.
   - `parse_porcelain_z_paths(bytes: &[u8]) -> Vec<String>` parsing `git status --porcelain=v1 -z --untracked-files=all` entries (handling rename source+target pairs when status starts with `'R'` or `'C'`).
3. In `crates/review-workspace-git/src/workspace.rs`, implement `list_changed_files_since(&self, commit: &str) -> Result<Vec<String>>`:
   - Calls `require_commit_id(commit)?`.
   - Runs `git diff-index --name-only -z <commit> --` and `git status --porcelain=v1 -z --untracked-files=all` via `run_bytes_unlocked`.
   - Collects both into a `BTreeSet<String>` (filtering through `path_to_safe_relative(&path).is_ok()`) and returns `.into_iter().collect()`.

- [ ] **Step 4: Run `cargo test -p review-workspace-git`**

```bash
cargo test -p review-workspace-git
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-workspace-git
git commit -m "feat(workspace): detect worktree file changes without taking git index locks"
```

---

### Task 8: Protocol v4 handlers, worktree watcher tick, and Unix domain socket server (`crates/review-rpc`) `[HIGH-RISK]`

**Files:**
- Create: `crates/review-rpc/src/server/agent.rs`
- Create: `crates/review-rpc/src/socket.rs`
- Modify: `crates/review-rpc/src/params.rs`
- Modify: `crates/review-rpc/src/protocol.rs`
- Modify: `crates/review-rpc/src/server.rs`
- Modify: `crates/review-rpc/src/server/comments.rs`
- Modify: `crates/review-rpc/src/lib.rs`
- Modify: `crates/review-rpc/tests/rpc.rs`

Bump `PROTOCOL_VERSION` to `4`, expose all local-comment and agent-loop methods over JSON-RPC, run `poll_worktree_files` on a configurable `watch_every` tick, and accept concurrent CLI JSON-RPC connections over a Unix domain socket while immediately flushing resulting `Event` notifications to the primary stdio writer (Neovim).

- [ ] **Step 1: Write failing protocol and Unix-socket integration tests in `crates/review-rpc/tests/rpc.rs`**

Add integration tests in `crates/review-rpc/tests/rpc.rs` (updating existing `protocolVersion` assertions from `3` to `4`):
1. `socket_agent_reply_pushes_threads_changed_to_stdio_and_refuses_github_threads`:
   - Starts `review_rpc::serve` in a background thread with `socket_path: Some(temp_sock.clone())` over an in-memory stdio pipe.
   - Sends `comment` with `"origin": "local"` on stdio -> receives `loc-1`.
   - Connects a `std::os::unix::net::UnixStream` to `temp_sock` and sends `agentReply` targeting `"T1"` (a GitHub thread) -> asserts JSON-RPC error `-32000` mentioning `GitHub thread`.
   - Sends `agentReply` targeting `"loc-1"` over the `UnixStream` -> asserts JSON-RPC success on the socket AND asserts the stdio reader immediately receives an `"event"` notification with `"type": "threadsChanged"` and `"localUnsentCount": 0` BEFORE any further stdio request is sent!
   - Sends `shutdown` on stdio -> asserts `temp_sock` is unlinked on exit.
2. `prepare_send_confirm_send_promote_and_prepass_write_work_over_rpc`:
   - Exercises `prepareAgentLaunch`, `prepareSend`, `confirmSend`, `promoteThread`, `prepassWrite`, and `updateLocalAnchors`.
3. `worktree_watcher_pushes_files_changed_event_when_disk_changes`:
   - Runs `serve` with `watch_every: Some(Duration::from_millis(25))`, mutates `FakeWorkspace` disk, and reads `{"method":"event","params":{"type":"filesChanged",...}}` from the stdio stream.

- [ ] **Step 2: Run `cargo test -p review-rpc` to confirm failure**

```bash
cargo test -p review-rpc
```

Expected: FAIL (`PROTOCOL_VERSION` is 3, `ServeOptions` lacks `socket_path` / `watch_every`, new methods return `-32601`).

- [ ] **Step 3: Implement protocol v4 params, agent RPC handlers, watcher tick, and `socket.rs`**

1. In `crates/review-rpc/src/protocol.rs`, change `pub const PROTOCOL_VERSION: u32 = 4;`.
2. In `crates/review-rpc/src/params.rs`, add parsers:
   - `get_origin_from_params(params: &Value) -> Result<Origin, RpcError>` (default `Origin::Github` when `"origin"` is omitted or null; `"github"` -> `Origin::Github`, `"local"` -> `Origin::Local`, else `INVALID_PARAMS`).
   - `get_agent_kind_from_params(params: &Value) -> Result<AgentKind, RpcError>` (default `AgentKind::Claude` when `"agent"` is omitted or null).
   - `get_round_kind_from_params(params: &Value) -> Result<AgentRoundKind, RpcError>`.
   - `get_string_vec_from_params(params: &Value, key: &str) -> Result<Vec<String>, RpcError>`.
   - `get_prepass_findings_from_params(params: &Value) -> Result<Vec<PrepassFinding>, RpcError>`.
   - `get_anchor_updates_from_params(params: &Value) -> Result<Vec<LocalAnchorUpdate>, RpcError>`.
3. In `crates/review-rpc/src/server/comments.rs`, update `"comment"` to read `let origin = get_origin_from_params(params)?;` and call `comment_with_origin(anchor, body, origin)`, and delegate unrecognized methods from `handle_reaction_and_review_method` to `super::agent::handle_agent_method(session, other, params)`.
4. Create `crates/review-rpc/src/server/agent.rs` routing:
   - `"agentReply"` -> `session.agent_reply(thread_id, body, author)` -> `{ thread, view }`
   - `"promoteThread"` -> `session.promote_thread(thread_id, body)` -> `{ thread, view }`
   - `"prepareAgentLaunch"` -> `session.prepare_agent_launch(kind)` -> `AgentLaunchPlan`
   - `"prepareSend"` -> `session.prepare_send(thread_id, kind)` -> `AgentDispatch`
   - `"confirmSend"` -> `session.confirm_send(round, kind, &thread_ids, prompt)` -> `{ round: entry, view }`
   - `"preparePrepass"` -> `session.prepare_prepass(kind)` -> `AgentDispatch`
   - `"prepassWrite"` -> `session.prepass_write(findings)` -> `{ threads, view }`
   - `"updateLocalAnchors"` -> `session.update_local_anchors(path, &updates)` -> `SessionView`
5. In `crates/review-rpc/src/ServeOptions` (`server.rs`), add:
   ```rust
   /// Optional Unix domain socket path for CLI clients (`jpr-review reply`, etc.).
   pub socket_path: Option<std::path::PathBuf>,
   /// Optional interval for checking worktree file changes on disk.
   pub watch_every: Option<Duration>,
   ```
   Initialize baseline `let _ = session.lock()...poll_worktree_files();` when `watch_every.is_some()`, and wake the background thread at the minimum of `(poll_every, retry_every, watch_every)`, calling `let _ = session.poll_worktree_files();` whenever `last_watch.elapsed() >= watch_every` and flushing `write_events(&events, &writer)`.
6. Create `crates/review-rpc/src/socket.rs` (`#[cfg(unix)]`, pure safe `std::os::unix::net::UnixListener`):
   - Removes any preexisting stale file at `socket_path`, creates parent dir if needed, binds `UnixListener::bind(socket_path)`, sets permissions `0o600`, and sets `listener.set_nonblocking(true)`.
   - Spawns an accept loop checking `stopped.try_recv()` every `25ms`: on each accepted `UnixStream`, switches that client stream to blocking with a 5s read timeout, reads newline-delimited requests, calls `handle(session, &request, &server_version)` (refusing `"shutdown"` on the socket so a CLI client cannot kill Neovim's daemon), flushes `write_events(&events, stdio_writer)` (ignoring broken stdio only on teardown), and writes the JSON-RPC response line back to the `UnixStream`.
   - Removes `socket_path` when the accept loop exits.

- [ ] **Step 4: Run `cargo test --workspace --all-features`**

Update any `ServeOptions { ... }` struct literals in `crates/jpr-review` and `crates/review-rpc` tests to include `socket_path: None, watch_every: None`, then run:

```bash
cargo test --workspace --all-features
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/review-rpc crates/jpr-review
git commit -m "feat(rpc): bump protocol to v4, add Unix socket server, and watch worktree files"
```

---

### Task 9: CLI subcommands (`guide`, `threads`, `reply`, `prepass-write`) and `serve` socket wiring (`crates/jpr-review`) `[HIGH-RISK]`

**Files:**
- Create: `crates/jpr-review/src/commands/guide.rs`
- Create: `crates/jpr-review/src/commands/socket_client.rs`
- Create: `crates/jpr-review/src/commands/threads.rs`
- Create: `crates/jpr-review/src/commands/reply.rs`
- Create: `crates/jpr-review/src/commands/prepass_write.rs`
- Modify: `crates/jpr-review/src/cli.rs`
- Modify: `crates/jpr-review/src/commands/mod.rs`
- Modify: `crates/jpr-review/src/commands/serve.rs`
- Create: `crates/jpr-review/tests/agent_cli.rs`

Wire `jpr-review serve` to bind a per-PR Unix socket (recorded in `session.json` and removed on shutdown) and watch worktree files every 2 seconds, and add the four CLI subcommands (`guide`, `threads`, `reply`, `prepass-write`) using live-socket RPC when a daemon is serving and locked atomic `local.json` fallback when no daemon is running.

- [ ] **Step 1: Write failing CLI parser tests in `cli.rs` and process integration tests in `crates/jpr-review/tests/agent_cli.rs`**

In `crates/jpr-review/src/cli.rs` tests, assert:
1. `jpr-review guide` parses to `Command::Guide`.
2. `jpr-review threads --pr 7 --repo octo/widgets --local` parses to `Command::Threads`.
3. `jpr-review reply loc-1 --body "Done. (abc1234)"` parses to `Command::Reply` (reading `JPR_SOCKET` and `JPR_PR` from env when omitted on the command line).
4. `jpr-review prepass-write --input findings.json` parses to `Command::PrepassWrite`.

Create `crates/jpr-review/tests/agent_cli.rs` testing the compiled `jpr-review` binary end-to-end with temporary `XDG_STATE_HOME`:
1. `guide_prints_the_agent_contract_to_stdout`: runs `jpr-review guide`, asserts exit 0, stdout contains `jpr-review reply <thread-id> --body` and `Never push`, and stderr is empty.
2. `offline_fallback_prepass_write_threads_and_reply_round_trip_and_refuse_github_ids`:
   - With **no** daemon running, pipes two JSON `PrepassFinding` items into `jpr-review prepass-write --pr 7 --repo octo/widgets` -> asserts exit 0 and `local.json` now holds `loc-1` and `loc-2`.
   - Runs `jpr-review reply PRRT_abc --body "no" --pr 7 --repo octo/widgets` -> asserts non-zero exit and stderr contains `GitHub thread`.
   - Runs `jpr-review reply loc-1 --body "Addressed in 1234567." --pr 7 --repo octo/widgets` -> asserts exit 0 and `jpr-review threads --pr 7 --repo octo/widgets --local` prints JSON showing `loc-1` with 2 messages and `"agent": {"state": "answered"}`.
3. `live_socket_reply_routes_through_daemon_via_jpr_socket_env`:
   - Starts an in-process `review_rpc::serve` on a temporary Unix socket path, runs `jpr-review reply loc-1 --body "Via socket"` with `JPR_SOCKET=<sock>` (and no `--pr` / `--repo` needed!), and verifies the live session receives the reply and emits `threadsChanged`.

- [ ] **Step 2: Run `cargo test -p jpr-review` to confirm failure**

```bash
cargo test -p jpr-review
```

Expected: FAIL (subcommands not yet in `Command`).

- [ ] **Step 3: Implement `cli.rs`, `serve.rs`, `socket_client.rs`, `guide.rs`, `threads.rs`, `reply.rs`, and `prepass_write.rs`**

1. In `crates/jpr-review/src/cli.rs`, add variants to `Command`:
   - `Guide`: prints the agent review/reply contract on stdout.
   - `Threads { #[arg(long, env = "JPR_PR")] pr: Option<u64>, #[arg(long, value_name = "OWNER/NAME")] repo: Option<String>, #[arg(long, env = "JPR_SOCKET", value_name = "PATH")] socket: Option<PathBuf>, #[arg(long)] local: bool }`.
   - `Reply { /// Local thread id (e.g. loc-1). Left out on a terminal, you are asked. thread_id: Option<String>, #[arg(long)] body: Option<String>, #[arg(long, env = "JPR_PR")] pr: Option<u64>, #[arg(long, value_name = "OWNER/NAME")] repo: Option<String>, #[arg(long, env = "JPR_SOCKET", value_name = "PATH")] socket: Option<PathBuf> }`.
   - `PrepassWrite { #[arg(long, value_name = "FILE")] input: Option<PathBuf>, #[arg(long, env = "JPR_PR")] pr: Option<u64>, #[arg(long, value_name = "OWNER/NAME")] repo: Option<String>, #[arg(long, env = "JPR_SOCKET", value_name = "PATH")] socket: Option<PathBuf> }`.
2. In `crates/jpr-review/src/commands/serve.rs`:
   - Add `pub const WATCH_SECONDS: u64 = 2;`.
   - Add `pub fn build_socket_path_from_state_dir(state_dir: &Path, pid: u32) -> PathBuf` choosing `state_dir.join("s.sock")` when `<= 96` bytes (below macOS's 104-byte `SUN_LEN` ceiling) and falling back to `std::env::temp_dir().join(format!("jpr-{pid}-{hash:08x}.sock"))` when longer.
   - Call `session.record_daemon_with_socket(pid, &cwd.to_string_lossy(), Some(&socket_str))?` and pass `socket_path: Some(socket_path)` and `watch_every: Some(Duration::from_secs(WATCH_SECONDS))` in `ServeOptions`.
3. Create `crates/jpr-review/src/commands/socket_client.rs`:
   - `call_socket(socket_path: &Path, method: &str, params: Value) -> Result<Option<Value>>`: connects to `UnixStream`; if `NotFound` or `ConnectionRefused`, returns `Ok(None)` so the caller falls back cleanly to `FsStore`; if connected, sends one JSON-RPC request line, reads one response line, returns `Err` on JSON-RPC `error` (such as refusing a GitHub thread ID!), or `Ok(Some(result))`.
   - `resolve_socket_or_store(socket: Option<&Path>, pr: Option<u64>, repo: Option<&str>, theme: Theme) -> Result<Target>` where `Target` tries explicit `socket` first, otherwise resolves `(owner, name, number)` (inferring `repo` from current git remote via `GhForge` when omitted before prompting on a TTY), checks `FsStore::load()?.session.socket` next, and falls back to `FsStore`.
4. Create `guide.rs` (`println!("{}", review_core::build_agent_guide())`), `threads.rs`, `reply.rs` (prompting via `prompt::ask` when `thread_id` or `body` is omitted on a TTY, refusing `PRRT_` / `IC_` / `PRRC_` / `tmp-` or any ID present in `github.json` during fallback, and mutating `local.json` via `FsStore::mutate_local_locked`), and `prepass_write.rs` (reading JSON array of `PrepassFinding` from `--input <FILE>` or stdin, capturing disk snapshots when in a git worktree, and writing via socket or `mutate_local_locked`).
   - Format timestamps in fallback mode as `YYYY-MM-DDTHH:MM:SSZ` from `SystemClock` using a small pure civil-date helper (Howard Hinnant's 20-line Euclidean civil-from-days formula, zero external crates).

- [ ] **Step 4: Run `cargo test --workspace --all-features`**

```bash
cargo test --workspace --all-features
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add crates/jpr-review
git commit -m "feat(cli): add guide, threads, reply, and prepass-write with socket and lock fallback"
```

---

### Task 10: Neovim protocol v4 bump, agent config, highlights, `:Jpr` commands, and `filesChanged` (`lua/jpr/`)

**Files:**
- Modify: `lua/jpr/rpc.lua`
- Modify: `lua/jpr/init.lua`
- Modify: `lua/jpr/session/init.lua`
- Modify: `tests/lua/fixtures/fake_engine.sh`
- Modify: `tests/lua/rpc_spec.lua`
- Modify: `tests/lua/session_spec.lua`

Bump `rpc.PROTOCOL_VERSION` to `4`, add agent options (`agent = "claude"`, `claude_cmd = "claude"`, `codex_cmd = "codex"`, `agent_width = 56`), define `JprThreadLocal`, register `:Jpr agent`, `:Jpr send`, and `:Jpr prepass` subcommands, handle `filesChanged` notifications (`vim.cmd("silent! checktime")` + diff and stream redraw), and update `fake_engine.sh` to protocol v4.

- [ ] **Step 1: Update `rpc_spec.lua` and `session_spec.lua` with failing protocol v4 and `filesChanged` assertions**

1. In `tests/lua/rpc_spec.lua`, update expected `PROTOCOL_VERSION` from `3` to `4`.
2. In `tests/lua/session_spec.lua`:
   - Assert `:Jpr` completion includes `"agent"`, `"send"`, and `"prepass"`.
   - Assert `JprThreadLocal` highlight group is defined by `define_highlights()`.
   - Simulate an incoming `event` notification with `{ type = "filesChanged", paths = { "README.md" }, view = session.view }` while `README.md` is open and modified externally on disk, and assert Neovim reloads `README.md` via `checktime` and refreshes the diff overlay.

- [ ] **Step 2: Run `just test-lua` to confirm failure**

```bash
just test-lua
```

Expected: FAIL (`PROTOCOL_VERSION` is 3, `JprThreadLocal` and `filesChanged` missing).

- [ ] **Step 3: Update `rpc.lua`, `init.lua`, `session/init.lua`, and `fake_engine.sh`**

1. In `lua/jpr/rpc.lua`, set `M.PROTOCOL_VERSION = 4`.
2. In `lua/jpr/init.lua`:
   - Add to `M.defaults`:
     ```lua
     -- Interactive agent CLI for `:Jpr agent`, `:Jpr send`, and `:Jpr prepass`:
     -- "claude" or "codex".
     agent = "claude",
     -- Command or path invoked for Claude Code in the agent panel.
     claude_cmd = "claude",
     -- Command or path invoked for Codex in the agent panel.
     codex_cmd = "codex",
     -- Width in columns of the right-hand `:Jpr agent` vertical split.
     agent_width = 56,
     ```
   - Add `"agent"`, `"send"`, `"prepass"` to `M.subcommands` (before `"close"`).
   - Add `JprThreadLocal = "DiagnosticHint"` (distinct cyan/teal tint from `JprThreadPublished`, `JprThreadDraft`, and `JprThreadFailed`) in `M.define_highlights()`.
   - Route `agent = session.agent_current`, `send = session.send_current`, and `prepass = session.prepass_current` in `M.command`.
3. In `lua/jpr/session/init.lua`:
   - Call `close_optional_view("jpr.agent", session)` inside `forget(session, close_tab)`.
   - In `M.on_notification`, handle `params.type == "filesChanged"`:
     ```lua
     elseif method == "event" and params and params.type == "filesChanged" then
         session.view = params.view or session.view
         vim.cmd("silent! checktime")
         panel.render(session, session.view)
         require("jpr.views.diff").redraw_all(session)
         require("jpr.views.stream").refresh(session, true)
     elseif method == "event" and params and params.type == "agentRound" then
         session.view = params.view or session.view
         panel.render(session, session.view)
         require("jpr.views.diff").redraw_threads(session)
         require("jpr.views.stream").refresh(session, true)
     ```
   - Add `M.agent_current()`, `M.send_current()`, and `M.prepass_current()` delegating to `require("jpr.agent").toggle(session)`, `require("jpr.agent").send(session)`, and `require("jpr.agent").prepass(session)` after checking `M.current()`.
4. In `tests/lua/fixtures/fake_engine.sh`:
   - Default `FAKE_ENGINE_PROTOCOL` to `4`, include `"localUnsentCount":0` in `view_synced` / `view_viewed` / `view_empty`, and add canned responses for `prepareAgentLaunch`, `prepareSend`, `confirmSend`, `preparePrepass`, `promoteThread`, and `updateLocalAnchors` so later Lua specs can inspect logged RPC calls via `FAKE_ENGINE_LOG`.

- [ ] **Step 4: Run `just test-lua`**

```bash
just test-lua
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add lua tests/lua
git commit -m "feat(nvim): bump protocol to v4, add agent config, and reload buffers on filesChanged"
```

---

### Task 11: Panel `local unsent N` count and pure local thread markers/badges (`render/panel.lua`, `render/threads.lua`, `render/stream.lua`)

**Files:**
- Modify: `lua/jpr/render/panel.lua`
- Modify: `lua/jpr/render/threads.lua`
- Modify: `lua/jpr/render/stream.lua`
- Modify: `tests/lua/panel_render_spec.lua`
- Modify: `tests/lua/threads_render_spec.lua`

Show `local unsent N` in the panel header counts line when `view.localUnsentCount > 0`, give `kind == "local"` threads their own sign (`◆` / `JprThreadLocal`), display `[local · unsent]`, `[local · sent]`, `[local · answered]`, and `[promoted]` badges in EOL previews, inline virtual lines, and the thread popup, and include `[p]romote  [s]end` in the popup footer whenever a local thread is shown.

- [ ] **Step 1: Add failing assertions in `tests/lua/panel_render_spec.lua` and `tests/lua/threads_render_spec.lua`**

1. In `tests/lua/panel_render_spec.lua`:
   - Assert `panel.build_counts_text({ viewedCount = 1, files = { {}, {} }, threadCount = 3, draftCount = 1, localUnsentCount = 2, queuedCount = 0 })` produces `"viewed 1/2 · threads 3 · drafts 1 · local unsent 2"`.
   - Assert `localUnsentCount = 0` omits the `local unsent` segment.
2. In `tests/lua/threads_render_spec.lua`:
   - Build a local `ThreadPreview` (`kind = "local"`, `origin = "local"`, `agent = { state = "unsent" }`) and assert `pick_sign` returns `"◆", "JprThreadLocal"`, `create_eol_chunks_from_threads` includes `"[local · unsent]"`, `sent` (`{ state = "sent", round = 2 }`) includes `"[local · sent #2]"`, `answered` includes `"[local · answered]"`, `promotedTo = "PRRT_9"` includes `"[promoted]"`, and `create_popup_layout_from_threads` includes `"[p]romote"` and `"[s]end"` in the footer line.

- [ ] **Step 2: Run `just test-lua` to confirm failure**

```bash
just test-lua
```

Expected: FAIL (`local unsent` and `JprThreadLocal` badges missing).

- [ ] **Step 3: Update `render/panel.lua`, `render/threads.lua`, and `render/stream.lua`**

1. In `lua/jpr/render/panel.lua`, append `local unsent %d` inside `M.build_counts_text(view)` when `(view.localUnsentCount or 0) > 0`.
2. In `lua/jpr/render/threads.lua` (keeping every function `<= 45` lines):
   - Add helper `M.build_local_badge_from_thread(thread)` returning `""` when `thread.origin ~= "local" and thread.kind ~= "local"`, else combining agent state (`unsent` -> `"[local · unsent]"`, `sent` -> `("[local · sent #%d]"):format(agent.round or 1)`, `answered` -> `"[local · answered]"`, fallback `"[local]"`) plus `" [promoted]"` when `thread.promotedTo` is non-nil.
   - Update `M.pick_sign(threads)` priority: `failed` (`"!", "JprThreadFailed"`) > `draft` (`"✎", "JprThreadDraft"`) > open `local` (`"◆", "JprThreadLocal"`) > open `published` (`"💬", "JprThreadPublished"`) > `resolved` (`"✓", "JprThreadResolved"`).
   - Include `M.build_local_badge_from_thread(first_thread)` in `M.create_eol_chunks_from_threads`, on the first message header in `M.create_expanded_virt_lines_from_threads`, and in the `Thread (...)` title line of `M.create_popup_layout_from_threads`.
   - In `M.create_popup_layout_from_threads`, include `[p]romote  [s]end` in the footer hint line when any displayed thread is local.
3. In `lua/jpr/render/stream.lua`, include `view.localUnsentCount or 0` in `M.build_key_from_view(view)` so stream caches invalidate when local thread states change.

- [ ] **Step 4: Run `just test-lua`**

```bash
just test-lua
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add lua/jpr/render tests/lua
git commit -m "feat(nvim): render local unsent counts, local thread signs, and agent status badges"
```

---

### Task 12: Compose destination toggle (`<C-g>`, `<C-s>`, `<M-s>`) and local PR conversation comments (`comments/compose.lua`, `views/conversation.lua`)

**Files:**
- Modify: `lua/jpr/comments/compose.lua`
- Modify: `lua/jpr/views/conversation.lua`
- Modify: `tests/lua/compose_spec.lua`
- Modify: `tests/lua/conversation_suggest_spec.lua`

Let the reviewer switch a new comment's destination between `[GitHub draft]` and `[Local → agent]` (`session.compose_destination`, sticky per session): `<C-g>` flips the destination badge and window title/footer in place (while keeping `<C-g>s` working in insert mode for GitHub suggestion blocks!), `<C-s>` saves to the shown destination, and `<M-s>` saves straight to the other destination. Also support replying (`r`), sending (`s`), and promoting (`p`) on local PR-level threads in `:Jpr conversation`.

- [ ] **Step 1: Add failing tests in `tests/lua/compose_spec.lua` and `tests/lua/conversation_suggest_spec.lua`**

1. In `tests/lua/compose_spec.lua`, add tests verifying:
   - Opening a new comment defaults to `[GitHub draft]` (`origin = "github"` on `<C-s>`).
   - Pressing `<C-g>` in normal mode updates the float window title to `[Local → agent] README.md:2`, persists `session.compose_destination == "local"`, and `<C-s>` sends `"origin":"local"` in the `comment` RPC payload.
   - Re-opening `compose.open_new` in the same session starts on `[Local → agent]` (sticky!), while pressing `<M-s>` submits `"origin":"github"` without flipping `session.compose_destination`.
   - `<C-g>s` in insert mode still inserts a ```` ```suggestion ```` fence cleanly.
2. In `tests/lua/conversation_suggest_spec.lua`, verify that pressing `c` in `:Jpr conversation`, flipping to `[Local → agent]` with `<C-g>`, and saving with `<C-s>` sends `{ anchor = { kind = "pr", side = "RIGHT" }, body = ..., origin = "local" }`.

- [ ] **Step 2: Run `just test-lua` to confirm failure**

```bash
just test-lua
```

Expected: FAIL (compose does not toggle destination or send `origin`).

- [ ] **Step 3: Implement destination toggling in `compose.lua` and local PR actions in `conversation.lua`**

1. In `lua/jpr/comments/compose.lua` (keeping every function `<= 45` lines):
   - Add `local function alternate_origin(origin) return origin == "local" and "github" or "local" end`.
   - Update `build_title_from_anchor(anchor, origin)`:
     - When `origin == "local"`, prefix `[Local → agent]` (`[Local → agent] PR Conversation`, `[Local → agent] file`, `[Local → agent] file:start-end`, or `[Local → agent] file:line`).
     - When `origin == "github"`, keep `[GitHub comment]` for `pr` and `[GitHub draft]` for file/line/range.
   - When `opts.allow_destination_toggle` is true (in `M.open_new`, and `false` for `open_reply` / `open_edit` / `open_promote`):
     - Track `current_origin = (opts.initial_origin) or session.compose_destination or "github"`.
     - `flip_destination()` flips `current_origin = alternate_origin(current_origin)`, saves `session.compose_destination = current_origin`, and calls `vim.api.nvim_win_set_config(win, { title = " " .. build_title_from_anchor(anchor, current_origin) .. " ", title_pos = "center" })`.
     - Bind `<C-g>` in `"n"` (`nowait = true`) to `flip_destination` and `<C-g>` in `"i"` (without `nowait`, so `<C-g>s` still fires `insert_suggestion_fence` while standalone `<C-g>` or `<C-g><C-g>` flips destination!).
     - Bind `<C-s>` in `{ "n", "i" }` to `submit_with(current_origin)` and `<M-s>` in `{ "n", "i" }` to `submit_with(alternate_origin(current_origin))`.
     - Update footer text to `" <C-s> save · <C-g> flip dest · <M-s> other dest · <C-g>s suggest · q cancel "`.
   - Also add `M.open_promote(session, thread)` pre-populated with `thread.messages[1].body` and titled `"[Promote → GitHub] " .. location`, calling `promoteThread` (`{ threadId = thread_id, body = body }`) on `<C-s>`.
   - Update `M.open_reply` and `M.open_edit` titles to show `[Local reply]` / `[Edit local comment]` when `thread.origin == "local"` or `message.sync == nil`.
2. In `lua/jpr/views/conversation.lua`:
   - Allow `r` to reply on `origin == "local"` PR threads (`compose.open_reply`), `p` to call `compose.open_promote(session, entry.thread)` on local PR threads, `s` to call `require("jpr.agent").send(session, entry.thread_id)` on local PR threads, allow `d` to delete any message in a local thread (`entry.thread.origin == "local" or entry.message.viewerDidAuthor`), and guard `+` on local threads with `jpr.info("reactions apply only to GitHub comments")`.

- [ ] **Step 4: Run `just test-lua`**

```bash
just test-lua
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add lua/jpr/comments/compose.lua lua/jpr/views/conversation.lua tests/lua/compose_spec.lua tests/lua/conversation_suggest_spec.lua
git commit -m "feat(nvim): add compose destination toggle (<C-g>/<M-s>) and local conversation actions"
```

---

### Task 13: Popup promote (`p`), single-thread send (`s`), and live buffer extmark anchor updates (`comments/popup.lua`, `views/threads.lua`, `views/diff/init.lua`)

**Files:**
- Modify: `lua/jpr/comments/popup.lua`
- Modify: `lua/jpr/views/threads.lua`
- Modify: `lua/jpr/views/diff/init.lua`
- Modify: `tests/lua/popup_spec.lua`
- Modify: `tests/lua/threads_view_spec.lua`

Wire `p` (promote local thread's root comment via compose into a GitHub draft) and `s` (send only this local thread to the agent now) in the floating thread popup, relax `d` on local threads so agent pre-pass threads can be deleted, guard `+` on local threads, and report shifted local extmark line spans to `updateLocalAnchors` whenever the reviewer saves an edited buffer (`BufWritePost`).

- [ ] **Step 1: Add failing tests in `tests/lua/popup_spec.lua` and `tests/lua/threads_view_spec.lua`**

1. In `tests/lua/popup_spec.lua`, add tests with a local `ThreadPreview` (`threadId = "loc-1"`, `origin = "local"`, `kind = "local"`, `agent = { state = "unsent" }`):
   - Pressing `p` closes the popup, opens the compose buffer pre-filled with the local thread's first message body, and pressing `<C-s>` sends `promoteThread` (`{ threadId = "loc-1", body = ... }`).
   - Pressing `s` closes the popup and triggers `require("jpr.agent").send(session, "loc-1")`.
   - Pressing `+` on a local thread notifies `"jpr: reactions apply only to GitHub comments"` without sending `toggleReaction`.
2. In `tests/lua/threads_view_spec.lua`:
   - Draw a local thread at line 2 of `README.md`, insert two lines at the top of `README.md` in Neovim, run `:write`, and assert `FAKE_ENGINE_LOG` records an `updateLocalAnchors` RPC call with `path = "README.md"` and `updates = [{ threadId = "loc-1", start = 4, end = 4 }]`.

- [ ] **Step 2: Run `just test-lua` to confirm failure**

```bash
just test-lua
```

Expected: FAIL (`p`, `s`, and `updateLocalAnchors` not yet wired).

- [ ] **Step 3: Implement `popup.lua`, `views/threads.lua`, and `views/diff/init.lua`**

1. In `lua/jpr/comments/popup.lua` (keeping every function `<= 45` lines):
   - Add `promote_current_thread(session)`: checks `entry.thread.origin == "local"` (else `jpr.info("only local threads can be promoted to GitHub")`), closes popup, and calls `require("jpr.comments.compose").open_promote(session, entry.thread)`.
   - Add `send_current_thread(session)`: checks `entry.thread.origin == "local"` (else `jpr.info("only local threads can be sent to the agent")`), closes popup, and calls `require("jpr.agent").send(session, entry.thread_id)`.
   - Guard `toggle_popup_reaction` when `entry.thread.origin == "local"` with `jpr.info("reactions apply only to GitHub comments")`.
   - Allow `delete_current_message` when `entry.thread.origin == "local"` even if `not entry.message.viewerDidAuthor` (so pre-pass agent findings can be deleted).
   - Copy `origin = updated_thread.origin or item.origin`, `agent = updated_thread.agent`, and `promotedTo = updated_thread.promotedTo` inside `merge_updated_thread`.
   - Bind `p` (`promote_current_thread`) and `s` (`send_current_thread`) in `bind_popup_keys`.
2. In `lua/jpr/views/threads.lua`:
   - Add `local anchor_namespace = vim.api.nvim_create_namespace("jpr-local-anchors")`.
   - When `M.draw_on_buffer(session, buf, threads)` runs, clear `anchor_namespace` on `buf` and place range extmarks (`end_row`, `strict = false`) for every `RIGHT`-side `line`/`range` thread with `origin == "local"` or `kind == "local"`, recording `{ thread_id = id, mark_id = mark_id, start = start_line, finish = end_line }` in `session.local_anchor_marks[buf]`. Also clear `anchor_namespace` and `session.local_anchor_marks[buf]` inside `M.clear_buffer`.
   - Add `M.collect_shifted_local_anchors(session, buf)` reading `nvim_buf_get_extmark_by_id(buf, anchor_namespace, item.mark_id, { details = true })` and returning `{ { threadId = item.thread_id, start = new_start, ["end"] = new_end }, ... }` for every mark whose 1-based bounds changed.
3. In `lua/jpr/views/diff/init.lua`'s `BufWritePost` callback:
   - Compute `local updates = require("jpr.views.threads").collect_shifted_local_anchors(session, event.buf)`.
   - When `#updates > 0`, call `require("jpr.session").request(session, "updateLocalAnchors", { path = path, updates = updates }, function() M.refresh_buffer(session, event.buf); require("jpr.views.stream").refresh(session, true) end)`, otherwise refresh immediately as before.

- [ ] **Step 4: Run `just test-lua`**

```bash
just test-lua
```

Expected: PASS.

- [ ] **Step 5: Gate and commit**

```bash
just check
git add lua/jpr/comments/popup.lua lua/jpr/views/threads.lua lua/jpr/views/diff/init.lua tests/lua/popup_spec.lua tests/lua/threads_view_spec.lua
git commit -m "feat(nvim): add popup promote/send keys and live extmark anchor updates on save"
```

---

### Task 14: Agent side panel, bracketed-paste delivery, `:Jpr send`, and `:Jpr prepass` (`lua/jpr/agent.lua`)

**Files:**
- Create: `lua/jpr/agent.lua`
- Create: `tests/lua/agent_spec.lua`

Implement `lua/jpr/agent.lua` (Neovim's `AgentChannel`): `:Jpr agent` opens/hides a right-hand vertical terminal split in `session.worktree` with `JPR_SOCKET` and `JPR_PR` set, choosing `--resume` vs `--session-id` for Claude (verifying `~/.claude/projects/<project-dir>/<id>.jsonl` exists before passing `--resume`) and `codex resume <id>` vs `codex` for Codex; `:Jpr send` and `:Jpr prepass` open/resume the panel if closed, paste sanitized bracketed-paste text, send the delayed submit key (`\r` for Claude, `\t` for Codex after 200ms), and call `confirmSend` only after delivery succeeds.

- [ ] **Step 1: Write failing headless terminal specs in `tests/lua/agent_spec.lua`**

Create `tests/lua/agent_spec.lua` testing both the pure helpers and a real headless Neovim terminal job (`claude_cmd` pointed at a tiny `/bin/sh` cat-to-file fixture script):
1. `build_launch_argv` produces `{ "claude", "--session-id", id }` on first launch or when `isResume == true` but no transcript `.jsonl` exists yet, `{ "claude", "--resume", id }` once `~/.claude/projects/<sanitized>/<id>.jsonl` exists, `{ "codex" }` on fresh Codex launch, and `{ "codex", "resume", id }` on Codex resume.
2. `build_bracketed_paste` strips embedded `\27[201~` / `\27` escape bytes from untrusted comment text and wraps the sanitized prompt in `"\27[200~...\27[201~"`.
3. `:Jpr agent` (`session.agent_current()`) opens a right-side split with `vim.w[win].jpr_side == true` (so `main_window.find(session)` never clobbers the agent terminal!), passes `JPR_SOCKET` and `JPR_PR` into the terminal process environment, hides the window on a second `:Jpr agent` while keeping the terminal buffer alive, and re-shows the same live terminal buffer on a third `:Jpr agent`.
4. `:Jpr send` (`session.send_current()`) auto-opens the closed agent panel, writes the bracketed-paste prompt + delayed `\r` submit key into the terminal PTY (captured by the fixture script), and sends `confirmSend` to the engine only after paste + submit succeed.
5. `:Jpr prepass` (`session.prepass_current()`) requests `preparePrepass`, pastes the pre-pass prompt into the agent terminal, and confirms the pre-pass round via `confirmSend`.

- [ ] **Step 2: Run `just test-lua` to confirm failure**

```bash
just test-lua
```

Expected: FAIL (`module 'jpr.agent' not found`).

- [ ] **Step 3: Implement `lua/jpr/agent.lua`**

Create `lua/jpr/agent.lua` (keeping every function `<= 45` lines):

```lua
-- Neovim AgentChannel: right-hand interactive terminal split (`:Jpr agent`),
-- sanitized bracketed-paste prompt delivery (`:Jpr send`), and `:Jpr prepass`.
local M = {}

--- Sanitizes `worktree` into Claude Code's `~/.claude/projects/<dir>` folder name.
function M.build_claude_project_slug(worktree)
    return (tostring(worktree or ""):gsub("[^%w%-]", "-"))
end

--- Whether Claude Code has already written a transcript for `session_id` in `worktree`.
function M.has_claude_transcript(worktree, session_id, home_dir)
    local home = home_dir or vim.env.HOME or ""
    if home == "" or not session_id or session_id == "" then
        return false
    end
    local slug = M.build_claude_project_slug(worktree)
    local path = ("%s/.claude/projects/%s/%s.jsonl"):format(home, slug, session_id)
    return vim.uv.fs_stat(path) ~= nil
end

--- Builds the argv list for starting or resuming the configured agent CLI.
function M.build_launch_argv(config, worktree, launch_plan, home_dir)
    if launch_plan.kind == "codex" then
        local cmd = config.codex_cmd or "codex"
        if launch_plan.isResume then
            return { cmd, "resume", launch_plan.sessionId }
        end
        return { cmd }
    end
    local cmd = config.claude_cmd or "claude"
    if launch_plan.isResume and M.has_claude_transcript(worktree, launch_plan.sessionId, home_dir) then
        return { cmd, "--resume", launch_plan.sessionId }
    end
    return { cmd, "--session-id", launch_plan.sessionId }
end

--- Strips raw ESC bytes from `prompt` and wraps it in bracketed-paste markers.
function M.build_bracketed_paste(prompt)
    local clean = tostring(prompt or ""):gsub("\27", "")
    return "\27[200~" .. clean .. "\27[201~"
end

--- Maps `profile.submitKey` (`"enter"` or `"tab"`) to its terminal byte sequence.
function M.profile_to_submit_bytes(profile)
    if profile and profile.submitKey == "tab" then
        return "\t"
    end
    return "\r"
end
```

Add window/terminal lifecycle functions below the pure helpers in `lua/jpr/agent.lua` (each `<= 45` lines):
- `open_right_split(session, buf)`: finds the rightmost normal window in `session.tab`, opens `vim.api.nvim_open_win(buf, true, { split = "right", win = target_win, width = require("jpr").config.agent_width or 56 })`, sets `vim.w[win].jpr_side = true`, `vim.wo[win].winfixwidth = true`, `vim.wo[win].number = false`, `vim.wo[win].relativenumber = false`, and `vim.wo[win].signcolumn = "no"`.
- `spawn_terminal(session, launch_plan, on_ready)`: creates an unlisted buffer, opens the right split on it, calls `vim.fn.jobstart(argv, { term = true, cwd = session.worktree, env = { JPR_SOCKET = launch_plan.socket or "", JPR_PR = tostring(session.number) }, on_exit = ... })` (note: in Neovim 0.11+, `jobstart(..., { term = true })` replaces deprecated `termopen`), stores `session.agent = { buf = buf, win = win, job = job, exited = false }`, and invokes `on_ready(session.agent)` if provided.
- `M.ensure_open(session, on_ready)`: if `session.agent` has a live `buf` and `not session.agent.exited`, ensures `session.agent.win` is open (re-splitting if hidden) and calls `on_ready(session.agent)`; otherwise requests `prepareAgentLaunch` (`{ agent = config.agent }`) and calls `spawn_terminal`.
- `M.toggle(session)`: if `session.agent and session.agent.win and vim.api.nvim_win_is_valid(session.agent.win)`, closes `session.agent.win` (`session.agent.win = nil`); otherwise calls `M.ensure_open(session)`.
- `M.deliver_dispatch(session, dispatch)`: calls `M.ensure_open(session, function(agent_state) ... end)`, sends `chansend(agent_state.job, M.build_bracketed_paste(dispatch.prompt))`, defers `dispatch.profile.submitDelayMs or 200` ms via `vim.defer_fn`, sends `chansend(agent_state.job, M.profile_to_submit_bytes(dispatch.profile))`, and only when both writes succeed calls `require("jpr.session").request(session, "confirmSend", { round = dispatch.round, kind = dispatch.kind, threadIds = dispatch.threadIds, prompt = dispatch.prompt }, function() end)`.
- `M.send(session, only_thread_id)`: requests `prepareSend` (`{ threadId = only_thread_id, agent = require("jpr").config.agent }`) and passes the result to `M.deliver_dispatch`.
- `M.prepass(session)`: requests `preparePrepass` (`{ agent = require("jpr").config.agent }`) and passes the result to `M.deliver_dispatch`.
- `M.close(session)`: stops `session.agent.job` when running, closes `session.agent.win`, deletes `session.agent.buf`, and clears `session.agent = nil`.

- [ ] **Step 4: Run `just test-lua`**

```bash
just test-lua
```

Expected: PASS (`agent_spec: ok`).

- [ ] **Step 5: Gate and commit**

```bash
just check
git add lua/jpr/agent.lua tests/lua/agent_spec.lua
git commit -m "feat(nvim): add :Jpr agent side panel, :Jpr send, and :Jpr prepass"
```

---

### Task 15: Documentation updates and `0.4.0` workspace version bump

**Files:**
- Modify: `Cargo.toml`
- Modify: `docs/protocol.md`
- Modify: `docs/architecture.md`
- Modify: `docs/decisions.md`
- Modify: `README.md`

Document protocol v4, the Unix domain socket + locked `local.json` fallback architecture, snapshot + extmark re-anchoring, and all new CLI and `:Jpr` agent commands, and bump the workspace version from `0.3.0` to `0.4.0` (with zero em dashes anywhere).

- [ ] **Step 1: Update `Cargo.toml`, `docs/protocol.md`, `docs/architecture.md`, `docs/decisions.md`, and `README.md`**

1. In `Cargo.toml`, bump workspace `version = "0.3.0"` to `version = "0.4.0"`.
2. In `docs/protocol.md`:
   - Update header and examples to `protocolVersion: 4` and `version: "0.4.0"`.
   - Document the Unix socket transport alongside stdio (`session.json` `socket`, `JPR_SOCKET`, refusal of `shutdown` over socket, immediate event push to stdio).
   - Document `comment`'s `origin` parameter (`"github" | "local"`), the 8 new requests (`agentReply`, `promoteThread`, `prepareAgentLaunch`, `prepareSend`, `confirmSend`, `preparePrepass`, `prepassWrite`, `updateLocalAnchors`), `filesChanged` and `agentRound` events, `AgentThreadState`, `AgentLaunchPlan`, `AgentDispatch`, and `SessionView.localUnsentCount`.
3. In `docs/architecture.md`:
   - Document `local.json` v1, `rounds.jsonl`, `session.json` v3, `local.lock` fallback writes in `review-store-fs`, snapshot re-anchoring + agent prompt/guide modules in `review-core`, `review-rpc`'s socket listener + file watcher, `jpr-review`'s `guide`/`threads`/`reply`/`prepass-write` subcommands, and `lua/jpr/agent.lua`.
4. In `docs/decisions.md`, append two concise sections:
   - `## CLI agent commands talk to the daemon socket first and fall back to local.lock`: why live socket calls push `threadsChanged` to Neovim immediately while `local.lock` keeps `jpr-review reply` and `prepass-write` working when Neovim is closed.
   - `## Two-phase agent dispatch confirms rounds only after bracketed paste succeeds`: why `prepareSend` and `confirmSend` are split so a failed terminal spawn never strands threads in `sent` state, and why ESC bytes are stripped before bracketed paste.
5. In `README.md`:
   - Add `:Jpr agent`, `:Jpr send`, `:Jpr prepass`, compose `<C-g>` / `<M-s>`, popup `p` / `s`, `setup({ agent, claude_cmd, codex_cmd, agent_width })`, and the `jpr-review` CLI subcommands (`guide`, `threads`, `reply`, `prepass-write`).

- [ ] **Step 2: Verify zero em dashes across the repository and run `just check`**

```bash
! rg "\x{2014}" README.md docs Cargo.toml crates lua plugin tests
just check
```

Expected: `! rg` exits 0 and `just check` exits 0.

- [ ] **Step 3: Commit**

```bash
git add Cargo.toml Cargo.lock README.md docs
git commit -m "docs: document protocol v4, local agent loop, and bump workspace to 0.4.0"
```

---

### Task 16: Mandatory `/avandar-code-review`, full `/diff-review`, walkthrough archive, and live smoke verification

**Files:**
- Modify: any files flagged by `/avandar-code-review`
- Create: `docs/code-walkthroughs/2026-11-21_m4-local-comments-agent-loop.md`

Run the mandatory `AGENTS.md` post-implementation review and walkthrough pipeline before requesting human branch approval.

- [ ] **Step 1: Run `/avandar-code-review` across the full branch**

Load `avandar-code-review` (`SKILL.md`) and audit `git diff main...HEAD` against naming (`create_*`, `build_*`, `*_from_*`, `*_to_*`, boolean auxiliary verbs, no `val`/`next`/`prev`/`n`), function length (`<= 45` lines), docstrings/comments (zero em dashes), and immutability/architecture rules. Fix every violation, run `just check`, and commit on `feat/local-comments-agent-loop`:

```bash
just check
git status
# If avandar-code-review made fixes:
git add -A
git commit -m "refactor: address avandar-code-review findings for milestone 4"
```

- [ ] **Step 2: Run full `/diff-review` (Initial mode) and archive the walkthrough**

Load `diff-review` (`SKILL.md`) and run **full Initial mode** against `main...HEAD` (never walkthrough-only mode) so `.difit/` receives the full review guide/explainer comments **and** `.difit/<stem>-walkthrough.md` is generated. Copy the generated walkthrough to `docs/code-walkthroughs/2026-11-21_m4-local-comments-agent-loop.md`, ensure zero em dashes (`! rg "\x{2014}" docs/code-walkthroughs/2026-11-21_m4-local-comments-agent-loop.md`), run `just check`, and commit:

```bash
mkdir -p docs/code-walkthroughs
cp .difit/*-walkthrough.md docs/code-walkthroughs/2026-11-21_m4-local-comments-agent-loop.md
! rg "\x{2014}" docs/code-walkthroughs/2026-11-21_m4-local-comments-agent-loop.md
just check
git add docs/code-walkthroughs/2026-11-21_m4-local-comments-agent-loop.md
git commit -m "docs(walkthrough): archive milestone 4 diff-review code walkthrough"
```

- [ ] **Step 3: Optional live GitHub smoke check and cleanup (if verifying `promoteThread` end-to-end)**

Following `AGENTS.md`'s `PR smoke tests` rules (`--repo jpsyx/jpr-nvim`, fresh `wt new chore smoke-m4-agent` worktree, draft PR closed and branch/state deleted afterward), optionally verify creating a local comment, replying via `jpr-review reply` over `JPR_SOCKET`, promoting the local root comment into a real GitHub pending-review draft via `promoteThread`, and cleaning up every remote/local smoke artifact.

---

## Execution & Review Routing Notes (`super-wrapper` + `finishing-a-development-branch`)

- **Controller gate:** Before dispatching subagents to execute this plan in Antigravity, confirm the controller session runs on **`gemini-4-neon-medium`** (`super-wrapper/references/antigravity.md`). Do **not** dispatch `inherit` subagents from a `gemini-4-carbon-high` or `gemini-4-neon-high` design session.
- **Subagent model tiers:**
  - Use `Model = "inherit"` (from a `gemini-4-neon-medium` controller) for implementer tasks and ordinary spec/code-quality unit reviews (`Tasks 0-3, 6-7, 10-16`).
  - Use `Model = "pro"` for task-level reviews after unit reviews pass on the four `[HIGH-RISK]` tasks (**Task 4**, **Task 5**, **Task 8**, **Task 9**), for any blocked-implementer escalation, and for the final whole-branch code review after Task 16 completes. Never use `flash` or `flash_lite`.
- **Completion & Phase Status Checklist:** At the end of every phase, include the 7-item Phase Status Checklist from `AGENTS.md`. Only switch the final item from `❌` to `👍` and ask for human full-branch review once Tasks 0-16 (including `/avandar-code-review`, full `/diff-review`, copying `docs/code-walkthroughs/2026-11-21_m4-local-comments-agent-loop.md`, and the `pro` whole-branch review) are complete and `just check` passes.
