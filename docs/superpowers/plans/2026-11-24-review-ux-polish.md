# Review UX Polish & Loading Progress (0.5.2) Implementation Plan

> **For agentic workers:** Execute via Subagent-Driven Development with strict Red/Green TDD, Spec Compliance Review, and Code Quality Review per task.

**Goal:** Resolve all 8 review-session dogfooding bugs and UX gaps in `jpr-nvim` (`0.5.2`, `PROTOCOL_VERSION = 6`): immediate 4-stage PR loading tab with real-time checkout and per-file diff percentage progress, left-sidebar `o` keymap and reviewed-files progress bar, `:Jpr keys` + `?` shortcuts cheatsheet, fixed command palette hover highlight, and soft background-only diff tints preserving full language Treesitter syntax highlighting across both file overlays and stream view.

**Architecture & Invariants:**
- Preserve the binding dependency rule: `crates/review-*` crates remain strictly UI-free. `review-core` exposes `ReviewSession::stream_with_progress` taking a pure Rust callback `(completed, total, path)`, and `review-rpc` emits `streamProgress` JSON-RPC notifications directly over the writer during `stream` execution (`PROTOCOL_VERSION = 6`).
- Preserve the binding Interactive Command Palette & Schema-to-TUI Invariant: `:Jpr keys` is registered in `lua/jpr/commands/schema.lua` with a human-readable label (`Keyboard Shortcuts`), `[keys]` tag, 1-sentence helper text, and full non-interactive parity.
- Keep all functions `<= 45` lines, all files `<= 400` lines, and zero em dashes across all code, comments, tests, and docs.
- Lockstep version bump: `Cargo.toml` and `lua/jpr/init.lua` to `"0.5.2"`, `PROTOCOL_VERSION` to `6`.

---

## File Map

| Area | Files | Responsibility |
| --- | --- | --- |
| Task 1: Palette highlight, sidebar `o`, progress bar | `lua/jpr/tui/render.lua`, `lua/jpr/views/panel.lua`, `lua/jpr/render/panel.lua`, `tests/lua/tui_render_spec.lua`, `tests/lua/panel_render_spec.lua`, `tests/lua/panel_view_spec.lua` | Fix hovered command highlight in palette/steppers; bind `o` to open file/conversation in panel; render visual reviewed-files progress bar (`█`/`░` + `X/Y (Z%)`) before `Conversation` |
| Task 2: Soft diff tints & stream Treesitter syntax | `lua/jpr/highlights.lua`, `lua/jpr/init.lua`, `lua/jpr/render/stream.lua`, `lua/jpr/views/stream/syntax.lua`, `lua/jpr/views/stream/init.lua`, `lua/jpr/views/diff/init.lua`, `tests/lua/highlights_spec.lua`, `tests/lua/stream_render_spec.lua`, `tests/lua/stream_view_spec/` | Compute soft background-only diff tints blended from `Normal.bg` (no `fg`, refreshed on `ColorScheme`, mapped in split diff via `winhighlight`); apply per-file Treesitter highlights on stream code rows |
| Task 3: `:Jpr keys` & `?` shortcuts cheatsheet | `lua/jpr/views/cheatsheet.lua`, `lua/jpr/commands/schema.lua`, `lua/jpr/init.lua`, `lua/jpr/views/panel.lua`, `lua/jpr/views/stream/navigation.lua`, `lua/jpr/views/conversation.lua`, `tests/lua/cheatsheet_spec.lua`, `tests/lua/palette_and_open_picker_spec/`, `tests/lua/command_spec.lua` | Add declarative `keys` command + scrollable floating cheatsheet modal reflecting `jpr.config.keys`, plus `?` binding in read-only Jpr UI buffers |
| Task 4: Live 4-stage loading tab & `streamProgress` RPC | `Cargo.toml`, `crates/review-core/src/session/diffs.rs`, `crates/review-rpc/src/protocol.rs`, `crates/review-rpc/src/server.rs`, `lua/jpr/rpc.lua`, `lua/jpr/views/loading.lua`, `lua/jpr/session/open.lua`, `lua/jpr/session/init.lua`, `lua/jpr/session/events.lua`, `lua/jpr/views/stream/init.lua`, Rust + Lua tests | Bump `0.5.2` + `PROTOCOL_VERSION = 6`; emit `streamProgress` notifications per file; open PR tab immediately on `:Jpr open` with live 4-stage spinner, streamed checkout stderr, and file percentage progress bar |
| Task 5: Docs, Reviews & Walkthrough | `README.md`, `docs/protocol.md`, `docs/architecture.md`, `docs/decisions.md`, `docs/code-walkthroughs/2026-11-24_review-ux-polish.md` | Keep docs current, run `just check`, `/avandar-code-review`, full Initial-mode `/diff-review`, and commit archived walkthrough |

