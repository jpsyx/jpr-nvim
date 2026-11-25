# Executable-Only Neovim Command Palette Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Filter the Neovim `:Jpr` Command Palette (and `:Jpr comment` scope options) so only commands and options executable in the current session, repository, and cursor view are displayed, removing dim-gray unavailable palette rows.

**Architecture:** Add pure declarative predicate helpers (`is_command_executable`, `get_active_commands`, `get_active_options_from_step`) in `lua/jpr/tui/schema.lua`. Filter commands once on palette open in `lua/jpr/tui/wizard/palette.lua` (and idempotently in `lua/jpr/tui/render.lua`, removing `JprMuted` label dimming), filter select options in `lua/jpr/tui/wizard/step_menu.lua`, expand `build_tui_context` in `lua/jpr/init.lua` (plus `session.has_pending_tab` in `lua/jpr/session/open.lua`), and attach per-command and comment-option `when` predicates in `lua/jpr/commands/schema.lua`.

**Tech Stack:** Lua (Neovim 0.11+ plugin), headless Neovim Lua specs (`./scripts/test-lua.sh`), `just check`.

**Spec:** `docs/superpowers/specs/2026-11-25-palette-executable-filter-design.md`

## Global Constraints

- Keep all 16 `:Jpr` subcommands registered in `lua/jpr/commands/schema.lua` and passing `jpr.tui.schema.validate_command_specs`.
- Keep direct `:Jpr <subcommand>` dispatch and `:Jpr` command-line completion unchanged for all 16 subcommands.
- Keep `lua/jpr/tui/schema.lua` and `lua/jpr/tui/render.lua` pure (zero window, buffer, or editor side effects).
- Keep all functions short (<= 45 lines) and avoid em dashes (`—`) in comments, copy, and docs.
- Keep `just check` green across Rust and Lua.

## Review Focus

- **All commands filtered out:** Palette renders `(no commands available)` safely and ignores `j`/`k`/`gg`/`G`/`<CR>` without crashing (pinned in Task 1).
- **Step-back from a filtered palette:** Pressing `h` on Step 1 restores the filtered palette with the same command selected, not an unfiltered index (pinned in Task 1).
- **Cursor on a stream file header (not a diff line):** `comment` stays visible with only `File-Level Comment [file]` in its stepper (omitting `[line]` and `[suggest]`), while `suggest` stays hidden (pinned in Task 2).
- **Pending PR checkout tab (before session registers):** `close` appears in the palette alongside `open`/`local`/`keys`, while session-body commands stay hidden (pinned in Task 2).
- **Read-only crashed session:** `close`, `open`, `local`, `keys`, `toggle`, `expand`, cached `conversation`, and live `agent` stay visible, while engine-RPC commands (`sync`, `stream`, `comment`, `suggest`, `submit`, `push`, `send`, `prepass`, uncached `conversation`, unlaunched `agent`) stay hidden (pinned in Task 2).

---

### Task 1: Pure Schema Filtering, Renderer Update, and Wizard Integration

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `lua/jpr/tui/schema.lua`
- Modify: `lua/jpr/tui/render.lua`
- Modify: `lua/jpr/tui/wizard/palette.lua`
- Modify: `lua/jpr/tui/wizard/step_menu.lua`
- Test: `tests/lua/tui_schema_spec.lua`, `tests/lua/tui_render_spec.lua`, `tests/lua/tui_wizard_spec/palette.lua`

**Interfaces:**
- Produces in `lua/jpr/tui/schema.lua`:
  - `M.is_command_executable(command, context) -> boolean`
  - `M.get_active_commands(commands, context) -> table[]`
  - `M.get_active_options_from_step(step, answers, context) -> table[]`
- Produces in `lua/jpr/tui/render.lua`:
  - `M.create_palette_layout_from_commands(commands, selected_index, max_width, context)` filters via `schema.get_active_commands` and never highlights command labels with `JprMuted`.
- Produces in `lua/jpr/tui/wizard/palette.lua`:
  - `M.open_at(controller, commands, context, initial_index, preserved_origin_win)` filters `commands` via `schema.get_active_commands(commands, current_context)` once on open.
- Produces in `lua/jpr/tui/wizard/step_menu.lua`:
  - `select` steps resolve `options = schema.get_active_options_from_step(step, answers, context)`.

