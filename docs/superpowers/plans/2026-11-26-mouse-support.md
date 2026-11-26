# Neovim Mouse & Point-and-Click Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every interactive Neovim UI surface in `jpr-nvim` compatible with mouse clicking, double-clicking, clickable footer action hints, and outside-click passthrough/dismissal.

**Architecture:** Introduce a focused `lua/jpr/mouse.lua` module holding pure click validation and footer-hint hit-testing plus thin Neovim click passthrough/cursor helpers. Wire `<LeftMouse>` (and `<2-LeftMouse>` in the full diff stream) into the sidebar panel, Command Palette, wizard menu steppers, diff stream, submit review modal, thread popup, PR conversation view, confirmation/auth modals, and cheatsheet, then update `docs/architecture.md`.

**Tech Stack:** Lua (Neovim 0.11+ plugin), headless Neovim Lua specs (`./scripts/test-lua.sh`), `just check`.

**Spec:** `docs/superpowers/specs/2026-11-26-mouse-support-design.md`

## Global Constraints

- Keep `lua/jpr/mouse.lua` hit-testing/parsing functions and `lua/jpr/render/submit.lua` completely pure (no window/buffer side effects).
- Never swallow `<LeftMouse>` or `<2-LeftMouse>` clicks aimed outside persistent split buffers (`panel`, `stream`, `conversation`): forward them natively via `mouse.passthrough`.
- Keep all functions short (<= 45 lines) and avoid em dashes in comments, copy, and docs.
- Keep all existing keyboard shortcuts and schema-to-TUI invariants unchanged.
- Keep `just check` green across Rust and Lua.

## Review Focus

- **Clicking from a persistent split (`panel` or `conversation`) into another window:** Must not swallow the click; must call `mouse.passthrough("<LeftMouse>")` so window focus switches cleanly (pinned in Tasks 2 and 4).
- **Clicking a Command Palette result row while focused in the Insert-mode prompt window:** Must work from Insert mode (`i` mapping on `prompt_buf`), exit Insert mode, select the clicked command, and activate it (pinned in Task 2).
- **Clicking a footer action button in Thread Popup or PR Conversation:** Must resolve `current_entry(session)` against the previously selected message, NOT move the cursor to the footer line first (pinned in Task 4).
- **Double-clicking a closed viewed-file fold in the full diff stream:** Must expand the fold in place (`za`) instead of jumping to the file, while double-clicking an expanded diff line opens the real file at that line (pinned in Task 3).
- **Clicking a restricted review action (`Approve` / `Request changes`) on your own PR in Submit Review:** Must respect `canApproveOrRequestChanges` and keep `COMMENT` selected while showing the info message (pinned in Task 3).

---

### Task 1: Shared Mouse Helper Module (`lua/jpr/mouse.lua`)

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Create: `lua/jpr/mouse.lua`
- Test: `tests/lua/mouse_spec.lua`

**Interfaces:**
- Produces in `lua/jpr/mouse.lua`:
  - `M.is_click_in_window(mouse, win) -> boolean`
  - `M.parse_footer_actions(line_text, specs) -> { action: string, col_start: integer, col_end: integer }[]`
  - `M.hit_test_footer_action(footer_line, spans, line, col) -> string|nil`
  - `M.get_click() -> table|nil`
  - `M.passthrough(key)`
  - `M.set_cursor_from_click(win, mouse)`

- [ ] **Step 1: Write failing tests in `tests/lua/mouse_spec.lua`**
  - Assert `is_click_in_window` accepts matching `winid` + `line >= 1` and rejects nil, mismatched `winid`, or `line < 1`.
  - Assert `parse_footer_actions` locates exact 1-based inclusive `[col_start, col_end]` spans for multi-token footer strings (including `[<CR>]`, `[+]react`, `[C-u] clear`, missing tokens skipped cleanly).
  - Assert `hit_test_footer_action` returns the matched action at start, middle, and end columns, and returns `nil` on wrong line or between tokens.
  - Assert `set_cursor_from_click` clamps line/column safely inside a real buffer window.
