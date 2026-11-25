# Non-Git-Repo Repository Picker, Managed Clone Checkout, and Global `gh` Auth Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect non-git-repo startup on bare `:Jpr` (and bare `:Jpr open`) to pick a GitHub owner/repo before opening the command palette, support checking out PRs for remote repos via a managed XDG clone cache, and wrap every `gh`-backed plugin flow with a single-flight authentication recovery flow.

**Architecture:** Classify unauthenticated `gh` errors once in `crates/review-core` (`ForgeAuthError`), produce them in `review-forge-github` and `review-workspace-git`, and expose structured signals across CLI exit code `3`, JSON-RPC error `-32001` (`AUTH_REQUIRED`), and `Event::SyncFailed { authRequired, isBackground }` (`PROTOCOL_VERSION = 9`). Add `jpr-review owners`, `jpr-review repos`, and managed-cache out-of-repo `jpr-review checkout` in Rust, and add `lua/jpr/auth.lua` plus `lua/jpr/repo_picker.lua` in Neovim to drive the pre-palette repo flow and unified auth recovery.

**Tech Stack:** Rust (edition 2024 Cargo workspace: `review-model`, `review-core`, `review-forge-github`, `review-workspace-git`, `review-rpc`, `jpr-review`, `cli-tui`), Neovim `>= 0.11` Lua (`vim.system`, `vim.fn.jobstart(..., { term = true })`, floating windows, headless Lua specs via `./scripts/test-lua.sh`).

**Spec:** `docs/superpowers/specs/2026-11-25-non-repo-picker-and-gh-auth-design.md`

## Global Constraints

- **Dependency rule:** `crates/review-*` crates never depend on Neovim, Lua, `cli-tui`, or any terminal/UI crate (`crates/jpr-review/tests/dependency_rule.rs`).
- **Schema-to-TUI invariant:** Every new `jpr-review` subcommand (`owners`, `repos`) must be registered in `crates/jpr-review/src/tui_schema/` with human-readable labels paired with `[<id>]`, concise helper text, smart defaults, discriminant-first ordering, Neovim-conventional keys, flag parity, and automated completeness tests. All 16 `:Jpr` subcommands in `lua/jpr/commands/schema.lua` remain intact and green.
- **Code style:** Zero em dashes across code, comments, tests, and docs; functions `<= 45` lines; Red/Green TDD by default; `just check` green (`cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --all-features -- -D warnings`, `cargo test --workspace --all-features`, `./scripts/test-lua.sh`).
- **Lockstep release & protocol:** Bump workspace `Cargo.toml` and `lua/jpr/init.lua` to `0.8.0`, and bump `PROTOCOL_VERSION` from `8` to `9` in `crates/review-rpc/src/protocol.rs` and `lua/jpr/rpc.lua`.
- **Documentation currency:** Update `docs/architecture.md`, `docs/protocol.md`, `docs/decisions.md`, `docs/rules/cli-ux.md`, and `README.md` in the same branch.

## Review Focus

- **Simultaneous `syncFailed` event + `sync` RPC `-32001` on one unauthenticated sync:** Must open exactly one auth modal and replay `sync` exactly once after sign-in (pinned in Task 6).
- **Manual close or Ctrl-C in the `gh auth login` floating terminal:** Must stop the terminal job, run `gh auth status` once anyway (resuming if browser login actually completed), or re-open the auth modal with an inline retry error while preserving the queued callbacks (pinned in Task 5).
- **Unrelated or wrong-remote directory already at `$XDG_CACHE_HOME/jpr/repos/<owner>/<repo>`:** `ensure_managed_clone` must refuse with guidance and never delete or overwrite existing user files, while cleaning up a partial directory created by a failed `gh repo clone` in the same call (pinned in Task 3).
- **Zero-org user vs multi-org user vs empty-repo owner:** Zero orgs must skip straight to the repository list; 1+ orgs must list the personal profile first with `[you]`; an owner with 0 repos must show a clear empty state where `h` navigates back to the owner list (pinned in Task 7).
- **Missing `gh` binary vs unauthenticated `gh` vs HTTP 403/429/5xx or timeout:** Missing `gh` must never be classified as `ForgeAuthError` and must show an install error instead of opening `gh auth login`; non-auth HTTP/network errors must remain `Transient` or `Rejected` (pinned in Task 1 and Task 5).

## File Structure

