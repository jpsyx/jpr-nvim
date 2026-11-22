# jpr-nvim Milestone 5 (Polish) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task, governed by `super-wrapper`. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete Milestone 5 (`0.5.0`) of `jpr-nvim`: worktree git status and panel badges (`dirty · ↑ahead ↓behind`, `✎` locally modified files, GitHub vs local thread counts), `:Jpr push`, dirty-worktree auto-stash/fast-forward/restore on remote `headSha` moves (`headMoved` with reviewer vs agent conflict resolution), `require("jpr").statusline()`, one-shot daemon crash auto-restart with read-only fallback and plugin/engine version mismatch diagnostics, and refreshed protocol/architecture/decision/README documentation.

**Architecture:** All git status inspection, branch-safe `HEAD:<merge_ref>` pushing, `BaseCache` `(base_sha, head_sha)` invalidation, dirty-worktree stash/fast-forward/pop orchestration, and conflict-resolution prompt assembly live in the generic Rust crates (`review-model`, `review-core`, `review-workspace-git`, `review-rpc`) behind `Workspace` and `ReviewSession`. Neovim (`lua/jpr/`) remains a thin presenter and transport adapter: pure panel and statusline formatters in `lua/jpr/render/`, crash recovery and version handshake in `lua/jpr/session/`, conflict-choice UI in `lua/jpr/session/events.lua`, and bracketed-paste dispatch reuse in `lua/jpr/agent.lua`.

**Tech Stack:** Rust 2024 (`1.85+`), `serde` / `serde_json`, `anyhow`, `tempfile` (dev), `git` plumbing + porcelain (`GIT_OPTIONAL_LOCKS=0`), Neovim `0.10+` Lua (`vim.uv`, `vim.system`, `vim.ui.select`, headless `nvim -l` specs). Zero new Cargo dependencies.

**Spec Reference:** `docs/superpowers/specs/2026-11-19-jpr-nvim-design.md` ("Pull and resync", "PR tab", "Commands", "Error handling", "Delivery milestones" item 5).

---

## Execution Governance & Constraints (`AGENTS.md` + `super-wrapper`)

1. **Controller Gate (`super-wrapper`):** Before dispatching any subagent during execution, verify the active controller model is `gemini-4-neon-medium` (or obtain an explicit user override in chat if running inline or from another model). Pass `Model: "inherit"` on standard `invoke_subagent` calls; escalate final code-quality review to `Model: "pro"` on `[HIGH-RISK]` tasks (**Task 3** and **Task 4**).
2. **Worktree Isolation (`using-wt`):** All implementation happens on branch `feat/polish` created with `wt new feat polish` (**Task 0**), never on `main`.
3. **Strict Style & Quality Gates (`AGENTS.md`):**
   - **Zero em dashes** anywhere in comments, docstrings, error messages, prompts, or markdown (`! rg "\x{2014}"` must pass). Use `:` or ` - `.
   - **Function length `<= 45` lines** in both Rust and Lua; `.rs` production files well under 400 lines; one module per responsibility.
   - **Naming conventions:** `create_*` for struct/table builders, `build_*` for string/primitive builders, `*_from_*` when deriving from seed inputs, `*_to_*` for conversions, auxiliary verbs on booleans (`is_*`, `has_*`, `can_*`), and zero vague/single-letter names (`val`, `next`, `prev`, `n`).
   - **Every task ends with a green `just check`** (`cargo fmt --all --check`, `cargo clippy --workspace --all-targets --all-features -- -D warnings`, `cargo test --workspace --all-features`, and `./scripts/test-lua.sh`).

---

## File Structure Plan

| File | Action | Responsibility |
| --- | --- | --- |
| `crates/review-model/src/view.rs` | Modify | Add `WorktreeStatus`, `PushResult`, `HeadMoveOutcome`, `FileRow.{is_modified, local_threads}`, `SessionView.worktree_status`, `Event::{WorktreeStatusChanged, HeadMoved}`, and `rename_all_fields = "camelCase"` on `Event`. |
| `crates/review-model/src/agent.rs` | Modify | Add `AgentRoundKind::Conflict` for agent-driven restore-conflict resolution rounds. |
| `crates/review-model/src/lib.rs` | Modify | Re-export `HeadMoveOutcome`, `PushResult`, and `WorktreeStatus`. |
| `crates/review-core/src/ports.rs` | Modify | Add `FastForwardOutcome` and `Workspace::{head_commit, worktree_status, push_head, fast_forward_to}`. |
| `crates/review-core/src/fakes.rs` | Modify | Add `FakeForge::set_pr` so session sync tests can advance `pr.head_sha`. |
| `crates/review-core/src/fakes/workspace.rs` | Modify | Add deterministic in-memory `head_commit`, `worktree_status`, `push_head`, and `fast_forward_to` controls on `FakeWorkspace`. |
| `crates/review-core/src/presenter.rs` | Modify | Populate `SessionView.worktree_status`, `FileRow.is_modified`, and `FileRow.local_threads` in `session_view`. |
| `crates/review-core/src/agent.rs` | Modify | Add `build_conflict_prompt_from_paths` for restore-conflict resolution rounds. |
| `crates/review-workspace-git/src/lib.rs` | Modify | Register `status`, `push`, and `fast_forward` submodules. |
| `crates/review-workspace-git/src/workspace.rs` | Modify | Wire `Workspace::{head_commit, worktree_status, push_head, fast_forward_to}` on `GitWorkspace` and expose internal helpers to sibling modules. |
| `crates/review-workspace-git/src/status.rs` | Create | Unlocked git status (`--porcelain=v1 -z`) and `rev-list --left-right --count` ahead/behind calculation. |
| `crates/review-workspace-git/src/push.rs` | Create | Branch-safe `git push --porcelain <remote> HEAD:<merge_ref>` for `gh pr checkout -b pr-<n>` worktrees. |
| `crates/review-workspace-git/src/fast_forward.rs` | Create | Safe fast-forward with ancestor checks, dirty-worktree `git stash push -u` + `git merge --ff-only` + `git stash pop`, and unmerged path reporting. |
| `crates/review-core/src/session/mod.rs` | Modify | Register `push` submodule, track `last_worktree_status`, and pass live `WorktreeStatus` into `session_view`. |
| `crates/review-core/src/session/diffs.rs` | Modify | Key `BaseCache` on `(base_sha, head_sha)` so `HEAD` fast-forwards invalidate cached merge-base and base blobs. |
| `crates/review-core/src/session/push.rs` | Create | `ReviewSession::push(&mut self) -> Result<PushResult>` with dirty/zero-ahead guard and post-push `sync()`. |
| `crates/review-core/src/session/sync.rs` | Modify | Detect `head_sha` moves on `apply_pull`, run `fast_forward_to`, re-anchor local threads, refresh digests/status, and emit `Event::HeadMoved`. |
| `crates/review-core/src/session/worktree_watch.rs` | Modify | Emit `Event::WorktreeStatusChanged` when git status (`dirty`/`ahead`/`behind`) changes without disk byte changes. |
| `crates/review-core/src/session/agent_loop.rs` | Modify | Add `prepare_conflict_resolution` and `AgentRoundKind::Conflict` round confirmation. |
| `crates/review-rpc/src/protocol.rs` | Modify | Bump `PROTOCOL_VERSION` from `4` to `5`. |
| `crates/review-rpc/src/params.rs` | Modify | Accept `"conflict"` in `get_round_kind_from_params`. |
| `crates/review-rpc/src/server.rs` | Modify | Route `push` on stdio JSON-RPC. |
| `crates/review-rpc/src/server/agent.rs` | Modify | Route `prepareConflictResolution` on stdio JSON-RPC. |
| `crates/review-rpc/src/socket.rs` | Modify | Verify `push` and `prepareConflictResolution` are rejected on `JPR_SOCKET`. |
| `crates/review-rpc/tests/serve.rs` | Modify | Update protocol version assertions to `5` and test `push`, `prepareConflictResolution`, and `headMoved` / `worktreeStatusChanged` events. |
| `lua/jpr/init.lua` | Modify | Add `M.VERSION = "0.5.0"`, `"push"` subcommand, `JprModified` highlight link, and `M.statusline()`. |
| `lua/jpr/rpc.lua` | Modify | Bump `M.PROTOCOL_VERSION = 5`. |
| `lua/jpr/render/panel.lua` | Modify | Render `dirty · ↑ahead ↓behind` / `[read-only]` header prefix, `✎ ` modified file icon (`JprModified`), and GitHub vs local thread count badges (`[2 · 1L]`, `[1L]`). |
| `lua/jpr/render/statusline.lua` | Create | Pure O(1) statusline builder (`build_statusline_from_session`) with zero I/O or RPC calls. |
| `lua/jpr/session/crash.lua` | Create | Stderr crash log writer (`stdpath("state")/jpr/engine-pr-<n>.log`), one-shot auto-restart, and second-crash read-only fallback. |
| `lua/jpr/session/init.lua` | Modify | Add binary/plugin version check in `handshake`, read-only request guard, `:Jpr push` (`M.push`, `M.push_current`), and delegate mid-review exits to `jpr.session.crash`. |
| `lua/jpr/session/events.lua` | Modify | Handle `worktreeStatusChanged` and `headMoved` (including `vim.ui.select` conflict resolution prompt). |
| `lua/jpr/agent.lua` | Modify | Add `M.resolve_conflicts(session, paths)` backed by `prepareConflictResolution`. |
| `tests/lua/fixtures/fake_engine.sh` | Modify | Default `FAKE_ENGINE_PROTOCOL` to `5`, support `FAKE_ENGINE_VERSION`, `push`, and `prepareConflictResolution`. |
| `tests/lua/statusline_spec.lua` | Create | Unit tests for `jpr.render.statusline` and `require("jpr").statusline()`. |
| `tests/lua/push_and_head_moved_spec.lua` | Create | Headless Neovim tests for `:Jpr push`, `worktreeStatusChanged`, `headMoved`, and conflict resolution picker choices. |
| `tests/lua/{panel_render_spec,command_spec,rpc_spec,session_lifecycle_spec}.lua` | Modify | Cover M5 panel badges, `:Jpr push` completion/dispatch, protocol `5`, version mismatch, one-shot crash auto-restart, and second-crash read-only mode. |
| `Cargo.toml`, `docs/{protocol,architecture,decisions}.md`, `README.md` | Modify | Bump workspace version to `0.5.0` and document all M5 wire shapes, architecture, decisions, commands, and statusline setup. |