---

## Task 1: Palette Hover Highlight, Sidebar `o` Keymap, and Reviewed Progress Bar (#3, #5, #7, #8)

**Changes:**
1. **`lua/jpr/tui/render.lua`**:
   - In `append_palette_command`: when `is_selected` is true, highlight `prefix .. label` (`[0, #prefix + #label]`) with `"JprTitle"` (never `"JprMuted"`), regardless of `requires_session` / `has_session`. Only apply `"JprMuted"` to the label when `not is_selected and command.requires_session and not has_session`.
   - In `append_step_option`: when `is_selected` is true, also highlight `prefix .. label` with `"JprTitle"` so active menu selection is visually unmistakable across all colorschemes.
2. **`lua/jpr/views/panel.lua`**:
   - Bind `o` in Normal mode on the panel buffer to `M.open_file_under_cursor(session)` with description `"Open the conversation or file under the cursor"` (identical to `<CR>`, covering both files and `Conversation`).
3. **`lua/jpr/render/panel.lua`**:
   - Add pure helper `M.build_progress_bar_from_counts(viewed_count, total_count, bar_width)` (default `bar_width = 16`) returning `{ text, filled_bytes, unfilled_bytes, counter_start, is_complete }` producing e.g. `"██████░░░░░░░░░░  8/20 (40%)"` (clamping `viewed_count` into `[0, total_count]`, returning `0%` when `total_count == 0`).
   - In `M.build(view, now)`, insert the visual progress bar line right before the blank separator / `Conversation` row (or right below the sync line and above `Conversation`) with `JprViewed` on filled blocks, `JprMuted` on unfilled blocks, and `JprViewed` (when 100% and `total_count > 0`) or `JprTitle` on the `X/Y (Z%)` counter.
   - Keep `M.build_counts_text(view)` intact for unit consumers and render `M.build` cleanly (check `panel_render_spec.lua` and `panel_view_spec.lua`, updating line expectations and adding tests for 0%, partial, 100%, and `o` opening both files and Conversation).

**Verification:** `./scripts/test-lua.sh` (specifically `tui_render_spec.lua`, `panel_render_spec.lua`, `panel_view_spec.lua`).

---

## Task 2: Lighter Diff Background Tints & Per-File Stream Treesitter Syntax (#6)

**Changes:**
1. **`lua/jpr/highlights.lua`** (new module, called from `lua/jpr/init.lua`):
   - Export pure helpers `M.blend_rgb(base_rgb, tint_rgb, alpha)`, `M.is_dark_background(normal_bg, bg_option)`, and `M.create_diff_highlights(normal_bg, bg_option)`.
   - Compute soft **background-only** highlight specs (explicitly NO `fg`!) for `JprDiffAdd`, `JprDiffAddText`, `JprDiffDelete`, `JprDiffDeleteText` by blending onto `Normal.bg` (dark: `#3fb950` at 0.14/0.28 and `#f85149` at 0.14/0.28; light: `#2ea043` at 0.14/0.28 and `#cf222e` at 0.12/0.24; with safe fallbacks when `Normal.bg` is nil).
   - Link all remaining `Jpr*` semantic highlight groups via `default = true`.
   - Register a `ColorScheme` autocmd in augroup `jpr-highlights` so changing themes recalculates the blended diff backgrounds automatically.
2. **`lua/jpr/views/diff/init.lua`**:
   - In `open_base` (split diff mode), set window-local `winhighlight` mapping `DiffAdd:JprDiffAdd,DiffChange:JprDiffAdd,DiffDelete:JprDiffDelete,DiffText:JprDiffAddText` on both split diff windows so split diffs also preserve syntax foregrounds over the softer background tints.