| Path | Action | Responsibility |
| --- | --- | --- |
| `crates/review-model/src/forge.rs` | Create | `OwnerKind`, `ForgeOwner`, `ForgeRepo` pure wire models |
| `crates/review-model/src/lib.rs`, `view/mod.rs` | Modify | Re-export discovery models; add `auth_required` and `is_background` to `Event::SyncFailed` |
| `crates/review-core/src/auth.rs` | Create | `AUTH_EXIT_CODE`, `ForgeAuthError`, `is_auth_error`, `is_gh_auth_failure_text` |
| `crates/review-core/src/lib.rs`, `ports.rs`, `fakes.rs`, `fakes/comments.rs` | Modify | Export auth helpers, add `ForgeWriteError::AuthRequired`, add `FakeForge::fail_auth_with` |
| `crates/review-core/src/session/` (`sync.rs`, `viewed.rs`, `comments.rs`, `comments/helpers.rs`, `comments/queue/mod.rs`, `comments/replay.rs`, `submit.rs`, `local.rs`) | Modify | Handle `ForgeAuthError` / `ForgeWriteError::AuthRequired` cleanly; separate foreground vs `sync_background` / `flush_queued_background` |
| `crates/review-forge-github/src/gh.rs`, `mutations.rs`, `lib.rs` | Modify | Wrap auth failures in `ForgeAuthError`; classify write auth errors as `ForgeWriteError::AuthRequired`; export discovery helpers |
| `crates/review-forge-github/src/discovery.rs` | Create | `GhForge::list_owners` (paginated GraphQL) and `GhForge::list_repos` (`gh repo list --json`) |
| `crates/review-workspace-git/src/process.rs`, `lib.rs` | Modify | Wrap `gh` auth failures in `ForgeAuthError`; re-export cache helpers |
| `crates/review-workspace-git/src/cache.rs` | Create | `managed_repo_dir` and `ensure_managed_clone` for XDG clone cache |
| `crates/review-rpc/src/protocol.rs`, `server.rs`, `server/ticker.rs` | Modify | `PROTOCOL_VERSION = 9`, `RpcError::AUTH_REQUIRED = -32001`, auth error RPC mapping, background ticker calls |
| `crates/jpr-review/src/` (`main.rs`, `cli.rs`, `commands/mod.rs`, `commands/owners.rs`, `commands/repos.rs`, `commands/checkout.rs`, `commands/local.rs`, `tui_schema/*`) | Modify / Create | Exit code `3`, `owners` & `repos` subcommands + `tui_schema`, out-of-repo managed-cache `checkout`, `local` auth propagation |
| `Cargo.toml`, `lua/jpr/init.lua`, `lua/jpr/rpc.lua` | Modify | Version `0.8.0` and `PROTOCOL_VERSION = 9` lockstep |
| `lua/jpr/auth/init.lua`, `lua/jpr/auth/modal.lua`, `lua/jpr/auth/terminal.lua` | Create | Single-flight auth queue, keyboard+mouse auth prompt modal, `gh auth login` floating terminal + `gh auth status` verification |
| `lua/jpr/repo_picker.lua` | Create | Async git repo detection and pre-palette owner -> repository wizard |
| `lua/jpr/session/` (`init.lua`, `open.lua`, `open_local.lua`, `commands.lua`, `events.lua`), `lua/jpr/comments/compose.lua`, `lua/jpr/views/diff/init.lua`, `lua/jpr/views/loading.lua` | Modify | Global auth gate wiring, compose draft preservation on auth cancel, multi-repo `buf_key` / `pending_by_key` / `open_tab_numbers` safety, `--repo` on `list_open_prs` |
| `lua/jpr/init.lua`, `lua/jpr/commands/schema.lua`, `lua/jpr/tui/render.lua`, `lua/jpr/tui/wizard/palette.lua` | Modify | Non-git-repo bare `:Jpr` and `:Jpr open` entry, repo-scoped palette (`context.repo`, `context.on_back`, `requires_git_repo`) |
| `tests/lua/auth_spec.lua`, `tests/lua/auth_integration_spec.lua`, `tests/lua/repo_picker_spec.lua` | Create | Unit and integration specs for auth modal/terminal, RPC/CLI retry, draft recovery, multi-repo safety, and repo picker |
| `docs/architecture.md`, `docs/protocol.md`, `docs/decisions.md`, `docs/rules/cli-ux.md`, `README.md` | Modify | Keep documentation current with `0.8.0` and `PROTOCOL_VERSION = 9` |

---

### Task 1: Shared Auth Classification, Discovery Models & `ReviewSession` Auth Handling (`review-model`, `review-core`)

help-me-pick: implement L2 (hours=1.5 cause=known material=familiar stakes=medium verified=yes)

**Files:**
- Create: `crates/review-model/src/forge.rs`
- Modify: `crates/review-model/src/lib.rs`, `crates/review-model/src/view/mod.rs`, `crates/review-model/src/view/tests.rs`
- Create: `crates/review-core/src/auth.rs`
- Modify: `crates/review-core/src/lib.rs`, `crates/review-core/src/ports.rs`, `crates/review-core/src/fakes.rs`, `crates/review-core/src/fakes/comments.rs`
- Modify: `crates/review-core/src/session/sync.rs`, `crates/review-core/src/session/viewed.rs`, `crates/review-core/src/session/comments.rs`, `crates/review-core/src/session/comments/helpers.rs`, `crates/review-core/src/session/comments/queue/mod.rs`, `crates/review-core/src/session/comments/replay.rs`, `crates/review-core/src/session/submit.rs`, `crates/review-core/src/session/local.rs`

**Interfaces:**
- Consumes: existing `review_model::Event`, `review_core::ports::ForgeWriteError`, `review_core::ReviewSession`
- Produces:
  - `review_model::{OwnerKind, ForgeOwner, ForgeRepo}` (camelCase serde wire format)
  - `review_model::Event::SyncFailed { message: String, auth_required: bool, is_background: bool }`
  - `review_core::{AUTH_EXIT_CODE, ForgeAuthError, is_auth_error, is_gh_auth_failure_text}`
  - `review_core::ports::ForgeWriteError::AuthRequired(String)`
  - `review_core::fakes::FakeForge::fail_auth_with(&self, message: Option<&str>)`
  - `ReviewSession::sync_background(&mut self) -> Result<SessionView>` and `ReviewSession::flush_queued_background(&mut self) -> Result<bool>`

- [ ] **Step 1: Write failing tests for discovery models and `SyncFailed` serialization (`review-model`)**

In `crates/review-model/src/forge.rs` tests and `crates/review-model/src/view/tests.rs`:
- Assert `ForgeOwner { login: "octo", name: Some("Octocat"), kind: OwnerKind::User }` serializes with `"kind": "user"` and `OwnerKind::Organization` serializes with `"kind": "organization"`, omitting `name` when `None`.
- Assert `ForgeRepo` serializes `nameWithOwner`, `description` (omitted when `None`), `isPrivate`, `isArchived`, `updatedAt`.
- Assert `Event::SyncFailed { message: "bad creds".into(), auth_required: true, is_background: false }` serializes with `"type": "syncFailed"`, `"authRequired": true`, `"isBackground": false`, and deserializes older payloads omitting both booleans as `false`.

- [ ] **Step 2: Run model tests to verify failure**

Run: `cargo test -p review-model`
Expected: FAIL (missing `forge` module and `auth_required`/`is_background` fields on `Event::SyncFailed`).

- [ ] **Step 3: Implement `forge.rs` and update `Event::SyncFailed` in `review-model`**

Create `crates/review-model/src/forge.rs` with `OwnerKind`, `ForgeOwner`, `ForgeRepo` matching spec Section 2, re-export from `crates/review-model/src/lib.rs`, and add `#[serde(default)] auth_required: bool` and `#[serde(default)] is_background: bool` to `Event::SyncFailed` in `crates/review-model/src/view/mod.rs`.

- [ ] **Step 4: Write failing tests for `ForgeAuthError`, `is_gh_auth_failure_text`, and `ReviewSession` auth handling (`review-core`)**