---

### Task 0: Create Isolated `feat/polish` Worktree

**Files:**
- None modified (workspace setup only)

- [ ] **Step 1: Create and enter the `feat/polish` worktree via `wt`**

Run from `/Users/pablo/src/jpsyx/jpr-nvim`:
```bash
cd "$(wt new feat polish)"
pwd
git branch --show-current
```
Expected: working directory inside the new `feat/polish` worktree, current branch `feat/polish`.

- [ ] **Step 2: Install pinned agent skills and verify clean baseline**

Run inside the `feat/polish` worktree:
```bash
just skills-install
just check
```
Expected: `just check` exits `0` with all Rust and Lua suites passing on `feat/polish`.

---

### Task 1: Domain & View-Model Polish Types (`crates/review-model`)

**Files:**
- Modify: `crates/review-model/src/view.rs`
- Modify: `crates/review-model/src/agent.rs`
- Modify: `crates/review-model/src/lib.rs`
- Modify: `crates/review-core/src/presenter.rs`
- Modify: `crates/review-core/src/session/agent_loop.rs`

- [ ] **Step 1: Write failing serialization tests in `crates/review-model/src/view.rs` and `crates/review-model/src/agent.rs`**

Add to `#[cfg(test)] mod tests` in `crates/review-model/src/view.rs`:
```rust
    #[test]
    fn worktree_status_push_result_and_head_moved_use_camel_case() {
        let mut view = create_sample_view();
        view.files[0].is_modified = true;
        view.files[0].local_threads = 1;
        view.worktree_status = WorktreeStatus {
            is_dirty: true,
            ahead: 2,
            behind: 1,
            modified_paths: vec!["a.rs".into()],
        };
        let push = serde_json::to_value(PushResult {
            is_pushed: true,
            head_sha: "abc1234".into(),
            sync_error: None,
            view: view.clone(),
        })
        .unwrap();
        assert_eq!(push["isPushed"], true);
        assert_eq!(push["headSha"], "abc1234");
        assert!(push.get("syncError").is_none());
        assert_eq!(push["view"]["worktreeStatus"]["isDirty"], true);
        assert_eq!(push["view"]["worktreeStatus"]["ahead"], 2);
        assert_eq!(push["view"]["worktreeStatus"]["behind"], 1);
        assert_eq!(push["view"]["files"][0]["isModified"], true);
        assert_eq!(push["view"]["files"][0]["localThreads"], 1);

        let status_event = serde_json::to_value(Event::WorktreeStatusChanged {
            view: Box::new(view.clone()),
        })
        .unwrap();
        assert_eq!(status_event["type"], "worktreeStatusChanged");

        let moved_event = serde_json::to_value(Event::HeadMoved {
            previous_sha: "old111".into(),
            head_sha: "new222".into(),
            outcome: HeadMoveOutcome::RestoreConflict,
            conflicted_paths: vec!["a.rs".into()],
            message: Some("stash pop conflict".into()),
            view: Box::new(view),
        })
        .unwrap();
        assert_eq!(moved_event["type"], "headMoved");
        assert_eq!(moved_event["previousSha"], "old111");
        assert_eq!(moved_event["headSha"], "new222");
        assert_eq!(moved_event["outcome"], "restoreConflict");
        assert_eq!(moved_event["conflictedPaths"], serde_json::json!(["a.rs"]));
    }
```

Add to `#[cfg(test)] mod tests` in `crates/review-model/src/agent.rs`:
```rust
    #[test]
    fn conflict_round_kind_serializes_as_conflict() {
        assert_eq!(
            serde_json::to_value(AgentRoundKind::Conflict).unwrap(),
            json!("conflict")
        );
    }
```

- [ ] **Step 2: Run `cargo test -p review-model` to confirm failure**

Run:
```bash
cargo test -p review-model
```
Expected: compile failure (`WorktreeStatus`, `PushResult`, `HeadMoveOutcome`, `AgentRoundKind::Conflict` missing).

- [ ] **Step 3: Implement the new pure data types and keep `review-core` compiling**

In `crates/review-model/src/view.rs`:
1. Add `WorktreeStatus`, `HeadMoveOutcome`, and `PushResult`:
```rust
/// Working-tree dirty and commit-divergence summary relative to the PR head.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WorktreeStatus {
    /// Whether any tracked or untracked file is modified in the worktree.
    pub is_dirty: bool,
    /// Commits on `HEAD` not reachable from the pull request's remote head commit.
    pub ahead: usize,
    /// Commits on the pull request's remote head commit not reachable from `HEAD`.
    pub behind: usize,
    /// Sorted repository-relative paths currently modified or untracked.
    pub modified_paths: Vec<String>,
}

/// How the local checkout reacted when the forge's `headSha` moved on sync.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HeadMoveOutcome {
    /// Local `HEAD` was already at the new `headSha` (for example right after `:Jpr push`).
    AlreadyAtTarget,
    /// Local `HEAD` fast-forwarded cleanly (auto-stashing and restoring dirty changes when needed).
    FastForwarded,
    /// Fast-forward succeeded, but popping the auto-stash hit conflicts; conflict markers and the stash entry remain.
    RestoreConflict,
    /// Local `HEAD` has unpushed commits ahead of the remote `headSha`; left untouched.
    AheadOfTarget,
    /// Local `HEAD` and remote `headSha` diverged; left untouched.
    Diverged,
    /// Fetching or fast-forwarding failed before changing `HEAD`.
    Failed,
}

/// Outcome returned by `:Jpr push` after pushing `HEAD` to the pull request head branch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PushResult {
    /// Always `true` when `git push` succeeded.
    pub is_pushed: bool,
    /// Commit SHA pushed from `HEAD`.
    pub head_sha: String,
    /// Non-fatal error if the post-push GitHub sync failed after `git push` succeeded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sync_error: Option<String>,
    /// Current session view after pushing (and syncing when sync succeeded).
    pub view: SessionView,
}
```
2. Extend `FileRow` with `#[serde(default)] pub is_modified: bool` and `#[serde(default)] pub local_threads: usize`, and `SessionView` with `#[serde(default)] pub worktree_status: WorktreeStatus` (updating `create_sample_view()` in `view.rs` tests with `is_modified: false, local_threads: 0` and `worktree_status: WorktreeStatus::default()`).
3. Update `Event` attributes to `#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]` and add `WorktreeStatusChanged { view: Box<SessionView> }` and `HeadMoved { previous_sha: String, head_sha: String, outcome: HeadMoveOutcome, #[serde(default)] conflicted_paths: Vec<String>, #[serde(default, skip_serializing_if = "Option::is_none")] message: Option<String>, view: Box<SessionView> }`.
4. In `crates/review-model/src/agent.rs`, add `Conflict` to `AgentRoundKind`.
5. Re-export `HeadMoveOutcome`, `PushResult`, and `WorktreeStatus` from `crates/review-model/src/lib.rs`.
6. Update `crates/review-core/src/presenter.rs` to initialize `is_modified: false`, `local_threads: 0`, and `worktree_status: review_model::WorktreeStatus::default()` temporarily (Task 2 wires real values), and update `validate_confirm_send` in `crates/review-core/src/session/agent_loop.rs` to reject non-empty `thread_ids` on `AgentRoundKind::Conflict`:
```rust
        match kind {
            AgentRoundKind::Prepass | AgentRoundKind::Conflict if !thread_ids.is_empty() => {
                bail!("{} round cannot include thread IDs", round_kind_label(kind));
            }
            AgentRoundKind::Send if thread_ids.is_empty() => {
                bail!("send round requires at least one thread ID");
            }
            AgentRoundKind::Prepass | AgentRoundKind::Conflict | AgentRoundKind::Send => Ok(()),
        }
```
with helper:
```rust
const fn round_kind_label(kind: AgentRoundKind) -> &'static str {
    match kind {
        AgentRoundKind::Send => "send",
        AgentRoundKind::Prepass => "prepass",
        AgentRoundKind::Conflict => "conflict",
    }
}
```

