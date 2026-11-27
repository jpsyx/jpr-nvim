# Unified Diff Summary + Conversation View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `Diff summary` sidebar row and `:Jpr summary` command that open the same unified Diff summary + Conversation buffer as `Conversation`, scrolling to line 1 for `summary` and to the `Conversation` heading for `conversation`.

**Architecture:** Extend `PullRequest` with an additive `#[serde(default)] pub body: String` fetched by `gh pr view` and persisted in `StoredPullRequest`. Render both the Diff summary section and the PR Conversation section in `lua/jpr/views/conversation.lua`, and add a `Diff summary` row directly above `Conversation` in `lua/jpr/render/panel.lua` and `lua/jpr/views/panel.lua`.

**Tech Stack:** Rust (edition 2024, `serde`, `serde_json`, `anyhow`), Lua (Neovim API), headless Neovim Lua specs (`./scripts/test-lua.sh`), `just check`.

**Spec:** `docs/superpowers/specs/2026-11-26-diff-summary-view-design.md`

## Global Constraints

- Generic Rust crates (`crates/review-*`) never depend on Neovim, Lua, or TUI libraries.
- `PullRequest.body` and `StoredPullRequest.body` use `#[serde(default)]` so existing `session.json` files and fixtures deserialize without bumping `SESSION_VERSION` or `protocolVersion`.
- `:Jpr summary` must be registered in `lua/jpr/commands/schema/init.lua` with a human-readable label, concise helper text, and `predicates.is_conversation_executable`.
- No em dashes in code comments, docs, or user-facing strings.
- Keep functions short (`<= 45` lines) and follow red/green TDD.

## Review Focus

1. **PR body with `\r\n` or `\r` line endings or whitespace-only body:** Splitting `pr.body` must normalize `\r\n`/`\r` so `nvim_buf_set_lines` never errors, and a blank/missing `body` must render `  (no PR description)`. (Pinned in Task 3.)
2. **Legacy `session.json` without `body` or `gh pr view` returning `body: null`:** Both must decode cleanly with `body == ""` instead of failing sync or session restore. (Pinned in Task 1.)
3. **Switching between `Diff summary` and `Conversation` while already open (including read-only cached mode) vs background `refresh()`:** Explicit `show(..., { target = "summary" | "conversation" })` must re-scroll to line 1 or `conversation_start_line` (even in read-only mode), while background `M.refresh(session)` must preserve the user's cursor/scroll position. (Pinned in Task 3.)
4. **Short buffer or tall window scroll clamping:** `winrestview({ lnum = target, col = 0, topline = target })` must clamp `target` to `[1, #lines]` and land cursor cleanly on line 1 (`summary`) or `conversation_start_line` (`conversation`). (Pinned in Task 3.)
5. **Action keys pressed on Diff summary lines (`e`, `d`, `r`, `p`, `s`, `+`, `X`, `c`) and panel keys (`r`, `a`, `v`) on the `Diff summary` sidebar row:** Message-targeted keys on summary lines must safely no-op while `c` still composes a new PR comment; sidebar `r`/`v` on `kind == "summary"` must no-op while `a` uses project root. (Pinned in Tasks 2 and 3.)

---

### Task 1: Add `PullRequest.body` across Rust model, GitHub forge, and filesystem store

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=low verified=yes)

**Files:**
- Modify: `crates/review-model/src/pr.rs`
- Modify: `crates/review-forge-github/src/pr.rs`
- Modify: `crates/review-store-fs/src/format.rs`
- Modify: `crates/review-store-fs/src/format/tests.rs` (if separate, else inline tests in `format.rs`)
- Modify: `crates/review-core/src/fakes.rs`
- Modify: `crates/review-workspace-git/src/push/tests.rs`
- Modify: `crates/review-forge-github/src/mutations/tests.rs`

**Interfaces:**
- Consumes: existing `PullRequest`, `PR_FIELDS`, `parse_pr`, `StoredPullRequest`.
- Produces:
  - `PullRequest.body: String` (`#[serde(default)]`, camelCase JSON key `"body"`).
  - `PR_FIELDS` includes `body`; `parse_pr` parses `/body` defaulting `null`/missing to `""`.
  - `StoredPullRequest.body: String` persisted in `session.json` and defaulting to `""` on legacy files.

- [ ] **Step 1: Write failing Rust tests for `PullRequest.body`, `parse_pr` with body and `null` body, and `StoredPullRequest` round-trip/legacy default**

  - In `crates/review-model/src/pr.rs`: extend `pull_request_uses_camel_case_keys_and_defaults_cross_repository` (or add a dedicated test `pull_request_serializes_body_and_defaults_when_omitted`) asserting `json["body"] == "Details here"` and that removing `"body"` deserializes to `decoded.body == ""`.
  - In `crates/review-forge-github/src/pr.rs`: include `"body":"Fixes #1\n\nMore details"` in `OPEN`, assert `pr.body == "Fixes #1\n\nMore details"`, and add a test `defaults_null_or_missing_body_to_empty_string` asserting both `"body":null` and omitted `body` parse with `pr.body.is_empty()`.
  - In `crates/review-store-fs/src/format/tests.rs`: assert `encode_session` / `decode_session` preserves `pr.body` and that a legacy `session.json` omitting `"body"` decodes with `body == ""`.

