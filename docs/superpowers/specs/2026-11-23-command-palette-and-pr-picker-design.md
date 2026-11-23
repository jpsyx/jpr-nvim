# `:Jpr` Command Palette, `:Jpr open` PR Picker & Cmdline Abbreviation Fix

## Goal

Fix two UX friction points discovered during real Neovim usage:

1. **Command-line abbreviation collision (`jpsyx-configs`):** Typing `:Jpr open<Space>` in Neovim expands `open` to `OpenCurrentFile` because `home/.config/nvim/init.lua` defines an unconditional `cnoreabbrev open OpenCurrentFile`. Command-line abbreviations must expand **only** when typed in the command position of `:` (never as subcommand arguments or inside `/` / `?` search prompts).
2. **Interactive `:Jpr` Command Palette and `:Jpr open` PR Picker (`jpr-nvim`):**
   - Running bare `:Jpr` (with no arguments) must open a centered, normal-mode floating **`:Jpr` Command Palette** modal listing every subcommand with a human-readable display label, its literal subcommand ID in brackets (`[open]`), and a dim 1-sentence helper description rendered dynamically on a second line underneath **only** the currently hovered/selected command.
   - Running `:Jpr open` (with no PR argument, or choosing `Open Pull Request  [open]` from the bare `:Jpr` palette) must fetch open pull requests for the current repository via the `jpr-review` engine and present them in the same floating normal-mode picker modal (`j`/`k` and `<Up>`/`<Down>` to navigate, `<CR>` to open, `q`/`<Esc>` to close).

## Scope

1. **`jpr-nvim` repository (`0.5.1`):**
   - Bump `jpr-review` crate workspace version (`Cargo.toml`) and `M.VERSION` (`lua/jpr/init.lua`) to `0.5.1` so `:Lazy update` rebuilds and lockstep version checks validate the new `prs` subcommand.
   - Rust engine (`review-model`, `review-forge-github`, `jpr-review`): add `PullRequestSummary` + `GhForge::open_pull_requests(limit)` + `jpr-review prs [--repo OWNER/NAME] [--limit N]` outputting JSON array of open PR summaries on stdout.
   - Reusable floating normal-mode picker view (`lua/jpr/views/picker.lua` + pure layout builder `lua/jpr/render/picker.lua`) supporting hover-only second-line dim helper text.
   - Subcommand metadata catalog (`M.subcommand_specs` in `lua/jpr/init.lua`) with human-readable display labels, command IDs, and 1-sentence helper descriptions for all 14 subcommands.
   - Bare `:Jpr` (`nargs = "*"` in `plugin/jpr.lua`) opening the `:Jpr` Command Palette modal, and `:Jpr open` (with no argument) asynchronously running `jpr-review prs` and opening the PR Picker modal.
   - Unit and headless Neovim integration tests covering Rust `gh pr list` JSON parsing, CLI surface, picker rendering (hover-only helper line, highlights, cursor row mapping), command palette dispatch, and `:Jpr open` PR selection.
2. **`jpsyx-configs` repository (post-merge & publish):**
   - Replace bare `cnoreabbrev` definitions in `home/.config/nvim/init.lua` (`W`, `Q`, `Wq`, `WQ`, `wQ`, `tb`, `open`, `dir`) with a command-position `<expr>` helper so `:open` expands to `OpenCurrentFile` while `:Jpr open` and `/open` stay untouched.
   - Add regression assertions in `home/.config/nvim/tests/file_actions_spec.lua`.
   - Update `home/.config/nvim/commands.yaml` (bare `:Jpr` palette + picker scope shortcuts), run `:Lazy! update jpr-nvim` so `lazy.nvim` pulls `0.5.1` and compiles the updated `jpr-review` binary, and capture the updated `lazy-lock.json`.

---

## Architecture & Components

### 1. Rust Engine: `jpr-review prs` (`review-model`, `review-forge-github`, `jpr-review`)

Keeping GitHub CLI execution and JSON parsing inside the Rust engine preserves `jpr-nvim`'s architectural boundary (`Gh` 30-second timeout, structured error formatting, zero shell/JSON parsing duplication in Lua).

