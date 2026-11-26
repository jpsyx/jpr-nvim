# Design: Agent Terminal Integration, Auto-Submit Delivery, and Confirmed Review Shortcuts

## Intent and Why

Today, `jpr-nvim`'s coding-agent integration and review submission flow have four friction points:

1. **Clunky custom agent panel:** `lua/jpr/agent.lua` spawns a raw scratch buffer in a narrow 56-column right split via `vim.fn.jobstart(..., { term = true })`, never enters terminal insert mode, and never triggers lazy-loaded terminal plugins (such as `akinsho/toggleterm.nvim`). As a result, none of the user's `TermOpen` keymaps (`fk`, `<C-w>h/j/k/l`, `<C-q>`, `<M-q>`, `<leader>o` tab breakout) or `toggleterm` shading apply until `toggleterm` happens to load elsewhere.
2. **Failed auto-submit on send:** When `:Jpr send` launches a new Claude terminal, `agent.lua` writes bracketed paste `0 ms` after `jobstart` and `\r` `200 ms` later while Claude Code is still booting (~1-2 s). Both the pasted text and `\r` sit in the PTY input buffer together and get absorbed into startup paste ingestion, leaving the prompt sitting unsubmitted in the input box until the reviewer manually presses `<CR>`. Warm multi-line sends also lack readiness gating and Claude Vim-mode awareness.
3. **Missing keyboard shortcuts for bulk send, GitHub review submit, and panel toggle:** Neither `:Jpr send`, `:Jpr submit`, nor `:Jpr agent` has a default review-buffer shortcut, forcing the reviewer through the Command Palette to send local threads, submit a GitHub review, or hide/show Claude.
4. **No confirmation guard on bulk agent send or final GitHub submit:** Binding short `g*` chords (`gS`, `gs`) without confirmation dialogs risks accidental dispatches to Claude or accidental GitHub review publication.

This design resolves all four cleanly in the Lua frontend (with zero Rust protocol changes), plus includes the personal configuration update in `jpsyx-configs` to set `claude_cmd = "cl"` and catalog the new shortcuts.

## Goals

1. **Built-in `:terminal` with on-demand `toggleterm.nvim` integration (`C1`):** Spawn the coding agent via Neovim's built-in `:terminal` (`vim.fn.jobstart(argv, { term = true, ... })`) while lazy-loading `akinsho/toggleterm.nvim` on demand (if installed under `lazy.nvim` or `rtp`) before spawning so the user's `TermOpen` (`pattern = "*"`) keymaps (`fk`, `<C-w>h/j/k/l`, `<C-q>`, `<M-q>`, `<leader>o`) and `toggleterm.ui.hl_term()` shading attach automatically. Keeping the buffer off `filetype = "toggleterm"` / `toggle_number` avoids upstream `toggleterm.nvim`'s `ui.find_open_windows()` bug (which breaks `<leader>t` / `:ToggleTerm` whenever a `hidden = true` `Terminal:new` is visible), avoids `toggleterm`'s `BufEnter` insert-mode bounce on `gS`, and avoids Neovim's 4095-byte `termopen` buffer-name truncation on large CLI prompts.
2. **Wider, configurable layout (`A1`):** Default the agent terminal to a right vertical split (`agent_direction = "vertical"`) sized proportionally to ~40% of `&columns` (clamped sensibly, with explicit numeric `agent_width` override supported), while supporting `"vertical"`, `"horizontal"`, `"float"`, and `"tab"`.
3. **Hide panel without quitting Claude:** Set `bufhidden = "hide"` on the agent terminal buffer and handle `WinClosed` cleanly so `:q`, `<C-q>`, `<M-q>`, `<C-w>c`, `:Jpr agent`, and `ga` hide only the window while Claude keeps running in the background. Reopening reattaches the live terminal buffer and job; only `:Jpr close` or exiting the CLI itself stops the job.
4. **Configurable Claude/Codex command (`claude_cmd` / `codex_cmd`):** Keep `claude_cmd = "claude"` and `codex_cmd = "codex"` defaults, accepting executable names, command strings with flags (e.g. `"cl"` or `"cl --model opus"`), or string arrays.
5. **Reliable immediate auto-submit with Vim-mode safety (`B1`):**
   - **Cold start (fresh Claude launch from `send` / `prepass` / `conflict`):** Pass the initial prompt directly as a positional CLI argument (`<claude_cmd> --session-id <id> -- <prompt>`, or `--resume <id> -- <prompt>` when resuming an existing transcript) whenever the prompt fits safely within CLI size bounds (`<= 32768` bytes), eliminating startup PTY paste races completely.
   - **Warm start (already-running terminal, oversized prompt, or Codex):** Gate PTY delivery on terminal readiness (`\x1b[?2004h` observed on `on_stdout` or bounded fallback timeout), detect Claude Vim mode (`editorMode == "vim"` in `$CLAUDE_CONFIG_DIR/settings.json` or `~/.claude/settings.json`), safely exit `VISUAL` / `VISUAL LINE` mode with `\x1b` only if the terminal buffer shows a `-- VISUAL` indicator (never sending `\x1b` in `NORMAL` mode), deliver sanitized bracketed paste, wait for paste settlement, and send the submit key (`\r` for Claude, `\t` for Codex) in a distinct PTY write before calling `confirmSend`.