- [ ] **Step 4: Run `just check` and commit**

Run:
```bash
just fmt
just check
git add crates/review-model crates/review-core/src/presenter.rs crates/review-core/src/session/agent_loop.rs
git commit -m "feat(model): add worktree status, push result, and head-move event types"
```
Expected: `just check` passes with zero warnings.

---

### Task 2: Workspace Status, Push, Presenter Badges & Conflict Prompt (`crates/review-core` + `crates/review-workspace-git`)

**Files:**
- Modify: `crates/review-core/src/ports.rs`
- Modify: `crates/review-core/src/fakes.rs`
- Modify: `crates/review-core/src/fakes/workspace.rs`
- Modify: `crates/review-core/src/presenter.rs`
- Modify: `crates/review-core/src/agent.rs`
- Modify: `crates/review-core/src/session/mod.rs`
- Modify: `crates/review-workspace-git/src/lib.rs`
- Modify: `crates/review-workspace-git/src/workspace.rs`
- Create: `crates/review-workspace-git/src/status.rs`
- Create: `crates/review-workspace-git/src/push.rs`

- [ ] **Step 1: Write failing tests for presenter badges, conflict prompt, `GitWorkspace::worktree_status`, and `GitWorkspace::push_head`**

1. In `crates/review-core/src/presenter.rs` tests, update existing `session_view` calls to pass `&WorktreeStatus::default()` and add:
```rust
    #[test]
    fn marks_modified_files_and_counts_local_threads_per_file() {
        let files = [
            changed_file("a.rs", ViewedState::Viewed),
            changed_file("b.rs", ViewedState::Unviewed),
        ];
        let threads = [
            github_thread("T1", "a.rs"),
            create_local_unsent_thread("loc-1", "a.rs"),
            create_local_unsent_thread("loc-2", "b.rs"),
        ];
        let status = WorktreeStatus {
            is_dirty: true,
            ahead: 1,
            behind: 0,
            modified_paths: vec!["b.rs".into(), "untracked.rs".into()],
        };
        let view = session_view(
            Some(&sample_pr()),
            &files,
            &threads,
            &SyncState::Synced { at: 5 },
            0,
            &status,
        );
        assert_eq!(view.worktree_status, status);
        assert!(!view.files[0].is_modified);
        assert_eq!((view.files[0].threads, view.files[0].local_threads), (2, 1));
        assert!(view.files[1].is_modified);
        assert_eq!((view.files[1].threads, view.files[1].local_threads), (1, 1));
    }
```

2. In `crates/review-core/src/agent.rs` tests, add:
```rust
    #[test]
    fn conflict_prompt_lists_conflicted_paths_and_forbids_pushing() {
        let paths = vec!["src/a.rs".to_owned(), "src/b.rs".to_owned()];
        let prompt = build_conflict_prompt_from_paths(&sample_pr(), &paths);
        assert!(prompt.contains("PR #7"), "{prompt}");
        assert!(prompt.contains("src/a.rs"), "{prompt}");
        assert!(prompt.contains("src/b.rs"), "{prompt}");
        assert!(prompt.contains("Never push and never touch GitHub"), "{prompt}");
    }
```

3. In `crates/review-workspace-git/src/status.rs` (unit tests with real `repo()`), test:
   - Clean checkout at `remote_head_sha` reports `WorktreeStatus { is_dirty: false, ahead: 0, behind: 0, modified_paths: [] }`.
   - Modified tracked file + untracked file report `is_dirty: true` and sorted `modified_paths`.
   - Local commit on top of `remote_head_sha` reports `ahead: 1, behind: 0`; commit on `origin` ahead of `HEAD` reports `ahead: 0, behind: 1`.

4. In `crates/review-workspace-git/src/push.rs` (unit tests against a local bare `origin` remote), test:
   - Worktree checked out on local branch `pr-7` (matching `gh pr checkout 7 -b pr-7` where `branch.pr-7.remote = origin` and `branch.pr-7.merge = refs/heads/fix/widget`, AND also when `branch.pr-7.merge` is unset!) pushes `HEAD` to `refs/heads/fix/widget` on `origin` and returns the new `HEAD` commit SHA.
   - Invalid `head_ref` (empty, leading `-`, `..`, NUL/whitespace) is rejected before spawning `git push`.

- [ ] **Step 2: Run `cargo test -p review-core -p review-workspace-git` to verify failure**

Run:
```bash
cargo test -p review-core -p review-workspace-git
```
Expected: compile failures on missing trait methods and helpers.

- [ ] **Step 3: Implement `Workspace` methods, `FakeWorkspace`, `GitWorkspace` (`status.rs` + `push.rs`), presenter, and conflict prompt**

1. Extend `Workspace` in `crates/review-core/src/ports.rs` (importing `WorktreeStatus` from `review_model`):
```rust
    /// Current `HEAD` commit identifier of the checkout.
    fn head_commit(&self) -> Result<String>;
    /// Dirty paths and ahead/behind counts relative to `remote_head_sha` (when known).
    fn worktree_status(&self, remote_head_sha: Option<&str>) -> Result<WorktreeStatus>;
    /// Pushes `HEAD` to the pull request's remote branch `head_ref` and returns the pushed `HEAD` commit SHA.
    fn push_head(&self, head_ref: &str) -> Result<String>;
```

2. Add `pub fn set_pr(&self, pr: PullRequest)` on `FakeForge` in `crates/review-core/src/fakes.rs`.

3. Extend `FakeWorkspace` in `crates/review-core/src/fakes/workspace.rs`:
   - Default `head_commit` to `"abc123"` (matching `sample_pr().head_sha`).
   - Add test steering methods: `set_head_commit(&self, sha: &str)`, `set_worktree_status(&self, status: Option<WorktreeStatus>)`, `fail_push_with(&self, message: Option<&str>)`, and `pushed_refs(&self) -> Vec<(String, String)>` (recording `(head_ref, head_commit)` on each successful `push_head` and clearing `ahead` in `status_override` when present).
   - In `worktree_status(&self, _remote_head_sha: Option<&str>)`: return `status_override` if set; otherwise if `commits.contains_key(&head_commit)`, compute `modified_paths` by diffing `disk` vs `commits[&head_commit]` (`is_dirty = !modified_paths.is_empty()`); otherwise return `WorktreeStatus::default()`.

4. Update `session_view` in `crates/review-core/src/presenter.rs` to accept `worktree_status: &WorktreeStatus`, mark `is_modified = worktree_status.modified_paths.binary_search(&file.path).is_ok() || worktree_status.modified_paths.contains(&file.path)`, and set `local_threads` to the count of `Origin::Local` threads anchored to `file.path`. Update `ReviewSession::view(&self)` in `crates/review-core/src/session/mod.rs` to compute `let worktree_status = self.current_worktree_status();` and pass `&worktree_status`.

