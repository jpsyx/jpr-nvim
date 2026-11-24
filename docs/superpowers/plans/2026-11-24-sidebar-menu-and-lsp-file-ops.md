# Track 1: Menu-Style Collapsible Sidebar, Inline LSP File Ops, and Immediate Worktree Diff Merging (`0.6.0`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade `jpr-nvim` to `0.6.0` (`PROTOCOL_VERSION = 7`) with a vertical-only collapsible sidebar menu, anchored inline `r` rename/move and `a` create with native LSP import rewrites, immediate worktree diff merging via `refreshWorktree`, and `<leader>gj` wired in personal Neovim config post-release.

**Architecture:** `crates/review-core` merges uncommitted and untracked worktree changes against `merge_base` alongside GitHub PR files into an effective file list, isolates local-only viewed marks and comments from GitHub until pushed, and exposes `refreshWorktree` (with optional rename path-migration pairs) over protocol v7 in `crates/review-rpc`. On the Neovim side, `lua/jpr/render/panel.lua` and `lua/jpr/views/panel.lua` implement vertical-only menu navigation and collapsible directories, while pure `lua/jpr/views/panel_paths.lua`, anchored floating `lua/jpr/views/panel_input.lua`, and zero-dependency `lua/jpr/lsp_files.lua` handle path resolution, live hints, LSP `willRenameFiles`/`didRenameFiles`/`willCreateFiles`/`didCreateFiles`, and immediate `refreshWorktree` redraws.

**Tech Stack:** Rust (edition 2024, `review-model`, `review-diff`, `review-core`, `review-store-fs`, `review-rpc`, `jpr-review`), Neovim Lua (0.11+, built-in `vim.lsp` and `vim.uv`), headless Lua specs (`./scripts/test-lua.sh`), `just check`.

**Spec:** `docs/superpowers/specs/2026-11-24-sidebar-menu-and-lsp-file-ops-design.md`

## Global Constraints

- Dependency rule: `crates/review-*` crates never depend on Neovim, Lua, TUI, or frontend crates (`crates/jpr-review/tests/dependency_rule.rs`).
- Lockstep version and protocol: `Cargo.toml` and `lua/jpr/init.lua` bumped to `"0.6.0"`; `PROTOCOL_VERSION` in `crates/review-rpc/src/protocol.rs` and `lua/jpr/rpc.lua` bumped to `7`.
- Zero em dashes across all code, comments, tests, docs, and commit messages.
- Every function `<= 45` lines and every source/test file `<= 400` lines; split cleanly into focused modules where needed.
- Strict Red/Green TDD for every task; `just check` passes before completion, followed by `/avandar-code-review` and full Initial-mode `/diff-review` with archived walkthrough.
- Self-contained public plugin: `lua/jpr/lsp_files.lua` uses only Neovim built-ins (`vim.lsp`, `vim.uv`, `vim.fs`), never depending on `nvim-file-operations` or `oil.nvim`.

## Review Focus

1. **Case-only rename on macOS APFS (`Foo.ts` -> `foo.ts`):** `uv.fs_stat(new_abs)` matches the same inode on case-insensitive filesystems; `lsp_files.rename` must compare `(dev, ino)` so case-only renames succeed instead of failing as "destination exists" (pinned in Task 3).
2. **Directory rename prefix boundary (`src/api` -> `src/v2/api` beside `src/api-extra/x.ts`):** Buffer renaming and Rust local thread/viewed migration must match exact path or `old_path .. "/"` prefix so sibling paths sharing a string prefix are never corrupted (pinned in Tasks 1 and 3).
3. **Renaming a directory into itself or escaping worktree root (`src/api` -> `src/api/sub`, `../../../etc/passwd`):** Must fail validation inline before any LSP request or filesystem write (pinned in Task 3).
4. **Partial LSP client failure/timeout on `workspace/willRenameFiles`:** Responses from all matching clients are collected before applying any `WorkspaceEdit`; if any client errors or times out, no edits are half-applied and `vim.ui.select` prompts whether to proceed or cancel (pinned in Task 3).
5. **Local-only file viewed -> edited -> dismissed -> re-viewed -> pushed lifecycle:** Editing a local-only file dismisses its `local_viewed` mark, `setViewed` on a local-only file never calls/queues GitHub, and syncing after push promotes `VIEWED` local marks into `queued_viewed` and sends them to GitHub (pinned in Task 1).

## File Structure Map

