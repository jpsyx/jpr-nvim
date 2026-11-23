# Interactive Command Palette, Schema-to-TUI Engine & Cmdline Abbreviation Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable declarative command-schema-to-TUI engine across both `jpr-nvim` (Lua) and `jpr-review` (Rust), add `jpr-review prs`, wire bare `:Jpr` as a Command Palette and `:Jpr open` as an open-PR stepper picker, codify the interactive command invariant in `AGENTS.md`, and fix command-position cmdline abbreviations in `jpsyx-configs`.

**Architecture:** Both the Rust crate `crates/cli-tui` (non-`review-*`, keeping `review-*` crates UI-free per `dependency_rule.rs`) and the Lua package `lua/jpr/tui/` implement the same declarative schema model (`CommandSpec`, `StepSpec`, `when` discriminant predicates, smart defaults, pure state/layout builders). Menu steps run in Normal mode (`j`/`k`/`<Down>`/`<Up>`, `h`/`<Left>`/`<S-Tab>` Back, `l`/`<Right>`/`<Tab>`/`<CR>` Confirm/Forward, `q`/`<Esc>` Cancel) with hover-only dim 1-sentence helper text on a second indented line; text input steps start in Insert mode prefilled with smart defaults (`<S-Tab>` Back, `<Tab>`/`<CR>` Confirm/Forward, `<Esc>` Normal/Cancel).

**Tech Stack:** Rust (edition 2024, `clap`, `serde_json`, `anyhow`, `crossterm`), Lua (Neovim 0.11+ floating windows + extmarks + `vim.system`), headless Neovim test runner (`./scripts/test-lua.sh`), `just check`.

---

## File Map

| Path | Responsibility |
| --- | --- |
| `Cargo.toml` | Bump workspace version `0.5.0` -> `0.5.1`; add `crossterm` and `cli-tui` workspace dependencies |
| `crates/review-model/src/pr.rs`, `lib.rs` | `PullRequestSummary` domain model |
| `crates/review-forge-github/src/pr.rs`, `lib.rs` | `PR_LIST_FIELDS`, `parse_pr_list`, `GhForge::list_args`, `GhForge::open_pull_requests` |
| `crates/cli-tui/Cargo.toml`, `src/{lib,schema,state,render,runner}.rs` | Reusable Rust schema-to-TUI crate (pure state machine, pure ANSI renderer, `crossterm` stderr TTY runner) |
| `crates/jpr-review/Cargo.toml`, `src/{lib,main,cli,tui_schema}.rs`, `src/commands/{mod,prs}.rs` | `Command::Prs`, declarative `tui_schema` for all 8 CLI commands, bare-invocation TTY palette / non-TTY help, TTY missing-option steppers |
| `lua/jpr/tui/schema.lua` | Pure Lua schema validation, discriminant-first step resolution, smart defaults, stale-answer pruning |
| `lua/jpr/tui/render.lua` | Pure Lua palette & stepper layout + extmarks (hover-only dim 1-sentence helper line, step counter, word wrapping) |
| `lua/jpr/tui/wizard.lua` | Floating rounded modal controller (Normal menu steps, Insert text steps via `virt_lines_above`, async loading, Back/Forward, `CursorMoved`) |
| `lua/jpr/commands/schema.lua` | Single source of truth for all 14 `:Jpr` subcommands (labels, `[id]`, 1-sentence helper text, discriminants, smart defaults) |
| `plugin/jpr.lua`, `lua/jpr/init.lua`, `lua/jpr/session/{init,commands}.lua`, `lua/jpr/agent.lua` | `nargs = "*"`, `M.VERSION = "0.5.1"`, bare `:Jpr` palette, `:Jpr open` PR picker, direct optional args (`toggle`, `comment`, `agent`) |
| `tests/lua/tui_{schema,render,wizard}_spec.lua`, `tests/lua/{command,session_lifecycle,build_and_binary}_spec.lua` | Headless Neovim unit & integration tests |
| `AGENTS.md`, `docs/rules/cli-{ux,rust}.md`, `docs/{architecture,protocol,decisions}.md`, `README.md` | Permanent interactive schema-to-TUI invariant + updated architecture/version/usage docs |
| `jpsyx-configs/home/.config/nvim/{init.lua,tests/file_actions_spec.lua,commands.yaml,docs/CHANGELOG.md,lazy-lock.json}` | Command-position `<expr>` abbreviation fix + `:Lazy! update jpr-nvim` (post-merge Task 9) |

---

### Task 1: Add `PullRequestSummary`, `GhForge::open_pull_requests`, and `jpr-review prs`

**Files:**
- Modify: `Cargo.toml`
- Modify: `crates/review-model/src/pr.rs`
- Modify: `crates/review-model/src/lib.rs`
- Modify: `crates/review-forge-github/src/pr.rs`
- Modify: `crates/review-forge-github/src/lib.rs`
- Create: `crates/jpr-review/src/commands/prs.rs`
- Modify: `crates/jpr-review/src/cli.rs`
- Modify: `crates/jpr-review/src/commands/mod.rs`

- [ ] **Step 1: Write failing Rust tests for `PullRequestSummary` and `parse_pr_list` / `GhForge::list_args`**

In `crates/review-model/src/pr.rs`, add to `mod tests`:
```rust
    #[test]
    fn pull_request_summary_serializes_with_camel_case_keys() {
        let summary = PullRequestSummary {
            number: 42,
            title: "Add OAuth flow".into(),
            author: "alice".into(),
            head_ref: "feat/oauth".into(),
            is_draft: true,
            updated_at: "2026-11-23T15:00:00Z".into(),
        };
        let json = serde_json::to_value(&summary).unwrap();
        assert_eq!(json["number"], 42);
        assert_eq!(json["title"], "Add OAuth flow");
        assert_eq!(json["author"], "alice");
        assert_eq!(json["headRef"], "feat/oauth");
        assert_eq!(json["isDraft"], true);
        assert_eq!(json["updatedAt"], "2026-11-23T15:00:00Z");
        let decoded: PullRequestSummary = serde_json::from_value(json).unwrap();
        assert_eq!(decoded, summary);
    }
```

