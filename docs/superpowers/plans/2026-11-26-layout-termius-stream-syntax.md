# Layout Manager, Termius 256-Color Diffs, and Mid-File Stream Syntax Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically manage review-tab sidebar/editor/AI widths with a `:Jpr panel` (`gp`) toggle, add 256-color `ctermbg`/`ctermfg` diff highlight parity for Termius on iPad, and preserve mid-file hunk syntax highlighting in `gF` full-stream diffs.

**Architecture:** Three focused Lua subsystems inside `lua/jpr/`: (1) a pure layout calculator and topology-keyed window reconciler (`lua/jpr/views/layout.lua`) wired into session lifecycle, panel toggle, main window, and agent terminal; (2) curated xterm-256 `ctermbg` palettes and `rgb_to_cterm256` `ctermfg` generation in `lua/jpr/highlights/init.lua`; (3) full-file worktree Treesitter lookup by `right_line` plus hunk-separated dedent and per-line recovery in `lua/jpr/views/stream/syntax.lua`.

**Tech Stack:** Neovim Lua API (`nvim >= 0.10`), Treesitter (`vim.treesitter`), `just test-lua` / `./scripts/test-lua.sh`.

**Spec:** `docs/superpowers/specs/2026-11-26-layout-termius-stream-syntax-design.md`

## Global Constraints

- Only Lua plugin files, Lua tests, and docs change; zero Rust crate or protocol changes.
- Every `:Jpr` command must be registered in `lua/jpr/commands/schema/init.lua` (Interactive Command Palette invariant) and reflected in `lua/jpr/views/cheatsheet.lua`.
- Functions stay short (<= 45 lines), no em dashes in comments or docs, descriptive names with auxiliary verbs.
- Red/green TDD for every task; `just check` must pass before completion.

## Review Focus

- Narrow terminal widths (e.g. iPad portrait at 70-80 columns) with Sidebar + Editor + AI open must clamp side widths without crashing `nvim_win_set_width` or collapsing the main pane below minimum width.
- Horizontal/float/tab agent layouts must NOT be treated as a vertical right side panel by `layout.classify_tab_windows`.
- Manual window resizing while tab topology and `vim.o.columns` are unchanged must NOT be overwritten by `layout.reconcile`.
- User-overridden `JprDiffAdd` (setting custom `bg` or `ctermbg`) must remain preserved across `define_highlights` and `ColorScheme` events.
- Untrusted or deleted/modified file paths in stream `code_rows` must never read outside `session.worktree` (validated via `diff.name_to_relative_path`) and must gracefully fall back when file line text differs from the stream row.

---

### Task 1: Automatic Review Tab Layout Manager and `:Jpr panel` (`gp`) Toggle

help-me-pick: implement L2 (hours=1.5 cause=known material=familiar stakes=low verified=yes)

**Files:**
- Create: `lua/jpr/views/layout.lua`
- Modify: `lua/jpr/views/panel.lua`
- Modify: `lua/jpr/views/main_window.lua`
- Modify: `lua/jpr/agent/terminal.lua`
- Modify: `lua/jpr/session/init.lua`
- Modify: `lua/jpr/session/commands.lua`
- Modify: `lua/jpr/views/diff/init.lua`
- Modify: `lua/jpr/init.lua`
- Modify: `plugin/jpr.lua`
- Modify: `lua/jpr/commands/schema/init.lua`
- Modify: `lua/jpr/views/cheatsheet.lua`
- Create: `tests/lua/layout_and_panel_toggle_spec.lua`
- Modify: `tests/lua/command_spec.lua`, `tests/lua/palette_and_open_picker_spec/palette.lua`, `tests/lua/local_review_spec.lua`, `tests/lua/session_shortcuts_spec.lua`, `tests/lua/cheatsheet_spec.lua`

