# Filterable Command Palette Design

## Intent and Why

Both the Neovim `:Jpr` Command Palette and the Rust CLI `jpr-review` Command Palette currently open as static Normal-mode menus where users must step through commands with `j`/`k`. With up to 16 commands, scanning and arrowing down is slower than typing a few letters to jump straight to a command.

Making both palettes behave like a VS Code command palette lets users type immediately to fuzzy-filter commands by label or `[id]`, move through matches with `Ctrl+j` / `Ctrl+k` (or arrow keys), clear the filter with `Ctrl+u`, and confirm with `Enter`, while keeping Neovim Normal-mode navigation and close ergonomics available via `<Esc>`.

## Goals, Non-Goals, and Anti-Goals

- **Goals:**
  - Open both the Neovim `:Jpr` palette and the Rust CLI `jpr-review` palette ready to type and fuzzy-filter immediately.
  - Fuzzy-match against command `label` and `[id]` (VS Code style), ranking stronger matches first and preserving original schema order when the filter is empty.
  - Support `Ctrl+j` / `Down` (next match), `Ctrl+k` / `Up` (previous match), `Ctrl+u` (clear entire filter input), and `Enter` / `Tab` (select match) while typing.
  - In Neovim, `<Esc>` in Insert mode drops to Normal mode first, where `j`/`k`/`<C-j>`/`<C-k>`/`gg`/`G`/`<CR>`/`l`/`h`/`<C-u>` work and `<Esc>` or `q` closes the palette; `i`/`a`/`c` naturally resume Insert-mode filtering.
  - Preserve Neovim's executable-only command pre-filtering (`schema.get_active_commands`), hover-only dim helper text, and repo-picker back navigation (`<S-Tab>` in Insert/Normal, `h`/`<Left>` in Normal).
- **Non-Goals:**
  - Adding type-to-filter to wizard stepper menus (`select`, `toggle`, `async_select`) or changing `text` wizard steps.
  - Changing direct Ex commands (`:Jpr <subcommand>`), command aliases (`review`, `self`), or non-interactive CLI flags.
  - Introducing external fuzzy-finder plugins or Rust crates.
- **Anti-Goals:**
  - Clipping the command list on shorter viewports by rendering results as non-scrollable `virt_lines`.
  - Allowing Insert-mode edits or undo to corrupt command rows.
  - Relying on Vim's default Insert-mode `<C-u>` behavior, which stops at the point where Insert mode began instead of always clearing the entire filter line.

## Constraints

- Honor the binding dependency rule: `crates/cli-tui` remains pure Rust with zero Neovim/Lua dependencies, no `unsafe`, and clippy pedantic + nursery clean.
- Keep `lua/jpr/tui/schema.lua`, `lua/jpr/tui/render.lua`, and the new pure fuzzy matcher free of Neovim window/buffer side effects.
- Keep functions short (`<= 45` lines), follow repository naming conventions, and update `AGENTS.md`, `docs/architecture.md`, `docs/decisions.md`, and `lua/jpr/views/cheatsheet.lua` in the same change.

## Approaches Considered

### Neovim Floating Palette

1. **Stacked two-window floating modal: 1-line editable prompt on top + read-only scrollable results below (Selected):**
   - Top window is a 1-line editable `nofile` buffer (`filetype = "jpr-tui-input"`) that opens in Insert mode and drives live filtering on `TextChangedI` / `TextChanged`.
   - Bottom window is a read-only `nofile` buffer (`filetype = "jpr-tui"`) with `cursorline = true` that displays the filtered commands, selected row highlight, hover-only helper text, and footer hints.
   - **Why selected:** Results scroll cleanly on small viewports, `cursorline` works natively, Insert-mode edits can never corrupt command rows, and cleanup guards close both windows together cleanly.
2. **Single editable floating window with results as `virt_lines` below line 1 (Rejected):**
   - Simpler single-window lifecycle, but Neovim cannot scroll `virt_lines` or draw `cursorline` on them, so a 16-command list clips on shorter viewports.
3. **Single editable buffer with command rows rewritten on every keystroke (Rejected):**
   - Fragile cursor clamping, undo pollution, and risk of Insert-mode edits corrupting list lines.

### Rust CLI Palette (`crates/cli-tui`)

