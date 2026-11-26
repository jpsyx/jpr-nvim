# Filterable Command Palette Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make both the Neovim `:Jpr` Command Palette and the Rust CLI `jpr-review` Command Palette open ready to type and fuzzy-filter commands by label or `[id]`, with `Ctrl+j`/`Ctrl+k` list navigation and `Ctrl+u` full-line filter clearing.

**Architecture:** Both platforms share the same deterministic, dependency-free subsequence fuzzy scorer (matching `label` and `id`, prioritizing exact `id` match, prefixes, word boundaries, consecutive runs, and shorter spans). In Neovim, the palette becomes a stacked two-window floating modal (1-line editable prompt window on top opening in Insert mode + read-only scrollable results window below) while keeping `<Esc>` to drop to Normal mode before closing. In Rust `crates/cli-tui`, `PaletteState`, `KeyMode::Palette`, and `render_palette` gain live filter input editing and fuzzy command filtering.

**Tech Stack:** Lua 5.1 / Neovim floating-window API, Rust (edition 2024, `crossterm`), `just check` (`cargo fmt`, `cargo clippy -- -D warnings`, `cargo test`, `./scripts/test-lua.sh`).

**Spec:** `docs/superpowers/specs/2026-11-25-filterable-command-palette-design.md`

## Global Constraints

- Honor the dependency rule: `crates/cli-tui` has zero Neovim or Lua dependencies, no `unsafe`, and passes `cargo clippy --workspace --all-targets --all-features -- -D warnings` (pedantic + nursery).
- Keep `lua/jpr/tui/fuzzy.lua`, `lua/jpr/tui/schema.lua`, and `lua/jpr/tui/render.lua` pure (no window/buffer side effects).
- Keep functions short (`<= 45` lines), follow repo naming conventions (`create{Type}`, `build{Thing}`, `*From{Seed}`, `*to*`), and avoid em dashes in code/comments/docs.
- Use red/green TDD for every behavioral change and update `AGENTS.md`, `docs/architecture.md`, `docs/decisions.md`, and `lua/jpr/views/cheatsheet.lua` in the same branch.

## Review Focus

