# Sidebar Unviewed Filter Shortcut and Header Pill Design

## Intent and Why

In the PR sidebar panel, toggling the unviewed-only file filter was mapped to `gu`. Because `gu` is Neovim's built-in lowercase operator (`gu<motion>`), any `g`-prefix timeout, plugin interference, or fallback executes the native operator against the `nomodifiable` sidebar buffer and raises `E21: Cannot make changes, 'modifiable' is off`. In addition, the filter had no visible trigger in the sidebar while inactive, making it hard to discover without opening the keyboard shortcuts cheatsheet.

## Goals, Non-Goals, and Anti-Goals

- **Goals:**
  - Replace `gu` with a conflict-free, single-key panel-local shortcut (`u`) that matches the rest of the sidebar's single-key actions (`v`, `o`, `r`, `a`, `?`).
  - Add a compact, always-visible clickable filter pill in the sidebar header that displays the shortcut and current filter state and toggles on `<LeftMouse>`.
  - Preserve existing session-only persistence (kept across `gP` sidebar toggles, reset when the review session ends, not written to disk).
- **Non-Goals:**
  - Persisting the filter in `local.json` across sessions.
  - Adding a `:Jpr` command palette entry or global review-buffer keymap for the sidebar filter.
  - Adding additional filter lenses beyond all files vs unviewed-only.
- **Anti-Goals:**
  - Overriding Vim navigation or scrolling keys (such as `<C-u>` half-page up) in long file trees.
  - Appending the filter pill to the counts line where narrow sidebars or dirty worktree prefixes clip it.
  - Making the filter header line part of `j`/`k` tree selection (`selectable_lines`).

## Constraints

- `jpr.render.panel` remains pure: it computes lines, highlights, row metadata, and `filter_line` without touching Neovim buffers or windows.
- `jpr.views.panel` handles the `u` keymap and `<LeftMouse>` click on `filter_line`, delegating to a single shared `toggle_unviewed_filter(session)` helper.
- Existing sidebar cursor clamping, preservation across re-renders, and `all files viewed` empty state remain intact.

## Approaches Considered

1. **Single-key `u` + dedicated clickable header pill (Chosen):**
   - Replaces `gu` with `u` (mnemonic for **u**nviewed, sits next to `v` for **v**iewed, zero built-in operator conflict since undo is a no-op on a read-only panel).
   - Renders a compact dedicated line in the sidebar header directly under the sync status line: `filter: [u] all files` (muted) when off, and `filter: [u] unviewed only` (`JprHunk` badge) when active, clickable via `<LeftMouse>`.
   - Trade-off: adds one header line above the blank separator before `Diff summary`, which shifts `summary_line` and `conversation_line` by +1 and stays visible even in narrow 26-column sidebars.
2. **Ctrl-based keymap (`<C-v>` or `<C-u>`) without a header pill:**
   - Avoids the `g`-prefix operator collision, but `<C-u>` breaks Vim half-page scroll up in large PRs, `<C-v>` conflicts with terminal paste bindings on some setups, and the filter remains invisible when off.
3. **Header pill appended to the counts line:**
   - Avoids adding a header line, but `dirty · ↑2 ↓0 · viewed 1/3 · threads 2 · drafts 1` already exceeds the 44-column default sidebar width (`wrap = false`), clipping the pill.

## Design Summary

- **Render (`lua/jpr/render/panel.lua`):**
  - Keep the counts line strictly as `M.build_counts_text(view)` (removing the ` · unviewed only` suffix).
  - Add a dedicated filter pill line directly beneath the sync status line (and above the blank line before `Diff summary`):
    - Inactive (`hide_viewed == false`): `filter: [u] all files` highlighted with `JprMuted`.
    - Active (`hide_viewed == true`): `filter: [u] unviewed only` with `filter: ` in `JprMuted` and `[u] unviewed only` in `JprHunk`.
  - Return `filter_line` (1-based line index of the pill line) in the table returned by `M.build(...)`.
  - Do not add `filter_line` to `rows` or `selectable_lines`.
- **View (`lua/jpr/views/panel.lua`):**
  - Store `panel.filter_line = built.filter_line` during `M.render`.
  - Add `toggle_unviewed_filter(session)` which toggles `session.panel_hide_viewed` and re-renders `M.render(session, session.view or {})`.
  - Remove the `gu` mapping and map `u` (Normal mode, buffer-local, `nowait`, `silent`) to `toggle_unviewed_filter(session)`.
  - In `handle_left_click(session)`, check `click.line == panel.filter_line` before the `panel.rows[click.line] == nil` guard and call `toggle_unviewed_filter(session)`.
- **Cheatsheet & Docs:**
  - Update `lua/jpr/views/cheatsheet.lua`, `README.md`, `docs/architecture.md`, and `docs/decisions.md` to document `u` and the clickable header pill.
