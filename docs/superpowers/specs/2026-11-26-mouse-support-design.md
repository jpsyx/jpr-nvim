# Neovim Mouse & Point-and-Click Support Design

## Intent and Why

Until now, `jpr-nvim` only handled `<LeftMouse>` in two floating modals (`jpr.views.confirm` and `jpr.auth.modal`). Every other interactive surface in the plugin (the PR sidebar panel, the filterable Command Palette, wizard menu steppers, the full branch diff stream, the Submit Review modal, the floating thread popup, the PR conversation view, and the keyboard cheatsheet) ignored mouse clicks or only moved the cursor without triggering actions.

With Neovim mouse reporting enabled (`vim.opt.mouse = "a"`), reviewers should be able to point, click, and scroll naturally across every `jpr-nvim` window without breaking keyboard-first workflows or swallowing clicks directed at other Neovim splits, borders, or tabline elements.

## Goals, Non-Goals, and Anti-Goals

- **Goals:**
  - Single-click (`<LeftMouse>`) activates items in the sidebar panel (open file/conversation, toggle directory), Command Palette (select and run command from either prompt or results window), wizard menu/toggle/async steppers (select and advance), and Submit Review modal (select review action, jump to pending draft, open summary editor).
  - Double-click (`<2-LeftMouse>`) in the full branch diff stream toggles closed viewed-file folds in place or opens the real file at the clicked diff line, while single-click preserves cursor placement and drag-selection for range comments.
  - Clickable footer action hints (`[r]eply`, `[e]dit`, `[d]elete`, `[R]esolve`, `[+]react`, `[X]retry`, `[p]romote`, `[s]end`, `[c]omment`, `[C-u] clear`, `[h] back`, `[<C-s>] submit`, `[q]uit` / `[q/Esc] close`) work across modals, popups, and the PR conversation view.
  - Clicking outside a floating modal dismisses it cleanly; clicking outside a persistent split view (`panel`, `stream`, `conversation`) passes the native click through to Neovim so window focus switching and split-border resizing never get swallowed.
  - Document mouse interactions in the `:Jpr keys` cheatsheet and `docs/architecture.md`.
- **Non-Goals:**
  - Changing the Rust CLI `jpr-review` or its terminal UI (`crates/cli-tui`).
  - Adding custom scroll-wheel remappings (native Neovim `mouse = "a"` scrolling already works in all windows once mouse reporting is enabled).
  - Changing any existing keyboard shortcuts or schema-to-TUI invariants.
- **Anti-Goals:**
  - Swallowing `<LeftMouse>` clicks aimed at another Neovim window, split border, statusline, or tabline.
  - Triggering accidental file jumps on single-click in the full diff stream (which would break clicking to place the cursor or dragging visual line ranges for comments).
  - Duplicating `vim.fn.getmousepos()` parsing and footer token hit-testing across every view module.

## Constraints

- Keep pure hit-testing and footer span parsing in `lua/jpr/mouse.lua` with zero window side effects, unit-tested independently.
- Keep `lua/jpr/render/submit.lua` pure (no window/buffer side effects).
- Keep all functions short (<= 45 lines), avoid em dashes in comments/docs/copy, and pass `just check` (Rust + Lua specs).
- Maintain 100% backwards compatibility with existing keyboard shortcuts and headless Lua tests.

## Approaches Considered

1. **Shared `lua/jpr/mouse.lua` helper + per-view click bindings (Selected):**
   - Centralize `getmousepos()` validation, outside-window native click passthrough (`vim.api.nvim_feedkeys(vim.keycode(key), "n", false)`), and pure footer-hint token span parsing/hit-testing in `lua/jpr/mouse.lua`.
   - Wire each interactive view (`panel`, `palette`, `step_menu`, `stream/navigation`, `submit`, `popup`, `conversation`, `confirm`, `auth/modal`, `cheatsheet`) to `jpr.mouse` with view-specific handlers.
   - **Why selected:** Keeps hit-testing pure and DRY, guarantees consistent outside-click passthrough/dismissal across every view, and keeps each view's mouse handler under 25 lines.
2. **Inline `getmousepos()` logic in every view file (Rejected):**
   - Repeats window/line validation, footer column parsing, and outside-window passthrough bugs across 10 files.
3. **Global Neovim `<LeftMouse>` autocmd/mapping dispatcher (Rejected):**
   - Interferes with non-`jpr` buffers and user Neovim mappings; buffer-local mappings scoped to `jpr-*` buffers are isolated and predictable.

