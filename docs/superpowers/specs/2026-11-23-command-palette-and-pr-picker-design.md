# Interactive Command Palette, Schema-to-TUI Engine & Cmdline Abbreviation Fix

## Goal

Make **every** command in both the `jpr-nvim` Neovim plugin (`:Jpr`) and the `jpr-review` CLI binary interactively discoverable and launchable through a shared **command-schema-to-TUI** architecture, while fixing the `open` command-line abbreviation collision in `jpsyx-configs`:

1. **Universal Interactive Command Palette & Stepper TUI (Plugin + Binary Invariant):**
   - Establish a permanent project invariant in `AGENTS.md` and `docs/rules/cli-ux.md`: every command and option in `:Jpr` and `jpr-review` must be registered in a declarative command schema with human-readable labels, literal command IDs in brackets (`[open]`), concise 1-sentence helper text (revealed on hover in menus and shown on every step), smart defaults prefilled/preselected, and **discriminant-first dynamic branching** so irrelevant options are never asked.
   - Build a reusable schema-to-TUI module in Lua (`lua/jpr/tui/`) powering bare `:Jpr` (Command Palette) and multi-step command modals (starting with `:Jpr open`, `:Jpr comment`, `:Jpr toggle`, and `:Jpr agent`).
   - Build a reusable schema-to-TUI crate in Rust (`crates/cli-tui`) powering bare `jpr-review` (TTY Command Palette) and interactive steppers whenever required options are omitted on a terminal, while keeping stdout strictly pure data and non-TTY invocations 100% scriptable.
2. **Pull Request Listing in Engine (`jpr-review prs`):**
   - Add `PullRequestSummary`, `GhForge::open_pull_requests`, and `jpr-review prs [--repo OWNER/NAME] [--limit N]` so `:Jpr open` (and the `jpr-review` CLI) lists open PRs through the Rust forge adapter.
3. **Command-Line Abbreviation Fix (`jpsyx-configs`):**
   - Scope `open`, `dir`, `tb`, `W`, `Q`, `Wq`, `WQ`, and `wQ` abbreviations in `home/.config/nvim/init.lua` strictly to command position (`getcmdtype() == ":"` and `getcmdline() == lhs`) so `:Jpr open ` never expands to `:Jpr OpenCurrentFile `.

## Scope

1. **`jpr-nvim` repository (`0.5.1`):**
   - Bump workspace version (`Cargo.toml`) and `M.VERSION` (`lua/jpr/init.lua`) to `0.5.1` so `:Lazy update` rebuilds and lockstep version checks validate the new `prs` subcommand.
   - Permanent rules: update `AGENTS.md`, `docs/rules/cli-ux.md`, `docs/rules/cli-rust.md`, `docs/architecture.md`, `docs/decisions.md`, and `README.md`.
   - Rust engine:
     - `crates/review-model`: add `PullRequestSummary`.
     - `crates/review-forge-github`: add `PR_LIST_FIELDS`, `parse_pr_list`, `GhForge::list_args`, and `GhForge::open_pull_requests`.
     - `crates/cli-tui`: new non-`review-*` workspace crate (preserving `dependency_rule.rs`) providing the reusable declarative command-schema IR, discriminant-first step resolver, pure ANSI frame renderer, and `crossterm`-backed interactive TTY runner writing exclusively to `stderr`.
     - `crates/jpr-review`: add `Command::Prs`, register all 8 CLI subcommands (`prs`, `checkout`, `threads`, `reply`, `prepass-write`, `state-path`, `serve`, `guide`) in the `cli-tui` schema, wire bare `jpr-review` on a TTY to the command palette, and wire interactive missing-option flows on a TTY to the subcommand's stepper.
   - Neovim plugin:
     - `lua/jpr/tui/schema.lua`: schema validation, discriminant-first active-step resolution, and smart-default prefilling.
     - `lua/jpr/tui/render.lua`: pure layout and extmark builder for the Command Palette (hover-only dim 1-sentence helper line) and Stepper Modal (header with step counter, hover-only option helper lines, prefilled text input box, mode-aware footer).
     - `lua/jpr/tui/wizard.lua`: floating rounded modal controller managing Normal-mode menu steps, Insert-mode text-input steps, async option loading (`jpr-review prs`), Back/Forward step navigation, and clean cancellation.
     - `lua/jpr/commands/schema.lua`: single source of truth for all 14 `:Jpr` subcommands (feeding bare `:Jpr` palette, `:Jpr <Tab>` completion, and interactive steppers).
     - `plugin/jpr.lua`, `lua/jpr/init.lua`, `lua/jpr/session/init.lua`, `lua/jpr/session/commands.lua`, `lua/jpr/agent.lua`: switch `:Jpr` to `nargs = "*"`, route bare `:Jpr` to the Command Palette, route `:Jpr open` (no arg) to `open`'s stepper, and support optional explicit CLI arguments for every interactive choice (`:Jpr toggle unified|split`, `:Jpr comment line|file|suggest`, `:Jpr agent claude|codex`).
   - Tests: Rust unit/integration tests for `review-forge-github`, `cli-tui`, and `jpr-review`; headless Neovim specs for `tui/schema`, `tui/render`, `tui/wizard`, bare `:Jpr` palette, and `:Jpr open` PR picker.