- [ ] **Step 2: Run targeted Lua spec to verify it fails**
  - Run: `nvim --headless -u NONE -l tests/lua/mouse_spec.lua`
  - Expected: FAIL (`module 'jpr.mouse' not found`).
- [ ] **Step 3: Implement `lua/jpr/mouse.lua`**
  - Implement all 6 exported functions cleanly, each <= 25 lines, with docstrings.
- [ ] **Step 4: Re-run targeted Lua spec to verify pass**
  - Run: `nvim --headless -u NONE -l tests/lua/mouse_spec.lua`
  - Expected: `mouse_spec.lua: ok`.
- [ ] **Step 5: Commit Task 1**
  - `git add lua/jpr/mouse.lua tests/lua/mouse_spec.lua && git commit -m "feat: add shared mouse hit-testing and passthrough helper"`

---

### Task 2: Sidebar Panel, Command Palette, and Wizard Menu Steppers

help-me-pick: implement L1 (hours=0.75 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `lua/jpr/views/panel.lua`
- Modify: `lua/jpr/tui/wizard/palette.lua`
- Modify: `lua/jpr/tui/wizard/step_menu.lua`
- Test: `tests/lua/panel_view_spec.lua`, `tests/lua/tui_wizard_spec/palette.lua`

**Interfaces:**
- Consumes: `jpr.mouse` (`get_click`, `is_click_in_window`, `passthrough`, `parse_footer_actions`, `hit_test_footer_action`, `set_cursor_from_click`).

- [ ] **Step 1: Write failing tests in `tests/lua/panel_view_spec.lua` and `tests/lua/tui_wizard_spec/palette.lua`**
  - Panel:
    - Single `<LeftMouse>` on a directory row toggles collapse/expand.
    - Single `<LeftMouse>` on a file row moves cursor and opens that file in the main window.
    - Single `<LeftMouse>` on the Conversation row opens PR conversation.
    - Single `<LeftMouse>` on a non-selectable header line keeps selection unchanged.
    - Single `<LeftMouse>` outside `panel.win` calls `mouse.passthrough("<LeftMouse>")` (does not swallow).
  - Palette & Wizard Stepper:
    - Clicking a command row in `state.win` while in Insert mode on `prompt_buf` exits Insert mode, selects that command, and executes/advances it.
    - Clicking `[C-u] clear` or `[Esc] normal/close` in palette footer clears filter / closes palette.
    - Clicking outside both palette windows closes the palette.
    - Clicking an option row in a wizard menu step selects and confirms that option.
    - Clicking `[h] back` / `[h] palette` or `[q/Esc] close` in a wizard menu step footer goes back / closes.
    - Clicking outside a wizard menu step window closes the wizard.
- [ ] **Step 2: Run targeted Lua specs to verify they fail**
  - Run: `nvim --headless -u NONE -l tests/lua/panel_view_spec.lua && nvim --headless -u NONE -l tests/lua/tui_wizard_spec.lua`
  - Expected: FAIL because `<LeftMouse>` is not bound on panel, palette, or step_menu.
- [ ] **Step 3: Implement mouse handlers in `panel.lua`, `palette.lua`, and `step_menu.lua`**
  - `panel.lua`: bind `<LeftMouse>` in `bind_action_keymaps` to handle selectable rows (set cursor + `handle_enter_key(session)`) or passthrough when outside `panel.win`.
  - `palette.lua`: bind `<LeftMouse>` in `"n"` and `"i"` on `prompt_buf` and `"n"` on `state.buf`; handle clicks in `state.win` (item activation + footer action tokens), clicks in `state.prompt_win` (focus + Insert mode), and outside clicks (`controller.close()`).
  - `step_menu.lua`: bind `<LeftMouse>` in `"n"` on `state.buf`; handle clicks in `state.win` (option activation + footer action tokens) and outside clicks (`controller.close()`).
- [ ] **Step 4: Re-run targeted Lua specs to verify pass**
  - Run: `nvim --headless -u NONE -l tests/lua/panel_view_spec.lua && nvim --headless -u NONE -l tests/lua/tui_wizard_spec.lua`
  - Expected: both print `: ok`.
- [ ] **Step 5: Commit Task 2**
  - `git add lua/jpr/views/panel.lua lua/jpr/tui/wizard/palette.lua lua/jpr/tui/wizard/step_menu.lua tests/lua/panel_view_spec.lua tests/lua/tui_wizard_spec/palette.lua && git commit -m "feat: add mouse click support to sidebar panel, command palette, and wizard steppers"`

---

### Task 3: Full Diff Stream (`<2-LeftMouse>`) and Submit Review Modal (`<LeftMouse>`)

help-me-pick: implement L1 (hours=0.75 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `lua/jpr/views/stream/navigation.lua`
- Modify: `lua/jpr/render/submit.lua`
- Modify: `lua/jpr/views/submit.lua`
- Test: `tests/lua/stream_view_spec/`, `tests/lua/submit_render_spec.lua`, `tests/lua/submit_view_spec.lua`

**Interfaces:**
- Consumes: `jpr.mouse`.
- Produces in `lua/jpr/render/submit.lua`:
  - `M.build(...)` returns additional pure fields: `event_lines` (`table<integer, string>`), `summary_lines` (`table<integer, boolean>`), and `footer_line` (`integer`).

- [ ] **Step 1: Write failing tests for stream double-click and submit modal clicks**
  - Stream (`tests/lua/stream_view_spec/`):
    - `<2-LeftMouse>` on an expanded diff line opens the real file at that target line.
    - `<2-LeftMouse>` on a closed viewed-file fold toggles/opens the fold in place without opening the file.
    - `<2-LeftMouse>` outside the stream window passes through natively.
  - Submit (`tests/lua/submit_render_spec.lua`, `tests/lua/submit_view_spec.lua`):
    - `render.build` returns `event_lines`, `summary_lines`, and `footer_line`.
    - Clicking an event row selects that event (and respects `canApproveOrRequestChanges = false`).
    - Clicking a pending draft row closes submit and opens that draft's file/line.
    - Clicking the summary section opens the summary editor.
    - Clicking `[e] summary`, `[<C-s>] submit`, or `[q] cancel` in the footer triggers the matching action.
    - Clicking outside the submit modal closes it.
- [ ] **Step 2: Run targeted Lua specs to verify they fail**
  - Run: `nvim --headless -u NONE -l tests/lua/stream_view_spec.lua && nvim --headless -u NONE -l tests/lua/submit_render_spec.lua && nvim --headless -u NONE -l tests/lua/submit_view_spec.lua`
  - Expected: FAIL.
- [ ] **Step 3: Implement stream double-click and submit modal clicks**
  - `stream/navigation.lua`: bind `<2-LeftMouse>` in `map_keys` to check `mouse.is_click_in_window`, move cursor, toggle fold when `vim.fn.foldclosed(mouse.line) ~= -1`, else call `stream_mod.open_target(session)`; passthrough when outside.
  - `render/submit.lua`: record `event_lines`, `summary_lines`, and `footer_line` in `M.build`.
  - `views/submit.lua`: bind `<LeftMouse>` in `bind_modal_keys` to dispatch event rows, draft anchors, summary lines, footer actions, and outside-click close.
- [ ] **Step 4: Re-run targeted Lua specs to verify pass**
  - Run: `nvim --headless -u NONE -l tests/lua/stream_view_spec.lua && nvim --headless -u NONE -l tests/lua/submit_render_spec.lua && nvim --headless -u NONE -l tests/lua/submit_view_spec.lua`
  - Expected: all 3 print `: ok`.
- [ ] **Step 5: Commit Task 3**
  - `git add lua/jpr/views/stream/navigation.lua lua/jpr/render/submit.lua lua/jpr/views/submit.lua tests/lua/stream_view_spec tests/lua/submit_render_spec.lua tests/lua/submit_view_spec.lua && git commit -m "feat: add mouse support to diff stream and submit review modal"`

---

### Task 4: Thread Popup, PR Conversation, Confirm/Auth Modals, Cheatsheet, and Docs

help-me-pick: implement L1 (hours=0.75 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `lua/jpr/comments/popup.lua`
- Modify: `lua/jpr/views/conversation.lua`
- Modify: `lua/jpr/views/confirm.lua`
- Modify: `lua/jpr/auth/modal.lua`
- Modify: `lua/jpr/views/cheatsheet.lua`
- Modify: `docs/architecture.md`
- Test: `tests/lua/popup_spec/`, `tests/lua/conversation_view_spec.lua`, `tests/lua/confirm_view_spec.lua`, `tests/lua/auth_spec.lua`, `tests/lua/cheatsheet_spec.lua`

**Interfaces:**
- Consumes: `jpr.mouse`.

- [ ] **Step 1: Write failing tests for popup, conversation, confirm/auth, and cheatsheet mouse behavior**
  - Popup: clicking a message line selects it; clicking `[r]eply`, `[R]esolve`, or `[q]uit` in the footer runs that action on the currently selected message without losing message selection; clicking outside closes the popup.
  - Conversation: clicking a message line selects it; clicking `[c]omment` or `[q]uit` in the footer runs that action; clicking outside passes through `<LeftMouse>`.
  - Confirm & Auth modals: clicking `[q/Esc] cancel` in the footer or clicking outside the modal cancels it.
  - Cheatsheet: clicking outside closes the cheatsheet; cheatsheet layout documents mouse actions.
- [ ] **Step 2: Run targeted Lua specs to verify they fail**
  - Run: `nvim --headless -u NONE -l tests/lua/popup_spec.lua && nvim --headless -u NONE -l tests/lua/conversation_view_spec.lua && nvim --headless -u NONE -l tests/lua/confirm_view_spec.lua && nvim --headless -u NONE -l tests/lua/auth_spec.lua && nvim --headless -u NONE -l tests/lua/cheatsheet_spec.lua`
  - Expected: FAIL.
- [ ] **Step 3: Implement mouse handlers and update cheatsheet + `docs/architecture.md`**
  - `comments/popup.lua`: bind `<LeftMouse>` for footer action hit-testing (preserving selected message), message cursor placement, and outside-click close.
  - `views/conversation.lua`: bind `<LeftMouse>` for footer action hit-testing, message cursor placement, and outside-click passthrough.
  - `views/confirm.lua` & `auth/modal.lua`: route `<LeftMouse>` through `jpr.mouse`, adding footer `[q/Esc] cancel` click and outside-click cancel.
  - `views/cheatsheet.lua`: bind `<LeftMouse>` to close on outside click (or allow cursor placement inside) and add mouse hints to the cheatsheet layout.
  - `docs/architecture.md`: add `jpr.mouse` to the Neovim plugin table and note mouse support on the views.
- [ ] **Step 4: Run full workspace verification (`just check`)**
  - Run: `just check`
  - Expected: formatting, clippy, Rust tests, and all Lua specs pass cleanly.
- [ ] **Step 5: Commit Task 4**
  - `git add lua/jpr/comments/popup.lua lua/jpr/views/conversation.lua lua/jpr/views/confirm.lua lua/jpr/auth/modal.lua lua/jpr/views/cheatsheet.lua docs/architecture.md tests/lua/popup_spec tests/lua/conversation_view_spec.lua tests/lua/confirm_view_spec.lua tests/lua/auth_spec.lua tests/lua/cheatsheet_spec.lua && git commit -m "feat: add mouse support to thread popup, conversation, modals, and cheatsheet"`

---

## Final Review

help-me-pick: bug-hunting-and-code-review L3 (hours=0.5 cause=known material=familiar stakes=none verified=yes)