- [ ] **Step 2: Run tests to verify they fail**

  Run: `cargo test -p review-model -p review-forge-github -p review-store-fs`
  Expected: FAIL (compile error: no field `body` on `PullRequest`).

- [ ] **Step 3: Implement `PullRequest.body` across model, forge, store, and test fixtures**

  - Add `#[serde(default)] pub body: String` with doc comment to `PullRequest` in `crates/review-model/src/pr.rs`.
  - Append `,body` to `PR_FIELDS` in `crates/review-forge-github/src/pr.rs` and parse `body: value["body"].as_str().unwrap_or_default().to_owned()`.
  - Add `body: String` to `StoredPullRequest` and wire both `From` impls in `crates/review-store-fs/src/format.rs`.
  - Initialize `body: String::new()` (or descriptive string) in `crates/review-core/src/fakes.rs`, `crates/review-workspace-git/src/push/tests.rs`, and `crates/review-forge-github/src/mutations/tests.rs`.

- [ ] **Step 4: Run Rust workspace tests and clippy**

  Run: `cargo test --workspace --all-features && cargo clippy --workspace --all-targets --all-features -- -D warnings`
  Expected: PASS with 0 warnings.

- [ ] **Step 5: Commit**

  ```bash
  git add crates/
  git commit -m "feat(model): fetch and persist pull request body"
  ```

---

### Task 2: Add `Diff summary` row to sidebar panel renderer and view

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=low verified=yes)

**Files:**
- Modify: `lua/jpr/render/panel.lua`
- Modify: `lua/jpr/views/panel.lua`
- Test: `tests/lua/panel_render_spec.lua`
- Test: `tests/lua/panel_view_spec.lua`
- Test: `tests/lua/panel_input_spec.lua`
- Test: `tests/lua/local_review_spec.lua`

**Interfaces:**
- Consumes: `require("jpr.session").summary_current()` (stubbed/implemented in Task 3; panel view delegates cleanly).
- Produces:
  - `panel.build(view, now, opts)` returns `summary_line` (1-based line 6) above `conversation_line` (1-based line 7), with `rows[summary_line] = { kind = "summary" }`, `lines[summary_line] == "  📄 Diff summary"`, highlighted with `JprTitle`, and `selectable_lines` starting with `{ summary_line, conversation_line, ... }`.
  - `panel.render(session, view)` sets `panel.summary_line = built.summary_line`, preserves cursor on `kind == "summary"`, defaults initial cursor to `built.summary_line or built.conversation_line or built.selectable_lines[1]`.
  - `panel.open_file_under_cursor(session)` dispatches `cursor_line == panel.summary_line` to `require("jpr.session").summary_current()`.

- [ ] **Step 1: Update and add failing Lua panel tests**

  - In `tests/lua/panel_render_spec.lua`: update expected lines/indices so line 6 is `"  📄 Diff summary"` (`summary_line == 6`, `rows[6] == { kind = "summary" }`) and line 7 is `"  💬 Conversation [2]"` (`conversation_line == 7`, `rows[7] == { kind = "conversation" }`), and verify `"  📄 Diff summary"` is highlighted with `JprTitle`.
  - In `tests/lua/local_review_spec.lua`: verify line 6 is `"  📄 Diff summary"` and line 7 is `"  💬 Local Notes"` (unlinked) / `"  💬 Conversation"` (linked).
  - In `tests/lua/panel_view_spec.lua`: add tests verifying `<CR>` / `o` / `<LeftMouse>` on `review.panel.summary_line` calls `summary_current()` (or opens summary at line 1 once Task 3 lands), cursor preservation across `panel.render` stays on `summary_line`, and `v` on `summary_line` is a no-op.
  - In `tests/lua/panel_input_spec.lua`: add checks that pressing `r` on `review.panel.summary_line` is a no-op and pressing `a` opens create input rooted at project root.

- [ ] **Step 2: Run Lua panel specs to verify they fail**

  Run: `nvim --headless -u NONE -l tests/lua/panel_render_spec.lua`
  Expected: FAIL (line 6 is still `"  💬 Conversation [2]"`).