In `crates/review-forge-github/src/pr.rs`, add to `mod tests`:
```rust
    const LIST_JSON: &str = r#"[
        {"number":42,"title":"Add OAuth","author":{"login":"alice"},"headRefName":"feat/oauth","isDraft":false,"updatedAt":"2026-11-23T15:04:05Z"},
        {"number":43,"title":"WIP refactor","author":null,"headRefName":"chore/wip","isDraft":true,"updatedAt":"2026-11-22T10:00:00Z"}
    ]"#;

    #[test]
    fn pr_list_fields_covers_every_key_read_by_parse_pr_list() {
        let allowed_keys: std::collections::BTreeSet<&str> = PR_LIST_FIELDS.split(',').collect();
        let mut parsed: Vec<Value> = serde_json::from_str(LIST_JSON).unwrap();
        for item in &mut parsed {
            item.as_object_mut()
                .unwrap()
                .retain(|key, _| allowed_keys.contains(key.as_str()));
        }
        let summaries = parse_pr_list(&serde_json::to_string(&parsed).unwrap()).unwrap();
        assert_eq!(summaries.len(), 2);
        assert_eq!(summaries[0].number, 42);
        assert_eq!(summaries[0].author, "alice");
        assert_eq!(summaries[1].author, "ghost");
        assert!(summaries[1].is_draft);
    }

    #[test]
    fn parses_empty_pr_list() {
        assert_eq!(parse_pr_list("[]").unwrap(), Vec::new());
    }
```

In `crates/review-forge-github/src/lib.rs`, add to `mod tests` (or create `#[cfg(test)] mod tests` at the bottom if none exists):
```rust
    #[test]
    fn list_args_includes_state_limit_fields_and_optional_repo() {
        let without_repo = GhForge::new(PathBuf::from("."), None);
        assert_eq!(
            without_repo.list_args(50),
            vec![
                "pr",
                "list",
                "--state",
                "open",
                "--limit",
                "50",
                "--json",
                pr::PR_LIST_FIELDS,
            ]
        );
        let with_repo = GhForge::new(PathBuf::from("."), Some("octo/widgets".into()));
        assert_eq!(
            with_repo.list_args(20),
            vec![
                "pr",
                "list",
                "--state",
                "open",
                "--limit",
                "20",
                "--json",
                pr::PR_LIST_FIELDS,
                "--repo",
                "octo/widgets",
            ]
        );
    }
```

In `crates/jpr-review/src/cli.rs`, add to `mod tests`:
```rust
    #[test]
    fn prs_uses_default_limit_and_optional_repo() {
        let bare = Cli::try_parse_from(["jpr-review", "prs"]).unwrap();
        assert_eq!(
            bare.command,
            Command::Prs {
                repo: None,
                limit: 50,
            }
        );
        let filtered =
            Cli::try_parse_from(["jpr-review", "prs", "--repo", "octo/widgets", "--limit", "15"])
                .unwrap();
        assert_eq!(
            filtered.command,
            Command::Prs {
                repo: Some("octo/widgets".into()),
                limit: 15,
            }
        );
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p review-model -p review-forge-github -p jpr-review`
Expected: FAIL with missing `PullRequestSummary`, `PR_LIST_FIELDS`, `parse_pr_list`, `list_args`, `Command::Prs`.

- [ ] **Step 3: Implement `PullRequestSummary`, `parse_pr_list`, `GhForge::open_pull_requests`, and `Command::Prs`**

1. Bump `Cargo.toml` workspace version to `"0.5.1"` (in `[workspace.package]`).
2. In `crates/review-model/src/pr.rs`, define:
```rust
/// Compact metadata for one open pull request, used by interactive pickers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequestSummary {
    /// The pull request number within its repository.
    pub number: u64,
    /// The title, as the author wrote it.
    pub title: String,
    /// The author's login (or `"ghost"` when the account was deleted).
    pub author: String,
    /// The head branch name, e.g. `feat/oauth`.
    pub head_ref: String,
    /// Whether the pull request is marked as a draft.
    pub is_draft: bool,
    /// ISO-8601 timestamp of the latest pull request update.
    pub updated_at: String,
}
```
And re-export `PullRequestSummary` in `crates/review-model/src/lib.rs`:
```rust
pub use pr::{ChangedFile, PullRequest, PullRequestSummary, ViewedState};
```
3. In `crates/review-forge-github/src/pr.rs`, import `PullRequestSummary` and add:
```rust
/// The fields `gh pr list --json` must report for open PR summaries.
pub const PR_LIST_FIELDS: &str = "number,title,author,headRefName,isDraft,updatedAt";

/// Parses `gh pr list --json PR_LIST_FIELDS` into compact pull request summaries.
pub fn parse_pr_list(stdout: &str) -> Result<Vec<PullRequestSummary>> {
    let items: Vec<Value> =
        serde_json::from_str(stdout).context("reading gh pr list output")?;
    items.iter().map(parse_pr_summary).collect()
}

fn parse_pr_summary(value: &Value) -> Result<PullRequestSummary> {
    let number = value["number"]
        .as_u64()
        .context("gh pr list item did not report /number")?;
    let title = value["title"]
        .as_str()
        .map(str::to_owned)
        .context("gh pr list item did not report /title")?;
    let head_ref = value["headRefName"]
        .as_str()
        .map(str::to_owned)
        .context("gh pr list item did not report /headRefName")?;
    let is_draft = value["isDraft"]
        .as_bool()
        .context("gh pr list item did not report /isDraft")?;
    let updated_at = value["updatedAt"]
        .as_str()
        .map(str::to_owned)
        .context("gh pr list item did not report /updatedAt")?;
    let author = value
        .pointer("/author/login")
        .and_then(Value::as_str)
        .filter(|login| !login.is_empty())
        .unwrap_or("ghost")
        .to_owned();
    Ok(PullRequestSummary {
        number,
        title,
        author,
        head_ref,
        is_draft,
        updated_at,
    })
}
```
4. In `crates/review-forge-github/src/lib.rs`, add to `impl GhForge`:
```rust
    /// The `gh pr list` arguments for listing open pull requests.
    #[must_use]
    pub fn list_args(&self, limit: u32) -> Vec<String> {
        let mut args = vec![
            "pr".to_owned(),
            "list".to_owned(),
            "--state".to_owned(),
            "open".to_owned(),
            "--limit".to_owned(),
            limit.to_string(),
            "--json".to_owned(),
            pr::PR_LIST_FIELDS.to_owned(),
        ];
        if let Some(repo) = &self.repo {
            args.push("--repo".to_owned());
            args.push(repo.clone());
        }
        args
    }

    /// Lists up to `limit` open pull requests in the inferred or pinned repository.
    pub fn open_pull_requests(&self, limit: u32) -> Result<Vec<review_model::PullRequestSummary>> {
        let args = self.list_args(limit);
        let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
        pr::parse_pr_list(&self.gh.run(&arg_refs, None)?)
    }
```
5. Create `crates/jpr-review/src/commands/prs.rs`:
```rust
use std::env;

use anyhow::{Context, Result};
use review_forge_github::GhForge;

use crate::theme::Theme;

/// Runs `jpr-review prs`: lists open pull requests as a JSON array on stdout.
pub fn run(repo: Option<&str>, limit: u32, theme: Theme) -> Result<()> {
    let cwd = env::current_dir().context("reading the current directory")?;
    if let Some(expected_repo) = repo {
        let _ = super::parse_repo(expected_repo)?;
    }
    super::narrate(theme, "Listing open pull requests...");
    let summaries = GhForge::new(cwd, repo.map(str::to_owned)).open_pull_requests(limit)?;
    println!(
        "{}",
        serde_json::to_string(&summaries).context("serializing open pull requests")?
    );
    Ok(())
}
```
6. Wire `Command::Prs` in `crates/jpr-review/src/cli.rs` and `pub mod prs;` + dispatch arm in `crates/jpr-review/src/commands/mod.rs`.

