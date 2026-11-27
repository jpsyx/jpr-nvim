# Design: Top-Right Toasts, In-Progress Indicators, and Sync/Agent Alerts

**Date:** 2026-11-27
**Branch:** `feat/toasts-progress-sync-alerts`
**Status:** Draft (awaiting approval)

## Intent and Why

When reviewing a pull request in `jpr-nvim`, slow GitHub requests (especially submitting a review, pushing commits, syncing, or posting comments) currently leave the user staring at a silent, seemingly frozen UI. At the same time, background polling runs automatically every 60 seconds and local coding agents reply over the Unix socket, but neither surfaces a clear summary of what changed, nor does a non-head-moving sync refresh all open review surfaces.

This change introduces:
1. A unified, `jpr`-owned top-right floating toast stack with consistent semantic color coding (red for errors, green for user-initiated successes, blue for automatic updates, amber for warnings, and animated spinners for in-flight work).
2. In-progress indicators across all async/GitHub operations so the user never sits in an unexplained waiting state, plus an inline submitting state in the Submit Review modal.
3. Engine-computed `SyncDelta` change summaries (filtering out the user's own local actions) with full auto-refresh of open views and blue summary toasts.
4. Blue toast notifications when a local coding agent posts a reply or pre-pass findings.

## Goals, Non-Goals, and Anti-Goals

### Goals
- **One predictable notification area:** All `jpr` errors, successes, warnings, automatic updates, and in-progress spinners appear in a top-right floating toast stack.
- **Clear color semantics:** Red (`error`), green (`success`), blue (`info`/automatic updates), amber (`warn`), and live spinner (`progress`) work identically regardless of whether the user has a third-party Neovim notifier plugin installed.
- **No hanging states:** Every GitHub-bound request shows an immediate spinner toast; fast/local RPC calls show a spinner if they take longer than 150 ms. The Submit Review modal also displays an inline submitting state while in flight.
- **Accurate sync alerts without self-noise:** Background and manual syncs report external changes (files changed, new/updated comments, resolved/reopened threads) in a blue toast and auto-refresh all open review views, while excluding changes the user themselves made locally (own comments/replies, own viewed marks, own pushed commits).
- **Local agent reply alerts:** Agent replies (`agentReply`) and pre-pass findings (`prepassWrite`) trigger blue toasts and refresh any open thread popup showing that thread.

### Non-Goals
- Replacing Neovim's global `vim.notify` for other plugins.
- Adding notification history drawers, interactive toast dismissal keymaps, or mouse-clickable toasts (toasts are non-focusable, non-intrusive, and auto-dismiss).
- Changing the background polling cadence (60 s GitHub sync, 20 s queued-op retry, 2 s worktree watch).

### Anti-Goals
- Flickering toasts on sub-150 ms local operations.
- Double-notifying (e.g., showing both a failed progress toast and a separate error toast for the same request).
- Counting the user's own newly posted comments, queued comments that just landed, or freshly pushed commits as "new" remote changes on the next sync.
- Leaking Neovim or UI concepts into `crates/review-*` (the dependency rule remains binding).

## Approaches Considered

### 1. Notification UI
- **Option A (Chosen): `jpr`-owned top-right floating toast stack (`lua/jpr/notify.lua`).**
  - *Pros:* Guarantees exact red/green/blue/amber color coding and in-place animated progress spinners in every Neovim setup (vanilla or with `snacks`/`noice`/`nvim-notify`). Zero focus stealing.
  - *Tradeoffs:* Adds a small (~250 line) Lua floating-window manager to maintain and test.
- **Option B: Continue calling `vim.notify` with plugin-specific options.**
  - *Why rejected:* Standard `vim.log.levels` cannot distinguish green (success) from blue (automatic update) or render in-place spinners across setups, and falls back to command-line echo in vanilla Neovim.

### 2. In-Progress Coverage
- **Option A (Chosen): Centralized RPC progress tracking in `jpr.session.request` (immediate for GitHub calls, 150 ms delay for fast/local ops) + inline Submit modal state.**
  - *Pros:* Guarantees no operation can silently hang, avoids flicker on instant local ops, and keeps call sites clean.
  - *Tradeoffs:* Requires a small per-method metadata table in Lua.
- **Option B: Add manual progress calls only to `submitReview`, `sync`, and `push`.**
  - *Why rejected:* Leaves comment posting, replies, reactions, thread resolution, promotion, and slow diff loads without feedback.

### 3. Sync Delta & Self-Action Filtering
- **Option A (Chosen): Pure Rust `SyncDelta` computation in `crates/review-core` attached to `Event::Synced`.**
  - *Pros:* Respects the dependency rule (reusable by any future TUI frontend), has direct access to `id_map`, `queued_ops`, `pushed_head`, and full `Thread`/`Message` lists (which `SessionView` does not carry).
  - *Tradeoffs:* Requires bumping `PROTOCOL_VERSION` from 11 to 12.
- **Option B: Diff `SessionView` counts in Lua.**
  - *Why rejected:* `SessionView` only has aggregate counts, not message IDs or `id_map`, so Lua could not reliably filter out the user's own comments/replies or distinguish additions from edits.

## Detailed Design

### 1. Rust Engine & Protocol (`PROTOCOL_VERSION = 12`)

#### `crates/review-model/src/view/mod.rs`
- Add `SyncDelta`:
  ```rust
  #[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
  #[serde(rename_all = "camelCase", default)]
  pub struct SyncDelta {
      pub files_changed: usize,
      pub new_comments: usize,
      pub updated_comments: usize,
      pub resolved_threads: usize,
      pub reopened_threads: usize,
      pub head_moved: bool,
  }
  ```
  With `SyncDelta::is_empty(&self) -> bool`.
- Extend `Event::Synced`:
  ```rust
  Synced {
      view: Box<SessionView>,
      #[serde(default)]
      is_background: bool,
      #[serde(default, skip_serializing_if = "Option::is_none")]
      delta: Option<SyncDelta>,
  }
  ```
- Add two dedicated agent notification events (emitted right after `Event::ThreadsChanged` so existing thread-redraw contracts stay intact):
  ```rust
  AgentReplied {
      thread_id: String,
      author: String,
      #[serde(default, skip_serializing_if = "Option::is_none")]
      file: Option<String>,
      #[serde(default, skip_serializing_if = "Option::is_none")]
      line: Option<u32>,
      view: Box<SessionView>,
  },
  AgentPrepassWritten {
      count: usize,
      view: Box<SessionView>,
  },
  ```

#### `crates/review-core/src/sync_delta.rs` (new pure module)
- Pure function `compute_sync_delta(before: &SyncSnapshot, after: &SyncSnapshot, id_map: &BTreeMap<String, String>, was_own_push: bool) -> SyncDelta`:
  - **Initial sync guard:** If `before.had_pr == false`, `apply_pull` does not emit a `SyncDelta` (`delta: None`).
  - **Head moved:** `head_moved = !was_own_push && before.head_sha != after.head_sha`.
  - **Files changed:** If `was_own_push` is `true`, `files_changed = 0`. Otherwise count PR files that were added, removed, had changed `additions`/`deletions`, or transitioned from `ViewedState::Viewed` to `ViewedState::Dismissed` on GitHub.
  - **Comments & threads (GitHub origin only):**
    - Build the set of known message IDs from `before.threads`, plus their canonical mapped IDs from `id_map` (so a queued `tmp-*` comment that just landed and came back with a real GitHub ID is recognized as already seen).
    - `new_comments`: GitHub messages in `after.threads` whose ID is NOT in the known set.
    - `updated_comments`: GitHub messages present in both `before` and `after` (by canonical ID) whose `body` changed.
    - `resolved_threads` / `reopened_threads`: GitHub threads present in both `before` and `after` (by canonical ID) whose `state` transitioned `Open -> Resolved` or `Resolved -> Open`.
- In `crates/review-core/src/session/sync.rs`:
  - Capture `before` snapshot at the start of `apply_pull` (before `reconcile_pulled_state`), check `was_own_push` against `self.pushed_head`, and after reconciliation compute `delta` (set to `None` when `!had_pr` or `delta.is_empty()`).
  - Pass `is_background` through to `Event::Synced`.
- In `crates/review-core/src/session/local.rs` (`agent_reply`):
  - After `save_and_announce_threads()`, publish `Event::AgentReplied` with `thread_id`, `author`, `anchor.file`, `anchor.start` (or `end`), and `view`.
- In `crates/review-core/src/session/agent_loop.rs` (`prepass_write`):
  - After publishing `Event::ThreadsChanged`, publish `Event::AgentPrepassWritten { count: created.len(), view }`.
- Bump `PROTOCOL_VERSION = 12` in `crates/review-rpc/src/protocol.rs` and `lua/jpr/rpc.lua`; update `docs/protocol.md` and `docs/architecture.md`.

### 2. Top-Right Floating Toast Stack (`lua/jpr/notify.lua`)

- **Highlight groups** (in `lua/jpr/highlights/init.lua`, `default = true`):
  - `JprNotifyErrorBorder` / `JprNotifyErrorTitle` -> `DiagnosticError` (red)
  - `JprNotifySuccessBorder` / `JprNotifySuccessTitle` -> `DiagnosticOk` (green)
  - `JprNotifyInfoBorder` / `JprNotifyInfoTitle` -> `DiagnosticInfo` (blue)
  - `JprNotifyWarnBorder` / `JprNotifyWarnTitle` -> `DiagnosticWarn` (amber/yellow)
  - `JprNotifyProgressBorder` / `JprNotifyProgressTitle` -> `DiagnosticInfo` (blue)
- **Window geometry & stacking:**
  - Floating windows with `relative = "editor"`, `anchor = "NE"`, `col = vim.o.columns - 1`, `row` stacked downward from row 1 with 1-row gaps, `border = "rounded"`, `style = "minimal"`, `focusable = false`, `zindex = 250`.
  - Width clamped to `math.min(56, math.max(24, vim.o.columns - 4))`, wrapped lines, capped at max 6 visible toasts (evicting oldest non-progress toast when full).
  - Reflows remaining toasts cleanly whenever any toast closes or resizes.
- **Public API:**
  - `notify.error(message, opts)` -> red, 6000 ms timeout
  - `notify.success(message, opts)` -> green, 3500 ms timeout
  - `notify.info(message, opts)` -> blue, 4500 ms timeout
  - `notify.warn(message, opts)` -> amber, 5000 ms timeout
  - `notify.progress(message, opts)` -> returns a handle `{ update(msg), succeed(msg?), fail(msg), cancel() }`.
    - Supports `opts.delay_ms` (default `0`): if > 0, defers opening the toast window until `delay_ms` elapses; if `cancel()` or `succeed(nil)` fires before the timer, nothing ever flashes on screen.
    - Drives a shared 80 ms `vim.uv.new_timer()` Braille spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) only while at least one visible progress toast is active.
  - `notify.clear()` -> closes all toasts and stops all timers (called on `VimLeavePre` and in test teardown).
