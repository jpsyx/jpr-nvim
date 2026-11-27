# Thread Popup UX Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-close the `gt` thread popup when resolving with `R`, scroll `gt` to the start of the last comment on open, and keep thread history visible in a docked two-pane floating modal when replying with `r`.

**Architecture:** Extend `jpr.comments.popup` with a shared `scroll_to_last_message(win, layout)` helper and close-on-resolve behavior. Add a focused `jpr.comments.reply_history` module that computes stacked two-pane floating geometry and renders a read-only, pre-scrolled thread history window docked directly above the editable `jpr.comments.compose` reply window, sharing cancel/submit/wipeout teardown.

**Tech Stack:** Neovim Lua (`vim.api`, `vim.keymap`, `vim.fn`), headless Neovim Lua specs (`tests/lua/*_spec.lua`).

**Spec:** `docs/superpowers/specs/2026-11-26-thread-popup-ux-design.md`

## Global Constraints

- Pure Neovim Lua change: no Rust engine, JSON-RPC protocol, or `:Jpr` command schema changes.
- Keep functions short (`<= 45` lines), use descriptive names, and avoid em dashes in comments and docs.
- `session.compose.buf` and `session.compose.win` must remain the editable reply buffer and window; companion history handles live at `session.compose.history_buf` and `session.compose.history_win`.
- Update `docs/architecture.md` in the same branch to reflect new and changed module behavior.

## Review Focus

- **Tall or wrapped final comment on `gt`:** Opening a popup whose last comment exceeds the popup height must land with cursor and viewport `topline` at `last_range.first`, never at the bottom of that comment (Task 1).
- **Unresolving an already-resolved thread (`R`):** Pressing `R` when `state == "resolved"` must keep the popup open and refresh it to `Thread (Open)` rather than closing it (Task 1).
- **Reply on a thread with missing or empty `messages`:** `compose.open_reply` must fall back to the single reply float with no empty history pane (Task 2).
- **Dirty-check cancel from the history pane:** Pressing `q` or `<Esc>` while focused in `history_win` after typing in `compose.win` must prompt to discard unsaved text and keep both panes open if canceled, or close both if discarded (Task 2).
- **Companion teardown and small terminals:** Wiping either reply or history buffer must close its companion with no orphan float, and `compute_stacked_geometry` on a 20-line terminal must keep both panes and their borders inside `vim.o.lines` (Task 2).

---

### Task 1: Auto-close on resolve (`R`) and scroll to start of last comment (`gt`)

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `lua/jpr/comments/popup.lua:81-101,290-328`
- Test: `tests/lua/popup_spec/actions.lua:50-63,196-256`

**Interfaces:**
- Consumes: `jpr.render.threads` (`layout.message_ranges` entries with 1-based `{ first, last }`).
- Produces: `require("jpr.comments.popup").scroll_to_last_message(win, layout)` - scrolls floating window `win` to show the end of `layout` while guaranteeing `last_range.first` is at or below `topline`, with cursor placed at `{ last_range.first, 0 }`.

- [ ] **Step 1: Write failing tests in `tests/lua/popup_spec/actions.lua`**

Update section 3 (resolve/unresolve) and add section 12 (initial scroll positioning) in `tests/lua/popup_spec/actions.lua`:
1. In section 3: pressing `R` on an open thread sends `setResolved(true)` and closes `popup_win` (`not vim.api.nvim_win_is_valid(popup_win)`). Then open the popup on a resolved thread (or via `popup_module.open(review, { resolved_thread })`) and press `R`: assert `setResolved(false)` is sent, `popup_win` stays valid, and its text updates to `"Thread (Open)"`.
2. In section 8: move the `R` resolve check on `T_TWO` after the `refresh_from_thread` shrink and `X` retry checks (or reopen `multi_win` after `R`), since resolving `T_TWO` now closes `multi_win`.
3. Add initial-scroll tests using `popup_module.open(review, { thread })`:
   - **Short multi-message thread:** 2 short messages -> cursor is on `last_range.first` (`second_msg_line`), `topline == 1`.
   - **Tall thread with short last comment:** 1st message has 25 lines, 2nd message has 2 lines -> cursor is on `last_range.first`, `topline > 1`, and `topline <= last_range.first`.
   - **Tall thread with long last comment (> 22 lines):** 1st message has 3 lines, 2nd message has 30 lines -> cursor is on `last_range.first` AND `vim.api.nvim_win_call(win, function() return vim.fn.winsaveview().topline end) == last_range.first`.