- Extend `PaletteState`, `KeyAction` / `keys.rs`, and `render_palette` directly with a pure fuzzy scorer and filter input line. This is the only approach that fits `cli-tui`'s existing pure state-machine and string-frame architecture.

## Design

### 1. Shared Fuzzy Matching Semantics (`lua/jpr/tui/fuzzy.lua` and `crates/cli-tui/src/state/fuzzy.rs`)

Both implementations share the same deterministic, dependency-free algorithm:

- Trim nothing from non-empty queries except treating an empty or whitespace-only query as "no filter", returning all commands in their original schema order.
- Match case-insensitively as a subsequence against `command.label` and `command.id`, taking the higher score between the two fields (with a small bonus for exact `id` match so typing `open` or `keys` always puts that command first).
- Score bonuses: consecutive matched characters, match at string start or word boundary (after space, `-`, `_`, `/`), and tighter match span (fewer skipped characters).
- Sort matches by descending score, breaking ties by original schema index so ordering is always deterministic.
- Whenever the filter query changes, reset the selected index to the first match (`1` in Lua, `0` in Rust).

### 2. Neovim Stacked Two-Window Palette

Text sketch of the stacked modal:

```text
╭────────────────── Jpr Commands ──────────────────╮
│ > diff                                           │
╰──────────────────────────────────────────────────╯
╭──────────────────────────────────────────────────╮
│ ▸ Switch Diff View  [toggle]                     │
│     Choose between unified inline diffs and...   │
│   Open Stream View  [stream]                     │
│                                                  │
│ [type] filter  [C-j/k] move  [C-u] clear  [CR] … │
╰──────────────────────────────────────────────────╯
```

- **Window geometry (`lua/jpr/tui/wizard/window.lua`):**
  - Add `create_palette_windows(title, layout, width)` and `paint_palette_results(buf, win, layout, width, prompt_win)` helpers.
  - Center the combined vertical stack (`prompt_outer_height = 3` + `results_outer_height`), clamping results height to the remaining viewport so both windows always stay on screen.
  - Prompt window: 1-line `nofile` buffer (`filetype = "jpr-tui-input"`, `modifiable = true`), rounded border, centered title (` Jpr Commands ` or `context.title`). Show `> ` as inline virtual text / sign prefix and a dim placeholder `"Type to filter commands..."` via `virt_text` when the line is empty.
  - Results window: read-only `nofile` buffer (`filetype = "jpr-tui"`), rounded border, `cursorline = true`, `wrap = false`, positioned immediately below the prompt window (`row = prompt_row + 3`).
- **Filtering & painting (`lua/jpr/tui/wizard/palette.lua`, `lua/jpr/tui/render.lua`):**
  - `palette.open_at` pre-filters `all_commands = schema.get_active_commands(commands, current_context)` once on open, initializes `query = ""` and `filtered_commands = all_commands`, opens the stacked windows, and enters Insert mode in the prompt window (`startinsert!`).
  - `TextChangedI` and `TextChanged` on the prompt buffer read line 1 (folding any pasted newlines into a single line), recompute `filtered_commands` via `fuzzy.filter_commands(state.all_commands, query)`, reset `selected_index = 1` when `query` changed, and repaint the results window (plus placeholder extmark).
  - `render.create_palette_layout_from_commands(commands, selected_index, max_width, context, opts)` accepts an optional `opts` table (`{ is_filtered = boolean }`): when `#commands == 0` and `opts.is_filtered` is true, render `"  (no matching commands)"` instead of `"  (no commands available)"`.
  - Footer text reflects the new controls:
    - Default: `"[type] filter  [C-j/k] move  [C-u] clear  [Enter] select  [Esc] normal/close"`
    - With `on_back`: `"[type] filter  [C-j/k] move  [S-Tab] repos  [C-u] clear  [Enter] select  [Esc] normal/close"`
- **Keybindings on the prompt buffer:**
  - **Insert mode:** `<C-j>` / `<Down>` move down; `<C-k>` / `<Up>` move up; `<C-u>` clear entire prompt line and re-filter; `<CR>` / `<Tab>` confirm selected match (no-op when 0 matches); `<S-Tab>` invoke `context.on_back` when present; `<Esc>` exits Insert mode to Normal mode (standard Neovim behavior).
  - **Normal mode:** `j` / `<Down>` / `<C-j>` move down; `k` / `<Up>` / `<C-k>` move up; `gg` / `<Home>` first match; `G` / `<End>` last match; `<CR>` / `l` / `<Right>` / `<Tab>` confirm; `h` / `<Left>` / `<S-Tab>` invoke `context.on_back` when present; `<C-u>` clear entire prompt line and re-filter; `q` / `<Esc>` close palette. Standard Insert-entry keys (`i`, `a`, `I`, `A`, `c`, `s`) remain unbound so users can seamlessly resume typing.