- [ ] **Step 3: Implement `Diff summary` row in `lua/jpr/render/panel.lua` and `lua/jpr/views/panel.lua`**

  - In `lua/jpr/render/panel.lua`: add `"  📄 Diff summary"` with `JprTitle` right before the Conversation row; record `summary_line`, `rows[summary_line] = { kind = "summary" }`, append to `selectable_lines`, and return `summary_line` in the result table.
  - In `lua/jpr/views/panel.lua`: store `panel.summary_line = built.summary_line`, update `find_preserved_cursor_line` to handle `prev_row.kind == "summary"` and default to `built.summary_line or built.conversation_line or built.selectable_lines[1]`, and route `cursor_line == panel.summary_line` in `open_file_under_cursor` to `require("jpr.session").summary_current()`.

- [ ] **Step 4: Run panel Lua specs to verify they pass**

  Run: `nvim --headless -u NONE -l tests/lua/panel_render_spec.lua && nvim --headless -u NONE -l tests/lua/panel_input_spec.lua`
  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add lua/jpr/render/panel.lua lua/jpr/views/panel.lua tests/lua/panel_render_spec.lua tests/lua/panel_view_spec.lua tests/lua/panel_input_spec.lua tests/lua/local_review_spec.lua
  git commit -m "feat(panel): add Diff summary row above Conversation"
  ```

---

### Task 3: Render unified Diff summary + Conversation view with scroll targeting

help-me-pick: implement L2 (hours=1 cause=known material=familiar stakes=low verified=yes)

**Files:**
- Modify: `lua/jpr/views/conversation.lua`
- Modify: `lua/jpr/session/comments.lua`
- Modify: `tests/lua/fixtures/fake_engine.sh`
- Test: `tests/lua/conversation_view_spec.lua`

**Interfaces:**
- Consumes: `session.view.pr` (`number`, `title`, `author`, `headRef`, `baseRef`, `body`), `session.view.localContext`, `session.view.files`, `session.view.viewedCount`.
- Produces:
  - `require("jpr.views.conversation").show(session, opts)` where `opts = { target = "summary" | "conversation" }` (default `"conversation"`).
  - `layout.conversation_start_line`: 1-based line number of the `Conversation (...)` / `Local Notes (...)` heading.
  - `require("jpr.session").summary_current()` and `require("jpr.session").conversation_current()`.

- [ ] **Step 1: Write failing tests in `tests/lua/conversation_view_spec.lua` and update `tests/lua/fixtures/fake_engine.sh`**

  - In `tests/lua/fixtures/fake_engine.sh`: enrich `pr` with `"author":"alice","headRef":"fix/widget","baseRef":"main","body":"Fixes widget crash.\r\n\r\nIncludes regression test."`.
  - In `tests/lua/conversation_view_spec.lua`:
    - Assert without an active session, `session.summary_current()` errors with `"no pull request"`.
    - Assert `session.summary_current()` opens `jpr://conversation/7` showing both the Diff summary (`#7 Fix the widget`, `@alice · fix/widget -> main`, `1 file changed · +2 -1 · 0/1 viewed`, normalized PR description lines with no `\r`, separator) and the `Conversation (1 comments)` section with `"Overall looks clean!"`, with cursor and `topline` at line 1.
    - Assert `session.conversation_current()` opens the same buffer with cursor and `topline` at `review.conversation.layout.conversation_start_line` (where the `Conversation` heading starts, > 1).
    - Assert switching targets (`summary_current()` then `conversation_current()` then `summary_current()`) on an already-rendered buffer (including `is_read_only = true` cached mode) scrolls immediately to line 1 or `conversation_start_line`.
    - Assert background `conversation.refresh(review)` preserves the user's current cursor line instead of snapping back to summary or conversation start.
    - Assert pressing `e`, `d`, `r`, `p`, `s`, `+`, `X` while cursor is on line 1 (inside Diff summary) does not error or send mutations, while `c` still opens PR comment compose.
    - Assert blank/whitespace-only PR `body` renders `  (no PR description)`.
    - Assert unlinked local mode (`mode = "local"`, `view.pr = nil`, `view.localContext = { branch = "feat/x", baseRef = "main" }`) renders `LOCAL feat/x vs main`, file/line diffstat, and the local-mode hint above `Local Notes`.

- [ ] **Step 2: Run conversation spec to verify it fails**

  Run: `nvim --headless -u NONE -l tests/lua/conversation_view_spec.lua`
  Expected: FAIL (`summary_current` is nil / summary lines not rendered).