**Interfaces:**
- Produces `jpr.views.layout`:
  - `compute_layout_widths(state)` -> `{ panel_width: integer|nil, agent_width: integer|nil, panel_fixwidth: boolean, agent_fixwidth: boolean }`
  - `classify_tab_windows(session)` -> `{ panel_win: integer|nil, agent_win: integer|nil, has_editor: boolean, topology_key: string }`
  - `reconcile(session, opts)` -> `boolean` (whether widths were applied)
  - `attach(session)` / `detach(session)`
- Produces `jpr.views.panel`:
  - `is_open(session)` -> `boolean`
  - `toggle(session)` -> `boolean`
- Produces `jpr.session`:
  - `panel_current()`
- Produces `jpr.defaults.keys.toggle_panel = "gp"`, `<Plug>(jpr-toggle-panel)`, `:Jpr panel`.

- [ ] **Step 1: Write failing tests in `tests/lua/layout_and_panel_toggle_spec.lua`**

Cover:
1. Pure `layout.compute_layout_widths`:
   - Sidebar + Editor + AI -> both side widths + `winfixwidth = true`.
   - Sidebar + AI (no Editor) -> sidebar at `panel_width` (`panel_fixwidth = true`), AI takes main width (`agent_width = nil`, `agent_fixwidth = false`).
   - Editor + AI (no Sidebar) -> AI at `agent_width` (`agent_fixwidth = true`).
   - Sidebar + Editor (no AI) -> sidebar at `panel_width` (`panel_fixwidth = true`).
   - Narrow terminal clamping (e.g., 75 columns with all 3 open leaves >= 20 cols for editor).
2. Live Neovim tab integration:
   - Close main window -> sidebar expands; open file from panel -> sidebar snaps back to `panel_width`.
   - Open vertical agent alongside sidebar + editor -> both side widths enforced; close editor -> sidebar stays `panel_width` and AI expands to fill remaining width; reopen file -> AI returns to `agent_width` and sidebar stays `panel_width`.
   - Toggle sidebar closed with `:Jpr panel` / `gp` while editor + AI open -> editor fills main width, AI stays `agent_width`; reopen with `gp` -> sidebar returns on left at `panel_width` preserving `collapsed_dirs`.
   - Closing sidebar when it is the only window refuses cleanly with error.
   - Manual sidebar width resize is preserved when topology is unchanged.
   - Non-vertical agent (float/horizontal) is ignored by vertical width classification.

- [ ] **Step 2: Run the new spec to confirm failure**

Run: `nvim --headless -u NONE -l tests/lua/layout_and_panel_toggle_spec.lua`
Expected: FAIL (`module 'jpr.views.layout' not found`).

- [ ] **Step 3: Implement `lua/jpr/views/layout.lua` and wire panel toggle, commands, schema, shortcuts, and cheatsheet**

1. Create `lua/jpr/views/layout.lua` with `compute_layout_widths`, `classify_tab_windows`, `reconcile`, `attach`, and `detach`.
2. Update `lua/jpr/views/panel.lua` with `M.is_open(session)`, `M.toggle(session)`, preserving `collapsed_dirs` on `session.panel_collapsed_dirs` across close/reopen, and calling `layout.reconcile(session, { force = true })`.
3. Update `lua/jpr/views/main_window.lua` (`M.find`) and `lua/jpr/agent/terminal.lua` (`spawn`, `show`, `hide`, plus binding `keys.toggle_panel` in Normal mode on agent buffer).
4. Attach `layout.attach(session)` in `lua/jpr/session/init.lua` (`start` and `open_local.lua` if separate — check `open_local.lua`!) and `layout.detach(session)` in `forget`.
5. Wire `session.panel_current()`, `:Jpr panel` in `lua/jpr/commands/schema/init.lua` and `lua/jpr/init.lua`, `<Plug>(jpr-toggle-panel)` in `plugin/jpr.lua`, `keys.toggle_panel = "gp"` in `jpr.defaults.keys`, `jpr.bind_session_keys`, tab-aware `gp` on non-changed worktree buffers, and `lua/jpr/views/cheatsheet.lua`.
6. Update existing subcommand/shortcut specs (`command_spec.lua`, `palette_and_open_picker_spec/palette.lua`, `local_review_spec.lua`, `session_shortcuts_spec.lua`, `cheatsheet_spec.lua`) for the 17th `:Jpr panel` command and `gp` shortcut.

