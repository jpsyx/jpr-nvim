# Layout Manager, Termius 256-Color Diffs, and Mid-File Stream Syntax Design

**Date:** 2026-11-26
**Branch:** `feat/layout-termius-stream-syntax`
**Scope:** `jpr-nvim` Lua frontend (`lua/jpr/`)

## Intent & Why

Three daily-use friction points surfaced while reviewing pull requests in `jpr-nvim` (including on iPad over SSH via Termius):

1. **Broken sidebar and AI panel widths after closing/reopening windows:** Closing the main editor window lets the diff sidebar expand to full width; opening a file afterward splits the expanded sidebar 50/50 and locks it at half the screen (`winfixwidth`). There is also no shortcut to reopen the diff sidebar once closed.
2. **Missing green/red diff backgrounds on Termius (iPad):** Termius over SSH/tmux frequently runs Neovim without `termguicolors`. Because `JprDiffAdd*` / `JprDiffDelete*` only set 24-bit `bg` (no `ctermbg`) and contrast-adjusted foreground groups (`JprDiffAddFg_*` / `JprDiffDeleteFg_*`) only set 24-bit `fg` (no `ctermfg`), `+`/`-` lines lose both their diff backgrounds and their syntax foreground colors.
3. **Lost syntax highlighting on mid-file YAML hunks in `gF` (full stream):** Stream syntax highlighting concatenates only visible hunk rows and parses that fragment. When a mid-file YAML hunk starts indented and later dedents (or two hunks meet at different indents), `tree-sitter-yaml` emits an `ERROR` node and drops all captures for the remaining lines.

## Goals

- Automatically maintain review-tab window widths across all four topologies whenever windows open, close, or the terminal resizes:
  - Sidebar + Editor + AI -> sidebar at `panel_width`, AI at `agent_width`, editor fills middle.
  - Sidebar + AI (no Editor) -> sidebar at `panel_width`, AI takes remaining main width.
  - Editor + AI (no Sidebar) -> AI at `agent_width`, editor fills main width.
  - Sidebar + Editor (no AI) -> sidebar at `panel_width`, editor fills main width.
- Provide `:Jpr panel` (palette-registered), `<Plug>(jpr-toggle-panel)`, and default shortcut `gp` (`keys.toggle_panel`) to toggle/reopen the diff sidebar from any review buffer.
- Render green/red diff backgrounds and contrast-adjusted syntax foregrounds in both truecolor (`termguicolors`) and 256-color (`notermguicolors`) terminals such as Termius on iPad.
- Preserve accurate Treesitter syntax highlighting for mid-file hunks in `gF` (full stream), including indentation-sensitive languages like YAML, for both on-disk and removed/fallback lines.

## Non-Goals

- Changing Rust engine crates or JSON-RPC protocol (`review-*`, `jpr-review`).
- Modifying personal Neovim config in `jpsyx-configs` (regular YAML buffers already highlight properly).
- Fighting manual user window resizes while the tab's window topology has not changed.

## Approaches Considered

### 1. Window Layout & Sidebar Toggle
- **Chosen: Pure layout calculator + topology-driven autocmd reconciler (`lua/jpr/views/layout.lua`) + `:Jpr panel` (`gp`).** Reconciles widths automatically on `WinNew`, `WinClosed`, `BufWinEnter`, `VimResized`, and panel/agent open/close, keyed on topology + `vim.o.columns` so manual drags in between are preserved.
- *Rejected:* Manual "reset sidebar width" shortcut only. Requires repetitive manual fixing after every `:q` / file open.

### 2. Termius 256-Color Diff Highlights
- **Chosen: Curated chromatic xterm-256 `ctermbg` palettes for dark/light themes + `rgb_to_cterm256` for derived `ctermfg`.** Guarantees vivid dark green (`22`/`28`) and dark red (`52`/`88`) on dark themes and soft light green (`194`/`157`) and light red (`224`/`217`) on light themes, while keeping syntax foregrounds intact.
- *Rejected:* Naive nearest-color RGB-to-256 quantization for diff backgrounds. Subtle dark RGB tints (`#274932`, `#542b2d`) are closer in Euclidean RGB distance to xterm greyscale (`237`/`238`) than to chromatic green/red, which would still hide the green/red distinction.

### 3. Mid-File Stream Syntax Highlighting
- **Chosen: Full-file Treesitter parse from `session.worktree` indexed by `right_line` for added/context rows, plus hunk-separated dedent + per-line error recovery for removed/fallback rows.** Gives 100% accurate full-file syntax context (YAML, Python, JSON, multiline blocks) with zero RPC changes, while keeping removed lines and worktree-less tests highlighted.
- *Rejected:* Fetching base file text over JSON-RPC for every file in the stream. Adds protocol complexity and latency when disk files already cover added/context lines and dedent+recovery covers removed lines.

## Decisions

- Default sidebar toggle shortcut: `keys.toggle_panel = "gp"`, `<Plug>(jpr-toggle-panel)`, `:Jpr panel` (registered in `lua/jpr/commands/schema/init.lua` and `lua/jpr/views/cheatsheet.lua`).
- Keep `collapsed_dirs` across sidebar close/reopen within the same review session.
- Never close the last non-floating window in a tab via `:Jpr panel` / `gp`.
