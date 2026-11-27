# Top-Right Toasts, In-Progress Indicators, and Sync/Agent Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `jpr`-owned color-coded top-right floating toast stack with live in-progress spinners across all async/GitHub operations, inline Submit Review modal progress, engine-computed `SyncDelta` auto-refresh alerts (filtering out the user's own actions), and blue notifications for local agent replies and pre-pass findings.

**Architecture:** The Rust engine (`review-model`, `review-core`, `review-rpc`, bumped to `PROTOCOL_VERSION = 12`) computes pure `SyncDelta` diffs with self-action filtering and emits `AgentReplied` / `AgentPrepassWritten` events so the dependency rule holds and any future frontend reuses the same logic. On the Neovim side, `lua/jpr/notify.lua` manages a non-focusable top-right floating toast stack with semantic red/green/blue/amber highlights and animated progress handles, wired into centralized RPC progress tracking in `jpr.session`, the Submit Review modal, and `jpr.session.events` auto-refresh handlers.

**Tech Stack:** Rust (edition 2024, `serde`, `anyhow`), Neovim Lua (`vim.api.nvim_open_win`, `vim.uv.new_timer`), `just check` (`cargo fmt`, `cargo clippy -- -D warnings`, `cargo test --workspace --all-features`, `./scripts/test-lua.sh`).

**Spec:** `docs/superpowers/specs/2026-11-27-toasts-progress-sync-alerts-design.md`

## Global Constraints

- **Dependency rule:** `crates/review-*` crates never depend on Neovim, Lua, `cli-tui`, or any UI crate.
- **Protocol lockstep:** Bump `PROTOCOL_VERSION` from `11` to `12` in both `crates/review-rpc/src/protocol.rs` and `lua/jpr/rpc.lua`, and update `docs/protocol.md` and `docs/architecture.md` in the same change.
- **No `unsafe` Rust; clippy pedantic + nursery clean (`-D warnings`).**
- **Keep functions short (<= 45 lines); no em dashes (`—`) in comments or copy.**
- **No double notifications:** `jpr.notify` renders its own top-right floating toast windows and never calls `vim.notify`. Failed progress toasts transition in place to red without emitting a second error toast.
- **Red/green TDD:** Write a failing test and verify it fails before writing implementation code for every task.

## Review Focus

1. **Initial PR sync must not alert:** First sync after opening a PR (`before.had_pr == false`) must emit `delta: None` so opening a PR never fires a noisy "N files changed" toast. (Pinned in Task 2 & Task 3)
2. **Queued `tmp-*` comments landing via `id_map` must not alert:** A comment queued offline with a temporary ID that lands on GitHub and returns with its real ID in `id_map` must not be counted in `new_comments`. (Pinned in Task 2)
3. **Own `:Jpr push` must not alert:** When `pushed_head` matches the pulled `pr.head_sha`, `files_changed` must be `0` and `head_moved` must be `false`. (Pinned in Task 2 & Task 3)
4. **Fast local RPCs (< 150 ms) must not flicker:** A `progress` handle created with `delay_ms = 150` that is cancelled before 150 ms must never open a window and must stop its delay timer cleanly. (Pinned in Task 4)
5. **Teardown while spinners are active:** Closing a session or invoking `notify.clear()` while progress toasts are spinning must close all windows and stop all timers without raising errors. (Pinned in Task 4 & Task 5)

---

### Task 1: Protocol v12 Model Types (`SyncDelta`, `Event::Synced`, `Event::AgentReplied`, `Event::AgentPrepassWritten`)

**Files:**
- Modify: `crates/review-model/src/view/mod.rs`
- Modify: `crates/review-model/src/view/tests.rs` (or inline test module)
- Modify: `crates/review-model/src/lib.rs` (re-export `SyncDelta`)