| Task | Files | Responsibility |
| --- | --- | --- |
| Task 1 (Rust engine + RPC v7) | `Cargo.toml`, `crates/review-model/src/view.rs`, `crates/review-core/src/ports/store.rs`, `crates/review-core/src/presenter.rs`, `crates/review-core/src/session/{mod,local_files,diffs,viewed,sync,worktree_watch,local,comments/helpers}.rs`, `crates/review-rpc/src/{protocol,params,server}.rs`, `crates/review-rpc/tests/serve.rs` | Effective worktree file merging, `FileRow.is_local_only`, `LocalStoreState.local_viewed` persistence/dismissal/promotion, origin-split comment validation, rename migration, `refreshWorktree` RPC, `0.6.0` / protocol v7 |
| Task 2 (Sidebar menu + compose lock) | `lua/jpr/init.lua`, `lua/jpr/rpc.lua`, `lua/jpr/render/panel.lua`, `lua/jpr/views/panel.lua`, `lua/jpr/comments/compose.lua`, `tests/lua/fixtures/fake_engine.sh`, `tests/lua/{panel_render,panel_view,compose,rpc,build_and_binary,session_lifecycle}_spec.lua` | Collapsible directory tree, vertical-only menu cursor locking, `h`/`l`/`o`/`<CR>`/`j`/`k`/`gg`/`G`, `[local]` badge, compose local-only lock, Lua `0.6.0` / protocol v7 |
| Task 3 (Path resolver + native LSP ops) | `lua/jpr/views/panel_paths.lua`, `lua/jpr/lsp_files.lua`, `tests/lua/panel_paths_spec.lua`, `tests/lua/lsp_files_spec.lua` | Pure path resolution & live mode hints (`same_dir`, `project_root`, `current_dir`); native LSP `willRenameFiles`/`didRenameFiles`/`willCreateFiles`/`didCreateFiles`, cold-start attach, atomic error/timeout prompt, buffer rename |
| Task 4 (Inline input UI + wiring + cheatsheet) | `lua/jpr/views/panel_input.lua`, `lua/jpr/views/panel.lua`, `lua/jpr/session/commands.lua`, `lua/jpr/views/cheatsheet.lua`, `tests/lua/panel_input_spec.lua`, `tests/lua/cheatsheet_spec.lua` | Anchored floating input under hovered row, live hints & validation errors, `r`/`a` keymaps wired to `lsp_files` + `refreshWorktree` RPC, updated `:Jpr keys` cheatsheet |
| Task 5 (Docs, reviews, walkthrough & post-merge config) | `docs/{protocol,architecture,decisions}.md`, `README.md`, `docs/code-walkthroughs/2026-11-24_sidebar-menu-lsp-ops.md`; post-merge: `jpsyx-configs` `commands.yaml`, `lua/plugins/jpr.lua`, `docs/{CHANGELOG,plugins}.md`, `lazy-lock.json` | Docs sync, `just check`, `/avandar-code-review`, full `/diff-review` + walkthrough, and post-approval `<leader>gj` + `0.6.0` install |

---

### Task 1: Rust Engine Effective Worktree Files, `local_viewed`, Origin-Split Comment Validation, and `refreshWorktree` RPC (v7 / `0.6.0`)

**Files:**
- Modify: `Cargo.toml`
- Modify: `crates/review-model/src/view.rs`
- Modify: `crates/review-core/src/ports/store.rs`
- Modify: `crates/review-core/src/presenter.rs`
- Create: `crates/review-core/src/session/local_files.rs`
- Modify: `crates/review-core/src/session/mod.rs`
- Modify: `crates/review-core/src/session/diffs.rs`
- Modify: `crates/review-core/src/session/viewed.rs`
- Modify: `crates/review-core/src/session/sync.rs`
- Modify: `crates/review-core/src/session/worktree_watch.rs`
- Modify: `crates/review-core/src/session/comments/helpers.rs`
- Modify: `crates/review-core/src/session/local.rs`
- Modify: `crates/review-core/src/session/agent_loop.rs`
- Modify: `crates/review-rpc/src/protocol.rs`
- Modify: `crates/review-rpc/src/params.rs`
- Modify: `crates/review-rpc/src/server.rs`
- Test: `crates/review-core/src/session/local_files.rs` (unit tests), `crates/review-store-fs/src/format.rs` (compat test), `crates/review-rpc/tests/serve.rs`

