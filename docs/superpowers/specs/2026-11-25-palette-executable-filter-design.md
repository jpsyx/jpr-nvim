# Executable-Only Neovim Command Palette Design

## Intent and Why

When opening the Neovim Command Palette (`<leader>J` or bare `:Jpr`), showing unavailable commands dimmed in `JprMuted` next to bright-white available commands and a green (`JprTitle`) hovered row is visually confusing: dimmed labels look like decorative hierarchy rather than disabled commands, and selecting a disabled command still lets the user trigger it and hit an error.

Only commands and menu options that can execute in the current session state, repository state, and cursor view should appear in the interactive palette. Every visible item is actionable right now, unselected labels render uniformly in normal text, and the hovered row remains highlighted in `JprTitle`.

## Goals, Non-Goals, and Anti-Goals

- **Goals:**
  - Hide every `:Jpr` command from the interactive Command Palette that cannot execute in the current state or view.
  - Hide inapplicable scope options inside `:Jpr comment`'s interactive stepper (for example, hide `[line]` and `[suggest]` when the cursor is on a stream file header where only `[file]` can anchor).
  - Remove the `JprMuted` label-dimming branch from palette command rows so all visible palette labels use normal text when unselected and `JprTitle` when hovered.
- **Non-Goals:**
  - Changing direct Ex command dispatch (`:Jpr <subcommand>`) or command-line tab completion (all 16 subcommands remain registered in the schema and directly invocable).
  - Changing the Rust CLI `jpr-review` Command Palette (which has no Neovim tab/view state).
  - Hiding `:Jpr push` based on `worktreeStatus.ahead` (which polls every 2 seconds and could momentarily vanish right after a terminal commit).
- **Anti-Goals:**
  - Leaving unreachable or error-guaranteed commands visible in the palette.
  - Duplicating filtering rules across renderer, wizard navigation, and tests (filtering must live in one pure schema predicate layer).

## Constraints

- Keep the repo's Schema-to-TUI invariant intact: all 16 `:Jpr` commands remain declared in `lua/jpr/commands/schema.lua` and validated by `jpr.tui.schema.validate_command_specs`.
- Keep `lua/jpr/tui/schema.lua` and `lua/jpr/tui/render.lua` pure (no Neovim window, buffer, or side-effect calls).
- Keep all functions short (<= 45 lines) and maintain full Lua spec coverage (`just check`).

## Approaches Considered

1. **Declarative `when(context)` predicates in `jpr.tui.schema` + pre-filtering in `palette.lua` and `render.lua` (Selected):**
   - Extend `jpr.tui.schema` with pure `is_command_executable(command, context)`, `get_active_commands(commands, context)`, and `get_active_options_from_step(step, answers, context)` helpers, honoring `requires_session`, `requires_git_repo`, and optional `when` predicates on commands and select options.
   - `palette.lua` filters commands once on open so `j`/`k`/`gg`/`G`/`<CR>`, `item_for_line`, and step-back indices stay in lockstep; `render.lua` also calls `get_active_commands` (idempotent) and drops the `JprMuted` label-dimming branch.
   - **Why selected:** Mirrors existing step-level `when` predicates, keeps rules declarative and unit-testable in pure Lua, and guarantees zero mismatch between displayed rows and key navigation.
2. **Coarse `requires_session` / `requires_git_repo` filtering only (Rejected):**
   - Leaves PR-only commands (`submit`, `push`, `suggest`) visible in local-only reviews, mutating commands visible in read-only crashed sessions, `send` visible with 0 unsent local threads, and `comment`/`suggest` visible from the sidebar panel or conversation buffer.
3. **Imperative filtering inside `lua/jpr/init.lua` before calling `wizard.open_palette` (Rejected):**
   - Splits command eligibility away from `lua/jpr/commands/schema.lua`, breaks reuse when tests or callers invoke `wizard.open_palette` / `render.create_palette_layout_from_commands` directly, and does not cover step-level option filtering.

## Design

### 1. Context Snapshot (`lua/jpr/init.lua`, `lua/jpr/session/open.lua`)

`session.has_pending_tab(tab)` exposes whether `tab` currently has an in-flight checkout. `build_tui_context(session, cmd_opts)` computes:

- `has_session`: `current_session ~= nil`
- `has_pending_tab`: `not has_session and session.has_pending_tab(current_tab) == true`
- `is_read_only`: `current_session ~= nil and current_session.is_read_only == true`
- `is_linked_pr`: `current_session ~= nil and (current_session.mode ~= "local" or type(current_session.view and current_session.view.pr) == "table")`
- `has_cached_conversation`: `current_session ~= nil` and `current_session.conversation.buf` is a valid buffer
- `local_unsent_count`: `tonumber(current_session.view.localUnsentCount) or 0`
- `is_agent_open`, `has_live_agent`: unchanged
- `is_on_diff_line`: cursor is on a commentable line in the stream, in a base diff buffer (`jpr_base_path`), or in a changed worktree file
- `can_comment_file`: cursor is on a changed file section in the stream (`render.stream.find_file_at_line`), in a base diff buffer, or in a changed worktree file
- `is_in_changed_worktree_file`: cursor is not in a stream buffer and `diff.buffer_to_changed_path(current_session, buf) ~= nil`

### 2. Pure Filtering in `lua/jpr/tui/schema.lua`

- `validate_command_specs` validates optional `command.when` (function) and optional `option.when` (function) on select options.
- `is_command_executable(command, context)` returns `false` if:
  - `command.requires_session == true` and `context.has_session ~= true`, or
  - `command.requires_git_repo == true` and `context.is_git_repo == false`, or
  - `type(command.when) == "function"` and `command.when(context) ~= true`.
- `get_active_commands(commands, context)` returns the ordered subset of commands passing `is_command_executable`.
- `get_active_options_from_step(step, answers, context)` returns the ordered subset of `step.options` whose optional `option.when(answers, context)` is absent or returns `true`.

### 3. Command & Option Rules (`lua/jpr/commands/schema.lua`)

| Command | Rule |
| --- | --- |
| `open` | Always executable (`requires_session = false`) |
| `local` | `requires_session = false`, `requires_git_repo = true` |
| `keys` | Always executable (`requires_session = false`) |
| `close` | `requires_session = false`, `when`: `has_session or has_pending_tab` |
| `toggle`, `expand` | `requires_session = true` |
| `stream`, `sync`, `prepass` | `requires_session = true`, `when`: `not is_read_only` |
| `conversation` | `requires_session = true`, `when`: `not is_read_only or has_cached_conversation` |
| `agent` | `requires_session = true`, `when`: `not is_read_only or has_live_agent` |
| `send` | `requires_session = true`, `when`: `not is_read_only and local_unsent_count > 0` |
| `submit`, `push` | `requires_session = true`, `when`: `not is_read_only and is_linked_pr` |
| `comment` | `requires_session = true`, `when`: `not is_read_only and (is_on_diff_line or can_comment_file)` |
| `suggest` | `requires_session = true`, `when`: `not is_read_only and is_linked_pr and is_in_changed_worktree_file` |

Inside `comment`'s `kind` step:

- `line` and `suggest`: `when = function(_, ctx) return ctx.is_on_diff_line == true end`
- `file`: `when = function(_, ctx) return ctx.can_comment_file == true end`

### 4. Palette, Stepper, and Renderer Integration

- `lua/jpr/tui/wizard/palette.lua`: filters `command_list = schema.get_active_commands(commands, current_context)` on open.
- `lua/jpr/tui/wizard/step_menu.lua`: uses `schema.get_active_options_from_step(step, answers, context)` for `select` steps.
- `lua/jpr/tui/render.lua`: filters `command_list = schema.get_active_commands(commands, context)` in `create_palette_layout_from_commands` and removes the `is_unavailable` / `JprMuted` label highlight branch.

### 5. Documentation & Tests

- Update `docs/architecture.md` and `docs/decisions.md` to document executable-only palette filtering.
- Update existing specs (`tests/lua/tui_schema_spec.lua`, `tests/lua/tui_render_spec.lua`, `tests/lua/tui_wizard_spec/palette.lua`, `tests/lua/palette_and_open_picker_spec/palette.lua`, `tests/lua/repo_picker_spec.lua`) and add thorough red/green TDD coverage for every state and view condition.