3. **`lua/jpr/render/stream.lua` & `lua/jpr/views/stream/syntax.lua` & `lua/jpr/views/stream/init.lua`**:
   - In `lua/jpr/render/stream.lua`: record `column.code_rows` entries `{ line = row_0based, path = row.path, gutter_len = #gutter, text = cell.text }` on each unified/split code cell.
   - Create `lua/jpr/views/stream/syntax.lua`:
     - Pure capture-resolution helper `M.resolve_hl_group(capture_name, lang, exists_fn)` walking `@a.b.c.<lang>` -> `@a.b.c` -> `@a.b` -> `@a` so authentic Treesitter colors render on every colorscheme.
     - `M.apply(buf, column)` using dedicated namespace `jpr-stream-syntax`: groups `column.code_rows` by `path`, resolves filetype + Treesitter lang, runs `pcall(vim.treesitter.get_string_parser, source, lang)` + `vim.treesitter.query.get(lang, "highlights")`, maps capture line/column spans back to `(row.line, row.gutter_len + col)` with `priority = 90`, and skips gracefully when no parser is installed or file exceeds 5,000 lines.
   - In `lua/jpr/views/stream/init.lua`: set `priority = 100` on `line_hl_group` extmarks and `priority = 110` on word highlight extmarks (both background-only), and call `syntax.apply(buf, column)` inside `M.fill`.

**Verification:** New `tests/lua/highlights_spec.lua` + stream syntax tests in `tests/lua/stream_render_spec.lua` and `tests/lua/stream_view_spec/`, run via `./scripts/test-lua.sh`.

---

## Task 3: `:Jpr keys` & `?` Keyboard Shortcuts Cheatsheet (#4)

**Changes:**
1. **`lua/jpr/views/cheatsheet.lua`** (new module):
   - Export pure `M.create_layout_from_config(config)` producing `{ lines, highlights, width }` grouped into:
     - **PR Sidebar Panel** (`<CR>` / `o`, `v`, `?`)
     - **Diff & Stream Views** (dynamic keys from `config.keys`: `comment`, `suggest_comment`, `file_comment`, `thread_popup`, `next_thread`, `prev_thread`, plus stream `<CR>`, `v`, `]f`/`[f`, `]h`/`[h`, `?`)
     - **Threads, Compose & Submit** (popup, compose, and submit modal hotkeys)
     - **Command Palette & Steppers** (`:Jpr`, `:Jpr keys`, `j`/`k`, `l`/`<CR>`, `h`/`<S-Tab>`, `gg`/`G`, `q`/`<Esc>`)
   - Export `M.open()` / `M.close()` rendering a centered scrollable rounded floating window (`jpr-cheatsheet`), closable via `q`, `<Esc>`, or `?`.
2. **`lua/jpr/commands/schema.lua` & `lua/jpr/init.lua`**:
   - Register `keys` command (`label = "Keyboard Shortcuts"`, `help = "Show all keyboard shortcuts for navigating reviews, comments, panels, and menus."`, `requires_session = false`, `execute` opens cheatsheet).
   - Handle `:Jpr keys` in `lua/jpr/init.lua` (no session required, rejects extra arguments).
3. **Buffer-local `?` bindings**:
   - Bind `?` to `require("jpr.views.cheatsheet").open` in `lua/jpr/views/panel.lua`, `lua/jpr/views/stream/navigation.lua`, and `lua/jpr/views/conversation.lua` (read-only Jpr UI buffers only; do not override `?` in editable code files).

**Verification:** New `tests/lua/cheatsheet_spec.lua` + updated schema/command specs in `tests/lua/palette_and_open_picker_spec/` and `tests/lua/command_spec.lua`.

---

## Task 4: Live 4-Stage Loading Tab, `streamProgress` RPC, and Lockstep `0.5.2` Bump (#1, #2)

**Changes:**
1. **Rust Engine (`0.5.2`, `PROTOCOL_VERSION = 6`)**:
   - `Cargo.toml`: bump workspace version `"0.5.1"` -> `"0.5.2"`.
   - `crates/review-core/src/session/diffs.rs`: add `pub fn stream_with_progress<F>(&mut self, mode: ViewMode, mut on_progress: F) -> Result<StreamView> where F: FnMut(usize, usize, &str)` emitting `(0, total, "")` before reading files and `(index + 1, total, &path)` as each file is processed; keep `stream()` delegating to `stream_with_progress(mode, |_, _, _| {})`.
   - `crates/review-rpc/src/protocol.rs`: bump `PROTOCOL_VERSION = 6`.
   - `crates/review-rpc/src/server.rs`: in `answer_requests`, handle `"stream"` with `stream_with_progress`, writing `notification("streamProgress", json!({ "completed": completed, "total": total, "path": path }))` immediately via `write_line` as each file finishes. Add unit test verifying `streamProgress` notifications arrive before the `stream` response in order `0..=N`.