- [ ] **Step 3: Implement unified Diff summary + Conversation rendering and scroll targeting**

  - In `lua/jpr/views/conversation.lua`:
    - Add helper `append_diff_summary(layout, session, is_local)` (splitting and normalizing `\r\n`/`\r` lines from `pr.body`, computing total additions/deletions/viewed from `session.view.files`, rendering linked PR or local-mode summary, followed by a muted horizontal rule `────────────────────────────────────────` and blank line).
    - In `create_layout_from_threads(session, threads)`: call `append_diff_summary`, record `layout.conversation_start_line = #layout.lines + 1`, then append the Conversation / Local Notes heading, threads, and footer.
    - Add helper `scroll_to_target(buf, layout, target)` that computes `target_line = (target == "summary") and 1 or (layout.conversation_start_line or 1)`, clamps to `[1, #layout.lines]`, and for each window showing `buf` calls `vim.api.nvim_win_call(win, function() vim.fn.winrestview({ lnum = clamped, col = 0, topline = clamped }) end)`.
    - Update `M.show(session, opts)` to accept `opts` (`target = (type(opts) == "table" and opts.target) or "conversation"`), set `state.pending_target = target`, call `scroll_to_target` immediately if `state.layout` already exists, and in `fetch_and_draw` apply and clear `state.pending_target` right after `paint_buffer` (while `M.refresh` does not set `pending_target`, preserving cursor/scroll).
  - In `lua/jpr/session/comments.lua`:
    - Add `session_mod.summary_current()` calling `require("jpr.views.conversation").show(session, { target = "summary" })`.
    - Update `session_mod.conversation_current()` to call `require("jpr.views.conversation").show(session, { target = "conversation" })`.

- [ ] **Step 4: Run conversation and panel specs to verify they pass**

  Run: `nvim --headless -u NONE -l tests/lua/conversation_view_spec.lua && nvim --headless -u NONE -l tests/lua/panel_view_spec.lua`
  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add lua/jpr/views/conversation.lua lua/jpr/session/comments.lua tests/lua/fixtures/fake_engine.sh tests/lua/conversation_view_spec.lua
  git commit -m "feat(views): unify Diff summary and Conversation with scroll targeting"
  ```

---

### Task 4: Register `:Jpr summary` command, Command Palette schema, cheatsheet, and docs

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=low verified=yes)

**Files:**
- Modify: `lua/jpr/init.lua`
- Modify: `lua/jpr/commands/schema/init.lua`
- Modify: `lua/jpr/views/cheatsheet.lua`
- Modify: `docs/protocol.md`
- Test: `tests/lua/palette_and_open_picker_spec/palette.lua`
- Test: `tests/lua/command_spec.lua`
- Test: `tests/lua/local_review_spec.lua`

**Interfaces:**
- Consumes: `require("jpr.session").summary_current()`, `predicates.is_conversation_executable`.
- Produces: `:Jpr summary` subcommand and `"summary"` (`Open Diff Summary`) Command Palette entry (18 total `:Jpr` subcommands).

- [ ] **Step 1: Update tests to assert `:Jpr summary` command and palette registration**

  - In `tests/lua/palette_and_open_picker_spec/palette.lua`: update expected spec count from `17` to `18` and assert `"summary"` is present with label `"Open Diff Summary"`.
  - In `tests/lua/local_review_spec.lua`: update `#ids` assertion from `17` to `18`.
  - In `tests/lua/command_spec.lua`: add `:Jpr summary` dispatch test asserting `summary_current` is called and rejects extra arguments.

- [ ] **Step 2: Run command & palette specs to verify they fail**

  Run: `nvim --headless -u NONE -l tests/lua/command_spec.lua && nvim --headless -u NONE -l tests/lua/palette_and_open_picker_spec.lua`
  Expected: FAIL (`summary` command unknown / count 17 != 18).

- [ ] **Step 3: Wire `:Jpr summary`, palette spec, cheatsheet, and protocol docs**

  - In `lua/jpr/init.lua`: add `summary = "summary_current"` to `ZERO_ARG_SESSION_METHODS`.
  - In `lua/jpr/commands/schema/init.lua`: add `create_session_action_spec("summary", "Open Diff Summary", "View the pull request description and diff stats above the conversation in the main review window.", "summary_current", predicates.is_conversation_executable)` right before `"conversation"`, and update doc comments from `17` to `18`.
  - In `lua/jpr/views/cheatsheet.lua`: update panel `<CR> / o` description to mention Diff summary, Conversation, or file, and update the `PR Conversation` section heading to `PR Diff Summary & Conversation`.
  - In `docs/protocol.md`: document `body` on the `PullRequest` shape.

- [ ] **Step 4: Run full workspace verification (`just check`)**

  Run: `just check`
  Expected: PASS (rustfmt, clippy, all Rust tests, all Lua specs green).

- [ ] **Step 5: Commit**

  ```bash
  git add lua/jpr/init.lua lua/jpr/commands/schema/init.lua lua/jpr/views/cheatsheet.lua docs/protocol.md tests/lua/palette_and_open_picker_spec/palette.lua tests/lua/command_spec.lua tests/lua/local_review_spec.lua
  git commit -m "feat(commands): register :Jpr summary in command palette and docs"
  ```
