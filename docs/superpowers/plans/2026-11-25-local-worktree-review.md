# Track 2 (0.7.0) Local Worktree Review, PR Auto-Detection, and Mid-Session Linking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add current-worktree local review (`:Jpr local [base]` and `jpr-review local`), automatic in-place PR attachment when the branch already has an open PR, and seamless mid-session local-to-PR upgrading via `:Jpr sync` with authoritative local `VIEWED` promotion.

**Architecture:** Generalize `ReviewSession` in `crates/review-core` from a fixed PR number to `SessionTarget::Pr { number } | SessionTarget::Local(LocalReviewContext)` with an in-place `FsStore` retargeting path so mid-session linking keeps the live daemon and `JPR_SOCKET` alive for running coding agents. Keep all base-branch resolution, PR auto-detection, local-mode refusals, and viewed-mark promotion in UI-free `crates/review-*` crates, and expose full declarative Command Palette parity in both `crates/jpr-review` and `lua/jpr`.

**Tech Stack:** Rust (edition 2024 Cargo workspace: `review-model`, `review-core`, `review-store-fs`, `review-forge-github`, `review-workspace-git`, `review-rpc`, `cli-tui`, `jpr-review`) and Neovim Lua (`lua/jpr/`, headless Neovim specs via `./scripts/test-lua.sh`).

**Spec:** `docs/superpowers/specs/2026-11-25-local-worktree-review-design.md`

## Global Constraints

- **Dependency rule:** `crates/review-*` crates never depend on Neovim, Lua, `cli-tui`, or any terminal/UI crate (`crates/jpr-review/tests/dependency_rule.rs` must pass).
- **Interactive Command Palette & Schema-to-TUI invariant:** Every command and option in both `:Jpr` (`lua/jpr/commands/schema.lua`) and `jpr-review` (`crates/jpr-review/src/tui_schema/`) must be declaratively registered with human-readable labels paired with `[<id>]`, concise hover/stepper helper text, smart defaults, discriminant-first `when` ordering, Neovim-conventional controls, full flag parity, and passing schema-completeness tests.
- **Code style:** Zero em dashes across code, comments, tests, and docs; no `unsafe`; clippy pedantic + nursery clean (`-D warnings`); functions `<= 45` lines; source and test files `<= 400` lines; Red/Green TDD by default.
- **Lockstep release & protocol:** Workspace `Cargo.toml` and `lua/jpr/init.lua` bumped to `0.7.0`; `PROTOCOL_VERSION` in `crates/review-rpc/src/protocol.rs` and `lua/jpr/rpc.lua` bumped to `8`.
- **Documentation currency:** Update `docs/protocol.md`, `docs/architecture.md`, `docs/decisions.md`, `README.md`, and `lua/jpr/views/cheatsheet.lua` before completion.

## Review Focus

1. **Explicit `--base HEAD` on a branch with an open PR:** Passing `--base <REF>` must bypass PR auto-detection and stay local-only against `<REF>` rather than silently attaching to the PR (pinned in Task 7).
2. **Fork repos (`origin` = fork, PR on `upstream`) and non-GitHub `origin` remotes (GitLab/Bitbucket):** Local mode must pass `None` to `GhForge::new` unless `--repo` was explicitly supplied so `gh` resolves `upstream` on forks and treats non-GitHub remotes as `Ok(None)` instead of querying an unrelated GitHub repo (pinned in Tasks 3 and 7).
3. **Retired local state dir after mid-session link:** After `retarget_to_pr` and durable PR save, `finalize_retarget()` must delete migrated state files from `old_dir` (leaving any still-bound `s.sock` intact) so offline CLI fallback never reads stale threads and a later re-link never duplicates `loc-*` threads or `rounds.jsonl` lines (pinned in Tasks 4 and 6).
4. **Aborted mid-session link (live PR daemon conflict or transient fetch failure):** Failing before committing the upgrade must leave `SessionTarget::Local` and `old_dir` completely untouched with no partial migration (pinned in Tasks 4 and 6).
5. **Agent env (`JPR_PR`) and shutdown cleanup after upgrade:** Local `:Jpr agent` launches must omit `JPR_PR` (never exporting `"nil"`), preserve `JPR_SOCKET` across linking, and clear `socket` from the upgraded `pr-<N>/session.json` on clean daemon shutdown (pinned in Tasks 7 and 8).

---

### Task 1: Domain Model, Protocol Version 8, and Port Extensions

**Files:**
- Modify: `Cargo.toml`
- Modify: `crates/review-model/src/view.rs`
- Modify: `crates/review-model/src/lib.rs`
- Modify: `crates/review-core/src/ports.rs`
- Modify: `crates/review-core/src/ports/store.rs`
- Modify: `crates/review-core/src/presenter.rs`
- Modify: `crates/review-core/src/session/mod.rs`
- Modify: `crates/review-core/src/fakes.rs`
- Modify: `crates/review-core/src/fakes/workspace.rs`
- Modify: `crates/review-rpc/src/protocol.rs`
- Modify: `lua/jpr/rpc.lua`
- Modify: `lua/jpr/init.lua`

**Interfaces:**
- Consumes: Existing `SessionView`, `Forge`, `Workspace`, `ReviewStore`, and `session_view` types.
- Produces:
  - `review_model::LocalReviewContext { pub branch: String, pub base_ref: String, pub base_sha: String, pub repo: Option<String> }`
  - `SessionView::local_context: Option<LocalReviewContext>` (JSON key `"localContext"`, omitted when `None`)
  - `Workspace::resolve_ref(&self, reference: &str) -> Result<String>`
  - `Forge::current_branch_pr(&self) -> Result<Option<PullRequest>>`
  - `Forge::pin_repo(&self, owner: &str, repo: &str)` (default no-op)
  - `ReviewStore::retarget_to_pr(&self, owner: &str, repo: &str, number: u64) -> Result<Option<StoreSnapshot>>` (default `Ok(None)`)
  - `ReviewStore::finalize_retarget(&self) -> Result<()>` (default `Ok(())`)
  - `PROTOCOL_VERSION = 8` (Rust + Lua) and `VERSION = "0.7.0"` (Rust + Lua)

