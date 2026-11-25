# Design: Non-Git-Repo Repository Picker, Managed Clone Checkout, and Global `gh` Auth Recovery (`0.8.0`)

## Intent and Why

Today, `jpr-nvim` assumes Neovim is opened inside a local git checkout and that the GitHub CLI (`gh`) is already authenticated:

1. Running bare `:Jpr` (or `<leader>J`) outside a git repository opens the global command palette directly with no repository context. Selecting `Open Pull Request` then fails because `jpr-review prs` has no repository to query and `jpr-review checkout` calls `main_repo_root(&cwd)` (`git rev-parse --git-common-dir`), which requires an existing local git checkout.
2. Whenever `gh` is unauthenticated (fresh machine, expired OAuth token, logged-out session), `jpr-review` fails with raw `gh` stderr text. In comment mutations (`comment`, `reply`, `editMessage`, etc.), unauthenticated failures are even misclassified as validation rejections (`ForgeWriteError::Rejected`). In `:Jpr local`, an unauthenticated PR probe is silently swallowed as a warning.

This design solves both gaps cohesively:

- **Pre-palette repository selection outside a git repo:** When Neovim is not inside a git repository and has no active Jpr session in the current tab, running bare `:Jpr` detects that condition *before* showing the global command palette. It fetches the user's GitHub accounts (personal profile plus organizations), prompts for an organization/profile first when the user belongs to one or more organizations (skipping straight to repositories when only the personal profile exists), prompts for a repository, and then opens the global command palette already scoped to that chosen repository.
- **Managed clone cache for out-of-repo PR checkout:** When opening a pull request for a repository chosen outside any local git checkout, `jpr-review checkout` automatically clones the repository on demand into an XDG cache directory and creates/reuses PR worktrees alongside that cached clone, keeping the entire local-worktree review engine (`GitWorkspace`, diffs, file editing, coding agent) working unchanged.
- **Plugin-wide `gh` authentication recovery:** Whenever *any* `gh` invocation across the plugin fails due to missing or expired authentication (discovery, PR listing, checkout/cloning, local PR detection, RPC sync, background poll, or GitHub mutations), the plugin intercepts the structured auth error, tells the user Jpr requires an authenticated GitHub CLI, offers a keyboard-selectable and mouse-clickable authenticate action, runs `gh auth login` in a floating terminal, detects completion via `gh auth status`, and automatically resumes the interrupted flow.

## Goals

1. **Pre-palette repository picker outside git checkouts:** Detect when Neovim's working directory is outside a git repository (and the current tab has no active session) before opening the `:Jpr` command palette. Fetch owners and repositories from the user's `gh` account, show an owner/org step first whenever `#owners > 1` (personal profile first, then organizations), show the owner's repositories, and open the palette scoped to the selected `owner/name`.
2. **Consistent bare `:Jpr open` outside git checkouts:** Reuse the same owner -> repository picker when bare `:Jpr open` is invoked outside a git repository without an active session, then advance directly into the open-PR picker for that repository. Direct `:Jpr open <PR-URL>` (or `:Jpr <PR-URL>`) skips the picker and checks out directly using the URL's `owner/name`.
3. **Zero-friction managed clone cache (Decision A1):** Allow `jpr-review checkout --pr <n> --repo <owner/name>` to work outside any git repository by cloning `owner/name` on demand into `$XDG_CACHE_HOME/jpr/repos/<owner>/<repo>` (defaulting to `~/.cache/jpr/repos/<owner>/<repo>`) with `gh repo clone`, then creating/reusing PR worktrees beside it via the existing worktree machinery.
4. **Structured Rust auth-error classification (Decision B1):** Classify unauthenticated `gh` failures once in `review-core` (`ForgeAuthError`), produce it in `review-forge-github` and `review-workspace-git`, surface it deterministically via CLI exit code `3`, JSON-RPC error code `-32001` (`AUTH_REQUIRED`), and `Event::SyncFailed { message, auth_required: true }` (`PROTOCOL_VERSION = 9`).
5. **Single-flight Neovim auth recovery wrapper (`lua/jpr/auth.lua`):** Intercept every CLI exit code `3`, RPC `-32001`, and `syncFailed` with `authRequired = true` through one central module. Display a centered floating prompt (keyboard + `<LeftMouse>` clickable `Authenticate with GitHub` / `Cancel`), run `gh auth login` in a centered floating terminal, confirm login via `gh auth status` on exit, and resume all waiting operations automatically.
6. **CLI & Schema-to-TUI parity:** Expose `jpr-review owners` and `jpr-review repos` as scriptable JSON subcommands, registered in `crates/jpr-review/src/tui_schema/` with automated completeness tests.

## Non-Goals