2. **`jpsyx-configs` repository (post-merge & publish):**
   - Fix command-line abbreviations in `home/.config/nvim/init.lua` using an `<expr>` command-position guard and add regression tests in `home/.config/nvim/tests/file_actions_spec.lua`.
   - Update `home/.config/nvim/commands.yaml` for bare `:Jpr` palette and `jpr-tui` modal shortcuts.
   - Run `:Lazy! update jpr-nvim` to pull `0.5.1` and rebuild `jpr-review`, run `jpsyx build && jpsyx sync`, and commit the updated `lazy-lock.json`.

---

## Keyboard Conventions (Neovim & TTY)

Both the Neovim floating modal (`lua/jpr/tui/wizard.lua`) and the Rust terminal TUI (`crates/cli-tui`) follow the same Neovim-conventional controls, distinguishing menu navigation from text editing so Vim muscle memory never collides with typing:

| Step Type | Mode | Browse Options | Back / Forward Step | Confirm | Cancel |
| --- | --- | --- | --- | --- | --- |
| **Palette & Menu / Choice / Boolean Toggle** | Normal mode (no text input) | `j` / `k`, `<Down>` / `<Up>`, `gg` / `<Home>`, `G` / `<End>` | `h` / `<Left>` / `<S-Tab>` = Back; `l` / `<Right>` / `<Tab>` = Confirm & Next | `<CR>` (advances step, or executes on final step) | `q` / `<Esc>` |
| **Text Input** | Starts in Insert mode with smart default prefilled | `<Left>` / `<Right>` move text cursor; `h`/`j`/`k`/`l` type characters normally | `<S-Tab>` = Back; `<Tab>` = Validate & Next | `<CR>` (validates & advances, or executes on final step) | `<Esc>` drops to Normal mode (allows Vim edits like `ciw`/`0`/`$`); `q` or second `<Esc>` in Normal mode cancels |

In the Rust terminal TUI (`crates/cli-tui`), text-input steps use `<Left>`/`<Right>`/`<Home>`/`<End>`/`<Backspace>` for inline editing, `<S-Tab>` for Back, `<Tab>`/`<CR>` for Forward/Confirm, and `<Esc>`/`<C-c>` to cancel. Menu/toggle steps use `j`/`k`/`<Down>`/`<Up>` to browse, `h`/`<Left>`/`<S-Tab>` for Back, `l`/`<Right>`/`<Tab>`/`<CR>` for Confirm/Forward, and `q`/`<Esc>`/`<C-c>` to cancel.

---

## Declarative Schema-to-TUI Model (Shared Architecture)