5. Add `build_conflict_prompt_from_paths` in `crates/review-core/src/agent.rs`:
```rust
/// Builds a prompt instructing the agent to resolve stash-restore merge conflicts
/// in `conflicted_paths` without pushing or touching GitHub.
#[must_use]
pub fn build_conflict_prompt_from_paths(pr: &PullRequest, conflicted_paths: &[String]) -> String {
    let mut output = String::new();
    let _ = writeln!(
        output,
        "PR #{} ({}/{}) fast-forwarded to `{}` and popping local uncommitted edits left merge conflicts in:",
        pr.number, pr.owner, pr.repo, pr.head_sha
    );
    for path in conflicted_paths {
        let _ = writeln!(output, "- `{path}`");
    }
    output.push_str(
        "\nResolve the conflict markers in those files while preserving both the upstream PR update and the local edits, stage the resolved files, and leave `git stash` intact if anything remains unclear. Never push and never touch GitHub.",
    );
    output
}
```

6. Create `crates/review-workspace-git/src/status.rs`:
   - `read_head_commit(dir: &Path) -> Result<String>`: runs unlocked `git rev-parse HEAD` (`run_bytes_unlocked`) and trims stdout.
   - `read_worktree_status(dir: &Path, remote_head_sha: Option<&str>) -> Result<WorktreeStatus>`:
     - Runs `run_bytes_unlocked("git", &["status", "--porcelain=v1", "-z", "--untracked-files=all"], dir)` and collects safe sorted `BTreeSet<String>` via `parse_porcelain_z_paths` + `path_to_safe_relative`.
     - Computes `(behind, ahead)` via `read_behind_ahead_counts(dir, remote_head_sha)`: if `remote_head_sha` passes `is_commit_id` and `run_bytes_unlocked("git", &["cat-file", "-e", &format!("{sha}^{{commit}}")], dir).is_ok()`, parses `run_bytes_unlocked("git", &["rev-list", "--left-right", "--count", &format!("{sha}...HEAD")], dir)` (`"<behind>\t<ahead>"`); otherwise tries `@{upstream}...HEAD`, falling back to `(0, 0)`.