- [ ] **Step 4: Run Rust tests and clippy**

Run: `cargo test -p review-model -p review-forge-github -p jpr-review && cargo clippy --workspace --all-targets --all-features -- -D warnings`
Expected: PASS, 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml Cargo.lock crates/review-model crates/review-forge-github crates/jpr-review
git commit -m "feat(engine): add jpr-review prs subcommand and bump workspace to 0.5.1"
```

---

### Task 2: Create Reusable `crates/cli-tui` Schema-to-TUI Crate (Schema + State Machine + Pure Renderer + Runner)

**Files:**
- Modify: `Cargo.toml` (add `crossterm = "0.28"` and `cli-tui = { path = "crates/cli-tui" }` to `[workspace.dependencies]`)
- Create: `crates/cli-tui/Cargo.toml`
- Create: `crates/cli-tui/src/lib.rs`
- Create: `crates/cli-tui/src/schema.rs`
- Create: `crates/cli-tui/src/state.rs`
- Create: `crates/cli-tui/src/render.rs`
- Create: `crates/cli-tui/src/runner.rs`

- [ ] **Step 1: Scaffold `crates/cli-tui/Cargo.toml` and write failing unit tests in `schema.rs`, `state.rs`, and `render.rs`**

`crates/cli-tui/Cargo.toml`:
```toml
[package]
name = "cli-tui"
description = "Reusable declarative command-schema-to-TUI palette and stepper library."
version.workspace = true
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[dependencies]
anyhow.workspace = true
crossterm.workspace = true

[lints]
workspace = true
```

Add `crossterm = "0.28"` and `cli-tui = { path = "crates/cli-tui" }` to `[workspace.dependencies]` in root `Cargo.toml`.

Create `crates/cli-tui/src/schema.rs` with types:
- `Answers = BTreeMap<String, String>`
- `SelectOption { pub value: String, pub label: String, pub badge: Option<String>, pub help: Option<String> }`
- `StepKind`:
  - `Select(Vec<SelectOption>)`
  - `DynamicSelect(Arc<dyn Fn(&Answers) -> anyhow::Result<Vec<SelectOption>> + Send + Sync>)`
  - `Toggle { yes_label: String, yes_help: String, no_label: String, no_help: String }`
  - `Text { placeholder: Option<String> }`
- `StepSpec`:
  - `pub id: String`
  - `pub label: String`
  - `pub help: String`
  - `pub kind: StepKind`
  - `pub default_value: Option<Arc<dyn Fn(&Answers) -> String + Send + Sync>>`
  - `pub when: Option<Arc<dyn Fn(&Answers) -> bool + Send + Sync>>`
  - `pub validate: Option<Arc<dyn Fn(&str, &Answers) -> Result<(), String> + Send + Sync>>`
- `CommandSpec`:
  - `pub id: String`
  - `pub label: String`
  - `pub help: String`
  - `pub steps: Vec<StepSpec>`
- Pure functions:
  - `validate_command_specs(commands: &[CommandSpec]) -> Result<(), String>` (verifies non-empty `id`, `label`, `help`, unique `id`, valid step IDs)
  - `resolve_active_steps<'a>(command: &'a CommandSpec, answers: &Answers) -> Vec<&'a StepSpec>`
  - `prune_inactive_answers(command: &CommandSpec, answers: &Answers) -> Answers`

Write unit tests in `crates/cli-tui/src/state.rs` covering:
1. `PaletteState`: `Down` / `Up` wrap navigation, `Confirm` returns `PaletteAction::Selected(idx)`, `Cancel` returns `PaletteAction::Cancelled`.
2. `WizardState`:
   - Discriminant-first branching: when step 1 (`target_mode`) is `"socket"`, only step 2a (`socket`) is active (`Step 1 of 2` -> `Step 2 of 2`). Stepping Back (`KeyAction::Back`) and changing `target_mode` to `"pr"` dynamically activates steps 2b (`pr`) and 3 (`repo`) (`Step 2 of 3`), and completing prunes the stale `"socket"` answer!
   - Smart default prefill on `Text` and `Select` steps.
   - Validation error on invalid text input keeps focus on the current step and populates `validation_error`.
   - Pressing `Back` on Step 1 when `can_return_to_palette == true` emits `WizardStepOutcome::BackToPalette`.

Write unit tests in `crates/cli-tui/src/render.rs` covering:
1. `render_palette`: every command shows `<Label>  [<id>]`, selected row starts with `▸ `, and **only** the selected command's 1-sentence `help` appears on the indented line underneath (unselected commands' `help` strings do NOT appear in the rendered output!).
2. `render_wizard`: header shows `Step 2 of 3 · <Label>`, shows the step's 1-sentence helper text, shows hover-only option helper text on `Select`/`Toggle` steps, and renders prefilled text cursor on `Text` steps.
3. Plain mode (`color = false`) emits zero `\x1b[` escape sequences.

- [ ] **Step 2: Run tests to verify they fail before implementation**

Run: `cargo test -p cli-tui`
Expected: FAIL (unimplemented stubs / compile errors).

- [ ] **Step 3: Implement `schema.rs`, `state.rs`, `render.rs`, `runner.rs`, and `lib.rs`**

Key implementation rules for `crates/cli-tui/src/runner.rs`:
- Keep every function <= 45 lines (per `AGENTS.md`).
- Guard at entry:
  ```rust
  pub fn is_interactive_terminal() -> bool {
      std::io::stdin().is_terminal() && std::io::stderr().is_terminal()
  }
  ```