2. **Lua Loading View (`lua/jpr/views/loading.lua`)**:
   - Pure layout builder `M.create_layout_from_state(state)` rendering:
     - PR title/number header (`PR #N` or `#N <title>`)
     - 4-stage checklist (`✓` done, spinner frame active, `○` pending):
       1. `Checking out worktree` (with live streamed `stderr` detail line from `jpr-review checkout`)
       2. `Starting review engine`
       3. `Syncing with GitHub`
       4. `Computing diffs` (with visual percentage bar `████████░░░░░░░░  8/20 files (40%)` + current file path when `total > 0`)
     - Hint footer (`Press :Jpr close or close tab to cancel`).
   - Buffer/window lifecycle helpers: `M.open(session)`, `M.update(session, patch)`, `M.is_loading_buffer(session, buf)`, `M.close(session)` (always stopping and closing the `uv` spinner timer cleanly!).
3. **Session & Stream Wiring (`lua/jpr/rpc.lua`, `lua/jpr/init.lua`, `lua/jpr/session/open.lua`, `lua/jpr/session/init.lua`, `lua/jpr/session/events.lua`, `lua/jpr/views/stream/init.lua`)**:
   - Bump `lua/jpr/init.lua` `M.VERSION = "0.5.2"` and `lua/jpr/rpc.lua` `M.PROTOCOL_VERSION = 6`.
   - `lua/jpr/session/open.lua`: immediately open a new PR tab with `loading.open(pending_session)` (stage 1) when `:Jpr open` starts, track pending checkouts so duplicate `:Jpr open <n>` focuses the loading tab, stream `stderr` lines from `vim.system` into `loading.update`, pass the existing tab + loading session into `session_mod.start(info, existing_session)` on success, and close/clean up the loading tab + notify on error (or abort if user closed the tab mid-checkout).
   - `lua/jpr/session/init.lua`: reuse the already-open tab & loading buffer when passed from `open.lua` (preserving direct `M.start(info)` compatibility for existing callers/tests!), seed `session.view = { pr = { number = info.number, title = info.title } }` when `info.title` is present so the panel immediately shows the PR title, transition loading stages 1 -> 2 -> 3 -> 4, and ensure `forget(session)` always calls `loading.close(session)`.
   - `lua/jpr/session/events.lua`: handle `method == "streamProgress"` by updating `session.loading` progress (and echoing non-intrusive status if a later `:Jpr stream` / `:Jpr toggle` runs after the loading screen closed).
   - `lua/jpr/views/stream/init.lua`: treat `loading.is_loading_buffer(session, buf)` as free in `is_free`, transition to stage 4 when `stream.show` starts, and close the loading buffer in `M.draw` once rendered.

**Verification:** `cargo test --workspace --all-features`, `cargo clippy --workspace --all-targets --all-features -- -D warnings`, and `./scripts/test-lua.sh` (including new `tests/lua/loading_view_spec.lua` and updated `rpc_spec.lua`, `session_lifecycle_spec.lua`, `build_and_binary_spec.lua`).

---

## Task 5: Documentation, Reviews, Walkthrough & Readiness Gate

1. Update `docs/protocol.md` (Version 6 + `streamProgress` notification + `"0.5.2"`), `docs/architecture.md` (`PROTOCOL_VERSION = 6`, `lua/jpr/highlights.lua`, `lua/jpr/views/stream/syntax.lua`, `lua/jpr/views/cheatsheet.lua`, `lua/jpr/views/loading.lua`), `docs/decisions.md` (short ADR on soft background-only diff tints + stream Treesitter highlighting and live `streamProgress`), and `README.md` (`:Jpr keys`, `?`, panel `o`, progress bar).
2. Run full `just check` and verify zero em dashes across all modified/added files.
3. Run `/avandar-code-review`, fix any findings, re-run `just check`, and commit.
4. Run full Initial-mode `/diff-review`, copy `.difit/<stem>-walkthrough.md` to `docs/code-walkthroughs/2026-11-24_review-ux-polish.md`, commit, and re-verify `just check`.
5. Present final status checklist (`👍 Ready for full-branch review, awaiting approval`).
