# Track 2 Design: Local Worktree Review, Active PR Auto-Detection, and Mid-Session PR Linking (`0.7.0`)

## Intent and Why

Today, `jpr-nvim` can only open a review after a pull request already exists on GitHub (`:Jpr open <n>`), and it always checks the pull request out into a separate worktree. Reviewers who want to self-review their current branch or uncommitted edits before opening a PR, or review an active branch in-place without spawning a duplicate checkout worktree, have to leave Neovim for another diff tool and lose their local comments, viewed marks, and coding-agent session when the PR is later opened.

Track 1 (`0.6.0`, `PROTOCOL_VERSION = 7`) built the reusable local worktree diff engine inside `crates/review-core`: effective worktree file merging (`local_files.rs`), `FileRow.isLocalOnly`, `LocalStoreState.local_viewed` persistence, edit-triggered dismissal, promotion to `queued_viewed` on sync, and origin-split comment validation.

Track 2 (`0.7.0`, `PROTOCOL_VERSION = 8`) builds directly on that foundation to add:
1. Reviewing the current worktree/branch changes locally against its base branch (no PR required, no new checkout worktree, edits remain unstaged in place).
2. Automatic in-place PR attachment when the current branch already has an open GitHub PR (following `dif`'s `gh pr view` pattern, Decision B3).
3. Seamless mid-session upgrade from local mode to a live GitHub PR via `:Jpr sync`, preserving the live daemon/agent socket and keeping every locally `VIEWED` file authoritative on GitHub.

## Goals

1. **Dedicated current-worktree review command (`:Jpr local [base]` and `jpr-review local`):** Add a top-level bare `:Jpr` palette entry (`Review Current Worktree [local]`) and direct Ex command (`:Jpr local [base]`), with full parity in `jpr-review` CLI and its TTY Command Palette.
2. **Smart base-branch auto-detection with override:** Match `dif`'s default rule (`develop` if present, else `main`, with safe `origin/*` and `origin/HEAD`/`master` fallbacks) while allowing any explicit git ref override (including `HEAD` for uncommitted-only review).
3. **In-place review with zero duplicate worktrees:** Open the review tab pointing directly at the current worktree root (`tcd` without creating any new git worktree), so user and coding-agent edits stay directly in the working tree as unstaged changes for the user to stage and commit.
4. **Active PR auto-detection on startup (Decision B3):** Probe GitHub via `gh pr view --json ...` in the current worktree. If the branch already has an open PR, attach to that PR in-place immediately (no separate checkout worktree; comments, viewed marks, push, and submit operate directly on the live PR). If no open PR exists (or GitHub is unreachable), start cleanly in local mode.
5. **Strict local-only isolation while unlinked:** While unlinked, disallow GitHub-only operations (GitHub comments, `promoteThread`, `:Jpr suggest`, `:Jpr submit`, `:Jpr push`, `retryMessage`, `prepareConflictResolution`, and 60-second background GitHub polling). Keep all review notes local (`Origin::Local`) with bulk `:Jpr send` to the coding agent (never eager per-comment dispatch) and live 2-second worktree watching.
6. **Seamless mid-session local-to-PR upgrade via `:Jpr sync`:** When `:Jpr sync` runs in an unlinked local session, probe `gh pr view` for an open PR on the current branch. When found, upgrade the running daemon in-place from local mode to PR mode without restarting the daemon or breaking a live `:Jpr agent` terminal's `JPR_SOCKET`, migrate persisted state into the PR's canonical state directory, promote every locally `VIEWED` file into `queued_viewed` (pushing `setViewed(path, true)` to GitHub so local viewed marks stay authoritative), and activate normal PR sync/polling.

## Non-Goals

- Creating or opening a GitHub PR from inside `jpr-nvim` (the user publishes the PR via `gh pr create` or their own workflow, then runs `:Jpr sync`).
- Auto-staging or auto-committing edits made in the current worktree.
- Eager per-comment dispatch to the coding agent (dispatch stays strictly explicit bulk `:Jpr send` or explicit single-thread `s` in popup/conversation).
- Background GitHub polling for a newly opened PR while in unlinked local mode (linking is triggered explicitly via `:Jpr sync`).
- Detaching/downgrading an already-linked PR session back into unlinked local mode.

## Anti-Goals

- Restarting the engine daemon or dropping `JPR_SOCKET` on mid-session local-to-PR upgrade (which would disconnect an active Claude Code or Codex terminal split).
- Creating a duplicate checkout worktree when starting a review from a worktree that already has an open PR on its branch.
- Calling GitHub GraphQL/REST mutations or queueing GitHub operations while unlinked.
- Letting GitHub's initial `UNVIEWED` file state wipe out locally `VIEWED` marks on first link.
- Overwriting or colliding with another running `jpr-review` daemon that is already serving the target PR number.
- Leaking terminal/editor dependencies into `crates/review-*`.

## Constraints

- **Dependency rule:** `crates/review-*` crates remain strictly UI-free (`crates/jpr-review/tests/dependency_rule.rs`). All base-branch resolution, PR linking, local-mode gating, and state migration rules live in Rust (`review-core`, `review-workspace-git`, `review-forge-github`, `review-store-fs`).
- **Interactive Command Palette & Schema-to-TUI invariant:** Every new/updated command and option in both `:Jpr` (`lua/jpr/commands/schema.lua`) and `jpr-review` (`crates/jpr-review/src/tui_schema/`) must be declaratively registered with human-readable labels paired with `[<id>]`, concise helper text, smart defaults, discriminant-first `when` ordering, Neovim-conventional keys, full flag parity, and automated completeness tests.
- **Code style:** Zero em dashes across code, comments, tests, and docs; functions `<= 45` lines; source and test files `<= 400` lines; Red/Green TDD; `just check` green.
- **Lockstep release & protocol:** Bump workspace `Cargo.toml` and `lua/jpr/init.lua` to `0.7.0`, and `PROTOCOL_VERSION` in `crates/review-rpc/src/protocol.rs` and `lua/jpr/rpc.lua` to `8`.
- **Documentation currency:** Update `docs/architecture.md`, `docs/protocol.md`, `docs/decisions.md`, `README.md`, and `:Jpr keys` cheatsheet in the same change.

## Approaches

Three architectural approaches were evaluated before writing this design:

| Approach | Summary | Trade-offs |
| --- | --- | --- |
| **1. Unified in-place `ReviewSession` (`Local` -> `Pr` target) with atomic store retargeting (Chosen)** | Generalize `ReviewSession` target to `SessionTarget::Local(LocalTarget) \| SessionTarget::Pr { number }`. Add `Forge::current_branch_pr()` and `ReviewStore::retarget_to_pr()`. On `:Jpr sync` in local mode, upgrade the live session and `FsStore` directory in-place while keeping the existing Unix socket bound, reusing Track 1's `promote_adopted_local_viewed` to push local `VIEWED` marks to GitHub. | Zero-downtime mid-session upgrade; a running `:Jpr agent` terminal keeps its live `JPR_SOCKET` across linking; all linking rules stay inside UI-free `review-core`; clean `FsStore` retargeting with live-daemon conflict checks. |
| **2. Separate local-only daemon + daemon restart handoff on link (Rejected)** | Run `jpr-review serve --local` strictly local-only; on link, have Lua/CLI copy files to `pr-<N>/`, shut down the local daemon, and spawn a fresh `jpr-review serve --pr <N>`. | Tears down `JPR_SOCKET` and breaks any live coding-agent terminal split; pushes upgrade orchestration and rollback complexity into Lua instead of `review-core`. |
| **3. In-memory ephemeral local mode until linked (Rejected)** | Keep local threads and `local_viewed` only in memory until a PR is linked, skipping disk persistence for local sessions. | Losing Neovim, switching sessions, or a single engine crash wipes all local review work; offline CLI commands (`jpr-review threads`/`reply`) cannot read state from disk. |

Approach 1 was selected (Decision B1) along with dedicated `:Jpr local [base]` + top-level palette entry (Decision A1) and `:Jpr sync` as the explicit mid-session link trigger with background polling disabled until linked (Decision A2).

---

## Detailed Design

### 1. Domain Model & Wire Protocol (`crates/review-model`, `crates/review-rpc`, `PROTOCOL_VERSION = 8`)

#### `LocalReviewContext` and `SessionView`
Add `LocalReviewContext` in `crates/review-model/src/view.rs`:

```rust
/// Context for an unlinked local worktree review session (`SessionView::pr == None`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalReviewContext {
    /// Checked-out branch name, or `detached-<short-sha>` when HEAD is detached.
    pub branch: String,
    /// Base branch or git ref being diffed against (for example `develop` or `main`).
    pub base_ref: String,
    /// Resolved full commit SHA of `base_ref`.
    pub base_sha: String,
    /// Inferred `owner/name` repository from `origin` remote, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
}
```

Add an optional field on `SessionView` (`#[serde(rename_all = "camelCase")]`):

```rust
/// Local worktree review context when unlinked (`pr == None`); omitted once
/// linked to a pull request (`pr == Some(..)`).
#[serde(default, skip_serializing_if = "Option::is_none")]
pub local_context: Option<LocalReviewContext>,
```

- Naming note (our call): the JSON key is `"localContext"` rather than `"local"` because `local` is a reserved keyword in Lua (`view.localContext` works cleanly without bracket indexing).
- State combinations on `SessionView`:
  - **PR session before initial sync:** `pr: null`, `localContext: null`, `sync: { state: "never" }`.
  - **PR session after sync:** `pr: { ... }`, `localContext: null`, `sync: { state: "synced" | "failed", ... }`.
  - **Unlinked local session:** `pr: null`, `localContext: { branch, baseRef, baseSha, repo? }`, `sync: { state: "never" }`.
  - **After mid-session `:Jpr sync` upgrade:** `pr: { ... }`, `localContext: null`, `sync: { state: "synced", at }`.

#### Protocol Version & RPC Surface
- Bump `PROTOCOL_VERSION` from `7` to `8` in `crates/review-rpc/src/protocol.rs` and `lua/jpr/rpc.lua`.
- Bump release version from `0.6.0` to `0.7.0` in workspace `Cargo.toml` and `lua/jpr/init.lua`.
- No new JSON-RPC methods are required. Every existing method operates uniformly with local-mode behavior defined below.

| RPC Method | Unlinked Local Mode | Linked PR Mode |
| --- | --- | --- |
| `initialize`, `snapshot`, `shutdown` | Allowed | Allowed |
| `fileDiff`, `stream`, `anchoredLines` | Allowed (diff vs `merge_base(base_sha, HEAD)`) | Allowed |
| `setViewed` | Allowed (persists in `local.json` `localViewed`; zero GitHub calls) | Allowed (PR files -> GitHub; local-only files -> `localViewed`) |
| `refreshWorktree` | Allowed (refreshes `local_files`, `base_sha`, digests, re-anchors local threads, dismisses edited `localViewed`) | Allowed |
| `threads` | Allowed (returns local threads) | Allowed |
| `mentions` | Returns `{ "candidates": [] }` (zero GitHub calls) | Returns cached PR mention candidates |
| `comment` (`origin: "local"`), `reply`/`editMessage`/`deleteMessage`/`setResolved`/`toggleReaction` on local threads | Allowed (`local.json` only) | Allowed |
| `agentReply`, `prepareAgentLaunch`, `prepareSend`, `confirmSend`, `preparePrepass`, `prepassWrite`, `updateLocalAnchors` | Allowed (bulk `:Jpr send`; prompts reference local branch and base ref) | Allowed |
| `sync` (explicit stdio request) | Probes `forge.current_branch_pr()`. If open PR found, upgrades in-place, migrates store, promotes `localViewed` -> `queuedViewed`, pulls PR, and emits `Synced`. If none found, returns `-32000` without mutating `sync` state. | Full GitHub sync |
| `comment` (`origin: "github"`), `promoteThread`, `suggestFromEdit`, `submitPreview`, `submitReview`, `push`, `retryMessage`, `prepareConflictResolution` | **Refused** with `-32000`: `"this review is not linked to a GitHub pull request yet; run :Jpr sync once a PR is open"` | Allowed |

---

### 2. Git Base-Branch Detection & Ref Resolution (`crates/review-workspace-git`, `crates/review-core`)

#### Base-Branch Auto-Detection (`crates/review-workspace-git/src/local_ref.rs`)
Mirror `dif`'s `BranchProbe` + `resolve_comparison_key` pattern in a pure, unit-tested module:

1. **Default detection (when `--base` is omitted):**
   - Check local `refs/heads/develop`, then `refs/remotes/origin/develop` -> `"develop"` / `"origin/develop"`.
   - Else check local `refs/heads/main`, then `refs/remotes/origin/main` -> `"main"` / `"origin/main"`.
   - Else check symbolic `refs/remotes/origin/HEAD` (stripped to short ref like `origin/<default>`), then local `refs/heads/master`, then `refs/remotes/origin/master`.
   - If none exist, fail with a clear message instructing the user to pass `--base <ref>`.
2. **Explicit override (`--base <ref>`):**
   - Validate `<ref>`: must be non-empty, must not start with `-`, and must not contain NUL, carriage return, newline, or whitespace.
   - Resolve via `git rev-parse --verify --quiet <ref>^{commit}` to obtain the 40-char hex `base_sha`. If resolution fails, return a clear error naming `<ref>`.
   - Note: passing `--base HEAD` naturally yields `merge_base(HEAD, HEAD) == HEAD`, allowing uncommitted-only review on any branch without special-case code. Similarly, being checked out directly on `main` or `develop` with default base yields `merge_base == HEAD` and reviews all uncommitted/untracked changes.
3. **Current branch name:**
   - Run `git branch --show-current`. If empty (detached HEAD), run `git rev-parse --short HEAD` and format `"detached-<short-sha>"` (matching `dif/src/git.rs`).

#### `Workspace` Port Additions (`crates/review-core/src/ports.rs`)
Add one method to `Workspace`:

```rust
/// Resolves a branch name, tag, or commit reference to its full commit SHA.
fn resolve_ref(&self, reference: &str) -> Result<String>;
```

- Implemented on `GitWorkspace` (using unlocked `git rev-parse --verify --quiet <reference>^{commit}` after validating `reference`) and `FakeWorkspace`.
- Used in local mode during `prepare_base()` so if the user fetches or advances `develop`/`main` locally while reviewing, `base_sha` refreshes automatically and `BaseCache` invalidates cleanly.

---

### 3. Active PR Auto-Detection (`crates/review-forge-github`, `crates/review-core`)

#### `Forge::current_branch_pr` (`crates/review-core/src/ports.rs`)
Add one method to `Forge`:

```rust
/// Looks up the open pull request associated with the checked-out branch in
/// the current worktree (`gh pr view --json ...`), returning `Ok(None)` when
/// no open pull request exists for this branch.
fn current_branch_pr(&self) -> Result<Option<PullRequest>>;
```

#### `GhForge` Implementation (`crates/review-forge-github/src/lib.rs`, `pr.rs`)
- Runs `gh pr view --json <PR_FIELDS>` (with `--repo <owner/name>` when pinned, and **no** PR number argument) in the worktree directory, with the existing 30-second timeout.
- Pure classification (`parse_optional_open_pr` + `is_no_pr_for_branch_stderr`):
  - **Exit 0, `state == "OPEN"`:** returns `Ok(Some(PullRequest))`.
  - **Exit 0, `state != "OPEN"` (`MERGED` or `CLOSED`):** returns `Ok(None)` so a closed/merged historical PR on a reused branch name does not hijack a fresh local review.
  - **Non-zero exit whose stderr indicates no PR exists for this branch** (for example: `"no pull requests found for branch"`, `"could not find pull request"`, `"not on any branch"`, `"could not determine current branch"`, `"none of the git remotes configured for this repository point to a known GitHub host"`, `"no git remotes found"`): returns `Ok(None)`.
  - **Any other error** (network timeout, `gh` not installed, authentication failure, malformed JSON): returns `Err(error)`.

---

### 4. Unified `ReviewSession` & Mid-Session Upgrade (`crates/review-core`)

#### `SessionTarget` (`crates/review-core/src/session/mod.rs`)
Replace `number: u64` on `ReviewSession` with:

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionTarget {
    Pr {
        number: u64,
    },
    Local {
        branch: String,
        base_ref: String,
        base_sha: String,
        repo: Option<String>,
    },
}
```

- Keep `ReviewSession::open(number: u64, ports: Ports) -> Result<Self>` unchanged for all existing callers and tests.
- Add `ReviewSession::open_local(context: LocalReviewContext, ports: Ports) -> Result<Self>`:
  - Loads persisted `StoreSnapshot` (restoring `local.threads`, `local.local_viewed`, `local.next_local_id`, `local.next_round`, and `session.agent_session_id`/`agent_kind`).
  - Initializes `target = SessionTarget::Local { ... }` and `sync = SyncState::Never`.
  - Immediately populates `local_files` and initial `disk_digests` via `refresh_local_files()` so `snapshot` returns the full changed-file list immediately without waiting for a `sync` round-trip!
- Add `ReviewSession::is_linked(&self) -> bool`:
  - Returns `matches!(self.target, SessionTarget::Pr { .. })`.
  - Used by `review-rpc`'s background ticker (`crates/review-rpc/src/server/ticker.rs`) so 60-second GitHub polling and 20-second forge-queue retries are skipped while unlinked, while the 2-second worktree watcher (`poll_worktree_files`) runs in both modes. Once `:Jpr sync` upgrades the session to `SessionTarget::Pr`, the ticker automatically starts polling on the next interval without restarting threads!

#### Unified Base Resolution & Local Operations
- `active_base_sha(&mut self) -> Result<String>`:
  - When `SessionTarget::Pr { .. }`: returns `self.synced_pr()?.base_sha.clone()`.
  - When `SessionTarget::Local { base_ref, base_sha, .. }`: calls `self.ports.workspace.resolve_ref(base_ref)` (updating cached `base_sha` if the ref moved, falling back to stored `base_sha` if ref lookup transiently fails) and returns it.
- `prepare_base()` and `refresh_local_files()` use `active_base_sha()` instead of requiring `saved.session.pr`.
- `set_viewed(path, viewed)` (`crates/review-core/src/session/viewed.rs`):
  - If `self.saved.session.pr` is `Some(pr)` and `path` is in `self.saved.files`: existing GitHub behavior unchanged.
  - Otherwise if `path` is in `self.local_files`: updates `local_file.viewed` and `self.saved.local.local_viewed`, saves store, and emits `Event::ViewedChanged` without calling `synced_pr()` or touching the forge!
  - Otherwise: returns error (`"{path} is not a file changed in this review"`).
- `require_linked_pr(&self) -> Result<&PullRequest>`:
  - When `SessionTarget::Local { .. }`, bails with `"this review is not linked to a GitHub pull request yet; run :Jpr sync once a PR is open"`.
  - When `SessionTarget::Pr { .. }`, delegates to `self.synced_pr()`.
  - Used by `create_github_thread_entry`, `promote_thread`, `suggest_from_edit`, `submit_preview`, `submit_review`, `push`, `retry_message`, and `prepare_conflict_resolution`.
- **Agent Loop in Local Mode (`crates/review-core/src/agent.rs`, `session/agent_loop.rs`):**
  - `prepare_agent_launch`: seeds UUID from PR number when linked, or a deterministic FNV-1a hash of `(branch, base_ref)` when unlinked.
  - `prepare_send` and `prepare_prepass`: do NOT require `synced_pr()`. Add local prompt builders (`build_local_send_prompt_from_threads(ctx, threads)` and `build_local_prepass_prompt_from_context(ctx)`):
    - Header references `"local branch `<branch>` against `<base_ref>` (`<short_base_sha>`)"` instead of `"PR #N"`.
    - Still instructs the agent to run `jpr-review guide`, reply via `jpr-review reply <thread-id> --body "..."` / `jpr-review prepass-write`, and explicitly states: `"Keep edits unstaged in this worktree for the reviewer to stage and commit. Never commit, never push, and never touch GitHub."`
  - `validate_local_anchor_file` already validates against `effective_files()`, so local `line`, `range`, `file`, and `pr` (general notes) comments and `prepassWrite` work seamlessly in local mode.

#### Mid-Session Local-to-PR Upgrade (`crates/review-core/src/session/sync.rs`)
When `session.sync()` is called while `self.target` is `SessionTarget::Local { branch, .. }`:
1. Call `self.ports.forge.current_branch_pr()?`.
   - If `Ok(None)`: return `Err(anyhow!("no open pull request found for branch {branch}; open a PR on GitHub and run :Jpr sync again"))` **without** setting `self.sync = SyncState::Failed` or emitting `Event::SyncFailed` (so the local review panel stays clean).
   - If `Err(error)`: return `Err(error)` (surfacing network/auth details cleanly without corrupting local state).
2. If `Ok(Some(pr))`:
   - Fetch the PR snapshot (`let snapshot = self.ports.forge.fetch(&pr)?;`) **before** retargeting the store or mutating `self.target`, so a transient fetch failure leaves the session cleanly in local mode with zero half-migrated state!
   - Call `let existing_pr_snapshot = self.ports.store.retarget_to_pr(&pr.owner, &pr.repo, pr.number)?;`.
     - If `retarget_to_pr` fails (for example, another `jpr-review` daemon is already serving PR `#N`), abort before mutating `self.target` so local state remains untouched!
   - Merge `existing_pr_snapshot` (if `Some(prior)`):
     - Preserve any preexisting `prior.registry` (`queued_viewed`, `queued_ops`, `agreed_bodies`, `id_map`, `next_temp_id`) as the base registry before applying the fresh pull.
     - Merge preexisting `prior.local.threads` with the current local session's `Origin::Local` threads, renumbering any colliding `loc-*` / `loc-m-*` IDs in the current session's threads and advancing `next_local_id = max(prior.next_local_id, current.next_local_id)` and `next_round = max(prior.next_round, current.next_round)`.
     - Preserve the current session's live `session.pid`, `session.socket`, `session.worktree`, and active `session.agent_session_id`/`agent_kind` (falling back to `prior.session.agent_session_id`/`agent_kind` only if the local session never launched an agent yet).
     - **Authoritative local viewed state:** Keep every `ViewedState::Viewed` entry from the current local session's `local_viewed` (overriding any `false` entry in `prior.registry.queued_viewed` for the same path).
   - Switch `self.target = SessionTarget::Pr { number: pr.number }`.
   - Run `self.apply_pull(pr, snapshot, now)`:
     - Because `self.saved.session.pr` was `None`, `prior_head_sha` is `None`, so `handle_head_moved` does **not** run on first link (the user's current worktree and any uncommitted edits or extra local commits are never touched or stashed).
     - `reconcile_viewed_and_local_files` calls Track 1's `promote_adopted_local_viewed(&incoming_files)`:
       - Every file in `incoming_files` whose `local_viewed` was `ViewedState::Viewed` is removed from `local_viewed` and inserted into `queued_viewed[path] = true`.
       - `apply_queued` marks every promoted file `ViewedState::Viewed` immediately in `self.saved.files`.
       - `send_queued` immediately pushes `forge.set_viewed(&pr, path, true)` to GitHub; any mark that fails transiently stays in `queued_viewed` and retries automatically.
       - Any local worktree file NOT yet pushed to the PR stays in `self.local_files` with `isLocalOnly = true` and keeps its `local_viewed` state until pushed!
     - `split_and_save_threads()` atomically persists the upgraded state into the PR's canonical state directory (`pr-<N>/`).
     - Call `self.ports.store.finalize_retarget()` (our call) **only after** `split_and_save_threads()` succeeds so the old `local-<branch>-<hash8>` state files are retired cleanly after the PR directory holds durable state.
     - Pin the forge adapter to `pr.owner/pr.repo` once linked (`Forge::pin_repo(&pr.owner, &pr.repo)`, default no-op, implemented on `GhForge` via interior `RwLock<Option<String>>`) so subsequent `pull_request(number)` polls target the linked PR's repository even in fork setups.
     - Emits `Event::Synced { view }` (now with `view.pr = Some(pr)` and `view.localContext = None`).

---

### 5. Local State Directory & Atomic Store Retargeting (`crates/review-store-fs`)

#### Local State Path (`crates/review-store-fs/src/paths.rs`)
Add `local_state_dir`:
- With inferred `(owner, repo)`:
  `<state_home>/<app>/<owner>/<repo>/local-<branch_slug>-<hash8>`
- Without a GitHub remote (`owner/repo == None`):
  `<state_home>/<app>/_local/<dir_slug>-<root_hash8>/local-<branch_slug>-<hash8>`
- Pure slug helper (`sanitize_slug(raw, max_len)`): maps runs of characters outside `[A-Za-z0-9._-]` to `-`, trims leading/trailing `-` and `.`, caps to 40 bytes, falls back to `"branch"`/`"repo"`.
- `<hash8>` is the 8-char lowercase hex FNV-1a (or SHA-256 prefix) hash of the canonical worktree path + `"\0"` + branch name, guaranteeing uniqueness across case-insensitive APFS, slash-bearing branch names, and multiple worktrees.

#### `FsStore` Retargeting (`crates/review-store-fs/src/lib.rs`)
- Store `dir: RwLock<PathBuf>` and optional `state_root: Option<StateRootConfig { xdg_state_home, home, app }>` inside `FsStore` (`FsStore::new(dir)` keeps `state_root: None` for backwards compatibility; `FsStore::new_with_root(dir, state_root)` enables `retarget_to_pr`).
- `FsStore::dir(&self) -> PathBuf` (or `current_dir(&self) -> PathBuf`) returns the active directory so `serve.rs` clears `socket` from the active directory on clean shutdown (whether still local or upgraded to `pr-<N>/`).
- `ReviewStore::retarget_to_pr(&self, owner: &str, repo: &str, number: u64) -> Result<Option<StoreSnapshot>>` plus `ReviewStore::finalize_retarget(&self) -> Result<()>` (our call for crash-safe retirement of the old local directory):
  1. Compute `target_dir = paths::state_dir(xdg, home, app, owner, repo, number)?`.
  2. If `old_dir == target_dir`, return `Ok(None)`.
  3. Refuse if any file in `target_dir` has a newer format version (`refuse_newer_file`).
  4. Check for an active live daemon already serving `target_dir` (connect check on `target_dir/session.json`'s `socket` and `target_dir/s.sock` on Unix); if reachable, bail with `"another jpr-review daemon is already serving PR #{number}"`.
  5. Load `existing_snapshot` from `target_dir` if any files exist there (`None` if fresh).
  6. If `old_dir/rounds.jsonl` exists and is non-empty, append its lines into `target_dir/rounds.jsonl` under `target_dir`'s `local.lock` (creating `target_dir` if needed).
  7. Update `self.dir` to `target_dir` and record `pending_retired_dir = Some(old_dir)`.
  8. Return `Ok(existing_snapshot)`.
  9. After `ReviewSession` atomically saves the merged snapshot into `target_dir`, `finalize_retarget()` removes the migrated state files (`local.json`, `rounds.jsonl`, `viewed.json`, `github.json`, `session.json`, `local.lock`) from `old_dir` (leaving a still-bound `old_dir/s.sock` intact until daemon shutdown, and calling `remove_dir` on `old_dir` if empty; on clean daemon shutdown after unlinking `s.sock`, best-effort `remove_dir` on `s.sock`'s parent if empty). This guarantees offline CLI fallback never reads stale pre-link threads and a future offline local reopen + re-link never duplicates previously migrated threads or `rounds.jsonl` lines.
- Live Unix socket continuity: the daemon's `UnixListener` remains bound at its original socket path for the lifetime of the process. Recording that live `socket` path inside `pr-<N>/session.json` lets both an already-running `:Jpr agent` terminal (`$JPR_SOCKET`) and any new `jpr-review threads/reply --pr <N>` CLI call reach the same upgraded daemon seamlessly.

---

### 6. CLI & TTY Command Palette (`crates/jpr-review`)

#### New & Updated Subcommands (`crates/jpr-review/src/cli.rs`)
1. **`jpr-review local`**:
   ```text
   jpr-review local [--base <REF>] [--repo <OWNER/NAME>] [--no-pr]
   ```
   - Opens `GitWorkspace::open(&cwd)` to obtain the canonical worktree root (fails cleanly if not inside a git checkout).
   - **Repository resolution (our call):** Pass **only** an explicit `--repo <OWNER/NAME>` flag to `GhForge::new(worktree_root, explicit_repo)` (passing `None` when omitted, matching `commands/checkout.rs` so `gh` resolves `upstream` / `gh repo set-default` in fork setups and rejects non-GitHub remotes like GitLab instead of querying an unrelated `github.com` repo). Use `origin`-inferred `owner/name` (when present) strictly for `local_state_dir` organization and `LocalReviewContext.repo`.
   - **Base-override precedence (Decision C1):** When `--base <REF>` is explicitly provided (or `--no-pr` is passed), stay strictly in local mode against `<REF>` and skip `current_branch_pr()` so commands like `:Jpr local HEAD` or `:Jpr local main` always diff against the requested ref even when the branch has an open PR.
   - When neither `--base` nor `--no-pr` is passed, probes `GhForge::new(worktree_root, explicit_repo).current_branch_pr()`:
     - If `Ok(Some(pr))`: prints one JSON line to stdout:
       `{"mode":"pr","worktree":"...","repo":"owner/name","number":7,"title":"..."}`
     - If `Ok(None)`: resolves base branch (auto-detected `develop` -> `main`), current branch, and `base_sha`, and prints:
       `{"mode":"local","worktree":"...","branch":"feat/x","baseRef":"develop","baseSha":"<40-hex>","repo":"owner/name"|null}`
     - If `Err(error)`: narrates a concise warning to stderr (`"Could not check GitHub for an open PR (...); starting in local mode"`) and falls back to the local JSON output above!
2. **`jpr-review serve`**:
   ```text
   jpr-review serve --pr <NUMBER> --repo <OWNER/NAME> [--poll <SECONDS>]
   jpr-review serve --local [--base <REF>] [--repo <OWNER/NAME>] [--poll <SECONDS>]
   ```
   - `--pr` and `--local` are mutually exclusive (one is required).
   - `--repo` is required with `--pr`, optional with `--local`. In `--local` mode, only an explicit `--repo` flag is passed to `GhForge::new` (otherwise `None`, letting `gh` resolve forks/remotes natively on `:Jpr sync`); `origin`-inferred `owner/name` is used only for `local_state_dir` and `LocalReviewContext.repo`.
   - `--base` is accepted only with `--local` (auto-detected if omitted).
   - In `--local` mode: opens `FsStore::new_with_root(local_dir, state_root)` and `ReviewSession::open_local(context, ports)`, records daemon PID/worktree/socket, and serves over stdio + Unix socket.
   - Note on `GhForge` in local mode: `GhForge::new(worktree_root, explicit_repo)` is still wired into `Ports` (it makes zero network calls until the user explicitly invokes `sync`, at which point `current_branch_pr()` and `fetch()` run, and upon linking `GhForge` pins itself to `pr.owner/pr.repo`).
3. **`jpr-review state-path`**:
   - Supports `--pr <N> --repo <OWNER/NAME>` OR `--local [--repo <OWNER/NAME>]` (mutually exclusive).
4. **Agent CLI commands (`threads`, `reply`, `prepass-write`)**:
   - Already try `--socket` and `$JPR_SOCKET` first (working automatically in local mode when spawned from `:Jpr agent`).
   - When no live socket responds and neither `--pr` nor `$JPR_PR` is passed, check whether the current worktree/branch has an existing local state directory (`local_state_dir`) before prompting for `--pr`.

#### Rust TTY Command Palette (`crates/jpr-review/src/tui_schema/`)
- Add `local` (`Review Current Worktree [local]`) with discriminant-first steps (matching Decision C1 so explicit custom base stays local-only):
  1. `base_mode` (`Select`, default `"auto"`): `Auto-detect base branch [auto]` vs `Specify base branch or ref [custom]` (helper explains custom base stays local-only).
  2. `base` (`Text`, `when: base_mode == "custom"`, placeholder `"main"`).
  3. `detect_pr` (`Toggle`, default `"true"`, `when: base_mode == "auto"`): `Auto-attach if branch has an open PR` vs `Local-only mode (skip PR lookup)`.
  4. `custom_repo` + `repo` (`when: base_mode == "auto" && detect_pr == "true"`).
- Update `serve` and `state-path` specs with discriminant-first `session_mode` (`Pull Request [pr]` vs `Local Worktree [local]`) so every flag is reachable via the interactive stepper with abandoned-branch pruning.
- Update `crates/jpr-review/src/tui_schema/tests/` to assert completeness for all 9 CLI subcommands.

---

### 7. Neovim Plugin (`lua/jpr/`)

#### Declarative Schema & Command Dispatch (`lua/jpr/commands/schema.lua`, `lua/jpr/init.lua`)
- Add `local` as the 16th `:Jpr` subcommand, placed immediately after `open` in `create_command_specs()`:
  - `id = "local"`
  - `label = "Review Current Worktree"`
  - `help = "Review this worktree's changes against its base branch (auto-attaches if a PR is open)."`
  - `requires_session = false`
  - Steps:
    1. `base_mode` (`select`, default `"auto"`):
       - `auto`: `Auto-detect Base Branch [auto]` (`"Compare against develop if present, else main (auto-attaches if a PR is open)."`)
       - `custom`: `Specify Base Branch or Ref [custom]` (`"Review locally against a custom base branch, tag, or commit ref (skips PR auto-attach)."`)
    2. `base` (`text`, `when = answers.base_mode == "custom"`, default `""`, validates non-empty, no leading `-`, no whitespace).
- Direct command invocations:
  - `:Jpr local` -> runs `session.open_local(nil)` immediately (auto-detects open PR per B3, else auto-detects `develop` -> `main`).
  - `:Jpr local <base_ref>` -> runs `session.open_local(base_ref)` immediately (stays local-only against `<base_ref>` per C1).
  - Bare `:Jpr` -> selecting `Review Current Worktree [local]` runs the interactive wizard (`<CR>` on default `Auto-detect Base Branch` launches immediately).
- Update `sync` help text to `"Sync with GitHub, or detect and link a newly opened PR in local mode."`

#### Startup Flow & Tab Reuse (`lua/jpr/session/open.lua`, `lua/jpr/session/init.lua`)
- `session.open_local(base_ref)`:
  1. Checks if an active session tab already exists whose canonical `worktree` matches the current git root (or cwd). If found, switches to that tab without disturbing open buffers or compose drafts. When the requested `base_ref` differs from the existing tab's mode or base ref (for example, `:Jpr local HEAD` while a tab is already open on `develop` or linked to a PR), emit a clear info notice explaining the active session's mode/base and that `:Jpr close` is needed before reopening with a different base (Decision C1).
  2. Opens a new review tab with the live loading view (`mode = "local"`, stage 1: `"Inspecting worktree & checking for open PR"` when `base_ref == nil`, or `"Inspecting worktree against <base_ref>"` when `base_ref` is set).
  3. Runs `jpr-review local [--base <base_ref>]` asynchronously via `vim.system` (cancelable via closing the tab or `:Jpr close`).
  4. Parses the JSON result:
     - **`info.mode == "pr"`**: notifies `"Attached to open PR #<N> in current worktree"` and calls `session.start(info, pending_session)`! If another tab already has PR `#N` open, closes the temporary loading tab and switches to that existing tab.
     - **`info.mode == "local"`**: calls `session.start_local(info, pending_session)`, which sets `session.mode = "local"`, `session.number = nil`, `session.repo = info.repo`, `session.worktree = info.worktree`, `session.base_ref = info.baseRef`, `session.branch = info.branch`, runs `tcd` to `info.worktree`, opens the panel, spawns `jpr-review serve --local --base <baseRef>` (without forwarding `origin`-inferred `info.repo` as `--repo`, so `gh` resolves forks and remotes natively on `:Jpr sync`), runs `initialize`, and requests `snapshot` (skipping initial `sync` so GitHub is never touched in local mode!).
- `M.show(session, view)`:
  - Treat a session as ready for stream & diff rendering whenever `type(view.pr) == "table" or type(view.localContext) == "table"`.
  - **Mid-session upgrade detection:** If `session.mode == "local"` and `type(view.pr) == "table"`:
    - Transition `session.mode = "pr"`, `session.number = view.pr.number`, `session.repo = view.pr.owner .. "/" .. view.pr.repo`.
    - Notify `"Linked to PR #<N> (<title>)"` via `jpr.info(...)`.
    - Redraw panel, stream (keyed on `view.pr` + `view.localContext` so the stream key changes cleanly), open diffs, and conversation view if visible!

#### UI Adaptations Across Views
- **Buffer names (`jpr.session.buf_key(session)`):**
  - PR sessions keep `"<number>"` (`jpr://panel/7`, `jpr://stream/7`, `jpr://conversation/7`, `jpr://loading/7`) for 100% compatibility.
  - Local sessions use `"local-" .. tostring(session.tab)` (`jpr://panel/local-2`, etc.).
- **Panel (`lua/jpr/render/panel.lua`):**
  - Header when `view.localContext` is set: `"LOCAL <branch> vs <baseRef>"` (`JprTitle`).
  - Sync status line when `view.localContext` is set: `"local only · :Jpr sync to link PR"` (`JprMuted`).
  - Conversation row when `view.localContext` is set: `"  💬 Local Notes"` (with count badge when `conversationCount > 0`), switching to `"  💬 Conversation"` once linked.
  - File rows: suppress the redundant per-file `[local]` suffix when `view.pr == nil` (the entire review is local); show `[local]` only on unpushed local-only files in a linked PR review.
- **Statusline (`lua/jpr/render/statusline.lua`):**
  - Unlinked local session: `"LOCAL <branch> · dirty ↑A ↓B · V/F viewed · L local"` (omitting `drafts` and `sync!`).
  - Once linked to PR `#N`: switches seamlessly to `"PR #N · ..."`.
- **Compose, Popup, Conversation, and Agent Env:**
  - `lua/jpr/comments/compose.lua`: when `session.view.pr == nil` (unlinked local session), lock destination to `"local"`, disable `<C-g>` / `<M-s>` / `<C-g>s`, and show footer `" <C-s> save · local review (no linked PR) · q cancel "`.
  - `lua/jpr/comments/popup.lua` & `lua/jpr/views/conversation.lua`: when unlinked, show header `"Local Review Notes (<N> comments)"` in conversation view, hide `[p]romote` / `[+]react` / `[X]retry` from footer, and refuse `p` with a clear info notice `"Link a GitHub PR with :Jpr sync before promoting comments"`.
  - `lua/jpr/binary.lua`: in `create_agent_env_from_session`, omit `JPR_PR` when `pr_number == nil` so agent CLI calls rely cleanly on `JPR_SOCKET` without an invalid `"nil"` PR number.
  - `lua/jpr/session/crash.lua`: support session labels (`"PR #N"` vs `"local review (<branch>)"`) and crash log paths (`engine-pr-<N>.log` vs `engine-local-<slug>.log`) so crash recovery and single auto-restart work identically in local mode and after mid-session upgrade.
  - `lua/jpr/views/loading.lua`: accept optional `mode = "local"` and `header` text, showing 3 clean stages in local mode (`Inspecting worktree`, `Starting review engine`, `Computing diffs`) when no PR is attached.

---

## Left to the Builder

- Exact submodule boundaries under `crates/review-workspace-git/`, `crates/review-core/src/session/`, `crates/review-store-fs/`, and `lua/jpr/` to keep every file `<= 400` lines and every function `<= 45` lines.
- Exact stderr substring list for `is_no_pr_for_branch_stderr` in `review-forge-github` (covered by unit tests against real `gh pr view` error messages).
- Exact local crash-log filename slugging and whether `jpr-review local` reuses `infer_repo_from_git_remote` from a shared helper crate or `commands/socket_client.rs`.
- Exact headless Lua test fixtures and Rust fake-port integration tests covering local startup, PR auto-detection, local-mode refusals, and mid-session local-to-PR upgrade with authoritative `VIEWED` promotion.