- RAII `RawModeGuard`: enables raw mode and hides cursor in `new()`, restores cursor, clears rendered lines, and disables raw mode in `Drop`.
- Renders exclusively to `std::io::stderr()` (never `stdout`).
- Translates `crossterm::event::KeyEvent` into `KeyAction`:
  - Menu/Toggle steps: `j`/`Down` -> `Down`, `k`/`Up` -> `Up`, `h`/`Left`/`BackTab` -> `Back`, `l`/`Right`/`Tab`/`Enter` -> `Confirm`, `g`/`Home` -> `First`, `G`/`End` -> `Last`, `q`/`Esc`/`Ctrl+C` -> `Cancel`.
  - Text steps: `BackTab` -> `Back`, `Tab`/`Enter` -> `Confirm`, `Left`/`Right`/`Home`/`End`/`Backspace`/`Delete`/`Char(c)` -> text editing, `Esc`/`Ctrl+C` -> `Cancel`.
- `run_palette(title, commands)` loops between `PaletteState` and `WizardState` so pressing Back on Step 1 of a selected command returns cleanly to the Command Palette with that command still highlighted!
- `run_command(command, initial_answers)` jumps straight to the first unanswered active step (or runs immediately if all active steps are already answered or `steps` is empty).

- [ ] **Step 4: Run tests, clippy, and `dependency_rule` test**

Run: `cargo test -p cli-tui && cargo test -p jpr-review --test dependency_rule && cargo clippy --workspace --all-targets --all-features -- -D warnings`
Expected: PASS, 0 warnings, and `generic_crates_stay_frontend_neutral` passes (proving `review-*` crates have zero dependency on `cli-tui` or `crossterm`).

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml Cargo.lock crates/cli-tui
git commit -m "feat(cli-tui): add reusable declarative schema-to-TUI crate"
```

---

### Task 3: Wire `crates/jpr-review` CLI Commands to `cli-tui` Schema & TTY Palette

**Files:**
- Modify: `crates/jpr-review/Cargo.toml`
- Create: `crates/jpr-review/src/tui_schema.rs`
- Modify: `crates/jpr-review/src/lib.rs`
- Modify: `crates/jpr-review/src/cli.rs`
- Modify: `crates/jpr-review/src/commands/mod.rs`
- Modify: `crates/jpr-review/src/main.rs`

- [ ] **Step 1: Write failing tests in `crates/jpr-review/src/tui_schema.rs` and `crates/jpr-review/src/cli.rs`**

In `crates/jpr-review/src/cli.rs`:
- Update `a_bare_invocation_shows_the_help` to verify `Cli::try_parse_from(["jpr-review"]).unwrap().command == None` (bare invocation now routes through `main.rs` / `commands::resolve_or_run` which launches the TUI palette on a TTY or prints clap help on non-TTY!).

In `crates/jpr-review/src/tui_schema.rs`, add unit tests:
1. `every_cli_subcommand_is_registered_in_tui_schema`: iterates `Cli::command().get_subcommands()` and asserts every clap subcommand name exists in `build_command_specs()` with valid non-empty `label`, `help`, and passes `cli_tui::validate_command_specs`.
2. `checkout_discriminants_branch_between_default_and_custom_worktree`: verifies `custom_worktree == "no"` skips `worktree_cmd`, and `custom_worktree == "yes"` activates `worktree_cmd`; `custom_repo == "no"` skips `repo`, `custom_repo == "yes"` activates `repo`.
3. `threads_discriminant_branches_between_socket_and_pr_repo`: verifies `target_mode == "socket"` activates `socket` (skipping `pr` and `repo`) and `target_mode == "pr"` activates `pr` and `repo` (skipping `socket`).
4. `answers_to_command_builds_typed_commands_for_every_subcommand`: verifies converting `Answers` for `prs`, `checkout`, `threads`, `reply`, `prepass-write`, `state-path`, `serve`, and `guide` yields exact `Command` values.
5. Non-TTY test in `crates/jpr-review/tests/agent_cli.rs` (or `tui_schema.rs`): spawning the compiled `jpr-review` binary with no args and piped stdin/stderr prints `Usage:` help to stderr, prints nothing to stdout, and exits with code `2`.

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test -p jpr-review`
Expected: FAIL with missing `tui_schema` module and `Option<Command>` mismatch.

- [ ] **Step 3: Implement `crates/jpr-review/src/tui_schema.rs` and wire `cli.rs` + `main.rs` + `commands/mod.rs`**

1. Add `cli-tui.workspace = true` to `crates/jpr-review/Cargo.toml` and `pub mod tui_schema;` to `crates/jpr-review/src/lib.rs`.
2. In `crates/jpr-review/src/cli.rs`:
   - Remove `arg_required_else_help = true` from `#[command(...)]`.
   - Change `pub command: Command` to `pub command: Option<Command>`.
3. Implement `crates/jpr-review/src/tui_schema.rs`:
   - `build_command_specs() -> Vec<CommandSpec>` registering all 8 commands (`prs`, `checkout`, `threads`, `reply`, `prepass-write`, `state-path`, `serve`, `guide`) with:
     - Human-readable display labels (`"List Open Pull Requests"`, `"Check Out Pull Request"`, `"List Review Threads"`, `"Reply to Local Thread"`, `"Write Pre-Pass Findings"`, `"Show Review State Path"`, `"Run Review Engine Daemon"`, `"Print Agent Review Guide"`).
     - Concise 1-sentence helper text on every command and every step.
     - Smart defaults (`limit = "50"`, `poll = "60"`, `$JPR_SOCKET` / `$JPR_PR` / `$JPR_WORKTREE_CMD` env defaults, `target_mode` defaulting to `"socket"` when `JPR_SOCKET` is set else `"pr"`).
     - Discriminants first:
       - `prs`: `custom_repo` (`no` default vs `yes`) -> `repo` when `yes`; `limit` text.
       - `checkout`: `source` (`list` default vs `manual`) -> `pr` via `DynamicSelect` (`GhForge::open_pull_requests(50)`) when `list`, or `pr_manual` text when `manual`; `custom_repo` -> `repo` when `yes`; `custom_worktree` -> `worktree_cmd` when `yes`.
       - `threads`: `target_mode` (`socket` vs `pr`) -> `socket` or (`pr`, `repo`); `is_local_only` toggle.
       - `reply`: `target_mode` -> `socket` or (`pr`, `repo`); `thread_id` text; `body` text.
       - `prepass-write`: `target_mode` -> `socket` or (`pr`, `repo`); `input_mode` (`file` default vs `stdin`) -> `input` path when `file`.
       - `state-path`: `pr` text; `repo` text.
       - `serve`: `pr` text; `repo` text; `poll` text (default `"60"`).
       - `guide`: 0 steps.
   - `answers_to_command(command_id: &str, answers: &Answers) -> Result<Command>`.
   - `initial_answers_from_command(command: &Command) -> Option<(&'static str, Answers)>`: when invoked on a TTY with missing required values (e.g. `jpr-review checkout` without `--pr`, `jpr-review reply` without `thread_id`/`--body`, `jpr-review state-path` without `--pr`/`--repo`), pre-populates any supplied flags into `Answers` so `cli_tui::run_command` opens the stepper right on the first missing step!