- **Plugin-wide wiring (`lua/jpr/init.lua`):**
  - `jpr.error(msg)` -> `notify.error(msg)`
  - `jpr.warn(msg)` -> `notify.warn(msg)`
  - `jpr.success(msg)` -> `notify.success(msg)`
  - `jpr.info(msg)` -> `notify.info(msg)`
  - `jpr.progress(msg, opts)` -> `notify.progress(msg, opts)`
  - Update user-initiated success notifications (`review submitted`, `pushed <sha>`, `<mode> view`, etc.) to `jpr.success(...)`.

### 3. In-Progress Indicators Across Operations

- **Centralized RPC progress (`lua/jpr/session/init.lua`):**
  - Add a pure method-to-progress-spec table (`lua/jpr/session/progress.lua` or inline helper):
    - **Immediate (`delay_ms = 0`)** for GitHub-bound operations: `submitReview`, `sync`, `push`, `comment` (when `origin ~= "local"`), `reply` (when GitHub), `editMessage`, `deleteMessage`, `setResolved`, `toggleReaction`, `retryMessage`, `promoteThread`, `suggestFromEdit`, `submitPreview`.
    - **Delayed (`delay_ms = 150`)** for fast/local operations: `setViewed`, `fileDiff`, `stream`, `threads`, `mentions`, `anchoredLines`, `prepareAgentLaunch`, `prepareSend`, `confirmSend`, `preparePrepass`, `prepareConflictResolution`, `refreshWorktree`, `setCollapsed`, local comments.
  - `session.request(session, method, params, on_result, on_error, opts)` opens a progress handle automatically:
    - On auth-required pause: cancels the spinner while the auth modal is open (the retry starts a fresh spinner).
    - On error: transitions the handle to red via `handle:fail(...)` (no duplicate `jpr.error()` toast).
    - On success: if `opts.success_message` is provided (string or function of result), calls `handle:succeed(msg)`; otherwise calls `handle:cancel()`.
  - `sync_session` in `lua/jpr/session/commands.lua` uses the same progress lifecycle (`"Syncing with GitHub..."`, transitioning to green `"Synced with GitHub"` when no external delta toast is shown, or cancelling cleanly when `Synced` already emits a blue delta toast, and transitioning to red on failure).
