# Contrast-Aware Diff Foreground Highlighting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically lift foreground syntax contrast on green/red diff lines in OKLCH space across the diff stream, unified file overlay, and split file diff (`:diffthis`) while preserving every colorscheme's hue and keeping runtime overhead negligible.

**Architecture:** A pure OKLCH/WCAG math module (`lua/jpr/highlights/contrast.lua`) computes hue-locked, gamut-clamped, same-hue-guarded foreground colors against active `JprDiffAdd`/`JprDiffDelete` backgrounds. `lua/jpr/highlights/init.lua` lazily caches collision-free derived highlight groups (`JprDiffAddFg_*`, `JprDiffDeleteFg_*`) and refreshes them on `ColorScheme`. The diff stream swaps Treesitter marks directly in `lua/jpr/views/stream/syntax.lua` (zero extra scroll work), while unified and split file diffs share one viewport-scoped `nvim_set_decoration_provider` (`lua/jpr/views/diff/contrast.lua`) plus contrast-adjusted syntax chunks on unified removed virtual lines (`lua/jpr/render/overlay.lua`).

**Tech Stack:** Lua (Neovim 0.11+ / 0.12 APIs: `nvim_get_hl`, `nvim_set_hl`, `nvim_buf_set_extmark`, `nvim_set_decoration_provider`, `vim.treesitter`), headless Neovim spec runner (`./scripts/test-lua.sh`), `just check`.

**Spec:** `docs/superpowers/specs/2026-11-25-diff-fg-contrast-design.md`

## Global Constraints

- Lua-only scope: zero changes to Rust crates (`crates/`), JSON-RPC protocol, or CLI TUI schemas.
- `JprDiffAdd`, `JprDiffAddText`, `JprDiffDelete`, and `JprDiffDeleteText` remain strictly background-only (`fg = nil`, `link = nil`).
- `require("jpr.highlights")` preserves all existing exports (`blend_rgb`, `is_dark_background`, `create_diff_highlights`, `define_highlights`).
- `overlay.removed_line_to_chunks` preserves byte-for-byte existing output when `opts.fg_group` and `opts.syntax_spans` are omitted.
- Every function stays `<= 45` lines; zero em dashes in code, comments, tests, or docs; descriptive variable and builder names.
- Red/Green TDD for every task; `just check` passes cleanly before finishing.

## Review Focus

- **Transparent / unset `Normal.bg` or `Normal.fg`:** `adjust_fg_for_diff_bg` falls back to default `orig_bg_L` (`0.25` dark / `0.96` light) when `Normal.bg` is nil, and `get_contrast_group("Normal", "add")` returns `"Normal"` without error when `Normal.fg` is nil. (Pinned in Tasks 1 and 2.)
- **Background-only or `reverse = true` highlight groups:** `get_contrast_group` returns the source group unchanged without inventing a `fg` or breaking reversed highlights. (Pinned in Task 2.)
- **ColorScheme change where a previously-derived group loses `fg`:** `define_highlights()` relinks that derived group back to its source group so existing buffers never display stale theme colors. (Pinned in Task 2.)
- **Long/minified lines (`> 1000` bytes) and non-tracked windows in the decoration provider:** Lines above `1000` bytes are skipped and non-tracked windows receive zero ephemeral marks. (Pinned in Task 4.)
- **Split `:diffthis` unfocused window:** `on_win` queries `diff_hlID` inside `vim.api.nvim_win_call(win, ...)` so both `base_win` and `win` receive their own independent diff contrast marks even when the other window is current. (Pinned in Task 4.)

---

## File Map