4. In `crates/jpr-review/src/main.rs`:
   - If `cli.command` is `None`:
     - If `cli_tui::is_interactive_terminal()`, run `cli_tui::run_palette("jpr-review Commands", &tui_schema::build_command_specs())`; on `PaletteOutcome::Completed { command_id, answers }`, convert via `answers_to_command` and execute `commands::run_command(&command, theme)`; on `Cancelled`, exit `ExitCode::SUCCESS`.
     - If not a terminal, print `Cli::command().render_help()` to stderr and return `ExitCode::from(2)`.
   - If `cli.command` is `Some(command)`:
     - If `cli_tui::is_interactive_terminal()` and `tui_schema::needs_interactive_input(&command)`, run the command's stepper via `cli_tui::run_command` to fill omitted options before executing `commands::run_command`.
     - Otherwise execute `commands::run_command(&command, theme)` directly (preserving all existing non-TTY error messages naming missing flags!).

- [ ] **Step 4: Run full Rust test suite and clippy**

Run: `cargo test --workspace --all-features && cargo clippy --workspace --all-targets --all-features -- -D warnings`
Expected: PASS across all crates (including `agent_cli` and `dependency_rule`), 0 clippy warnings.

- [ ] **Step 5: Commit**

```bash
git add crates/jpr-review
git commit -m "feat(cli): wire jpr-review commands to reusable cli-tui palette and steppers"
```

---

### Task 4: Build Lua Schema Engine (`lua/jpr/tui/schema.lua`) & Pure Renderer (`lua/jpr/tui/render.lua`)

**Files:**
- Create: `lua/jpr/tui/schema.lua`
- Create: `lua/jpr/tui/render.lua`
- Create: `tests/lua/tui_schema_spec.lua`
- Create: `tests/lua/tui_render_spec.lua`

- [ ] **Step 1: Write failing Lua tests in `tests/lua/tui_schema_spec.lua` and `tests/lua/tui_render_spec.lua`**

`tests/lua/tui_schema_spec.lua`:
- Tests `schema.validate_command_specs(commands)` accepts valid specs and rejects missing `label`, missing `help`, duplicate `id`, or unknown `step.kind`.
- Tests `schema.resolve_active_steps(command, answers, context)` dynamically includes/excludes steps based on `when(answers, context)` discriminants.
- Tests `schema.get_default_value_from_step(step, answers, context)` supports static defaults and computed default functions.
- Tests `schema.prune_inactive_answers(command, answers, context)` strips answers belonging to inactive branches after a discriminant changes.

`tests/lua/tui_render_spec.lua`:
- Tests `render.build_palette_layout(commands, selected_index, max_width, context)`:
  - Every command line renders `<Display Label>  [<id>]`.
  - Selected row starts with `"▸ "` (`JprTitle`), unselected rows start with `"  "`.
  - `[<id>]` has `JprMuted` highlight.
  - **Only** `selected_index`'s 1-sentence `help` appears on the indented line immediately beneath it with `JprMuted` highlight; unselected commands' `help` text does NOT appear anywhere in `lines`.
  - Changing `selected_index` from `1` to `2` moves `cursor_line` to command 2's primary line and swaps the hover helper text to command 2.
  - Commands with `requires_session = true` get `JprMuted` on their label when `context.has_session == false`.
  - Long helper text wraps cleanly onto indented continuation lines within `max_width`.
- Tests `render.build_step_layout(command, active_steps, step_index, step_state, max_width)`:
  - Renders `Step 1 of 2 · Pull Request Source` header with progress dots (`● ○`).
  - Renders the step's 1-sentence `help` text in `JprMuted`.
  - Renders option rows with hover-only dim helper text under the hovered option only.
  - Renders `"  Loading..."` state when `step_state.is_loading == true`.
  - Renders validation error line in `JprError` when `step_state.error_message` is set.
  - Footer reflects step position (`[h] palette` on step 1 with `can_return_to_palette`, `[h] back` on step > 1, `[Enter/l] run` on final step vs `[Enter/l] next` on non-final step).

