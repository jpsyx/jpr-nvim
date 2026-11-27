# Sidebar Unviewed Filter Shortcut and Clickable Header Pill

<small>

> <table border="0">
> <tr><th colspan="2">Files</th><th colspan="2">Lines</th></tr>
> <tr><td>Changed (total)</td><td>9</td><td>Insertions (+)</td><td>212</td></tr>
> <tr><td>Added</td><td>0</td><td>Deletions (-)</td><td>143</td></tr>
> <tr><td>Deleted</td><td>0</td><td>Net change</td><td>+69</td></tr>
> </table>

</small>

## 1. Purpose

Pressing `gu` in the pull-request sidebar panel to hide viewed files collided with Neovim's built-in `gu` lowercase operator and raised `E21: Cannot make changes, 'modifiable' is off` on the read-only sidebar buffer. When the filter was off, the sidebar also gave no visible indication that an unviewed-only filter existed.

This change:

- Replaces the `gu` sidebar mapping with single-key `u` so toggling the unviewed filter<sup>G10</sup> never triggers Neovim's lowercase operator.
- Adds a dedicated clickable `filter: [u] all files` / `filter: [u] unviewed only` header line beneath the sync status line<sup>G9</sup>.
- Updates the keyboard shortcuts cheatsheet<sup>G4</sup>, documentation, and Lua test suite for the new shortcut and one-line header offset.

## 2. Background technical context

```text
lua/jpr/
├── highlights/
│   └── init.lua
├── mouse.lua
├── render/
│   └── panel.lua              (changed)
├── session/
│   └── init.lua
└── views/
    └── panel.lua              (changed)
```

<small>

| Unit | What it is |
| --- | --- |
| `highlights/init.lua` | Defines the plugin's semantic Neovim highlight groups, including `JprMuted` (linked to `Comment`) for secondary text and `JprHunk` (linked to `Special`) for accented controls. `render/panel.lua` attaches these group names to rendered sidebar lines. |
| `mouse.lua` | Provides shared Neovim mouse click helpers that read the clicked window and line and pass clicks outside the target window back to Neovim's default mouse handling. `views/panel.lua` calls it to check whether a `<LeftMouse>` click landed inside the sidebar window. |
| `render/panel.lua` | Builds the pull-request sidebar's text lines, highlight spans, and clickable row maps from a review snapshot<sup>G7</sup> without touching Neovim windows or buffers. `views/panel.lua` calls `M.build` on every sidebar redraw. |
| `session/init.lua` | Owns the per-tab pull-request review session<sup>G6</sup> table, holding the latest snapshot<sup>G7</sup> from the review engine<sup>G5</sup> and in-memory UI state such as `panel` and `panel_hide_viewed`. `views/panel.lua` reads and updates this session table when rendering or toggling the sidebar filter. |
| `views/panel.lua` | Manages the read-only pull-request sidebar window and buffer, binding Normal-mode navigation keys, `<LeftMouse>` click handling, and cursor clamping<sup>G2</sup> onto selectable rows<sup>G8</sup>. It writes `render/panel.lua`'s output into the buffer and stores layout line numbers on `session.panel`. |

</small>

## 3. Shape of the solution

This change keeps all layout computation inside the pure renderer `lua/jpr/render/panel.lua` and routes both keyboard and mouse triggers through one toggle helper in `lua/jpr/views/panel.lua`.

**File: `lua/jpr/render/panel.lua`**

```lua {3,9}
function M.build(view, now, opts)
    ...
    content.add_line(M.build_counts_text(view), "JprMuted")
    if is_unlinked_local then
        content.add_line("local only · :Jpr sync to link PR", "JprMuted")
    else
        content.add_line(M.sync_text(view.sync, now))
    end
    local filter_line = add_filter_pill_line(content, hide_viewed)
    content.add_line("")
    content.add_line("  📄 Diff summary", "JprTitle")
    local summary_line = #content.lines
    content.rows[summary_line] = { kind = "summary" }
    content.selectable_lines[#content.selectable_lines + 1] = summary_line
    ...
end
```

`M.build` leaves the counts line<sup>G1</sup> (`M.build_counts_text(view)`, where `view` is the review snapshot<sup>G7</sup>) free of filter status text, appends the filter pill<sup>G3</sup> line directly after the sync status line<sup>G9</sup>, and returns that line's 1-based line number as `filter_line`. Because `filter_line` is never inserted into `rows` (the 1-based line-to-item lookup table) or `selectable_lines` (the ordered list of keyboard-navigable line numbers), `j`/`k` navigation and cursor clamping<sup>G2</sup> continue to skip the header and land on `Diff summary`, `Conversation`, directories, and files.

In `lua/jpr/views/panel.lua`, `M.render` stores `filter_line` from `render/panel.lua`'s `M.build` output on `session.panel`. Both the Normal-mode `u` keymap (replacing `gu`) and `<LeftMouse>` clicks whose clicked line (`click.line` from `mouse.get_click()`) matches `session.panel.filter_line` call `toggle_unviewed_filter(session)`, which flips `session.panel_hide_viewed` and re-renders the sidebar while keeping focus in the sidebar window and clamping the cursor onto a visible row. Inserting the filter header line shifts the `Diff summary` line (`summary_line`), the `Conversation` line (`conversation_line`), and every file-tree row down by one line, which accounts for the line-index adjustments across the five updated Lua specs.