| Task | Files | Responsibility |
| --- | --- | --- |
| Task 1 | Create `lua/jpr/highlights/contrast.lua`, Create `tests/lua/highlights_contrast_spec.lua` | Pure sRGB/linear/OKLab/OKLCH conversion, WCAG luminance/contrast ratio, gamut-clamped chroma projection, same-hue guard, and foreground contrast adjustment |
| Task 2 | Move `lua/jpr/highlights.lua` -> `lua/jpr/highlights/init.lua`, Modify `tests/lua/highlights_contrast_spec.lua` | Lazy collision-free `JprDiffAddFg_*` / `JprDiffDeleteFg_*` cache, style preservation, `bg == nil`, user override awareness, and `ColorScheme` refresh/relink |
| Task 3 | Modify `lua/jpr/render/stream.lua`, Modify `lua/jpr/views/stream/syntax.lua`, Modify `tests/lua/stream_syntax_spec.lua` | Carry `change` on `code_rows`, export `collect_line_spans`, apply priority `85` `Normal` fallback and priority `90` contrast-adjusted Treesitter marks on added/removed stream rows |
| Task 4 | Modify `lua/jpr/render/overlay.lua`, Create `lua/jpr/views/diff/contrast.lua`, Modify `lua/jpr/views/diff/init.lua`, Modify `tests/lua/overlay_render_spec.lua`, Create `tests/lua/diff_contrast_spec.lua` | Chunk splitting for removed virtual lines, viewport-scoped `nvim_set_decoration_provider` (`45`/`115`/`135`, `1000`-byte guard, unified + split `:diffthis`), and lifecycle wiring |
| Task 5 | Modify `docs/architecture.md`, Modify `docs/decisions.md` | Document new highlight/contrast architecture and decision rationale; run full `just check` |

---

### Task 1: Pure OKLCH & WCAG Contrast Engine

High-risk: no
help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Create: `lua/jpr/highlights/contrast.lua`
- Test: `tests/lua/highlights_contrast_spec.lua`

**Interfaces:**
- Consumes: none (pure Lua math, zero Neovim API calls).
- Produces (`lua/jpr/highlights/contrast.lua`):
  - `M.relative_luminance(rgb: number) -> number`
  - `M.contrast_ratio(rgb_a: number, rgb_b: number) -> number`
  - `M.rgb_to_oklch(rgb: number) -> (L: number, C: number, H: number)`
  - `M.oklch_to_rgb_clamped(lightness: number, chroma: number, hue: number) -> (rgb: number, clamped_chroma: number)`
  - `M.adjust_fg_for_diff_bg(fg_rgb: number, normal_bg_rgb: number|nil, diff_bg_rgb: number, is_dark: boolean) -> number`

- [ ] **Step 1: Write the failing pure-math tests in `tests/lua/highlights_contrast_spec.lua`**

Write tests asserting:
1. `relative_luminance(0x000000) == 0`, `relative_luminance(0xffffff) == 1`, and `contrast_ratio(0x000000, 0xffffff)` within `21.0 +/- 0.01`.
2. `rgb_to_oklch` -> `oklch_to_rgb_clamped` round-trips `0x000000`, `0xffffff`, `0x282c34`, `0x98c379`, `0xe06c75`, `0x61afef`, `0xc678dd`, and `0x116329` within `<= 1` per RGB channel.
3. On dark `onedark` (`normal_bg = 0x282c34`, `add_bg = 0x2d4e3b`, `del_bg = 0x5a3539`):
   - Every token (`Normal 0xabb2bf`, `Comment 0x5c6370`, `String 0x98c379`, `Error 0xe06c75`, `Keyword 0xc678dd`, `Func 0x61afef`) strictly increases `contrast_ratio` against `add_bg` and `del_bg`.
   - Chromatic tokens keep locked OKLCH hue (`angular_diff_deg < 2.0` degrees) and retain positive chroma (`out_C > 0.05`).
   - Dim `Comment` (`0x5c6370`) lifts above `3.5:1` on `add_bg` while remaining dimmer than adjusted `Normal`.
   - Same-hue guard: green `String` (`0x98c379`) gets a larger OKLCH lightness lift on `add_bg` (green) than on `del_bg` (red), and red `Error` (`0xe06c75`) gets a larger OKLCH lightness lift on `del_bg` (red) than on `add_bg` (green).
4. On light `github` (`normal_bg = 0xfafafa`, `add_bg = 0xc9e5cf`, `del_bg = 0xf4ced1`):
   - `Normal 0x24292f`, `Comment 0x6e7781`, `String 0x116329`, and `Keyword 0xcf222e` all strictly darken (`out_L < fg_L`) and increase `contrast_ratio` against `add_bg`/`del_bg`, with green `String` getting stronger darkening on green `add_bg` than red `del_bg`.