**Interfaces:**
- Produces:
  - `review_model::SyncDelta { files_changed: usize, new_comments: usize, updated_comments: usize, resolved_threads: usize, reopened_threads: usize, head_moved: bool }` with `pub const fn is_empty(&self) -> bool`
  - `Event::Synced { view: Box<SessionView>, is_background: bool, delta: Option<SyncDelta> }`
  - `Event::AgentReplied { thread_id: String, author: String, file: Option<String>, line: Option<u32>, view: Box<SessionView> }`
  - `Event::AgentPrepassWritten { count: usize, view: Box<SessionView> }`

- [ ] **Step 1: Write failing serialization and `is_empty` unit tests**

In `crates/review-model/src/view/tests.rs`, add tests:
- `sync_delta_is_empty_only_when_all_fields_zero_and_false`: asserts `SyncDelta::default().is_empty()` is `true`, and flipping any single field makes `is_empty()` return `false`.
- `event_synced_omits_delta_when_none_and_serializes_camel_case_when_some`: serializes `Event::Synced` with `delta: None` (verifying `"delta"` key is omitted and `"isBackground"` is present) and with `delta: Some(SyncDelta { files_changed: 3, new_comments: 2, ..Default::default() })` (verifying `"filesChanged": 3`, `"newComments": 2`).
- `event_agent_replied_and_prepass_written_serialize_camel_case`: verifies `type: "agentReplied"` with `threadId`, `author`, optional `file`/`line`, and `type: "agentPrepassWritten"` with `count`.

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test -p review-model`
Expected: FAIL (missing `SyncDelta`, missing `Event::AgentReplied` / `Event::AgentPrepassWritten`, missing `Synced` fields).

- [ ] **Step 3: Implement `SyncDelta` and updated `Event` variants**

Add `SyncDelta` (with `#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]` and `#[serde(rename_all = "camelCase", default)]`) and `SyncDelta::is_empty(&self) -> bool` in `crates/review-model/src/view/mod.rs`. Re-export `SyncDelta` from `crates/review-model/src/lib.rs`. Update `Event::Synced` and add `Event::AgentReplied` and `Event::AgentPrepassWritten`. Fix any exhaustive pattern matches on `Event::Synced` across workspace crates (`crates/review-core`, `crates/review-rpc`).

- [ ] **Step 4: Run tests to verify pass**

Run: `cargo test -p review-model`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/review-model crates/review-core crates/review-rpc
git commit -m "feat(model): add SyncDelta, AgentReplied, and AgentPrepassWritten events"
```

---

### Task 2: Pure `SyncDelta` Computation and Self-Action Filtering in `review-core`

**Files:**
- Create: `crates/review-core/src/sync_delta.rs`
- Modify: `crates/review-core/src/lib.rs` (declare module `pub(crate) mod sync_delta;`)

**Interfaces:**
- Consumes: `review_model::{ChangedFile, Origin, SyncDelta, Thread, ThreadState, ViewedState}`
- Produces:
  - `pub(crate) struct SyncComparisonSnapshot { pub had_pr: bool, pub head_sha: Option<String>, pub files: Vec<ChangedFile>, pub threads: Vec<Thread> }`
  - `pub(crate) fn compute_sync_delta(before: &SyncComparisonSnapshot, after: &SyncComparisonSnapshot, id_map: &BTreeMap<String, String>, was_own_push: bool) -> Option<SyncDelta>`

- [ ] **Step 1: Write failing unit tests in `crates/review-core/src/sync_delta.rs`**

Add `#[cfg(test)] mod tests` covering:
- `returns_none_on_initial_sync`: `before.had_pr == false` returns `None` even when `after` has files and comments.
- `returns_none_when_nothing_changed`: identical before/after returns `None`.
- `counts_added_removed_edited_and_dismissed_files`: verifies `files_changed` counts newly added files, removed files, files with changed `additions`/`deletions`, and `Viewed -> Dismissed` transitions, while ignoring `Unviewed -> Viewed` (own viewed mark).
- `ignores_file_and_head_changes_for_own_push`: when `was_own_push == true`, `files_changed == 0` and `head_moved == false` even if `head_sha` and files changed, while still counting external `new_comments`.
- `filters_out_own_optimistic_and_mapped_comments_via_id_map`: a message whose pre-sync ID was `tmp-m-1` mapped to `PRRC_99` in `id_map` is NOT counted as `new_comments`, whereas an unseen `PRRC_100` IS counted.
- `counts_updated_comments_and_thread_state_transitions_only_for_github_threads`: verifies `updated_comments` (body changed), `resolved_threads` (`Open -> Resolved`), `reopened_threads` (`Resolved -> Open`), and ignores `Origin::Local` threads.

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test -p review-core sync_delta`
Expected: FAIL (`sync_delta` module/function not found).

- [ ] **Step 3: Implement `compute_sync_delta` in `crates/review-core/src/sync_delta.rs`**

Keep helper functions <= 45 lines each:
- `count_remote_file_changes(before_files, after_files) -> usize`
- `build_known_message_map(before_threads, id_map) -> BTreeMap<String, &str>` (maps both original ID and `id_map` canonical ID to pre-sync body)
- `count_thread_and_comment_deltas(before_threads, after_threads, id_map) -> (usize, usize, usize, usize)`
- `compute_sync_delta(...) -> Option<SyncDelta>` returning `None` when `!before.had_pr` or `delta.is_empty()`.

- [ ] **Step 4: Run tests to verify pass**

Run: `cargo test -p review-core sync_delta`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/review-core/src/sync_delta.rs crates/review-core/src/lib.rs
git commit -m "feat(core): add pure SyncDelta computation with self-action filtering"
```

