# Agent Terminal Integration, Auto-Submit Delivery, and Confirmed Review Shortcuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `jpr-nvim`'s raw narrow agent split with a wider built-in `:terminal` enhanced by on-demand `toggleterm.nvim` hooks, fix cold/warm auto-submit (including Claude Vim-mode safety), add confirmed review-wide shortcuts (`gS`, `gs`, `ga`), and update `jpsyx-configs` to use `claude_cmd = "cl"`.

**Architecture:** Refactor `lua/jpr/agent.lua` into focused Lua submodules (`lua/jpr/agent/{init,command,terminal,delivery}.lua`) plus a shared floating confirmation modal (`lua/jpr/views/confirm.lua`). Lazy-load `toggleterm.nvim` on demand before spawning Neovim's built-in `:terminal` (`jobstart(argv, { term = true })`, `bufhidden = "hide"`) so user `TermOpen` keymaps and `hl_term` shading attach without touching `toggleterm`'s window registry. Cold-start Claude dispatches pass `-- <prompt>` via CLI argv (<= 32 KiB) while warm/Codex/oversized dispatches use `\x1b[?2004h` readiness gating and Vim-mode-safe bracketed paste + separate `\r`/`\t` submission; zero Rust or protocol changes are needed.

**Tech Stack:** Neovim 0.11+ Lua (`vim.api`, `vim.fn.jobstart`, `vim.fn.chansend`, `vim.uv`, `vim.json`), optional `akinsho/toggleterm.nvim` + `lazy.nvim` hooks, headless Neovim Lua specs (`./scripts/test-lua.sh`), `just check`, and `jpsyx` CLI (`jpsyx sync`, `jpsyx status`, `jpsyx doctor`).

**Spec:** `docs/superpowers/specs/2026-11-25-agent-terminal-and-review-shortcuts-design.md`

## Global Constraints

- Dependency rule: zero changes to `crates/review-*` or `PROTOCOL_VERSION` (remains `9`).
- Code style: zero em dashes (U+2014) anywhere in code, comments, tests, or docs; functions `<= 45` lines; Red/Green TDD by default.
- Interactive Command Palette invariant: all 16 `:Jpr` subcommands in `lua/jpr/commands/schema.lua` remain intact, and `:Jpr keys` (`lua/jpr/views/cheatsheet.lua`) dynamically reflects `keys.send_agent`, `keys.submit_review`, and `keys.toggle_agent`.
- Hide-without-quitting invariant: `bufhidden = "hide"` on the agent terminal buffer; closing the window (`:q`, `<C-q>`, `<M-q>`, `<C-w>c`, `<C-\>`, `ga`, `:Jpr agent`) never stops the running agent job; only `:Jpr close` or exiting the CLI stops it.
- Isolation invariant: never set `filetype = "toggleterm"` or `vim.b[buf].toggle_number`, and never monkey-patch `toggleterm.nvim` internals.
- Verification: focused Lua specs run via `nvim --headless -u NONE -i NONE -l <spec>`, full Lua suite via `./scripts/test-lua.sh`, full workspace verification via `just check`.

## Review Focus