5. Edge cases: `normal_bg_rgb = nil` works cleanly on both `is_dark = true` and `is_dark = false`; extreme backgrounds (`0x000000`, `0xffffff`) return valid 24-bit RGB integers in `[0, 0xffffff]` without NaN.

- [ ] **Step 2: Run the spec to verify it fails**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/highlights_contrast_spec.lua`
Expected: FAIL with `module 'jpr.highlights.contrast' not found`.

- [ ] **Step 3: Implement `lua/jpr/highlights/contrast.lua`**

Implement the pure OKLCH + WCAG functions from Section 1 of the spec (`srgb_to_linear`, `linear_to_srgb`, `signed_cbrt`, `relative_luminance`, `contrast_ratio`, `rgb_to_oklch`, `oklch_to_linear_rgb`, `oklch_to_rgb_clamped` with 10-step chroma binary search, `compute_hue_proximity` with 50-degree cosine falloff for `fg_C > 0.025 and bg_C > 0.025`, and `adjust_fg_for_diff_bg` with `bg_shift * 0.85 + 0.04 + 0.06 * same_hue` and `min_sep = 0.34 + 0.08 * same_hue`, bounded to `[0.10, 0.96]`). Keep every helper function `<= 45` lines.

- [ ] **Step 4: Run the spec to verify it passes**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/highlights_contrast_spec.lua`
Expected: PASS (`highlights_contrast_spec: ok`).

- [ ] **Step 5: Commit Task 1**

```bash
git add lua/jpr/highlights/contrast.lua tests/lua/highlights_contrast_spec.lua
git commit -m "feat(highlights): add pure OKLCH contrast adjustment engine"
```

---

### Task 2: Lazy Derived Highlight Cache & ColorScheme Refresh

High-risk: no
help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Move/Create: `lua/jpr/highlights/init.lua` (replacing `lua/jpr/highlights.lua`)
- Delete: `lua/jpr/highlights.lua`
- Test: `tests/lua/highlights_contrast_spec.lua` (extend), `tests/lua/highlights_spec.lua` (verify unchanged passes)

**Interfaces:**
- Consumes: `jpr.highlights.contrast.adjust_fg_for_diff_bg`
- Produces (`lua/jpr/highlights/init.lua`, loaded via `require("jpr.highlights")`):
  - Existing: `M.blend_rgb`, `M.is_dark_background`, `M.create_diff_highlights`, `M.define_highlights`
  - New:
    - `M.build_contrast_group_name(source_group: string, kind: "add"|"delete") -> string`
    - `M.get_contrast_group(source_group: string, kind: "add"|"delete") -> string`
    - `M.reset_contrast_cache()` (test helper clearing in-memory caches cleanly between colorscheme assertions if needed; `define_highlights()` already refreshes automatically in production)

- [ ] **Step 1: Add failing cache, style, and `ColorScheme` tests to `tests/lua/highlights_contrast_spec.lua`**

Append tests asserting:
1. `build_contrast_group_name("@a.b", "add") ~= build_contrast_group_name("@a_b", "add")` and both match `^JprDiffAddFg_[%w_]+$`; `"delete"` uses prefix `JprDiffDeleteFg_`.
2. With `Normal = { bg = 0x282c34, fg = 0xabb2bf }`, `@string = { fg = 0x98c379, italic = true, bold = true }`, and `define_highlights()`:
   - `get_contrast_group("@string", "add")` returns the `JprDiffAddFg_*` name.
   - Its `nvim_get_hl(0, { name = derived, link = false })` has `bg == nil`, `italic == true`, `bold == true`, and `contrast_ratio(derived.fg, JprDiffAdd.bg) > contrast_ratio(0x98c379, JprDiffAdd.bg)`.
   - Calling `get_contrast_group("@string", "add")` a second time returns the same cached group name.