- **Inline Submit Review Modal State (`lua/jpr/views/submit.lua` & `lua/jpr/render/submit.lua`):**
  - Pass `in_flight` to `render.build(preview, event, body_lines, { is_submitting = state.in_flight })`.
  - When `is_submitting == true`, display an inline status line (`"Submitting review to GitHub..."`) and hide/dim action hints while keeping the modal open until the request finishes.
  - On completion: close modal and transition the progress toast to green `"Review submitted"`. On failure: clear `state.in_flight`, repaint modal, and transition the toast to red with the error.
- **Stream diff progress (`lua/jpr/session/events.lua`):**
  - Outside the initial loading screen (`session.loading`), route `streamProgress` notifications into the active `stream` progress toast (`handle:update(...)`) instead of `vim.api.nvim_echo`. Remove the `vim.api.nvim_echo` in `lua/jpr/views/diff/init.lua` now that `fileDiff` is covered by the delayed progress toast.

### 4. Auto-Refresh and Blue Notifications on Sync & Agent Events

- **`lua/jpr/session/events.lua`:**
  - On `Event::Synced`:
    - Call `show_session(session, params.view)`.
    - If `params.delta` is present and non-empty:
      - If `delta.filesChanged > 0` or `delta.headMoved`: call `diff.redraw_all(session)` and `stream.refresh(session, true)`.
      - If `delta.newComments > 0` or `delta.updatedComments > 0` or `delta.resolvedThreads > 0` or `delta.reopenedThreads > 0`: call `diff.redraw_threads(session)`, `stream.refresh(session, true)`, refresh `conversation` if open, and refresh `popup` if open.
      - Format a concise human-readable summary (e.g., `"3 files changed, 2 new comments"`) and show it via `jpr.info(...)` (blue toast).
  - On `Event::AgentReplied`:
    - Format location (`src/a.rs:42` or `PR conversation`) and show a blue toast via `jpr.info(...)` (e.g., `"Agent replied on src/a.rs:42"`).
    - Refresh the open thread popup if it currently displays `params.threadId`.
  - On `Event::AgentPrepassWritten`:
    - Show a blue toast via `jpr.info(...)` (e.g., `"Agent added 3 pre-pass findings"`).

## What Is Left to the Builder

- Exact Braille spinner frames, toast padding/border styling, and auto-dismiss durations (defaults above are starting points).
- Exact wording of per-method progress labels and pluralization helpers (`1 file changed` vs `3 files changed`).
- Ensuring all existing Lua specs that stub `vim.notify` or assert on `jpr.error`/`jpr.info` are updated cleanly and new red/green TDD specs cover `SyncDelta`, self-action filtering, `Event::AgentReplied`, `jpr.notify` stacking/colors/spinners, submit modal in-flight state, and sync auto-refresh.