Both `lua/jpr/tui/` and `crates/cli-tui` share the exact same declarative model so adding any command or option automatically produces a consistent interactive TUI:

### Core Primitives

- **`CommandSpec`:**
  - `id`: literal subcommand identifier (e.g. `"open"`, `"checkout"`).
  - `label`: human-readable UX-friendly display label (e.g. `"Open Pull Request"`).
  - `help`: concise 1-sentence helper text (rendered in dim font on a second line **only** when hovered in the palette).
  - `requires_session` (Lua only, boolean): dims the entry in the palette when no review session is active in the current tab while keeping it inspectable.
  - `steps`: ordered list of `StepSpec` entries, **discriminants first**.
  - `execute(answers, context)`: invoked once all active steps are answered (or immediately if `steps` is empty).

- **`StepSpec`:**
  - `id`: answer key stored in `answers[step.id]`.
  - `label`: short step title shown in the stepper header (e.g. `"Pull Request Source"`).
  - `help`: 1-sentence helper text explaining what is being asked (always displayed under the step header; never exceeds 1 sentence unless the option is genuinely complex).
  - `kind`:
    - `"select"`: static list of `{ value, label, badge?, help? }` options; hovering an option expands its dim 1-sentence `help` text onto an indented second line right below it.
    - `"async_select"` (Lua) / `"dynamic_select"` (Rust): loads options via a provider function `load(answers, context, callback)` (e.g. `jpr-review prs`), showing an inline `"Loading..."` state while fetching and rendering the loaded options with hover-only dim detail lines.
    - `"toggle"`: boolean choice rendered as two clear human-readable options (e.g. `No (default)` vs `Yes`), with hover helper text for each choice.
    - `"text"`: single-line input box prefilled with `default(answers, context)` and validated by optional `validate(value, answers) -> ok, error_message`.
  - `default`: static value or `function(answers, context)` returning the smart default (prefilled in text boxes, preselected in menus).
  - `when` (optional discriminant predicate): `function(answers, context) -> boolean`. When omitted, the step is always active. When present, the step is included in the stepper **only** if `when(answers, context)` returns `true`.
  - `skip_when_provided` (optional boolean, default `true`): if the caller already supplied this answer via command arguments/flags (e.g. `jpr-review checkout --pr 42`), pre-populates `answers[step.id]` and skips asking it unless the user explicitly steps back.

### Discriminant-First Resolution Algorithm

Implemented identically as pure functions in `lua/jpr/tui/schema.lua` and `crates/cli-tui/src/state.rs`:

1. `resolve_active_steps(command, answers, context)` walks `command.steps` in order and keeps every step whose `when` predicate is absent or evaluates to `true` against the current `answers` and `context`.
2. Whenever a user changes an earlier discriminant answer and advances, any stored answers belonging to steps **no longer in `resolve_active_steps(...)`** are ignored on execution (and pruned on submit), and the stepper recomputes `Step X of Y` dynamically.
3. Going Back (`h` / `<Left>` / `<S-Tab>`) returns to the previous active step with its previously selected/typed value preserved; on Step 1 of a command launched from the Command Palette, going Back returns directly to the Command Palette with that command still highlighted.
4. If a command has 0 active steps (for example, `sync` or `close`, or `agent` when its split is already open and simply hiding), `<CR>` executes it immediately with no extra modal.

---

## Component Design

### 1. Neovim Reusable TUI Engine (`lua/jpr/tui/`)

- **`lua/jpr/tui/schema.lua` (pure):**
  - `validate_command_specs(commands)`: verifies every command has non-empty `id`, `label`, `help`, unique `id`, and valid `steps` (called in unit tests so missing labels/helper text fail CI).
  - `resolve_active_steps(command, answers, context)`: computes active steps after discriminant evaluation.
  - `get_default_value_from_step(step, answers, context)`: evaluates static or function smart default.
  - `prune_inactive_answers(command, answers, context)`: returns a clean answer table containing only active step IDs.

