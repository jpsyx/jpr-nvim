# Design: Contrast-Aware Diff Foreground Highlighting

## Intent and Why

Increasing the background tint strength of `JprDiffAdd`, `JprDiffAddText`, `JprDiffDelete`, and `JprDiffDeleteText` makes added and deleted lines stand out clearly, but brighter green and red backgrounds compress foreground contrast. Two cases suffer most:

1. **Muted tokens** (such as comments) lose almost all legibility against tinted diff lines and word-diff highlights.
2. **Same-hue tokens** (such as green strings on green added lines, or red errors and keywords on red deleted lines) blend into the background even when their raw luminance is moderate.

Hardcoding syntax colors would fight the user's colorscheme, while a flat RGB brightness multiplier clips already-bright tokens, shifts hue, and fails to distinguish green backgrounds from red ones. Instead, `jpr-nvim` can dynamically derive contrast-adjusted companion highlight groups per active colorscheme in perceptual **OKLCH** color space, preserving each syntax token's hue and style while lifting its contrast away from the specific green or red diff background across both dark and light themes.

## Goals

1. **Perceptual OKLCH contrast adjustment (`lua/jpr/highlights/contrast.lua`):** Pure color math converting sRGB <-> linear RGB <-> OKLab <-> OKLCH, computing WCAG relative luminance and contrast ratio, locking hue `H`, compensating for the lightness shift between `Normal.bg` and the diff background, applying a smooth same-hue guard when a chromatic token's hue lies close to the diff background's hue, and clamping chroma into the sRGB gamut without hue drift.
2. **Lazy, colorscheme-aware derived highlight cache (`lua/jpr/highlights/init.lua`):** Expose `get_contrast_group(source_group, kind)` (`"add"` or `"delete"`) that resolves `source_group` from the active colorscheme, derives a collision-free companion group (`JprDiffAddFg_<encoded>` or `JprDiffDeleteFg_<encoded>`) with adjusted `fg`, preserved text styles (`bold`, `italic`, `underline`, `undercurl`, `underdouble`, `underdotted`, `underdashed`, `strikethrough`, `sp`, `blend`, `standout`, `nocombine`), and `bg = nil`. Cache each group once per colorscheme and recompute all registered derived groups automatically whenever `define_highlights()` runs (including on `ColorScheme`).
3. **Zero-overhead diff stream integration (`lua/jpr/render/stream.lua`, `lua/jpr/views/stream/syntax.lua`):** Record `change` (`"added"`, `"removed"`, or `"context"`) on each `code_rows` entry. On `"added"` and `"removed"` rows, paint a contrast-adjusted `Normal` fallback at priority `85` and swap each Treesitter capture to its cached contrast-adjusted companion group at priority `90`, while leaving `"context"` rows untouched and keeping `JprDiffAdd` (`100`) and `JprDiffAddText` (`110`) strictly background-only.
4. **Viewport-scoped file diff integration (`lua/jpr/views/diff/contrast.lua`, `lua/jpr/views/diff/init.lua`, `lua/jpr/render/overlay.lua`):**
   - Provide a single `nvim_set_decoration_provider` gated strictly to active `jpr` diff windows (`on_start` returns `false` when no `jpr` diff window is open; `on_win` returns `false` for non-tracked windows).
   - Cover both **unified file overlay** (tracked added lines) and **split file diff (`:diffthis`)** (via `vim.api.nvim_win_call(win, ...)` + `vim.fn.diff_hlID(row + 1, 1)`).
   - Emit `ephemeral = true` contrast-adjusted extmarks inside `on_win` for visible diff lines (`<= 1000` bytes) across `Normal` fallback (`45`), Treesitter captures (`115`), and LSP semantic tokens (`135`).
   - Apply contrast-adjusted `Normal` fg (and Treesitter syntax highlights when a parser is available) to removed virtual lines in unified file overlay via Neovim chunk highlight arrays `{ bg_group, fg_group }`.
5. **Backwards compatibility & documentation:** Keep `require("jpr.highlights")` exports, `JprDiff*` background-only invariants, and `overlay.removed_line_to_chunks` default behavior intact. Update `docs/architecture.md` and `docs/decisions.md` in the same change.