- **`crates/review-model/src/lib.rs` — `PullRequestSummary`:**
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
  - `parse_pr_list(stdout: &str) -> Result<Vec<PullRequestSummary>>`: parses `gh pr list` JSON output (defaulting missing `author.login` to `"ghost"` so deleted GitHub accounts never break listing).
  - `GhForge::list_args(&self, limit: u32) -> Vec<String>`: builds `["pr", "list", "--state", "open", "--limit", "<limit>", "--json", PR_LIST_FIELDS]` plus optional `["--repo", repo]`.
  - `GhForge::open_pull_requests(&self, limit: u32) -> Result<Vec<PullRequestSummary>>`.
- **`crates/jpr-review/src/cli.rs` & `commands/prs.rs`:**
  - New `Command::Prs { repo: Option<String>, #[arg(long, default_value_t = 50)] limit: u32 }`.
  - Runs `GhForge::new(cwd, repo).open_pull_requests(limit)` and prints a single compact JSON line (`serde_json::to_string(&summaries)`) to stdout.

### 2. Pure Picker Layout (`lua/jpr/render/picker.lua`) & Floating Modal (`lua/jpr/views/picker.lua`)

A single self-contained normal-mode picker powers both the bare `:Jpr` command palette and the `:Jpr open` pull request picker, with zero external plugin dependencies (`telescope`, `dressing`, `fzf` not required).

- **Item contract:**
  Each item passed to `picker.open(opts)` has:
  - `label` (`string`, required): human-readable primary text (e.g. `"Open Pull Request"`, or `"#42  Fix token refresh"`).
  - `badge` (`string?`): bracketed suffix rendered on the primary row in `JprMuted` (e.g. `"[open]"`, or `"[draft]"` / `"[active]"`).
  - `detail` (`string?`): 1-sentence helper/metadata line rendered in `JprMuted` (`Comment` highlight) **only** on the line immediately below the currently selected item.
  - `dimmed` (`boolean?`): when `true` (e.g. session-only commands when no review session is active in the current tab), renders `label` in `JprMuted` instead of normal text while still allowing selection or showing why.
  - `value` (`any`): payload passed to `opts.on_choice(item)`.

- **Rendered buffer layout (`lua/jpr/render/picker.lua`):**
  ```text
  ▸ Open Pull Request  [open]
      Pick an open pull request in this repository and start a review session.
    Sync with GitHub  [sync]
    Toggle Diff View  [toggle]
    ...

  [j/k] move  [Enter] select  [q/Esc] close
  ```
  - Selected item prefixes `"▸ "` (`JprTitle`); unselected items prefix `"  "`.
  - Primary row: `<prefix><label>` + optional `"  " .. badge` (`badge` highlighted with `JprMuted`).
  - Hover detail row (emitted **only** for `selected_index` when `item.detail` is non-empty): `"    " .. item.detail`, highlighted end-to-end with `JprMuted`. If `item.detail` exceeds inner modal width, wraps cleanly onto indented continuation lines (`"    ..."`) so helper sentences are never clipped mid-word.
  - Blank separator line + footer `"[j/k] move  [Enter] select  [q/Esc] close"` in `JprMuted`.
  - Pure `build(items, selected_index, max_width)` returns `{ lines, highlights, cursor_line, item_for_line }` so mouse clicks or cursor jumps also resolve cleanly to an item index.

- **Floating window & keymaps (`lua/jpr/views/picker.lua`):**
  - Opens a centered `border = "rounded"` floating window (`title = " " .. opts.title .. " "`, `title_pos = "center"`, `style = "minimal"`, `cursorline = true`, `modifiable = false`, `bufhidden = "wipe"`, filetype `"jpr-picker"`).
  - Enters Normal mode (`vim.cmd("stopinsert")` if needed) and locks the cursor to `rendered.cursor_line` (`col = 0`).
  - Buffer-local normal-mode mappings (`nowait = true`, `silent = true`):
    - `j` / `<Down>`: select next item (wraps from last to first), re-render hover detail, place cursor on the newly selected item's primary line.
    - `k` / `<Up>`: select previous item (wraps from first to last), re-render hover detail, place cursor on the newly selected item's primary line.
    - `gg` / `<Home>`: select first item.
    - `G` / `<End>`: select last item.
    - `<CR>`: close modal and invoke `opts.on_choice(selected_item)`.
    - `q` / `<Esc>`: close modal and invoke optional `opts.on_cancel()`.
  - Also attaches a `CursorMoved` buffer autocmd so if the user clicks a row with the mouse, `selected_index` updates to `item_for_line[cursor_row]` and re-paints the hover line smoothly.
  - Singleton guard: opening a new picker closes any previously open `jpr` picker window cleanly.