- **`lua/jpr/tui/render.lua` (pure):**
  - **`build_palette_layout(commands, selected_index, max_width, context)`:**
    - Primary row for every command:
      - Selected: `▸ <Display Label>  [<id>]` (`▸ ` in `JprTitle`, `[<id>]` in `JprMuted`).
      - Unselected: `  <Display Label>  [<id>]` (`<Display Label>` in `JprMuted` if `requires_session` and no session active, else normal text; `[<id>]` in `JprMuted`).
    - **Hover-only second line:** emitted **only** immediately underneath `selected_index`, indented by 4 spaces (`"    " .. command.help`), wrapped cleanly to `max_width - 4`, highlighted in `JprMuted`.
    - Footer: `"[j/k] move  [Enter/l] select  [q/Esc] close"` in `JprMuted`.
    - Returns `{ lines, highlights, cursor_line, item_for_line }`.
  - **`build_step_layout(command, active_steps, step_index, step_state, max_width)`:**
    - Header line 1: `Step <step_index> of <#active_steps> · <step.label>` (`JprTitle`) + compact step dots (e.g. `● ○` in `JprTitle` / `JprMuted`).
    - Header line 2: 1-sentence `step.help` in `JprMuted` (wrapped cleanly).
    - Optional inline validation error line in `JprError` if validation failed.
    - Body:
      - For `select` / `async_select` / `toggle`: option rows with `"▸ "` / `"  "`, optional dim `[badge]`, and **hover-only** indented dim `option.help` line right below the currently hovered option (or `"  Loading..."` / empty-state message during async fetch).
      - For `text`: prompt label + single editable input line prefilled with the current/default value.
    - Footer:
      - Menu/toggle step: `"[j/k] move  [h] back  [Enter/l] next  [q/Esc] close"` (or `"[Enter/l] run"` on the final step; `"[h] palette"` on step 1 when opened from palette).
      - Text step: `"[Enter/Tab] next  [S-Tab] back  [Esc] normal/cancel"` (or `"[Enter/Tab] run"` on the final step).

- **`lua/jpr/tui/wizard.lua` (floating modal controller):**
  - `M.open_palette(commands, context)` and `M.open_command(command, initial_answers, context, return_to_palette)`.
  - Manages a single centered rounded floating window (for menu steps: single non-modifiable buffer in Normal mode; for text steps: a header/helper float + editable 1-line input float or a unified editable input line with extmark virtual header/footer so Neovim Insert mode works cleanly without clobbering header lines).
    - **Text step buffer design (clean and bug-free in Neovim):** use a dedicated 1-line editable scratch buffer for the text input inside a rounded float whose `title` carries `" Step X of Y · <step.label> "` and `footer` carries the key hints, with a read-only companion banner/virtual lines above (`virt_lines_above = true` on line 0 via extmark) showing the 1-sentence `step.help` and any validation error! That keeps buffer line 1 strictly the user's text value (`vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]`), prevents accidental deletion of headers in Insert mode, allows full Vim text editing (`ciw`, `0`, `$`, `<Left>`, `<Right>`), and keeps a single floating window with zero multi-window focus glitches.
  - Singleton guard: opening a new wizard closes any active `jpr` wizard cleanly.
  - Async cancellation guard: monotonically incrementing `request_id` drops stale `async_select` callbacks if the user steps back or closes the modal while `jpr-review prs` is in flight.

### 2. `:Jpr` Command Schema (`lua/jpr/commands/schema.lua`)

Single source of truth for all 14 `:Jpr` subcommands (drives bare `:Jpr` palette, `:Jpr <Tab>` cmdline completion, and interactive steppers):