3. Background-only group (`TestBgOnly = { bg = 0x334455 }`) and reversed group (`TestReversed = { fg = 0xabb2bf, reverse = true }`) both return their original source group name unchanged.
4. Transparent `Normal` with `fg = nil`: `get_contrast_group("Normal", "add")` returns `"Normal"` without throwing.
5. Custom user override on `JprDiffAdd` (e.g. brighter custom green `bg = 0x3a6e4c`): derived group computes against the active custom `JprDiffAdd.bg`.
6. `ColorScheme` refresh:
   - Switching to a light theme (`vim.o.background = "light"`, `Normal = { bg = 0xfafafa, fg = 0x24292f }`, `@string = { fg = 0x116329 }`) and firing `vim.api.nvim_exec_autocmds("ColorScheme", {})` updates the already-registered `JprDiffAddFg_*` group in place so its `fg` is darker than `0x116329` with `bg == nil`.
   - If a previously-derived group (`TestTransient`) loses its `fg` on the next `ColorScheme`, its derived group is relinked (`link == "TestTransient"`) so stale colors never remain.

- [ ] **Step 2: Run the spec to verify it fails**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/highlights_contrast_spec.lua`
Expected: FAIL because `build_contrast_group_name` / `get_contrast_group` do not exist yet.

- [ ] **Step 3: Move `lua/jpr/highlights.lua` to `lua/jpr/highlights/init.lua` and implement derived highlight caching + refresh**

Move the existing file to `lua/jpr/highlights/init.lua` and delete `lua/jpr/highlights.lua`. Add:
- `PRESERVED_ATTRS` list (`bold`, `italic`, `underline`, `undercurl`, `underdouble`, `underdotted`, `underdashed`, `strikethrough`, `sp`, `blend`, `standout`, `nocombine`).
- `M.build_contrast_group_name(source_group, kind)` hex-encoding non-`%w` bytes as `_%02x`.
- `resolve_diff_bg(kind)` reading active `JprDiffAdd`/`JprDiffDelete` `bg` (falling back to `create_diff_highlights`).
- `apply_contrast_highlight(source_group, kind, derived_name)` computing adjusted `fg` via `contrast.adjust_fg_for_diff_bg`, returning `false` when `source_hl.fg` is non-numeric or `source_hl.reverse == true`, else calling `vim.api.nvim_set_hl(0, derived_name, spec)` (`bg` omitted).
- `M.get_contrast_group(source_group, kind)` with O(1) cache table (`contrast_cache[cache_key]`) and `registered_derived[derived_name] = { source = source_group, kind = kind }`.
- `refresh_contrast_highlights()` called at the end of `apply_diff_highlights()` (inside `M.define_highlights()`): clears negative cache entries, recomputes every registered derived group, and calls `vim.api.nvim_set_hl(0, derived_name, { link = entry.source })` whenever a source group no longer qualifies.

- [ ] **Step 4: Run both highlight specs to verify they pass**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/highlights_spec.lua && nvim --headless -u NONE -i NONE -l tests/lua/highlights_contrast_spec.lua`
Expected: Both print `ok`.

- [ ] **Step 5: Commit Task 2**

```bash
git add -A lua/jpr/highlights.lua lua/jpr/highlights/init.lua tests/lua/highlights_contrast_spec.lua
git commit -m "feat(highlights): add lazy contrast-adjusted derived highlight cache"
```

---

### Task 3: Diff Stream Contrast Integration & Reusable Line-Span Collector

High-risk: no
help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `lua/jpr/render/stream.lua:51-78`
- Modify: `lua/jpr/views/stream/syntax.lua:1-151`
- Test: `tests/lua/stream_syntax_spec.lua`

**Interfaces:**
- Consumes: `jpr.highlights.get_contrast_group(source_group, kind)`
- Produces:
  - `column.code_rows[i]` gains `change = cell.change` (`"added" | "removed" | "context"`).
  - `jpr.views.stream.syntax.collect_line_spans(lines: string[], language: string) -> table<integer, { col_start: integer, col_end: integer, hl_group: string }[]>` (1-based line keys matching `lines`, raw resolved Treesitter `hl_group`s).