- [ ] **Step 2: Run Lua specs to verify failure**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/tui_schema_spec.lua`
Expected: FAIL (`module 'jpr.tui.schema' not found`).

- [ ] **Step 3: Implement `lua/jpr/tui/schema.lua` and `lua/jpr/tui/render.lua`**

- Keep every function <= 45 lines, descriptive names with auxiliary verbs (`is_loading`, `has_session`, `create_*` / `build_*` naming conventions from `AGENTS.md`), zero em dashes.
- `lua/jpr/tui/schema.lua`: exports `VALID_STEP_KINDS`, `validate_command_specs`, `resolve_active_steps`, `get_default_value_from_step`, `prune_inactive_answers`.
- `lua/jpr/tui/render.lua`: exports `wrap_text`, `build_palette_layout`, `build_step_layout`, `build_text_step_virt_lines`.

- [ ] **Step 4: Run both Lua specs to verify they pass**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/tui_schema_spec.lua && nvim --headless -u NONE -i NONE -l tests/lua/tui_render_spec.lua`
Expected: PASS (exit code 0).

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/tui/schema.lua lua/jpr/tui/render.lua tests/lua/tui_schema_spec.lua tests/lua/tui_render_spec.lua
git commit -m "feat(tui): add Lua command-schema resolver and hover-helper renderer"
```

---

### Task 5: Build Neovim Floating Modal Controller (`lua/jpr/tui/wizard.lua`)

**Files:**
- Create: `lua/jpr/tui/wizard.lua`
- Create: `tests/lua/tui_wizard_spec.lua`

- [ ] **Step 1: Write failing interactive headless Neovim tests in `tests/lua/tui_wizard_spec.lua`**

Cover every interaction contract in a real headless Neovim floating window:
1. **Palette hover & navigation:**
   - `wizard.open_palette(commands, context)` opens a centered rounded float in Normal mode with `filetype = "jpr-tui"`.
   - Initially row 1 is hovered and only command 1's helper text is in the buffer.
   - Sending `j` (and `<Down>`) moves selection to command 2, moves cursor to command 2's primary line, replaces hover helper text with command 2's helper text.
   - Sending `k` (and `<Up>`) wraps back to command 1.
   - Sending `G` jumps to last command; `gg` jumps to first command.
   - Pressing `q` or `<Esc>` closes the floating window cleanly without executing any command.
2. **Discriminant stepper & Back/Forward (`h`/`l`/`<Left>`/`<Right>`/`<S-Tab>`/`<Tab>`/`<CR>`):**
   - Selecting a multi-step command with a discriminant step (`mode`: `"auto"` vs `"custom"`) opens Step 1 of 1 (`"auto"` default).
   - Moving to `"custom"` with `j` and pressing `l` (or `<CR>`) advances to Step 2 of 2 (a `text` step prefilled with its smart default `"default-val"`).
   - On the `text` step, buffer line 1 holds `"default-val"`, `virt_lines_above` renders the step helper text, and pressing `<S-Tab>` returns cleanly to Step 1 with `"custom"` still highlighted!
   - Switching back to `"auto"` and pressing `<CR>` executes `command.execute(pruned_answers)` with NO stale `custom_value` key in `pruned_answers`.
   - Pressing `h` on Step 1 returns to the Command Palette with the originating command highlighted.
3. **Text validation:**
   - Submitting an invalid value on a `text` step keeps the modal open and displays the validation error in `virt_lines_above`; fixing line 1 and pressing `<CR>` succeeds.
4. **Async select step (`async_select`):**
   - Opening a step with `kind = "async_select"` displays `"Loading..."` while the async provider is pending, then paints loaded options when callback fires, and pressing `<CR>` passes the chosen option value to `execute`.
   - Closing the modal before a slow async callback fires drops the stale callback cleanly without error.
5. **Direct entry at an inner step (`initial_answers` + `start_step_id`):**
   - `wizard.open_command(command, { source = "list" }, context, { start_step_id = "pr" })` lands directly on Step 2 (`pr` async list), and pressing `h` steps back to Step 1 (`source`).

- [ ] **Step 2: Run spec to verify failure**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/tui_wizard_spec.lua`
Expected: FAIL (`module 'jpr.tui.wizard' not found`).

- [ ] **Step 3: Implement `lua/jpr/tui/wizard.lua`**

Architecture details (keeping every function <= 45 lines):
- Singleton `active_wizard` handle so opening a new wizard closes any prior one cleanly (`M.close()`).
- Floating window geometry helper `create_window_config(title, footer, width, height)` centered on `vim.o.columns` / `vim.o.lines`, `border = "rounded"`, `style = "minimal"`.
- **Menu / Toggle / AsyncSelect step buffer:**
  - `modifiable = false`, `cursorline = true`, `filetype = "jpr-tui"`.
  - Paints lines + extmarks from `render.build_palette_layout` or `render.build_step_layout`.
  - Maps `j`, `<Down>`, `k`, `<Up>`, `gg`, `<Home>`, `G`, `<End>`, `h`, `<Left>`, `<S-Tab>`, `l`, `<Right>`, `<Tab>`, `<CR>`, `q`, `<Esc>` (`nowait = true`, `silent = true`, `buffer = buf`).
  - `CursorMoved` autocmd guarded by `is_painting` flag syncs mouse clicks to `item_for_line[row]` and re-paints hover helper text.
- **Text input step buffer:**
  - Single-line editable scratch buffer (`modifiable = true`, `buftype = "nofile"`, `filetype = "jpr-tui-input"`).
  - Prefills line 1 with existing answer or `schema.get_default_value_from_step(...)`.
  - Attaches `virt_lines_above = true` extmark on line 0 with the wrapped 1-sentence `step.help` (`JprMuted`) and any `error_message` (`JprError`), while window `title` shows `Step X of Y · <step.label>` and `footer` shows `[Enter/Tab] next  [S-Tab] back  [Esc] normal/cancel`.
  - Enters Insert mode (`vim.cmd("startinsert!")`) so typing works immediately with `<Left>`/`<Right>` moving the text cursor.
  - Buffer-local mappings:
    - Insert mode (`i`): `<CR>` and `<Tab>` validate & advance (after `stopinsert`); `<S-Tab>` saves draft & steps back (after `stopinsert`); `<Esc>` drops to Normal mode (standard Vim behavior).
    - Normal mode (`n`): `<CR>` and `<Tab>` validate & advance; `<S-Tab>` steps back; `q` and `<Esc>` cancel cleanly.

- [ ] **Step 4: Run `tui_wizard_spec.lua` to verify it passes**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/tui_wizard_spec.lua`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/tui/wizard.lua tests/lua/tui_wizard_spec.lua
git commit -m "feat(tui): add Neovim floating palette and stepper wizard controller"
```

---

### Task 6: Define All 14 `:Jpr` Commands in `lua/jpr/commands/schema.lua` & Wire `:Jpr` / `:Jpr open`

**Files:**
- Create: `lua/jpr/commands/schema.lua`
- Modify: `plugin/jpr.lua`
- Modify: `lua/jpr/init.lua`
- Modify: `lua/jpr/session/init.lua`
- Modify: `lua/jpr/session/commands.lua`
- Modify: `lua/jpr/agent.lua`
- Modify: `tests/lua/command_spec.lua`
- Modify: `tests/lua/session_lifecycle_spec.lua`
- Modify: `tests/lua/build_and_binary_spec.lua`
- Create: `tests/lua/palette_and_open_picker_spec.lua`

- [ ] **Step 1: Write failing tests for schema completeness, bare `:Jpr`, `:Jpr open` PR picker, and direct option flags**

1. Update version assertions from `"0.5.0"` to `"0.5.1"` in:
   - `tests/lua/command_spec.lua`
   - `tests/lua/session_lifecycle_spec.lua`
   - `tests/lua/build_and_binary_spec.lua`
2. In `tests/lua/command_spec.lua`:
   - Assert `:Jpr` user command has `nargs == "*"`.
   - Assert `jpr.complete("", "Jpr toggle ")` offers `{ "unified", "split" }`, `jpr.complete("", "Jpr comment ")` offers `{ "line", "file", "suggest" }`, `jpr.complete("", "Jpr agent ")` offers `{ "claude", "codex" }`.
   - Assert `:Jpr open abc` emits an `ERROR` notification mentioning `"invalid pull request"` (or usage).