6. **Focus preservation on auto-send (`A3`):** Keep cursor focus in the reviewer's current review buffer (in Normal mode) when `gS` / `:Jpr send` / `:Jpr prepass` / conflict resolution opens or reveals the agent split, while scrolling the terminal to the bottom. Interactive open (`:Jpr agent` / `ga`) moves cursor focus into the agent terminal and enters terminal insert mode (`startinsert`).
7. **Review-wide shortcuts with mandatory confirmation dialogs (`A2`, `B2`):**
   - Bind `gS` (`<Plug>(jpr-send-agent)`), `gs` (`<Plug>(jpr-submit-review)`), and `ga` (`<Plug>(jpr-toggle-agent)`) across **all** review buffers (changed diff buffers, split base buffers, stream buffers, PR sidebar panel, and PR conversation), configurable and disableable via `setup({ keys = { ... } })`.
   - `gS` and `:Jpr send` run `prepareSend` first and open a centered confirmation modal stating the exact number of local review threads to send (`Send N local review thread(s) to <Agent>?`) before launching or writing to the agent.
   - `gs` and `:Jpr submit` open the `Submit Review` preview modal (showing `Pending Drafts (N)`), and triggering submission inside that modal opens a confirmation modal stating the exact review action and draft count (`Submit <Action> review with N draft comment(s) to GitHub?`) before calling `submitReview`.
8. **Personal `jpsyx-configs` update (`C2`):** At the end of this work, update the user's Neovim config in `jpsyx-configs` to set `claude_cmd = "cl"`, catalog `gS`, `gs`, and `ga` in `commands.yaml`, update its `docs/plugins.md` and `docs/CHANGELOG.md`, and run `jpsyx sync` + verification.

## Non-Goals

- Changing the Rust JSON-RPC protocol (`PROTOCOL_VERSION` stays `9`) or adding Rust-side terminal/plugin detection.
- Registering Jpr's agent inside `toggleterm.nvim`'s internal terminal registry (`Terminal:new`, `:TermSelect!`), which was explicitly rejected in `C1` due to upstream `ui.find_open_windows()` breaking `<leader>t` across tabs.
- Auto-committing, auto-pushing, or modifying GitHub state without explicit user action.
- Adding new `:Jpr` subcommands (the existing 16 subcommands in `lua/jpr/commands/schema.lua` remain unchanged).

## Anti-Goals