## Non-Goals

- Inspecting legacy regex `:syntax` tokens per character via `vim.inspect_pos` or `synID` (too slow on scroll; legacy `:syntax` at priority `50` stays intact while uncaptured `Normal` text is lifted at priority `45`).
- Adding new `:Jpr` subcommands, CLI flags, or user-facing contrast tuning options (contrast adapts automatically to the active colorscheme and any custom `JprDiffAdd`/`JprDiffDelete` overrides).
- Changing the background colors of `JprDiffAdd`, `JprDiffAddText`, `JprDiffDelete`, or `JprDiffDeleteText`.
- Modifying any Rust crates (`crates/`), JSON-RPC protocol, or TUI command schemas.

## Anti-Goals

- Hardcoding syntax highlight colors or theme-specific lookup tables.
- Setting `fg` directly on `JprDiffAdd`, `JprDiffAddText`, `JprDiffDelete`, or `JprDiffDeleteText`.
- Running decoration work outside active `jpr` diff windows, scanning off-screen lines on redraw, or calling `vim.inspect_pos` per column.
- Clobbering diagnostics (`150`), search/user extmarks (`200`), or `reverse = true` highlight groups.
- Leaving stale derived colors active after `:colorscheme` changes.

## Constraints

- **Pure Lua frontend scope:** No Rust or protocol changes.
- **Code style:** Zero em dashes in code, comments, tests, or docs; functions `<= 45` lines; descriptive naming; Red/Green TDD; `just check` passes cleanly.
- **Preserved invariants:** `JprDiffAdd`, `JprDiffAddText`, `JprDiffDelete`, and `JprDiffDeleteText` remain background-only (`fg = nil`). User overrides of those diff groups are respected and automatically used as the target background when computing foreground contrast.

## Approaches

Three approaches were evaluated before writing this design:

| Approach | Summary | Trade-offs |
| --- | --- | --- |
| **1. OKLCH Contrast-Preserving + Same-Hue Guard across Stream Swap & Viewport Decoration Provider (Chosen)** | Compute contrast-adjusted companion highlight groups lazily in OKLCH (locked hue, gamut-clamped chroma, background-shift compensation, same-hue boost); swap syntax groups directly in `jpr.views.stream.syntax`; cover unified overlay and split `:diffthis` with one viewport-scoped `nvim_set_decoration_provider` gated to active `jpr` diff windows, plus syntax/contrast chunks on unified removed virtual lines. | Full visual consistency across all diff views (stream, unified file, split file), negligible perf cost (one-time `< 1 ms` cache per colorscheme, zero scroll cost in stream, `~0.2-1 ms/redraw` strictly on visible diff lines in active `jpr` diff windows), preserves colorscheme feel, and solves both dim comments and green-on-green / red-on-red clashes. |
| **2. Stream-Only Swap (Rejected as sole solution)** | Apply contrast-adjusted groups only in `jpr.views.stream.syntax`. | Simplest code and zero redraw callbacks, but opening a file in unified overlay or split `:diffthis` drops back to lower-contrast foreground text. |
| **3. Flat RGB Brightness Multiplier or Per-Column `inspect_pos` (Rejected)** | Multiply RGB channels by a fixed factor (e.g. `1.2`) or inspect every screen column with `vim.inspect_pos`. | Flat RGB multiplication clips bright colors, shifts hue, and fails on dark comments and light themes; per-column `inspect_pos` causes visible scroll stutter. |

Pablo approved **Approach 1** for its combination of low runtime overhead and contrast-aware syntax legibility.

---

## Detailed Design

### 1. Pure OKLCH & Contrast Math (`lua/jpr/highlights/contrast.lua`)

All color conversions and contrast adjustments live in a pure Lua module with zero Neovim API calls:

- **sRGB <-> linear RGB:** Standard IEC 61966-2-1 gamma transfer (`0.04045` / `0.0031308` thresholds).
- **WCAG 2.1 luminance & contrast ratio:**
  - `M.relative_luminance(rgb)` = `0.2126 * r_lin + 0.7152 * g_lin + 0.0722 * b_lin`
  - `M.contrast_ratio(rgb_a, rgb_b)` = `(max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)`