- [ ] **Step 1: Write failing tests for `LocalReviewContext` serialization and `session_view` local context**

In `crates/review-model/src/view.rs` (`mod tests`), add `local_context_serializes_camel_case_and_is_omitted_when_none` asserting:
- `SessionView` with `local_context: None` omits `"localContext"` in JSON and legacy JSON without `"localContext"` deserializes to `None`.
- `SessionView` with `local_context: Some(LocalReviewContext { branch: "feat/x".into(), base_ref: "develop".into(), base_sha: "abc1234".into(), repo: Some("octo/widgets".into()) })` encodes `"localContext": { "branch": "feat/x", "baseRef": "develop", "baseSha": "abc1234", "repo": "octo/widgets" }`, and omits `"repo"` when `None`.

In `crates/review-core/src/presenter.rs` (`mod tests`), add `session_view_carries_local_context_when_unlinked` asserting `view.pr.is_none()` and `view.local_context == Some(ctx)`.

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test -p review-model -p review-core --all-features`
Expected: FAIL to compile (`LocalReviewContext` and `local_context` not defined).

- [ ] **Step 3: Implement model, port traits, fakes, presenter, and lockstep version bumps**

- Add `LocalReviewContext` and `SessionView::local_context` in `crates/review-model/src/view.rs` and re-export `LocalReviewContext` from `crates/review-model/src/lib.rs`.
- Add `resolve_ref` to `Workspace`, `current_branch_pr` and default `pin_repo` to `Forge` in `crates/review-core/src/ports.rs`, and default `retarget_to_pr` + `finalize_retarget` to `ReviewStore` in `crates/review-core/src/ports/store.rs`.
- Update `presenter::session_view` to take `local_context: Option<&LocalReviewContext>` and update `ReviewSession::view_with_status` plus presenter test calls.
- Implement fake support on `FakeWorkspace` (`set_ref_sha`, `resolve_ref` returning configured SHA or `base000` default, honoring `failure`), `FakeForge` (`set_current_branch_pr`, `clear_pr`, `pinned_repo`, `current_branch_pr`, `pin_repo`), and `MemoryStore` (`set_retarget_snapshot`, `fail_retarget_with`, `retargeted_prs`, `finalized_retarget_count`, `retarget_to_pr`, `finalize_retarget`).
- Implement temporary stub/default `resolve_ref` on `GitWorkspace` and `current_branch_pr` on `GhForge` (or wire real bodies in Tasks 2-3; keep workspace compiling cleanly!).
- Bump `Cargo.toml` workspace version to `0.7.0`, `lua/jpr/init.lua` `M.VERSION` to `"0.7.0"`, `crates/review-rpc/src/protocol.rs` `PROTOCOL_VERSION` to `8`, and `lua/jpr/rpc.lua` `M.PROTOCOL_VERSION` to `8`. Update any existing tests asserting `PROTOCOL_VERSION == 7` or `VERSION == "0.6.0"`.

- [ ] **Step 4: Run workspace tests and Lua specs**

Run: `cargo test --workspace --all-features && ./scripts/test-lua.sh`
Expected: PASS across all Rust crates and Lua specs.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml crates/ lua/ tests/
git commit -m "feat(model): add LocalReviewContext, port hooks, and protocol v8 / 0.7.0 lockstep"
```

---

### Task 2: Git Base-Branch Auto-Detection & `Workspace::resolve_ref` (`review-workspace-git`)

**Files:**
- Create: `crates/review-workspace-git/src/local_ref.rs`
- Modify: `crates/review-workspace-git/src/workspace.rs`
- Modify: `crates/review-workspace-git/src/lib.rs`

**Interfaces:**
- Consumes: `Workspace::resolve_ref` (Task 1), `crate::process::{run, run_bytes_unlocked}`, `crate::git_output::is_commit_id`.
- Produces:
  - `review_workspace_git::LocalWorktreeInfo { pub worktree: PathBuf, pub branch: String, pub base_ref: String, pub base_sha: String }`
  - `review_workspace_git::BranchProbe` trait (`ref_exists`, `symbolic_origin_head`)
  - `review_workspace_git::resolve_default_base_branch(probe: &impl BranchProbe) -> Result<String>`
  - `review_workspace_git::validate_git_ref(reference: &str) -> Result<()>`
  - `review_workspace_git::read_current_branch(dir: &Path) -> Result<String>`
  - `review_workspace_git::inspect_local_worktree(dir: &Path, explicit_base: Option<&str>) -> Result<LocalWorktreeInfo>`
  - Real `GitWorkspace::resolve_ref(&self, reference: &str) -> Result<String>`

- [ ] **Step 1: Write failing unit and git-repo integration tests in `crates/review-workspace-git/src/local_ref.rs`**