**Interfaces:**
- Consumes: existing `Workspace::list_changed_files_since`, `Workspace::file_at`, `Workspace::file_on_disk`, `review_diff::create_file_diff_view_with_threads`.
- Produces:
  - `FileRow::is_local_only: bool` (`isLocalOnly` in JSON, `#[serde(default)]`).
  - `LocalStoreState::local_viewed: BTreeMap<String, ViewedState>` (`localViewed` in `local.json`, backward-compatible with v1).
  - `PathRename { pub old_path: String, pub new_path: String }` in `review_core` (or `review_model`).
  - `ReviewSession::refresh_worktree(&mut self, renames: &[PathRename]) -> Result<SessionView>`.
  - `PROTOCOL_VERSION = 7` and RPC method `"refreshWorktree"` accepting `{ "renames"?: [{ "oldPath": string, "newPath": string }] }` and returning `SessionView`.

- [ ] **Step 1: Write failing Rust tests for local-only files, viewed lifecycle, origin-split comments, rename migration, and `refreshWorktree` RPC**

Add tests covering:
1. `local_worktree_files_merge_into_view_and_diffs`: adding an untracked file `"src/new.rs"` in fake workspace makes `refresh_worktree(&[])` include `"src/new.rs"` in `view.files` with `is_local_only == true` and line counts, and `file_diff("src/new.rs")` + `stream()` succeed.
2. `local_only_viewed_never_calls_forge_and_dismisses_on_disk_edit_and_promotes_on_sync`: `set_viewed("src/new.rs", true)` records `ViewedState::Viewed` in `local.local_viewed` with zero `forge.viewed_calls()`, editing `"src/new.rs"` on disk + `poll_worktree_files()` transitions it to `ViewedState::Dismissed`, re-marking `Viewed` and syncing once `"src/new.rs"` enters `ForgeSnapshot.files` promotes `("src/new.rs", true)` through `queued_viewed` to `forge.set_viewed` and removes it from `local_viewed`.
3. `origin_split_comment_validation`: `create_comment` with `Origin::Local` and `prepass_write` succeed on `"src/new.rs"`, whereas `Origin::Github`, `promote_thread`, and `suggest_from_edit` fail with `"Push this file to GitHub before adding GitHub comments"`.
4. `refresh_worktree_migrates_local_threads_and_local_viewed_with_prefix_boundary`: passing `PathRename { old_path: "src/api", new_path: "src/v2/api" }` rewrites local thread anchor `"src/api/u.rs"` -> `"src/v2/api/u.rs"` and `local_viewed["src/api/u.rs"]`, while leaving `"src/api-extra/x.rs"` untouched.
5. `local_json_v1_without_local_viewed_deserializes`: existing `local.json` v1 payload without `localViewed` loads cleanly with an empty map.
6. `serve_handles_refresh_worktree_and_reports_protocol_7` in `crates/review-rpc/tests/serve.rs`: `initialize` returns `protocolVersion: 7`, `refreshWorktree` with `renames` migrates threads and returns updated `SessionView`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p review-core -p review-store-fs -p review-rpc`
Expected: FAIL (missing `is_local_only`, `local_viewed`, `refresh_worktree`, `PROTOCOL_VERSION = 7`).

- [ ] **Step 3: Implement model, store, `review-core` local-file merging, viewed lifecycle, origin-split validation, and `refreshWorktree` RPC**

1. Bump `Cargo.toml` workspace version to `"0.6.0"`.
2. Add `#[serde(default)] pub is_local_only: bool` to `FileRow` in `crates/review-model/src/view.rs` and `#[serde(default)] pub local_viewed: BTreeMap<String, ViewedState>` to `LocalStoreState` in `crates/review-core/src/ports/store.rs`.
3. Create `crates/review-core/src/session/local_files.rs` (keeping every function `<= 45` lines):
   - Define `PathRename { pub old_path: String, pub new_path: String }` (re-exported from `review_core`).
   - Pure helper `rewrite_renamed_path(path: &str, rename: &PathRename) -> Option<String>` matching exact `path == rename.old_path` or prefix `path.strip_prefix(&format!("{}/", rename.old_path))`.
   - `ReviewSession::effective_files(&self) -> Vec<(ChangedFile, bool)>` combining `self.saved.files` (`is_local_only = false`) with `self.local_files` (`is_local_only = true`, reading viewed state from `self.saved.local.local_viewed`).
   - `ReviewSession::refresh_local_files(&mut self)` caching `(additions, deletions)` keyed by `(path, digest)` using `review_diff` against `merge_base` (skipping paths already in `self.saved.files`, handling binary/oversized safely as `0/0`).
   - `ReviewSession::refresh_worktree(&mut self, renames: &[PathRename]) -> Result<SessionView>`: validates rename paths via `validate_safe_relative_path`, migrates matching `Origin::Local` threads and `local_viewed` keys (saving `local.json` and emitting `Event::ThreadsChanged` when modified), invalidates `base_cache.renamed_from`, refreshes `local_files`, `disk_digests`, and `worktree_status`, re-anchors affected local threads, emits `Event::FilesChanged` / `Event::WorktreeStatusChanged` when changed, and returns `self.view()`.