- **linear RGB <-> OKLab <-> OKLCH:** Canonical Björn Ottosson matrices with signed cube root (`cbrt`).
- **Hue-locked sRGB gamut projection (`oklch_to_rgb_clamped(L, C, H)`):**
  - Convert `(L, C, H)` to linear RGB. If all channels lie in `[0, 1]`, encode to 24-bit sRGB directly.
  - Otherwise, binary-search chroma `c` in `[0, C]` (10 iterations) at fixed `(L, H)` to preserve the exact hue while keeping maximum in-gamut colorfulness.
- **Same-hue proximity (`hue_proximity(h1, h2)`):**
  - Circular angular difference `deg` in `[0, 180]`.
  - Smooth cosine falloff within `50` degrees: `deg >= 50 and 0 or 0.5 * (1 + math.cos(math.pi * deg / 50))`.
  - Applied only when both foreground and diff background are chromatic (`fg_C > 0.025` and `bg_C > 0.025`), so neutral greys are unaffected by background hue.
- **Foreground contrast adjustment (`M.adjust_fg_for_diff_bg(fg_rgb, normal_bg_rgb, diff_bg_rgb, is_dark)`):**
  - Convert `fg_rgb` -> `(fg_L, fg_C, fg_H)` and `diff_bg_rgb` -> `(bg_L, bg_C, bg_H)`.
  - Resolve `orig_bg_L` from `normal_bg_rgb` (or default `0.25` dark / `0.96` light when `Normal.bg` is nil).
  - Compute background lightness eaten by the diff tint:
    - Dark theme: `bg_shift = math.max(0, bg_L - orig_bg_L)`
    - Light theme: `bg_shift = math.max(0, orig_bg_L - bg_L)`
  - Compute smooth, headroom-bounded perceptual lightness shift:
    - `lift = bg_shift * 0.85 + 0.04 + 0.06 * same_hue`
    - `min_sep = 0.34 + 0.08 * same_hue`
    - Dark theme (`is_dark == true`):
      - `headroom = math.max(0, 0.95 - fg_L)`
      - `target_L = fg_L + headroom * (1 - math.exp(-lift / math.max(0.08, headroom)))`
      - `desired_L = math.min(0.96, math.max(target_L, math.min(0.94, bg_L + min_sep)))`
    - Light theme (`is_dark == false`):
      - `headroom = math.max(0, fg_L - 0.12)`
      - `target_L = fg_L - headroom * (1 - math.exp(-lift / math.max(0.08, headroom)))`
      - `desired_L = math.max(0.10, math.min(target_L, math.max(0.14, bg_L - min_sep)))`
  - Return `oklch_to_rgb_clamped(desired_L, fg_C, fg_H)`.
  - Why this beats raw WCAG ratio matching: `JprDiffAddText` on dark themes has a physical max contrast of ~`7.2:1` against pure white, so demanding a token's raw `Normal.bg` ratio (`~7-10:1`) would crush bright syntax colors to white (`C -> 0`). Headroom-bounded perceptual OKLab `L` shifting lifts dim comments and same-hue tokens substantially while preserving chroma and hue across every syntax role.

### 2. Derived Highlight Cache & ColorScheme Refresh (`lua/jpr/highlights/init.lua`)

Move `lua/jpr/highlights.lua` to `lua/jpr/highlights/init.lua` (preserving `require("jpr.highlights")` and all existing public functions) and add:

- **Injective derived group names (`M.build_contrast_group_name(source_group, kind)`):**
  - `kind` is `"add"` (prefix `"JprDiffAddFg_"`) or `"delete"` (prefix `"JprDiffDeleteFg_"`).
  - Non-alphanumeric characters in `source_group` are hex-encoded as `_%02x` so `@a.b` and `@a_b` never collide and every result is a valid Neovim highlight group name.