### 3. Bare `:Jpr` Command Palette (`lua/jpr/init.lua` & `plugin/jpr.lua`)

- **`plugin/jpr.lua`:** change `nargs = "+"` to `nargs = "*"` so bare `:Jpr` is accepted by Neovim without `E471: Argument required`.
- **`M.subcommand_specs` (`lua/jpr/init.lua`):** single source of truth from which `M.subcommands` (for cmdline `<Tab>` completion) and the `:Jpr` Command Palette items are derived:

  | Display Label | `[id]` | 1-Sentence Hover Helper Text | Needs Active Session? |
  | --- | --- | --- | --- |
  | Open Pull Request | `[open]` | Pick an open pull request in this repository and start a review session. | No |
  | Sync with GitHub | `[sync]` | Fetch the latest pull request commits, files, and review threads from GitHub. | Yes |
  | Toggle Diff View | `[toggle]` | Switch the current file review between unified and side-by-side split diff views. | Yes |
  | Open Stream View | `[stream]` | View all changed files stacked continuously in a single scrollable diff stream. | Yes |
  | Add Line Comment | `[comment]` | Draft a new review comment on the current cursor line or visual selection. | Yes |
  | Suggest Code Change | `[suggest]` | Draft a review comment pre-filled with a GitHub suggestion block for the current line. | Yes |
  | Expand Diff Context | `[expand]` | Reveal additional unchanged surrounding lines around the current diff hunk. | Yes |
  | Open PR Conversation | `[conversation]` | Read and post top-level pull request issue comments in the main review window. | Yes |
  | Submit Review | `[submit]` | Preview pending draft comments and submit your review decision to GitHub. | Yes |
  | Push Head Branch | `[push]` | Push local commits on the checked-out pull request branch back to GitHub. | Yes |
  | Toggle Coding Agent | `[agent]` | Open or hide the interactive coding-agent terminal split for this pull request. | Yes |
  | Send Local Threads to Agent | `[send]` | Prompt the coding agent to address pending local review threads in this worktree. | Yes |
  | Run Agent Pre-Pass | `[prepass]` | Ask the coding agent to scan the pull request diff and post local pre-pass findings. | Yes |
  | Close Review Session | `[close]` | Close the current tab's pull request review session and stop its background engine. | Yes |

- **Behavior when bare `:Jpr` runs (`#fargs == 0`):**
  - Checks whether `require("jpr.session").current()` is non-nil; commands with `requires_session = true` set `dimmed = true` when no session is open in the current tab (so `Open Pull Request  [open]` stands out immediately when starting fresh, while all 14 commands remain inspectable and selectable).
  - Selecting `open` triggers `session.open_picker()` (the `:Jpr open` PR picker flow).
  - Selecting any other subcommand dispatches `M.command({ spec.name }, cmd_opts)`.

### 4. `:Jpr open` Pull Request Picker (`lua/jpr/session/init.lua` & `lua/jpr/init.lua`)

- **Behavior when `:Jpr open` runs with no argument (`fargs[1] == "open"` and `fargs[2] == nil`):**
  - Verifies the `jpr-review` binary is executable (same `:Lazy build jpr-nvim` hint if missing).
  - Emits `jpr.info("loading open pull requests…")` and runs `{ binary_path, "prs" }` asynchronously via `vim.system` in `vim.fn.getcwd()`.
  - On non-zero exit (e.g. not in a GitHub repo or `gh` unauthenticated), surfaces stderr cleanly via `jpr.error(...)`.
  - On empty JSON array (`#prs == 0`), notifies `jpr.info("no open pull requests in this repository")`.
  - Otherwise opens `picker.open({ title = "Open Pull Request", items = ... })`:
    - `label`: `("#%d  %s"):format(pr.number, pr.title)`
    - `badge`: combinable bracket tags — `"[open]"` if already open in a Neovim tab (`M.by_tab`), `"[draft]"` if `pr.isDraft` is true (e.g. `"[draft] [open]"`).
    - `detail` (hover-only second line): `("@%s · %s · updated %s"):format(pr.author, pr.headRef, format_date(pr.updatedAt))` where `format_date` turns ISO-8601 `"2026-11-23T15:04:05Z"` into `"2026-11-23"`.
    - `on_choice`: calls `M.open(pr.number)`.