- [ ] **Step 1: Update and extend `tests/lua/stream_syntax_spec.lua` with failing tests**

Set explicit dark `Normal` (`bg = 0x282c34, fg = 0xabb2bf`) and `@keyword` (`fg = 0xc678dd`), `@string` (`fg = 0x98c379`), `@number` (`fg = 0xd19a66`), then `jpr.define_highlights()`, and assert:
1. `column.code_rows[i].change` records `"added"`, `"removed"`, and `"context"` accurately.
2. In a mixed stream containing an `"added"` Lua row, a `"removed"` Lua row, and a `"context"` Lua row:
   - `"context"` row receives raw `@keyword*` extmarks at priority `90` and NO `Normal` fallback mark at priority `85`.
   - `"added"` row receives `JprDiffAddFg_*` syntax extmarks at priority `90` (with higher WCAG contrast against `JprDiffAdd.bg` than the raw syntax group) AND a `JprDiffAddFg_*` `Normal` fallback mark at priority `85`.
   - `"removed"` row receives `JprDiffDeleteFg_*` syntax extmarks at priority `90` (with higher WCAG contrast against `JprDiffDelete.bg` than the raw syntax group) AND a `JprDiffDeleteFg_*` `Normal` fallback mark at priority `85`.
   - `JprDiffAdd` line mark stays at priority `100` (`bg`-only) and `JprDiffAddText` word mark stays at priority `110` (`bg`-only).
3. `syntax.collect_line_spans({ "local x = 42" }, "lua")` returns spans for `"local"` (`@keyword*`) and `"42"` (`@number*`) on line `1`.