- [ ] **Step 4: Run focused and full Lua tests**

Run: `nvim --headless -u NONE -l tests/lua/layout_and_panel_toggle_spec.lua && ./scripts/test-lua.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/ plugin/ tests/lua/
git commit -m "feat(layout): auto-manage review panel widths and add :Jpr panel toggle"
```

---

### Task 2: Termius iPad 256-Color Diff Highlights (`ctermbg` & `ctermfg`)

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `lua/jpr/highlights/init.lua`
- Modify: `tests/lua/highlights_spec.lua`
- Modify: `tests/lua/highlights_contrast_spec.lua`

**Interfaces:**
- Produces `jpr.highlights`:
  - `rgb_to_cterm256(rgb)` -> `integer` (16..255)
  - `create_diff_highlights(normal_bg, background_option)` -> specs with both `bg` and `ctermbg` (and no `fg`/`ctermfg`)
  - Derived contrast groups set both `fg` and `ctermfg`.

- [ ] **Step 1: Add failing tests to `tests/lua/highlights_spec.lua` and `tests/lua/highlights_contrast_spec.lua`**

Assert:
1. `highlights.rgb_to_cterm256` maps black (`0x000000` -> `16`), white (`0xffffff` -> `231`), pure green (`0x00ff00` -> `46`), pure red (`0xff0000` -> `196`), and mid-grey (`0x808080` -> `244` or `102` within 10 units).
2. `create_diff_highlights` includes chromatic `ctermbg` values:
   - Dark (both blended and nil fallback): `JprDiffAdd = 22`, `JprDiffAddText = 28`, `JprDiffDelete = 52`, `JprDiffDeleteText = 88`.
   - Light (both blended and nil fallback): `JprDiffAdd = 194`, `JprDiffAddText = 157`, `JprDiffDelete = 224`, `JprDiffDeleteText = 217`.
3. `define_highlights()` applies `ctermbg` onto all four `JprDiff*` groups, updates `ctermbg` on `ColorScheme` dark <-> light switch, and preserves user overrides of `ctermbg` as well as `bg`.
4. `get_contrast_group` sets numeric `ctermfg` matching `rgb_to_cterm256(adjusted_fg)` on derived `JprDiffAddFg_*` / `JprDiffDeleteFg_*` groups so 256-color terminals never lose syntax foregrounds.

- [ ] **Step 2: Run highlight specs to confirm failure**

Run: `nvim --headless -u NONE -l tests/lua/highlights_spec.lua && nvim --headless -u NONE -l tests/lua/highlights_contrast_spec.lua`
Expected: FAIL (`ctermbg` / `rgb_to_cterm256` missing).

- [ ] **Step 3: Implement `ctermbg` palettes and `rgb_to_cterm256` `ctermfg` in `lua/jpr/highlights/init.lua`**

Add `DARK_CTERM_BG`, `LIGHT_CTERM_BG`, `M.rgb_to_cterm256(rgb)`, include `ctermbg` in `create_diff_highlights` and `apply_diff_highlights`, track both `bg` and `ctermbg` in `last_applied_diff_bg` / `should_update_diff_highlight`, and set `spec.ctermfg = M.rgb_to_cterm256(adjusted_fg)` in `apply_contrast_highlight`.

- [ ] **Step 4: Run highlight specs to verify pass**