7. Create `crates/review-workspace-git/src/push.rs`:
   - Validates `is_safe_branch_ref(head_ref)` (non-empty, does not start with `-` or `/`, no `..`, `@{`, `\`, control chars, NUL, or ASCII whitespace).
   - Resolves `(remote, merge_ref)` from `git symbolic-ref --quiet --short HEAD`: reads `branch.<branch>.pushRemote` -> `branch.<branch>.remote` -> `"origin"`, and `branch.<branch>.merge` -> `format!("refs/heads/{head_ref}")`.
   - Runs `run_unattended("git", &["push", "--porcelain", &remote, &format!("HEAD:{merge_ref}")], dir, timeout)` with context `"pushing HEAD to {remote} ({merge_ref})"`, then returns `read_head_commit(dir)`.

8. Wire `head_commit`, `worktree_status`, and `push_head` into `impl Workspace for GitWorkspace` in `crates/review-workspace-git/src/workspace.rs`.

- [ ] **Step 4: Run `just check` and commit**

Run:
```bash
just fmt
just check
git add crates/review-core crates/review-workspace-git
git commit -m "feat(workspace): add git worktree status, branch-safe push, and presenter badges"
```
Expected: `just check` passes with zero warnings.

---

### Task 3 `[HIGH-RISK]`: Dirty-Worktree Stash, Fast-Forward & Restore (`crates/review-workspace-git`)

> **Subagent Review Note (`super-wrapper`):** `[HIGH-RISK]` git state mutation (`git stash push -u`, `git merge --ff-only`, `git stash pop`). Escalate final task review to `Model: "pro"`.

**Files:**
- Modify: `crates/review-core/src/ports.rs`
- Modify: `crates/review-core/src/fakes/workspace.rs`
- Modify: `crates/review-workspace-git/src/lib.rs`
- Modify: `crates/review-workspace-git/src/workspace.rs`
- Create: `crates/review-workspace-git/src/fast_forward.rs`

- [ ] **Step 1: Define `FastForwardOutcome` in `ports.rs` and write failing real-git tests in `crates/review-workspace-git/src/fast_forward.rs`**

In `crates/review-core/src/ports.rs`, add:
```rust
/// Result of attempting to fast-forward the local checkout to a new PR `head_sha`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FastForwardOutcome {
    /// `HEAD` already equals `target_sha`.
    AlreadyAtTarget {
        /// Current `HEAD` commit SHA.
        head_sha: String,
    },
    /// `HEAD` fast-forwarded cleanly from `previous_sha` to `head_sha`.
    FastForwarded {
        /// `HEAD` commit SHA before fast-forwarding.
        previous_sha: String,
        /// `HEAD` commit SHA after fast-forwarding.
        head_sha: String,
    },
    /// `HEAD` fast-forwarded, but popping the auto-stash produced unmerged files.
    RestoreConflict {
        /// `HEAD` commit SHA before fast-forwarding.
        previous_sha: String,
        /// `HEAD` commit SHA after fast-forwarding.
        head_sha: String,
        /// Sorted repository-relative unmerged paths left with conflict markers.
        conflicted_paths: Vec<String>,
    },
    /// Local `HEAD` already contains `target_sha` plus local unpushed commits; left untouched.
    AheadOfTarget {
        /// Current `HEAD` commit SHA.
        head_sha: String,
        /// Remote target SHA that is an ancestor of `HEAD`.
        target_sha: String,
    },
    /// Local `HEAD` and `target_sha` diverged (neither is an ancestor of the other); left untouched.
    Diverged {
        /// Current `HEAD` commit SHA.
        head_sha: String,
        /// Divergent remote target SHA.
        target_sha: String,
    },
}
```
And add `fn fast_forward_to(&self, target_sha: &str) -> Result<FastForwardOutcome>;` to `Workspace`.

Write real-git unit tests in `crates/review-workspace-git/src/fast_forward.rs` covering all 6 scenarios against temporary `origin` + worktree repos:
1. `already_at_target_is_a_noop`
2. `clean_worktree_fast_forwards_fetching_missing_commit_from_origin`
3. `dirty_worktree_stashes_tracked_and_untracked_fast_forwards_and_restores`
4. `conflicting_stash_restore_keeps_conflict_markers_and_stash_entry_and_lists_paths`
5. `local_commits_ahead_of_target_are_never_rewound`
6. `diverged_force_pushed_target_leaves_head_and_dirty_files_untouched`

- [ ] **Step 2: Run `cargo test -p review-workspace-git` to verify failure**

Run:
```bash
cargo test -p review-workspace-git
```
Expected: compile failure (`fast_forward_to` not yet implemented).

- [ ] **Step 3: Implement `FakeWorkspace::fast_forward_to` and `GitWorkspace::fast_forward_to`**

1. In `crates/review-core/src/fakes/workspace.rs`:
   - Add `set_fast_forward_outcome(&self, outcome: Option<Result<FastForwardOutcome, String>>)` so `ReviewSession` tests in Task 4 can deterministically simulate every `FastForwardOutcome` or error; when unset, if `self.head_commit == target_sha`, return `AlreadyAtTarget { head_sha }`, else advance `self.head_commit = target_sha.to_owned()` and return `FastForwarded { previous_sha, head_sha: target_sha.to_owned() }`.

2. In `crates/review-workspace-git/src/fast_forward.rs` (keeping every helper `<= 45` lines):
   - Validate `require_commit_id(target_sha)?` and call `ensure_commit(dir, target_sha, fetch_timeout)?`.
   - Read `previous_sha = read_head_commit(dir)?`.
   - If `previous_sha == target_sha`: return `Ok(FastForwardOutcome::AlreadyAtTarget { head_sha: previous_sha })`.
   - Check `is_ancestor(dir, target_sha, &previous_sha)?` (`git merge-base --is-ancestor <ancestor> <descendant>` exit `0` -> `true`, exit `1` -> `false`, other -> error): if `target_sha` is already an ancestor of `HEAD`, return `Ok(FastForwardOutcome::AheadOfTarget { head_sha: previous_sha, target_sha: target_sha.to_owned() })`.
   - Check `is_ancestor(dir, &previous_sha, target_sha)?`: if `HEAD` is NOT an ancestor of `target_sha`, return `Ok(FastForwardOutcome::Diverged { head_sha: previous_sha, target_sha: target_sha.to_owned() })`.
   - Check if worktree has any tracked or untracked changes (`!read_status_paths(dir)?.is_empty()`):
     - If clean: run `git merge --ff-only <target_sha>` and return `FastForwarded { previous_sha, head_sha: read_head_commit(dir)? }`.
     - If dirty: record `stash_before = read_optional_ref(dir, "refs/stash")` (`git rev-parse --verify --quiet refs/stash`), run `git stash push --include-untracked -m "jpr-review auto-stash before fast-forward"`, verify `did_create_stash = read_optional_ref(dir, "refs/stash") != stash_before`.
       - Run `git merge --ff-only <target_sha>`: if this fails and `did_create_stash`, best-effort `git stash pop` before returning the error.
       - If `did_create_stash`, run `create_command("git", &["stash", "pop"], dir).output()`:
         - If `output.status.success()`: return `FastForwarded { previous_sha, head_sha }`.
         - Otherwise read unmerged paths via `run_bytes_unlocked("git", &["diff", "--name-only", "--diff-filter=U", "-z"], dir)` (falling back to `read_status_paths(dir)` if empty) and return `RestoreConflict { previous_sha, head_sha, conflicted_paths }`.

- [ ] **Step 4: Run `just check` and commit**

Run:
```bash
just fmt
just check
git add crates/review-core/src/ports.rs crates/review-core/src/fakes/workspace.rs crates/review-workspace-git
git commit -m "feat(workspace-git): add dirty-worktree stash, fast-forward, and conflict detection"
```
Expected: all 6 new real-git fast-forward tests and `just check` pass.

---

### Task 4 `[HIGH-RISK]`: Session Push, `BaseCache` HEAD Keying, `HeadMoved`, Status Watch & Conflict Dispatch (`crates/review-core`)

> **Subagent Review Note (`super-wrapper`):** `[HIGH-RISK]` core session state transitions (`BaseCache`, `push`, `sync` fast-forward + re-anchoring, `poll_worktree_files`, `prepare_conflict_resolution`). Escalate final task review to `Model: "pro"`.

**Files:**
- Modify: `crates/review-core/src/session/mod.rs`
- Modify: `crates/review-core/src/session/diffs.rs`
- Create: `crates/review-core/src/session/push.rs`
- Modify: `crates/review-core/src/session/sync.rs`
- Modify: `crates/review-core/src/session/worktree_watch.rs`
- Modify: `crates/review-core/src/session/agent_loop.rs`

- [ ] **Step 1: Write failing unit tests across `diffs.rs`, `push.rs`, `sync.rs`, `worktree_watch.rs`, and `agent_loop.rs`**

1. **`crates/review-core/src/session/diffs.rs`:**
   - `moving_head_commit_invalidates_base_cache_and_recomputes_merge_base`: call `session.file_diff("src/a.rs")`, verify `merge_base_calls() == 1`, then call `fakes.workspace.set_head_commit("def456")` and `session.file_diff("src/a.rs")`, verify `merge_base_calls() == 2`.
2. **`crates/review-core/src/session/push.rs`:**
   - `push_refuses_dirty_worktree_with_zero_commits_ahead`: set `WorktreeStatus { is_dirty: true, ahead: 0, behind: 0, modified_paths: vec!["src/a.rs".into()] }`, assert `session.push()` fails with `"commit your changes before running :Jpr push"` and `pushed_refs()` is empty.
   - `push_pushes_pr_head_ref_syncs_and_returns_push_result`: set `WorktreeStatus { is_dirty: false, ahead: 1, behind: 0, modified_paths: Vec::new() }` and `head_commit = "newhead1"`, assert `session.push()` pushes `("fix/widget", "newhead1")`, runs `sync()`, and returns `PushResult { is_pushed: true, head_sha: "newhead1", sync_error: None, .. }`.
   - `push_keeps_pushed_result_with_sync_error_when_post_push_sync_fails`: make `forge.fail_reads_with(Some("gh offline"))` after configuring `ahead: 1`, assert `session.push()` succeeds with `is_pushed: true` and `sync_error: Some("gh offline"...)`.
3. **`crates/review-core/src/session/sync.rs`:**
   - `sync_fast_forwards_when_remote_head_moves_reanchors_local_threads_and_emits_head_moved`: sync once at `"abc123"`, add a local thread on `"src/a.rs"` line 2 (`"let x = 1;"`), update `FakeForge` PR + snapshot `head_sha` to `"def456"`, update disk `"src/a.rs"` to `"// upstream header\nfn f() {}\nlet x = 1;\n"`, run `session.sync()`, assert `Event::HeadMoved` is emitted with `outcome == HeadMoveOutcome::FastForwarded`, `previous_sha == "abc123"`, `head_sha == "def456"`, and the local thread re-anchored to line 3 before `Event::Synced`.
   - `sync_emits_restore_conflict_and_diverged_outcomes_without_failing_the_pull`: verify `FastForwardOutcome::RestoreConflict` maps to `HeadMoveOutcome::RestoreConflict` with `conflicted_paths`, and `FastForwardOutcome::Diverged` maps to `HeadMoveOutcome::Diverged` with an explanatory `message`.
4. **`crates/review-core/src/session/worktree_watch.rs`:**
   - `poll_worktree_files_emits_worktree_status_changed_when_git_status_changes_without_file_edits`: baseline `poll_worktree_files()` returns `None`, then change `FakeWorkspace` `WorktreeStatus` (`is_dirty: false, ahead: 1`) without changing disk bytes; assert `poll_worktree_files()` returns `Ok(None)` and publishes `Event::WorktreeStatusChanged`.
5. **`crates/review-core/src/session/agent_loop.rs`:**
   - `prepare_conflict_resolution_builds_conflict_dispatch_and_confirm_send_records_it`: call `session.prepare_conflict_resolution(&["src/a.rs".into()], AgentKind::Claude)`, assert `dispatch.kind == AgentRoundKind::Conflict`, `dispatch.thread_ids.is_empty()`, and `session.confirm_send(dispatch.round, AgentRoundKind::Conflict, &[], &dispatch.prompt)` persists the round.

- [ ] **Step 2: Run `cargo test -p review-core` to confirm failure**

Run:
```bash
cargo test -p review-core
```
Expected: compile failures on missing `push` and `prepare_conflict_resolution` methods and failing tests.

- [ ] **Step 3: Implement the `ReviewSession` M5 methods and `BaseCache` `(base_sha, head_sha)` keying**

1. **`crates/review-core/src/session/mod.rs`:**
   - Add `mod push;` and `last_worktree_status: Option<WorktreeStatus>` on `ReviewSession` (initialized to `None` in `open`).
   - Add `pub(super) fn current_worktree_status(&self) -> WorktreeStatus`: queries `self.ports.workspace.worktree_status(self.saved.session.pr.as_ref().map(|pr| pr.head_sha.as_str()))`, falling back to `self.last_worktree_status.clone().unwrap_or_default()` on transient error.
2. **`crates/review-core/src/session/diffs.rs`:**
   - Add `head_sha: String` to `BaseCache`.
   - In `prepare_base(&mut self)`: read `let head_sha = self.ports.workspace.head_commit()?;` and require both `self.base_cache.base_sha == base_sha && self.base_cache.head_sha == head_sha` to reuse the cache.
3. **`crates/review-core/src/session/push.rs`:**
   - Implement `pub fn push(&mut self) -> Result<PushResult>`:
     - Require `let head_ref = self.synced_pr()?.head_ref.clone();`.
     - Check `let status = self.ports.workspace.worktree_status(self.saved.session.pr.as_ref().map(|pr| pr.head_sha.as_str()))?;`: if `status.ahead == 0 && status.is_dirty`, `bail!("nothing committed to push: commit your changes before running :Jpr push")`.
     - Call `let head_sha = self.ports.workspace.push_head(&head_ref)?;`.
     - Match `self.sync()`:
       - `Ok(view)` -> `Ok(PushResult { is_pushed: true, head_sha, sync_error: None, view })`
       - `Err(error)` -> refresh `let view = self.view();`, `self.last_worktree_status = Some(view.worktree_status.clone());`, return `Ok(PushResult { is_pushed: true, head_sha, sync_error: Some(format!("{error:#}")), view })`.
4. **`crates/review-core/src/session/sync.rs`:**
   - Capture `let previous_head_sha = self.saved.session.pr.as_ref().map(|existing| existing.head_sha.clone());` at the top of `apply_pull`.
   - After reconciling threads/files and saving, if `let Some(prev_sha) = previous_head_sha.filter(|prev| prev != &pr_head_sha)`: run `self.handle_head_moved(&prev_sha, &pr_head_sha)?` which calls `self.ports.workspace.fast_forward_to(&pr_head_sha)`, re-anchors local threads across changed disk digests when `HEAD` moved (`FastForwarded` or `RestoreConflict`), updates `self.disk_digests` and `self.last_worktree_status`, and publishes `Event::HeadMoved` right before `Event::Synced`.
5. **`crates/review-core/src/session/worktree_watch.rs`:**
   - Promote `collect_worktree_digests` and `reanchor_changed_local_threads` to `pub(super)` so `sync.rs` reuses them without duplicating a line.
   - Update `poll_worktree_files` to track `self.last_worktree_status`: when `changed_paths` is empty, call `self.ports.workspace.worktree_status(...)` and if `Ok(status)` differs from `self.last_worktree_status`, update `self.last_worktree_status = Some(status)` and publish `Event::WorktreeStatusChanged { view: Box::new(self.view()) }`.
6. **`crates/review-core/src/session/agent_loop.rs`:**
   - Add `pub fn prepare_conflict_resolution(&self, conflicted_paths: &[String], kind: AgentKind) -> Result<AgentDispatch>` validating non-empty safe relative paths (`validate_safe_relative_path`) and building the prompt via `build_conflict_prompt_from_paths(pr, conflicted_paths)` with `AgentRoundKind::Conflict`.

- [ ] **Step 4: Run `just check` and commit**

Run:
```bash
just fmt
just check
git add crates/review-core
git commit -m "feat(core): add session push, head-move fast-forward, status watch, and conflict dispatch"
```
Expected: all `review-core` unit tests and `just check` pass with zero warnings.

---

### Task 5: RPC Protocol v5 (`push`, `prepareConflictResolution`, Socket Allowlist Guard)

**Files:**
- Modify: `crates/review-rpc/src/protocol.rs`
- Modify: `crates/review-rpc/src/params.rs`
- Modify: `crates/review-rpc/src/server.rs`
- Modify: `crates/review-rpc/src/server/agent.rs`
- Modify: `crates/review-rpc/src/socket.rs`
- Modify: `crates/review-rpc/tests/serve.rs`
- Modify: `lua/jpr/rpc.lua`
- Modify: `tests/lua/fixtures/fake_engine.sh`
- Modify: `tests/lua/rpc_spec.lua`

- [ ] **Step 1: Write failing RPC tests in `crates/review-rpc/src/params.rs`, `crates/review-rpc/src/socket.rs`, and `crates/review-rpc/tests/serve.rs`**

1. In `crates/review-rpc/src/params.rs` (`round_kind_parses_send_and_prepass_and_rejects_unknown`), assert `get_round_kind_from_params(&json!({ "kind": "conflict" })).unwrap() == AgentRoundKind::Conflict`.
2. In `crates/review-rpc/src/socket.rs` (`allowlist_permits_only_expected_socket_methods`), add `"push"` and `"prepareConflictResolution"` to the `refused` list so an agent on `JPR_SOCKET` can never push to GitHub.
3. In `crates/review-rpc/tests/serve.rs`:
   - Update `protocolVersion` assertions from `4` to `5`.
   - Add integration tests verifying stdio `push` returns `isPushed: true` + `headSha`, and `prepareConflictResolution` + `confirmSend` (`kind: "conflict"`) round-trips cleanly.

- [ ] **Step 2: Run `cargo test -p review-rpc` to confirm failure**

Run:
```bash
cargo test -p review-rpc
```
Expected: test failures (`protocolVersion` 4 vs 5, `push` and `prepareConflictResolution` returning `-32601`).

- [ ] **Step 3: Implement RPC protocol v5 routing and keep Lua protocol version in lockstep**

1. Bump `PROTOCOL_VERSION` to `5` in `crates/review-rpc/src/protocol.rs`.
2. In `crates/review-rpc/src/params.rs`, accept `"conflict" => Ok(AgentRoundKind::Conflict)` in `get_round_kind_from_params` and update its error string to `expected "kind" to be "send", "prepass", or "conflict"`.
3. In `crates/review-rpc/src/server.rs`, add `"push" => to_value(&engine_result_to_rpc(lock(session)?.push())?),` to `handle`.
4. In `crates/review-rpc/src/server/agent.rs`, add `"prepareConflictResolution"` in `handle_prepass_and_anchor_method`:
```rust
        "prepareConflictResolution" => {
            let paths = get_string_vec_from_params(params, "paths")?;
            let kind = get_agent_kind_from_params(params)?;
            to_value(&engine_result_to_rpc(
                lock(session)?.prepare_conflict_resolution(&paths, kind),
            )?)
        }