- [ ] **Step 2: Run the stream syntax spec to verify it fails**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/stream_syntax_spec.lua`
Expected: FAIL because `change` is nil, `collect_line_spans` does not exist, and added/removed rows still use raw `@keyword`.

- [ ] **Step 3: Implement `change` on `code_rows` and stream contrast integration**

1. In `lua/jpr/render/stream.lua`: pass `cell.change` into `record_code_row(column, row.path, #gutter, cell.text, cell.change)` and store `change = change` on each entry.
2. In `lua/jpr/views/stream/syntax.lua`:
   - Add `NORMAL_FALLBACK_PRIORITY = 85` and `CHANGE_TO_CONTRAST_KIND = { added = "add", removed = "delete" }`.
   - Add `M.collect_line_spans(lines, language)` reusing `get_highlight_group_from_capture` and `vim.treesitter.get_string_parser` to collect per-line `{ col_start, col_end, hl_group }` tables (1-based line indices).
   - Add `apply_normal_fallbacks(buf, rows)` emitting priority `85` `highlights.get_contrast_group("Normal", kind)` extmarks over `0 .. entry.gutter_length + #entry.text` for every row whose `change` maps to `"add"` or `"delete"` (skipping when derived equals `"Normal"`).
   - In `apply_capture_to_rows`, resolve `effective_group = kind and highlights.get_contrast_group(highlight_group, kind) or highlight_group` per row at `priority = SYNTAX_PRIORITY` (`90`).
   - Run `apply_normal_fallbacks` inside `highlight_file_group` (after the `MAX_FILE_ROWS` guard, before returning when no parser exists) so plain unhighlighted added/removed lines still get lifted `Normal` contrast at priority `85` while files over 5000 rows are still skipped and unknown extensions receive zero priority `90` Treesitter marks.

- [ ] **Step 4: Run stream specs to verify they pass**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/stream_syntax_spec.lua && nvim --headless -u NONE -i NONE -l tests/lua/stream_render_spec.lua && nvim --headless -u NONE -i NONE -l tests/lua/stream_view_spec.lua`
Expected: All three print `ok`.

- [ ] **Step 5: Commit Task 3**

```bash
git add lua/jpr/render/stream.lua lua/jpr/views/stream/syntax.lua tests/lua/stream_syntax_spec.lua
git commit -m "feat(stream): apply contrast-adjusted foreground highlights on diff rows"
```

---

### Task 4: File Diff Viewport Contrast Provider & Removed Virtual-Line Chunks

High-risk: no
help-me-pick: implement L2 (hours=1 cause=known material=familiar stakes=low verified=yes)

**Files:**
- Modify: `lua/jpr/render/overlay.lua:56-114`
- Create: `lua/jpr/views/diff/contrast.lua`
- Modify: `lua/jpr/views/diff/init.lua:103-220`
- Test: `tests/lua/overlay_render_spec.lua` (extend), `tests/lua/diff_contrast_spec.lua` (new), `tests/lua/diff_view_spec.lua` (verify unchanged passes)

**Interfaces:**
- Consumes:
  - `jpr.highlights.get_contrast_group(source_group, kind)`
  - `jpr.views.stream.syntax.get_highlight_group_from_capture`, `jpr.views.stream.syntax.collect_line_spans`, `jpr.views.stream.syntax.get_language_from_path`
- Produces:
  - `overlay.removed_line_to_chunks(removed, opts)` accepts optional `opts.fg_group` (`string|nil`) and `opts.syntax_spans` (`{ col_start, col_end, hl_group }[]|nil`); when both are absent, behaves identically to before.
  - `overlay.create_extmarks_from_diff(diff, line_count, opts)` accepts optional `opts.removed_fg_group` and `opts.removed_syntax_by_block` (`table<integer, table<integer, span[]>>` indexed by block index then 1-based line index within that block).
  - `lua/jpr/views/diff/contrast.lua`:
    - `M.MAX_LINE_BYTES = 1000`
    - `M.attach_unified(win, buf, added_lines)` (`added_lines`: map `{ [row0] = "add" }`)
    - `M.attach_split(win)`
    - `M.detach_window(win)`
    - `M.clear_buffer(buf)`
    - `M.collect_viewport_marks(win, buf, topline, botline) -> { row, col_start, col_end, hl_group, priority }[]` (pure-enough helper called by `on_win` and directly inspectable in unit tests so we can verify exact priorities `45`/`115`/`135` alongside live redraws!)

- [ ] **Step 1: Write failing tests in `tests/lua/overlay_render_spec.lua` and `tests/lua/diff_contrast_spec.lua`**

1. Extend `tests/lua/overlay_render_spec.lua`:
   - When `opts.fg_group = "JprDiffDeleteFg_Normal"` and `opts.syntax_spans = { { col_start = 0, col_end = 3, hl_group = "JprDiffDeleteFg_Keyword" } }` are passed for `{ text = "let x = 1;", words = { { start = 8, ["end"] = 9 } } }`, chunks split cleanly across both syntax and word boundaries with `{ "JprDiffDelete", "JprDiffDeleteFg_Keyword" }`, `{ "JprDiffDelete", "JprDiffDeleteFg_Normal" }`, `{ "JprDiffDeleteText", "JprDiffDeleteFg_Normal" }`, and trailing padding `"JprDiffDelete"`.
   - When a syntax span overlaps a word-diff span, the overlapping segment uses `{ "JprDiffDeleteText", syntax_hl }`.
2. Create `tests/lua/diff_contrast_spec.lua` testing:
   - Non-tracked window: `collect_viewport_marks` returns `{}` and redraw invokes no contrast marks.
   - Unified overlay on a Lua buffer (`vim.treesitter.start(buf, "lua")`) with an added line, an unchanged line, a simulated LSP semantic token extmark (`@lsp.type.variable` in a semantic-tokens namespace), and a long `> 1000`-byte added line:
     - Added line produces `Normal` fallback at priority `45`, Treesitter contrast marks at priority `115`, and LSP contrast mark at priority `135`, all pointing to `JprDiffAddFg_*`.
     - Unchanged line produces zero contrast marks.
     - `> 1000`-byte added line is skipped (zero contrast marks).
     - Removed virtual lines in `diff_view.draw_overlay` carry `{ "JprDiffDelete", "JprDiffDeleteFg_*" }` chunks (syntax-highlighted for Lua, `Normal`-lifted for unknown filetypes).
   - Split `:diffthis` across two windows (`base_win` and `win`):
     - With `win` focused, `collect_viewport_marks` returns contrast marks for **both** `base_win` and `win` independently (confirming `nvim_win_call` reads each window's own `diff_hlID`), leaving equal lines untouched.
     - After `diff_view.clear(session, win)` (or `detach_window`), tracked windows are removed and `collect_viewport_marks` returns `{}`.

- [ ] **Step 2: Run the new/updated specs to verify they fail**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/overlay_render_spec.lua; nvim --headless -u NONE -i NONE -l tests/lua/diff_contrast_spec.lua`
Expected: Both fail (missing chunk-splitting support and missing `jpr.views.diff.contrast` module).

- [ ] **Step 3: Implement `overlay.lua` chunk splitting, `lua/jpr/views/diff/contrast.lua`, and `lua/jpr/views/diff/init.lua` wiring**

1. In `lua/jpr/render/overlay.lua`:
   - Keep the existing fast path when `not opts.fg_group and not opts.syntax_spans`.
   - Add a small pure interval splitter `split_removed_segments(text_len, words, syntax_spans, fg_group)` collecting sorted unique cut points in `[0, text_len]` and resolving each segment's `{ bg_group, fg_group }` (picking the last matching syntax span or `fg_group`), then expanding tabs and padding to `opts.width` with `"JprDiffDelete"`.
   - In `create_extmarks_from_diff`, pass per-block/per-line `syntax_spans` and `fg_group = opts.removed_fg_group` into `removed_line_to_chunks`.
2. Create `lua/jpr/views/diff/contrast.lua`:
   - Namespace `contrast_namespace = vim.api.nvim_create_namespace("jpr-diff-contrast")`.
   - Constants: `M.MAX_LINE_BYTES = 1000`, `NORMAL_PRIORITY = 45`, `TREESITTER_PRIORITY = 115`, `LSP_PRIORITY = 135`, `IGNORED_CAPTURES = { spell = true, nospell = true, conceal = true }`.
   - `tracked_windows` (`[win] = { mode = "unified", buf = buf }` or `{ mode = "split" }`) and `unified_lines_by_buf` (`[buf] = { [row0] = "add" }`).
   - Lazy `ensure_provider()` registering `nvim_set_decoration_provider(contrast_namespace, { on_start = ..., on_win = ... })` once:
     - `on_start`: prunes invalid windows, returns `next(tracked_windows) ~= nil`.
     - `on_win(_, win, buf, topline, botline)`: emits `ephemeral = true` marks from `M.collect_viewport_marks(win, buf, topline, botline)` and returns `false`.
   - `resolve_diff_kinds(entry, win, buf, topline, botline)`:
     - Unified: intersects `unified_lines_by_buf[buf]` with `[topline, botline]`.
     - Split: `pcall(vim.api.nvim_win_call, win, ...)` querying `vim.fn.diff_hlID(row + 1, 1)` and mapping `DiffAdd`/`DiffChange`/`DiffText -> "add"`, `DiffDelete -> "delete"`.
   - `append_treesitter_marks(marks, buf, diff_kinds, line_lengths, topline, botline)`: uses `vim.treesitter.highlighter.active[buf]` -> `highlighter.tree:for_each_tree(...)` -> `query:iter_captures(root, buf, topline, botline + 1)` (respecting `MAX_LINE_BYTES`).
   - `append_lsp_marks(marks, buf, diff_kinds, line_lengths, topline, botline)`: inspects namespaces from `vim.api.nvim_get_namespaces()` (skipping `contrast_namespace` and `jpr-*` namespaces) whose extmarks in `[topline, botline]` carry `@lsp.` `hl_group`s and maps them through `highlights.get_contrast_group(hl_group, kind)`.
3. In `lua/jpr/views/diff/init.lua`:
   - In `draw_overlay(buf, diff, win)`: resolve `removed_fg_group` (`highlights.get_contrast_group("Normal", "delete")`, nil if `"Normal"`), resolve removed-block Treesitter spans via `stream_syntax.collect_line_spans` when a language is available (mapping each span's `hl_group` through `highlights.get_contrast_group(group, "delete")`), pass both to `overlay.create_extmarks_from_diff`, and call `diff_contrast.attach_unified(win, buf, added_lines)`.
   - In `open_base(session, win, buf, diff)`: call `diff_contrast.attach_split(base_win)` and `diff_contrast.attach_split(win)`.
   - In `clear(session, win)`: call `diff_contrast.detach_window(win)`, `diff_contrast.clear_buffer(applied.buf)` when `not is_buffer_drawn(session, applied.buf)`, and `diff_contrast.detach_window(base_split.base_win)` when `base_split` exists.

- [ ] **Step 4: Run overlay and diff specs to verify they pass**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/overlay_render_spec.lua && nvim --headless -u NONE -i NONE -l tests/lua/diff_contrast_spec.lua && nvim --headless -u NONE -i NONE -l tests/lua/diff_view_spec.lua`
Expected: All three print `ok`.

- [ ] **Step 5: Commit Task 4**

```bash
git add lua/jpr/render/overlay.lua lua/jpr/views/diff/contrast.lua lua/jpr/views/diff/init.lua tests/lua/overlay_render_spec.lua tests/lua/diff_contrast_spec.lua
git commit -m "feat(diff): add viewport contrast provider and removed-line syntax contrast"
```

---

### Task 5: Documentation Updates & Full Workspace Verification

High-risk: no
help-me-pick: implement L1 (hours=0.3 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `docs/architecture.md`
- Modify: `docs/decisions.md`

**Interfaces:**
- Consumes: Final module paths and APIs from Tasks 1-4.
- Produces: Up-to-date architectural inventory and decision record.

- [ ] **Step 1: Update `docs/architecture.md`**

Update the Neovim plugin module table to reflect:
- `jpr.highlights` (`lua/jpr/highlights/init.lua`, `contrast.lua`): semantic links, blended background-only diff tints, OKLCH contrast math, and lazy colorscheme-refreshed derived foreground highlight groups (`JprDiffAddFg_*`, `JprDiffDeleteFg_*`).
- `jpr.render.overlay`: removed virtual-line chunk splitting across word-diff and optional syntax/contrast highlight spans.
- `jpr.views.stream` (`syntax.lua`): per-file Treesitter highlighting with contrast-adjusted foregrounds on added/removed rows and reusable `collect_line_spans`.
- `jpr.views.diff` (`init.lua`, `contrast.lua`): unified overlay removed-line syntax contrast and viewport-scoped `nvim_set_decoration_provider` lifting `Normal`, Treesitter, and LSP semantic-token contrast on visible diff lines in unified and split `:diffthis` windows.

- [ ] **Step 2: Append decision entry to `docs/decisions.md`**

Add a new section at the bottom of `docs/decisions.md` documenting why diff foreground legibility uses lazy OKLCH contrast-preserving derived highlight groups with a same-hue guard (direct swap in the stream + viewport-scoped decoration provider in unified/split file diffs) rather than setting `fg` on `JprDiff*`, flat RGB brightening, or per-column `vim.inspect_pos`.

- [ ] **Step 3: Run full `just check` and em-dash guard**

Run: `just check && ! rg -P '\x{2014}' lua/jpr/highlights lua/jpr/render/stream.lua lua/jpr/render/overlay.lua lua/jpr/views/stream/syntax.lua lua/jpr/views/diff/contrast.lua lua/jpr/views/diff/init.lua tests/lua/highlights_contrast_spec.lua tests/lua/diff_contrast_spec.lua docs/superpowers/specs/2026-11-25-diff-fg-contrast-design.md docs/superpowers/plans/2026-11-25-diff-fg-contrast.md docs/architecture.md docs/decisions.md`
Expected: `just check` exits `0` (fmt-check, clippy, Rust tests, all Lua specs) and zero em dashes found.

- [ ] **Step 4: Commit Task 5**

```bash
git add docs/architecture.md docs/decisions.md
git commit -m "docs: document contrast-aware diff foreground highlighting"
```

---

## Final Review

help-me-pick: bug-hunting-and-code-review L3 (hours=0.5 cause=known material=familiar stakes=low verified=yes)