Add tests in `crates/review-core/src/auth.rs` and `crates/review-core/src/session/` covering:
- `is_gh_auth_failure_text` returns `true` for `"To get started with GitHub CLI, please run:  gh auth login"`, `"not logged into any GitHub hosts"`, `"HTTP 401: Bad credentials"`, `"The token in default is invalid."`, `"authentication required"`, `"no oauth token"`.
- `is_gh_auth_failure_text` returns `false` for `"running gh (is the GitHub CLI installed?): No such file or directory"`, `"gh timed out after 30s"`, `"HTTP 403 Forbidden"`, `"HTTP 422"`, `"HTTP 502"`, `"no pull requests found for branch"` (Review Focus #5).
- `is_auth_error` detects `ForgeAuthError` even when wrapped in `.context(...)`.
- `ReviewSession::sync()` on auth failure emits `Event::SyncFailed { auth_required: true, is_background: false }` and returns an error satisfying `is_auth_error`.
- `ReviewSession::sync_background()` on auth failure emits `Event::SyncFailed { auth_required: true, is_background: true }`.
- `ReviewSession::set_viewed()` on auth failure queues the mark locally AND emits `Event::SyncFailed { auth_required: true, is_background: false }`.
- `ReviewSession::flush_queued_background()` on auth failure keeps the queued viewed mark and queued comment ops intact (not dropped, not marked failed) and emits `Event::SyncFailed { auth_required: true, is_background: true }`.
- Comment/review mutations (`comment`, `reply`, `edit_message`, `delete_message`, `set_resolved`, `toggle_reaction`, `promote_thread`, `submit_review`) on `ForgeWriteError::AuthRequired` return `Err` satisfying `is_auth_error` WITHOUT queueing an op or mutating threads/drafts/sync status.

- [ ] **Step 5: Run core tests to verify failure**

Run: `cargo test -p review-core --all-features`
Expected: FAIL (missing `auth` module, `ForgeWriteError::AuthRequired`, `sync_background`, `flush_queued_background`).

- [ ] **Step 6: Implement `auth.rs`, `ForgeWriteError::AuthRequired`, `FakeForge::fail_auth_with`, and `ReviewSession` auth paths**

- Create `crates/review-core/src/auth.rs` with `AUTH_EXIT_CODE = 3`, `ForgeAuthError`, `is_auth_error`, `is_gh_auth_failure_text`; re-export in `crates/review-core/src/lib.rs`.
- Add `ForgeWriteError::AuthRequired(String)` in `crates/review-core/src/ports.rs`.
- Add `auth_failure: Option<String>` and `fail_auth_with(&self, message: Option<&str>)` to `FakeForge` (returns `Err(ForgeAuthError)` from reads/`set_viewed`/`current_branch_pr` and `Err(ForgeWriteError::AuthRequired)` from write methods).
- Add `sync_background` (`is_background = true`) vs `sync` (`is_background = false`) in `sync.rs`, and `flush_queued_background` vs `flush_queued` in `viewed.rs`.
- Update `set_viewed` to publish `Event::SyncFailed { message, auth_required: true, is_background: false }` when `forge.set_viewed` fails with `is_auth_error`.
- Update all `ForgeWriteError` match sites in `comments.rs`, `comments/helpers.rs`, `comments/queue/mod.rs`, `comments/replay.rs`, `submit.rs`, and `local.rs`: foreground mutations propagate `Err(anyhow::Error::new(ForgeAuthError::new(msg)))` without mutating state; replay stops with a new `ReplayOutcome::AuthRequired(String)` preserving queued ops and publishing `Event::SyncFailed { message, auth_required: true, is_background }`.
- Keep all functions `<= 45` lines.

- [ ] **Step 7: Run tests and clippy for `review-model` and `review-core`**

Run: `cargo test -p review-model -p review-core --all-features && cargo clippy -p review-model -p review-core --all-targets --all-features -- -D warnings`
Expected: PASS with zero warnings.

- [ ] **Step 8: Commit**

```bash
git add crates/review-model crates/review-core
git commit -m "feat(core): add shared gh auth error classification and discovery models"
```

---

### Task 2: GitHub Forge Auth Wrapping & Owner/Repo Discovery (`review-forge-github`)

help-me-pick: implement L1 (hours=1 cause=known material=familiar stakes=low verified=yes)

**Files:**
- Modify: `crates/review-forge-github/src/gh.rs`, `crates/review-forge-github/src/mutations.rs`, `crates/review-forge-github/src/lib.rs`
- Create: `crates/review-forge-github/src/discovery.rs`

**Interfaces:**
- Consumes: `review_core::{ForgeAuthError, is_auth_error, is_gh_auth_failure_text}`, `review_core::ports::ForgeWriteError`, `review_model::{ForgeOwner, ForgeRepo, OwnerKind}`
- Produces:
  - `Gh::run` returning `Err` satisfying `is_auth_error` on unauthenticated `gh` failures
  - `GhForge::list_owners(&self) -> Result<Vec<ForgeOwner>>`
  - `GhForge::list_repos(&self, owner: Option<&str>, limit: u32) -> Result<Vec<ForgeRepo>>`
  - `GhForge::repo_list_args(owner: Option<&str>, limit: u32) -> Result<Vec<String>>`

- [ ] **Step 1: Write failing tests for auth wrapping and owner/repo discovery**

Add unit tests in `crates/review-forge-github/src/gh.rs`, `mutations/tests.rs`, and `discovery.rs`:
- `Gh::run` (or pure `gh_failure_to_error(stdout, stderr)`) wraps `"To get started with GitHub CLI, please run:  gh auth login"` and `"HTTP 401: Bad credentials"` into `ForgeAuthError` (`is_auth_error == true`), while keeping `"HTTP 502"` / `"HTTP 422"` / missing `gh` non-auth (`is_auth_error == false`).
- `classify_write_error` maps a wrapped `ForgeAuthError` to `ForgeWriteError::AuthRequired`, ahead of `Transient`/`Rejected`.
- `parse_owners_page` parses GraphQL `viewer { login name organizations { pageInfo nodes } }`, puts `OwnerKind::User` first, normalizes blank `name` to `None`, deduplicates orgs, sorts orgs case-insensitively, and returns `endCursor` when `hasNextPage` is true.
- `repo_list_args(None, 100)` omits owner and includes `--limit 100 --json nameWithOwner,description,isPrivate,isArchived,updatedAt`; `repo_list_args(Some("acme"), 50)` puts `"acme"` after `"list"`; rejects `limit == 0` and invalid owner segments (`"a/b"`, `"-flag"`, `"bad space"`, `""`).
- `parse_repo_list` parses `gh repo list --json` array into `Vec<ForgeRepo>`, normalizing `""` or `null` description to `None`.

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test -p review-forge-github`
Expected: FAIL (missing `discovery` module and auth wrapping).

- [ ] **Step 3: Implement auth wrapping in `gh.rs` / `mutations.rs` and discovery in `discovery.rs`**

- In `gh.rs`: check `review_core::is_gh_auth_failure_text(&message)` when `!output.status.success()` and return `Err(anyhow::Error::new(ForgeAuthError::new(message)))`.
- In `mutations.rs` (`classify_write_error`): check `if review_core::is_auth_error(error) { return ForgeWriteError::AuthRequired(format!("{error:#}")); }` first.
- In `discovery.rs`: implement `OWNERS_QUERY` (paginated GraphQL), `parse_owners_page`, `GhForge::list_owners`, `REPO_LIST_FIELDS`, `GhForge::repo_list_args`, `parse_repo_list`, and `GhForge::list_repos`. Export `pub mod discovery;` from `lib.rs`.

- [ ] **Step 4: Run tests and clippy for `review-forge-github`**

Run: `cargo test -p review-forge-github && cargo clippy -p review-forge-github --all-targets -- -D warnings`
Expected: PASS with zero warnings.

- [ ] **Step 5: Commit**

```bash
git add crates/review-forge-github
git commit -m "feat(forge): wrap gh auth errors and add owner/repo discovery"
```

---

### Task 3: Managed Clone Cache & `gh` Auth Propagation (`review-workspace-git`)

help-me-pick: implement L2 (hours=1 cause=known material=familiar stakes=medium verified=yes)

**Files:**
- Modify: `crates/review-workspace-git/src/process.rs`, `crates/review-workspace-git/src/lib.rs`
- Create: `crates/review-workspace-git/src/cache.rs`

**Interfaces:**
- Consumes: `review_core::{ForgeAuthError, is_gh_auth_failure_text}`, `crate::repo::main_repo_root`, `crate::process::run`
- Produces:
  - `review_workspace_git::managed_repo_dir(xdg_cache_home: Option<&Path>, home: &Path, app: &str, owner: &str, repo: &str) -> Result<PathBuf>`
  - `review_workspace_git::ensure_managed_clone(repo_dir: &Path, owner: &str, repo: &str) -> Result<PathBuf>`
  - `review_workspace_git::process::get_stdout_from_output` returning `ForgeAuthError` when `program == "gh"` fails auth

- [ ] **Step 1: Write failing tests for `process.rs` auth wrapping and `cache.rs` managed clone behavior**

Add tests in `crates/review-workspace-git/src/process.rs` and `crates/review-workspace-git/src/cache.rs`:
- `get_stdout_from_output("gh", ...)` with stderr `"To get started with GitHub CLI, please run: gh auth login"` returns `Err` satisfying `review_core::is_auth_error`; `get_stdout_from_output("git", ...)` does not.
- `managed_repo_dir` uses absolute `xdg_cache_home` when provided, falls back to `home/.cache` when `None` or relative, returns `<root>/jpr/repos/<owner>/<repo>`, and rejects unsafe `owner`/`repo` segments (`""`, `"."`, `".."`, `"a/b"`, `"a\\b"`, `"a b"`).
- `ensure_managed_clone` reuses an existing valid git checkout at `repo_dir` whose `origin` remote matches `owner/repo` (case-insensitive, supporting both HTTPS and SSH remote URLs).
- `ensure_managed_clone` refuses without deleting or modifying files when `repo_dir` already exists as a non-git directory OR as a git repo pointing at a different `origin` remote (Review Focus #3).
- `ensure_managed_clone` with an injected clone runner creates parent dirs, runs the clone command, and cleans up a partial directory created at `repo_dir` if cloning fails (while leaving a pre-existing directory untouched) (Review Focus #3).

- [ ] **Step 2: Run workspace-git tests to verify failure**

Run: `cargo test -p review-workspace-git`
Expected: FAIL (missing `cache` module and `gh` auth wrapping).

- [ ] **Step 3: Implement `process.rs` auth wrapping and `cache.rs`**

- In `process.rs` (`get_stdout_from_output`): when `program == "gh"` and `review_core::is_gh_auth_failure_text(stderr.trim())`, return `Err(anyhow::Error::new(ForgeAuthError::new(format!("gh failed: {}", stderr.trim()))))`.
- In `cache.rs`: implement `managed_repo_dir`, `parse_owner_repo_from_remote_url` (supporting `https://.../owner/repo(.git)` and `git@host:owner/repo(.git)`), `verify_existing_clone`, `ensure_managed_clone_with` (testable with a fake cloner), and `ensure_managed_clone` (calling `process::run("gh", &["repo", "clone", &slug, &target_text], parent)`). Export `managed_repo_dir` and `ensure_managed_clone` from `lib.rs`.

- [ ] **Step 4: Run tests and clippy for `review-workspace-git`**

Run: `cargo test -p review-workspace-git && cargo clippy -p review-workspace-git --all-targets -- -D warnings`
Expected: PASS with zero warnings.

- [ ] **Step 5: Commit**

```bash
git add crates/review-workspace-git
git commit -m "feat(workspace): add managed clone cache and gh auth error wrapping"
```

---

### Task 4: Protocol v9, CLI `owners` / `repos` / Out-of-Repo `checkout` / Exit Code `3` (`review-rpc`, `jpr-review`)

help-me-pick: implement L2 (hours=1.5 cause=known material=familiar stakes=medium verified=yes)

**Files:**
- Modify: `Cargo.toml`, `lua/jpr/init.lua`, `lua/jpr/rpc.lua` (version `0.8.0` and `PROTOCOL_VERSION = 9` lockstep)
- Modify: `crates/review-rpc/src/protocol.rs`, `crates/review-rpc/src/server.rs`, `crates/review-rpc/src/server/ticker.rs`
- Create: `crates/jpr-review/src/commands/owners.rs`, `crates/jpr-review/src/commands/repos.rs`
- Modify: `crates/jpr-review/src/main.rs`, `crates/jpr-review/src/cli.rs`, `crates/jpr-review/src/commands/mod.rs`, `crates/jpr-review/src/commands/checkout.rs`, `crates/jpr-review/src/commands/local.rs`
- Modify: `crates/jpr-review/src/tui_schema/specs.rs`, `crates/jpr-review/src/tui_schema/steps.rs`, `crates/jpr-review/src/tui_schema/prefill.rs`, `crates/jpr-review/src/tui_schema/convert.rs`, `crates/jpr-review/src/tui_schema/tests/specs.rs`, `crates/jpr-review/src/tui_schema/tests/convert.rs`, `crates/jpr-review/src/tui_schema/tests/prefill.rs`

**Interfaces:**
- Consumes: `review_core::{AUTH_EXIT_CODE, is_auth_error}`, `review_forge_github::GhForge::{list_owners, list_repos}`, `review_workspace_git::{managed_repo_dir, ensure_managed_clone, main_repo_root}`
- Produces:
  - `PROTOCOL_VERSION = 9` (`crates/review-rpc/src/protocol.rs` & `lua/jpr/rpc.lua`), `VERSION = "0.8.0"` (`Cargo.toml` & `lua/jpr/init.lua`)
  - `RpcError::AUTH_REQUIRED = -32001`
  - CLI subcommands: `jpr-review owners`, `jpr-review repos [--owner <LOGIN>] [--limit <N>]`, out-of-repo `jpr-review checkout --pr <N> --repo <OWNER/NAME>`
  - Process exit code `3` on `ForgeAuthError` for all `jpr-review` commands

- [ ] **Step 1: Write failing tests for RPC `-32001`, background ticker flag, CLI parsing, `tui_schema`, `local`, `checkout`, and exit code `3`**

Add tests across:
- `crates/review-rpc/src/server.rs` (or `crates/review-rpc/tests/`): `engine_result_to_rpc(Err(ForgeAuthError))` returns `RpcError::AUTH_REQUIRED` (`-32001`), while non-auth error returns `RpcError::ENGINE_ERROR` (`-32000`); ticker background sync failure emits `Event::SyncFailed { auth_required: true, is_background: true }`.
- `crates/jpr-review/src/cli.rs`: `owners` parses with no args; `repos` parses defaults (`owner: None, limit: 100`) and `--owner acme --limit 25`, rejecting `--limit 0`.
- `crates/jpr-review/src/tui_schema/tests/`: `owners` and `repos` are present in `build_command_specs()`, pass `validate_command_specs`, convert answers cleanly in `answers_to_command` (both `owner_scope = "false"` and `owner_scope = "true"`), and satisfy schema completeness.
- `crates/jpr-review/src/commands/local.rs`: `resolve_local_output` propagates `Err(ForgeAuthError)` instead of falling back to local mode, while non-auth probe errors (`Err(anyhow!("offline"))`) still warn and return `Ok(LocalCommandOutput::Local { .. })`.
- `crates/jpr-review/src/commands/checkout.rs`: out-of-repo checkout without `--repo` returns a clear error advising `--repo <owner/name>`; helper `exit_code_for_error(&err)` returns `3` for `ForgeAuthError` and `1` otherwise.

- [ ] **Step 2: Run workspace Rust tests to verify failure**

Run: `cargo test --workspace --all-features`
Expected: FAIL (missing `AUTH_REQUIRED`, `Command::Owners`/`Repos`, `tui_schema` entries, and `local`/`checkout` changes).

- [ ] **Step 3: Implement RPC v9, `owners`/`repos` commands + `tui_schema`, out-of-repo `checkout`, `local` auth propagation, and exit code `3`**

- Bump `PROTOCOL_VERSION = 9` in `crates/review-rpc/src/protocol.rs` and `lua/jpr/rpc.lua`; bump version to `0.8.0` in `Cargo.toml` and `lua/jpr/init.lua` (also update any existing Rust/Lua tests that hardcode `8` or `"0.7.0"` if present).
- In `crates/review-rpc`: add `RpcError::AUTH_REQUIRED = -32001`, map `review_core::is_auth_error(&error)` in `engine_result_to_rpc`, and switch `ticker.rs` to call `guard.sync_background()` and `guard.flush_queued_background()`.
- In `crates/jpr-review`:
  - Add `Command::Owners` and `Command::Repos { owner: Option<String>, limit: u32 }` (default `100`, range `1..`).
  - Create `commands/owners.rs` and `commands/repos.rs` printing JSON arrays via `GhForge::list_owners` and `GhForge::list_repos`.
  - Update `commands/checkout.rs`: check `main_repo_root(&cwd).ok()`. If `Some(_)`, run existing in-repo flow unchanged. If `None`, require `expected_repo`, parse `(owner, repo)`, look up PR via `GhForge::new(cwd, Some(slug)).pull_request(number)?`, resolve `cache_dir = managed_repo_dir(xdg_cache_home, home, STATE_APP, &owner, &repo)?`, narrate clone if `!cache_dir.exists()`, call `ensure_managed_clone(&cache_dir, &owner, &repo)?`, then reuse or run `checkout_pr(&cache_dir, number, &command)?`.
  - Update `commands/local.rs`: `resolve_local_output` returns `Result<LocalCommandOutput>` and propagates `Err(error)` when `review_core::is_auth_error(&error)`.
  - Update `main.rs` (`report_result`) and expose `exit_code_for_result` / `exit_code_for_error` in `lib.rs` (or `commands/mod.rs`) returning `ExitCode::from(AUTH_EXIT_CODE)` (`3`) on `is_auth_error`.
  - Register `owners` and `repos` across `tui_schema/{specs,steps,prefill,convert}.rs`.

- [ ] **Step 4: Run full Rust test suite and clippy**

Run: `cargo test --workspace --all-features && cargo clippy --workspace --all-targets --all-features -- -D warnings`
Expected: PASS with zero warnings (including `dependency_rule.rs` and all `tui_schema` completeness tests).

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml crates/ lua/jpr/init.lua lua/jpr/rpc.lua
git commit -m "feat(cli,rpc): add protocol v9 auth codes, owners/repos commands, and managed-cache checkout"
```

---

### Task 5: Unified Neovim Auth Recovery Wrapper (`lua/jpr/auth/`)

help-me-pick: implement L2 (hours=1.5 cause=known material=familiar stakes=medium verified=yes)

**Files:**
- Create: `lua/jpr/auth/init.lua`, `lua/jpr/auth/modal.lua`, `lua/jpr/auth/terminal.lua`
- Test: `tests/lua/auth_spec.lua`

**Interfaces:**
- Consumes: `jpr.tui.wizard` (`close`), `jpr.tui.wizard.window` (`get_modal_width`, `create_menu_window`, `paint_menu_window`, `close_handle`, `create_window_config`), `jpr.tui.render` (`wrap_text`, `to_single_line`)
- Produces (`require("jpr.auth")`):
  - `M.AUTH_EXIT_CODE = 3`, `M.RPC_AUTH_REQUIRED = -32001`
  - `M.is_cli_auth_error(result) -> boolean`
  - `M.is_rpc_auth_error(rpc_error) -> boolean`
  - `M.prompt_and_resume(opts)` where `opts = { key?: string, is_background?: boolean, detail?: string, on_authenticated: fun(), on_cancel?: fun(reason: string) }`
  - `M.is_active() -> boolean`
  - `M.reset()` (test teardown helper)

- [ ] **Step 1: Write failing Lua specs in `tests/lua/auth_spec.lua`**

Cover every auth state transition (stubbing `vim.fn.executable`, `vim.fn.jobstart`, `vim.system`, and `vim.fn.getmousepos`):
- `is_cli_auth_error({ code = 3 }) == true`, `is_cli_auth_error({ code = 1 }) == false`; `is_rpc_auth_error({ code = -32001 }) == true`, `is_rpc_auth_error({ code = -32000 }) == false`.
- Missing `gh` binary (`vim.fn.executable("gh") == 0`): notifies install error, does NOT open modal or call `jobstart`, calls `on_cancel("missing_gh")` (Review Focus #5).
- Prompt modal shows `"GitHub Authentication Required"`, `"Authenticate with GitHub"` (`[auth]`), and `"Cancel"` (`[cancel]`); closes any open `jpr.tui.wizard` modal cleanly.
- Keyboard (`<CR>`/`l`) OR `<LeftMouse>` click on the `Authenticate with GitHub` row closes the modal, opens a centered floating terminal running `jobstart({ "gh", "auth", "login" }, { term = true, on_exit = ... })`, and on `on_exit` verifies with `vim.system({ "gh", "auth", "status" })`.
- When `gh auth status` exits `0`: closes terminal, resumes every queued `on_authenticated()` callback once, and clears background decline suppression.
- When `gh auth status` exits non-zero (incomplete login / Ctrl-C): closes terminal and re-opens the auth modal with `"GitHub authentication did not complete"` keeping the queue intact so choosing `Authenticate with GitHub` retries and choosing `Cancel` fires `on_cancel("incomplete")` (Review Focus #2).
- Manual terminal window close (`WinClosed` / `BufWipeout`) stops the login job, still runs `gh auth status` once, and resumes if authenticated or re-prompts Retry/Cancel if not (Review Focus #2).
- Single-flight deduplication: two overlapping `prompt_and_resume` calls with the same `key` open one modal and fire `on_authenticated` once; two calls with distinct keys both resume after one login.
- Background suppression: declining sets `is_background_suppressed = true` so subsequent `is_background = true` calls skip prompting and invoke `on_cancel("declined")`, whereas a subsequent `is_background = false` explicit call clears suppression and shows the modal.

- [ ] **Step 2: Run auth spec to verify failure**

Run: `nvim --headless -u NONE -l tests/lua/auth_spec.lua`
Expected: FAIL (`module 'jpr.auth' not found`).

- [ ] **Step 3: Implement `lua/jpr/auth/{init,modal,terminal}.lua`**

- `lua/jpr/auth/modal.lua`: pure layout builder + centered floating prompt window with `j`/`k`/`<Down>`/`<Up>`/`gg`/`G`, `<CR>`/`l`/`<Right>`/`<Tab>`, `q`/`<Esc>`, and `<LeftMouse>` click activation via `vim.fn.getmousepos()` mapped through `layout.item_for_line`.
- `lua/jpr/auth/terminal.lua`: centered floating terminal running `vim.fn.jobstart({ "gh", "auth", "login" }, { term = true, on_exit = ... })`, `startinsert`, `WinClosed`/`BufWipeout` guard stopping job and invoking verification callback once (`is_settled` guard so `on_exit` and `WinClosed` never double-verify).
- `lua/jpr/auth/init.lua`: single-flight coordinator, `gh` executable check, background suppression flag, keyed queue deduplication, `gh auth status` async verification via `vim.system`, and retry/resume draining. Keep every function `<= 45` lines.

- [ ] **Step 4: Run auth spec to verify it passes**

Run: `nvim --headless -u NONE -l tests/lua/auth_spec.lua`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/auth tests/lua/auth_spec.lua
git commit -m "feat(nvim): add unified single-flight gh auth recovery modal and terminal"
```

---

### Task 6: Wire Global Auth Wrapper, Compose Draft Recovery & Multi-Repo Buffer Safety

help-me-pick: implement L2 (hours=1.5 cause=known material=familiar stakes=medium verified=yes)

**Files:**
- Modify: `lua/jpr/session/init.lua`, `lua/jpr/session/open.lua`, `lua/jpr/session/open_local.lua`, `lua/jpr/session/commands.lua`, `lua/jpr/session/events.lua`
- Modify: `lua/jpr/comments/compose.lua`
- Modify: `lua/jpr/views/diff/init.lua`, `lua/jpr/views/loading.lua`
- Test: `tests/lua/auth_integration_spec.lua`

**Interfaces:**
- Consumes: `require("jpr.auth")` (`is_cli_auth_error`, `is_rpc_auth_error`, `prompt_and_resume`)
- Produces:
  - `session.list_open_prs(on_result, on_error, opts)` where `opts = { repo?: string, on_reopen?: fun() }`
  - `session.open_tab_numbers(repo?: string) -> table<integer, boolean>`
  - Collision-safe `session.buf_key(session) -> string` (preserving `tostring(session.number)` when no other session collides, disambiguating by repo/tab on same-PR-number collision across repos)
  - Global auth interception on CLI exit code `3`, RPC `-32001`, and `syncFailed` (`authRequired`, `isBackground`)
  - Compose draft preservation on auth cancel in `lua/jpr/comments/compose.lua`

- [ ] **Step 1: Write failing Lua integration specs in `tests/lua/auth_integration_spec.lua`**

Cover:
- `session.list_open_prs(..., { repo = "octo/widgets" })` passes `--repo octo/widgets` to `jpr-review prs`, intercepts exit code `3`, runs auth, and retries listing PRs (invoking `opts.on_reopen` if the wizard was closed for the auth modal).
- `session.open(7, "octo/widgets")` hitting checkout exit code `3` cancels/closes the pending loading tab cleanly, runs auth, and re-invokes `session.open(7, "octo/widgets")` on success.
- `session.open_local()` hitting exit code `3` runs auth and re-invokes `session.open_local()` on success; cancelling aborts cleanly without opening a session.
- `session.request(session, "comment", ...)` hitting RPC `-32001` runs auth and replays the exact same RPC request on success.
- Simultaneous `syncFailed { authRequired = true, isBackground = false }` notification AND `sync` RPC `-32001` response on the same tab opens ONE auth modal and sends ONE `sync` retry on completion (Review Focus #1).
- Background `syncFailed { authRequired = true, isBackground = true }` after decline stays suppressed, whereas foreground `syncFailed { authRequired = true, isBackground = false }` (from `setViewed` or post-push resync) clears suppression and shows the auth modal.
- Submitting a comment/reply/edit/promote from `compose.lua` when RPC returns `-32001` and the user cancels auth reopens the compose editor prefilled with the user's unsent body text (no lost draft).
- Opening PR `#7` in `org-a/repo` and PR `#7` in `org-b/repo` in two tabs: `session.buf_key` keeps `"7"` for the first tab and produces a distinct key for the second tab so `jpr://panel/...`, `jpr://stream/...`, `jpr://base/...`, `jpr://conversation/...`, and `jpr://loading/...` never raise `E95`; `open_tab_numbers("org-b/repo")` does not mark `#7` as `[open]` when only `org-a/repo` `#7` is open; `pending_by_key` tracks concurrent checkouts for the same PR number in different repos independently.

- [ ] **Step 2: Run the new integration spec to verify failure**

Run: `nvim --headless -u NONE -l tests/lua/auth_integration_spec.lua`
Expected: FAIL.

- [ ] **Step 3: Implement session auth wiring, compose draft recovery, and multi-repo buffer disambiguation**

- `lua/jpr/session/init.lua`:
  - Update `M.buf_key(session)` to cache/return `session.buf_key_value`, choosing `tostring(session.number)` when no other valid session in `M.by_tab` (and no existing `jpr://panel/<number>` buffer owned by another session) uses that number, otherwise `<sanitized_repo>-<number>` (or `<number>-tab<tab>` fallback).
  - In `M.request`: when `auth.is_rpc_auth_error(request_error)` and `not session.closing`, invoke `auth.prompt_and_resume` to replay `M.request(session, method, params, on_result, on_error)` on auth, or invoke `on_error(request_error)` on cancel without duplicating noisy error banners.
- `lua/jpr/session/open.lua`:
  - Accept optional `opts` (`opts.repo`, `opts.on_reopen`) in `list_open_prs` and append `{ "--repo", opts.repo }`; intercept exit code `3` via `auth.prompt_and_resume`.
  - Key `pending_by_key` by `(repo or ""):lower() .. "#" .. tostring(number)`; filter `collect_open_tab_numbers(session_mod, repo)` by `repo` when supplied.
  - In `on_checkout_exit`: when `auth.is_cli_auth_error(result)`, close loading view + tab cleanly, then call `auth.prompt_and_resume` to re-run `open_pull_request(session_mod, number, repo)`.
- `lua/jpr/session/open_local.lua`: intercept exit code `3` in `open_local_worktree` via `auth.prompt_and_resume` to re-run `open_local_worktree(session_mod, base_ref)`.
- `lua/jpr/session/commands.lua`: in `sync_session`, intercept `auth.is_rpc_auth_error(sync_error)` with `key = "sync:" .. tostring(session.tab)`, `is_background = false`, retrying `session_mod.sync(session)`.
- `lua/jpr/session/events.lua`: in `handle_event_notification` for `syncFailed`, when `params.authRequired == true`, call `auth.prompt_and_resume({ key = "sync:" .. tostring(session.tab), is_background = params.isBackground == true, on_authenticated = function() if not session.closing then require("jpr.session").sync(session) end end })`.
- `lua/jpr/comments/compose.lua`: pass an `on_error` handler to `session.request` in `open_new`, `open_reply`, `open_edit`, and `open_promote` that reopens `open_editor` with `initial_text = body` (and original origin/title/anchor) whenever `auth.is_rpc_auth_error(err)` and `not session.closing`.
- `lua/jpr/views/diff/init.lua` & `lua/jpr/views/loading.lua`: route buffer names through `require("jpr.session").buf_key(session)` so multi-repo same-PR-number sessions never collide on `jpr://base/...` or `jpr://loading/...`.

- [ ] **Step 4: Run new integration spec and existing Lua specs**

Run: `./scripts/test-lua.sh`
Expected: PASS (all existing specs plus `auth_spec.lua` and `auth_integration_spec.lua`).

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/session lua/jpr/comments/compose.lua lua/jpr/views/diff/init.lua lua/jpr/views/loading.lua tests/lua/auth_integration_spec.lua
git commit -m "feat(nvim): wire global gh auth recovery, compose draft preservation, and multi-repo buffer keys"
```

---

### Task 7: Pre-Palette Non-Git-Repo Picker & Repo-Scoped Command Palette

help-me-pick: implement L2 (hours=1.5 cause=known material=familiar stakes=low verified=yes)

**Files:**
- Create: `lua/jpr/repo_picker.lua`
- Modify: `lua/jpr/init.lua`, `lua/jpr/commands/schema.lua`, `lua/jpr/tui/render.lua`, `lua/jpr/tui/wizard/palette.lua`
- Test: `tests/lua/repo_picker_spec.lua`

**Interfaces:**
- Consumes: `require("jpr.auth")`, `require("jpr.tui.wizard")`, `require("jpr.session")` (`list_open_prs`, `open`)
- Produces:
  - `require("jpr.repo_picker").detect_git_repo(cwd, callback)`
  - `require("jpr.repo_picker").pick(on_selected, opts?)`
  - Repo-scoped palette context: `context.repo`, `context.is_git_repo`, `context.title`, `context.on_back`
  - `command.requires_git_repo = true` on `local` in `lua/jpr/commands/schema.lua`

- [ ] **Step 1: Write failing Lua specs in `tests/lua/repo_picker_spec.lua`**

Cover:
- Bare `:Jpr` inside a git repo (or when a tab session is already open): skips `repo_picker` and opens the global command palette immediately (unchanged behavior).
- Bare `:Jpr` outside a git repo with **zero orgs** (`#owners == 1`, personal profile only): skips the owner menu automatically, loads repos for `owners[1].login`, lets the user select a repo, and opens the global command palette with `title = " Jpr Commands · <owner/repo> "` and `context.repo = "<owner/repo>"` (Review Focus #4).
- Bare `:Jpr` outside a git repo with **1+ orgs** (`#owners > 1`): shows `Step 1 of 2 · Select Account or Organization` with personal profile first (`[you]`) and orgs (`[org]`); picking an org loads `jpr-review repos --owner <org>` showing `[private]`/`[archived]` badges and updated date; pressing `h` in repo list returns to the owner list; picking an owner with 0 repos renders a helpful empty message and lets `h` go back (Review Focus #4).
- Pressing `h`/`<Left>`/`<S-Tab>` in the repo-scoped palette calls `context.on_back` to re-open the repo picker, and the palette footer displays `[h] repos`.
- Inside the repo-scoped palette:
  - `local` is muted (`JprMuted`) when `context.is_git_repo == false` and executing it notifies a clear error requiring a local git checkout.
  - `open` -> `Pick from Open PRs` passes `repo = context.repo` to `session.list_open_prs` and calls `session.open(number, context.repo)` on selection.
  - `open` -> `Enter PR Number or URL` with `"42"` calls `session.open(42, context.repo)`; with `"https://github.com/other/repo/pull/9"` calls `session.open(9, "other/repo")`.
- Bare `:Jpr open` outside a git repo runs `repo_picker.pick` first and opens the `:Jpr open` PR picker (`start_step_id = "pr"`) for the chosen repo.
- Auth failure (exit code `3`) during `jpr-review owners` OR `jpr-review repos` triggers `jpr.auth.prompt_and_resume`, and after auth succeeds resumes at the interrupted step and completes into the repo-scoped palette.

- [ ] **Step 2: Run repo picker spec to verify failure**

Run: `nvim --headless -u NONE -l tests/lua/repo_picker_spec.lua`
Expected: FAIL (`module 'jpr.repo_picker' not found`).

- [ ] **Step 3: Implement `lua/jpr/repo_picker.lua` and wire `init.lua`, `schema.lua`, `render.lua`, `palette.lua`**

- Create `lua/jpr/repo_picker.lua`:
  - `detect_git_repo(cwd, callback)` via async `vim.system({ "git", "rev-parse", "--is-inside-work-tree" }, { cwd = cwd, text = true, timeout = 3000 })`.
  - `list_owners(on_result, on_error)` calling `jpr-review owners` and `list_repos(owner, on_result, on_error)` calling `jpr-review repos --owner <owner>`, both wrapped in `auth.prompt_and_resume` on exit code `3`.
  - `pick(on_selected)` using `jpr.tui.wizard` (fetching owners, skipping owner step when `#owners == 1`, showing owner -> repo steps when `#owners > 1`, calling `on_selected(repo.nameWithOwner)`).
- Update `lua/jpr/tui/render.lua` and `lua/jpr/tui/wizard/palette.lua`:
  - Support `context.on_back` (`h`/`<Left>`/`<S-Tab>` bindings + `[h] repos` footer hint).
  - Mute commands with `command.requires_git_repo and context.is_git_repo == false` using `JprMuted`.
- Update `lua/jpr/commands/schema.lua`:
  - Pass `context.repo` through `load_open_pr_options` (with `on_reopen` callback that reopens the `open` PR picker step on auth resume) and `execute_open_command` (preserving URL repo override).
  - Add `requires_git_repo = true` on `local` and guard its `execute` when `context and context.is_git_repo == false`.
- Update `lua/jpr/init.lua`:
  - On bare `:Jpr` (when `not context.has_session`) and bare `:Jpr open` (when `not context.has_session`): run `repo_picker.detect_git_repo(vim.fn.getcwd(), ...)` before opening the palette / open-PR picker, invoking `repo_picker.pick` when `not is_git_repo`.

- [ ] **Step 4: Run all Lua specs**

Run: `./scripts/test-lua.sh`
Expected: PASS (every existing spec including `command_spec.lua` and `palette_and_open_picker_spec.lua`, plus `repo_picker_spec.lua`).

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/repo_picker.lua lua/jpr/init.lua lua/jpr/commands/schema.lua lua/jpr/tui/render.lua lua/jpr/tui/wizard/palette.lua tests/lua/repo_picker_spec.lua
git commit -m "feat(nvim): add pre-palette non-git-repo picker and repo-scoped command palette"
```

---

### Task 8: Documentation, Release Build & Full Verification

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=low verified=yes)

**Files:**
- Modify: `docs/architecture.md`, `docs/protocol.md`, `docs/decisions.md`, `docs/rules/cli-ux.md`, `README.md`

**Interfaces:**
- Consumes: completed Rust and Lua implementation from Tasks 1-7
- Produces: up-to-date docs, compiled `target/release/jpr-review` (`0.8.0`, `PROTOCOL_VERSION = 9`), and verified green `just check`

- [ ] **Step 1: Update project documentation to reflect `0.8.0` and `PROTOCOL_VERSION = 9`**

- `docs/protocol.md`: bump header to `version 9`, document `-32001` (`AUTH_REQUIRED`) in Errors, document `authRequired` and `isBackground` on `syncFailed`, add `Version 9` changelog entry.
- `docs/architecture.md`: document `review-core/src/auth.rs`, `review-forge-github/src/discovery.rs`, `review-workspace-git/src/cache.rs`, `jpr-review owners` / `repos` / out-of-repo managed-cache `checkout` / exit code `3`, `lua/jpr/auth/` and `lua/jpr/repo_picker.lua`, and multi-repo `buf_key` disambiguation.
- `docs/decisions.md`: record the managed XDG clone cache decision (A1), structured Rust auth-error signaling (`ForgeAuthError`, exit code `3`, RPC `-32001`, `SyncFailed.authRequired`/`isBackground`) + single-flight Lua auth recovery (B1), and compose draft preservation / multi-repo buffer disambiguation calls.
- `docs/rules/cli-ux.md`: document exit code `3` for unauthenticated `gh` failures alongside `0`/`1`/`2`.
- `README.md`: document running `:Jpr` outside a git repository (org -> repo picker + managed clone cache) and automatic `gh auth login` recovery.
- Verify zero em dashes (U+2014) across all edited docs.

- [ ] **Step 2: Rebuild release binary and run full `just check`**

Run: `cargo build --release -p jpr-review && just check`
Expected: Release binary compiles cleanly (`jpr-review 0.8.0`), `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --all-features -- -D warnings`, `cargo test --workspace --all-features`, and `./scripts/test-lua.sh` all PASS.

- [ ] **Step 3: Commit docs**

```bash
git add docs/architecture.md docs/protocol.md docs/decisions.md docs/rules/cli-ux.md README.md
git commit -m "docs: document non-repo picker, managed clone cache, and protocol v9 gh auth recovery"
```

---

## Final Branch Review

help-me-pick: bug-hunting-and-code-review L3 (hours=1 cause=unknown material=familiar stakes=medium verified=yes)

After Task 8 passes `just check`, run the repository's mandatory completion sequence:
1. Run `/avandar-code-review` across the branch, fix every violation, verify `just check`, and commit review fixes.
2. Run full `/diff-review` (Initial mode, never walkthrough-only) producing `.difit/` review guides and `.difit/<stem>-walkthrough.md`.
3. Copy and commit the walkthrough to `docs/code-walkthroughs/2026-11-25_non-repo-picker-and-gh-auth.md`.