- [ ] **Step 2: Run the Lua popup spec to verify it fails**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/popup_spec.lua`
Expected: FAIL on resolve auto-close and initial scroll assertions.

- [ ] **Step 3: Implement `M.scroll_to_last_message`, update `M.open`, and update `toggle_resolved` in `lua/jpr/comments/popup.lua`**

1. Export `M.scroll_to_last_message(win, layout)`:
   - Return early if `not win or not vim.api.nvim_win_is_valid(win)` or `not layout` or `#(layout.lines or {}) == 0`.
   - `local ranges = layout.message_ranges or {}`; `local last_range = ranges[#ranges]`; return if `not last_range`.
   - Inside `vim.api.nvim_win_call(win, function() ... end)`:
     - `vim.api.nvim_win_set_cursor(win, { #layout.lines, 0 })`
     - `vim.cmd("normal! zb")`
     - `local top_line = vim.fn.winsaveview().topline`
     - `vim.api.nvim_win_set_cursor(win, { last_range.first, 0 })`
     - `if top_line > last_range.first then vim.cmd("normal! zt") end`
2. In `M.open(session, threads)`: after setting `wrap = true` on `popup.win`, call `M.scroll_to_last_message(popup.win, popup.layout)`.
3. In `toggle_resolved(session)`: inside the `setResolved` callback, when `next_resolved` is `true`, call `M.close(session)` and return; otherwise keep `if result and result.thread then M.refresh_from_thread(session, result.thread) end`.

- [ ] **Step 4: Run popup spec to verify it passes**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/popup_spec.lua`
Expected: PASS (`popup_spec: ok`).

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/comments/popup.lua tests/lua/popup_spec/actions.lua
git commit -m "feat(popup): auto-close on resolve and scroll to last comment"
```

---

### Task 2: Docked two-pane reply modal (`r`) with read-only thread history