Add tests asserting:
- `default_base_prefers_develop_then_origin_develop_then_main_then_origin_main_then_origin_head_then_master`: verifies exact priority order with a `FakeProbe` and error mentioning `--base` when none exist.
- `validate_git_ref_rejects_empty_leading_dash_whitespace_and_control_bytes`: rejects `""`, `"-x"`, `"--all"`, `"a b"`, `"a\nb"`, `"a\0b"` and accepts `"develop"`, `"origin/main"`, `"HEAD"`, `"v1.0.0"`, `"HEAD~2"`.
- `inspect_local_worktree_auto_detects_branch_and_resolves_base_sha`: in a real temp git repo (`test_support::repo`), checks `main` default, `develop` preference when created, explicit `HEAD` override, and detached HEAD reporting `"detached-<short>"`.
- `git_workspace_resolve_ref_returns_full_commit_sha_and_rejects_flags`: verifies `GitWorkspace::resolve_ref("HEAD")` returns a 40-char commit SHA and `resolve_ref("--verify")` fails.

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test -p review-workspace-git local_ref`
Expected: FAIL (module/functions not implemented).

- [ ] **Step 3: Implement `crates/review-workspace-git/src/local_ref.rs` and wire `GitWorkspace::resolve_ref`**

- Keep every function `<= 45` lines.
- Use `git rev-parse --verify --quiet <ref>^{commit}` (unlocked via `GIT_OPTIONAL_LOCKS=0`) for ref existence and SHA resolution.
- Use `git symbolic-ref --quiet --short refs/remotes/origin/HEAD` for `symbolic_origin_head`.
- Export `LocalWorktreeInfo`, `BranchProbe`, `inspect_local_worktree`, `read_current_branch`, `resolve_default_base_branch`, `validate_git_ref` from `crates/review-workspace-git/src/lib.rs`.
- Replace stub `GitWorkspace::resolve_ref` in `workspace.rs` with `local_ref::resolve_ref_commit(&self.dir, reference)`.

- [ ] **Step 4: Run tests and clippy**

Run: `cargo test -p review-workspace-git && cargo clippy -p review-workspace-git --all-targets -- -D warnings`
Expected: PASS, 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add crates/review-workspace-git/
git commit -m "feat(workspace-git): add base-branch auto-detection and Workspace::resolve_ref"
```

---

### Task 3: Active PR Auto-Detection & Repo Pinning (`review-forge-github`)

**Files:**
- Modify: `crates/review-forge-github/src/pr.rs`
- Modify: `crates/review-forge-github/src/lib.rs`

**Interfaces:**
- Consumes: `Forge::current_branch_pr`, `Forge::pin_repo` (Task 1), `pr::PR_FIELDS`, `pr::parse_pr`.
- Produces:
  - `review_forge_github::pr::parse_optional_open_pr(stdout: &str) -> Result<Option<PullRequest>>`
  - `review_forge_github::pr::is_no_pr_for_branch_stderr(stderr: &str) -> bool`
  - `GhForge::current_branch_view_args(&self) -> Vec<String>`
  - Real `Forge::current_branch_pr` and `Forge::pin_repo` on `GhForge` (using `Arc<RwLock<Option<String>>>` for `repo` so `GhForge` stays `Clone + Send` and `GhForge::new` keeps its exact signature)

- [ ] **Step 1: Write failing tests in `crates/review-forge-github/src/pr.rs` and `src/lib.rs`**