```
5. Bump `M.PROTOCOL_VERSION = 5` in `lua/jpr/rpc.lua`, update `FAKE_ENGINE_PROTOCOL:-5` (plus `"version":"${FAKE_ENGINE_VERSION:-test}"`) in `tests/lua/fixtures/fake_engine.sh`, and update `protocolVersion == 5` in `tests/lua/rpc_spec.lua`.

- [ ] **Step 4: Run `just check` and commit**

Run:
```bash
just fmt
just check
git add crates/review-rpc lua/jpr/rpc.lua tests/lua/fixtures/fake_engine.sh tests/lua/rpc_spec.lua
git commit -m "feat(rpc): bump protocol to v5 with push and prepareConflictResolution"
```
Expected: `just check` passes across both Rust and headless Neovim specs.

---

### Task 6: Pure Lua Panel Badges, Statusline & `:Jpr push` Command Surface

**Files:**
- Modify: `lua/jpr/render/panel.lua`
- Create: `lua/jpr/render/statusline.lua`
- Modify: `lua/jpr/init.lua`
- Modify: `tests/lua/panel_render_spec.lua`
- Modify: `tests/lua/command_spec.lua`
- Create: `tests/lua/statusline_spec.lua`

- [ ] **Step 1: Write failing Lua specs for panel badges, `statusline()`, and `:Jpr push` command completion/dispatch**

1. In `tests/lua/panel_render_spec.lua`, add assertions for:
   - `worktreeStatus = { isDirty = true, ahead = 2, behind = 0 }` prepending `"dirty · ↑2 ↓0 · "` to line 2 (`build_counts_text`), `ahead = 1, behind = 2, isDirty = false` prepending `"↑1 ↓2 · "`, `isReadOnly = true` prepending `"[read-only] · "`, and clean default `worktreeStatus` keeping line 2 unchanged (`"viewed 1/3 · threads 2 · drafts 1"`) and `conversation_line == 5`.
   - File row with `isModified = true` rendering `✎ ` highlighted with `JprModified`, and `threads = 3, localThreads = 1` rendering `[2 · 1L]` while `threads = 1, localThreads = 1` renders `[1L]`.
2. Create `tests/lua/statusline_spec.lua` testing `jpr.render.statusline.build_statusline_from_session` and `require("jpr").statusline()`:
   - Returns `""` when `session` is `nil` (no PR open in the current tab).
   - Returns `"PR #7 · Loading…"` before initial sync (`view.pr == nil`).
   - Returns `"PR #7 · dirty ↑2 · 1/3 viewed · 2 drafts · 1 local"` when dirty/ahead with drafts and local unsent comments.
   - Includes `"[read-only]"` when `session.is_read_only == true` and `"sync!"` when `view.sync.state == "failed"`.
   - Never includes untrusted PR title or author text.
3. Update `tests/lua/command_spec.lua`:
   - Expect `"push"` in `jpr.complete("", "Jpr ")` (between `"submit"` and `"agent"`), assert `JprModified` highlight exists, assert `jpr.VERSION == "0.5.0"`, and assert `jpr.command({ "push" })` invokes `session.push_current`.

- [ ] **Step 2: Run `./scripts/test-lua.sh` to confirm failure**

Run:
```bash
./scripts/test-lua.sh
```
Expected: failures in `panel_render_spec.lua`, `command_spec.lua`, and missing `jpr.render.statusline`.

- [ ] **Step 3: Implement `lua/jpr/render/panel.lua`, `lua/jpr/render/statusline.lua`, and `lua/jpr/init.lua`**

1. Create `lua/jpr/render/statusline.lua` (pure, O(1), zero I/O or RPC):
```lua
-- Pure O(1) statusline formatter for an open pull-request review tab.
-- Reads in-memory session fields only: never spawns processes or makes RPC calls.
local M = {}