Run: `nvim --headless -u NONE -l tests/lua/highlights_spec.lua && nvim --headless -u NONE -l tests/lua/highlights_contrast_spec.lua`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/highlights/init.lua tests/lua/highlights_spec.lua tests/lua/highlights_contrast_spec.lua
git commit -m "fix(highlights): emit 256-color ctermbg and ctermfg for Termius compatibility"
```

---

### Task 3: Full-File Context & Hunk-Safe Stream Syntax Highlighting (`gF`)

help-me-pick: implement L2 (hours=1.0 cause=known material=familiar stakes=low verified=yes)

**Files:**
- Modify: `lua/jpr/render/stream.lua`
- Modify: `lua/jpr/views/stream/syntax.lua`
- Modify: `lua/jpr/views/stream/init.lua`
- Modify: `tests/lua/stream_syntax_spec.lua`

**Interfaces:**
- Produces `render.stream` `code_rows` entries with `{ line, path, gutter_length, text, change, left_line, right_line, hunk_index }`.
- Produces `views.stream.syntax`:
  - `dedent_lines(lines)` -> `(dedented_lines: string[], stripped_indent: integer)`
  - `apply(buf, column, opts)` where `opts = { worktree?: string }`

- [ ] **Step 1: Add failing tests to `tests/lua/stream_syntax_spec.lua`**

Cover:
1. `render.create_layout_from_stream` records `left_line`, `right_line`, and `hunk_index` on `code_rows`.
2. Mid-file hunk with `worktree` option (using a temp worktree file, e.g., multi-section Lua or YAML file): rows at lines 8-12 (starting inside a nested block and dedenting) receive accurate syntax extmarks from the full file.
3. Fallback without `worktree` (or for removed rows): indented fragment that starts deeper and dedents mid-hunk still produces syntax extmarks via `dedent_lines` + per-line recovery; multiple hunks at different indentation levels are parsed independently.
4. Untrusted path (`../escape.lua`) never reads outside `worktree` and falls back safely.

- [ ] **Step 2: Run stream syntax spec to confirm failure**

Run: `nvim --headless -u NONE -l tests/lua/stream_syntax_spec.lua`
Expected: FAIL.

- [ ] **Step 3: Implement full-file lookup and hunk/dedent/per-line recovery**

1. Update `lua/jpr/render/stream.lua` to record `left_line`, `right_line`, and `hunk_index` on `code_rows`.
2. Update `lua/jpr/views/stream/init.lua` to pass `{ worktree = session.worktree }` into `M.fill` -> `syntax.apply(buf, column, opts)`.
3. Update `lua/jpr/views/stream/syntax.lua`:
   - `M.dedent_lines(lines)`
   - Safe full-file lookup from `opts.worktree` (validated via `diff.name_to_relative_path`, capped at `MAX_FILE_ROWS`, verifying `file_lines[entry.right_line] == entry.text`) for added/context rows.
   - Hunk-and-side grouped fallback using `dedent_lines` + column offset restoration, with per-line dedented fallback for any non-blank row that got zero spans from a parse containing `ERROR` nodes.

- [ ] **Step 4: Run stream syntax spec and full Lua suite**

Run: `nvim --headless -u NONE -l tests/lua/stream_syntax_spec.lua && ./scripts/test-lua.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/render/stream.lua lua/jpr/views/stream/syntax.lua lua/jpr/views/stream/init.lua tests/lua/stream_syntax_spec.lua
git commit -m "fix(stream): preserve syntax highlighting on mid-file hunks"
```

---

### Task 4: Documentation Update and Full Workspace Verification

help-me-pick: implement L1 (hours=0.25 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `docs/architecture.md`
- Modify: `README.md`

- [ ] **Step 1: Update `docs/architecture.md` and `README.md`**

Document `lua/jpr/views/layout.lua`, `:Jpr panel` / `gp` (`keys.toggle_panel`), 256-color `ctermbg`/`ctermfg` diff highlight parity, and full-file stream syntax context.

- [ ] **Step 2: Run `just check`**

Run: `just check`
Expected: formatting, clippy, Rust tests, and all Lua specs pass cleanly.

- [ ] **Step 3: Commit docs**

```bash
git add docs/architecture.md README.md
git commit -m "docs: document layout manager, :Jpr panel, 256-color diffs, and stream syntax"
```