3. Create `tests/lua/palette_and_open_picker_spec.lua`:
   - Verifies `require("jpr.commands.schema").create_command_specs()` passes `require("jpr.tui.schema").validate_command_specs` and covers all 14 subcommands with human-readable labels (distinct from bare lowercase `id`) and 1-sentence helper text.
   - Verifies running bare `:Jpr` (via `jpr.command({})`) opens the floating Command Palette showing `▸ Open Pull Request  [open]` with hover-only helper text underneath; pressing `j` moves to `Sync with GitHub  [sync]` and swaps the hover helper text.
   - Uses a temporary fake binary script handling `prs` (returns JSON array of 2 PRs, one normal and one draft) and verifies:
     - Running `:Jpr open` (no arg) invokes `prs`, opens the PR picker modal with `#42  Add OAuth` and `#43  WIP refactor  [draft]`, shows `@alice · feat/oauth · updated 2026-11-23` only on hover, moving down with `j` switches hover metadata to `#43`, and pressing `<CR>` calls `session.open(43)`.
     - Running `:Jpr open` and pressing `h` steps back to Step 1 (`Pull Request Source`), selecting `Enter PR Number or URL` opens the text input step, typing `#99` and pressing `<CR>` calls `session.open(99)`.
     - Running `:Jpr open` when `prs` returns `[]` notifies `"no open pull requests in this repository"`.
   - Verifies selecting `Switch Diff View  [toggle]`, `Add Review Comment  [comment]`, and `Coding Agent Panel  [agent]` from the palette opens their respective steppers with smart defaults, and direct `:Jpr toggle split`, `:Jpr comment file`, `:Jpr agent codex` dispatch immediately without a modal.

- [ ] **Step 2: Run new and updated specs to verify failure**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/palette_and_open_picker_spec.lua`
Expected: FAIL (`module 'jpr.commands.schema' not found`).

- [ ] **Step 3: Implement `lua/jpr/commands/schema.lua` and wire `plugin/jpr.lua`, `init.lua`, `session/`, and `agent.lua`**

1. **`plugin/jpr.lua`**: change `nargs = "+"` to `nargs = "*"`.
2. **`lua/jpr/agent.lua`**: allow optional `agent_kind` (`"claude"` or `"codex"`) on `M.ensure_open(session, on_ready, agent_kind)` and `M.toggle(session, agent_kind)` so `prepareAgentLaunch` sends `{ agent = agent_kind or jpr().config.agent }` when opening a fresh agent panel.
3. **`lua/jpr/session/commands.lua`**:
   - Add `session_mod.set_view_mode(mode)` setting `view_mode.set(mode)` and redrawing active sessions.
   - Allow optional `agent_kind` argument on `session_mod.agent_current(agent_kind)`.
4. **`lua/jpr/session/init.lua`**:
   - Add `M.list_open_prs(on_result, on_error)`: checks `vim.fn.executable(binary_path) == 1` (with `:Lazy build jpr-nvim` hint if missing), runs `vim.system({ binary_path, "prs" }, { cwd = vim.fn.getcwd(), text = true }, vim.schedule_wrap(...))`, decodes JSON array, and calls `on_result(prs)` or `on_error(message)`.
   - Add `M.open_tab_numbers()` returning a map `{ [number] = true }` of currently open PR tabs so the PR picker adds `[open]` badges cleanly.
5. **`lua/jpr/commands/schema.lua`**:
   - Defines all 14 `:Jpr` commands with human-readable labels, `[id]`, concise 1-sentence helper text, `requires_session`, smart defaults, and discriminants (`open`, `toggle`, `comment`, `agent`) exactly per the design spec.
   - Exports `M.create_command_specs()`, `M.find_command_spec(id)`, `M.list_command_ids()`, `M.subcommand_arg_completions(subcommand)`, and `M.format_pr_updated_date(iso_timestamp)`.
6. **`lua/jpr/init.lua`**:
   - Bump `M.VERSION = "0.5.1"`.
   - Derive `M.subcommands` from `commands/schema.lua`.
   - Update `M.complete(arglead, cmdline)` to complete subcommands on word 2 and optional schema argument values (`toggle` -> `unified`/`split`, `comment` -> `line`/`file`/`suggest`, `agent` -> `claude`/`codex`) on word 3.
   - Update `M.command(fargs, cmd_opts)`:
     - `#fargs == 0`: calls `wizard.open_palette(schema.create_command_specs(), build_tui_context(cmd_opts))`.
     - `subcommand == "open"` and `(fargs[2] == nil or fargs[2] == "")`: calls `wizard.open_command(open_spec, { source = "list" }, context, { start_step_id = "pr" })`.
     - `subcommand == "open"` with explicit `fargs[2]`: parses with `M.parse_pr_arg(fargs[2])`; on `nil` reports `invalid pull request %q; expected a PR number, #number, or pull request URL`.
     - `toggle`, `comment`, `agent`: accept optional `fargs[2]` (`unified|split`, `line|file|suggest`, `claude|codex`) and error clearly on unknown arg values; with no `fargs[2]` preserve existing fast direct behavior (`toggle_view()`, cursor `comment_current(cmd_opts)`, `agent_current()`).

- [ ] **Step 4: Run all Lua specs via `./scripts/test-lua.sh`**

Run: `./scripts/test-lua.sh`
Expected: ALL Lua specs pass (exit code 0).

- [ ] **Step 5: Commit**

```bash
git add plugin/jpr.lua lua/jpr/ tests/lua/
git commit -m "feat(nvim): wire bare :Jpr command palette and :Jpr open PR stepper picker"
```

---

### Task 7: Codify Permanent Invariant in `AGENTS.md` and Update Project Documentation

**Files:**
- Modify: `AGENTS.md`
- Modify: `docs/rules/cli-ux.md`
- Modify: `docs/rules/cli-rust.md`
- Modify: `docs/architecture.md`
- Modify: `docs/protocol.md`
- Modify: `docs/decisions.md`
- Modify: `README.md`

- [ ] **Step 1: Add the Interactive Command Palette & Schema-to-TUI Invariant to `AGENTS.md` and `docs/rules/cli-ux.md`**

In `AGENTS.md` (under `## Stack` or a dedicated `## Interactive Command Palette & Schema-to-TUI Invariant` section), codify as a binding rule:
- Every command and option in both `:Jpr` (`lua/jpr/commands/schema.lua`) and `jpr-review` (`crates/jpr-review/src/tui_schema.rs`) MUST be registered in its declarative command schema so it is interactively launchable from the Command Palette (`:Jpr` in Neovim, bare `jpr-review` on a TTY).
- Every schema entry MUST define:
  1. A human-readable display label (never just the raw command literal) paired with `[<id>]`.
  2. Concise helper text (at most 1 sentence unless the option is genuinely confusing), shown on hover in menus and on every stepper screen.
  3. Smart prefilled/preselected defaults wherever inferable from context.
  4. Discriminant-first step ordering with `when` predicates whenever a boolean/enum controls downstream options, so irrelevant steps are skipped.
  5. Full non-interactive flag/argument parity (scripts and agents never hit interactive prompts).