- **Lazy lookup & caching (`M.get_contrast_group(source_group, kind)`):**
  - Validate `source_group` (non-empty string) and `kind` (`"add"` or `"delete"`).
  - Return cached derived name immediately on cache hit.
  - Resolve `source_hl = vim.api.nvim_get_hl(0, { name = source_group, link = false })`.
  - If `type(source_hl.fg) ~= "number"` or `source_hl.reverse == true`:
    - Return `source_group` unchanged (do not invent a foreground for `bg`-only or reversed groups; cache `false` so repeated misses stay O(1) until the next `ColorScheme`).
  - Resolve `diff_group = kind == "add" and "JprDiffAdd" or "JprDiffDelete"`, read `diff_hl = vim.api.nvim_get_hl(0, { name = diff_group, link = false })`, and read `normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })`.
  - Determine `diff_bg` (active `diff_hl.bg`, falling back to `create_diff_highlights(normal_hl.bg, vim.o.background)[diff_group].bg`) and `is_dark = M.is_dark_background(diff_bg, vim.o.background)`.
  - Compute `adjusted_fg = contrast.adjust_fg_for_diff_bg(source_hl.fg, normal_hl.bg, diff_bg, is_dark)`.
  - Define the derived highlight group with `{ fg = adjusted_fg, ...preserved_style_attrs }` (`bg` explicitly omitted).
  - Store in `derived_groups[cache_key] = derived_name` and `registered_derived[derived_name] = { source = source_group, kind = kind }`.
- **Automatic refresh on `ColorScheme` / `define_highlights()`:**
  - After `apply_diff_highlights()`, clear the negative-lookup cache and iterate every entry in `registered_derived`, recomputing its highlight definition against the new colorscheme.
  - If a previously-derived `source` no longer has a numeric `fg` or is now `reverse = true`, link `derived_name` back to `source` (`{ link = source }`) so existing buffers never display stale colors from the previous colorscheme.

### 3. Diff Stream Integration (`lua/jpr/render/stream.lua`, `lua/jpr/views/stream/syntax.lua`)

- **`lua/jpr/render/stream.lua`:** Include `change = cell.change` (`"added"`, `"removed"`, or `"context"`) in `record_code_row` entries.
- **`lua/jpr/views/stream/syntax.lua`:**
  - Map row `change` to contrast kind: `"added" -> "add"`, `"removed" -> "delete"`, `"context" -> nil`.
  - Before painting Treesitter captures for a file group, for every row with a contrast kind, emit one `Normal` fallback extmark spanning `0 .. #entry.text + entry.gutter_length` (the full rendered line including gutter sign/numbers and plain code) at `priority = 85` using `highlights.get_contrast_group("Normal", kind)` when it differs from `"Normal"`.
  - When applying a Treesitter capture onto rows (`apply_capture_to_rows`), pick `hl_group = kind and highlights.get_contrast_group(highlight_group, kind) or highlight_group` at `priority = 90`.
  - Result:
    - Context lines use raw `@capture` groups (completely unchanged).
    - Added/removed lines layer `Normal` contrast fallback (`85`) < Treesitter contrast marks (`90`) < `JprDiffAdd`/`JprDiffDelete` line bg (`100`, bg-only) < `JprDiffAddText`/`JprDiffDeleteText` word bg (`110`, bg-only).
    - Existing buffers automatically pick up new colors on `:colorscheme` because `define_highlights()` updates the derived highlight groups in place.
  - Also export a small pure/reusable helper `M.collect_line_spans(lines, language)` (returning per-line `{ col_start, col_end, hl_group }` spans from `vim.treesitter.get_string_parser`) so unified overlay removed virtual lines can reuse the exact same Treesitter capture resolution without duplicating query logic.

### 4. File Diff Viewport Contrast Provider (`lua/jpr/views/diff/contrast.lua`, `lua/jpr/views/diff/init.lua`, `lua/jpr/render/overlay.lua`)

#### Viewport Decoration Provider (`lua/jpr/views/diff/contrast.lua`)

A single module manages one `nvim_set_decoration_provider` on namespace `"jpr-diff-contrast"`:

- **Window registration API (called by `jpr.views.diff`):**
  - `M.attach_unified(win, buf, added_lines)`: registers `win` as `{ mode = "unified", buf = buf }` and stores `buf -> { [row0] = "add", ... }`.
  - `M.attach_split(win)`: registers `win` as `{ mode = "split" }`.
  - `M.detach_window(win)`: removes `win` from `tracked_windows`.
  - `M.clear_buffer(buf)`: removes `buf` from `unified_lines_by_buf`.
  - Lazy provider installation: registers `nvim_set_decoration_provider` once on first attach.
- **Fast-path gating:**
  - `on_start`: prunes invalid windows lazily if needed; if `next(tracked_windows) == nil`, returns `false` immediately (zero work for the rest of Neovim).
  - `on_win(_, win, buf, topline, botline)`:
    - Look up `entry = tracked_windows[win]`; if not found (or `entry.mode == "unified"` and `entry.buf ~= buf`), return `false`.
    - Build `diff_kinds` (map of 0-based `row -> "add" | "delete"`) strictly for `row` in `[topline, botline]`:
      - Unified mode: intersect `[topline, botline]` with `unified_lines_by_buf[buf]`.
      - Split mode: inside `pcall(vim.api.nvim_win_call, win, ...)`, check `vim.fn.diff_hlID(row + 1, 1)` for `row = topline..botline` and map `DiffAdd`/`DiffChange`/`DiffText -> "add"`, `DiffDelete -> "delete"`.
    - If `next(diff_kinds) == nil`, return `false`.
    - For each visible diff row (skipping lines with byte length `> MAX_CONTRAST_LINE_BYTES = 1000`):
      1. **Normal fallback (`priority = 45`):** emit `ephemeral = true` extmark spanning `0 .. line_len` with `highlights.get_contrast_group("Normal", kind)` (sits above `Normal`, below legacy `:syntax` `50`).
      2. **Treesitter spans (`priority = 115`):** if `vim.treesitter.highlighter.active[buf]` exists, iterate `highlighter.tree:for_each_tree` and run `query:iter_captures(root, buf, topline, botline + 1)` (skipping ignored/internal captures), clamping each capture's rows to `diff_kinds` and emitting `ephemeral = true` extmarks with `highlights.get_contrast_group(capture_group, kind)`.
      3. **LSP semantic-token spans (`priority = 135`):** inspect extmarks in `[topline, botline]` across active `vim.lsp.semantic_tokens` namespaces (or namespaces whose marks carry `@lsp.` `hl_group`s, excluding our own namespace), and emit `ephemeral = true` extmarks with `highlights.get_contrast_group(mark.hl_group, kind)`.
    - Return `false` from `on_win` so Neovim skips per-line `on_line`/`on_range` callbacks while keeping all ephemeral extmarks set in `on_win`.

#### Unified Overlay Removed Virtual Lines (`lua/jpr/render/overlay.lua` & `lua/jpr/views/diff/init.lua`)

- **`lua/jpr/render/overlay.lua`:**
  - Extend `removed_line_to_chunks(removed, opts)` cleanly while preserving full backwards compatibility:
    - When `opts.fg_group` and `opts.syntax_spans` are absent (existing callers/tests), output is byte-for-byte identical to today (`"JprDiffDelete"` / `"JprDiffDeleteText"`).
    - When `opts.fg_group` and/or `opts.syntax_spans` (list of `{ col_start, col_end, hl_group }`) are provided, split the line at both word-diff and syntax boundaries and emit each chunk with `{ bg_group, fg_group }` (using `syntax_span.hl_group` when present, else `opts.fg_group`), keeping the right-edge padding chunk on `"JprDiffDelete"`.
- **`lua/jpr/views/diff/init.lua`:**
  - In `draw_overlay(buf, diff, win)`:
    - Compute `delete_normal_fg = highlights.get_contrast_group("Normal", "delete")` (nil if unchanged).
    - If a Treesitter language exists for the buffer's filetype (`vim.bo[buf].filetype`), collect per-line syntax spans for each removed block via `stream_syntax.collect_line_spans`, map each span's `hl_group` through `highlights.get_contrast_group(group, "delete")`, and pass them into `overlay.create_extmarks_from_diff`.
    - Register `(win, buf, added_lines)` with `diff_contrast.attach_unified(...)`.
  - In `open_base(session, win, buf, diff)`:
    - Register both `base_win` and `win` with `diff_contrast.attach_split(...)`.
  - In `clear(session, win)`:
    - Call `diff_contrast.detach_window(win)` (and `diff_contrast.detach_window(base_split.base_win)` when closing a split, and `diff_contrast.clear_buffer(applied.buf)` when no window shows that buffer anymore).