Add tests asserting:
- `parse_optional_open_pr_returns_some_for_open_and_none_for_merged_or_closed`: `OPEN` -> `Ok(Some(pr))`, `MERGED` -> `Ok(None)`, `CLOSED` -> `Ok(None)`, invalid JSON -> `Err`.
- `is_no_pr_for_branch_stderr_classifies_no_pr_and_non_github_remotes_but_not_network_or_auth`: returns `true` for `"no pull requests found for branch \"feat/x\""`, `"could not find pull request"`, `"none of the git remotes configured for this repository point to a known GitHub host"`, `"no git remotes found"`, `"not on any branch"`; returns `false` for `"gh timed out after 30s"`, `"To get started with GitHub CLI, please run:  gh auth login"`, `"error connecting to api.github.com"`.
- `current_branch_view_args_omits_pr_number_and_respects_pinned_repo`: `GhForge::new(dir, None).current_branch_view_args()` is `["pr", "view", "--json", PR_FIELDS]` (no `--repo`); after `forge.pin_repo("upstream-org", "widgets")`, `view_args(7)` includes `["--repo", "upstream-org/widgets"]` (pins Review Focus #2).

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test -p review-forge-github`
Expected: FAIL (`parse_optional_open_pr`, `is_no_pr_for_branch_stderr`, `current_branch_view_args` missing).

- [ ] **Step 3: Implement `pr.rs` helpers and `GhForge` `current_branch_pr` + `pin_repo`**

- Refactor `GhForge.repo` to `Arc<RwLock<Option<String>>>` with a helper `pinned_repo(&self) -> Option<String>`.
- Implement `current_branch_pr`: run `self.gh.run(&arg_refs, None)`. On `Ok(stdout)`, return `pr::parse_optional_open_pr(&stdout)`. On `Err(error)`, if `pr::is_no_pr_for_branch_stderr(&format!("{error:#}"))`, return `Ok(None)`, else return `Err(error)`.
- Implement `pin_repo(&self, owner, repo)` writing `Some(format!("{owner}/{repo}"))` into `self.repo`.

- [ ] **Step 4: Run tests and clippy**

Run: `cargo test -p review-forge-github && cargo clippy -p review-forge-github --all-targets -- -D warnings`
Expected: PASS, 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add crates/review-forge-github/
git commit -m "feat(forge-github): add current_branch_pr auto-detection and repo pinning"
```

---

### Task 4: Local State Directory Paths & Crash-Safe `FsStore` Retargeting (`review-store-fs`)

**Files:**
- Modify: `crates/review-store-fs/src/paths.rs`
- Create: `crates/review-store-fs/src/retarget.rs`
- Modify: `crates/review-store-fs/src/lib.rs`

**Interfaces:**
- Consumes: `ReviewStore::retarget_to_pr`, `ReviewStore::finalize_retarget` (Task 1), `paths::state_dir`, `lock::with_local_lock`, `format::refuse_newer`.
- Produces:
  - `review_store_fs::local_state_dir(xdg_state_home: Option<&Path>, home: &Path, app: &str, owner_repo: Option<(&str, &str)>, worktree_root: &Path, branch: &str) -> Result<PathBuf>`
  - `review_store_fs::StateRootConfig { pub xdg_state_home: Option<PathBuf>, pub home: PathBuf, pub app: String }`
  - `FsStore::new_with_root(dir: impl Into<PathBuf>, state_root: StateRootConfig) -> Self`
  - `FsStore::current_dir(&self) -> PathBuf`
  - Real `ReviewStore::retarget_to_pr` and `ReviewStore::finalize_retarget` on `FsStore`

- [ ] **Step 1: Write failing tests in `crates/review-store-fs/src/paths.rs` and `src/retarget.rs`**

Add tests asserting:
- `local_state_dir_places_repo_scoped_and_remote_less_worktrees_in_collision_free_paths`:
  - With `Some(("octo", "widgets"))`: `<state>/jpr/octo/widgets/local-feat-auth-<8hex>`.
  - With `None`: `<state>/jpr/_local/<dir_slug>-<8hex>/local-feat-auth-<8hex>`.
  - Different case/worktrees (`feat/Auth` vs `feat/auth`, or two worktree roots on `main`) produce distinct `<8hex>` suffixes; rejects unsafe `owner`/`repo`.
- `retarget_to_pr_migrates_rounds_switches_dir_and_finalize_retires_old_files_preserving_live_socket`:
  - Saves local threads, `local_viewed`, `rounds.jsonl`, and creates a dummy `s.sock` in `old_dir`.
  - Calls `retarget_to_pr("octo", "widgets", 42)` -> returns `Ok(None)`, `current_dir()` is `pr-42`, `rounds()` returns migrated rounds, and BEFORE `finalize_retarget()`, `old_dir/local.json` still exists (crash safety before PR save).
  - Saves merged snapshot into `pr-42`, calls `finalize_retarget()` -> `old_dir/local.json`, `old_dir/rounds.jsonl`, `old_dir/session.json`, `old_dir/viewed.json`, `old_dir/github.json` are deleted while `old_dir/s.sock` remains intact (pins Review Focus #3).
- `retarget_to_pr_returns_existing_pr_snapshot_and_refuses_live_daemon_or_newer_version`:
  - Preexisting `pr-42` snapshot is returned for merging; a bound Unix socket in `pr-42/session.json` or `pr-42/s.sock` causes `retarget_to_pr` to fail with `"already serving PR #42"` without changing `current_dir()` or touching `old_dir` (pins Review Focus #4).

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test -p review-store-fs`
Expected: FAIL (`local_state_dir`, `StateRootConfig`, `new_with_root`, `retarget_to_pr` not implemented).

- [ ] **Step 3: Implement `paths.rs` local dir, `retarget.rs`, and `RwLock<PathBuf>` inside `FsStore`**

- Keep `FsStore::new(dir)` backwards-compatible (`state_root: None`). Update `FsStore::dir(&self)` -> `current_dir(&self) -> PathBuf` (or keep `dir()` if tests call it; check all callers with `rg '\.dir\(\)' crates/`).
- Put retargeting, live-daemon Unix socket check, rounds copy, and `finalize_retarget` in `crates/review-store-fs/src/retarget.rs` so both `lib.rs` and `retarget.rs` stay well under 400 lines.
- Ensure `FsStore` continues passing `review_core::contract::review_store_contract`.

- [ ] **Step 4: Run tests and clippy**

Run: `cargo test -p review-store-fs && cargo clippy -p review-store-fs --all-targets -- -D warnings`
Expected: PASS, 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add crates/review-store-fs/
git commit -m "feat(store-fs): add local state paths and crash-safe PR retargeting"
```

---

### Task 5: Unified `ReviewSession` Local Mode, Agent Prompts, and Ticker Gating (`review-core`, `review-rpc`)

**Files:**
- Modify: `crates/review-core/src/session/mod.rs`
- Modify: `crates/review-core/src/session/diffs.rs`
- Modify: `crates/review-core/src/session/local_files.rs`
- Modify: `crates/review-core/src/session/viewed.rs`
- Modify: `crates/review-core/src/session/comments.rs`
- Modify: `crates/review-core/src/session/comments/helpers.rs`
- Modify: `crates/review-core/src/session/local.rs`
- Modify: `crates/review-core/src/session/submit.rs`
- Modify: `crates/review-core/src/session/push.rs`
- Modify: `crates/review-core/src/session/agent_loop.rs`
- Modify: `crates/review-core/src/session/worktree_watch.rs`
- Modify: `crates/review-core/src/agent.rs`
- Modify: `crates/review-rpc/src/server/ticker.rs`
- Create: `crates/review-core/src/session/local_mode_tests.rs`

**Interfaces:**
- Consumes: `LocalReviewContext`, `Workspace::resolve_ref` (Task 1).
- Produces:
  - `ReviewSession::open_local(context: LocalReviewContext, ports: Ports) -> Result<Self>`
  - `ReviewSession::is_linked(&self) -> bool`
  - `ReviewSession::require_linked_pr(&self) -> Result<&PullRequest>`
  - `review_core::agent::build_local_send_prompt_from_threads(context: &LocalReviewContext, threads: &[&Thread]) -> String`
  - `review_core::agent::build_local_prepass_prompt_from_context(context: &LocalReviewContext) -> String`
  - `review-rpc` ticker skipping `PollStep::Sync` and `PollStep::Retry` when `!session.is_linked()` while running `poll_worktree_files()` every 2s.

- [ ] **Step 1: Write failing tests in `crates/review-core/src/session/local_mode_tests.rs` and `crates/review-rpc/src/server/ticker.rs`**

Add tests asserting:
- `open_local_populates_files_diffs_stream_and_persists_local_viewed_without_calling_forge`: opens local session on `FakeWorkspace` with changed files; verifies `view().pr.is_none()`, `view().local_context == Some(ctx)`, `view().files` populated immediately with `is_local_only == true`, `file_diff` and `stream` succeed, `set_viewed("src/a.rs", true)` updates `local.json` and emits `ViewedChanged` with `forge.viewed_calls().is_empty()`, and disk edit transitions `Viewed` to `Dismissed`.
- `local_mode_refuses_all_github_only_operations_and_returns_empty_mentions`: verifies `comment(Github)`, `promote_thread`, `suggest_from_edit`, `submit_preview`, `submit_review`, `push`, `retry_message`, and `prepare_conflict_resolution` all fail with `"not linked to a GitHub pull request yet"`, and `mentions()` is empty.
- `local_mode_supports_local_comments_agent_launch_bulk_send_and_prepass`: verifies `comment_with_origin(Local)`, `prepare_agent_launch`, `prepare_send`, `confirm_send`, `agent_reply`, `prepare_prepass`, and `prepass_write` all succeed without a PR, and generated prompts reference `branch`, `base_ref`, and `"Keep edits unstaged in this worktree"`.
- `local_mode_refreshes_base_sha_when_base_ref_moves`: calls `workspace.set_ref_sha("develop", "newbase99")` and verifies `refresh_worktree` updates `view().local_context.base_sha` and recomputes merge base.
- In `review-rpc/src/server/ticker.rs`: `ticker_skips_sync_and_retry_while_unlinked_but_still_watches_worktree` verifying `PollStep::Sync`/`Retry` do not invoke `session.sync()` while `!is_linked()`, while worktree polling runs.

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test -p review-core -p review-rpc --all-features`
Expected: FAIL (`open_local`, `is_linked`, local prompts missing).

- [ ] **Step 3: Implement `SessionTarget`, `open_local`, `active_base_sha`, `require_linked_pr`, local agent prompts, and ticker gating**

- Replace `number: u64` on `ReviewSession` with `target: SessionTarget` (`Pr { number }` / `Local(LocalReviewContext)`).
- Update `active_base_sha(&mut self) -> Result<String>` to resolve `base_ref` via `workspace.resolve_ref` in local mode (updating `target`'s `base_sha` on move, falling back to cached `base_sha` if `resolve_ref` fails).
- Update `prepare_base`, `refresh_local_files`, `collect_candidate_paths`, and `set_viewed` to work seamlessly when `target` is `Local`.
- Route all GitHub-only methods through `require_linked_pr()` (checking `Local` first so the error message says `"this review is not linked to a GitHub pull request yet; run :Jpr sync once a PR is open"`).
- Add `build_local_send_prompt_from_threads` and `build_local_prepass_prompt_from_context` in `crates/review-core/src/agent.rs` and dispatch on `self.target` in `session/agent_loop.rs`.
- Gate `PollStep::Sync` and `PollStep::Retry` on `guard.is_linked()` in `crates/review-rpc/src/server/ticker.rs`.

- [ ] **Step 4: Run tests and clippy**

Run: `cargo test -p review-core -p review-rpc --all-features && cargo clippy -p review-core -p review-rpc --all-targets --all-features -- -D warnings`
Expected: PASS, 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add crates/review-core/ crates/review-rpc/
git commit -m "feat(core): add unified local ReviewSession mode, agent prompts, and ticker gating"
```

---

### Task 6: Mid-Session Local-to-PR Upgrade & Authoritative Viewed Promotion (`review-core`)

**Files:**
- Create: `crates/review-core/src/session/link.rs`
- Create: `crates/review-core/src/session/link_tests.rs`
- Modify: `crates/review-core/src/session/mod.rs`
- Modify: `crates/review-core/src/session/sync.rs`

**Interfaces:**
- Consumes: `Forge::current_branch_pr`, `Forge::pin_repo`, `ReviewStore::retarget_to_pr`, `ReviewStore::finalize_retarget` (Tasks 1, 3, 4), `SessionTarget`, `promote_adopted_local_viewed` (Task 5 + Track 1).
- Produces:
  - `ReviewSession::sync(&mut self) -> Result<SessionView>` handling `SessionTarget::Local` via `sync_or_link_local(&mut self, now: u64) -> Result<SessionView>` with zero-downtime upgrade, preexisting PR state merging, authoritative local `VIEWED` promotion, and crash-safe `finalize_retarget()`.

- [ ] **Step 1: Write failing tests in `crates/review-core/src/session/link_tests.rs`**

Add tests asserting:
- `sync_in_local_mode_returns_notice_without_sync_failed_when_no_pr_exists`: `current_branch_pr()` returns `Ok(None)` -> `sync()` returns `Err` containing `"no open pull request found for branch"`, `view().sync == SyncState::Never`, no `Event::SyncFailed` emitted, `is_linked() == false`.
- `sync_in_local_mode_rolls_back_cleanly_on_fetch_or_retarget_failure`:
  - `forge.fail_reads_with(Some("timeout"))` on `fetch` -> `retarget_to_pr` NOT called, `is_linked() == false`, `local_viewed` and threads untouched (pins Review Focus #4).
  - `store.fail_retarget_with(Some("already serving PR #7"))` -> `is_linked() == false`, `finalize_retarget` NOT called, `local_viewed` and threads untouched (pins Review Focus #4).
- `sync_in_local_mode_links_promotes_authoritative_viewed_and_keeps_unpushed_files_local`:
  - Starts local with `src/a.rs` (`Viewed`), `src/b.rs` (`Unviewed`), `src/c.rs` (`Viewed`, unpushed extra file), and a local thread `loc-1` + `agent_session_id`.
  - PR `#7` has `src/a.rs` (`Unviewed`) and `src/b.rs` (`Unviewed`).
  - `sync()` upgrades session: `is_linked() == true`, `view.pr.unwrap().number == 7`, `view.local_context.is_none()`, `forge.pinned_repo() == Some("octo/widgets")`, `forge.viewed_calls() == [("src/a.rs", true)]`, `src/a.rs` is `Viewed`, `src/b.rs` is `Unviewed`, `src/c.rs` remains `is_local_only == true` and `Viewed`, `store.finalized_retarget_count() == 1`, and NO `Event::HeadMoved` is emitted on first link.
- `sync_in_local_mode_queues_promoted_viewed_when_github_write_fails_transiently`:
  - `forge.fail_writes_with(Some("offline"))` during link -> `src/a.rs` stays `Viewed` locally with `queued_count == 1` (`queued_viewed["src/a.rs"] == true`) so the next flush/sync delivers it to GitHub.
- `sync_in_local_mode_merges_preexisting_pr_snapshot_renumbering_colliding_local_ids`:
  - Preexisting `pr-7` snapshot has local thread `loc-1` (`next_local_id = 1`) and `queued_viewed["src/a.rs"] = false`; current local session also has `loc-1` and `local_viewed["src/a.rs"] = Viewed`.
  - After link: both local threads survive with distinct IDs (`loc-1` and `loc-2`), `next_local_id >= 2`, `src/a.rs` is `Viewed` (current local `VIEWED` wins over stale `false`), and live `socket`/`pid`/`agent_session_id` are preserved.

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test -p review-core --all-features link_tests`
Expected: FAIL (`sync_or_link_local` not implemented).

- [ ] **Step 3: Implement `crates/review-core/src/session/link.rs` and dispatch from `sync.rs`**

- Keep every helper `<= 45` lines (`sync_or_link_local`, `merge_preexisting_pr_snapshot`, `renumber_colliding_local_threads`).
- Sequence strictly:
  1. `let Some(pr) = self.ports.forge.current_branch_pr()? else { bail!(...) };`
  2. `let snapshot = self.ports.forge.fetch(&pr)?;` (before retargeting!)
  3. `let existing = self.ports.store.retarget_to_pr(&pr.owner, &pr.repo, pr.number)?;`
  4. Merge `existing` if `Some(prior)` (preserving live daemon/agent fields and authoritative `local_viewed`).
  5. `self.ports.forge.pin_repo(&pr.owner, &pr.repo);`
  6. `self.target = SessionTarget::Pr { number: pr.number };`
  7. `let view = self.apply_pull(pr, snapshot, now)?;`
  8. `let _ = self.ports.store.finalize_retarget();` (after `apply_pull` durably saved `pr-<N>/`).
- Notice in `apply_pull`: `previous_head_sha` is `None` because `self.saved.session.pr` was `None`, so `handle_head_moved` naturally does not run on first link.

- [ ] **Step 4: Run tests and clippy**

Run: `cargo test -p review-core --all-features && cargo clippy -p review-core --all-targets --all-features -- -D warnings`
Expected: PASS, 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add crates/review-core/
git commit -m "feat(core): implement mid-session local-to-PR upgrade with authoritative viewed promotion"
```

---

### Task 7: CLI Subcommands (`local`, `serve --local`, `state-path --local`) & Rust TTY Palette (`crates/jpr-review`)

**Files:**
- Create: `crates/jpr-review/src/commands/local.rs`
- Modify: `crates/jpr-review/src/cli.rs`
- Modify: `crates/jpr-review/src/commands/mod.rs`
- Modify: `crates/jpr-review/src/commands/serve.rs`
- Modify: `crates/jpr-review/src/commands/state_path.rs`
- Modify: `crates/jpr-review/src/commands/socket_client.rs`
- Modify: `crates/jpr-review/src/tui_schema/specs.rs`
- Modify: `crates/jpr-review/src/tui_schema/steps.rs`
- Modify: `crates/jpr-review/src/tui_schema/prefill.rs`
- Modify: `crates/jpr-review/src/tui_schema/convert.rs`
- Modify: `crates/jpr-review/src/tui_schema/tests/` (completeness & round-trip tests)

**Interfaces:**
- Consumes: `inspect_local_worktree`, `read_current_branch` (Task 2), `GhForge::current_branch_pr` (Task 3), `local_state_dir`, `StateRootConfig`, `FsStore::new_with_root`, `FsStore::current_dir` (Task 4), `ReviewSession::open_local` (Task 5).
- Produces:
  - `jpr-review local [--base <REF>] [--repo <OWNER/NAME>] [--no-pr]` -> JSON `{"mode":"pr",...}` or `{"mode":"local","worktree":...,"branch":...,"baseRef":...,"baseSha":...,"repo":...}`
  - `jpr-review serve (--pr <N> --repo <OWNER/NAME> | --local [--base <REF>] [--repo <OWNER/NAME>]) [--poll <SECONDS>]`
  - `jpr-review state-path (--pr <N> --repo <OWNER/NAME> | --local [--repo <OWNER/NAME>])`
  - All 9 subcommands registered in `tui_schema` with discriminant-first steps and passing completeness tests.

- [ ] **Step 1: Write failing tests for CLI parsing, `commands::local` precedence, `serve` shutdown cleanup, and `tui_schema` completeness**

Add tests asserting:
- In `cli.rs`: `local` parses `[--base] [--repo] [--no-pr]`; `serve` accepts `--local [--base <ref>] [--repo <owner/name>]` and rejects `--pr 7 --local` or `--pr 7` without `--repo` or `--base main` without `--local`; `state-path` accepts `--local` and rejects `--pr 7 --local`.
- In `commands/local.rs`:
  - Explicit `--base HEAD` bypasses `current_branch_pr()` and outputs `{"mode":"local",...,"baseRef":"HEAD"}` even when fake forge has an open PR (pins Review Focus #1).
  - Bare `local` with an open PR outputs `{"mode":"pr","worktree":...,"repo":"octo/widgets","number":7,"title":...}` and verifies `GhForge` is only pinned to `--repo` when explicitly supplied, never `origin`-inferred `repo` (pins Review Focus #2).
  - Bare `local` when `current_branch_pr()` returns `Err("offline")` falls back cleanly to `{"mode":"local",...}`.
- In `commands/serve.rs`: `clear_owned_socket_record` uses `store.current_dir()` so after a mid-session `retarget_to_pr`, shutdown clears `socket` in `pr-<N>/session.json` instead of the retired local directory (pins Review Focus #5).
- In `tui_schema/tests/`: all 9 subcommands (`prs`, `local`, `checkout`, `threads`, `reply`, `prepass-write`, `state-path`, `serve`, `guide`) pass `validate_command_specs`, discriminant-first `when` tests (`local` with `base_mode == "custom"` hides `detect_pr` and `custom_repo`; `serve`/`state-path` with `session_mode == "local"` hides `pr` and `repo`), and `answers_to_command` round-trips.

- [ ] **Step 2: Run tests to verify failure**

Run: `cargo test -p jpr-review`
Expected: FAIL (new CLI variants, `commands/local.rs`, and schema specs missing).

- [ ] **Step 3: Implement CLI commands, shutdown store-dir tracking, offline local fallback, and `tui_schema` updates**

- Implement `crates/jpr-review/src/commands/local.rs` with a testable pure/port-injected `resolve_local_output(...)` helper plus `run(...)`.
- Update `commands/serve.rs` to support `ServeTarget::Pr` vs `ServeTarget::Local`, wire `FsStore::new_with_root` + `Arc<FsStore>` (or shared active-dir accessor) so `clear_owned_socket_record` clears `socket` from the active post-upgrade directory and best-effort removes an empty retired socket directory on shutdown.
- Update `commands/state_path.rs` for `--local`.
- Update `commands/socket_client.rs` so offline fallback checks for an existing `local_state_dir` (containing `local.json`) for the current worktree/branch when `--pr` and `$JPR_PR` are absent before prompting for `--pr`.
- Update `tui_schema` (`specs.rs`, `steps.rs`, `prefill.rs`, `convert.rs`) for `local`, `serve`, and `state-path`, keeping every file `<= 400` lines and every function `<= 45` lines.

- [ ] **Step 4: Run workspace tests, dependency rule, and clippy**

Run: `cargo test --workspace --all-features && cargo clippy --workspace --all-targets --all-features -- -D warnings`
Expected: PASS, 0 warnings, `dependency_rule` green.

- [ ] **Step 5: Commit**

```bash
git add crates/jpr-review/
git commit -m "feat(cli): add jpr-review local, serve --local, state-path --local, and TUI schema"
```

---

### Task 8: Neovim Plugin `:Jpr local`, Local Rendering, and Mid-Session PR Upgrade (`lua/jpr`)

**Files:**
- Modify: `lua/jpr/commands/schema.lua`
- Modify: `lua/jpr/init.lua`
- Modify: `lua/jpr/binary.lua`
- Modify: `lua/jpr/session/init.lua`
- Modify: `lua/jpr/session/open.lua`
- Create: `lua/jpr/session/open_local.lua` (keeps `open.lua <= 400` lines)
- Modify: `lua/jpr/session/commands.lua`
- Modify: `lua/jpr/session/events.lua`
- Modify: `lua/jpr/session/crash.lua`
- Modify: `lua/jpr/render/panel.lua`
- Modify: `lua/jpr/render/statusline.lua`
- Modify: `lua/jpr/render/stream.lua`
- Modify: `lua/jpr/views/panel.lua`
- Modify: `lua/jpr/views/stream/init.lua`
- Modify: `lua/jpr/views/loading.lua`
- Modify: `lua/jpr/views/conversation.lua`
- Modify: `lua/jpr/comments/compose.lua`
- Modify: `lua/jpr/comments/popup.lua`
- Modify: `tests/lua/palette_and_open_picker_spec.lua`
- Create: `tests/lua/local_review_spec.lua`

**Interfaces:**
- Consumes: `jpr-review local` JSON, `jpr-review serve --local` JSON-RPC v8, `SessionView.localContext` (Tasks 1-7).
- Produces:
  - 16th `:Jpr` subcommand `local` (`Review Current Worktree [local]`) in `lua/jpr/commands/schema.lua`
  - Direct `:Jpr local` and `:Jpr local <base_ref>` fast paths in `lua/jpr/init.lua`
  - `jpr.session.open_local(base_ref)`, `jpr.session.start_local(info, pending_session)`, `jpr.session.buf_key(session)`, `jpr.session.display_label(session)`
  - Mid-session upgrade handling in `jpr.session.show` (`session.mode = "pr"`, `session.number`, `session.repo`, notification, full redraw)
  - `binary.create_agent_env_from_session` omitting `JPR_PR` when `pr_number == nil`

- [ ] **Step 1: Write failing Lua specs in `tests/lua/palette_and_open_picker_spec.lua` and `tests/lua/local_review_spec.lua`**

Add headless Neovim specs asserting:
- Schema completeness for all 16 `:Jpr` subcommands (including `local` right after `open`, discriminant-first `base_mode` + `base` steps, validation rejecting `"-bad"` / whitespace, and bare `:Jpr local` / `:Jpr local HEAD` direct dispatch).
- `binary.create_agent_env_from_session` omits `JPR_PR` when `pr_number == nil` and sets `JPR_PR = "7"` when `pr_number == 7` (pins Review Focus #5).
- `render.panel.build` in local mode renders `"LOCAL feat/x vs develop"`, `"local only · :Jpr sync to link PR"`, `"  💬 Local Notes"`, and suppresses redundant `[local]` per-file badges; after linking (`view.pr` set), switches to `"#7 ..."`, `"  💬 Conversation"`, and shows `[local]` only on `isLocalOnly == true` files.
- `render.statusline.build_statusline_from_session` renders `"LOCAL feat/x · dirty ↑1 · 1/3 viewed · 2 local"` when unlinked and `"PR #7 · ..."` after upgrade.
- `render.stream.build_key_from_view` changes when `localContext.baseSha` changes or when upgrading from `localContext` to `pr`.
- `session.open_local` reuses an existing tab for the same canonical worktree and emits an info notice on mode/base mismatch without closing buffers (Decision C1); routes `mode == "pr"` to `session.start` (attaching in-place) and `mode == "local"` to `session.start_local` (spawning `serve --local --base <baseRef>` without `--repo` and requesting `snapshot` without initial `sync`).
- `compose.open_new` in an unlinked local session locks destination to `"local"`, disables `<C-g>`/`<M-s>`, and shows `" <C-s> save · local review (no linked PR) · q cancel "`; `popup` and `conversation` refuse `p` (promote) with an info notice when unlinked.
- Mid-session upgrade via `session.show(session, synced_pr_view)` transitions `session.mode`, `session.number`, `session.repo`, updates statusline/panel, and notifies `"Linked to PR #7 ..."`.
- `crash.append_crash_log` and `crash.handle_unexpected_exit` work cleanly when `session.number == nil` (`engine-local-...log`, `"local review (feat/x)"` label).

- [ ] **Step 2: Run Lua specs to verify failure**

Run: `./scripts/test-lua.sh`
Expected: FAIL on new `local_review_spec.lua` and updated `palette_and_open_picker_spec.lua`.

- [ ] **Step 3: Implement Lua schema, session lifecycle, renderers, and views**

- Keep every Lua file `<= 400` lines and every function `<= 45` lines (place local open/probe/tab-reuse helpers in `lua/jpr/session/open_local.lua`).
- Ensure `session.buf_key(session)` returns `tostring(session.number)` for PR sessions (preserving `jpr://panel/7`, `jpr://stream/7`, `jpr://conversation/7`, `jpr://loading/7`) and `"local-" .. tostring(session.tab)` for local sessions.
- Ensure `M.show` triggers stream + diff rendering whenever `type(view.pr) == "table" or type(view.localContext) == "table"`.
- Ensure `M.sync_session` in `lua/jpr/session/commands.lua` and `events.lua` use `session.display_label(session)` instead of assuming numeric `session.number`.

- [ ] **Step 4: Run all Lua specs**

Run: `./scripts/test-lua.sh`
Expected: PASS across all Lua spec files.

- [ ] **Step 5: Commit**

```bash
git add lua/ tests/lua/
git commit -m "feat(nvim): add :Jpr local, local UI rendering, and mid-session PR upgrade"
```

---

### Task 9: Documentation, Cheatsheet, and Full Workspace Verification

**Files:**
- Modify: `docs/protocol.md`
- Modify: `docs/architecture.md`
- Modify: `docs/decisions.md`
- Modify: `README.md`
- Modify: `lua/jpr/views/cheatsheet.lua`
- Modify: `tests/lua/cheatsheet_spec.lua` (if assertions cover command entries)

**Interfaces:**
- Consumes: All Track 2 interfaces and behaviors from Tasks 1-8.
- Produces: Up-to-date docs, ADR, README, and `:Jpr keys` cheatsheet with zero em dashes and full `just check` pass.

- [ ] **Step 1: Update documentation and cheatsheet**

- `docs/protocol.md`: document protocol version 8, `LocalReviewContext`, `SessionView.localContext`, `jpr-review serve --local`, and the local-mode RPC behavior table (including `:Jpr sync` local-to-PR upgrade).
- `docs/architecture.md`: document `SessionTarget::Local` / `SessionTarget::Pr`, `local_ref.rs`, `current_branch_pr`, `local_state_dir`, `FsStore` retargeting + `finalize_retarget`, `jpr-review local`, 16 `:Jpr` subcommands, and local-mode UI adaptations.
- `docs/decisions.md`: add concise ADR explaining in-place `ReviewSession` + `FsStore` retargeting (preserving live `JPR_SOCKET`), explicit `--base` local-only precedence (C1), and `GhForge` explicit-only `--repo` pinning for fork/non-GitHub safety.
- `README.md`: document `:Jpr local [base]`, active PR auto-detection, and mid-session `:Jpr sync` linking.
- `lua/jpr/views/cheatsheet.lua`: include `:Jpr local [base]` and update `:Jpr sync` description if listed.

- [ ] **Step 2: Verify zero em dashes and run full `just check`**

Run: `just check`
Expected: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets --all-features -- -D warnings`, `cargo test --workspace --all-features`, and `./scripts/test-lua.sh` all PASS.

- [ ] **Step 3: Commit**

```bash
git add docs/ README.md lua/jpr/views/cheatsheet.lua tests/lua/
git commit -m "docs: update protocol v8, architecture, ADR, README, and cheatsheet for 0.7.0"
```

---

## Final Branch Review

After all 9 tasks pass `just check`:
1. Run `/avandar-code-review` across the entire branch, fix every violation, verify `just check`, and commit review fixes.
2. Run full `/diff-review` (Initial mode, never walkthrough-only) to generate `.difit/` guides and walkthrough.
3. Copy `.difit/<stem>-walkthrough.md` to `docs/code-walkthroughs/2026-11-25_track2-local-worktree-review.md`, commit it, verify `just check`, and present the branch ready for human review.