## Design

### 1. Shared Mouse Helper (`lua/jpr/mouse.lua`)

Pure functions:
- `M.is_click_in_window(mouse, win) -> boolean`: true iff `mouse` is a table, `win ~= nil`, `mouse.winid == win`, and `mouse.line >= 1`.
- `M.parse_footer_actions(line_text, specs) -> { action: string, col_start: integer, col_end: integer }[]`: finds each `{ token, action }` literal in `line_text` and returns 1-based inclusive display/byte column ranges.
- `M.hit_test_footer_action(footer_line, spans, line, col) -> string|nil`: returns the matching `action` when `line == footer_line` and `col` falls within `[col_start, col_end]`.

Thin Neovim helpers:
- `M.get_click() -> table|nil`: safely calls `vim.fn.getmousepos()`.
- `M.passthrough(key)`: forwards `key` (default `"<LeftMouse>"`) natively via `vim.api.nvim_feedkeys(vim.keycode(key), "n", false)` so clicks on other windows, split borders, statuslines, or tablines are never swallowed.
- `M.set_cursor_from_click(win, mouse)`: moves cursor in `win` to `{ mouse.line, math.max(0, (mouse.column or 1) - 1) }` safely with line clamping.

### 2. Per-View Mouse Behavior

| Surface | File(s) | `<LeftMouse>` inside window | Outside window |
| --- | --- | --- | --- |
| PR Sidebar Panel | `lua/jpr/views/panel.lua` | Selectable row: move cursor + open file/conversation or toggle dir. Non-selectable row: ignore. | Passthrough `<LeftMouse>` |
| Command Palette | `lua/jpr/tui/wizard/palette.lua` | Results win: click command -> select & activate; click footer token (`clear`, `back`, `close`) -> run action. Prompt win: focus prompt + Insert mode at clicked column. | Close palette |
| Wizard Menu Stepper | `lua/jpr/tui/wizard/step_menu.lua` | Click option row -> select & confirm; click footer token (`back`, `confirm`, `close`) -> run action. | Close wizard |
| Full Branch Diff Stream | `lua/jpr/views/stream/navigation.lua` | Single-click: native cursor placement / visual drag. `<2-LeftMouse>`: on closed fold -> toggle fold (`za`); else on target line -> open real file at line (`<CR>`). | Passthrough `<2-LeftMouse>` |
| Submit Review Modal | `lua/jpr/render/submit.lua`, `lua/jpr/views/submit.lua` | Event row -> select `COMMENT`/`APPROVE`/`REQUEST_CHANGES`; draft row -> jump to draft; summary section -> open summary editor; footer token (`summary`, `submit`, `cancel`) -> run action. | Close submit modal |
| Thread Popup | `lua/jpr/comments/popup.lua` | Footer line -> run clicked action (`reply`, `edit`, `delete`, `resolve`, `react`, `retry`, `promote`, `send`, `close`) targeting the previously selected message; message lines -> move cursor to clicked line. | Close popup |
| PR Conversation | `lua/jpr/views/conversation.lua` | Footer line -> run clicked action (`comment`, `reply`, `edit`, `delete`, `promote`, `send`, `react`, `retry`, `close`) targeting the previously selected message; message lines -> move cursor to clicked line. | Passthrough `<LeftMouse>` |
| Confirm & Auth Modals | `lua/jpr/views/confirm.lua`, `lua/jpr/auth/modal.lua` | Existing option click + clickable `[q/Esc] cancel` footer token. | Cancel modal |
| Keyboard Cheatsheet | `lua/jpr/views/cheatsheet.lua` | Native scroll/cursor inside window; documents mouse actions in the cheatsheet sections. | Close cheatsheet |

### 3. Documentation & Tests

- Add unit tests for `lua/jpr/mouse.lua` (`tests/lua/mouse_spec.lua`).
- Add mouse interaction tests in existing view spec suites (`panel_view_spec.lua`, `tui_wizard_spec/palette.lua`, `stream_view_spec`, `submit_view_spec.lua`, `popup_spec`, `conversation_view_spec.lua`, `confirm_view_spec.lua`, `auth_spec.lua`, `cheatsheet_spec.lua`).
- Update `docs/architecture.md` to document `jpr.mouse` and mouse behavior across views.