- [ ] **Step 1: Write failing tests for schema filtering, renderer omission, and wizard palette/step filtering**
  - In `tests/lua/tui_schema_spec.lua`:
    - Validate that non-function `command.when` and non-function `option.when` are rejected by `validate_command_specs`.
    - Assert `is_command_executable` and `get_active_commands` enforce `requires_session`, `requires_git_repo`, and `command.when(context)` in combination.
    - Assert `get_active_options_from_step` filters select options by `option.when(answers, context)` without mutating `step.options`.
  - In `tests/lua/tui_render_spec.lua`:
    - Assert `create_palette_layout_from_commands` omits `requires_session` commands when `has_session = false`, omits `requires_git_repo` commands when `is_git_repo = false`, omits commands whose `when(context)` returns `false`, and renders `(no commands available)` when all commands are filtered out.
    - Assert unselected visible command labels never receive `JprMuted` (only `[id]` tags, hover help, and footer use `JprMuted`).
  - In `tests/lua/tui_wizard_spec/palette.lua`:
    - Assert `open_palette` with `{ has_session = false }` hides `requires_session` commands, wraps navigation only across visible commands, handles all-filtered-out empty state cleanly, preserves the filtered palette selection when stepping back (`h`) from a command wizard, and filters `select` step options via `option.when`.

- [ ] **Step 2: Run targeted Lua specs to verify they fail**
  - Run: `nvim --headless -u NONE -l tests/lua/tui_schema_spec.lua` and `tui_render_spec.lua` and `tui_wizard_spec.lua`
  - Expected: FAIL (`is_command_executable` is nil / unavailable commands still rendered).

- [ ] **Step 3: Implement schema, render, palette, and step_menu changes**
  - `lua/jpr/tui/schema.lua`: validate `command.when` and select `option.when`; implement `M.is_command_executable`, `M.get_active_commands`, and `M.get_active_options_from_step`.
  - `lua/jpr/tui/render.lua`: filter `command_list` through `schema.get_active_commands(commands, context)` and remove the `is_unavailable` / `JprMuted` label highlight branch in `append_palette_command`.
  - `lua/jpr/tui/wizard/palette.lua`: filter `command_list = schema.get_active_commands(commands, current_context)` in `M.open_at`.
  - `lua/jpr/tui/wizard/step_menu.lua`: resolve `select` options via `schema.get_active_options_from_step(step, answers, context)`.

- [ ] **Step 4: Re-run targeted Lua specs to verify pass**
  - Run: `nvim --headless -u NONE -l tests/lua/tui_schema_spec.lua && nvim --headless -u NONE -l tests/lua/tui_render_spec.lua && nvim --headless -u NONE -l tests/lua/tui_wizard_spec.lua`
  - Expected: all 3 print `: ok`.

- [ ] **Step 5: Commit Task 1**
  - `git add lua/jpr/tui/schema.lua lua/jpr/tui/render.lua lua/jpr/tui/wizard/palette.lua lua/jpr/tui/wizard/step_menu.lua tests/lua/tui_schema_spec.lua tests/lua/tui_render_spec.lua tests/lua/tui_wizard_spec/palette.lua`
  - `git commit -m "feat: filter non-executable commands and options in TUI schema and palette"`

---

### Task 2: Runtime Context Snapshot and Per-Command Executability Predicates

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `lua/jpr/session/open.lua`
- Modify: `lua/jpr/init.lua`
- Modify: `lua/jpr/commands/schema.lua`
- Test: `tests/lua/palette_and_open_picker_spec/palette.lua`, `tests/lua/repo_picker_spec.lua`

**Interfaces:**
- Consumes: `jpr.tui.schema.get_active_commands`, `jpr.tui.schema.get_active_options_from_step`.
- Produces in `lua/jpr/session/open.lua`:
  - `session.has_pending_tab(tab) -> boolean`
- Produces in `lua/jpr/init.lua`:
  - `build_tui_context(session, cmd_opts)` populates `has_session`, `has_pending_tab`, `is_read_only`, `is_linked_pr`, `has_cached_conversation`, `local_unsent_count`, `is_agent_open`, `has_live_agent`, `is_on_diff_line`, `can_comment_file`, `is_in_changed_worktree_file`.
- Produces in `lua/jpr/commands/schema.lua`:
  - Declarative `when` predicates on all session/mode/view-gated commands and on `comment`'s `kind` step options (`line`, `file`, `suggest`).