Interface change: Capturing live Neovim TUI screenshots is blocked in this non-interactive CLI environment, so the wireframe below shows the two sidebar header states.

```text
Inactive (hide_viewed = false)           Active (hide_viewed = true)
------------------------------           ---------------------------
#7 Fix the widget                        #7 Fix the widget
█████░░░░░░░░░░░  1/3 (33%)              █████░░░░░░░░░░░  1/3 (33%)
viewed 1/3 · threads 2 · drafts 1        viewed 1/3 · threads 2 · drafts 1
synced 12s ago                           synced 12s ago
filter: [u] all files      (JprMuted)    filter: [u] unviewed only  (pill: JprHunk)

  📄 Diff summary                          📄 Diff summary
  💬 Conversation [2]                      💬 Conversation [2]
```

Decisions:

- **Use single-key `u` to toggle hiding viewed files in the sidebar instead of a Ctrl-based shortcut.** `<C-u>` was rejected because it overrides Vim half-page scroll up in large pull requests, and `<C-v>` can conflict with terminal paste bindings; `u` sits beside `v` (toggle viewed) and matches every other sidebar-local action (`o`, `r`, `a`, `?`).
- **Place the clickable filter toggle on its own sidebar header line rather than appending it to the viewed-and-thread summary line.** The counts line<sup>G1</sup> already overflows the 44-column default sidebar width when git worktree status badges (such as `dirty · ↑1 ↓0`) or local unsent thread counts are present, clipping any appended badge; a dedicated 21-to-25-column line stays visible and clickable in narrow sidebars.

Not handled:

- Persisting `panel_hide_viewed` to `local.json` (the review engine's<sup>G5</sup> per-PR local state file) across restarts remains out of scope, keeping the filter in session-only memory.
- Adding a user-configurable `config.keys` keymap option or a `:Jpr` command palette entry for the sidebar filter is not included.

<div style="page-break-before: always"></div>

## Appendix A. Manual testing

<small>

1. Run the sidebar render and view specs from the repository root and confirm both print `ok`:

   ```sh
   nvim --headless -u NONE -i NONE -l tests/lua/panel_render_spec.lua && nvim --headless -u NONE -i NONE -l tests/lua/panel_view_spec.lua
   ```

2. Start Neovim inside a git repository, open a review with `:Jpr open` (or `:Jpr local`), and focus the left pull-request sidebar panel.
3. Confirm the header shows `filter: [u] all files` in muted text directly beneath the sync status line<sup>G9</sup>.
4. Mark at least one file viewed with `v`, then press `u` in the sidebar.
   - **Before this change:** pressing `gu` could trigger Neovim's lowercase operator on the non-modifiable sidebar buffer and raise `E21: Cannot make changes, 'modifiable' is off`.
   - **Now:** the header switches to highlighted `filter: [u] unviewed only`, viewed files disappear from the tree, and the sidebar stays focused with the cursor on a visible row.
5. Click the `filter: [u] unviewed only` line with the left mouse button. Confirm the header returns to `filter: [u] all files` and restores the full file tree while keeping sidebar focus.
6. Press `?` in the sidebar and confirm the **PR Sidebar Panel** section lists `u` instead of `gu`.

</small>

<div style="page-break-before: always"></div>

## Appendix B. Glossary

<small>

| Term | Meaning |
| --- | --- |
| **G1** Counts line | The pull-request sidebar header line beneath the progress bar that summarizes viewed files, review threads, drafts, and optional git worktree status or local unsent thread counts (built by `M.build_counts_text`). |
| **G2** Cursor clamping | Keeping the sidebar window's cursor restricted to selectable rows<sup>G8</sup> (`Diff summary`, `Conversation`, directories, and files) so vertical motion and redraws never leave the cursor on header or blank lines. |
| **G3** Filter pill | The clickable `[u] all files` or `[u] unviewed only` control in the pull-request sidebar header that toggles the unviewed filter<sup>G10</sup>. |
| **G4** Keyboard shortcuts cheatsheet | The centered floating modal opened by `?` or `:Jpr keys` that lists active keybindings grouped by view, including the **PR Sidebar Panel** section. |
| **G5** Review engine | The Rust `jpr-review` backend process that holds pull-request state, syncs with GitHub, and sends updated review snapshots<sup>G7</sup> to the Neovim plugin. |
| **G6** Review session (session table) | The per-tab Lua state table managed by `session/init.lua` that ties together one open pull-request review's engine process, latest review snapshot<sup>G7</sup>, and in-memory UI flags such as `panel_hide_viewed`. |
| **G7** Review snapshot (snapshot) | The current pull-request state object (`SessionView` / `view`) sent by the review engine<sup>G5</sup>, containing PR metadata, file viewed states, thread counts, and sync status used to redraw the sidebar. |
| **G8** Selectable row | A sidebar row that the cursor can land on and activate (`Diff summary`, `Conversation`, a directory, or a file), tracked by 1-based line number in `selectable_lines`. |
| **G9** Sync status line | The pull-request sidebar header line directly below the counts line<sup>G1</sup> that shows when the review last synced with GitHub (such as `synced 12s ago`), a sync error, or local-only status. |
| **G10** Unviewed filter | A session-only sidebar view filter (stored as `panel_hide_viewed`) that hides files marked `VIEWED` and directories whose files are all `VIEWED`, leaving only items that still need review (`UNVIEWED` or `DISMISSED`). |

</small>