| ID | Display Label | 1-Sentence Hover Helper Text | Requires Session | Interactive Steps & Discriminants |
| --- | --- | --- | --- | --- |
| `open` | Open Pull Request | Pick an open pull request or enter a PR number or URL to start reviewing. | No | **Step 1 (discriminant `source`, default `"list"`):** `Pick from Open PRs` vs `Enter PR Number or URL`. **Step 2a (`when source == "list"`, `async_select`):** loads open PRs via `jpr-review prs`; primary row `#<n>  <title>` + `[draft]`/`[open]` badges; hover-only dim line `@<author> · <headRef> · updated <YYYY-MM-DD>`. **Step 2b (`when source == "manual"`, `text`):** prefilled empty, validates via `jpr.parse_pr_arg`. |
| `sync` | Sync with GitHub | Fetch the latest pull request commits, files, and review threads from GitHub. | Yes | 0 steps (runs immediately). |
| `toggle` | Switch Diff View | Choose between unified inline diffs and side-by-side split diffs for review buffers. | Yes | **Step 1 (`mode`, `select`, smart default = opposite of current `view_mode.get()`):** `Unified Diff  [unified]` vs `Side-by-Side Split  [split]`, each with 1-sentence hover help. *(Direct `:Jpr toggle` flips immediately; `:Jpr toggle unified\|split` sets explicitly.)* |
| `stream` | Open Stream View | View all changed files stacked continuously in a single scrollable diff stream. | Yes | 0 steps (runs immediately). |
| `comment` | Add Review Comment | Draft a new review comment on the current line, visual selection, or entire file. | Yes | **Step 1 (discriminant `kind`, `select`, smart default = `"line"` when on a diff/stream line else `"file"`):** `Line / Selection Comment  [line]` vs `File-Level Comment  [file]` vs `Code Suggestion  [suggest]`. *(Direct `:Jpr comment` still comments on the cursor line/range; `:Jpr comment file` and `:Jpr comment suggest` also work directly.)* |
| `suggest` | Suggest Code Change | Draft a review comment pre-filled with a GitHub suggestion block for the current line. | Yes | 0 steps (runs immediately). |
| `expand` | Expand Inline Threads | Toggle inline expansion of review threads across diff and stream buffers. | Yes | 0 steps (runs immediately). |
| `conversation` | Open PR Conversation | Read and post top-level pull request issue comments in the main review window. | Yes | 0 steps (opens conversation view). |
| `submit` | Submit Review | Preview pending draft comments and submit your review decision to GitHub. | Yes | 0 steps (opens dedicated `:Jpr submit` modal). |
| `push` | Push Head Branch | Push local commits on the checked-out pull request branch back to GitHub. | Yes | 0 steps (runs immediately). |
| `agent` | Coding Agent Panel | Open, configure, or hide the interactive coding-agent terminal split for this review. | Yes | **Step 1 (`when` agent window is NOT already open; `provider`, `select`, smart default = `jpr.config.agent`):** `Claude Code  [claude]` vs `Codex  [codex]`. If agent window is already open, 0 steps (hides immediately). *(Direct `:Jpr agent` toggles using configured default; `:Jpr agent claude\|codex` selects explicitly.)* |
| `send` | Send Local Threads to Agent | Prompt the coding agent to address pending local review threads in this worktree. | Yes | 0 steps (runs immediately). |
| `prepass` | Run Agent Pre-Pass | Ask the coding agent to scan the pull request diff and post local pre-pass findings. | Yes | 0 steps (runs immediately). |
| `close` | Close Review Session | Close the current tab's pull request review session and stop its background engine. | Yes | 0 steps (runs immediately). |

- **Direct CLI parity (`plugin/jpr.lua` & `lua/jpr/init.lua`):**
  - `:Jpr` (`nargs = "*"`) with 0 args -> opens the Command Palette (`wizard.open_palette`).
  - `:Jpr open` with 0 args -> opens `open`'s stepper directly on Step 2a (the open PR list) with `source = "list"` prefilled, while `h`/`<Left>`/`<S-Tab>` steps back to Step 1 (`Pull Request Source`) if the user wants to switch to manual PR number or URL input.
  - `:Jpr open <number|#number|url>` -> skips wizard and calls `session.open(number, repo)` immediately.
  - `:Jpr open <invalid>` -> reports clear error (`invalid pull request ...`).
  - `:Jpr <subcommand>` for all other commands continues to execute directly without friction, and also supports the optional arguments exposed by the schema (`:Jpr toggle unified|split`, `:Jpr comment line|file|suggest`, `:Jpr agent claude|codex`).