- Killing the running Claude process when the user closes the agent split with `:q`, `<C-q>`, `<M-q>`, `<C-w>c`, `ga`, or `:Jpr agent`.
- Breaking or interfering with `<leader>t` (`:ToggleTerm`) or `1ToggleTerm` shell terminals while Claude is open.
- Monkey-patching upstream `toggleterm.nvim` internals at runtime.
- Blindly sending `<Esc>` before pasting or submitting in Claude Vim mode (in Claude Code's `NORMAL` mode, `<Esc>` can clear or cancel input; `<Esc>` is only needed when exiting `VISUAL` / `VISUAL LINE` mode).
- Calling `confirmSend` if launching or writing to the agent terminal fails, or firing `submitReview` / `confirmSend` before the user confirms the dialog.
- Dropping cursor focus into Terminal-Normal mode when opening the agent interactively, or stealing cursor focus away from the diff (or flashing Insert mode) when pressing `gS`.
- Breaking the `crates/review-*` frontend-neutral dependency rule.

## Constraints

- **Dependency rule:** All changes for `jpr-nvim` live in Lua (`lua/jpr/`, `plugin/jpr.lua`), Lua specs (`tests/lua/`), and `docs/` / `README.md`. Zero Rust crate changes or protocol bumps are required.
- **Interactive Command Palette & Schema-to-TUI invariant:** All 16 `:Jpr` subcommands remain intact in `lua/jpr/commands/schema.lua`, and `:Jpr keys` (`lua/jpr/views/cheatsheet.lua`) dynamically reflects `keys.send_agent`, `keys.submit_review`, and `keys.toggle_agent` (including custom overrides and `false` disabled state).
- **Code style:** Zero em dashes anywhere in code, comments, tests, or docs; functions `<= 45` lines; split modules cleanly (`lua/jpr/agent/` submodules and `lua/jpr/views/confirm.lua`); Red/Green TDD; `just check` green.
- **Documentation currency:** Update `README.md`, `docs/architecture.md`, and `docs/decisions.md` in the same change.
- **Worktree & Git hygiene:** Implement `jpr-nvim` in worktree `feat/agent-terminal-and-shortcuts` (never committing directly to `main`). Apply the `jpsyx-configs` personal config update at the end (`C2`), following `jpsyx-configs` sync and verification rules.

## Approaches

Three architectural approaches were evaluated before writing this design, followed by a builder-check refinement on `toggleterm.nvim` integration (`C1`):

| Approach | Summary | Trade-offs |
| --- | --- | --- |
| **1. Hybrid CLI cold-start + readiness-gated PTY warm-start on built-in `:terminal` with on-demand `toggleterm.nvim` hooks (Chosen - B1, C1)** | Lazy-load `toggleterm.nvim` on demand (so `TermOpen` maps and `hl_term` shading attach) and spawn via Neovim's built-in `:terminal` (`jobstart(argv, { term = true })`, `bufhidden = "hide"`); pass prompt via `-- <prompt>` when cold-starting Claude from `send`/`prepass`/`conflict` (up to 32 KiB); gate warm PTY sends on `\x1b[?2004h` readiness + Vim-mode-safe `VISUAL` check + paste settle delay + separate `\r` write. | Eliminates cold-start boot races completely, keeps warm multi-round sends reliable under Claude Vim mode, keeps `<leader>t` / `:ToggleTerm` 100% isolated with zero monkey-patching, avoids Neovim's 4095-byte `termopen` buffer-name truncation, and needs no Rust protocol bump. |
| **2. Readiness-gated PTY paste for both cold and warm starts (Rejected)** | Same terminal backend, but always launch bare `cl --session-id <id>` without a CLI prompt argument and wait for `\x1b[?2004h` + settle delay before pasting on turn 1. | One uniform delivery path, but turn 1 still depends on terminal startup timing while Claude mounts its Ink input after enabling bracketed paste. |
| **3. Push CLI argv, Vim-mode detection, and terminal profile config into Rust RPC (Rejected)** | Parse `claude_cmd`, `~/.claude/settings.json`, and delivery bytes in Rust and bump `PROTOCOL_VERSION`. | Centralizes config logic in Rust, but crosses the frontend-neutral architecture boundary (Lua owns editor plugins, window management, and PTY quirks) and forces an unnecessary protocol bump and binary rebuild. |

Decisions `A1` (wider ~40% right vertical split), `A2` (`gs` and `gS` with confirmation dialogs stating exact send counts), `A3` (keep focus in review buffer on `gS`), `B1` (Approach 1), `B2` (bind `ga` to toggle agent panel across review buffers), `C1` (built-in `:terminal` + on-demand `toggleterm.nvim` loading for `TermOpen` maps & shading), and `C2` (apply `jpsyx-configs` update at the end of this work) are locked into the detailed design below.

---

## Detailed Design

### 1. Configuration & Keybindings (`lua/jpr/init.lua`, `plugin/jpr.lua`, `lua/jpr/views/cheatsheet.lua`)

#### Config Defaults (`lua/jpr/init.lua`)
Extend `M.defaults` cleanly without breaking existing user configs:

```lua
M.defaults = {
    -- ... existing options ...
    agent = "claude",
    -- Executable name, command string with flags, or argv list for Claude Code.
    claude_cmd = "claude",
    -- Executable name, command string with flags, or argv list for Codex.
    codex_cmd = "codex",
    -- Layout direction: "vertical" (right split), "horizontal" (bottom split),
    -- "float", or "tab".
    agent_direction = "vertical",
    -- Width in columns for vertical split; nil computes ~40% of editor columns
    -- (clamped to [60, columns - 20], falling back gracefully on very narrow screens).
    agent_width = nil,
    -- Whether to lazy-load toggleterm.nvim (if installed) before spawning the
    -- agent terminal so user TermOpen mappings and shading attach automatically.
    agent_load_toggleterm = true,
    keys = {
        palette = "<leader>J",
        comment = "gc",
        suggest_comment = "gC",
        file_comment = "gf",
        thread_popup = "gt",
        next_thread = "]t",
        prev_thread = "[t",
        send_agent = "gS",
        submit_review = "gs",
        toggle_agent = "ga",
    },
}
```

#### `<Plug>` Mappings & Buffer-Local Keybinding Scope
- Add three `<Plug>` mappings in `plugin/jpr.lua`:
  - `<Plug>(jpr-send-agent)` -> `require("jpr").action("send_agent")` -> `session.send_current()`
  - `<Plug>(jpr-submit-review)` -> `require("jpr").action("submit_review")` -> `session.submit_current()`
  - `<Plug>(jpr-toggle-agent)` -> `require("jpr").action("toggle_agent")` -> `session.agent_current()`
- Add `M.bind_session_keys(buf)` in `lua/jpr/init.lua` to bind `keys.send_agent` (`gS`), `keys.submit_review` (`gs`), and `keys.toggle_agent` (`ga`) in Normal mode (skipping any key set to `false` or empty string).
- Call `M.bind_session_keys(buf)` from:
  1. `M.bind_buffer_keys(buf)` (covers changed file diff buffers, split base buffers, and stream buffers).
  2. `lua/jpr/views/panel.lua` (`bind_action_keymaps` on the PR sidebar panel buffer).
  3. `lua/jpr/views/conversation.lua` (`bind_keys` on the PR conversation buffer).
- Update `lua/jpr/views/cheatsheet.lua`:
  - Add a **"Review Session & Agent"** section displaying `keys.send_agent` (`Send local threads to agent (confirms)`), `keys.submit_review` (`Submit GitHub review (confirms)`), `keys.toggle_agent` (`Toggle coding agent panel (hides without quitting)`), and `:q / <C-q> / <M-q>` (`Hide agent terminal window without quitting`).

---

### 2. Modular Agent Terminal Architecture (`lua/jpr/agent/`)

Refactor `lua/jpr/agent.lua` into focused submodules under `lua/jpr/agent/` while keeping `require("jpr.agent")` as the stable public entry point (preserving all existing exported helper signatures used by callers and tests):

| Module | Responsibility |
| --- | --- |
| `lua/jpr/agent/init.lua` | Public API (`ensure_open`, `toggle`, `send`, `prepass`, `resolve_conflicts`, `close`, `is_open`, `has_live_agent`, `deliver_dispatch`, re-exported pure helpers), launch coalescing, confirmation wiring for `send`, and two-phase `confirmSend`. |
| `lua/jpr/agent/command.lua` | Pure command parsing (`parse_command_argv`), Claude transcript lookup (`build_claude_project_slug_from_worktree`, `has_claude_transcript`), launch argv builders (with optional cold-start `-- <prompt>`), and Claude Vim-mode config reader (`is_claude_vim_mode_enabled`). |
| `lua/jpr/agent/terminal.lua` | On-demand `toggleterm.nvim` lazy-load + `hl_term` shading hook, built-in `:terminal` window creation (`vertical` / `horizontal` / `float` / `tab`), proportional ~40% vertical width sizing, `bufhidden = "hide"`, `jpr_side` marking, `<C-\>` buffer-local hide mapping (when `toggleterm`'s `open_mapping` is configured), `WinClosed` tracking, tab-breakout/multi-tab toggle handling, and focus/mode restoration. |
| `lua/jpr/agent/delivery.lua` | Readiness tracking (`\x1b[?2004h` detection on `on_stdout` + bounded timeout fallback), bracketed paste sanitization (`build_bracketed_paste_from_prompt`), Vim-mode `-- VISUAL` screen inspection, paste-settle timer, distinct submit-key write (`\r` / `\t`), and queued dispatch draining. |

#### Command Parsing & Cold-Start CLI Prompt (`lua/jpr/agent/command.lua`)
- `M.MAX_CLI_PROMPT_BYTES = 32768` (prompts larger than 32 KiB fall back to readiness-gated PTY paste to stay well under OS `ARG_MAX` limits).
- `M.parse_command_argv(command_spec, fallback)`:
  - If `type(command_spec) == "table"` and `#command_spec > 0`: copies non-empty string items.
  - If `type(command_spec) == "string"` and trimmed non-empty: splits shell-like tokens supporting single/double quotes (e.g. `"cl"` -> `{ "cl" }`, `"cl --model opus"` -> `{ "cl", "--model", "opus" }`).
  - Otherwise returns `{ fallback }`.
- `M.create_launch_argv_from_plan(config, worktree, launch_plan, home_directory, initial_prompt)`:
  - Builds `{ ...base_argv }` plus `--session-id <id>` or `--resume <id>` (for Claude when transcript exists) or `resume <id>` (for Codex).
  - **Cold-start prompt injection (Approach 1):** When `kind == "claude"`, `type(initial_prompt) == "string"`, `initial_prompt ~= ""`, and `#initial_prompt <= M.MAX_CLI_PROMPT_BYTES`: appends `"--"` and `initial_prompt` to argv.
    - Verified against Claude Code 2.1.326 and the user's `cl` wrapper (`cl` slices flags up to `--` and forwards `"$@"` intact to `command claude`).
    - Because `vim.fn.jobstart(argv, { term = true })` passes `argv` directly without shell-escaping or `;#toggleterm#<id>`, arbitrary multi-line prompts up to 32 KiB avoid both shell-quoting pitfalls and Neovim's 4095-byte `termopen` buffer-name truncation.
    - When `initial_prompt` is omitted, empty, oversized, or `kind == "codex"`, argv omits `-- <prompt>` and delivery uses the PTY path.
- `M.is_claude_vim_mode_enabled(home_directory, claude_config_dir)`:
  - Resolves settings path: `<claude_config_dir>/settings.json` if `claude_config_dir` (or `$CLAUDE_CONFIG_DIR`) is non-empty, else `<home>/.claude/settings.json`.
  - Reads and `pcall(vim.json.decode, raw)` safely; returns `type(decoded) == "table" and decoded.editorMode == "vim"`. Never errors on missing or malformed files.

#### Built-In `:terminal` & On-Demand `toggleterm.nvim` Integration (`lua/jpr/agent/terminal.lua`)
- **On-demand `toggleterm.nvim` hook (`ensure_toggleterm_hooks(config)`):**
  - When `config.agent_load_toggleterm ~= false`:
    1. If `package.loaded["toggleterm"] == nil`, check if `lazy.nvim` knows `"toggleterm.nvim"` (`pcall(require, "lazy.core.config")` -> `plugins["toggleterm.nvim"] ~= nil`); if so, call `pcall(require("lazy").load, { plugins = { "toggleterm.nvim" } })`.
    2. Because `toggleterm.nvim` (and the user's `terminal.lua` config) registers `TermOpen` with `pattern = "*"`, loading it before `jobstart(..., { term = true })` ensures all `TermOpen` mappings (`fk`, `<C-w>h/j/k/l`, `<C-q>`, `<M-q>`, `<leader>o` tab breakout) attach automatically to the agent buffer!
    3. After opening the terminal window, if `toggleterm.ui` and `toggleterm.config` are loaded and `shade_terminals` is enabled, apply `pcall(toggleterm_ui.hl_term, { window = win, id = "JprAgent" })` so the agent window inherits the user's terminal shading.
    4. If `toggleterm.config.get("open_mapping")` is configured (e.g. `<C-\>`), map that key buffer-locally in terminal and normal modes on the agent buffer to hide this session's agent panel (`require("jpr.agent").toggle(session)`) so `<C-\>` inside Claude hides Claude cleanly.
  - Because `filetype` is left as Neovim's standard terminal buffer (NOT `"toggleterm"`) and `vim.b[buf].toggle_number` is NOT set, `<leader>t` (`:ToggleTerm`) and `1ToggleTerm` remain 100% isolated from the Jpr Claude split, and `<leader>o` in the user's `terminal.lua` uses its built-in `vim.cmd("tab split")` path cleanly.
- **Width & geometry calculation (`resolve_vertical_width(config)`):**
  - If `type(config.agent_width) == "number"` and `config.agent_width > 0`: return clamped width `math.min(config.agent_width, math.max(20, vim.o.columns - 10))`.
  - Otherwise (`agent_width == nil`): compute `math.floor(vim.o.columns * 0.4)`, clamped to at least `60` (when `vim.o.columns >= 80`) and at most `math.max(20, vim.o.columns - 20)`.
- **Window layout & hide-without-quitting guarantees:**
  - Opens a window in `session.tab` matching `config.agent_direction or "vertical"`:
    - `"vertical"`: rightmost split (`split = "right"` beside rightmost non-side window, width = `resolve_vertical_width`, `winfixwidth = true`, `vim.w[win].jpr_side = true`).
    - `"horizontal"`: bottom split (`botright split`, height = `math.max(15, math.floor(vim.o.lines * 0.3))`, `winfixheight = true`, `vim.w[win].jpr_side = true`).
    - `"float"`: centered rounded floating window (~80% columns x ~75% lines, clamped to viewport).
    - `"tab"`: new tabpage (`tabnew`) displaying the terminal buffer.
  - Sets `vim.bo[buf].bufhidden = "hide"` on spawn and on every re-open so `:q`, `<C-q>`, `<M-q>`, and `<C-w>c` ONLY hide the window and NEVER stop the Claude process.
  - Registers a `WinClosed` autocmd for the active window that clears `agent_state.win = nil` (only when no other valid window displays `agent_state.buf`) without stopping the job or deleting the buffer.
  - Disables `number`, `relativenumber`, and `signcolumn` locally on the agent window.
- **Design calls for `float` on `gS` and `tab` / `<leader>o` breakout on `ga`:**
  - **Float + `gS` (`focus = false`, design call):** When `agent_direction == "float"` and a non-focusing dispatch (`gS`, `:Jpr send`, `:Jpr prepass`, conflict resolution) runs while the float is closed, launch/deliver to the terminal buffer in the background without popping a floating window on top of the diff (preserving `A3` focus and diff visibility), and notify via `jpr.info("sent to agent (press ga to open)")`. Opening interactively (`ga` / `:Jpr agent`) shows and focuses the float.
  - **Tab / `<leader>o` breakout + `ga` / `:Jpr agent` (design call):** Track any live window displaying `agent_state.buf` across tabpages (`vim.fn.win_findbuf(agent_state.buf)`):
    - When `ga` / `:Jpr agent` is invoked **from inside the agent's own tab** (where it is the only window in that tab, whether from `agent_direction = "tab"` or after `<leader>o` tab breakout): if `#vim.api.nvim_list_tabpages() > 1`, close that tab window (`nvim_win_close(win, true)`, hiding without quitting Claude because `bufhidden = "hide"`) and return focus to `session.tab`! Only error with `"cannot close the last window in the tab"` when it is the sole window in the sole remaining tabpage.
    - When `ga` / `:Jpr agent` is invoked **from `session.tab`** while the agent is already open in a different tabpage: switch focus to that agent tabpage and enter `startinsert` (instead of opening a duplicate split or failing).
    - When the agent is visible as a split in `session.tab`: close only that split window (keeping the job alive).
- **Focus & mode handling (`A3`):**
  - Interactive open (`:Jpr agent` / `ga`): focuses `agent_state.win`, scrolls to bottom, and schedules `vim.cmd("startinsert")` (guarded by checking `nvim_get_current_win() == agent_state.win`).
  - Non-focusing dispatch (`gS` / `:Jpr send` / `:Jpr prepass` / conflict resolution): captures `origin_win` before opening/re-showing a split, restores `vim.api.nvim_set_current_win(origin_win)` and `pcall(vim.cmd, "stopinsert")` immediately (with no `toggleterm` `BufEnter` race!), and scrolls the agent window to the bottom so the reviewer can watch Claude work side-by-side.

#### Readiness-Gated Warm PTY Delivery & Vim-Mode Safety (`lua/jpr/agent/delivery.lua`)
- **Readiness tracking on `agent_state`:**
  - `on_stdout` inspects incoming chunks for `"\27[?2004h"` (DECSET bracketed paste mode enabled by Ink/Claude/Codex when interactive input mounts).
  - Once seen, sets `agent_state.is_ready = true` and flushes any queued dispatches after a `150 ms` mount-settle delay.
  - Starts a fallback timer (`config.agent_ready_timeout_ms or 2500` ms) on spawn: if a CLI or test fixture never emits `\x1b[?2004h`, marks `agent_state.is_ready = true` once the timer fires and flushes queued dispatches.
- **Cold-start CLI delivery path (Approach 1):**
  - When `deliver_dispatch(session, dispatch)` is called and `not is_live_agent(session.agent)` and `command.can_use_cli_initial_prompt(kind, dispatch.prompt)`:
    1. Calls `ensure_open(session, callback, { agent_kind = kind, focus = false, initial_prompt = dispatch.prompt })`.
    2. `spawn` launches Claude with `-- <dispatch.prompt>` in argv.
    3. Because the prompt was delivered directly at process launch, `callback` skips PTY paste and immediately calls `confirmSend` once the process is confirmed spawned (`job > 0` and not exited).
- **Warm-start / fallback PTY delivery path:**
  - Waits until `agent_state.is_ready == true` (queuing if the user ran `:Jpr agent` moments before `gS`).
  - Checks `kind == "claude"` and `command.is_claude_vim_mode_enabled()`:
    - Inspects the bottom 6 non-empty lines of `agent_state.buf` for `-- VISUAL` (`-- VISUAL --` or `-- VISUAL LINE --`).
    - If `-- VISUAL` is detected, writes `"\27"` (`<Esc>`) first to exit Visual mode into Normal mode, waits `50 ms`, then proceeds with paste.
    - Never sends `"\27"` when in `INSERT` or `NORMAL` mode (verified in Claude Code 2.1.326: both `INSERT` and `NORMAL` accept bracketed paste and submit on `\r`, whereas `<Esc>` in `NORMAL` clears/cancels input).
  - Writes sanitized bracketed paste `"\27[200~" .. sanitized .. "\27[201~"` via `vim.fn.chansend`.
  - Computes settle delay: `config.agent_submit_delay_ms` when explicitly configured, else `math.max(profile.submitDelayMs or 200, kind == "claude" and 350 or 200)`.
  - After the settle delay, verifies `not session.closing and session.agent == agent_state and is_live_agent(agent_state)`, sends submit bytes (`\r` for Claude, `\t` for Codex) in a separate `chansend` call, and invokes `confirmSend`.

---

### 3. Confirmation Dialogs for `gS` and `gs` (`lua/jpr/views/confirm.lua`, `lua/jpr/agent/`, `lua/jpr/views/submit.lua`)

#### Shared Confirmation Modal (`lua/jpr/views/confirm.lua`)
Built on `lua/jpr/tui/wizard/window.lua` and `lua/jpr/tui/render.lua` (same visual language as `lua/jpr/auth/modal.lua`):

```text
╭──────────────────── Send to Coding Agent ────────────────────╮
│ Send 3 local review threads to Claude?                       │
│                                                              │
│   • src/auth.rs:L42                                          │
│   • src/session.rs:L108-115                                  │
│   • PR conversation                                          │
│                                                              │
│ ▸ Send 3 Threads to Claude  [send]                           │
│     Auto-submit these threads to the Claude terminal.        │
│   Cancel  [cancel]                                           │
│                                                              │
│ [j/k] move  [Enter/Click] select  [q/Esc] cancel             │
╰──────────────────────────────────────────────────────────────╯
```

- Pure `M.create_layout(spec, selected_index, max_width)` for direct unit testing.
- Keyboard controls: `j`/`<Down>`, `k`/`<Up>`, `gg`/`<Home>`, `G`/`<End>`, `<CR>`/`l`/`<Right>`/`<Tab>` confirm selected item, `q`/`<Esc>` cancel, plus `<LeftMouse>` click support.
- `WinClosed` guard invokes `on_cancel` exactly once if dismissed externally.

#### `gS` / `:Jpr send` Confirmation Flow
1. `agent.send(session, only_thread_id, opts)` calls `prepareSend` RPC (no state changes yet).
2. If `prepareSend` returns an error (e.g. no unsent local threads), report the error as today; no modal opens.
3. On `dispatch`, extract thread count (`#dispatch.threadIds`) and up to 5 compact item labels from `dispatch.prompt` (lines matching `^%d+%. %[[^%]]+%] (.+)$`, with `... and N more` when more than 5 exist).
4. Unless `opts and opts.skip_confirm == true`:
   - Open `confirm.open(...)` showing `"Send <N> local review thread(s) to <AgentName>?"`, the compact item preview, and `[send]` / `[cancel]` options.
   - If the user confirms (and session is not closing), call `M.deliver_dispatch(session, dispatch)`.
   - If the user cancels, do nothing (terminal is not opened, `confirmSend` is not called, threads remain `unsent`).
- **Design call:** Single-thread `s` inside the Thread Popup (`gt`) and PR Conversation (`:Jpr conversation`) also flows through `agent.send(session, thread_id)`, so it shows `"Send 1 local review thread to <AgentName>?"` for consistent protection everywhere.

#### `gs` / `:Jpr submit` Confirmation Flow (`lua/jpr/views/submit.lua`)
1. Pressing `gs` (or `:Jpr submit`) opens the `Submit Review` floating preview modal (`submitPreview`), displaying `Pending Drafts (N):`, draft locations, review action (`1/2/3`), and summary body. Nothing is sent by pressing `gs`.
2. When the reviewer triggers submission inside `Submit Review` (`<C-s>`, or `<CR>` on a non-draft row):
   - Run all existing validations first (`blockedReason`, own-PR restriction, empty zero-draft `COMMENT` check).
   - If valid, open `confirm.open(...)` titled `" Confirm GitHub Review Submission "` displaying the exact action, draft count, and whether a summary body is attached:
     - Examples:
       - `"Submit Comment review with 3 draft comments to GitHub?"`
       - `"Submit Approve review with 2 draft comments and a summary to GitHub?"`
       - `"Submit Approve review with 0 draft comments (summary only) to GitHub?"`
     - Options: `▸ Submit to GitHub  [submit]` and `  Cancel  [cancel]`.
   - On Cancel / `q` / `<Esc>`: closes only the confirmation dialog and restores focus to the `Submit Review` modal with selected event and summary body intact.
   - On Confirm: sets `state.in_flight = true`, sends `submitReview` RPC, closes the `Submit Review` modal on success (`jpr.info("review submitted")`), or keeps the `Submit Review` modal open with summary preserved on error for retry.
   - Closing `Submit Review` (`M.close` or `BufWipeout`) also closes any open confirmation dialog cleanly.

---

### 4. Personal `jpsyx-configs` Configuration Update (`C2`)

As the final phase of this work (after `jpr-nvim` tests and reviews pass):
1. Update `home/.config/nvim/lua/plugins/jpr.lua` to add `claude_cmd = "cl"` inside `opts`.
2. Update `home/.config/nvim/commands.yaml` to catalog the new `jpr-nvim` shortcuts (`gS` send local threads to agent, `gs` submit GitHub review, `ga` toggle coding agent panel) across review scopes.
3. Update `home/.config/nvim/docs/plugins.md` and `home/.config/nvim/docs/CHANGELOG.md` per the Neovim config documentation rules.
4. Run `jpsyx sync`, verify rendered `home-dist/`, `jpsyx status`, and `jpsyx doctor`, and apply the documented personal-config publication flow.

---

### 5. What Is Left to the Builder

- Exact helper decomposition and internal naming inside `lua/jpr/agent/{init,command,terminal,delivery}.lua` and `lua/jpr/views/confirm.lua`, keeping every function `<= 45` lines and avoiding em dashes.
- Exact headless test fixtures and mocks in `tests/lua/` covering on-demand `toggleterm.nvim` loading and shading, `bufhidden = "hide"`, `WinClosed` preservation, `<C-\>` hide override, `float` background delivery and `tab` / `<leader>o` breakout toggling, cold-start CLI `-- <prompt>`, warm-start `\x1b[?2004h` readiness, Vim-mode `VISUAL` `<Esc>` guard, focus restoration, and `confirm.lua` / `gS` / `gs` / `ga` across all review buffers.
- Updating `tests/lua/agent_spec.lua`, `tests/lua/submit_view_spec.lua`, `tests/lua/cheatsheet_spec.lua`, `tests/lua/panel_view_spec.lua`, and `tests/lua/conversation_view_spec.lua` alongside new dedicated specs.
- Updating `README.md`, `docs/architecture.md`, and `docs/decisions.md` to match the final implementation.