4. Update `presenter.rs` to accept `(ChangedFile, bool)` (or `local_only_paths: &BTreeSet<&str>`) and populate `FileRow.is_local_only`.
5. Update `diffs.rs` so `file_texts` checks `effective_files` and `stream_with_progress` iterates `effective_files`.
6. Update `viewed.rs` so `set_viewed` handles local-only files in `self.saved.local.local_viewed` without calling/queueing `forge.set_viewed`, and update `worktree_watch.rs` so digest changes on local-only `Viewed` files transition them to `Dismissed` and refresh `local_files`.
7. Update `sync.rs`: before `apply_queued`, promote any path newly present in `snapshot.files` whose `local_viewed` state is `ViewedState::Viewed` into `queued_viewed` (`(path, true)`), drop adopted/stale entries from `local_viewed`, and refresh `local_files` after applying the pull.
8. Update `comments/helpers.rs`, `local.rs`, `agent_loop.rs`, and `submit.rs` to split anchor validation: `validate_local_anchor_file` allows `effective_files`, while `validate_github_anchor_file` requires `self.saved.files` and returns `"Push this file to GitHub before adding GitHub comments"` when the path is in `local_files`.
9. Bump `PROTOCOL_VERSION = 7` in `crates/review-rpc/src/protocol.rs`, add `get_renames_from_params` in `params.rs`, and wire `"refreshWorktree"` in `server.rs`.

- [ ] **Step 4: Run Rust tests and clippy to verify green**