### 3. Rust Engine: `jpr-review prs` (`review-model`, `review-forge-github`, `jpr-review`)

- **`crates/review-model/src/pr.rs` (re-exported from `lib.rs`):**
  ```rust
  #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
  #[serde(rename_all = "camelCase")]
  pub struct PullRequestSummary {
      pub number: u64,
      pub title: String,
      pub author: String,
      pub head_ref: String,
      pub is_draft: bool,
      pub updated_at: String,
  }
  ```
- **`crates/review-forge-github/src/pr.rs` & `lib.rs`:**
  - `PR_LIST_FIELDS = "number,title,author,headRefName,isDraft,updatedAt"`.
  - `parse_pr_list(stdout: &str) -> Result<Vec<PullRequestSummary>>` (missing `author.login` falls back to `"ghost"`).
  - `GhForge::list_args(&self, limit: u32) -> Vec<String>` -> `["pr", "list", "--state", "open", "--limit", "<limit>", "--json", PR_LIST_FIELDS]` + optional `["--repo", repo]`.
  - `GhForge::open_pull_requests(&self, limit: u32) -> Result<Vec<PullRequestSummary>>`.
- **`crates/jpr-review/src/cli.rs` & `commands/prs.rs`:**
  - `Command::Prs { #[arg(long, value_name = "OWNER/NAME")] repo: Option<String>, #[arg(long, default_value_t = 50)] limit: u32 }`.
  - Prints a compact JSON array to stdout (`serde_json::to_string(&summaries)`) and narrates `"Listing open pull requests..."` on stderr.

### 4. Reusable Rust Schema-to-TUI Crate (`crates/cli-tui`) & `jpr-review` Integration

- **Crate placement & dependency rule:**
  - `crates/cli-tui` is a workspace crate **outside** `crates/review-*` (so `crates/jpr-review/tests/dependency_rule.rs` continues to guarantee zero UI dependencies in any `review-*` crate).
  - Dependencies: `anyhow`, `crossterm` (raw mode + keyboard events + alternate/inline cursor rendering on `stderr`).
  - `crates/jpr-review` depends on `cli-tui`.
- **Modules inside `crates/cli-tui/src/`:**
  - `schema.rs`: `CommandSpec`, `StepSpec`, `StepKind` (`Select`, `DynamicSelect`, `Toggle`, `Text`), `SelectOption`, `Answers` (`BTreeMap<String, String>`), `WhenPredicate`, `DefaultFn`, `ValidateFn`.
  - `state.rs` (100% pure, unit-tested without a TTY):
    - `PaletteState` and `WizardState` state machines implementing `resolve_active_steps`, discriminant-first branching, `KeyAction` handling (`Up`, `Down`, `Back`, `Forward`, `Confirm`, `Cancel`, `Char`, `Backspace`, `Left`, `Right`), hover-only helper expansion, and Back-to-Palette from Step 1.
  - `render.rs` (100% pure, unit-tested without a TTY):
    - Renders palette frames (`▸ <Label>  [<id>]` + hover-only dim second line) and stepper frames (`Step X of Y · <Label>` + 1-sentence help + options or prefilled input + key footer) using semantic ANSI styles (respecting `NO_COLOR`).
  - `runner.rs`:
    - Checks `stdin().is_terminal() && stderr().is_terminal()`. Never reads from stdin or draws a TUI when non-interactive.
    - Drives `crossterm::terminal::enable_raw_mode` with a drop guard so raw mode and cursor visibility are **always** restored on return, cancel, or panic, rendering strictly to `stderr` so `stdout` stays pure data.
