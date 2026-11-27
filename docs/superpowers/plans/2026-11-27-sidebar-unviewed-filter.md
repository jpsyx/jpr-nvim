# Sidebar Unviewed Filter Shortcut and Header Pill Implementation Plan

> **For agentic workers:** Follow red/green TDD for each behavioral task. Keep functions short (<= 45 lines), pure render logic in `lua/jpr/render/panel.lua`, and Neovim window/keymap wiring in `lua/jpr/views/panel.lua`.

**Goal:** Replace the colliding `gu` sidebar filter keymap with `u` and add a compact, always-visible clickable filter pill line in the sidebar header.

**Architecture:** `jpr.render.panel` emits a dedicated filter pill line right below the sync line and exposes its 1-based `filter_line` index. `jpr.views.panel` removes `gu`, binds `u`, stores `panel.filter_line`, and routes `<LeftMouse>` clicks on `filter_line` to the shared `toggle_unviewed_filter(session)` helper.

**Tech Stack:** Lua (Neovim 0.11+ plugin), headless Neovim Lua specs (`./scripts/test-lua.sh`), `just check`.

---

### Task 1: Render the clickable filter pill line in `jpr.render.panel`

**Files:**
- Modify: `tests/lua/panel_render_spec.lua`
- Modify: `lua/jpr/render/panel.lua`

- [ ] **Step 1 (Red):** Update `tests/lua/panel_render_spec.lua` to expect the dedicated filter pill line (`filter: [u] all files` when off, `filter: [u] unviewed only` with `JprHunk` highlight on `[u] unviewed only` when on), `built.filter_line == 5`, and the +1 shift on `summary_line`/`conversation_line` and file indices. Run `nvim --headless -u NONE -i NONE -l tests/lua/panel_render_spec.lua` and confirm it fails.
- [ ] **Step 2 (Green):** Update `lua/jpr/render/panel.lua`:
  - Remove `build_visible_counts_text` and draw `M.build_counts_text(view)` directly on the counts line.
  - Add `add_filter_pill_line(content, hide_viewed)` to append `filter: [u] all files` (`JprMuted`) or `filter: [u] unviewed only` (`JprMuted` + `JprHunk`) directly after the sync line and return its 1-based line number.
  - Return `filter_line = filter_line` from `M.build`.
- [ ] **Step 3 (Verify):** Run `nvim --headless -u NONE -i NONE -l tests/lua/panel_render_spec.lua` and confirm PASS.

### Task 2: Replace `gu` with `u` and wire `<LeftMouse>` on `filter_line` in `jpr.views.panel`

**Files:**
- Modify: `tests/lua/panel_view_spec.lua`
- Modify: `lua/jpr/views/panel.lua`
- Modify: `lua/jpr/views/cheatsheet.lua`

- [ ] **Step 1 (Red):** Update `tests/lua/panel_view_spec.lua`:
  - Assert `gu` is NOT mapped buffer-locally on the panel (`vim.fn.maparg("gu", "n", false, true)` has no `callback`).
  - Assert `u` is mapped on the panel and toggles `unviewed only` / `all files`, keeps sidebar focused, clamps cursor onto a visible row, and survives `panel_view.toggle`.
  - Assert `<LeftMouse>` on `review.panel.filter_line` toggles `panel_hide_viewed` on and off without losing focus.
  - Update the 3 line-index assertions around line 522 for the +1 header line shift.
  - Run `nvim --headless -u NONE -i NONE -l tests/lua/panel_view_spec.lua` and confirm it fails.
- [ ] **Step 2 (Green):**
  - In `lua/jpr/views/panel.lua`, add `toggle_unviewed_filter(session)`, replace `gu` with `u`, store `panel.filter_line = built.filter_line` in `M.render`, and handle `click.line == panel.filter_line` in `handle_left_click`.
  - In `lua/jpr/views/cheatsheet.lua`, update `{ key = "gu", ... }` to `{ key = "u", desc = "Show only files and directories that still need review (or click header pill)" }`.
- [ ] **Step 3 (Verify):** Run `nvim --headless -u NONE -i NONE -l tests/lua/panel_view_spec.lua` and `./scripts/test-lua.sh` and confirm PASS.

### Task 3: Update documentation, commit, and run full verification

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/decisions.md`

- [ ] **Step 1:** Update `README.md`, `docs/architecture.md`, and `docs/decisions.md` to document `u` and the clickable header filter pill (`filter: [u] all files` / `filter: [u] unviewed only`) instead of `gu`.
- [ ] **Step 2:** Run `just check` in the worktree and verify all Rust formatting, clippy, Rust tests, and Lua specs pass.
- [ ] **Step 3:** Commit the spec, plan, implementation, tests, and docs on `fix/sidebar-unviewed-filter`.