- **Lifecycle (`lua/jpr/tui/wizard/init.lua`):**
  - `state` stores `prompt_buf` / `prompt_win` alongside `buf` / `win` (results).
  - `detach_current_window`, `handle_external_close`, and `register_cleanup_guards` manage both windows/buffers so closing either window or calling `wizard.close()` cleanly closes both, exits Insert mode, and restores `origin_win`.
  - `M.is_open()` returns true when the active state's primary window (`prompt_win or win`) is valid.
  - Stepping back from a command wizard's first step (`step_back_from_step`) reopens the palette with an empty filter and the previously selected command focused.

### 3. Rust CLI `jpr-review` Palette (`crates/cli-tui`)

- **`KeyAction` and `keys.rs`:**
  - Add `KeyAction::ClearLine` to `crates/cli-tui/src/state/mod.rs`.
  - Replace `is_text_input: bool` in `key_event_to_action` with `KeyMode { Menu, Text, Palette }`.
  - In `KeyMode::Palette`:
    - `Ctrl+c` / `Esc` -> `KeyAction::Cancel`
    - `Ctrl+j` / `Down` -> `KeyAction::Down`
    - `Ctrl+k` / `Up` -> `KeyAction::Up`
    - `Ctrl+u` -> `KeyAction::ClearLine`
    - `Enter` / `Tab` -> `KeyAction::Confirm`
    - `Left`, `Right`, `Home`, `End`, `Backspace`, `Delete` -> corresponding text-editing actions
    - Printable `Char(c)` without Ctrl/Alt -> `KeyAction::Char(c)`
  - Keep `KeyMode::Text` unchanged so wizard text steps stay strictly within scope.
- **`PaletteState` (`crates/cli-tui/src/state/palette.rs`):**
  - Store `selected_index: usize`, `query: String`, and `cursor_char_index: usize`.
  - Expose `query()`, `cursor_char_index()`, `selected_index()`, `filtered_command_indices(commands) -> Vec<usize>`, and `handle_key(action, commands) -> PaletteAction`.
  - Editing `query` (`Char`, `Backspace`, `Delete`, `ClearLine`) updates the string/cursor and resets `selected_index = 0`.
  - `Up` / `Down` / `First` / `Last` wrap/clamp within `filtered_command_indices.len()`.
  - `Confirm` returns `PaletteAction::Selected(original_index)` when `filtered_command_indices` is non-empty, otherwise `PaletteAction::Continue`.
  - Returning from a wizard step back to the palette in `runner/mod.rs` resets the filter query (or preserves selected command) cleanly.
- **`render_palette` (`crates/cli-tui/src/render/mod.rs`):**
  - Render title, filter input line (`> <query>` with cursor block and `"Type to filter commands..."` placeholder, reusing `format_text_input` made `pub(super)`), blank line, filtered command rows (with hover-only dim helper text under the selected row), or `"  (no matching commands)"` when the query matches nothing, blank line, and footer `"[type] filter  [Ctrl+j/k] move  [Ctrl+u] clear  [Enter] select  [Esc] close"`.

### 4. Documentation & Cheatsheet

- Update `lua/jpr/views/cheatsheet.lua` (`Command Palette & Steppers` section) to document typing to filter, `<C-j>`/`<C-k>` movement, and `<C-u>` clearing the filter.
- Update `AGENTS.md`, `docs/architecture.md`, and `docs/decisions.md` to reflect the filterable command palette controls alongside Normal-mode menu/stepper controls.

## What Is Left to the Builder

- Exact helper decomposition inside `lua/jpr/tui/wizard/palette.lua`, `window.lua`, and `crates/cli-tui` to keep every function under 45 lines.
- Full red/green TDD test coverage in Lua (`tests/lua/`) and Rust (`crates/cli-tui`), plus running `just check`, `/avandar-code-review`, and `/diff-review`.