- **`crates/jpr-review/src/tui_schema.rs`:**
  - Declares all 8 `jpr-review` subcommands (`prs`, `checkout`, `threads`, `reply`, `prepass-write`, `state-path`, `serve`, `guide`) with human-readable labels, `[id]`, 1-sentence helper text, smart defaults, and discriminants:
    - **`prs`** (*List Open Pull Requests*): discriminant `custom_repo` (`Current repository` [default] vs `Specific owner/name`) -> `repo` text only if custom; `limit` text (default `"50"`).
    - **`checkout`** (*Check Out Pull Request*): discriminant `source` (`Pick from Open PRs` [default] vs `Enter PR Number`) -> `pr` via `DynamicSelect` from `GhForge::open_pull_requests` or manual `Text` input; discriminant `custom_repo` (`Current repository` [default] vs `Specific owner/name`) -> `repo` text only if custom; discriminant `custom_worktree` (`Default git worktree` [default] vs `Custom worktree command`) -> `worktree_cmd` text (default `$JPR_WORKTREE_CMD`) only if custom.
    - **`threads`** (*List Review Threads*): discriminant `target_mode` (`Running daemon socket` [default if `$JPR_SOCKET` set] vs `PR & repository`) -> branches to either `socket` (default `$JPR_SOCKET`) or (`pr` + `repo`); `is_local_only` toggle (`All threads` [default] vs `Local agent threads only`).
    - **`reply`** (*Reply to Local Thread*): discriminant `target_mode` -> `socket` or (`pr` + `repo`); `thread_id` text; `body` text.
    - **`prepass-write`** (*Write Pre-Pass Findings*): discriminant `target_mode` -> `socket` or (`pr` + `repo`); discriminant `input_mode` (`JSON file` [default] vs `Read from stdin`) -> `input` file path only if JSON file.
    - **`state-path`** (*Show Review State Path*): `pr` text; `repo` text (default inferred from `git`).
    - **`serve`** (*Run JSON-RPC Review Engine*): `pr` text; `repo` text; `poll` text (default `"60"`).
    - **`guide`** (*Print Agent Review Guide*): 0 steps (executes immediately).
  - Bare `jpr-review` with no subcommand:
    - On a TTY: launches `cli_tui::run_palette(...)` and executes the resulting `Command`.
    - Not on a TTY (pipes, scripts, CI, tests): prints clap help to stderr and exits non-zero (preserving existing non-interactive behavior).
  - `jpr-review <subcommand>` with omitted required flags on a TTY: launches `cli_tui::run_command(...)` pre-populated with any flags already passed on the command line (replacing ad-hoc linear prompts with the unified stepper TUI). When non-TTY, continues failing immediately with the missing flag name per `docs/rules/cli-ux.md`.

### 5. Permanent Invariant in `AGENTS.md` & `docs/rules/cli-ux.md`

Add a binding **Interactive Command Palette & Schema-to-TUI Invariant** rule to `AGENTS.md` and `docs/rules/cli-ux.md`:
- Every command and option in both `:Jpr` (`lua/jpr/commands/schema.lua`) and `jpr-review` (`crates/jpr-review/src/tui_schema.rs`) MUST be registered in its declarative command schema.
- Every schema entry MUST provide:
  1. A human-readable display label (never just the raw command literal) paired with `[<id>]`.
  2. Concise helper text (at most 1 sentence unless the option is genuinely confusing), shown on hover in menus and on every stepper screen.
  3. Smart prefilled/preselected defaults wherever inferable from context.
  4. Discriminant-first ordering with `when` predicates whenever one flag/choice controls downstream options, so users are never asked irrelevant questions.
  5. Full parity with direct non-interactive command/flag invocation.
- Automated schema-completeness tests in both Rust and Lua enforce that every `Command` variant and every `:Jpr` subcommand exists in its schema with valid metadata.

### 6. Command-Position Abbreviations in `jpsyx-configs` (`home/.config/nvim/init.lua`)

