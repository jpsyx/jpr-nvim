# Thread Popup UX Improvements Design

Date: 2026-11-26
Branch: `feat/thread-popup-ux`
Size: Small change

## Intent and Why

Make the `gt` floating thread popup feel fast and natural during PR review:

1. **Auto-close on resolve (`R`):** Resolving a thread signals the reviewer is done with it; leaving the popup open forces an extra `q` every time.
2. **Keep thread visible on reply (`r`):** Closing the popup and opening an empty modal makes the reviewer lose sight of what they are replying to. Like a web UI, the thread history should stay visible and scrollable while composing a reply.
3. **Scroll to the start of the last comment on `gt`:** Reviewers popping open a multi-comment thread usually want to read the latest response. Landing at the top forces scrolling down, while blindly jumping to the bottom hides the start of a long comment.

## Goals, Non-Goals, and Anti-Goals

### Goals

1. **Resolve (`R`) auto-closes:** When `R` marks a thread resolved (`resolved = true`), close the popup upon RPC success. When `R` unresolves a thread (`resolved = false`), keep the popup open and refresh it in place.
2. **Docked two-pane reply modal (`r`):** When replying to a thread that has messages, display a stacked two-pane floating modal:
   - **Top pane (read-only history):** Renders the thread's messages using the existing thread layout (`jpr.render.threads`), without the popup action footer, pre-scrolled to the start of the last comment.
   - **Bottom pane (editable reply):** Docked directly beneath the top pane with matching width, holding the standard markdown compose buffer (`<C-s>` submit, `@` mentions, `<C-g>s` suggestion fence, dirty-check cancel).
   - **Navigation and lifecycle:** Focus starts in the reply pane. `<C-w>k` / `<C-w>j` and Normal-mode `<Tab>` switch focus between the reply and history panes so the user can press `<Esc>` out of Insert mode and scroll the thread. `q` / `<Esc>` in Normal mode on either pane runs the same cancel flow (confirming if unsaved reply text exists). `<C-s>` submits and closes both panes. Closing or wiping either pane cleans up its companion so no orphan window remains.
3. **Initial scroll to start of last comment (`gt`):** When opening `popup.open`, place the cursor on `last_range.first` (the first line of the last entry in `popup.layout.message_ranges`). Scroll to the bottom (`zb` on the last line) so short trailing comments do not leave empty space at the bottom; if the viewport `topline` is then greater than `last_range.first` (meaning the last comment is taller than the popup, including wrapped lines), snap `last_range.first` to the top (`zt`).

### Non-Goals

- No Rust engine or JSON-RPC protocol changes.
- No changes to `:Jpr` command schema or CLI Command Palette.
- No changes to `open_new`, `open_edit`, or `open_promote` compose layouts.

### Anti-Goals

- Leaving an orphaned history float behind when the reply compose window closes (or vice versa).
- Allowing the user to accidentally edit or submit thread history text.
- Dropping the user at the bottom of a long or line-wrapped final comment when opening `gt`.

## Approaches

- **Option 1 (Picked): Docked two-pane floating modal** - A read-only thread history float stacked directly above a docked editable reply compose float. Matches a web UI, keeps thread highlights intact, preserves `@` mentions and `<C-g>s`, and prevents accidental edits to history or fragile separator parsing.
- **Option 2 (Rejected): Single compose buffer with thread history above a separator** - Lets `k`/`<C-u>` scroll directly into history without switching panes, but exposes history to accidental edits/deletion and relies on fragile delimiter stripping on submit.

## Builder Details and Constraints

- **Fallback for empty threads:** If `compose.open_reply` is called with a thread that has no `messages` (or an empty `messages` table), fall back to the existing single reply compose float with no empty history pane.
- **Responsive vertical sizing:** Compute combined stacked height from `vim.o.lines` so both panes (plus borders) fit cleanly even on small terminals.
- **Session handle compatibility:** Keep `session.compose.buf` and `session.compose.win` pointing to the editable reply buffer/window; store companion handles as `session.compose.history_buf` and `session.compose.history_win`.
- **Shared scroll helper:** Extract a pure/small helper (e.g. `scroll_to_last_message(win, layout)`) reused by both `popup.open` and the reply history pane.
- **Docs and tests:** Update `docs/architecture.md` (and `docs/decisions.md` if relevant) and add/update Lua specs under `tests/lua/popup_spec/` and `tests/lua/compose_spec/`.