- **Invalid explicit argument (`:Jpr open not-a-pr`):**
  - When `fargs[2]` **is** provided (`fargs[2] ~= nil` and `fargs[2] ~= ""`) and `M.parse_pr_arg(fargs[2])` returns `nil`, keeps returning an explicit error (`invalid pull request %q; expected a PR number, #number, or pull request URL`) rather than silently ignoring a mistyped argument.

### 5. Command-Position Abbreviations in `jpsyx-configs` (`home/.config/nvim/init.lua`)

- Define a small local helper in `home/.config/nvim/init.lua`:
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
  - Using `vim.keymap.set("ca", lhs, fn, { expr = true })` checks `getcmdtype() == ":"` and `getcmdline() == lhs` at the exact moment the user presses `<Space>` or `<CR>` after typing `:open`.
  - Typing `:open<Space>` or `:open<CR>` has `getcmdline() == "open"`, so it expands to `OpenCurrentFile`.
  - Typing `:Jpr open<Space>` has `getcmdline() == "Jpr open"`, so it returns `"open"` unchanged!
  - Typing `/open<Space>` has `getcmdtype() == "/"`, so it returns `"open"` unchanged!
- Apply `cabbrev_cmd` to all 8 command-line abbreviations in `init.lua`: `W`, `Q`, `Wq`, `WQ`, `wQ`, `tb`, `open`, and `dir`.
- Update `home/.config/nvim/tests/file_actions_spec.lua` to verify both:
  1. `:open` still expands to `OpenCurrentFile` and `:dir` still expands to `OpenCurrentDirectory` in command position.
  2. `:Jpr open ` does **not** expand `open` to `OpenCurrentFile`.

---

## Error Handling & Edge Cases

- **Engine binary missing or outdated (`0.5.0` vs `0.5.1`):**
  - Bumping `M.VERSION` and `Cargo.toml` to `0.5.1` ensures `:checkhealth jpr`, handshake checks, and `:Lazy update` keep Lua and the `jpr-review` binary in lockstep. If someone runs an older binary that lacks `prs`, `vim.system` exits non-zero and surfaces the error cleanly.
- **Long helper descriptions or PR titles:**
  - `render/picker.lua` computes modal width clamped between `56` and `math.min(92, vim.o.columns - 6)` and wraps the selected item's `detail` helper text across indented lines (`"    "`) so the full 1-sentence explanation is always readable without horizontal scrolling.
- **Window resize or rapid `j`/`k` navigation:**
  - Dynamic height adjusts smoothly by `+1` (or wrapped detail height) as items with varying detail lengths are hovered, clamped to `vim.o.lines - 4`.

## Testing Strategy

1. **Rust unit tests (`cargo test --workspace`):**
   - `review-forge-github`: `parse_pr_list` with multiple PRs, draft PRs, missing `author` (`null` -> `"ghost"`), empty `[]`, and `PR_LIST_FIELDS` field-coverage check; `GhForge::list_args` with and without `--repo`.
   - `jpr-review`: CLI parsing for `jpr-review prs`, `--repo`, and `--limit`.
2. **Headless Neovim Lua specs (`just test-lua`):**
   - `tests/lua/picker_spec.lua`:
     - Pure `render/picker.lua` test verifying non-selected items render `<label>  [<id>]` on 1 line and **only** `selected_index` renders the indented dim `JprMuted` helper second line.
     - Interactive `views/picker.lua` test verifying `j`, `k`, `<Down>`, `<Up>`, `G`, `gg` move selection + update hover helper row + keep cursor on the active item's primary line, `<CR>` invokes `on_choice`, and `q`/`<Esc>` closes without invoking `on_choice`.
   - `tests/lua/palette_and_open_picker_spec.lua` (or extending `session_spec.lua` + `fake_engine.lua`):
     - Bare `:Jpr` opens the 14-item command palette with human-readable labels, `[id]` badges, and hover-only helper text; pressing `<CR>` on `open` transitions into the PR picker.
     - `:Jpr open` (no args) invokes `prs` on `fake_engine.lua`, renders the PR picker modal, navigates with `j`, and pressing `<CR>` opens the selected PR session.
     - `:Jpr open invalid-arg` still reports a clear invalid-argument error.
3. **`jpsyx-configs` Neovim spec:**
   - Run `home/.config/nvim/tests/file_actions_spec.lua` in headless Neovim verifying `:open<Space>` -> `:OpenCurrentFile ` and `:Jpr open<Space>` -> `:Jpr open `.