- Replace the 8 bare `cnoreabbrev` calls (`W`, `Q`, `Wq`, `WQ`, `wQ`, `tb`, `open`, `dir`) in `home/.config/nvim/init.lua` with:
  ```lua
  local function cabbrev_cmd(lhs, rhs)
  	vim.keymap.set("ca", lhs, function()
  		if vim.fn.getcmdtype() == ":" and vim.fn.getcmdline() == lhs then
  			return rhs
  		end
  		return lhs
  	end, { expr = true })
  end
  ```
- Typing `:open<Space>` or `:open<CR>` expands to `OpenCurrentFile`.
- Typing `:Jpr open<Space>` has `getcmdline() == "Jpr open"` and returns `"open"` verbatim.
- Typing `/open<Space>` has `getcmdtype() == "/"` and returns `"open"` verbatim.
- Add regression assertions to `home/.config/nvim/tests/file_actions_spec.lua`.

---

## Error Handling & Edge Cases

- **No open pull requests in repo:** `:Jpr open` shows `jpr.info("no open pull requests in this repository")` (or offers switching back to manual PR number/URL input via `h` when opened from the stepper).
- **Missing or outdated `jpr-review` binary:** Checks executable status before invoking `jpr-review prs`, instructing the user to run `:Lazy build jpr-nvim`. Bumping `0.5.0` -> `0.5.1` guarantees lockstep validation across `:checkhealth jpr` and `:Lazy update`.
- **Terminal cleanup on crash/cancel (`cli-tui`):** Raw-mode RAII guard ensures terminal state is always restored even on early `Err` or panic; TUI never writes to `stdout`.
- **Long helper sentences or PR titles:** Pure renderers wrap hover-only helper text cleanly onto indented lines within the modal width (`56..92` cols in Neovim, clamped to terminal width in `cli-tui`).
- **Changing a discriminant after stepping back:** Moving back with `h`/`<Left>`/`<S-Tab>` and selecting a different branch recomputes active steps immediately and prunes stale answers from the abandoned branch before execution.

## Testing Strategy

1. **Rust (`just test` + `just lint`):**
   - `review-forge-github`: `parse_pr_list` (multiple PRs, drafts, missing author -> `"ghost"`, empty `[]`, `PR_LIST_FIELDS` coverage) and `GhForge::list_args`.
   - `cli-tui`: pure `state.rs` tests for palette hover navigation, discriminant-first branching, Back/Forward across branches, pruning stale answers, smart-default prefill, and validation errors; pure `render.rs` tests verifying `<Label>  [<id>]`, hover-only dim helper line, and `Step X of Y` header.
   - `jpr-review`: `Command::Prs` CLI parsing, schema-completeness test ensuring every clap subcommand exists in `tui_schema` with non-empty label and 1-sentence help, non-TTY fallback test ensuring bare `jpr-review` prints help without hanging, and `dependency_rule.rs` verifying `review-*` crates remain UI-free.
2. **Headless Neovim (`just test-lua`):**
   - `tests/lua/tui_schema_spec.lua`: schema completeness across all 14 `:Jpr` subcommands, discriminant branching, smart defaults, and stale-branch answer pruning.
   - `tests/lua/tui_render_spec.lua`: palette layout (`▸ <Label>  [<id>]` + hover-only dim helper line), stepper header (`Step X of Y`), and text wrapping.
   - `tests/lua/tui_wizard_spec.lua`: interactive modal tests for `j`/`k`/`<Down>`/`<Up>`, `h`/`<Left>`/`<S-Tab>` Back, `l`/`<Right>`/`<Tab>`/`<CR>` Forward/Confirm, Insert-mode text input with prefilled smart default, `q`/`<Esc>` cancel, bare `:Jpr` palette -> `open` -> async PR picker via `fake_engine.lua`, and `:Jpr open` direct PR picker + `h` back to manual PR/URL step.
3. **`jpsyx-configs` (`file_actions_spec.lua`):**
   - Verify `:open ` expands to `:OpenCurrentFile `, `:dir ` expands to `:OpenCurrentDirectory `, and `:Jpr open ` stays `:Jpr open `.