---

### Task 3: Wire `SyncDelta`, `AgentReplied`, `AgentPrepassWritten`, and Protocol v12

**Files:**
- Modify: `crates/review-core/src/session/sync.rs`
- Modify: `crates/review-core/src/session/local.rs`
- Modify: `crates/review-core/src/session/agent_loop.rs`
- Modify: `crates/review-core/src/session/sync/tests.rs` (or `crates/review-core/src/session/sync.rs` tests)
- Modify: `crates/review-rpc/src/protocol.rs` (`PROTOCOL_VERSION = 12`)
- Modify: `lua/jpr/rpc.lua` (`M.PROTOCOL_VERSION = 12`)
- Modify: `docs/protocol.md` (document v12 changes)
- Modify: `docs/architecture.md` (document `sync_delta.rs`, `PROTOCOL_VERSION = 12`)

**Interfaces:**
- Consumes: `crate::sync_delta::{SyncComparisonSnapshot, compute_sync_delta}`
- Produces:
  - `ReviewSession::sync` / `sync_background` emitting `Event::Synced { view, is_background, delta }`
  - `ReviewSession::agent_reply` emitting `Event::ThreadsChanged` followed by `Event::AgentReplied`
  - `ReviewSession::prepass_write` emitting `Event::ThreadsChanged` followed by `Event::AgentPrepassWritten`
  - `PROTOCOL_VERSION = 12` in Rust and Lua

- [ ] **Step 1: Write failing integration tests in `review-core`**