Run: `cargo fmt --all --check && cargo clippy --workspace --all-targets --all-features -- -D warnings && cargo test --workspace --all-features`
Expected: PASS (0 warnings, all tests pass).

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml Cargo.lock crates/
git commit -m "feat(engine): merge local worktree files, add refreshWorktree RPC, and bump 0.6.0 (protocol v7)"
```

---

### Task 2: Menu-Style Collapsible Left Sidebar, Compose Local-Only Lock, and Lua `0.6.0` / Protocol v7

**Files:**
- Modify: `lua/jpr/init.lua`
- Modify: `lua/jpr/rpc.lua`
- Modify: `lua/jpr/render/panel.lua`
- Modify: `lua/jpr/views/panel.lua`
- Modify: `lua/jpr/comments/compose.lua`
- Modify: `tests/lua/fixtures/fake_engine.sh`
- Modify: `tests/lua/panel_render_spec.lua`
- Modify: `tests/lua/panel_view_spec.lua`
- Modify: `tests/lua/compose_spec.lua`
- Modify: `tests/lua/rpc_spec.lua`
- Modify: `tests/lua/build_and_binary_spec.lua`
- Modify: `tests/lua/session_lifecycle_spec.lua`

**Interfaces:**
- Consumes: `FileRow.isLocalOnly` and `PROTOCOL_VERSION = 7` from Task 1.
- Produces:
  - `render.build(view, now, opts)` returning `{ lines, highlights, paths, rows, selectable_lines, conversation_line }` where `rows[line_1based]` is `{ kind = "conversation" | "dir" | "file", path?, depth?, parent_dir?, is_collapsed? }`.
  - `panel.get_row_under_cursor(session)` returning `{ line = integer, row = table } | nil` for Task 4's inline `r`/`a` input anchor.
  - `panel.render(session, view)` preserving cursor position on the same item path (or nearest selectable row) at column `0`.

- [ ] **Step 1: Write failing Lua tests for collapsible tree rendering, `[local]` badge, menu navigation, and compose local-only lock**

Add tests in:
1. `tests/lua/panel_render_spec.lua`:
   - Expanded dir renders `▾ src/` and `rows[line] = { kind = "dir", path = "src", is_collapsed = false }`.
   - Collapsed dir (`opts = { collapsed_dirs = { ["src"] = true } }`) renders `▸ src/ (2)` and omits descendant rows from `lines`, `paths`, `rows`, and `selectable_lines`.
   - Lone-child joined dirs (`docs/x/`) carry canonical `path = "docs/x"` and `parent_dir`.
   - `isLocalOnly = true` renders `[local]` highlighted with `JprThreadLocal`.
2. `tests/lua/panel_view_spec.lua`:
   - Cursor clamps to column `0` and snaps off header lines onto `Conversation`.
   - `j`/`k`/`gg`/`G` move strictly across `selectable_lines`; horizontal keys (`w`, `$`, `0`) are no-ops.
   - `h` collapses an expanded dir; `h` on a collapsed dir or child file jumps to `parent_dir`.
   - `l` expands a collapsed dir, steps into first child on an expanded dir, and opens a file or Conversation.
   - `o` expands a collapsed dir, does nothing on an already-expanded dir, and opens a file or Conversation.
   - `<CR>` toggles directories and opens files/Conversation.
   - Cursor stays on the same file path across `M.render` redraws.
3. `tests/lua/compose_spec.lua`:
   - `compose.open_new` on a file with `isLocalOnly == true` defaults to `origin = "local"`, disables `<C-g>`/`<M-s>` flipping to `"github"`, and renders `"local only (unpushed file)"` in the footer.
4. Update `0.5.2` -> `0.6.0` and protocol `6` -> `7` expectations in `rpc_spec.lua`, `build_and_binary_spec.lua`, `session_lifecycle_spec.lua`, and `fixtures/fake_engine.sh` (adding `"refreshWorktree"` handler returning current snapshot).

- [ ] **Step 2: Run Lua tests to verify they fail**

Run: `./scripts/test-lua.sh`
Expected: FAIL on new panel render/view, compose, and version assertions.

- [ ] **Step 3: Implement collapsible panel rendering, vertical-only menu panel view, compose lock, and version bump**

1. Bump `lua/jpr/init.lua` (`M.VERSION = "0.6.0"`) and `lua/jpr/rpc.lua` (`M.PROTOCOL_VERSION = 7`).
2. Update `lua/jpr/render/panel.lua` (keeping all functions `<= 45` lines and file `<= 400` lines):
   - Build canonical directory paths and descendant file counts while walking `view.tree`.
   - Render `▾`/`▸` indicators, `(N)` collapsed counts, `[local]` badge in `JprThreadLocal`, `rows`, and `selectable_lines`.
3. Update `lua/jpr/views/panel.lua`:
   - Initialize `session.panel.collapsed_dirs = {}`, set `sidescrolloff = 0` window-local, register `CursorMoved` column-0 and selectable-row clamp, disable horizontal motions, and map `j`/`<Down>`, `k`/`<Up>`, `gg`/`<Home>`, `G`/`<End>`, `h`/`<Left>`, `l`/`<Right>`, `o`, `<CR>`, `v`, `?`.
   - Export `M.get_row_under_cursor(session)` and preserve cursor target path across `M.render`.
4. Update `lua/jpr/comments/compose.lua`:
   - Helper `is_local_only_anchor(session, anchor)` checks `session.view.files` for `isLocalOnly == true`.
   - When true, force `origin = "local"`, `allow_destination_toggle = false`, and include `"local only (unpushed file)"` in the footer.

- [ ] **Step 4: Run Lua tests to verify green**

Run: `./scripts/test-lua.sh`
Expected: PASS (all Lua specs ok).

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/init.lua lua/jpr/rpc.lua lua/jpr/render/panel.lua lua/jpr/views/panel.lua lua/jpr/comments/compose.lua tests/lua/
git commit -m "feat(panel): add collapsible menu sidebar, compose local-only lock, and bump Lua 0.6.0"
```

---

### Task 3: Pure Path Resolution (`panel_paths.lua`) and Native LSP File Operations (`lsp_files.lua`)

**Files:**
- Create: `lua/jpr/views/panel_paths.lua`
- Create: `lua/jpr/lsp_files.lua`
- Modify: `lua/jpr/init.lua` (add `lsp_file_ops_timeout_ms = 30000` and `lsp_attach_timeout_ms = 3000` defaults in `DEFAULT_CONFIG`)
- Test: `tests/lua/panel_paths_spec.lua`
- Test: `tests/lua/lsp_files_spec.lua`

**Interfaces:**
- Consumes: `jpr.views.diff.name_to_relative_path` for worktree boundary safety, `jpr.config.lsp_file_ops_timeout_ms` / `lsp_attach_timeout_ms`.
- Produces:
  - `panel_paths.resolve_input_from_context(raw_input, context)` returning `{ ok = true, relative_path = string, absolute_path = string, is_directory = boolean, mode = "same_dir" | "project_root" | "current_dir", hint = string }` or `{ ok = false, error = string, mode = string }`.
  - `panel_paths.create_rename_context_from_row(worktree, row)` returning `{ mode = "rename", worktree, current_dir, target_path, initial_text, is_directory }`.
  - `panel_paths.create_create_context_from_row(worktree, row)` returning `{ mode = "create", worktree, current_dir }`.
  - `lsp_files.rename(old_abs, new_abs, opts, on_done)` executing LSP `willRenameFiles` (with cold-start attach + atomic timeout/error `vim.ui.select` guard) -> `mkdir -p` + `fs_rename` -> open buffer rename (file & directory prefix) -> `didRenameFiles` -> `on_done(is_ok, err_or_nil)`.
  - `lsp_files.create(target_abs, is_directory, opts, on_done)` executing `willCreateFiles` -> `mkdir -p` + `fs_open` -> `didCreateFiles` -> `on_done(is_ok, err_or_nil)`.