help-me-pick: implement L2 (hours=1.0 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `lua/jpr/render/threads.lua:323-341`
- Create: `lua/jpr/comments/reply_history.lua`
- Modify: `lua/jpr/comments/compose.lua:16-33,108-120,149-222,287-316`
- Test: `tests/lua/compose_spec/reply_edit_and_origins.lua`
- Test: `tests/lua/popup_spec.lua:204-234`

**Interfaces:**
- Consumes: `require("jpr.comments.popup").scroll_to_last_message(win, layout)` (from Task 1), `require("jpr.render.threads").create_popup_layout_from_threads(threads, opts)`.
- Produces:
  - `render.create_popup_layout_from_threads(threads, opts)` where `opts.include_footer` defaults to `true`; when `opts.include_footer == false`, omits the popup action footer line.
  - `reply_history.compute_stacked_geometry(total_lines, total_cols, history_line_count)` returning `{ width, col, history_row, history_height, reply_row, reply_height }`.
  - `reply_history.open(thread, layout_geom, callbacks)` where `callbacks = { on_focus_reply, on_cancel, on_submit }` returning `{ buf, win }`.
  - `session.compose` fields `{ buf, win, origin, anchor, history_buf, history_win }`.

- [ ] **Step 1: Write failing tests in `tests/lua/compose_spec/reply_edit_and_origins.lua` and `tests/lua/popup_spec.lua`**

1. In `tests/lua/compose_spec/reply_edit_and_origins.lua`, add specs for:
   - **Single-pane fallback:** `compose.open_reply(review, { threadId = "T1", anchor = line_anchor })` (no `messages`) leaves `review.compose.history_win == nil` and `review.compose.history_buf == nil`.
   - **Docked two-pane layout:** `compose.open_reply(review, thread_with_messages)` opens both `review.compose.win` and `review.compose.history_win`:
     - Focus starts in `review.compose.win`.
     - `history_buf` is non-modifiable (`vim.bo[history_buf].modifiable == false`), contains the thread messages, and omits `"[r]eply"`.
     - Geometry: same `width` and `col`, and `history_cfg.row + history_cfg.height + 2 == reply_cfg.row`.
     - For a tall thread with a long last comment, `history_win` is scrolled to `last_range.first`.
   - **Pane switching:** In Normal mode from `compose.win`, `<Tab>` and `<C-w>k` move focus to `history_win`; from `history_win`, `<Tab>` and `<C-w>j` move focus back to `compose.win`.
   - **Shared dirty-check cancel from history pane:** Type text into `compose.buf`, switch to `history_win`, press `q` with `vim.fn.confirm` returning `2` (Keep editing) -> both windows stay valid; press `<Esc>` with `vim.fn.confirm` returning `1` (Discard) -> both windows and buffers close.
   - **Submit closes both panes and sends only reply text:** Type `"My reply"` in `compose.buf`, press `<C-s>` -> `reply` RPC body is `"My reply"` (does not contain history text) and both `compose.win` and `history_win` are closed.
   - **Companion teardown on wipeout:** Deleting `history_buf` (`nvim_buf_delete(history_buf, { force = true })`) closes `compose.win`; deleting `compose.buf` closes `history_win`.
   - **Small terminal geometry:** `require("jpr.comments.reply_history").compute_stacked_geometry(20, 80, 30)` returns `history_height >= 4`, `reply_height >= 4`, `history_row >= 1`, `reply_row == history_row + history_height + 2`, and `reply_row + reply_height + 2 <= 20`.
2. In `tests/lua/popup_spec.lua` (`test_local_reply_and_delete`), assert that pressing `r` on the local thread opens both `review.compose.win` and `review.compose.history_win` and that `<C-s>` closes both.

- [ ] **Step 2: Run compose and popup specs to verify they fail**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/compose_spec.lua && nvim --headless -u NONE -i NONE -l tests/lua/popup_spec.lua`
Expected: FAIL (missing `reply_history` module / `history_win` is nil).

- [ ] **Step 3: Add `opts.include_footer` to `lua/jpr/render/threads.lua`**

In `create_popup_layout_from_threads(threads, opts)`, only append the footer line when `not opts or opts.include_footer ~= false`.

- [ ] **Step 4: Create `lua/jpr/comments/reply_history.lua`**

Implement:
- `M.compute_stacked_geometry(total_lines, total_cols, history_line_count)`:
  - `width = math.min(86, math.max(54, total_cols - 12))`
  - `col = math.max(2, math.floor((total_cols - width) / 2))`
  - Available interior rows for both panes: `usable = math.max(8, total_lines - 6)` (4 border rows + 2 lines for status/cmdline).
  - Target reply height `reply_height = math.min(10, math.max(4, math.floor(usable * 0.4)))`.
  - Max history height `max_history = math.max(4, usable - reply_height)`.
  - `history_height = math.min(max_history, math.max(4, history_line_count))`.
  - `total_height = history_height + reply_height + 4`.
  - `history_row = math.max(1, math.floor((total_lines - total_height) / 2))`.
  - `reply_row = history_row + history_height + 2`.
- `M.open(thread, geom, callbacks)`:
  - Renders `layout = render.create_popup_layout_from_threads({ thread }, { include_footer = false })`.
  - Creates non-modifiable `nofile`/`wipe`/`markdown` buffer, writes `layout.lines` and extmark highlights in namespace `jpr-reply-history`.
  - Opens floating window (`enter = false`, `relative = "editor"`, `row = geom.history_row`, `col = geom.col`, `width = geom.width`, `height = geom.history_height`, `style = "minimal"`, `border = "rounded"`, `title = " Thread History "`, `title_pos = "center"`, `footer = " <Tab>/<C-w>j reply · q cancel "`, `footer_pos = "center"`), sets `wrap = true`, calls `popup.scroll_to_last_message(win, layout)`.
  - Binds Normal-mode `<Tab>` and `<C-w>j` to `callbacks.on_focus_reply`, `q` and `<Esc>` to `callbacks.on_cancel`, and `<C-s>` to `callbacks.on_submit`.
  - Returns `{ buf = buf, win = win }`.

- [ ] **Step 5: Wire docked history pane into `lua/jpr/comments/compose.lua`**

1. In `M.close(session)`: close `compose.history_win` and delete `compose.history_buf` alongside `compose.win` and `compose.buf` (after `session.compose = nil` to prevent recursion).
2. In `build_footer(...)`: accept `has_history`; when `has_history` is true (and not unlinked/local-only/destination-toggle), return `" <C-s> save · <Tab> thread · <C-g>s suggest · @ mention · q cancel "`.
3. In `open_editor(session, opts)`:
   - Determine `has_history = type(opts.history_thread) == "table" and #(opts.history_thread.messages or {}) > 0`.
   - When `has_history`, compute stacked geometry via `reply_history.compute_stacked_geometry(vim.o.lines, vim.o.columns, history_line_count)` (computing the layout line count or passing `thread`), open the reply window at `geom.reply_row` / `geom.reply_height` / `geom.width` / `geom.col`, and open the docked history window via `reply_history.open(...)`.
   - Store `compose.history_buf` and `compose.history_win` on `session.compose`.
   - Bind Normal-mode `<Tab>` and `<C-w>k` on `compose.buf` to focus `compose.history_win` (if valid).
   - Register `BufWipeout` on `compose.buf` and `compose.history_buf` so wiping either calls `M.close(session)` when `session.compose == compose`.
4. In `M.open_reply(session, thread)`: pass `history_thread = thread` to `open_editor`.

- [ ] **Step 6: Run Lua specs to verify they pass**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/compose_spec.lua && nvim --headless -u NONE -i NONE -l tests/lua/popup_spec.lua`
Expected: PASS (`compose_spec: ok` and `popup_spec: ok`).

- [ ] **Step 7: Commit**

```bash
git add lua/jpr/render/threads.lua lua/jpr/comments/reply_history.lua lua/jpr/comments/compose.lua tests/lua/compose_spec/reply_edit_and_origins.lua tests/lua/popup_spec.lua
git commit -m "feat(compose): dock read-only thread history above reply modal"
```

---

### Task 3: Update architecture docs and run full workspace check

help-me-pick: implement L1 (hours=0.25 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `docs/architecture.md:349-368`

**Interfaces:**
- Consumes: Final module behaviors from Tasks 1 and 2.
- Produces: Up-to-date architecture documentation and verified green workspace (`just check`).

- [ ] **Step 1: Update `docs/architecture.md`**

Update the module table rows for:
- `jpr.comments.popup`: note that `gt` opens scrolled to the start of the last comment and `R` auto-closes when resolving (keeping open + refreshing when unresolving).
- `jpr.comments.compose`: note that `open_reply` docks a read-only thread history float above the reply input when the thread has messages (`<Tab>` / `<C-w>k` / `<C-w>j` switch panes).
- Add a row for `jpr.comments.reply_history`: stacked two-pane geometry and read-only pre-scrolled thread history float paired with `jpr.comments.compose`.

- [ ] **Step 2: Run full workspace verification**

Run: `just check`
Expected: Exit 0 (Rust fmt, clippy, Rust tests, and all Lua specs pass).

- [ ] **Step 3: Commit**

```bash
git add docs/architecture.md
git commit -m "docs: document thread popup UX and docked reply history"
```