- [ ] **Step 1: Write failing tests covering every state and view combination**
  - In `tests/lua/palette_and_open_picker_spec/palette.lua`:
    - Outside session in git repo: bare `:Jpr` shows only `open`, `local`, `keys` (none of the session commands).
    - Pending checkout tab (no registered session): bare `:Jpr` shows `open`, `local`, `close`, `keys`.
    - Active linked PR session in panel/unrelated buffer: hides `comment`, `suggest`, and `send` (with 0 unsent); shows `open`, `local`, `sync`, `toggle`, `stream`, `expand`, `conversation`, `submit`, `push`, `agent`, `prepass`, `close`, `keys`.
    - Active linked PR session with `localUnsentCount = 2`: shows `send`.
    - Active linked PR session in changed worktree file: shows `comment` (with `[line]`, `[file]`, `[suggest]`) and `suggest`.
    - Active linked PR session on stream file header (not diff line): shows `comment` whose stepper shows only `File-Level Comment [file]`, and hides `suggest`.
    - Unlinked local review session (`mode = "local"`, no `view.pr`) in changed worktree file: hides `submit`, `push`, `suggest`; keeps `sync`, `conversation`, `comment`, `agent`, `prepass`, `close`, etc.
    - Read-only crashed session: hides `sync`, `stream`, `comment`, `suggest`, `submit`, `push`, `send`, `prepass`, uncached `conversation`, unlaunched `agent`; keeps `open`, `local`, `toggle`, `expand`, `close`, `keys`, and shows `conversation` when cached or `agent` when live.
    - Update `test_palette_multi_step_commands_preselect_and_dispatch_smart_defaults` to run inside an active session/buffer where `toggle`, `comment`, and `agent` are actually executable.
  - In `tests/lua/repo_picker_spec.lua`:
    - Outside git repo after picking a repo: assert `Review Current Worktree [local]` and session-only commands are NOT shown in the repo-scoped palette (only `open` and `keys`), while direct `:Jpr local` / `local` execute guard still works.

- [ ] **Step 2: Run targeted Lua specs to verify they fail**
  - Run: `nvim --headless -u NONE -l tests/lua/palette_and_open_picker_spec.lua` and `tests/lua/repo_picker_spec.lua`
  - Expected: FAIL because non-executable commands still appear in the palette.

- [ ] **Step 3: Implement context snapshot and command/option `when` rules**
  - `lua/jpr/session/open.lua`: add `has_pending_tab(tab)` and attach as `session_mod.has_pending_tab`.
  - `lua/jpr/init.lua`: add small pure/helper readers for cursor view state (`is_on_diff_line`, `can_comment_file`, `is_in_changed_worktree_file`), `is_linked_pr_session`, `has_cached_conversation`, and populate them in `build_tui_context`.
  - `lua/jpr/commands/schema.lua`: add `when` predicates for `close`, `stream`, `sync`, `prepass`, `conversation`, `agent`, `send`, `submit`, `push`, `comment`, `suggest`, and `comment`'s `kind` step options (`line`, `file`, `suggest`).

- [ ] **Step 4: Re-run targeted Lua specs to verify pass**
  - Run: `nvim --headless -u NONE -l tests/lua/palette_and_open_picker_spec.lua && nvim --headless -u NONE -l tests/lua/repo_picker_spec.lua`
  - Expected: both print `: ok`.

- [ ] **Step 5: Commit Task 2**
  - `git add lua/jpr/session/open.lua lua/jpr/init.lua lua/jpr/commands/schema.lua tests/lua/palette_and_open_picker_spec/palette.lua tests/lua/repo_picker_spec.lua`
  - `git commit -m "feat: hide non-executable commands from Neovim command palette"`

---

### Task 3: Update Architecture/Decision Docs and Run Full Verification

help-me-pick: implement L1 (hours=0.25 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `docs/architecture.md`
- Modify: `docs/decisions.md`

- [ ] **Step 1: Update `docs/architecture.md`**
  - Update the `jpr.commands.schema`, `jpr.tui.schema`, `jpr.tui.render`, and `jpr.tui.wizard` rows in the Neovim plugin table to note executable-only Command Palette filtering (`when` predicates on commands and select options).

- [ ] **Step 2: Append decision entry to `docs/decisions.md`**
  - Add a new section at the bottom explaining why the Neovim Command Palette filters out non-executable commands and step options instead of dimming them in `JprMuted` (and why `:Jpr push` remains visible in linked PR sessions rather than gating on 2-second-polled `ahead`).

- [ ] **Step 3: Run full verification**
  - Run: `just check`
  - Expected: formatting, clippy, Rust tests, and all Lua specs exit 0.

- [ ] **Step 4: Commit Task 3**
  - `git add docs/architecture.md docs/decisions.md`
  - `git commit -m "docs: document executable-only Neovim command palette filtering"`

---

### Final Branch Review

help-me-pick: bug-hunting-and-code-review L3 (hours=0.5 cause=unknown material=familiar stakes=low verified=yes)