local function build_head_segment(status)
    if type(status) ~= "table" then
        return nil
    end
    local parts = {}
    if status.isDirty == true then
        parts[#parts + 1] = "dirty"
    end
    local ahead = type(status.ahead) == "number" and status.ahead or 0
    local behind = type(status.behind) == "number" and status.behind or 0
    if ahead > 0 then
        parts[#parts + 1] = ("\u{2191}%d"):format(ahead)
    end
    if behind > 0 then
        parts[#parts + 1] = ("\u{2193}%d"):format(behind)
    end
    return #parts > 0 and table.concat(parts, " ") or nil
end

--- Builds a concise statusline summary for `session`, or `""` when `session` is nil.
function M.build_statusline_from_session(session)
    if type(session) ~= "table" or type(session.number) ~= "number" then
        return ""
    end
    local view = type(session.view) == "table" and session.view or {}
    local segments = { ("PR #%d"):format(session.number) }
    if session.is_read_only or view.isReadOnly == true then
        segments[#segments + 1] = "[read-only]"
    end
    if type(view.pr) ~= "table" then
        segments[#segments + 1] = "Loading\u{2026}"
        return table.concat(segments, " \u{00b7} ")
    end
    local head_segment = build_head_segment(view.worktreeStatus)
    if head_segment then
        segments[#segments + 1] = head_segment
    end
    local files = type(view.files) == "table" and view.files or {}
    segments[#segments + 1] = ("%d/%d viewed"):format(view.viewedCount or 0, #files)
    if (view.draftCount or 0) > 0 then
        segments[#segments + 1] = ("%d drafts"):format(view.draftCount)
    end
    local local_unsent = type(view.localUnsentCount) == "number" and view.localUnsentCount or 0
    if local_unsent > 0 then
        segments[#segments + 1] = ("%d local"):format(local_unsent)
    end
    if type(view.sync) == "table" and view.sync.state == "failed" then
        segments[#segments + 1] = "sync!"
    end
    return table.concat(segments, " \u{00b7} ")
end

return M
```

2. Update `lua/jpr/render/panel.lua`:
   - Add `M.build_worktree_badge(view)` returning `nil` when clean and not read-only, or joining `"[read-only]"`, `"dirty"`, and `("↑%d ↓%d"):format(ahead, behind)` (when `isDirty` or `ahead > 0` or `behind > 0`) with `" · "`.
   - Prepend `badge .. " · "` in `M.build_counts_text(view)` when `M.build_worktree_badge(view)` is non-nil.
   - Add `M.build_file_threads_badge(file)` formatting `[2]`, `[2 · 1L]`, or `[1L]`.
   - In `add_file_line`, render `modified_prefix = file.isModified == true and "✎ " or ""` right before `shown_name` and add a `JprModified` highlight span over `"✎"`.

3. Update `lua/jpr/init.lua`:
   - Set `M.VERSION = "0.5.0"`.
   - Insert `"push"` into `M.subcommands` right after `"submit"`, and wire `push = session.push_current` in `M.command`.
   - Add `JprModified = "Special"` in `M.define_highlights()`.
   - Add `M.warn(message)` (`vim.notify("jpr: " .. message, vim.log.levels.WARN)`) and `M.statusline()`:
```lua
--- Short statusline summary for the current tab's review session, or `""`.
function M.statusline()
    local session_module = package.loaded["jpr.session"]
    if not session_module then
        return ""
    end
    return require("jpr.render.statusline").build_statusline_from_session(session_module.current())
end
```
(Checking `package.loaded["jpr.session"]` first means `require("jpr").statusline()` does not even load session modules in tabs before any PR is opened!)

- [ ] **Step 4: Run `just check` and commit**

Run:
```bash
just check
git add lua/jpr/init.lua lua/jpr/render/panel.lua lua/jpr/render/statusline.lua tests/lua/panel_render_spec.lua tests/lua/command_spec.lua tests/lua/statusline_spec.lua
git commit -m "feat(nvim): add panel git badges, statusline(), and :Jpr push command"
```
Expected: `just check` passes with all Lua specs green.

---

### Task 7: Lua Session Push, Crash Auto-Restart, Version Check & Conflict UI

**Files:**
- Create: `lua/jpr/session/crash.lua`
- Modify: `lua/jpr/session/init.lua`
- Modify: `lua/jpr/session/events.lua`
- Modify: `lua/jpr/agent.lua`
- Modify: `tests/lua/fixtures/fake_engine.sh`
- Modify: `tests/lua/session_lifecycle_spec.lua`
- Create: `tests/lua/push_and_head_moved_spec.lua`

- [ ] **Step 1: Write failing headless Neovim tests in `session_lifecycle_spec.lua` and `push_and_head_moved_spec.lua`**

1. Update `tests/lua/session_lifecycle_spec.lua`:
   - Add binary/plugin version mismatch test using `vim.env.FAKE_ENGINE_VERSION = "0.1.0"`: asserts handshake forgets the session, closes the startup tab, and notifies an error naming both `0.5.0` and `0.1.0` plus `./install.sh`.
   - Update the mid-review crash test (`PR #12`):
     - First `vim.fn.jobstop(died.client.job)` after `wait_for_sync(died)`: asserts stderr/crash entry is written to `<stdpath("state")>/jpr/engine-pr-12.log`, a warning notification mentions restarting, `died_tab` and `jpr://panel/12` remain valid, `died.has_restarted == true`, and a new `died.client` starts and syncs.
     - Second crash (`jpr.config.binary = crashing_engine`, then `vim.fn.jobstop(died.client.job)`): asserts `died.is_read_only == true`, `died_tab` and `jpr://panel/12` remain open with `[read-only]` rendered in the panel, an error notification names `engine-pr-12.log`, and `session.sync_current()` reports read-only mode instead of crashing.
2. Create `tests/lua/push_and_head_moved_spec.lua` testing:
   - `:Jpr push` calls RPC `push`, updates `session.view`, notifies `"pushed abc1234"`, and emits a warning notification when `syncError` is present on `PushResult`.
   - `worktreeStatusChanged` event updates `session.view` and redraws the panel (`dirty · ↑1 ↓0`).
   - `headMoved` with `outcome = "restoreConflict"` prompts `vim.ui.select` with `{ "Resolve myself", "Ask agent to resolve" }`:
     - Choosing `"Resolve myself"` opens `conflictedPaths[1]` in the main window.
     - Choosing `"Ask agent to resolve"` requests `prepareConflictResolution` with `paths = conflictedPaths` and delivers the prompt to the agent terminal.

- [ ] **Step 2: Run `./scripts/test-lua.sh` to confirm failure**

Run:
```bash
./scripts/test-lua.sh
```
Expected: `session_lifecycle_spec.lua` and `push_and_head_moved_spec.lua` fail.

- [ ] **Step 3: Implement `lua/jpr/session/crash.lua`, `session/init.lua`, `session/events.lua`, `agent.lua`, and `fake_engine.sh`**

1. Update `tests/lua/fixtures/fake_engine.sh` to handle:
   - `"method":"push"` -> replies `{"isPushed":true,"headSha":"abc1234","view":'$view_synced'}` (or includes `"syncError":"offline"` when `FAKE_ENGINE_PUSH_SYNC_ERROR` is set).
   - `"method":"prepareConflictResolution"` -> replies `{"round":1,"kind":"conflict","threadIds":[],"prompt":"Resolve conflicts in README.md","profile":'$(agent_profile "$line")'}` and `"confirmSend"` with `"kind":"conflict"`.
2. Create `lua/jpr/session/crash.lua`:
   - `M.build_log_path_from_number(number)` -> `vim.fn.stdpath("state") .. "/jpr/engine-pr-" .. tostring(number) .. ".log"`.
   - `M.append_crash_log(number, code, stderr)` -> creates parent dir via `pcall(vim.fn.mkdir, dir, "p")` and appends timestamped exit + stderr lines via `pcall(vim.fn.writefile, lines, log_path, "a")`.
   - `M.handle_unexpected_exit(session, code, stderr, callbacks)` (`callbacks = { forget = ..., spawn = ... }`):
     - If `not session.ready`: calls `callbacks.forget(session)` and `jpr().error(...)` (preserving startup failure behavior).
     - Appends to `engine-pr-<n>.log`.
     - If `not session.has_restarted`: sets `session.has_restarted = true`, warns `("the review engine for PR #%d exited (code %d); restarting once (log: %s)"):format(...)`, and calls `callbacks.spawn(session)`; if spawning fails immediately, transitions to read-only.
     - On second crash (`session.has_restarted == true`): sets `session.is_read_only = true`, sets `session.view.isReadOnly = true`, re-renders the panel so `[read-only]` is visible, and notifies `jpr().error(("the review engine for PR #%d crashed again (exit %d); session is now read-only (see %s)"):format(...))`.
3. Update `lua/jpr/session/init.lua`:
   - Extract `spawn_engine(session)` helper used by both `M.start` and `crash.handle_unexpected_exit`.
   - In `handshake(session, client)`:
     - Check `result.protocolVersion ~= rpc.PROTOCOL_VERSION` (keeping `"protocol mismatch"` wording).
     - Check `type(result.version) == "string" and result.version ~= "test" and result.version ~= jpr().VERSION`: forget (or mark read-only if `session.has_restarted`) and report `("version mismatch: plugin is %s and %s is %s; run ./install.sh from the plugin checkout"):format(jpr().VERSION, jpr().config.binary, result.version)`.
   - Guard `M.request` and `M.sync`: when `session.is_read_only`, invoke `on_error` (if given) and report `("PR #%d is in read-only mode after an engine crash; close the tab and run :Jpr open %d"):format(session.number, session.number)`.
   - Add `M.push(session)` and `M.push_current()`: calls `M.request(session, "push", nil, function(result) ... end)`, calls `M.show(session, result.view)`, notifies `jpr().info(("pushed %s"):format(tostring(result.headSha):sub(1, 7)))`, and if `type(result.syncError) == "string" and result.syncError ~= ""`, calls `jpr().warn("pushed, but GitHub resync failed: " .. result.syncError)`.
4. Update `lua/jpr/agent.lua`:
   - Add `M.resolve_conflicts(session, paths)` calling `prepareConflictResolution` (`{ paths = paths, agent = jpr().config.agent }`) and `M.deliver_dispatch(session, dispatch)`.
5. Update `lua/jpr/session/events.lua`:
   - Handle `params.type == "worktreeStatusChanged"`: update `session.view = params.view or session.view` and `panel.render(session, session.view)`.
   - Handle `params.type == "headMoved"` via helper `handle_head_moved(session, params, show_session)`:
     - Run `pcall(vim.cmd, "silent! checktime")` and `show_session(session, params.view)` when `params.view` is present.
     - For `outcome == "fastForwarded"`, notify `jpr().info(...)`.
     - For `outcome == "diverged"` or `outcome == "failed"`, notify `jpr().warn(...)`.
     - For `outcome == "restoreConflict"`, prompt via `vim.ui.select({ "Resolve myself", "Ask agent to resolve" }, { prompt = ("PR #%d fast-forwarded with conflicts in %d file(s):"):format(...) }, function(choice) ... end)`: `"Resolve myself"` opens `conflictedPaths[1]` via `main_window.edit(session, main_window.find(session), first_path)`; `"Ask agent to resolve"` calls `require("jpr.agent").resolve_conflicts(session, paths)`.

- [ ] **Step 4: Run `just check` and commit**

Run:
```bash
just check
git add lua/jpr/session lua/jpr/agent.lua tests/lua/fixtures/fake_engine.sh tests/lua/session_lifecycle_spec.lua tests/lua/push_and_head_moved_spec.lua
git commit -m "feat(nvim): add session push, crash auto-restart, version check, and conflict prompt"
```
Expected: `just check` passes with all 22 headless Neovim specs green.

---

### Task 8: Bump Version to `0.5.0` & Update Documentation (`Cargo.toml`, `docs/`, `README.md`)

**Files:**
- Modify: `Cargo.toml`
- Modify: `docs/protocol.md`
- Modify: `docs/architecture.md`
- Modify: `docs/decisions.md` (append-only at the bottom)
- Modify: `README.md`

- [ ] **Step 1: Bump workspace version to `0.5.0` in `Cargo.toml`**

Update `[workspace.package] version = "0.5.0"` in `Cargo.toml` (matching `M.VERSION = "0.5.0"` in `lua/jpr/init.lua`).

- [ ] **Step 2: Update `docs/protocol.md`, `docs/architecture.md`, `docs/decisions.md`, and `README.md`**

1. **`docs/protocol.md`:**
   - Update `protocolVersion` to `5` and `version` example to `"0.5.0"`.
   - Document `push` and `prepareConflictResolution` requests/responses, `"conflict"` in `confirmSend`, `WorktreeStatus` on `SessionView`, `isModified` and `localThreads` on `FileRow`, and `worktreeStatusChanged` + `headMoved` notifications.
   - Note that `push` and `prepareConflictResolution` are stdio-only and rejected on the Unix domain socket.
2. **`docs/architecture.md`:**
   - Update `PROTOCOL_VERSION = 5`, `review-workspace-git` module table (`status.rs`, `push.rs`, `fast_forward.rs`), `review-core` `session/push.rs` and `(base_sha, head_sha)` `BaseCache`, and Neovim `render/statusline.lua` + `session/crash.lua`.
3. **`docs/decisions.md` (append new sections at the bottom only; never edit or reorder prior sections):**
   - `## :Jpr push pushes HEAD to the PR branch refspec without auto-committing` (why `HEAD:refs/heads/<head_ref>` is required for `gh pr checkout -b pr-<n>` worktrees, why uncommitted-only trees are refused, and why post-push sync errors return `syncError` instead of failing the push).
   - `## Remote head moves auto-stash, fast-forward, and never rewrite local history` (ancestor checks keep ahead or diverged worktrees untouched; conflicting `git stash pop` preserves conflict markers and the stash entry while letting the reviewer choose self vs agent resolution; `BaseCache` now keys on `(base_sha, head_sha)`).
   - `## Mid-review engine crashes restart once and fall back to read-only mode` (why one automatic restart recovers transient panics/kills from persisted `$XDG_STATE_HOME/jpr` files while a second crash halts restart loops and preserves open buffers in `[read-only]` mode).
4. **`README.md`:**
   - Document `:Jpr push`, panel git/thread badges, `require("jpr").statusline()` (including a minimal `statusline` / `lualine` snippet), dirty-worktree resync behavior, and crash recovery logs (`stdpath("state")/jpr/engine-pr-<n>.log`).

- [ ] **Step 3: Verify zero em dashes, run `just check`, and commit**

Run:
```bash
! rg "\x{2014}" Cargo.toml crates lua plugin tests docs/protocol.md docs/architecture.md docs/decisions.md README.md
just fmt
just check
git add Cargo.toml Cargo.lock docs/protocol.md docs/architecture.md docs/decisions.md README.md
git commit -m "docs: document milestone 5 polish, protocol v5, and bump to 0.5.0"
```
Expected: zero em-dash matches (`! rg` exits `0`) and `just check` passes completely.

---

### Task 9: Mandatory Post-Implementation Review & Walkthrough Pipeline (`AGENTS.md`)

**Files:**
- Create: `docs/code-walkthroughs/2026-11-22_m5-polish.md`

- [ ] **Step 1: Run `/avandar-code-review` across the full `main..HEAD` diff**

Invoke the `avandar-code-review` skill against `main..HEAD` in the `feat/polish` worktree and fix every naming, function-length (`<= 45` lines), comment, em-dash, immutability, or test violation autonomously. Re-run `just check`.

- [ ] **Step 2: Run full `/diff-review` (Initial mode, never walkthrough-only) and persist walkthrough**

Invoke the `diff-review` skill on `main..HEAD` in Initial mode (both `diff-guide.md` and `<branch>-walkthrough.md`), then copy the walkthrough into `docs/code-walkthroughs/2026-11-22_m5-polish.md`:
```bash
mkdir -p docs/code-walkthroughs
cp .difit/*-walkthrough.md docs/code-walkthroughs/2026-11-22_m5-polish.md
! rg "\x{2014}" docs/code-walkthroughs/2026-11-22_m5-polish.md
just check
git add docs/code-walkthroughs/2026-11-22_m5-polish.md
git commit -m "docs(walkthrough): add milestone 5 polish code walkthrough"
```
Expected: `just check` passes, walkthrough committed cleanly on `feat/polish`, ready to present the final `AGENTS.md` Phase Status Checklist and await merge/PR approval.