- Scanning local filesystem directories (e.g. `~/src`) to discover existing clones (Decision A1 explicitly chose the managed clone cache).
- Reviewing pull requests without a local git worktree (virtual GitHub-only buffers).
- Managing multiple GitHub Enterprise hostnames or custom `GH_HOST` selectors in the picker UI (`gh`'s default host configuration governs).
- Persisting the picked non-git repository across Neovim restarts or writing a new `:Jpr` subcommand for repository switching (pressing `h`/`<Left>`/`<S-Tab>` in the repo-scoped palette returns to the repo picker).
- Auto-installing `gh` if the `gh` binary itself is missing from `PATH`.
- Deleting or garbage-collecting cached clones automatically.

## Anti-Goals

- Proactively running `gh auth status` before every command (adds unnecessary subprocess latency to every authenticated call and still misses mid-session token expiry).
- Duplicating `gh` API invocation, JSON parsing, or stderr auth regexes in Lua instead of the Rust engine.
- Misclassifying unauthenticated `gh` errors on comment/review mutations as `ForgeWriteError::Rejected` (which marks valid comments `failed` locally) or silently queueing them without prompting the user.
- Opening duplicate auth modals when overlapping calls or a `sync` request plus its `syncFailed` event fail together.
- Nagging the user every 60 seconds from the background poller after they explicitly declined authentication.
- Deleting or overwriting an unrelated or non-git directory at the managed cache path.
- Leaking UI, terminal, or Neovim dependencies into `crates/review-*`.

## Constraints

- **Dependency rule:** `crates/review-*` crates remain strictly UI-free (`crates/jpr-review/tests/dependency_rule.rs`). Auth error classification, owner/repo discovery, and managed clone cache checkout all live in Rust (`review-model`, `review-core`, `review-forge-github`, `review-workspace-git`, `review-rpc`, `jpr-review`); Lua handles windows, modals, floating terminals, and retry orchestration.
- **Interactive Command Palette & Schema-to-TUI invariant:** New `jpr-review` subcommands (`owners`, `repos`) must be registered in `crates/jpr-review/src/tui_schema/` with human-readable labels paired with `[<id>]`, concise helper text, smart defaults, discriminant-first ordering, Neovim-conventional keys, flag parity, and automated schema completeness tests. The 16 `:Jpr` subcommands in `lua/jpr/commands/schema.lua` remain intact with all existing schema completeness tests green.
- **Code style:** Zero em dashes across code, comments, tests, and docs; functions `<= 45` lines; Red/Green TDD by default; `just check` green (`cargo fmt`, `cargo clippy --workspace --all-targets --all-features -- -D warnings`, `cargo test --workspace --all-features`, `./scripts/test-lua.sh`).
- **Lockstep release & protocol:** Bump workspace `Cargo.toml` and `lua/jpr/init.lua` to `0.8.0`, and bump `PROTOCOL_VERSION` from `8` to `9` in `crates/review-rpc/src/protocol.rs` and `lua/jpr/rpc.lua`.
- **Documentation currency:** Update `docs/architecture.md`, `docs/protocol.md`, `docs/decisions.md`, `docs/rules/cli-ux.md` (documenting exit code `3`), and `README.md` in the same change.

## Approaches

Three architectural approaches were evaluated before writing this design:

| Approach | Summary | Trade-offs |
| --- | --- | --- |
| **1. Rust Engine-Backed Discovery & Structured Auth Signals + Unified Lua Auth Gate (Chosen)** | Add `ForgeAuthError` and `is_gh_auth_failure_text` in `review-core`; add `list_owners` (single GraphQL call) and `list_repos` (`gh repo list --json`) in `review-forge-github` exposed as `jpr-review owners` and `jpr-review repos`; add managed clone cache in `review-workspace-git`; surface auth failures via CLI exit code `3`, RPC `-32001`, and `SyncFailed.authRequired` (`PROTOCOL_VERSION = 9`); handle all auth recovery in one single-flight `lua/jpr/auth.lua`. | Honors the binding dependency rule and Schema-to-TUI invariant, eliminates brittle Lua stderr parsing, reuses one GraphQL round-trip for profile + orgs, and gives CLI users `owners`, `repos`, and out-of-repo `checkout`. Requires bumping `PROTOCOL_VERSION` to `9` and rebuilding the engine binary. |
| **2. Lua-Driven `gh` Calls & Stderr Pattern Matching (Rejected)** | Restrict Rust changes to managed clone checkout only; call `gh api` / `gh repo list` directly from Lua and match stderr strings across CLI stderr, RPC `-32000` errors, and `syncFailed` messages. | Smaller Rust diff and no protocol bump, but breaks the Rust-first architecture boundary, duplicates `gh` logic in Lua, and relies on fragile text matching across RPC error chains. |
| **3. Proactive `gh auth status` Pre-Flight Before Every Command (Dropped)** | Run `gh auth status` before every `:Jpr` command and discovery step. | Adds 150-400 ms latency to every authenticated invocation and still fails to catch mid-session token expiry during background polling or live session writes. |

Decision A1 selected the **managed clone cache** for out-of-repo checkouts, and Decision B1 selected **Approach 1**.

---

## Detailed Design

### 1. Shared Auth Error Classification (`crates/review-core`, `crates/review-forge-github`, `crates/review-workspace-git`)

#### `crates/review-core/src/auth.rs`
Introduce a dedicated auth-error module re-exported from `review_core`:

```rust
/// Exit code used by `jpr-review` when a command fails because `gh` is not
/// authenticated with GitHub.
pub const AUTH_EXIT_CODE: u8 = 3;

/// Error raised when `gh` fails because GitHub CLI authentication is missing
/// or invalid (as opposed to `gh` being uninstalled, offline, or rejecting a
/// request for domain validation reasons).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForgeAuthError {
    message: String,
}
```

- `ForgeAuthError` implements `Display` (printing `self.message`) and `std::error::Error`.
- `pub fn is_auth_error(error: &anyhow::Error) -> bool`: returns `error.chain().any(|cause| cause.is::<ForgeAuthError>())`.
- `pub fn is_gh_auth_failure_text(text: &str) -> bool`: pure case-insensitive classifier.
  - Matches canonical `gh` unauthenticated / invalid-token failure strings:
    - `"gh auth login"`
    - `"not logged into any github hosts"`
    - `"not authenticated"`
    - `"authentication required"`
    - `"failed to authenticate"`
    - `"bad credentials"`
    - `"http 401"`
    - `"no oauth token"`
    - `"requires authentication"`
    - `"token in"` combined with `"is invalid"` (e.g. `"The token in default is invalid."`)
  - Explicitly rejects missing-binary messages (`"is the github cli installed"`, `"no such file or directory"`, `"program not found"`), timeouts, HTTP 403/404/422/5xx, and `"no pull requests found for branch"`.

#### `ForgeWriteError` in `crates/review-core/src/ports.rs`
Extend `ForgeWriteError` with a third variant:

```rust
pub enum ForgeWriteError {
    /// Network timeout, offline `gh`, HTTP 5xx, or rate limit.
    Transient(String),
    /// Validation error (HTTP 4xx / GraphQL refusal) that retrying unchanged
    /// will not fix.
    Rejected(String),
    /// Missing or invalid `gh` authentication; must not queue or mark failed.
    AuthRequired(String),
}
```

#### Producing `ForgeAuthError`
- `crates/review-forge-github/src/gh.rs` (`Gh::run`): when `!output.status.success()`, format the failure as today; if `review_core::is_gh_auth_failure_text(&message)` is true, return `Err(anyhow::Error::new(ForgeAuthError::new(message)))` instead of `bail!`.
- `crates/review-forge-github/src/mutations.rs` (`classify_write_error`): check `review_core::is_auth_error(error)` *before* transient/rejected classification and return `ForgeWriteError::AuthRequired(format!("{error:#}"))`.
- `crates/review-workspace-git/src/process.rs` (`get_stdout_from_output`): when `program == "gh"` and `!output.status.success()`, check `review_core::is_gh_auth_failure_text(&stderr)` and return `Err(anyhow::Error::new(ForgeAuthError::new(detail)))`. This automatically covers both `gh pr checkout` and `gh repo clone`.

#### Handling `ForgeAuthError` inside `ReviewSession` (`crates/review-core`)
- **Comment / review mutations** (`comment`, `reply`, `edit_message`, `delete_message`, `set_resolved`, `toggle_reaction`, `retry_message`, `promote_thread`, `submit_review`):
  - On `ForgeWriteError::AuthRequired(message)`: do **not** queue the operation, do **not** mark optimistic messages `failed`, and revert/leave local state untouched; return `Err(anyhow::Error::new(ForgeAuthError::new(message)))`. (Because `jpr-review serve` translates `ForgeAuthError` to RPC `-32001`, Neovim intercepts it, runs `gh auth login`, and replays the exact RPC mutation cleanly.)
- **Background queue replay (`send_queued_comments` / `send_queued`):**
  - If replaying a queued viewed mark or queued comment op hits an auth error (`is_auth_error` or `ForgeWriteError::AuthRequired`): keep the queued item in place (do NOT drop it and do NOT mark it failed), stop replaying further items for this tick, and emit `Event::SyncFailed { message, auth_required: true, is_background }`.
- **`set_viewed`:**
  - Keeps its existing optimistic local contract (applies the mark locally and queues it if the forge fails), and when the forge failure satisfies `is_auth_error(&error)`, additionally publishes `Event::SyncFailed { message: format!("{error:#}"), auth_required: true, is_background: false }` so Neovim prompts the user to sign in (clearing any prior background-decline suppression) and then syncs the queued mark.
- **`sync` (`fail_sync`) & `push`:**
  - `sync()` (explicit foreground call, including `:Jpr push`'s post-push resync) sets `is_background: false`; background poller ticks (`ticker.rs`, via a dedicated background sync/flush entry point such as `sync_background` / `flush_queued_background`) set `is_background: true`.
  - Sets `auth_required: review_core::is_auth_error(error)` when publishing `Event::SyncFailed { message, auth_required, is_background }`.
  - In unlinked local mode (`sync_or_link_local`), `forge.current_branch_pr()` already propagates non-absent-PR errors; when that error is `ForgeAuthError`, `sync` returns it directly (which `review-rpc` maps to `-32001`).

---

### 2. Domain Models & Wire Protocol (`crates/review-model`, `crates/review-rpc`, `PROTOCOL_VERSION = 9`)

#### New Discovery Models (`crates/review-model/src/forge.rs`, re-exported from `review-model`)

```rust
/// Kind of GitHub account returned by `jpr-review owners`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OwnerKind {
    /// The authenticated user's personal profile.
    User,
    /// A GitHub organization the authenticated user belongs to.
    Organization,
}

/// A GitHub user profile or organization that owns repositories.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ForgeOwner {
    /// Account or organization login (e.g. `"octocat"` or `"acme-corp"`).
    pub login: String,
    /// Optional human-readable display name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Whether this entry is the authenticated user or an organization.
    pub kind: OwnerKind,
}

/// Compact summary of a GitHub repository returned by `jpr-review repos`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ForgeRepo {
    /// Repository slug in `owner/name` form.
    pub name_with_owner: String,
    /// Optional repository description.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Whether the repository is private.
    pub is_private: bool,
    /// Whether the repository is archived.
    pub is_archived: bool,
    /// ISO-8601 timestamp when the repository was last updated.
    pub updated_at: String,
}
```

#### Event & RPC Protocol Update (`PROTOCOL_VERSION = 9`)
- Bump `PROTOCOL_VERSION` from `8` to `9` in `crates/review-rpc/src/protocol.rs` and `lua/jpr/rpc.lua`.
- Bump release version from `0.7.0` to `0.8.0` in workspace `Cargo.toml` and `lua/jpr/init.lua`.
- Add `RpcError::AUTH_REQUIRED: i64 = -32001` in `crates/review-rpc/src/protocol.rs`.
- In `crates/review-rpc/src/server.rs` (`engine_result_to_rpc`):
  - If `review_core::is_auth_error(&error)` -> `RpcError::new(RpcError::AUTH_REQUIRED, format!("{error:#}"))`.
  - Otherwise -> `RpcError::new(RpcError::ENGINE_ERROR, format!("{error:#}"))`.
- In `crates/review-model/src/view/mod.rs` (`Event::SyncFailed`):
  ```rust
  SyncFailed {
      /// What went wrong, for a person to read.
      message: String,
      /// Whether the failure was caused by missing or invalid `gh` authentication.
      #[serde(default)]
      auth_required: bool,
      /// Whether this failure came from the background poller rather than an
      /// explicit user-initiated request (`sync`, `setViewed`, `push`).
      #[serde(default)]
      is_background: bool,
  },
  ```
  Wire JSON shape: `{ "type": "syncFailed", "message": "...", "authRequired": true, "isBackground": false }`.

---

### 3. Owner & Repository Discovery (`crates/review-forge-github`, `crates/jpr-review`)

#### `GhForge::list_owners` (`crates/review-forge-github/src/discovery.rs`)
- Runs paginated GraphQL query against `gh api graphql --input -`:
  ```graphql
  query($after: String) {
    viewer {
      login
      name
      organizations(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { login name }
      }
    }
  }
  ```
- Single round-trip for users with `<= 100` orgs; automatically follows `endCursor` when `hasNextPage` is true.
- Returns `Vec<ForgeOwner>` with the viewer's personal profile (`OwnerKind::User`) first, followed by organizations (`OwnerKind::Organization`) deduplicated by login and sorted case-insensitively by `login`. Empty `name` strings normalize to `None`.

#### `GhForge::list_repos` (`crates/review-forge-github/src/discovery.rs`)
- Signature: `pub fn list_repos(&self, owner: Option<&str>, limit: u32) -> Result<Vec<ForgeRepo>>`.
- Rejects `limit == 0` and validates `owner` (when `Some`) as a safe single path segment (no `/`, whitespace, leading `-`, or control chars).
- Runs:
  `gh repo list [<owner>] --limit <limit> --json nameWithOwner,description,isPrivate,isArchived,updatedAt`
- Parses stdout into `Vec<ForgeRepo>`, normalizing blank descriptions to `None` and preserving `gh`'s recency order.

#### New `jpr-review` CLI Subcommands (`crates/jpr-review`)
- `jpr-review owners`
  - Flags: none.
  - Output: JSON array of `ForgeOwner` on stdout.
  - `tui_schema` entry: id `"owners"`, label `"List GitHub Owners"`, 0 steps.
- `jpr-review repos [--owner <LOGIN>] [--limit <N>]`
  - `--owner <LOGIN>`: optional; omitted lists the authenticated user's personal repositories.
  - `--limit <N>`: optional `u32 >= 1`, default `100`.
  - Output: JSON array of `ForgeRepo` on stdout.
  - `tui_schema` entry: id `"repos"`, label `"List GitHub Repositories"`, discriminant-first steps:
    1. `owner_scope` (toggle, default `"false"`): `"My personal repositories"` vs `"Specific owner or organization"`.
    2. `owner` (text, `when = owner_scope == "true"`): owner/org login, validated non-empty without slashes/whitespace/leading `-`.
    3. `limit` (text, default `"100"`, validated positive `u32`).
- Exit code handling in `crates/jpr-review/src/main.rs`:
  - `report_result` checks `review_core::is_auth_error(&error)`: returns `ExitCode::from(review_core::AUTH_EXIT_CODE)` (`3`) on auth errors, `ExitCode::FAILURE` (`1`) on all other errors, `2` for non-TTY bare invocation.
- `crates/jpr-review/src/commands/local.rs`:
  - Update `resolve_local_output` to return `Result<LocalCommandOutput>`: when `probe_pr()` returns an error satisfying `review_core::is_auth_error(&error)`, propagate that `Err(error)` (causing exit code `3` so the plugin's auth wrapper triggers). Non-auth probe errors (offline, timeout) keep the existing fallback to local mode with a warning.

---

### 4. Managed Clone Cache Checkout (`crates/review-workspace-git`, `crates/jpr-review/src/commands/checkout.rs`)

#### Managed Cache Layout (`crates/review-workspace-git/src/cache.rs`)
- Pure path builder:
  ```rust
  pub fn managed_repo_dir(
      xdg_cache_home: Option<&Path>,
      home: &Path,
      app: &str,
      owner: &str,
      repo: &str,
  ) -> Result<PathBuf>
  ```
  - Uses `xdg_cache_home` when present, non-empty, and absolute; otherwise `home.join(".cache")`.
  - Validates `owner` and `repo` as safe single segments (rejects empty, `.`, `..`, `/`, `\`, whitespace, control chars).
  - Resolves to `<cache_root>/<app>/repos/<owner>/<repo>` (for `app = "jpr"`, e.g. `~/.cache/jpr/repos/octo/widgets`).
  - Because `default_worktree_path(main_root, number)` already places worktrees at `<parent>/<name>-worktrees/pr-<n>`, PR worktrees for cached clones naturally live at `~/.cache/jpr/repos/<owner>/<repo>-worktrees/pr-<n>` with zero changes to worktree path or reuse logic.

#### Ensuring a Managed Clone (`ensure_managed_clone`)
- `pub fn ensure_managed_clone(repo_dir: &Path, owner: &str, repo: &str) -> Result<PathBuf>`:
  - **If `repo_dir` already exists:**
    - Verify `main_repo_root(repo_dir)` succeeds and resolves to `repo_dir` (canonicalized).
    - Verify its `origin` remote URL resolves to `owner/repo` (case-insensitive).
    - If either check fails, return a clear error naming `repo_dir` and refusing to remove or overwrite it.
    - Return `Ok(repo_dir.to_path_buf())`.
  - **If `repo_dir` does not exist:**
    - Create parent directory (`<cache_root>/jpr/repos/<owner>`).
    - Run `gh repo clone <owner>/<repo> <repo_dir>` via `process::run` (so `gh` auth failures automatically produce `ForgeAuthError` and respect the user's configured HTTPS/SSH git protocol).
    - If `gh repo clone` fails and created a partial directory at `repo_dir`, remove only that newly created directory before returning the error.
    - Return `Ok(repo_dir.to_path_buf())`.

#### Updated `jpr-review checkout` (`crates/jpr-review/src/commands/checkout.rs`)
- Determine whether `cwd` is inside a git repository via `review_workspace_git::main_repo_root(&cwd).ok()`.
- **When `cwd` IS inside a git repository:**
  - Preserve existing behavior verbatim: look up PR via `GhForge::new(cwd.clone(), None).pull_request(number)?`, verify `ensure_expected_repo(&pr, expected_repo)?`, reuse or create worktree relative to `cwd`.
- **When `cwd` is NOT inside a git repository:**
  - Require `expected_repo` (`--repo <owner/name>`); if absent, fail with `"not inside a git repository; pass --repo <owner/name> to check out a pull request"`.
  - Parse `(owner, repo)` via `super::parse_repo`.
  - Look up PR via `GhForge::new(cwd.clone(), Some(format!("{owner}/{repo}"))).pull_request(number)?` (validates auth and open PR state before cloning).
  - Resolve `cache_dir = managed_repo_dir(xdg_cache_home, home, STATE_APP, &owner, &repo)?`.
  - Narrate `"Cloning <owner>/<repo> into cache..."` when `cache_dir` does not exist yet, then call `ensure_managed_clone(&cache_dir, &owner, &repo)?`.
  - Run `find_existing_pr_worktree(&cache_dir, ...)` and fall back to `checkout_pr(&cache_dir, number, &command)?`.
  - Print the exact same JSON line `{ "worktree", "repo", "number", "title" }`.
- Note on `worktree_cmd`: when a custom `worktree_cmd` is configured, it runs with `cwd = &cache_dir` (which is a valid git checkout).
- Note on `checkout` interactive CLI stepper (`tui_schema`): update `create_checkout_spec` helper text if needed so `--repo` is also described as enabling checkout outside a git repository (no breaking changes to existing steps).

---

### 5. Unified Neovim Auth Recovery Wrapper (`lua/jpr/auth.lua`)

#### Responsibilities & Public API
`lua/jpr/auth.lua` is the single gatekeeper for `gh` authentication recovery across the entire plugin:

- `M.AUTH_EXIT_CODE = 3`
- `M.RPC_AUTH_REQUIRED = -32001`
- `M.is_cli_auth_error(result)` -> `type(result) == "table" and result.code == M.AUTH_EXIT_CODE`
- `M.is_rpc_auth_error(rpc_error)` -> `type(rpc_error) == "table" and rpc_error.code == M.RPC_AUTH_REQUIRED`
- `M.prompt_and_resume(opts)`:
  - `opts`:
    - `key?: string`: optional deduplication key (e.g. `"sync:" .. session.tab`) so an overlapping `syncFailed` event + `sync` RPC `-32001` only schedules one retry callback.
    - `is_background?: boolean`: `true` when triggered by an unsolicited background `syncFailed` event.
    - `detail?: string`: optional context message.
    - `on_authenticated: fun()`: continuation invoked once `gh auth status` succeeds.
    - `on_cancel?: fun(reason: string)`: invoked if the user declines, closes the prompt/terminal without completing auth, or `gh` is not installed (`"declined"`, `"incomplete"`, `"missing_gh"`).
- `M.reset()` (for tests): clears single-flight queue, active modal/terminal state, and decline suppression flag.

#### Single-Flight & Background Suppression Rules
1. **Missing `gh` binary:** Before opening any modal, check `vim.fn.executable("gh") == 1`. If missing, notify `jpr.error("gh (GitHub CLI) is required on PATH; install it from https://cli.github.com")` and call `on_cancel("missing_gh")`.
2. **Background decline suppression:** If the user declines an auth prompt (`Cancel` / `q` / `<Esc>`), set `is_background_suppressed = true`. Subsequent `is_background = true` calls skip prompting and immediately call `on_cancel("declined")`. Any explicit user-initiated action (`is_background ~= true`) clears suppression and shows the prompt; completing authentication also clears suppression.
3. **Single-flight queue:** While an auth prompt modal OR `gh auth login` terminal is already open, additional `prompt_and_resume` calls enqueue their `{ key, on_authenticated, on_cancel }` (replacing an existing queued entry with the same non-nil `key`) without opening another window.

#### Auth Prompt Modal UI (Keyboard + Mouse Clickable)
- Centered rounded floating window built on `jpr.tui.wizard.window` helpers (`JprTitle`, `JprMuted`, `JprError`), closing any currently open `jpr.tui.wizard` modal cleanly first so windows never stack awkwardly.
- Layout:
  ```text
  ╭─────────────── GitHub Authentication Required ───────────────╮
  │ Jpr cannot work without an authenticated GitHub CLI (gh).    │
  │                                                              │
  │ ▸ Authenticate with GitHub  [auth]                           │
  │     Run `gh auth login` here and resume once signed in.      │
  │   Cancel  [cancel]                                           │
  │                                                              │
  │ [j/k] move  [Enter/Click] select  [q/Esc] cancel             │
  ╰──────────────────────────────────────────────────────────────╯
  ```
- Keybindings & mouse:
  - Normal-mode navigation: `j`/`<Down>`, `k`/`<Up>`, `gg`/`<Home>`, `G`/`<End>`.
  - Confirm: `<CR>`, `l`, `<Right>`, `<Tab>`.
  - Cancel: `q`, `<Esc>`.
  - Mouse click: `<LeftMouse>` resolves clicked line via `vim.fn.getmousepos()`, maps it via `layout.item_for_line[pos.line]`, selects that item, and immediately activates it (`auth` launches `gh auth login`; `cancel` cancels).

#### `gh auth login` Floating Terminal & Completion Detection
- When the user activates `Authenticate with GitHub`:
  1. Close the prompt modal.
  2. Create a scratch buffer and centered rounded floating window sized to ~80% of editor dimensions (clamped to viewport, min 64x18 when space allows), titled `" GitHub CLI Login (gh auth login) "` with footer `" Complete sign-in in terminal · resumes automatically when done "`.
  3. Start `vim.fn.jobstart({ "gh", "auth", "login" }, { term = true, on_exit = on_login_exit })` and enter terminal insert mode (`vim.cmd("startinsert")`).
  4. Register `BufWipeout` / `WinClosed` cleanup guards: if the user manually closes the terminal before `on_exit`, stop the job and still run the `gh auth status` verification once (in case they closed the float immediately after completing login).
  5. When `on_login_exit` fires (scheduled onto the main loop):
     - Run `vim.system({ "gh", "auth", "status" }, { text = true, timeout = 5000 })` asynchronously.
     - **If `status_result.code == 0`:**
       - Close the floating terminal window/buffer and restore focus to the origin window.
       - Reset `is_background_suppressed = false`.
       - Show `jpr.info("GitHub authentication complete; continuing...")`.
       - Snapshot and clear the pending queue, then invoke every queued `on_authenticated()` callback in order.
     - **If `status_result.code ~= 0`:**
       - Close the floating terminal window/buffer.
       - Re-open the Auth Prompt Modal with an inline error banner: `"GitHub authentication did not complete. Select Authenticate to try again or Cancel."` keeping the pending queue intact so clicking `Authenticate with GitHub` retries and `Cancel` drains `on_cancel("incomplete")`.

#### Wiring Every Plugin Entry Point Through `lua/jpr/auth.lua`

| Entry point | File | Auth error signal | Resume action on auth |
| --- | --- | --- | --- |
| Owner discovery (`jpr-review owners`) | `lua/jpr/repo_picker.lua` | CLI exit code `3` | Re-runs owner fetch and continues into owner/repo picker -> palette |
| Repo discovery (`jpr-review repos`) | `lua/jpr/repo_picker.lua` | CLI exit code `3` | Re-runs repo fetch for chosen owner -> palette |
| Open PR listing (`jpr-review prs`) | `lua/jpr/session/open.lua` | CLI exit code `3` | Re-invokes `list_open_prs` (or reopens the PR picker step cleanly if the wizard was closed by the auth modal) |
| PR checkout (`jpr-review checkout`) | `lua/jpr/session/open.lua` | CLI exit code `3` | Cancels/closes the loading tab cleanly, prompts auth, and re-runs `session.open(number, repo)` |
| Local worktree probe (`jpr-review local`) | `lua/jpr/session/open_local.lua` | CLI exit code `3` | Re-runs `session.open_local(base_ref)`; on cancel, aborts cleanly (builder/design call: consistent with modal copy; explicit `:Jpr local <base>` remains offline without calling `gh`) |
| All RPC requests (`comment`, `reply`, `editMessage`, `deleteMessage`, `setResolved`, `toggleReaction`, `retryMessage`, `promoteThread`, `submitReview`, `push`, etc.) | `lua/jpr/session/init.lua` (`M.request`) & `lua/jpr/comments/compose.lua` | RPC `code == -32001` | Re-sends the exact `(session, method, params, on_result, on_error)` request if session is still alive. For compose submissions (`comment`, `reply`, `editMessage`, `promoteThread`), `on_error` reopens the compose buffer prefilled with the user's unsent body when auth is cancelled/incomplete so text is never lost (design call). |
| Explicit `:Jpr sync` / startup `sync` | `lua/jpr/session/commands.lua` (`sync_session`) | RPC `code == -32001` | Calls `prompt_and_resume({ key = "sync:" .. session.tab, is_background = false, on_authenticated = ... })` -> re-runs `session_mod.sync(session)` |
| Background poll / `setViewed` / post-push `syncFailed` | `lua/jpr/session/events.lua` | `params.authRequired == true` | Calls `prompt_and_resume({ key = "sync:" .. session.tab, is_background = params.isBackground == true, on_authenticated = ... })` -> re-runs `require("jpr.session").sync(session)`. Foreground `setViewed` and post-push resync carry `isBackground = false` and therefore clear any earlier background-decline suppression (design call). |

**Important interaction for wizard steps:** Because opening the auth prompt closes any active `jpr.tui.wizard` modal, when `list_open_prs` hits exit code `3` while inside the `:Jpr open` wizard step, its `on_authenticated` callback re-opens the `:Jpr open` wizard directly at `start_step_id = "pr"` with the same `context` (including `context.repo`) so the user lands right back in the open PR list! Likewise, when `repo_picker` hits exit code `3` on owners or repos, its `on_authenticated` callback re-opens the repo picker at the interrupted step with the saved continuation (`on_repo_selected`).

---

### 6. Pre-Palette Non-Git-Repo Flow (`lua/jpr/repo_picker.lua`, `lua/jpr/init.lua`, `lua/jpr/commands/schema.lua`, `lua/jpr/tui/`)

#### Detecting Non-Git-Repo State
- In `lua/jpr/repo_picker.lua`:
  - `M.detect_git_repo(cwd, callback)` runs `vim.system({ "git", "rev-parse", "--is-inside-work-tree" }, { cwd = cwd, text = true, timeout = 3000 })` asynchronously and calls `callback(result.code == 0 and vim.trim(result.stdout or "") == "true")`.
  - Pure, testable entry helper allows test specs to stub git detection cleanly.
- In `lua/jpr/init.lua`:
  - **Bare `:Jpr` (`#args == 0`):**
    - If `context.has_session` is `true`: open the global command palette immediately (the active review tab is already in a PR/local worktree).
    - Otherwise, call `repo_picker.detect_git_repo(vim.fn.getcwd(), function(is_git_repo) ...)`:
      - If `is_git_repo == true`: set `context.is_git_repo = true` and open `wizard.open_palette(commands, context)` directly (unchanged behavior).
      - If `is_git_repo == false`: call `repo_picker.pick(function(selected_repo) ... end)`:
        - Once `selected_repo` (`"owner/name"`) is picked, build a repo-scoped context:
          - `context.is_git_repo = false`
          - `context.repo = selected_repo`
          - `context.title = (" Jpr Commands · %s "):format(selected_repo)`
          - `context.on_back = function() repo_picker.pick(...) end` (so pressing `h`/`<Left>`/`<S-Tab>` in the repo-scoped palette lets the user pick a different repo!)
        - Open `wizard.open_palette(commands, context)`.
  - **Bare `:Jpr open` (no argument):**
    - If `context.has_session` is `true`: open the `:Jpr open` PR picker immediately as today.
    - Otherwise, check `repo_picker.detect_git_repo`:
      - If `is_git_repo == true`: open the `:Jpr open` PR picker immediately as today.
      - If `is_git_repo == false`: run `repo_picker.pick(function(selected_repo) ... end)` and once chosen, open `:Jpr open` at `start_step_id = "pr"` with `context.repo = selected_repo`!
  - **`:Jpr open <n|#n|URL>` or `:Jpr <URL>`:**
    - If `<URL>` provides `repo`: goes directly to `session.open(number, repo)` (which now works outside a git repo via managed clone cache!).
    - If only a bare `<n>` is given outside a git repo: `jpr-review checkout --pr <n>` fails clearly advising to pass a URL or run `:Jpr` to pick a repository.

#### Owner -> Repository Wizard Steps (`lua/jpr/repo_picker.lua`)
Reuses `jpr.tui.wizard` (same centered floating window, Neovim keys, hover-only helper text):

1. **Fetch owners first (`jpr-review owners`):**
   - Opens a lightweight loading modal (or step 1 `async_select`) while `jpr-review owners` runs.
   - If `auth.is_cli_auth_error(result)` -> invokes `auth.prompt_and_resume` and retries owner loading on auth success.
   - If `#owners == 0`: reports an error (`"no GitHub account found via gh"`).
   - **If `#owners == 1`** (personal profile only, zero organizations):
     - Skips the owner picker step automatically and jumps straight to the Repository Picker for `owners[1].login` (`Step 1 of 1 · Select Repository`).
   - **If `#owners > 1`** (personal profile + 1 or more organizations):
     - Shows `Step 1 of 2 · Select Account or Organization`:
       - Personal profile first: label = `owner.login`, badge = `[you]`, help = `owner.name and (owner.name .. " · Your personal GitHub repositories") or "Your personal GitHub repositories"`.
       - Each organization: label = `owner.login`, badge = `[org]`, help = `owner.name and (owner.name .. " · Organization repositories") or ("Repositories in " .. owner.login)`.
     - Selecting an owner advances to `Step 2 of 2 · Select Repository`.
2. **Repository Picker (`jpr-review repos --owner <login>`):**
   - Loads repositories asynchronously for the selected owner.
   - If `auth.is_cli_auth_error(result)` -> invokes `auth.prompt_and_resume` and retries repo loading for that owner on auth success.
   - Each repository option displays:
     - `label`: `repo.nameWithOwner`
     - `badge`: `[private]`, `[archived]`, or `[private] [archived]` (nil for active public repos)
     - `help`: `<description> · updated YYYY-MM-DD` (or `updated YYYY-MM-DD` when description is absent)
   - Pressing `h`/`<Left>`/`<S-Tab>` when `#owners > 1` returns to the Owner/Organization step.
   - Selecting a repository closes the picker and invokes `on_selected(repo.nameWithOwner)`.

#### Repo-Scoped Palette & Command Adjustments
- `lua/jpr/tui/wizard/palette.lua` & `lua/jpr/tui/render.lua`:
  - Support optional `context.on_back` on palette: bind `h`, `<Left>`, `<S-Tab>` to call `context.on_back()` when present, and include `[h] repos` in the palette footer when `context.on_back` is set.
  - Support `command.requires_git_repo` (set to `true` on `local` in `lua/jpr/commands/schema.lua`): mute the row in `render.lua` when `context.is_git_repo == false` (parallel to `requires_session and not has_session`).
- `lua/jpr/commands/schema.lua`:
  - `load_open_pr_options(answers, context, on_loaded)`: passes `context and context.repo or nil` to `session.list_open_prs(on_result, on_error, { repo = repo, on_reopen = ... })`, and embeds `repo = repo` in each option's `value = { number = pr.number, repo = repo }` so selecting a PR passes `repo` to `session.open(number, repo)`.
  - `execute_open_command(answers, context)`: for manual PR input, falls back to `context and context.repo or nil` when `parse_pr_arg` returns `repo == nil` (so typing `42` in a repo-scoped palette opens PR `#42` in the chosen repo, while pasting a full PR URL for another repo uses the URL's repo).
  - `create_local_command_spec()`: sets `requires_git_repo = true`; if executed while `context.is_git_repo == false`, displays a clear error explaining that `:Jpr local` requires a local git checkout.
- `lua/jpr/session/open.lua`, `lua/jpr/session/init.lua`, & `lua/jpr/views/diff/init.lua` (multi-repo same-PR-number safety, design call):
  - `list_open_prs(on_result, on_error, opts)`: accepts optional `opts.repo` and appends `{ "--repo", opts.repo }` to `{ binary_path, "prs" }`; intercepts CLI exit code `3` through `jpr.auth.prompt_and_resume`.
  - Key `pending_by_key` in `open.lua` by `(repo or ""):lower() .. "#" .. tostring(number)` instead of bare `number`, and let `open_tab_numbers(repo)` filter open tabs by matching `repo` (case-insensitive) when `repo` is given so `[open]` badges do not falsely match another repository's PR of the same number.
  - Disambiguate `session.buf_key(session)` on collision (preserving `tostring(session.number)` when no other open session or named `jpr://panel/<number>` buffer collides, and falling back to `<repo_slug>-<number>` or `<number>-tab<tab>` when another repo already holds that PR number), and route `views/diff/init.lua`'s base buffer name through `session.buf_key(session)` so opening PR `#7` in two different repositories in the same Neovim instance never fails with `E95` while keeping all existing single-repo `jpr://<view>/<number>` buffer names unchanged.

---

### 7. What Is Left to the Builder

- Exact module splitting inside `crates/review-forge-github/src/discovery.rs`, `crates/review-workspace-git/src/cache.rs`, and `lua/jpr/auth/` (if splitting `auth.lua` into prompt/terminal submodules keeps files `<= 400` lines and functions `<= 45` lines).
- Exact floating terminal window dimensions and highlight group reuse (`JprTitle`, `JprMuted`, `JprError`) within viewport clamping bounds.
- Exact unit test fixtures and mock `gh` scripts in Rust (`review-core`, `review-forge-github`, `review-workspace-git`, `review-rpc`, `jpr-review`) and headless Neovim Lua specs (`tests/lua/`).
- Exact ordering of tasks in the implementation plan, provided every unit follows Red/Green TDD and `just check` passes cleanly.