- Schema completeness is enforced by unit tests in both Rust and Lua.

- [ ] **Step 2: Update `docs/rules/cli-rust.md`, `docs/architecture.md`, `docs/protocol.md`, `docs/decisions.md`, and `README.md`**

- `docs/rules/cli-rust.md`: document `crates/cli-tui` alongside `prompt.rs` and `theme.rs`.
- `docs/architecture.md`: add `crates/cli-tui` (frontend-layer reusable TUI crate outside `review-*`), `jpr-review prs`, `lua/jpr/tui/{schema,render,wizard}.lua`, and `lua/jpr/commands/schema.lua`.
- `docs/protocol.md`: update `initialize` example version `"0.5.0"` -> `"0.5.1"`.
- `docs/decisions.md`: append concise ADR documenting the declarative command-schema-to-TUI architecture, discriminant-first steppers, hover-only helper text, and Neovim Normal-vs-Insert keyboard conventions.
- `README.md`: update Commands section to highlight bare `:Jpr` (Command Palette), `:Jpr open` (open-PR picker), and optional arguments (`:Jpr toggle unified|split`, `:Jpr comment file|suggest`, `:Jpr agent claude|codex`).

- [ ] **Step 3: Verify zero em dashes in modified docs and run full `just check`**

Run: `just check`
Expected: `cargo fmt --check`, `cargo clippy --workspace --all-targets --all-features -- -D warnings`, `cargo test --workspace --all-features`, and `./scripts/test-lua.sh` ALL PASS cleanly.

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md docs/ README.md
git commit -m "docs: codify interactive schema-to-TUI invariant and document palette/picker"
```

---

### Task 8: Final Review, `/avandar-code-review`, Full `/diff-review`, and Merge/Publish `jpr-nvim`

- [ ] **Step 1: Run `just check` across the entire `jpr-nvim` workspace**
- [ ] **Step 2: Run `/avandar-code-review`, fix any findings, re-verify `just check`, and commit**
- [ ] **Step 3: Run full Initial-mode `/diff-review`, copy `.difit/<stem>-walkthrough.md` to `docs/code-walkthroughs/2026-11-23_command-palette-and-schema-tui.md`, and commit**
- [ ] **Step 4: Present readiness checklist (`👍 Ready for full-branch review, awaiting approval`), and after approval merge to `main`, delete finished plan file if desired, and push `origin/main`**

---

### Task 9: Fix `jpsyx-configs` Command-Line Abbreviations & Update `jpr-nvim` via `lazy.nvim` (Post-Publish)

**Files (in `/Users/pablo/src/jpsyx/jpsyx-configs`):**
- Modify: `home/.config/nvim/init.lua`
- Modify: `home/.config/nvim/tests/file_actions_spec.lua`
- Modify: `home/.config/nvim/commands.yaml`
- Modify: `home/.config/nvim/docs/CHANGELOG.md`
- Update via `lazy.nvim` + `jpsyx sync`: `home/.config/nvim/lazy-lock.json`

- [ ] **Step 1: Write failing regression test in `home/.config/nvim/tests/file_actions_spec.lua`**

Verify in a headless Neovim child process:
1. Feeding `:open ` expands to `OpenCurrentFile ` (command position).
2. Feeding `:Jpr open ` does **not** expand `open` to `OpenCurrentFile` (remains `Jpr open `).
3. Feeding `/open ` does **not** expand `open` to `OpenCurrentFile`.

- [ ] **Step 2: Run `file_actions_spec.lua` to verify the new `:Jpr open ` assertion fails**

Run: `nvim --headless -u NONE -l /Users/pablo/src/jpsyx/jpsyx-configs/home/.config/nvim/tests/file_actions_spec.lua` (using the repo's exact test invocation).
Expected: FAIL on `:Jpr open ` expanding to `Jpr OpenCurrentFile `.

- [ ] **Step 3: Replace bare `cnoreabbrev` calls in `home/.config/nvim/init.lua` with `cabbrev_cmd`**

```lua
local function cabbrev_cmd(lhs, rhs)
	vim.keymap.set("ca", lhs, function()
		if vim.fn.getcmdtype() == ":" and vim.fn.getcmdline() == lhs then
			return rhs
		end
		return lhs
	end, { expr = true })
end

cabbrev_cmd("W", "w")
cabbrev_cmd("Q", "q")
cabbrev_cmd("Wq", "wq")
cabbrev_cmd("WQ", "wq")
cabbrev_cmd("wQ", "wq")
cabbrev_cmd("tb", "tabnew")
cabbrev_cmd("open", "OpenCurrentFile")
cabbrev_cmd("dir", "OpenCurrentDirectory")
```

Update `home/.config/nvim/commands.yaml` to catalog bare `:Jpr` (Command Palette) and `jpr-tui` modal shortcuts, plus `home/.config/nvim/docs/CHANGELOG.md`.

- [ ] **Step 4: Run `file_actions_spec.lua`, `jpsyx build && jpsyx sync`, `:Lazy! update jpr-nvim`, `:checkhealth jpr`, and `:CommandPaletteAudit`**

Run:
```sh
jpsyx --repo /Users/pablo/src/jpsyx/jpsyx-configs build && jpsyx --repo /Users/pablo/src/jpsyx/jpsyx-configs sync
nvim --headless "+Lazy! update jpr-nvim" +qa
~/.local/share/nvim/lazy/jpr-nvim/target/release/jpr-review --version
jpsyx --repo /Users/pablo/src/jpsyx/jpsyx-configs sync && jpsyx --repo /Users/pablo/src/jpsyx/jpsyx-configs status
```
Expected:
- `jpr-review 0.5.1`
- `:checkhealth jpr` all OK
- `:CommandPaletteAudit` clean
- `file_actions_spec.lua` passes
- `lazy-lock.json` captures the new `jpr-nvim` commit

- [ ] **Step 5: Commit and push `jpsyx-configs`**

```bash
git -C /Users/pablo/src/jpsyx/jpsyx-configs add -A
git -C /Users/pablo/src/jpsyx/jpsyx-configs commit -m "fix(nvim): scope cmdline abbreviations to command position and update jpr-nvim 0.5.1"
git -C /Users/pablo/src/jpsyx/jpsyx-configs push origin main
```