- **Whitespace-only query (`"   "`):** Treated as unfiltered, showing all executable commands in original schema order rather than `(no matching commands)`.
- **`<C-u>` after re-entering Insert mode:** Must clear the entire filter line, never stopping at the Insert-start column (which Vim's built-in Insert `<C-u>` does).
- **Multiline paste into Neovim prompt buffer:** Folded onto line 1 via `render.to_single_line` so the 1-line prompt buffer never grows extra lines or breaks filtering.
- **Zero matching commands (`"zzzz"`):** Displays `"  (no matching commands)"`, keeps `<C-j>`/`<C-k>`/`<CR>`/`<Tab>` as safe no-ops, and `<C-u>` immediately restores the full command list.
- **Small viewport height & dual-window cleanup:** Clamping keeps both stacked windows inside `vim.o.lines`, and closing either window (via `:q`, `WinClosed`, `BufWipeout`, or `wizard.close()`) closes both windows, exits Insert mode, and restores `origin_win`.

---

### Task 1: Pure Fuzzy Matcher in Lua

**Files:**
- Create: `lua/jpr/tui/fuzzy.lua`
- Test: `tests/lua/tui_fuzzy_spec.lua`

**Interfaces:**
- Consumes: none (pure Lua)
- Produces:
  - `fuzzy.score_match(query, candidate) -> integer|nil`: returns positive score when `query` matches `candidate` as a case-insensitive subsequence, or `nil` when it does not match.
  - `fuzzy.filter_commands(commands, query) -> table[]`: returns all `commands` in original order when `query` is nil/empty/whitespace-only; otherwise returns matching commands sorted by descending score (highest of `label` or `id`, with exact `id` match bonus), breaking ties by original index.

- [ ] **Step 1: Write the failing Lua fuzzy matcher spec (`tests/lua/tui_fuzzy_spec.lua`)**

Test cases:
- Empty, `nil`, or whitespace-only query returns all commands in original schema order.
- Subsequence matching works case-insensitively across `label` and `id` (e.g. `"sdiff"` matches `Switch Diff View [toggle]`, `"TOG"` matches `[toggle]`).
- Exact `id` match ranks above partial subsequence matches (e.g. `"open"` puts `Open Pull Request [open]` above `Open Stream View [stream]` and `Open PR Conversation [conversation]`).
- Prefix / word-boundary / consecutive-character matches outrank scattered subsequence matches.
- Ties preserve original schema order.
- Non-matching query returns `{}`.

- [ ] **Step 2: Run the spec to confirm it fails**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/tui_fuzzy_spec.lua`
Expected: FAIL (`module 'jpr.tui.fuzzy' not found`).

- [ ] **Step 3: Implement `lua/jpr/tui/fuzzy.lua`**

Implement `score_match(query, candidate)` and `filter_commands(commands, query)` with small pure helpers (`<= 45` lines each):
- Normalize `query` and `candidate` with `string.lower`.
- Find subsequence character positions; award bonuses for consecutive match (+15), match at index 1 (+20), match after word separator ` `, `-`, `_`, `/` (+12), and subtract a small gap penalty for skipped characters so tighter spans rank higher.
- In `score_command(command, normalized_query)`, compute `score_match` on `command.label` and `command.id`, add an exact-`id` bonus (+100) when `string.lower(command.id) == normalized_query`, and take the maximum.
- Sort matches by `score desc`, then `original_index asc`.

- [ ] **Step 4: Run the spec to confirm it passes**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/tui_fuzzy_spec.lua`
Expected: `tui_fuzzy_spec: ok`.

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/tui/fuzzy.lua tests/lua/tui_fuzzy_spec.lua
git commit -m "feat(tui): add pure Lua fuzzy matcher for command palette"
```

---

### Task 2: Stacked Two-Window Palette Layout & Renderer in Lua

**Files:**
- Modify: `lua/jpr/tui/render.lua`
- Modify: `lua/jpr/tui/wizard/window.lua`
- Test: `tests/lua/tui_render_spec.lua`

**Interfaces:**
- Consumes: `lua/jpr/tui/schema.lua`
- Produces:
  - `render.create_palette_layout_from_commands(commands, selected_index, max_width, context, opts)` where `opts = { is_filtered?: boolean }` emits `"  (no matching commands)"` when `#command_list == 0 and opts.is_filtered == true` (otherwise `"  (no commands available)"`), and uses filterable palette footers:
    - Default: `"[type] filter  [C-j/k] move  [C-u] clear  [Enter] select  [Esc] normal/close"`
    - With `on_back`: `"[type] filter  [C-j/k] move  [S-Tab] repos  [C-u] clear  [Enter] select  [Esc] normal/close"`
  - `window.create_palette_windows(title, layout, width) -> prompt_buf, prompt_win, results_buf, results_win`
  - `window.paint_palette_results(results_buf, results_win, prompt_win, layout, width)`
  - `window.paint_palette_prompt_decorations(prompt_buf, is_empty)` (renders `> ` prefix via `virt_text_pos = "inline"` and dim `"Type to filter commands..."` placeholder when `is_empty`).

- [ ] **Step 1: Add failing renderer tests to `tests/lua/tui_render_spec.lua`**

Assert:
- `create_palette_layout_from_commands({}, 1, 80, {}, { is_filtered = true })` renders `"(no matching commands)"` with `JprMuted`.
- `create_palette_layout_from_commands({}, 1, 80, {}, { is_filtered = false })` still renders `"(no commands available)"`.
- Footer includes `[type] filter`, `[C-j/k] move`, `[C-u] clear`, and `[S-Tab] repos` when `context.on_back` is a function.

- [ ] **Step 2: Run `tui_render_spec.lua` to confirm failure**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/tui_render_spec.lua`
Expected: FAIL on new assertions.

- [ ] **Step 3: Update `lua/jpr/tui/render.lua` and `lua/jpr/tui/wizard/window.lua`**

- Update `PALETTE_FOOTER`, `PALETTE_FOOTER_WITH_BACK`, and `create_palette_layout_from_commands` in `lua/jpr/tui/render.lua`.
- Add stacked geometry + prompt/results window creation and painting helpers in `lua/jpr/tui/wizard/window.lua`:
  - Combined stack centers vertically (`prompt_outer = 3`, `results_outer = results_height + 2`, clamped so `results_height >= 1` and both fit inside `vim.o.lines - 2`).
  - Prompt window gets `title`, rounded border, 1-line `nofile` buffer (`filetype = "jpr-tui-input"`, `modifiable = true`), `cursorline = false`, `wrap = false`.
  - Results window sits directly beneath (`row = prompt_row + 3`), rounded border, read-only `nofile` buffer (`filetype = "jpr-tui"`), `cursorline = true`, `wrap = false`.
  - Use separate extmark namespaces (`prompt_namespace` vs `namespace`) so prompt decorations never collide with results highlights.

- [ ] **Step 4: Run `tui_render_spec.lua` to confirm pass**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/tui_render_spec.lua`
Expected: `tui_render_spec: ok`.

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/tui/render.lua lua/jpr/tui/wizard/window.lua tests/lua/tui_render_spec.lua
git commit -m "feat(tui): add stacked palette windows and filterable layout renderer"
```

---

### Task 3: Interactive Filterable Palette Controller in Neovim

**Files:**
- Modify: `lua/jpr/tui/wizard/init.lua`
- Modify: `lua/jpr/tui/wizard/palette.lua`
- Modify: `tests/lua/support/helpers.lua`
- Modify: `tests/lua/tui_wizard_spec/palette.lua`
- Modify: `tests/lua/tui_wizard_spec/navigation_and_text.lua`
- Modify: `tests/lua/tui_wizard_spec/async_and_lifecycle.lua`
- Modify: `tests/lua/palette_and_open_picker_spec/palette.lua`
- Modify: `tests/lua/palette_and_open_picker_spec/filtering.lua`
- Modify: `tests/lua/palette_and_open_picker_spec/session_integration.lua`
- Modify: `tests/lua/repo_picker_spec.lua`
- Modify: `tests/lua/cheatsheet_spec.lua`

**Interfaces:**
- Consumes: `fuzzy.filter_commands`, `render.create_palette_layout_from_commands`, `window.create_palette_windows`, `window.paint_palette_results`, `window.paint_palette_prompt_decorations`.
- Produces: Updated `wizard.open_palette` / `palette.open_at` / `wizard.close` / `wizard.is_open` handling the stacked prompt+results modal cleanly.

- [ ] **Step 1: Add test helper and failing filterable palette tests**

In `tests/lua/support/helpers.lua`, add `helpers.palette_results_win()` and `helpers.palette_results_text()` (finding the open floating window with `filetype == "jpr-tui"`, falling back to `current_float_win()` for single-window wizard steps) so specs can read results cleanly.
In `tests/lua/tui_wizard_spec/palette.lua`, add failing tests for:
- Opening palette focuses the 1-line `jpr-tui-input` prompt window with a stacked read-only `jpr-tui` results window below.
- Typing in Insert mode filters commands fuzzily by label and `[id]`, resets selection to the top match, and updates hover-only helper text.
- `<C-j>` / `<Down>` and `<C-k>` / `<Up>` move and wrap through filtered matches in Insert mode.
- `<C-u>` clears the entire filter input in Insert mode (including after exiting and re-entering Insert mode) and restores all executable commands.
- `<Esc>` in Insert mode drops to Normal mode without closing; a second `<Esc>` or `q` in Normal mode closes both windows and restores `origin_win`.
- Non-matching query displays `(no matching commands)`, ignores `<C-j>`/`<C-k>`/`<CR>`, and recovers on `<C-u>`.
- Whitespace-only query shows all commands in original order.
- Pasting multiline text into the prompt buffer folds it to a single line.
- Closing either stacked window externally closes the sibling window cleanly.

- [ ] **Step 2: Run `tui_wizard_spec.lua` to confirm failure**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/tui_wizard_spec.lua`
Expected: FAIL on new stacked/filterable palette tests.

- [ ] **Step 3: Implement stacked lifecycle in `init.lua` and filterable palette in `palette.lua`**

- In `lua/jpr/tui/wizard/init.lua`:
  - Update `detach_current_window`, `handle_external_close`, `register_cleanup_guards`, and `M.is_open()` to handle optional `state.prompt_win` and `state.prompt_buf` alongside `state.win` and `state.buf`.
  - Stop Insert mode if either `previous_buf` or `previous_prompt_buf` is current.
- In `lua/jpr/tui/wizard/palette.lua`:
  - Store `all_commands`, `commands` (currently filtered list), `query`, `selected_index`, `prompt_buf`, `prompt_win`, `buf` (results), `win` (results).
  - Bind `TextChangedI` and `TextChanged` on `prompt_buf` to read/fold line 1, re-filter via `fuzzy.filter_commands(state.all_commands, query)`, reset `selected_index = 1` when `query` changed, and repaint results + prompt decorations.
  - Bind Insert-mode keys on `prompt_buf`: `<C-j>`/`<Down>` down, `<C-k>`/`<Up>` up, `<C-u>` clear entire line + re-filter, `<CR>`/`<Tab>` confirm, `<S-Tab>` back (when `on_back` is a function). Leave `<Esc>` unmapped in Insert mode so Neovim drops to Normal mode.
  - Bind Normal-mode keys on `prompt_buf`: `j`/`<Down>`/`<C-j>` down, `k`/`<Up>`/`<C-k>` up, `gg`/`<Home>` first, `G`/`<End>` last, `<CR>`/`l`/`<Right>`/`<Tab>` confirm, `h`/`<Left>`/`<S-Tab>` back (when `on_back` is a function), `<C-u>` clear line, `q`/`<Esc>` close.
  - Schedule `startinsert!` on open (mirroring `step_text.lua`).
  - When stepping into a command wizard, pass `palette_commands = state.all_commands` and `palette_index` resolved to that command's index in `state.all_commands` so stepping back restores the originating command in the full list.
- Update existing Lua specs (`palette_and_open_picker_spec/*`, `tui_wizard_spec/*`, `repo_picker_spec.lua`, `cheatsheet_spec.lua`) to read results via `helpers.palette_results_text()` / `helpers.palette_results_win()` where they previously assumed the prompt and results were the same window.

- [ ] **Step 4: Run all Lua specs to verify pass**

Run: `./scripts/test-lua.sh`
Expected: every `*_spec.lua` prints `: ok` and exits 0.

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/tui/wizard/init.lua lua/jpr/tui/wizard/palette.lua tests/lua/
git commit -m "feat(tui): make Neovim command palette live-filterable with stacked prompt"
```

---

### Task 4: Rust CLI Filterable Command Palette (`crates/cli-tui`)

**Files:**
- Create: `crates/cli-tui/src/state/fuzzy.rs`
- Modify: `crates/cli-tui/src/state/mod.rs`
- Modify: `crates/cli-tui/src/state/palette.rs`
- Modify: `crates/cli-tui/src/runner/keys.rs`
- Modify: `crates/cli-tui/src/runner/mod.rs`
- Modify: `crates/cli-tui/src/render/wizard.rs`
- Modify: `crates/cli-tui/src/render/mod.rs`
- Test: `crates/cli-tui/src/state/fuzzy.rs`, `crates/cli-tui/src/state/palette.rs`, `crates/cli-tui/src/runner/tests.rs`, `crates/cli-tui/src/render/tests.rs`

**Interfaces:**
- Consumes: `CommandSpec`
- Produces:
  - `state::fuzzy::filter_command_indices(commands: &[CommandSpec], query: &str) -> Vec<usize>`
  - `KeyAction::ClearLine`
  - `KeyMode { Menu, Text, Palette }` in `runner::keys::key_event_to_action(event, mode)`
  - `PaletteState` with `query() -> &str`, `cursor_char_index() -> usize`, `filtered_command_indices(&self, commands: &[CommandSpec]) -> Vec<usize>`, `clear_query(&mut self)`, and `handle_key(&mut self, action: KeyAction, commands: &[CommandSpec]) -> PaletteAction`
  - `render_palette` displaying `> <query>` (with placeholder `"Type to filter commands..."`), filtered rows or `"(no matching commands)"`, and footer `"[type] filter  [Ctrl+j/k] move  [Ctrl+u] clear  [Enter] select  [Esc] close"`.

- [ ] **Step 1: Write failing Rust tests across fuzzy, palette state, keys, and render**

Add unit tests covering:
- `fuzzy::filter_command_indices`: empty/whitespace query preserves order, case-insensitive subsequence on `label` and `id`, exact `id` bonus, boundary/consecutive ranking, tie-breaking by index, non-matching returns empty.
- `PaletteState`: typing filters commands and resets `selected_index` to 0; `Up`/`Down` wrap within filtered matches; `Confirm` returns the original command index in `commands`; `ClearLine` clears query and cursor and restores all commands; `Backspace`/`Delete`/`Left`/`Right`/`Home`/`End` edit the filter cleanly; empty match list ignores `Confirm`/`Up`/`Down` and cancels on `Cancel`.
- `key_event_to_action(..., KeyMode::Palette)`: `Ctrl+j` -> `Down`, `Ctrl+k` -> `Up`, `Ctrl+u` -> `ClearLine`, `Down`/`Up` -> `Down`/`Up`, `Enter`/`Tab` -> `Confirm`, `Esc`/`Ctrl+c` -> `Cancel`, printable `j`/`k`/`q` -> `Char('j')`/`Char('k')`/`Char('q')`, `Backspace`/`Delete`/`Left`/`Right`/`Home`/`End` -> text-editing actions.
- `render_palette`: renders `> (Type to filter commands...)` when empty (uncolored), `> diff` when filtered, only matching commands with hover-only help, `(no matching commands)` when query matches nothing, `(no commands available)` when `commands` is empty, and the updated footer.

- [ ] **Step 2: Run `cargo test -p cli-tui` to confirm failure**

Run: `cargo test -p cli-tui`
Expected: FAIL (missing `fuzzy`, `KeyAction::ClearLine`, `KeyMode::Palette`, updated signatures).

- [ ] **Step 3: Implement Rust `cli-tui` changes**

- Create `crates/cli-tui/src/state/fuzzy.rs` matching Task 1's exact scoring rules.
- Add `KeyAction::ClearLine` to `crates/cli-tui/src/state/mod.rs` and export `fuzzy` module.
- Update `crates/cli-tui/src/state/palette.rs` with `query`, `cursor_char_index`, `filtered_command_indices`, `clear_query`, and `handle_key(&mut self, action, commands)`.
- Update `crates/cli-tui/src/runner/keys.rs` to use `KeyMode { Menu, Text, Palette }` and wire `KeyMode::Palette` in `crates/cli-tui/src/runner/mod.rs` (clearing `palette_state.clear_query()` when returning from a wizard step back to the palette).
- Make `format_text_input` `pub(super)` in `crates/cli-tui/src/render/wizard.rs` and reuse it in `crates/cli-tui/src/render/mod.rs` for `render_palette`.

- [ ] **Step 4: Run Rust tests and clippy**

Run: `cargo test --workspace --all-features && cargo clippy --workspace --all-targets --all-features -- -D warnings`
Expected: PASS with zero warnings.

- [ ] **Step 5: Commit**

```bash
git add crates/cli-tui/
git commit -m "feat(cli-tui): add fuzzy type-to-filter command palette with Ctrl+j/k/u"
```

---

### Task 5: Cheatsheet & Documentation Updates

**Files:**
- Modify: `lua/jpr/views/cheatsheet.lua`
- Modify: `tests/lua/cheatsheet_spec.lua`
- Modify: `AGENTS.md`
- Modify: `docs/architecture.md`
- Modify: `docs/decisions.md`

**Interfaces:**
- Consumes: none
- Produces: Up-to-date cheatsheet entries and architecture/decision/agent documentation reflecting the filterable command palette.

- [ ] **Step 1: Add failing cheatsheet assertion in `tests/lua/cheatsheet_spec.lua`**

Assert that `cheatsheet.create_layout_from_config(jpr.config)` mentions `<C-j>`/`<C-k>` and `<C-u>` in the `Command Palette & Steppers` section.

- [ ] **Step 2: Run `cheatsheet_spec.lua` to confirm failure**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/cheatsheet_spec.lua`
Expected: FAIL on missing `<C-j>`/`<C-k>`/`<C-u>` entries.

- [ ] **Step 3: Update `lua/jpr/views/cheatsheet.lua`, `AGENTS.md`, `docs/architecture.md`, and `docs/decisions.md`**

- Update `Command Palette & Steppers` in `lua/jpr/views/cheatsheet.lua` to document typing to filter, `<C-j>/<C-k>` (and `<Down>/<Up>`), `<C-u>` clear filter, `<Esc>` Normal mode / close, alongside stepper controls.
- Update `AGENTS.md` under `Interactive Command Palette & Schema-to-TUI Invariant` to document Command Palette type-to-filter (`<C-j>`/`<C-k>`, `<C-u>`, `<Esc>` to Normal then `q`/`<Esc>`) separately from Normal-mode stepper menus/toggles.
- Update `docs/architecture.md` (both `cli-tui` and `jpr.tui.*` rows) and add a short decision entry in `docs/decisions.md` explaining the stacked two-window filterable palette and shared fuzzy scoring.

- [ ] **Step 4: Run full workspace verification (`just check`)**

Run: `just check`
Expected: `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test --workspace --all-features`, and `./scripts/test-lua.sh` all pass with exit code 0.

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/views/cheatsheet.lua tests/lua/cheatsheet_spec.lua AGENTS.md docs/architecture.md docs/decisions.md
git commit -m "docs: document filterable command palette controls and architecture"
```