- **Flag-bearing or blank `claude_cmd` / `codex_cmd` strings** (e.g. `"cl --model opus"`, quoted args, or `"   "`): `parse_command_argv` splits into clean argv tokens and falls back to `"claude"`/`"codex"` on blank input (pinned in Task 2).
- **Cold-start prompts starting with `-` or containing newlines/shell metacharacters (`$`, `` ` ``, `'`, `"`)**: passing `"--"` before the prompt directly via `jobstart(argv, { term = true })` delivers the literal text without flag confusion or shell expansion (pinned in Task 2 and Task 5).
- **Closing the agent via `:q` / `<C-w>c` or toggling `ga` after a `<leader>o` tab breakout**: `WinClosed` clears `agent_state.win` without killing the job, and `ga` inside a dedicated agent tab closes that tab and returns to `session.tab` instead of erroring (pinned in Task 3).
- **Claude Vim mode in `NORMAL` vs `VISUAL` state during warm send**: never send `\x1b` when `-- VISUAL` is absent (since `<Esc>` in Claude `NORMAL` mode can clear input); send `\x1b` + 50 ms settle only when `-- VISUAL` appears in the terminal's bottom status lines (pinned in Task 4).
- **Canceling or externally closing confirmation modals for `gS` and `gs`**: canceling `gS` leaves local threads `unsent` and never spawns an agent; closing `Submit Review` while its confirmation dialog is open closes both floats cleanly without firing `submitReview` (pinned in Task 5 and Task 6).

## File Structure

- Create `lua/jpr/views/confirm.lua`: reusable centered floating confirmation modal (keyboard + `<LeftMouse>` + `WinClosed` guard).
- Create `lua/jpr/agent/command.lua`: pure command argv parsing, Claude transcript lookup, cold-start `-- <prompt>` argv builder, and Claude Vim-mode settings detector.
- Create `lua/jpr/agent/terminal.lua`: on-demand `toggleterm.nvim` lazy-load + `hl_term` shading + `<C-\>` hide map, built-in `:terminal` split/float/tab layout, ~40% vertical sizing, `bufhidden = "hide"`, `WinClosed` tracking, tab-breakout toggle, and focus preservation.
- Create `lua/jpr/agent/delivery.lua`: `\x1b[?2004h` readiness tracking + fallback timer, bracketed paste sanitization, Vim-mode `-- VISUAL` screen check, settle delay, separate `\r`/`\t` submit write, and queue draining.
- Replace `lua/jpr/agent.lua` with `lua/jpr/agent/init.lua`: public `jpr.agent` facade, cold/warm dispatch selection, `prepareSend` confirmation wiring, and two-phase `confirmSend`.
- Modify `lua/jpr/init.lua`, `plugin/jpr.lua`, `lua/jpr/views/panel.lua`, `lua/jpr/views/conversation.lua`, `lua/jpr/views/submit.lua`, `lua/jpr/views/cheatsheet.lua`.
- Create `tests/lua/confirm_view_spec.lua`, `tests/lua/agent_command_spec.lua`, `tests/lua/agent_terminal_spec.lua`, `tests/lua/agent_delivery_spec.lua`, `tests/lua/session_shortcuts_spec.lua`.
- Modify `tests/lua/agent_spec.lua`, `tests/lua/submit_view_spec.lua`, `tests/lua/cheatsheet_spec.lua`, `tests/lua/panel_view_spec.lua`, `tests/lua/conversation_view_spec.lua`.
- Modify `README.md`, `docs/architecture.md`, `docs/decisions.md`.
- Modify `${JPSYX_CONFIGS_DIR:-$HOME/src/jpsyx/jpsyx-configs}/home/.config/nvim/{lua/plugins/jpr.lua,commands.yaml,docs/plugins.md,docs/CHANGELOG.md}`.

---

### Task 1: Shared Confirmation Modal (`lua/jpr/views/confirm.lua`)

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Create: `lua/jpr/views/confirm.lua`
- Test: `tests/lua/confirm_view_spec.lua`

**Interfaces:**
- Consumes: `jpr.tui.render.wrap_text`, `jpr.tui.wizard.window.{get_modal_width, create_menu_window, paint_menu_window, close_handle}`, `jpr.define_highlights`.
- Produces:
  - `confirm.create_layout(spec, selected_index, max_width) -> { lines: string[], highlights: table[], cursor_line: integer, item_for_line: table<integer, integer> }`
  - `confirm.open(spec) -> state` where `spec` accepts `{ title, headline, items?, confirm_label, confirm_badge?, confirm_help?, cancel_label?, cancel_help?, on_confirm, on_cancel? }`
  - `confirm.close(state) -> nil` (closes window/buffer without invoking `on_cancel`)
  - `confirm.is_open(state) -> boolean`

- [ ] **Step 1: Write the failing test in `tests/lua/confirm_view_spec.lua`**

Cover:
1. `create_layout` renders `headline`, optional bullet `items`, highlighted default option `1` (`confirm_label` + `confirm_badge` + hover `confirm_help`), unselected option `2` (`cancel_label`), and footer `[j/k] move  [Enter/Click] select  [q/Esc] cancel` with zero em dashes.
2. Moving selection to option `2` highlights `cancel_label`, shows `cancel_help`, and hides `confirm_help`.
3. `open()` opens a rounded floating modal; `<CR>` on default option `1` invokes `on_confirm` once and closes the modal without invoking `on_cancel`.
4. `j` then `<CR>` (and `q`, `<Esc>`, and external `nvim_win_close`) invokes `on_cancel` exactly once and never invokes `on_confirm`.
5. `confirm.close(state)` closes the modal cleanly without triggering `on_cancel`.

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/confirm_view_spec.lua`
Expected: FAIL with module `jpr.views.confirm` not found.

- [ ] **Step 3: Implement `lua/jpr/views/confirm.lua`**

Follow `lua/jpr/auth/modal.lua`'s layout and event structure (`JprTitle`, `JprMuted`, `item_for_line` hover sync on `CursorMoved`, `<LeftMouse>` activation via `vim.fn.getmousepos()`, `j`/`<Down>`, `k`/`<Up>`, `gg`/`<Home>`, `G`/`<End>`, `<CR>`/`l`/`<Right>`/`<Tab>`, `q`/`<Esc>`, and a single-fire `is_settled` guard on `WinClosed`). Keep every function `<= 45` lines.

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/confirm_view_spec.lua`
Expected: `confirm_view_spec: ok` (exit 0).

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/views/confirm.lua tests/lua/confirm_view_spec.lua
git commit -m "feat(ui): add reusable floating confirmation modal"
```

---

### Task 2: Agent Command Parsing, Cold-Start Argv, and Vim-Mode Detection (`lua/jpr/agent/command.lua`)

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Create: `lua/jpr/agent/command.lua`
- Test: `tests/lua/agent_command_spec.lua`

**Interfaces:**
- Consumes: `vim.uv`, `vim.json`, `vim.trim`.
- Produces:
  - `command.MAX_CLI_PROMPT_BYTES = 32768`
  - `command.parse_command_argv(command_spec, fallback) -> string[]`
  - `command.build_claude_project_slug_from_worktree(worktree) -> string`
  - `command.has_claude_transcript(worktree, session_id, home_directory?) -> boolean`
  - `command.can_use_cli_initial_prompt(kind, prompt) -> boolean`
  - `command.create_launch_argv_from_plan(config, worktree, launch_plan, home_directory?, initial_prompt?) -> string[]`
  - `command.is_claude_vim_mode_enabled(home_directory?, claude_config_dir?) -> boolean`
  - `command.extract_prompt_preview_items(prompt, max_items?) -> string[]`

- [ ] **Step 1: Write the failing test in `tests/lua/agent_command_spec.lua`**

Cover:
1. `parse_command_argv`: `"cl"` -> `{"cl"}`; `"cl --model opus"` -> `{"cl", "--model", "opus"}`; `"cl --tag 'a b' \"c d\""` -> `{"cl", "--tag", "a b", "c d"}`; `{"cl", "--fast"}` -> `{"cl", "--fast"}`; `""` / `"   "` / `nil` -> `{fallback}`.
2. `create_launch_argv_from_plan`:
   - Fresh Claude without prompt -> `{ "cl", "--session-id", id }`.
   - Fresh Claude with prompt (including prompt starting with `"- item\n$HOME 'q'"`) -> `{ "cl", "--session-id", id, "--", prompt }`.
   - Resumed Claude with existing transcript + prompt -> `{ "cl", "--resume", id, "--", prompt }`.
   - Claude with prompt > `32768` bytes -> omits `"--"` and prompt (`can_use_cli_initial_prompt` returns `false`).
   - Codex with prompt -> omits `"--"` and prompt (`can_use_cli_initial_prompt("codex", "hi") == false`).
   - Missing/empty/`vim.NIL` `sessionId` still omits `--session-id`/`--resume` while preserving `-- <prompt>` for Claude when `initial_prompt` is valid.
3. `is_claude_vim_mode_enabled`: returns `true` when `<home>/.claude/settings.json` has `{"editorMode":"vim"}`; prefers explicit `claude_config_dir` over `<home>/.claude`; returns `false` for `"emacs"`, missing file, or malformed JSON without throwing.
4. `extract_prompt_preview_items`: parses numbered `1. [loc-1] src/a.rs:L7` lines from send prompts and caps at `max_items` (default 5) appending `"... and N more"` when truncated.

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/agent_command_spec.lua`
Expected: FAIL with module `jpr.agent.command` not found.

- [ ] **Step 3: Implement `lua/jpr/agent/command.lua`**

Implement the pure helpers cleanly with functions `<= 45` lines and zero side effects.

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/agent_command_spec.lua`
Expected: `agent_command_spec: ok` (exit 0).

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/agent/command.lua tests/lua/agent_command_spec.lua
git commit -m "feat(agent): add command argv parsing, cold-start prompt args, and Vim-mode detection"
```

---

### Task 3: Built-In `:terminal` Lifecycle, On-Demand `toggleterm.nvim` Hooks, and Layout/Focus Handling (`lua/jpr/agent/terminal.lua`)

help-me-pick: implement L2 (hours=1.5 cause=known material=familiar stakes=low verified=yes)

**Files:**
- Create: `lua/jpr/agent/terminal.lua`
- Test: `tests/lua/agent_terminal_spec.lua`

**Interfaces:**
- Consumes: `jpr.views.main_window`, `jpr.tui.wizard.window`, optional `lazy` / `lazy.core.config` / `toggleterm.ui` / `toggleterm.config`.
- Produces:
  - `terminal.resolve_vertical_width(config, total_columns?) -> integer`
  - `terminal.ensure_toggleterm_hooks(config) -> boolean`
  - `terminal.find_agent_window(agent_state) -> integer|nil`
  - `terminal.is_open(session) -> boolean`
  - `terminal.has_live_agent(session) -> boolean`
  - `terminal.spawn(session, argv, env, opts) -> agent_state|nil` where `opts = { kind, focus, on_stdout, on_exit, on_toggle_hide }`
  - `terminal.show(session, agent_state, opts) -> integer|nil` where `opts = { focus, on_toggle_hide }`
  - `terminal.hide(session, agent_state) -> boolean`
  - `terminal.scroll_to_bottom(agent_state) -> nil`
  - `terminal.close(session, agent_state) -> nil`

- [ ] **Step 1: Write the failing test in `tests/lua/agent_terminal_spec.lua`**

Cover:
1. `resolve_vertical_width`: `agent_width = nil` on 160 cols -> `64` (40%); on 120 cols -> `60` (min clamp when >= 80); on 70 cols -> `50` (`columns - 20`); explicit `agent_width = 72` -> `72` (clamped on narrow screens).
2. `ensure_toggleterm_hooks`: when stubbed `lazy.core.config` lists `"toggleterm.nvim"`, calls `lazy.load({ plugins = { "toggleterm.nvim" } })` once; skipped when `agent_load_toggleterm = false`; applies `toggleterm.ui.hl_term` when `shade_terminals = true`; overrides buffer-local `open_mapping` (e.g. `<C-\>`) in `t` and `n` modes to invoke `on_toggle_hide`; leaves `filetype ~= "toggleterm"` and `vim.b[buf].toggle_number == nil`.
3. Hide without quitting: spawning a long-lived `/bin/sh` process sets `vim.bo[buf].bufhidden == "hide"` and `vim.w[win].jpr_side == true` (for splits); closing the window with `:q` / `nvim_win_close` clears `agent_state.win` via `WinClosed` while `has_live_agent(session)` stays `true` and `show()` reattaches the exact same `buf` and `job`.
4. Focus preservation (`A3`): `spawn` / `show` with `focus = false` keeps `nvim_get_current_win() == origin_win` and stays in Normal mode (`mode() == "n"`); `focus = true` moves to `agent_state.win`.
5. `float` background dispatch (`focus = false` when `agent_direction = "float"`): spawns the job into a hidden buffer without opening a floating window, and subsequent `show(..., { focus = true })` opens the centered rounded float on that same live buffer.
6. `tab` / `<leader>o` breakout toggling: when the agent buffer lives as the sole window in a second tabpage, `hide()` closes that tabpage and returns focus to `session.tab` while keeping the job alive; when called from `session.tab` while open in another tab, `show()` focuses that tabpage; only errors `"cannot close the last window in the tab"` when it is the sole window in the sole tabpage.

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/agent_terminal_spec.lua`
Expected: FAIL with module `jpr.agent.terminal` not found.

- [ ] **Step 3: Implement `lua/jpr/agent/terminal.lua`**

Implement built-in `:terminal` window creation (`vertical` / `horizontal` / `float` / `tab`), on-demand `toggleterm.nvim` loading and optional `hl_term` shading, `<C-\>` buffer-local hide mapping, `bufhidden = "hide"`, `WinClosed` cleanup, tab-aware `hide`/`show`, and focus/mode restoration. Keep functions `<= 45` lines.

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/agent_terminal_spec.lua`
Expected: `agent_terminal_spec: ok` (exit 0).

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/agent/terminal.lua tests/lua/agent_terminal_spec.lua
git commit -m "feat(agent): add builtin terminal manager with on-demand toggleterm hooks and hide-safe lifecycle"
```

---

### Task 4: Readiness-Gated Warm PTY Delivery and Vim-Mode-Safe Auto-Submit (`lua/jpr/agent/delivery.lua`)

help-me-pick: implement L2 (hours=1 cause=known material=familiar stakes=low verified=yes)

**Files:**
- Create: `lua/jpr/agent/delivery.lua`
- Test: `tests/lua/agent_delivery_spec.lua`

**Interfaces:**
- Consumes: `jpr.agent.command.is_claude_vim_mode_enabled`, `jpr.agent.terminal.{has_live_agent, scroll_to_bottom}`.
- Produces:
  - `delivery.build_bracketed_paste_from_prompt(prompt) -> string`
  - `delivery.profile_to_submit_bytes(profile) -> string`
  - `delivery.is_buffer_in_visual_mode(buf) -> boolean`
  - `delivery.resolve_submit_delay_ms(config, profile, kind) -> integer`
  - `delivery.on_stdout(agent_state, data) -> nil`
  - `delivery.start_ready_fallback_timer(session, agent_state, timeout_ms) -> nil`
  - `delivery.enqueue_pty_dispatch(session, agent_state, dispatch, on_submitted) -> nil`

- [ ] **Step 1: Write the failing test in `tests/lua/agent_delivery_spec.lua`**

Cover:
1. `build_bracketed_paste_from_prompt` strips raw `\27` bytes and wraps in `\27[200~...\27[201~`; `profile_to_submit_bytes` maps `"tab"` -> `"\t"` and `"enter"`/`nil` -> `"\r"`.
2. `is_buffer_in_visual_mode` detects `-- VISUAL --` and `-- VISUAL LINE --` in the bottom 6 non-empty buffer lines, and returns `false` for `-- INSERT --`, `-- NORMAL --`, or earlier scrollback lines more than 6 non-empty lines above the bottom.
3. Readiness gating: dispatching while `agent_state.is_ready == false` queues the dispatch without calling `chansend`; feeding `"\27[?2004h"` into `on_stdout` marks `is_ready = true` and flushes bracketed paste followed by separate `\r` write and `on_submitted(dispatch)` callback.
4. Fallback readiness timer: when `on_stdout` never emits `\27[?2004h`, `start_ready_fallback_timer` marks `is_ready = true` after `timeout_ms` and flushes queued dispatches.
5. Claude Vim-mode safety: stubbing `chansend` and `is_claude_vim_mode_enabled = true`:
   - When buffer ends with `-- NORMAL --`: writes ONLY bracketed paste then `\r` (NEVER writes `\27`).
   - When buffer ends with `-- VISUAL --`: writes `\27`, then after 50 ms writes bracketed paste, then after settle delay writes `\r`.
6. Exit/closing guard: if `agent_state.exited = true` during the settle delay before submit, `\r` is skipped and `on_submitted` is never called.

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/agent_delivery_spec.lua`
Expected: FAIL with module `jpr.agent.delivery` not found.

- [ ] **Step 3: Implement `lua/jpr/agent/delivery.lua`**

Implement readiness tracking (`\27[?2004h` + `150 ms` mount-settle, configurable `agent_ready_settle_ms` for fast deterministic tests), fallback readiness timer, Vim-mode `-- VISUAL` check, distinct `chansend` writes for paste and submit key, and `resolve_submit_delay_ms` (`config.agent_submit_delay_ms` override, else `math.max(profile.submitDelayMs or 200, kind == "claude" and 350 or 200)`). Keep functions `<= 45` lines.

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/agent_delivery_spec.lua`
Expected: `agent_delivery_spec: ok` (exit 0).

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/agent/delivery.lua tests/lua/agent_delivery_spec.lua
git commit -m "feat(agent): add readiness-gated PTY delivery with Claude Vim-mode safety"
```

---

### Task 5: Assemble `lua/jpr/agent/init.lua` with Cold/Warm Dispatch and `gS` Confirmation

help-me-pick: implement L2 (hours=1.5 cause=known material=familiar stakes=low verified=yes)

**Files:**
- Delete: `lua/jpr/agent.lua`
- Create: `lua/jpr/agent/init.lua`
- Modify: `tests/lua/agent_spec.lua`

**Interfaces:**
- Consumes: `jpr.agent.{command, terminal, delivery}`, `jpr.views.confirm`, `jpr.binary`, `jpr.session`.
- Produces (preserving all existing `require("jpr.agent")` exports):
  - `agent.build_claude_project_slug_from_worktree`, `agent.has_claude_transcript`, `agent.create_launch_argv_from_plan`, `agent.build_bracketed_paste_from_prompt`, `agent.profile_to_submit_bytes`, `agent.is_claude_vim_mode_enabled`, `agent.parse_command_argv`
  - `agent.is_open(session)`, `agent.has_live_agent(session)`
  - `agent.ensure_open(session, on_ready?, opts_or_kind?)`
  - `agent.toggle(session, agent_kind?)`
  - `agent.deliver_dispatch(session, dispatch)`
  - `agent.send(session, only_thread_id?, opts?)` (opens confirmation modal showing thread count unless `opts.skip_confirm == true`)
  - `agent.prepass(session)`, `agent.resolve_conflicts(session, paths)`, `agent.close(session)`

- [ ] **Step 1: Update `tests/lua/agent_spec.lua` with failing tests for new behaviors**

Keep and adapt existing end-to-end coverage, and add tests for:
1. Cold-start `:Jpr send` opens the confirmation modal (`Send 1 local review thread to Claude?`); canceling with `q` leaves `review.agent == nil` and sends zero `confirmSend` RPCs.
2. Confirming `:Jpr send` on cold start launches Claude with `-- <prompt>` in argv (verified in `metadata_log` including leading `-` / multi-line safety), confirms `confirmSend` without PTY paste race, opens the right split without stealing focus from the review buffer (`A3`), and sets `bufhidden = "hide"`.
3. Second `:Jpr send` on the already-running warm agent opens confirmation, confirms, delivers via readiness-gated PTY bracketed paste + separate `\r`, and keeps cursor focus in the review buffer.
4. Closing the agent split via `:q` hides only the window while `has_live_agent(review)` remains `true`, and `toggle(review)` reopens the exact same buffer and job without spawning a second process.
5. `agent.close(review)` closes any open send confirmation modal as well as stopping the job and wiping the buffer.

- [ ] **Step 2: Run `tests/lua/agent_spec.lua` to verify the new tests fail**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/agent_spec.lua`
Expected: FAIL against old `lua/jpr/agent.lua`.

- [ ] **Step 3: Replace `lua/jpr/agent.lua` with `lua/jpr/agent/init.lua`**

Wire `command`, `terminal`, `delivery`, and `views.confirm`:
- Cold-start `deliver_dispatch`: when `not has_live_agent(session)` and `command.can_use_cli_initial_prompt(kind, dispatch.prompt)`, spawn via `ensure_open(session, cb, { agent_kind = kind, focus = false, initial_prompt = dispatch.prompt })` and call `confirmSend` once the job is verified alive.
- Warm/Codex/oversized `deliver_dispatch`: `ensure_open(session, cb, { agent_kind = kind, focus = false })` and deliver via `delivery.enqueue_pty_dispatch(...)` -> `confirmSend`.
- `send(session, only_thread_id, opts)`: runs `prepareSend`; unless `opts and opts.skip_confirm`, opens `confirm.open(...)` with thread count + preview items (`extract_prompt_preview_items`) stored on `session.agent_confirm` (cleaned up on `agent.close`), delivering only on confirm.
- Remove old `lua/jpr/agent.lua` so `require("jpr.agent")` resolves cleanly to `lua/jpr/agent/init.lua`.

- [ ] **Step 4: Run agent tests and full Lua suite**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/agent_spec.lua && ./scripts/test-lua.sh`
Expected: all Lua specs pass (exit 0).

- [ ] **Step 5: Commit**

```bash
git rm lua/jpr/agent.lua
git add lua/jpr/agent/init.lua tests/lua/agent_spec.lua
git commit -m "feat(agent): wire cold/warm auto-submit delivery and confirmed send flow"
```

---

### Task 6: Review-Wide Shortcuts (`gS`, `gs`, `ga`), Confirmed GitHub Submit, and Cheatsheet

help-me-pick: implement L2 (hours=1.5 cause=known material=familiar stakes=low verified=yes)

**Files:**
- Modify: `lua/jpr/init.lua`
- Modify: `plugin/jpr.lua`
- Modify: `lua/jpr/views/panel.lua`
- Modify: `lua/jpr/views/conversation.lua`
- Modify: `lua/jpr/views/submit.lua`
- Modify: `lua/jpr/views/cheatsheet.lua`
- Create: `tests/lua/session_shortcuts_spec.lua`
- Modify: `tests/lua/submit_view_spec.lua`
- Modify: `tests/lua/cheatsheet_spec.lua`
- Modify: `tests/lua/panel_view_spec.lua`
- Modify: `tests/lua/conversation_view_spec.lua`

**Interfaces:**
- Consumes: `jpr.views.confirm`, `jpr.session.{send_current, submit_current, agent_current}`.
- Produces:
  - Config defaults: `agent_direction = "vertical"`, `agent_width = nil`, `agent_load_toggleterm = true`, `keys.send_agent = "gS"`, `keys.submit_review = "gs"`, `keys.toggle_agent = "ga"`.
  - `<Plug>` mappings: `<Plug>(jpr-send-agent)`, `<Plug>(jpr-submit-review)`, `<Plug>(jpr-toggle-agent)`.
  - `jpr.bind_session_keys(buf) -> nil` (bound across diff, base split, stream, panel, and conversation buffers).
  - `jpr.action("send_agent" | "submit_review" | "toggle_agent")`.

- [ ] **Step 1: Write failing tests in `tests/lua/session_shortcuts_spec.lua`, `tests/lua/submit_view_spec.lua`, and `tests/lua/cheatsheet_spec.lua`**

Cover:
1. `session_shortcuts_spec.lua`:
   - `gS`, `gs`, and `ga` are bound in Normal mode on diff buffers, split base buffers, stream buffers, PR sidebar panel buffer, and PR conversation buffer, mapping to `<Plug>(jpr-send-agent)`, `<Plug>(jpr-submit-review)`, and `<Plug>(jpr-toggle-agent)`.
   - Setting `keys = { send_agent = false, submit_review = "gR", toggle_agent = false }` disables `gS`/`ga` and remaps `gs` -> `gR` across all 5 buffer types while keeping `<Plug>` mappings intact.
   - Pressing `gS`, `gs`, and `ga` dispatches to `send_current`, `submit_current`, and `agent_current` respectively.
2. `submit_view_spec.lua`:
   - Pressing `<C-s>` (or non-draft `<CR>`) on a valid `Submit Review` modal opens `"Confirm GitHub Review Submission"` displaying the exact action and draft count (e.g. `"Submit Approve review with 1 draft comment and a summary to GitHub?"`) without calling `submitReview` yet.
   - Canceling the confirmation with `q` or `<Esc>` returns focus to `Submit Review` with the chosen event and summary preserved and sends zero `submitReview` RPCs.
   - Confirming with `<CR>` fires `submitReview` once; on error keeps `Submit Review` open with summary preserved; closing `Submit Review` (`M.close` or `BufWipeout`) while confirmation is open closes both modals cleanly.
   - Blocked or empty-comment validation errors still reject immediately without opening the confirmation modal.
3. `cheatsheet_spec.lua`:
   - Default layout includes `Review Session & Agent`, `gS`, `gs`, `ga`, and hide-without-quitting note.
   - Custom/disabled `send_agent`, `submit_review`, and `toggle_agent` render dynamically (`(disabled)` with `JprMuted` when `false`).

- [ ] **Step 2: Run focused tests to verify they fail**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/session_shortcuts_spec.lua && nvim --headless -u NONE -i NONE -l tests/lua/submit_view_spec.lua && nvim --headless -u NONE -i NONE -l tests/lua/cheatsheet_spec.lua`
Expected: FAIL on missing `<Plug>` mappings, missing confirmation dialog in `submit.lua`, and missing cheatsheet entries.

- [ ] **Step 3: Implement shortcuts, confirmed GitHub submission, and cheatsheet updates**

1. `lua/jpr/init.lua`: update `M.defaults` (`agent_direction`, `agent_width = nil`, `agent_load_toggleterm = true`, `keys.{send_agent, submit_review, toggle_agent}`), add `M.bind_session_keys(buf)`, call it from `M.bind_buffer_keys(buf)`, and add `send_agent`, `submit_review`, `toggle_agent` to `M.action`.
2. `plugin/jpr.lua`: register `<Plug>(jpr-send-agent)`, `<Plug>(jpr-submit-review)`, and `<Plug>(jpr-toggle-agent)`.
3. `lua/jpr/views/panel.lua` and `lua/jpr/views/conversation.lua`: call `require("jpr").bind_session_keys(buf)` when binding buffer keymaps.
4. `lua/jpr/views/submit.lua`: after validations pass in `submit_review`, open `require("jpr.views.confirm").open(...)` stored on `state.confirm`, showing exact review action (`Comment` / `Approve` / `Request changes`), draft count, and summary status; close `state.confirm` inside `close_active_submit` and `BufWipeout`; ignore duplicate triggers while `state.confirm` or `state.in_flight` is active.
5. `lua/jpr/views/cheatsheet.lua`: add `"Review Session & Agent"` section reading `keys.send_agent`, `keys.submit_review`, `keys.toggle_agent`, plus `:q / <C-q> / <M-q>` hide note.
6. Update any affected expectations in `tests/lua/panel_view_spec.lua` and `tests/lua/conversation_view_spec.lua` if needed.

- [ ] **Step 4: Run all Lua specs to verify pass**

Run: `./scripts/test-lua.sh`
Expected: every Lua spec prints `ok` (exit 0).

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/init.lua plugin/jpr.lua lua/jpr/views/panel.lua lua/jpr/views/conversation.lua lua/jpr/views/submit.lua lua/jpr/views/cheatsheet.lua tests/lua/session_shortcuts_spec.lua tests/lua/submit_view_spec.lua tests/lua/cheatsheet_spec.lua tests/lua/panel_view_spec.lua tests/lua/conversation_view_spec.lua
git commit -m "feat(keys): add confirmed gS/gs and ga shortcuts across review buffers"
```

---

### Task 7: Documentation Updates and Full `jpr-nvim` Verification

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/decisions.md`

**Interfaces:**
- Consumes: finalized config options, module layout (`lua/jpr/agent/`, `lua/jpr/views/confirm.lua`), shortcuts (`gS`, `gs`, `ga`), and test file list.
- Produces: up-to-date project docs with zero em dashes.

- [ ] **Step 1: Update `README.md`, `docs/architecture.md`, and `docs/decisions.md`**

- `README.md`: update `opts` snippet (`claude_cmd`, `codex_cmd`, `agent_direction`, `agent_width`, `agent_load_toggleterm`, `keys.{send_agent, submit_review, toggle_agent}`), document `gS`, `gs`, `ga` across review buffers, confirmation dialogs, and hide-without-quitting terminal behavior.
- `docs/architecture.md`: update the Lua frontend module table (`lua/jpr/agent/{init,command,terminal,delivery}.lua`, `lua/jpr/views/confirm.lua`) and Lua test list.
- `docs/decisions.md`: record an architectural decision entry explaining why Jpr uses built-in `:terminal` (`bufhidden = "hide"`) + on-demand `toggleterm.nvim` loading (instead of `Terminal:new`), cold-start CLI `-- <prompt>` + readiness-gated Vim-mode-safe warm PTY delivery, and mandatory confirmation dialogs on `gS` and `gs`.

- [ ] **Step 2: Run full workspace verification (`just check`) and em-dash guard**

Run: `just check && ! grep -rn $'\xe2\x80\x94' lua/ plugin/ tests/lua/ README.md docs/architecture.md docs/decisions.md`
Expected: `fmt-check`, `lint`, Rust `test`, Lua `test-lua` all pass with exit 0 and zero em dashes.

- [ ] **Step 3: Commit**

```bash
git add README.md docs/architecture.md docs/decisions.md
git commit -m "docs: document agent terminal integration, auto-submit delivery, and confirmed shortcuts"
```

---

### Task 8: Personal `jpsyx-configs` Update (`claude_cmd = "cl"`, `commands.yaml`, Docs, `jpsyx sync`)

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=low verified=yes)

**Files (in `${JPSYX_CONFIGS_DIR:-$HOME/src/jpsyx/jpsyx-configs}`):**
- Modify: `home/.config/nvim/lua/plugins/jpr.lua`
- Modify: `home/.config/nvim/commands.yaml`
- Modify: `home/.config/nvim/docs/plugins.md`
- Modify: `home/.config/nvim/docs/CHANGELOG.md`

**Interfaces:**
- Consumes: `jpr-nvim` config (`claude_cmd = "cl"`) and review shortcut bindings (`gS`, `gs`, `ga`).
- Produces: rendered `home-dist/.config/nvim/` (including regenerated `commands.json` and `CHEATSHEET.md`), verified with `jpsyx status` and `jpsyx doctor`.

- [ ] **Step 1: Update `home/.config/nvim/lua/plugins/jpr.lua`, `commands.yaml`, `docs/plugins.md`, and `docs/CHANGELOG.md`**

1. In `home/.config/nvim/lua/plugins/jpr.lua`, add `claude_cmd = "cl"` inside `opts` (preserving tabs indentation and existing `worktree_cmd = "wt pr {n}"`).
2. In `home/.config/nvim/commands.yaml`, add catalog entries for `jpr-nvim` review shortcuts (`gS` send local threads to agent with confirmation, `gs` open GitHub review submit modal with confirmation, `ga` toggle coding agent panel) under the review scopes (`jpr-diff`, `jpr-panel`, `jpr-conversation`, matching existing `jpr-nvim` catalog style).
3. Update the `jpsyx/jpr-nvim` row in `home/.config/nvim/docs/plugins.md` to mention `claude_cmd = "cl"` and add a dated entry in `home/.config/nvim/docs/CHANGELOG.md`.

- [ ] **Step 2: Syntax-check Lua, run `jpsyx sync`, and verify rendered output**

Run:
```bash
CONFIGS="${JPSYX_CONFIGS_DIR:-$HOME/src/jpsyx/jpsyx-configs}"
nvim -l /dev/stdin "$CONFIGS/home/.config/nvim/lua/plugins/jpr.lua" <<'LUA'
local ok, err = loadfile(_G.arg[1])
assert(ok, "SYNTAX ERROR: " .. tostring(err))
print("syntax ok")
LUA
jpsyx sync && jpsyx status && jpsyx doctor
```
Expected: `syntax ok`, rendered `home-dist/.config/nvim/lua/plugins/jpr.lua` contains `claude_cmd = "cl"`, `jpsyx status` all `ok`, `jpsyx doctor` clean.

- [ ] **Step 3: Commit and push personal cross-machine config update per `jpsyx-configs/AGENTS.md` standing exception (only the modified personal config files)**

```bash
cd "${JPSYX_CONFIGS_DIR:-$HOME/src/jpsyx/jpsyx-configs}"
git add home/.config/nvim/lua/plugins/jpr.lua home/.config/nvim/commands.yaml home/.config/nvim/docs/plugins.md home/.config/nvim/docs/CHANGELOG.md
git commit -m "feat(nvim): configure jpr claude_cmd=cl and catalog gS/gs/ga shortcuts"
git push origin main
```

---

## Final Review

help-me-pick: bug-hunting-and-code-review L3 (hours=0.5 cause=unknown material=familiar stakes=low verified=yes)

After Tasks 1-7 are complete on `feat/agent-terminal-and-shortcuts`:
1. Run `/avandar-code-review` across the branch, fix every violation, run `just check`, and commit review fixes.
2. Run full `/diff-review` (Initial mode, never walkthrough-only) to generate `.difit/` review comments/guides and walkthrough.
3. Copy `.difit/<stem>-walkthrough.md` to `docs/code-walkthroughs/2026-11-25_agent-terminal-and-review-shortcuts.md` and commit on `feat/agent-terminal-and-shortcuts`.
4. Complete Task 8 (`jpsyx-configs` update) and report ready for full-branch human review.