### 5. Testing Plan (Red/Green TDD)

1. **`tests/lua/highlights_contrast_spec.lua` (new):**
   - Pure OKLCH round-trip accuracy (`rgb -> oklch -> rgb` within `<= 1` channel step across dark, light, saturated, and neutral colors).
   - Contrast improvement invariants on dark (`onedark`) and light (`github-light`) palettes: adjusted colors strictly improve WCAG contrast against `JprDiffAdd` / `JprDiffDelete`, keep hue locked (OKLCH hue delta `< 2` degrees for in-gamut/clamped chromatic colors), apply extra lift for same-hue clashes (green on green, red on red), and lift dim comments above readability threshold while keeping them softer than `Normal`.
   - `highlights.get_contrast_group` caching, injective naming (`@a.b` vs `@a_b`), style preservation (`bold`, `italic`, `undercurl`, `bg == nil`), skipping `bg`-only and `reverse = true` groups, honoring user custom `JprDiffAdd`/`JprDiffDelete` overrides, and updating derived groups in place on `ColorScheme` (including reverting to link when a source group loses `fg`).
2. **`tests/lua/stream_syntax_spec.lua` (extended):**
   - Context rows keep raw `@keyword` / `@number` / `@string` groups.
   - Added and removed rows receive contrast-adjusted `JprDiffAddFg_*` / `JprDiffDeleteFg_*` groups at priority `90` plus `Normal` fallback at priority `85`, with strictly higher WCAG contrast against `JprDiffAdd` / `JprDiffDelete` than raw syntax groups.
   - `JprDiffAdd` (`100`) and `JprDiffAddText` (`110`) remain background-only.
3. **`tests/lua/overlay_render_spec.lua` (extended):**
   - Existing assertions remain untouched when `fg_group`/`syntax_spans` are omitted.
   - New assertions verify chunk splitting across overlapping word-diff + syntax spans and `{ bg_group, fg_group }` highlight arrays on removed virtual lines.
4. **`tests/lua/diff_contrast_spec.lua` (new):**
   - Headless Neovim verification of `jpr.views.diff.contrast`:
     - Non-tracked windows get zero ephemeral marks (`on_start`/`on_win` fast-path).
     - Unified file overlay emits priority `45` (`Normal` fallback), `115` (Treesitter), and `135` (LSP semantic token) contrast extmarks strictly on visible added lines, skipping lines `> 1000` bytes, and applies contrast-adjusted syntax chunks on removed virtual lines.
     - Split `:diffthis` emits contrast extmarks on visible changed lines in both `base_win` and `win` independently (even when the other window is focused), and stops cleanly after `diff_view.clear`.
5. **`just check`:** Full Rust + Lua verification suite remains green.

### 6. Documentation Updates

- **`docs/architecture.md`:** Update `jpr.highlights` (`init.lua` + `contrast.lua`), `jpr.views.stream` (`syntax.lua`), `jpr.render.overlay`, and `jpr.views.diff` (`contrast.lua`) rows.
- **`docs/decisions.md`:** Add a decision entry explaining why diff foreground legibility uses lazy OKLCH contrast-preserving derived highlight groups with a same-hue guard (direct swap in stream + viewport-scoped decoration provider in file diffs) rather than setting `fg` on `JprDiff*`, flat RGB brightening, or per-column `inspect_pos`.

## What Is Left to the Builder

- Exact helper function decomposition inside `lua/jpr/highlights/contrast.lua`, `lua/jpr/highlights/init.lua`, `lua/jpr/views/diff/contrast.lua`, and `lua/jpr/render/overlay.lua` to keep every function under 45 lines.
- Minor constant tuning if unit tests reveal edge cases on extreme colorschemes (e.g. pure black `#000000` or pure white `#ffffff` `Normal.bg`).