- [ ] **Step 1: Write failing tests in `tests/lua/panel_paths_spec.lua` and `tests/lua/lsp_files_spec.lua`**

1. `tests/lua/panel_paths_spec.lua`:
   - Plain filename `"helper.ts"` in `current_dir = "src/api"` -> `mode = "same_dir"`, `relative_path = "src/api/helper.ts"`.
   - Path with slash `"some/new/path/module.ts"` -> `mode = "project_root"`, `relative_path = "some/new/path/module.ts"`, `hint` contains `"Path is relative to project root"`.
   - Path starting with `"../shared/util.ts"` from `current_dir = "src/api"` -> `mode = "current_dir"`, `relative_path = "src/shared/util.ts"`, `hint` contains `"Path is relative to current directory"`.
   - Path starting with `"./local.ts"` from `current_dir = "src/api"` -> `mode = "current_dir"`, `relative_path = "src/api/local.ts"`.
   - Create trailing slash `"src/newdir/"` -> `is_directory = true`, `relative_path = "src/newdir"`.
   - Rejects escaping worktree (`"../../../etc/passwd"`), leading `"/"`, `.git/config`, empty input, renaming a directory into itself (`"src/api"` -> `"src/api/sub"`), and no-op same path.
   - Joined lone-child dir row (`path = "docs/x"`) produces `current_dir = "docs"`, `initial_text = "x"`.
2. `tests/lua/lsp_files_spec.lua` (using real temp directories + stubbed `vim.lsp.get_clients` / `vim.ui.select`):
   - File rename sends `workspace/willRenameFiles`, applies `WorkspaceEdit` to a second file and autosaves clean edited buffers, moves file across new intermediate dirs, updates open buffer name, and sends `workspace/didRenameFiles`.
   - Case-only rename (`Foo.ts` -> `foo.ts`) succeeds on APFS via `(dev, ino)` equality check.
   - Directory rename (`src/api` -> `src/v2/api`) updates open buffers under `src/api/` while leaving `src/api-extra/other.ts` untouched.
   - LSP timeout/error on one of two matching clients does NOT half-apply the first client's edits; warns and prompts via `vim.ui.select`; cancelling leaves disk and buffers untouched, while confirming proceeds cleanly.
   - Create file creates intermediate directories, creates empty file, invokes `willCreateFiles`/`didCreateFiles`; create directory creates dir cleanly; existing target is refused.

- [ ] **Step 2: Run tests to verify they fail**

Run: `nvim --headless -u NONE -l tests/lua/panel_paths_spec.lua && nvim --headless -u NONE -l tests/lua/lsp_files_spec.lua`
Expected: FAIL (modules not found).

- [ ] **Step 3: Implement `lua/jpr/views/panel_paths.lua`, `lua/jpr/lsp_files.lua`, and timeout config defaults in `lua/jpr/init.lua`**

- Keep every function `<= 45` lines and every file `<= 400` lines (split `lua/jpr/lsp_files/` into `init.lua` + `buffers.lua` or `clients.lua` if approaching 300 lines).
- In `lsp_files.rename`:
  - Check `(dev, ino)` equality for case-only APFS renames; reject real collisions and moving a directory inside itself (`new_abs:sub(1, #old_abs + 1) == old_abs .. "/"`).
  - Match LSP clients by `workspace.fileOperations.willRename` capability (and glob `filters` when declared).
  - Cold-start attach for regular files when zero matching clients are attached (load hidden buffer, `vim.wait(attach_timeout_ms, ...)`, clean up temp buffer).
  - Collect all `request_sync` responses before applying any `WorkspaceEdit`; on any error/timeout, prompt with `vim.ui.select`.
  - Autosave buffers modified by `WorkspaceEdit` that were unmodified before the edit; warn if a pre-dirty buffer was also edited by LSP.
  - Perform `mkdir -p` + `vim.uv.fs_rename`, update open buffers (exact file or `old_abs .. "/"` prefix), send `workspace/didRenameFiles`, invoke `on_done`.