Add tests in `crates/review-core/src/session/`:
- `initial_sync_emits_synced_with_no_delta`: first `sync()` emits `Event::Synced { delta: None, is_background: false, .. }`.
- `background_sync_with_remote_changes_emits_delta_excluding_own_comments`: after initial sync, reviewer posts a comment (lands on fake forge), then fake forge adds 1 external comment and 1 new file; `sync_background()` emits `Event::Synced { is_background: true, delta: Some(SyncDelta { files_changed: 1, new_comments: 1, .. }), .. }` (not counting reviewer's own comment).
- `sync_after_own_push_omits_file_and_head_delta`: after `push()`, next `sync()` returns `delta: None` when only the pushed commit's files/HEAD changed.
- `agent_reply_emits_agent_replied_event_with_location`: `agent_reply("loc-1", "Fixed it", Some("claude"))` emits `Event::AgentReplied { thread_id: "loc-1", author: "claude", file: Some("src/a.rs"), line: Some(2), .. }`.
- `prepass_write_emits_agent_prepass_written_event`: `prepass_write` with 2 findings emits `Event::AgentPrepassWritten { count: 2, .. }`.

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test -p review-core`
Expected: FAIL.

- [ ] **Step 3: Wire events in `sync.rs`, `local.rs`, `agent_loop.rs`, bump protocol to v12, update docs**

- In `crates/review-core/src/session/sync.rs`:
  - Pass `is_background: bool` into `apply_pull`.
  - Capture `before = SyncComparisonSnapshot` before `reconcile_pulled_state`, compute `was_own_push` from `self.pushed_head.as_ref().is_some_and(|p| p.pushed_sha == pr_head_sha)`, and after reconciliation compute `delta = compute_sync_delta(&before, &after, &self.saved.registry.id_map, was_own_push)`.
  - Emit `Event::Synced { view: Box::new(view.clone()), is_background, delta }`.
- In `crates/review-core/src/session/local.rs`:
  - In `agent_reply`, after `save_and_announce_threads()`, publish `Event::AgentReplied` with `thread_id`, `author`, `updated.anchor.file`, `updated.anchor.start.or(updated.anchor.end)`, and `view`.
- In `crates/review-core/src/session/agent_loop.rs`:
  - In `prepass_write`, after publishing `Event::ThreadsChanged`, publish `Event::AgentPrepassWritten { count: created.len(), view: Box::new(view.clone()) }`.
- Bump `PROTOCOL_VERSION = 12` in `crates/review-rpc/src/protocol.rs` and `lua/jpr/rpc.lua` (and update any protocol-version assertions in tests).
- Update `docs/protocol.md` and `docs/architecture.md` with v12 event shapes.

- [ ] **Step 4: Run full Rust test suite and clippy**

Run: `cargo test --workspace --all-features && cargo clippy --workspace --all-targets --all-features -- -D warnings`
Expected: PASS with zero warnings.

- [ ] **Step 5: Commit**

```bash
git add crates/ lua/jpr/rpc.lua docs/protocol.md docs/architecture.md
git commit -m "feat(engine): emit SyncDelta, AgentReplied, and AgentPrepassWritten (protocol v12)"
```

---

### Task 4: `jpr.notify` Top-Right Color-Coded Floating Toast Stack & Highlights

**Files:**
- Modify: `lua/jpr/highlights/init.lua`
- Create: `lua/jpr/notify.lua`
- Modify: `lua/jpr/init.lua`
- Create: `tests/lua/notify_spec.lua`
- Modify: existing `tests/lua/*.lua` specs that stub `vim.notify` to capture `jpr` notifications via `jpr.notify.set_listener` (or `get_history`)

**Interfaces:**
- Produces in `lua/jpr/notify.lua`:
  - `M.error(message, opts?) -> toast_id`
  - `M.success(message, opts?) -> toast_id`
  - `M.info(message, opts?) -> toast_id`
  - `M.warn(message, opts?) -> toast_id`
  - `M.progress(message, opts?) -> { update(msg), succeed(msg?), fail(msg), cancel() }`
  - `M.get_toasts() -> table[]` (active visible toasts, for inspection/tests)
  - `M.set_listener(fn | nil)` (optional callback `(kind, message)` for tests without touching `vim.notify`)
  - `M.clear()` (closes all toast windows, stops all timers)
- Produces in `lua/jpr/init.lua`:
  - `M.error(message)`, `M.warn(message)`, `M.success(message)`, `M.info(message)`, `M.progress(message, opts?)`

- [ ] **Step 1: Write failing Lua spec `tests/lua/notify_spec.lua`**

Tests to include:
- Highlight links: `JprNotifyErrorBorder`/`Title` -> `DiagnosticError`, `JprNotifySuccessBorder`/`Title` -> `DiagnosticOk`, `JprNotifyInfoBorder`/`Title` -> `DiagnosticInfo`, `JprNotifyWarnBorder`/`Title` -> `DiagnosticWarn`, `JprNotifyProgressBorder`/`Title` -> `DiagnosticInfo`.
- Top-right window placement: calling `notify.error("boom")` opens a non-focusable (`focusable = false`) floating window with `anchor = "NE"`, border highlight `JprNotifyErrorBorder`, and does NOT call `vim.notify`.
- Color coding per kind: `error` uses `JprNotifyError*`, `success` uses `JprNotifySuccess*`, `info` uses `JprNotifyInfo*`, `warn` uses `JprNotifyWarn*`.
- Stacking and reflow: opening 3 toasts stacks their `row` values monotonically downward without overlap; dismissing the first reflows the remaining two upward; exceeding max 6 toasts evicts the oldest non-progress toast.
- Progress lifecycle (immediate): `notify.progress("Submitting...")` opens a visible toast immediately; `handle:update("Almost done...")` updates its buffer text in place without opening a second window; `handle:succeed("Review submitted")` transitions its highlight to `JprNotifySuccess*`; `handle:fail("boom")` transitions to `JprNotifyError*`.
- Delayed progress (no flicker): `notify.progress("Fast op", { delay_ms = 150 })` followed immediately by `handle:cancel()` never opens a floating window; if not cancelled, it opens after ~160 ms.
- Clean teardown: `notify.clear()` closes all windows and stops all active timers cleanly even while progress spinners are running.

- [ ] **Step 2: Run Lua spec to verify failure**

Run: `./scripts/test-lua.sh tests/lua/notify_spec.lua`
Expected: FAIL (`module 'jpr.notify' not found`).

- [ ] **Step 3: Implement highlights, `lua/jpr/notify.lua`, and wire `lua/jpr/init.lua`**

- Add `JprNotify*` semantic links to `SEMANTIC_LINKS` in `lua/jpr/highlights/init.lua`.
- Implement `lua/jpr/notify.lua` with:
  - Top-right `anchor = "NE"`, `relative = "editor"`, `border = "rounded"`, `focusable = false`, `zindex = 250`, `winhighlight` mapping `FloatBorder` and `FloatTitle` to the kind's semantic highlight groups.
  - Shared 80 ms spinner timer (Braille frames `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`), started only while visible progress toasts exist and stopped immediately when none remain.
  - Per-toast auto-dismiss timer (`error`: 6000 ms, `warn`: 5000 ms, `info`: 4500 ms, `success`: 3500 ms; configurable via `opts.timeout_ms`).
  - `VimLeavePre` autocmd calling `M.clear()`.
- Route `jpr.error`, `jpr.warn`, `jpr.info` through `jpr.notify` in `lua/jpr/init.lua`, and add `jpr.success` and `jpr.progress`.
- Update existing `tests/lua/*_spec.lua` files that stubbed `vim.notify` to listen via `require("jpr.notify").set_listener(...)` (and clear toasts in teardown) so the entire Lua suite stays green.

- [ ] **Step 4: Run full Lua test suite**

Run: `./scripts/test-lua.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/highlights/init.lua lua/jpr/notify.lua lua/jpr/init.lua tests/lua/
git commit -m "feat(nvim): add color-coded top-right toast stack with live progress spinners"
```

---

### Task 5: Centralized RPC In-Progress Indicators & Submit Review Modal Progress

**Files:**
- Create: `lua/jpr/session/progress.lua`
- Modify: `lua/jpr/session/init.lua`
- Modify: `lua/jpr/session/commands.lua`
- Modify: `lua/jpr/render/submit.lua`
- Modify: `lua/jpr/views/submit.lua`
- Modify: `lua/jpr/views/diff/init.lua`
- Modify: `lua/jpr/session/events.lua` (`streamProgress` updates active stream toast instead of `nvim_echo`)
- Create: `tests/lua/progress_and_submit_spec.lua`

**Interfaces:**
- Produces in `lua/jpr/session/progress.lua`:
  - `M.get_spec_from_request(method, params) -> { label: string, delay_ms: integer } | nil`
  - `M.start(session, method, params, opts?) -> handle | nil`
  - `M.cancel_all(session)` (called on `forget` / session teardown)
- Consumes: `jpr.notify.progress`

- [ ] **Step 1: Write failing Lua spec `tests/lua/progress_and_submit_spec.lua`**

Tests to include:
- `get_spec_from_request` returns `delay_ms = 0` for GitHub-bound methods (`submitReview`, `sync`, `push`, `submitPreview`, `promoteThread`, `suggestFromEdit`, `comment` with `origin = "github"`, `reply`, `editMessage`, `deleteMessage`, `setResolved`, `toggleReaction`, `retryMessage`) and `delay_ms = 150` for fast/local methods (`fileDiff`, `stream`, `setViewed`, `threads`, `comment` with `origin = "local"`, `refreshWorktree`).
- `session.request` starts a progress toast while in flight, transitions it to red on error (with only 1 error toast, never 2), transitions to green when `opts.success_message` is provided, and cancels cleanly when `forget` closes the session mid-request.
- `session.sync` shows `"Syncing with GitHub..."` immediately while in flight, transitions to red on failure, and transitions cleanly on success.
- `session.push` shows `"Pushing commits to GitHub..."` immediately while in flight and transitions to green `"pushed <sha>"` on success.
- Submit Review modal: while `submitReview` is in flight, `render.build(preview, event, body_lines, { is_submitting = true })` renders an inline `"Submitting review to GitHub..."` status line; on success the modal closes and the progress toast transitions to green `"Review submitted"`; on error the modal stays open, clears `in_flight`, repaints without the submitting banner, and the progress toast transitions to red.
- `streamProgress` outside initial loading updates the active stream progress toast in place instead of calling `vim.api.nvim_echo`.

- [ ] **Step 2: Run Lua spec to verify failure**

Run: `./scripts/test-lua.sh tests/lua/progress_and_submit_spec.lua`
Expected: FAIL.

- [ ] **Step 3: Implement `progress.lua`, wire `session/init.lua`, `session/commands.lua`, `views/submit.lua`, `render/submit.lua`, `views/diff/init.lua`, `session/events.lua`**

- Create `lua/jpr/session/progress.lua` with `get_spec_from_request`, `start` (tracking active handles on `session.active_progress`), and `cancel_all(session)`.
- Update `session.request(session, method, params, on_result, on_error, opts)` to start/track progress, cancel on auth pause, fail in place on error (without duplicate `jpr.error`), and succeed/cancel on result. Call `progress.cancel_all(session)` in `forget(session)`.
- Update `sync_session` and `push_session` in `lua/jpr/session/commands.lua` to use progress handles and `jpr.success` for user-initiated successes (`pushed <sha>`, `<mode> view`).
- Update `lua/jpr/render/submit.lua` to accept optional 4th param `opts` (`{ is_submitting = boolean }`), displaying `"Submitting review to GitHub..."` (highlighted with `JprNotifyProgressTitle`) when `is_submitting` is true.
- Update `lua/jpr/views/submit.lua` to call `paint_modal(state)` when setting `state.in_flight = true` and again on error when clearing `state.in_flight = false`, passing `{ success_message = "Review submitted" }` to `session.request`.
- Update `lua/jpr/views/diff/init.lua` to remove `vim.api.nvim_echo` loading/clearing lines (now handled by delayed `fileDiff` progress toast).
- Update `handle_stream_progress` in `lua/jpr/session/events.lua` to update `session.stream_progress_handle` in place (creating one if needed and cancelling when `stream` finishes).

- [ ] **Step 4: Run full Lua test suite**

Run: `./scripts/test-lua.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/ tests/lua/progress_and_submit_spec.lua
git commit -m "feat(nvim): show in-progress toast indicators for RPC ops and submit modal"
```

---

### Task 6: Sync Auto-Refresh & Blue Notifications for Sync Deltas and Local Agent Replies

**Files:**
- Modify: `lua/jpr/session/events.lua`
- Modify: `lua/jpr/comments/popup.lua` (refresh open popup when threads change / agent replies)
- Modify: `docs/architecture.md` (document `jpr.notify`, `jpr.session.progress`, sync delta auto-refresh, and agent reply alerts)
- Create: `tests/lua/sync_and_agent_alerts_spec.lua`

**Interfaces:**
- Consumes:
  - Protocol v12 `Event::Synced { view, isBackground, delta }`
  - Protocol v12 `Event::AgentReplied { threadId, author, file, line, view }`
  - Protocol v12 `Event::AgentPrepassWritten { count, view }`
  - `jpr.info` (blue toast)
- Produces:
  - Pure formatter `events.build_sync_delta_message(session, delta) -> string | nil`
  - Pure formatter `events.build_agent_reply_message(params) -> string`

- [ ] **Step 1: Write failing Lua spec `tests/lua/sync_and_agent_alerts_spec.lua`**

Tests to include:
- `build_sync_delta_message` formats pluralized summaries cleanly:
  - `{ filesChanged = 3, newComments = 2 }` -> `"PR #7 updated: 3 files changed, 2 new comments"`
  - `{ filesChanged = 1, newComments = 1, updatedComments = 1, resolvedThreads = 1, reopenedThreads = 1 }` -> singular forms (`1 file changed`, `1 new comment`, `1 comment edited`, `1 thread resolved`, `1 thread reopened`).
  - `nil` or all-zero delta -> `nil` (no toast emitted).
- `synced` notification with non-empty `delta`:
  - Emits a **blue** (`info`) toast with the formatted summary.
  - When `delta.filesChanged > 0`, calls `diff.redraw_all(session)` and `stream.refresh(session, true)`.
  - When `delta.newComments > 0`, calls `diff.redraw_threads(session)`, `stream.refresh(session, true)`, and refreshes open `conversation` view.
- `synced` notification with `delta = nil`: redraws panel/views normally and emits NO blue change-summary toast.
- `agentReplied` notification:
  - Emits a **blue** (`info`) toast: `"claude replied on src/a.rs:42"` (or `"agent replied on PR conversation"` when `file` is nil).
  - Refreshes the open thread popup if it is displaying `params.threadId`.
- `agentPrepassWritten` notification:
  - Emits a **blue** (`info`) toast: `"Agent added 3 pre-pass findings"` (singular `"1 pre-pass finding"` for count 1).

- [ ] **Step 2: Run Lua spec to verify failure**

Run: `./scripts/test-lua.sh tests/lua/sync_and_agent_alerts_spec.lua`
Expected: FAIL.

- [ ] **Step 3: Implement sync delta auto-refresh, agent reply/prepass handlers, and docs**

- In `lua/jpr/session/events.lua`:
  - Add pure helpers `M.build_sync_delta_message(session, delta)` and `M.build_agent_reply_message(params)`.
  - On `params.type == "synced"`: call `show_session(session, params.view)`, then if `params.delta` has changes, run `diff.redraw_all` (on file/head changes), `diff.redraw_threads` + `conversation.refresh` + `popup.refresh` (on comment/thread changes), `stream.refresh(session, true)`, and show `jpr().info(summary)`.
  - On `params.type == "agentReplied"`: apply `params.view`, refresh open popup for `params.threadId` if present, and show `jpr().info(M.build_agent_reply_message(params))`.
  - On `params.type == "agentPrepassWritten"`: apply `params.view` and show `jpr().info(...)`.
- In `lua/jpr/comments/popup.lua`:
  - Add `M.refresh_thread_by_id(session, thread_id)` (or refresh via `threads` RPC when the open popup contains `thread_id`) so an open popup updates live when an agent replies or sync brings new replies.
- Update `docs/architecture.md` with `jpr.notify`, `jpr.session.progress`, and the new event flows.

- [ ] **Step 4: Run full workspace verification (`just check`)**

Run: `just check`
Expected: `cargo fmt --check`, `cargo clippy --workspace --all-targets --all-features -- -D warnings`, `cargo test --workspace --all-features`, and `./scripts/test-lua.sh` all PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/ docs/architecture.md tests/lua/sync_and_agent_alerts_spec.lua
git commit -m "feat(nvim): auto-refresh on sync deltas and show blue toasts for sync and agent replies"
```