- [ ] **Step 4: Run Lua tests to verify green**

Run: `./scripts/test-lua.sh`
Expected: PASS (all Lua specs including `panel_paths_spec` and `lsp_files_spec`).

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/init.lua lua/jpr/views/panel_paths.lua lua/jpr/lsp_files.lua tests/lua/panel_paths_spec.lua tests/lua/lsp_files_spec.lua
git commit -m "feat(fs): add sidebar path resolver and native LSP rename/create operations"
```

---

### Task 4: Inline Anchored Rename (`r`) & Create (`a`) Input UI, `refreshWorktree` Wiring, and Cheatsheet Updates

**Files:**
- Create: `lua/jpr/views/panel_input.lua`
- Modify: `lua/jpr/views/panel.lua`
- Modify: `lua/jpr/session/commands.lua`
- Modify: `lua/jpr/views/cheatsheet.lua`
- Test: `tests/lua/panel_input_spec.lua`
- Modify: `tests/lua/cheatsheet_spec.lua`

**Interfaces:**
- Consumes: `panel.get_row_under_cursor` (Task 2), `panel_paths` and `lsp_files` (Task 3), `refreshWorktree` RPC (Task 1).
- Produces:
  - `panel_input.open(session, context, on_confirm)` rendering a rounded floating input anchored below the hovered row in `panel.win` (flipping above when at bottom), updating live path-resolution hints and inline errors on `TextChangedI` / `TextChanged`.
  - `session_mod.refresh_worktree(session, renames, on_done)` sending `refreshWorktree` RPC and redrawing panel/diffs/stream cleanly.
  - Normal-mode `r` and `a` bindings in `lua/jpr/views/panel.lua` + updated shortcuts in `lua/jpr/views/cheatsheet.lua`.

- [ ] **Step 1: Write failing tests in `tests/lua/panel_input_spec.lua` and `tests/lua/cheatsheet_spec.lua`**

1. `tests/lua/panel_input_spec.lua`:
   - Pressing `r` on a file row opens `jpr-panel-input` float anchored directly below the row (`relative == "win"`, `win == panel.win`), prefilled with basename.
   - Pressing `r` on `Conversation` is a no-op (does not open float).
   - Typing `"some/new/module.ts"` updates virtual hint line immediately to include `"Path is relative to project root"`.
   - Typing `"../sibling.ts"` updates virtual hint line immediately to include `"Path is relative to current directory"`.
   - Submitting invalid escaping path (`"../../escape.ts"`) keeps the float open and renders an inline `JprError` virtual line.
   - Submitting valid rename runs `lsp_files.rename` and sends `refreshWorktree` RPC with `{ renames = { { oldPath = ..., newPath = ... } } }`, updating the sidebar with the new path.
   - Pressing `a` and submitting `"src/nested/fresh.ts"` creates the file with intermediate dirs, sends `refreshWorktree` RPC (`{}`), and opens the new file in `main_window`.
   - Pressing `a` with `"src/empty_dir/"` creates the directory and notifies cleanly.
   - Pressing `<Esc>` / `q` cancels and closes the float cleanly without touching disk.
2. `tests/lua/cheatsheet_spec.lua`:
   - PR Sidebar Panel section lists `h`/`<Left>`, `l`/`<Right>`, `o`/`<CR>`, `r`, `a`, `v`, `?`.

- [ ] **Step 2: Run Lua tests to verify they fail**

Run: `./scripts/test-lua.sh`
Expected: FAIL (`panel_input` missing, `cheatsheet_spec` missing new sidebar keys).

- [ ] **Step 3: Implement `lua/jpr/views/panel_input.lua`, wire `r`/`a` and `refresh_worktree`, and update `cheatsheet.lua`**

1. Create `lua/jpr/views/panel_input.lua` (reusing the same rounded border + virtual-lines pattern as `lua/jpr/tui/wizard/step_text.lua`):
   - Compute anchor row relative to `panel.win` (`cursor_line - topline + 1`, flipping above to `cursor_line - topline - 1` if at bottom of window).
   - Paint live virtual lines via `jpr-panel-input` extmark namespace on `TextChangedI` and `TextChanged` using `panel_paths.resolve_input_from_context`.
   - Bind `<CR>` (Insert & Normal) to validate and invoke `on_confirm(resolved)`, `q` / `<Esc>` (Normal) to close cleanly, and register `BufLeave`/`WinClosed` cleanup guards.
2. Add `session_mod.refresh_worktree(session, renames, on_done)` in `lua/jpr/session/commands.lua`.
3. In `lua/jpr/views/panel.lua`: bind `r` and `a` (guarding against `session.is_read_only` via `report_read_only`) to open `panel_input`, run `lsp_files.rename` / `lsp_files.create`, call `refresh_worktree`, and open newly created files in `main_window`.
4. Update `lua/jpr/views/cheatsheet.lua` PR Sidebar Panel entries (`j`/`k`, `h`/`<Left>`, `l`/`<Right>`, `<CR>`/`o`, `r`, `a`, `v`, `?`).

- [ ] **Step 4: Run full workspace verification (`just check`)**

Run: `just check`
Expected: PASS (fmt, clippy, all Rust tests, all Lua specs green).

- [ ] **Step 5: Commit**

```bash
git add lua/jpr/views/panel_input.lua lua/jpr/views/panel.lua lua/jpr/session/commands.lua lua/jpr/views/cheatsheet.lua tests/lua/panel_input_spec.lua tests/lua/cheatsheet_spec.lua
git commit -m "feat(panel): wire inline rename/create input box, refreshWorktree, and cheatsheet keys"
```

---

### Task 5: Documentation, `/avandar-code-review`, Full `/diff-review` + Walkthrough, and Post-Approval `jpsyx-configs` `<leader>gj` Wiring

**Files:**
- Modify: `docs/protocol.md`
- Modify: `docs/architecture.md`
- Modify: `docs/decisions.md`
- Modify: `README.md`
- Create: `docs/code-walkthroughs/2026-11-24_sidebar-menu-lsp-ops.md`
- Post-merge/push (after Pablo approves merging & pushing `jpr-nvim` `0.6.0`):
  - Modify in `jpsyx-configs`: `home/.config/nvim/commands.yaml`, `home/.config/nvim/lua/plugins/jpr.lua`, `home/.config/nvim/docs/CHANGELOG.md`, `home/.config/nvim/docs/plugins.md`, `home/.config/nvim/lazy-lock.json` (captured via `:Lazy! update jpr-nvim` + `jpsyx sync`).

- [ ] **Step 1: Update `jpr-nvim` documentation for `0.6.0` / protocol v7**
  - `docs/protocol.md`: bump to Version 7 (`0.6.0`), document `refreshWorktree` request/response and `FileRow.isLocalOnly`, add Version 7 bullet.
  - `docs/architecture.md`: update `PROTOCOL_VERSION = 7`, document `session/local_files.rs`, `local_viewed` in `local.json`, `lua/jpr/views/panel_paths.lua`, `lua/jpr/views/panel_input.lua`, `lua/jpr/lsp_files.lua`, and menu-style collapsible sidebar behavior.
  - `docs/decisions.md`: add concise ADR covering self-contained native LSP `willRenameFiles` + atomic error/timeout prompt, effective worktree file merging with origin-split comment guards, and `local_viewed` promotion on sync.
  - `README.md`: document sidebar menu navigation (`h`/`l`/`o`), inline `r` rename/move and `a` create with path rules and LSP import updates.
  - Run `just check` and commit: `git commit -m "docs: update protocol v7, architecture, ADR, and README for 0.6.0"`.

- [ ] **Step 2: Run `/avandar-code-review` across the branch**
  - Fix every violation surfaced (`<= 45` lines/fn, `<= 400` lines/file, zero em dashes, naming, docstrings, immutability/purity), re-run `just check`, and commit review fixes.

- [ ] **Step 3: Run full Initial-mode `/diff-review` and archive walkthrough**
  - Produce full `.difit/` review artifacts + walkthrough, copy to `docs/code-walkthroughs/2026-11-24_sidebar-menu-lsp-ops.md`, verify zero em dashes and `just check` green, and commit the walkthrough.

- [ ] **Step 4: Present `AGENTS.md` readiness gate and await Pablo's approval to merge & push `0.6.0`**

- [ ] **Step 5 (Post-approval): Wire `<leader>gj` and install `0.6.0` in `jpsyx-configs`**
  - Update `commands.yaml` (`<leader>gj` on `jpr-nvim-jpr`, updated `jpr-panel` and `jpr-panel-input` entries), `lua/plugins/jpr.lua` (`keys` triggering `:Jpr` via `catalog`), `docs/CHANGELOG.md`, `docs/plugins.md`.
  - Run `nvim --headless "+Lazy! update jpr-nvim" +qa`, `jpsyx sync`, verify `:checkhealth jpr` (`0.6.0`), `:CommandPaletteAudit`, `jpsyx status`, `jpsyx doctor`, commit & push `jpsyx-configs`, and run `jpsyx update`.
