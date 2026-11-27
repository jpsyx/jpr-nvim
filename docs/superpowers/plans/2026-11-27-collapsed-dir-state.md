# Persisted Sidebar Directory Collapse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remember which sidebar directories are collapsed across a restarted review, and expand a collapsed directory on a GitHub pull only when a file under it newly needs review.

**Architecture:** `local.json` stores `collapsedDirs`. Every `SessionView` carries that set. `setCollapsed` updates one path. A successful pull runs a pure function that drops collapsed ancestors of files whose reconciled viewed state became `UNVIEWED` or `DISMISSED` because the forge snapshot says so, then prunes paths that no longer contain a file. The sidebar reads the set from the view and sends a toggle only when the collapsed bit changes.

**Tech Stack:** Rust (edition 2024, `serde`, `anyhow`), Lua (Neovim API), headless Neovim Lua specs (`./scripts/test-lua.sh`), `just check`.

**Spec:** `docs/superpowers/specs/2026-11-27-collapsed-dir-state-design.md`

## Global Constraints

- Generic crates under `crates/review-*` stay free of Neovim, Lua, and TUI dependencies.
- `local.json` stays version 1. `collapsedDirs` defaults to empty so older files still load.
- `PROTOCOL_VERSION` becomes 11 in `crates/review-rpc/src/protocol.rs`, `lua/jpr/rpc.lua`, the fake engine default, `docs/protocol.md`, and `docs/architecture.md`.
- `setCollapsed` is stdio-only. The Unix socket refuses it with `-32600`, the same way it refuses `setViewed`.
- No em dashes in comments, docs, or user-facing copy.
- New functions stay at or under 45 lines.
- Write a failing test before the implementation that makes it pass.

## Review Focus

1. **A later pull where GitHub still says `UNVIEWED` and the saved state was already `UNVIEWED`:** the collapsed parent stays collapsed. Expanding every unviewed file on each sync would undo the feature. (Pinned in Task 4.)
2. **A queued viewed mark overlaying a lagging GitHub `UNVIEWED`, and a queued unviewed mark overlaying GitHub `VIEWED`:** neither expands. The reviewer's own mark and a mark GitHub has not caught up to are not a GitHub change. (Pinned in Task 4.)
3. **Prefix boundary and joined directories:** collapsed `src` does not match `src2/a.rs`; collapsed `docs/x` does match `docs/x/y.md`. Use `is_path_in_directory`. (Pinned in Task 4.)
4. **A collapsed directory that still contains only a local-only file stays; a path that contains no current file is dropped; a failed pull and `set_viewed` leave the set unchanged.** (Pinned in Tasks 3 and 4.)
5. **The sidebar draws `view.collapsedDirs`, not a stale in-memory set.** A failed `setCollapsed` does not flip the tree. A `synced` view that drops a parent expands it, including after `gp` closed the sidebar. `h` on a file, and `o` or `l` on an already expanded directory, send no request. (Pinned in Task 7.)

---

### Task 1: Persist `collapsedDirs` on `local.json`

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `crates/review-core/src/ports/store.rs`
- Modify: `crates/review-core/src/contract.rs`
- Modify: `crates/review-store-fs/src/format/tests.rs`
- Test: `crates/review-store-fs/src/format/tests.rs`

**Interfaces:**
- Consumes: `LocalStoreState` (`#[serde(rename_all = "camelCase", default)]`).
- Produces: `LocalStoreState.collapsed_dirs: BTreeSet<String>` (`#[serde(default)]`, JSON `collapsedDirs`). Missing on decode means an empty set. `encode_local` / `decode_local` keep `LOCAL_VERSION` at 1.

- [ ] **Step 1: Write the failing round-trip and legacy tests**

In `crates/review-store-fs/src/format/tests.rs`:

- Extend `the_local_file_round_trips_v1_and_refuses_version_9` so the sample `LocalStoreState` includes `collapsed_dirs: BTreeSet::from(["src/core".to_owned()])`, and assert `encoded_json["collapsedDirs"] == json!(["src/core"])` and `decode_local` equals that value.
- Extend `local_json_v1_without_local_viewed_deserializes` to assert `decoded.collapsed_dirs.is_empty()` for a v1 object that also omits `collapsedDirs`.

- [ ] **Step 2: Run the store tests to verify they fail**

Run: `cargo test -p review-store-fs --lib format::tests`
Expected: FAIL to compile (`collapsed_dirs` is not a field).

- [ ] **Step 3: Add `collapsed_dirs` and fix struct literals**

- Add `pub collapsed_dirs: BTreeSet<String>` with `#[serde(default)]` and a doc comment to `LocalStoreState`.
- Add `collapsed_dirs: BTreeSet::new()` to both `LocalStoreState` literals in `crates/review-core/src/contract.rs`.
- Do not bump `LOCAL_VERSION`.

- [ ] **Step 4: Run the store tests**

Run: `cargo test -p review-store-fs --lib format::tests && cargo test -p review-core --lib contract`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/review-core/src/ports/store.rs crates/review-core/src/contract.rs crates/review-store-fs/src/format/tests.rs
git commit -m "feat(store): persist collapsed sidebar directories in local state"
```

---

### Task 2: Carry `collapsedDirs` on `SessionView`

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `crates/review-model/src/view/mod.rs`
- Modify: `crates/review-model/src/view/tests.rs`
- Modify: `crates/review-core/src/presenter.rs`
- Modify: `crates/review-core/src/session/mod.rs`
- Test: `crates/review-model/src/view/tests.rs`
- Test: `crates/review-core/src/presenter.rs`

**Interfaces:**
- Consumes: `LocalStoreState.collapsed_dirs` from Task 1.
- Produces:
  - `SessionView.collapsed_dirs: BTreeSet<String>` with `#[serde(default, skip_serializing_if = "BTreeSet::is_empty")]`.
  - `session_view(..., collapsed_dirs: &BTreeSet<String>, ...) -> SessionView` copies that set onto the view.
  - `ReviewSession::view_with_status` passes `&self.saved.local.collapsed_dirs`.

- [ ] **Step 1: Write the failing view tests**

- In `crates/review-model/src/view/tests.rs`, add `session_view_omits_empty_collapsed_dirs_and_serializes_a_sorted_set`: a `SessionView` with an empty set serializes without a `collapsedDirs` key; deserializing that JSON yields an empty set; a set of `"src"` and `"docs/x"` serializes as `["docs/x", "src"]`.
- Add `collapsed_dirs: BTreeSet::new()` to `create_sample_view`.
- In `crates/review-core/src/presenter.rs` tests, add `session_view_copies_collapsed_dirs` asserting the passed set `{"src"}` is `view.collapsed_dirs`.

- [ ] **Step 2: Run the view tests to verify they fail**

Run: `cargo test -p review-model -p review-core session_view_omits_empty_collapsed_dirs_and_serializes_a_sorted_set session_view_copies_collapsed_dirs`
Expected: FAIL to compile (missing field or argument).

- [ ] **Step 3: Thread the set through `session_view`**

- Add the field to `SessionView`. An empty set is omitted on the wire.
- Add the `collapsed_dirs` argument to `session_view` and pass `&self.saved.local.collapsed_dirs` from `view_with_status`.
- Update the existing `session_view(...)` calls in `presenter.rs` tests to pass `&BTreeSet::new()` except the new test.

- [ ] **Step 4: Run the Rust tests that construct views**

Run: `cargo test -p review-model -p review-core`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/review-model/src/view crates/review-core/src/presenter.rs crates/review-core/src/session/mod.rs
git commit -m "feat(view): include collapsed directories on the session view"
```

---

### Task 3: Add `ReviewSession::set_collapsed`

help-me-pick: implement L2 (hours=1 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Create: `crates/review-core/src/session/collapsed.rs`
- Modify: `crates/review-core/src/session/mod.rs`
- Test: `crates/review-core/src/session/collapsed.rs`

**Interfaces:**
- Consumes: `validate_safe_relative_path` (`crates/review-core/src/reanchor.rs`), `LocalStoreState.collapsed_dirs`, `MemoryStore::fail_saves_with`, `Fakes::open_synced`.
- Produces: `ReviewSession::set_collapsed(&mut self, path: &str, collapsed: bool) -> Result<SessionView>`.

- [ ] **Step 1: Write the failing session tests**

In `crates/review-core/src/session/collapsed.rs` under `#[cfg(test)]`:

- `set_collapsed_persists_and_round_trips_on_the_view`: `open_synced()`, `set_collapsed("src/core", true)` returns a view whose `collapsed_dirs` is `{"src/core"}`, and `fakes.store.saved().local.collapsed_dirs` matches. `set_collapsed("src/core", false)` leaves the set empty in both the view and the saved snapshot.
- `set_collapsed_same_value_leaves_the_set_unchanged`: after inserting `"src"`, calling `set_collapsed("src", true)` again returns `Ok` and the set is still `{"src"}`.
- `set_collapsed_rejects_an_unsafe_path_without_changing_the_set`: `set_collapsed("../src", true)` and `set_collapsed("src//core", true)` are `Err`, and `saved().local.collapsed_dirs` stays empty. (Review Focus #4, the save-rollback half is the next test.)
- `set_collapsed_restores_the_set_when_the_save_fails`: insert nothing, `fail_saves_with(Some("disk full"))`, `set_collapsed("src", true)` is `Err` containing `disk full`, `session.view().collapsed_dirs` is empty, and `saved().local.collapsed_dirs` is empty.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p review-core --lib session::collapsed`
Expected: FAIL to compile (`set_collapsed` is not a method).

- [ ] **Step 3: Implement `set_collapsed`**

- `mod collapsed;` in `crates/review-core/src/session/mod.rs`.
- Validate `path` with `validate_safe_relative_path` before mutating. On failure, return that error and leave the set untouched.
- `collapsed == true` inserts `path`. `collapsed == false` removes it.
- When membership is already correct, return `self.view()` and do not save.
- Otherwise clone the previous set, mutate, `store.save(&self.saved)`, and on save error write the previous set back before returning the error.
- Return `self.view()` on success. Do not publish an event. Do not call the forge. Do not expand or prune other paths.

- [ ] **Step 4: Run the session tests**

Run: `cargo test -p review-core --lib session::collapsed`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/review-core/src/session/collapsed.rs crates/review-core/src/session/mod.rs
git commit -m "feat(session): save one collapsed directory at a time"
```

---

### Task 4: Expand and prune collapsed directories on a GitHub pull

help-me-pick: implement L3 (hours=1.5 cause=known material=familiar stakes=high verified=yes)

**Files:**
- Create: `crates/review-core/src/collapsed.rs`
- Modify: `crates/review-core/src/lib.rs`
- Modify: `crates/review-core/src/session/sync.rs`
- Test: `crates/review-core/src/collapsed.rs`
- Test: `crates/review-core/src/session/sync/tests.rs`
- Test: `crates/review-core/src/session/collapsed.rs`

**Interfaces:**
- Consumes: `is_path_in_directory(path, dir) -> bool` from `crates/review-core/src/viewed.rs`, `set_collapsed` from Task 3, `apply_queued` in `reconcile_viewed_and_local_files`.
- Produces: `create_collapsed_dirs_after_pull(collapsed: &BTreeSet<String>, previous: &BTreeMap<String, ViewedState>, forge: &BTreeMap<String, ViewedState>, reconciled: &[ChangedFile], local_only_paths: &[String]) -> BTreeSet<String>`.

- [ ] **Step 1: Write the failing pure-function tests and the session wiring tests**

In `crates/review-core/src/collapsed.rs`:

- `unchanged_unviewed_file_keeps_its_collapsed_parent`: previous `src/a.rs = UNVIEWED`, forge `UNVIEWED`, reconciled `UNVIEWED`, collapsed `{"src", "lib"}`. Result stays `{"src", "lib"}`. (Review Focus #1.)
- `viewed_to_dismissed_expands_only_matching_ancestors`: previous `src/a.rs = VIEWED`, forge `DISMISSED`, reconciled `DISMISSED`, collapsed `{"src", "lib"}`. Result is `{"lib"}`.
- `new_unviewed_file_expands_its_ancestors`: previous has no `src/b.rs`, forge and reconciled are `UNVIEWED`, collapsed `{"src"}`. Result is empty.
- `queued_viewed_overlay_does_not_expand`: previous `src/a.rs = VIEWED`, forge `UNVIEWED`, reconciled `VIEWED`, collapsed `{"src"}`. Result stays `{"src"}`. (Review Focus #2.)
- `queued_unviewed_overlay_does_not_expand`: previous `src/a.rs = VIEWED`, forge `VIEWED`, reconciled `UNVIEWED`, collapsed `{"src"}`. Result stays `{"src"}`. (Review Focus #2.)
- `prefix_boundary_and_joined_directory`: collapsed `{"src", "src2", "docs/x"}`. Reconciled new `UNVIEWED` files `src2/a.rs` and `docs/x/y.md`, forge matches those states. Result is `{"src"}`. `src` does not match `src2/a.rs`. `docs/x` is removed. (Review Focus #3.)
- `local_only_file_keeps_a_collapsed_directory_and_an_empty_path_is_pruned`: collapsed `{"notes", "gone"}`, reconciled files empty, `local_only_paths` is `["notes/todo.rs"]`. Result is `{"notes"}`. (Review Focus #4.)

In `crates/review-core/src/session/sync/tests.rs`:

- `sync_expands_a_collapsed_parent_when_github_dismisses_a_viewed_file`: `open_synced()` (forge starts as `src/a.rs` `VIEWED`, `src/b.rs` `UNVIEWED`), `set_collapsed("src", true)`, `set_collapsed("lib", true)`. Replace the forge snapshot with the same two paths except `src/a.rs` is `DISMISSED`. `sync()` succeeds. `view.collapsed_dirs` and `saved().local.collapsed_dirs` are `{"lib"}`.
- `a_failed_sync_keeps_collapsed_directories`: after `set_collapsed("src", true)`, `forge.fail_with(Some("gh timed out after 30s"))`, `sync()` is `Err`, and `view().collapsed_dirs` is still `{"src"}`. (Review Focus #4.)

In `crates/review-core/src/session/collapsed.rs`:

- `set_viewed_does_not_expand_a_collapsed_directory`: `set_collapsed("src", true)`, then `set_viewed("src/a.rs", false)`. `view().collapsed_dirs` is still `{"src"}`. (Review Focus #4.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p review-core --lib unchanged_unviewed_file_keeps_its_collapsed_parent sync_expands_a_collapsed_parent_when_github_dismisses_a_viewed_file`
Expected: FAIL to compile (`create_collapsed_dirs_after_pull` is missing, and the sync test cannot call it). `set_viewed_does_not_expand_a_collapsed_directory` calls only `set_collapsed` and `set_viewed`, so it passes as soon as it compiles. Keep it. It locks Review Focus #4 without a change to `set_viewed`.

- [ ] **Step 3: Implement the pure function and call it from the pull**

Add `mod collapsed;` to `crates/review-core/src/lib.rs`. `sync.rs` calls `crate::collapsed::create_collapsed_dirs_after_pull`. Keep the module private.

Algorithm, in this order:

- A reconciled file triggers when its viewed state is `UNVIEWED` or `DISMISSED`, `forge` has that same path at `UNVIEWED` or `DISMISSED`, and `previous.get(path) != Some(reconciled.viewed)`.
- Start from a clone of `collapsed`. Remove `P` when any triggering file satisfies `is_path_in_directory(file, P)`.
- Then keep `P` only when some reconciled path or some `local_only_paths` entry satisfies `is_path_in_directory`.

In `reconcile_viewed_and_local_files`, copy `previous` from `self.saved.files` and `forge` from `incoming_files` before `apply_queued` mutates those files. After local files are refreshed, assign `self.saved.local.collapsed_dirs` from the pure function. `local_only_paths` are `self.local_files` paths. Do not call this from `set_viewed`, `refresh_worktree`, or `fail_sync`.

- [ ] **Step 4: Run the collapse and sync tests**

Run: `cargo test -p review-core --lib collapsed session::sync session::collapsed`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/review-core/src/collapsed.rs crates/review-core/src/lib.rs crates/review-core/src/session/sync.rs crates/review-core/src/session/sync/tests.rs crates/review-core/src/session/collapsed.rs
git commit -m "feat(sync): expand collapsed directories when GitHub marks a file for review"
```

---

### Task 5: Rewrite collapsed paths on rename and union them when linking a PR

help-me-pick: implement L2 (hours=1 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `crates/review-core/src/session/local_files.rs`
- Modify: `crates/review-core/src/session/link.rs`
- Test: `crates/review-core/src/session/local_files/tests.rs`
- Test: `crates/review-core/src/session/link_tests.rs`

**Interfaces:**
- Consumes: `rewrite_renamed_path` / `apply_renames_to_path` in `local_files.rs`, `set_collapsed` from Task 3, `merge_preexisting_pr_snapshot`, `MemoryStore::set_retarget_snapshot`.
- Produces: `migrate_renames` returns `(did_migrate_threads, did_migrate_viewed, did_migrate_collapsed)`, all `bool`, and rewrites `saved.local.collapsed_dirs`. `merge_preexisting_pr_snapshot` unions `prior.local.collapsed_dirs` into `self.saved.local.collapsed_dirs` before `apply_pull`.

- [ ] **Step 1: Write the failing rename and link tests**

- In `local_files/tests.rs`, `refresh_worktree_rewrites_collapsed_directory_prefixes`: use the same `Fakes::open_synced()` plus `PathRename { old_path: "src/api", new_path: "src/v2/api" }` shape as `refresh_worktree_migrates_local_threads_and_local_viewed_with_prefix_boundary`. `set_collapsed("src/api", true)`, `set_collapsed("src/api/nested", true)`, and `set_collapsed("src/api-extra", true)`, then `refresh_worktree` with that rename. Saved `collapsed_dirs` is `{"src/api-extra", "src/v2/api", "src/v2/api/nested"}`. `refresh_worktree` must not call `create_collapsed_dirs_after_pull`, so a collapsed path with no file under it still remains.
- In `link_tests.rs`, `linking_unions_collapsed_directories_that_still_contain_viewed_files`: `set_retarget_snapshot` with `prior.local.collapsed_dirs = {"lib"}`. Local session `set_collapsed("src", true)`. Forge snapshot files are `src/kept.rs` and `lib/kept.rs`, both `VIEWED`, with matching `put_base` / `put_disk` text so the link can diff them. After `sync()`, `saved().local.collapsed_dirs` is `{"lib", "src"}`. Both files stay `VIEWED`, so the pull must not expand either directory.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p review-core --lib refresh_worktree_rewrites_collapsed_directory_prefixes linking_unions_collapsed_directories_that_still_contain_viewed_files`
Expected: FAIL (`collapsed_dirs` is not rewritten, or `lib` is missing after link).

- [ ] **Step 3: Rewrite on rename and union on link**

- `migrate_renames` today returns `(did_migrate_threads, did_migrate_viewed)`. Change it to `(bool, bool, bool)`: threads, `local_viewed`, collapsed paths. Map each collapsed path through `apply_renames_to_path`. `refresh_worktree` saves when any of the three is true.
- In `merge_preexisting_pr_snapshot`, `append` every prior collapsed path into `self.saved.local.collapsed_dirs` (`BTreeSet::extend`). Do this before `apply_pull`, which is the existing call order in `sync_or_link_local`.

- [ ] **Step 4: Run the rename and link tests**

Run: `cargo test -p review-core --lib local_files link_tests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/review-core/src/session/local_files.rs crates/review-core/src/session/local_files/tests.rs crates/review-core/src/session/link.rs crates/review-core/src/session/link_tests.rs
git commit -m "feat(session): keep collapsed directories across renames and PR link"
```

---

### Task 6: Expose `setCollapsed` on the protocol

help-me-pick: implement L1 (hours=0.75 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `crates/review-rpc/src/server.rs`
- Modify: `crates/review-rpc/src/protocol.rs`
- Modify: `crates/review-rpc/tests/serve.rs`
- Modify: `crates/review-rpc/src/socket/tests.rs`
- Modify: `lua/jpr/rpc.lua`
- Modify: `tests/lua/fixtures/fake_engine.sh` (default protocol only)
- Test: `crates/review-rpc/tests/serve.rs`
- Test: `crates/review-rpc/src/socket/tests.rs`

**Interfaces:**
- Consumes: `ReviewSession::set_collapsed` from Task 3, `get_string_from_params`, `get_bool_from_params`, `validate_safe_relative_path`.
- Produces: JSON-RPC method `setCollapsed` with params `{ "path": string, "collapsed": bool }` and result `SessionView`. No event. `PROTOCOL_VERSION` is 11 in Rust, `lua/jpr/rpc.lua`, and `FAKE_ENGINE_PROTOCOL:-11`.

- [ ] **Step 1: Write the failing RPC tests**

In `crates/review-rpc/tests/serve.rs`, follow `set_viewed_announces_the_change_before_answering`:

- `set_collapsed_returns_the_view_without_an_event`: request `setCollapsed` with `{"path":"src","collapsed":true}`. The response result's `collapsedDirs` is `["src"]`. No `event` notification is written before that response.
- `set_collapsed_rejects_an_unsafe_path`: request `{"path":"../src","collapsed":true}` and `{"collapsed":true}` (missing path). Both responses are error `-32602`, and a following `snapshot` has no `collapsedDirs` key.

In `allowlist_permits_only_expected_socket_methods`, add `"setCollapsed"` to the refused list.

- [ ] **Step 2: Run the RPC tests to verify they fail**

Run: `cargo test -p review-rpc --test serve set_collapsed && cargo test -p review-rpc --lib allowlist_permits_only_expected_socket_methods`
Expected: FAIL (`-32601` method not found, or the allowlist assertion).

- [ ] **Step 3: Handle `setCollapsed` and bump the protocol numbers that tests execute**

- In `server.rs`, `"setCollapsed"` reads `path` and `collapsed`. If `validate_safe_relative_path(path)` fails, return `RpcError::INVALID_PARAMS` and do not call the session. Otherwise `lock(session)?.set_collapsed(path, collapsed)` and return that view. Do not announce an event.
- Set `PROTOCOL_VERSION` to 11.
- Set `M.PROTOCOL_VERSION = 11` in `lua/jpr/rpc.lua`.
- Set the fake engine default in `tests/lua/fixtures/fake_engine.sh` from `:-10` to `:-11`. Do not add the `setCollapsed` reply yet.
- Leave `docs/protocol.md` for Task 7 so this commit stays on the code the tests run. `just check` does not parse the protocol doc.

- [ ] **Step 4: Run the RPC tests and the Lua specs**

Run: `cargo test -p review-rpc && ./scripts/test-lua.sh`
Expected: PASS. Lua still passes because no spec sends `setCollapsed` yet, and initialize reports version 11 on both sides.

- [ ] **Step 5: Commit**

```bash
git add crates/review-rpc lua/jpr/rpc.lua tests/lua/fixtures/fake_engine.sh
git commit -m "feat(rpc): add setCollapsed and bump the protocol to 11"
```

---

### Task 7: Draw collapse from the session view

help-me-pick: implement L2 (hours=1.5 cause=known material=familiar stakes=none verified=yes)

**Files:**
- Modify: `lua/jpr/views/panel.lua`
- Modify: `tests/lua/fixtures/fake_engine.sh`
- Modify: `tests/lua/panel_view_spec.lua`
- Modify: `tests/lua/layout_and_panel_toggle_spec.lua`
- Modify: `docs/protocol.md`
- Modify: `docs/architecture.md`
- Modify: `docs/decisions.md`
- Test: `tests/lua/panel_view_spec.lua`
- Test: `tests/lua/layout_and_panel_toggle_spec.lua`

**Interfaces:**
- Consumes: `setCollapsed` from Task 6, `jpr.session.show(session, view)`, `jpr.render.panel.build(view, now, opts)` which already takes `opts.collapsed_dirs`.
- Produces: `panel.render` builds its collapse set only from `view.collapsedDirs`. Directory keys send `setCollapsed` only when the bit changes, then `show` the returned view. `panel_render_spec.lua` stays on `opts.collapsed_dirs` and is not rewritten.

- [ ] **Step 1: Write the failing Lua tests and point the fake engine at a fixture file**

In `tests/lua/fixtures/fake_engine.sh`, handle `setCollapsed` before the `*)` fallback:

- A line containing `"method":"setCollapsed"` and `"path":"../x"` replies with error `-32602` and message `invalid repository-relative path`.
- Otherwise, if `FAKE_ENGINE_SET_COLLAPSED_FILE` is a file, `reply` its contents and do not `announce` an event.
- If the file is missing, reply `-32602` with message `setCollapsed fixture missing`. Do not reply with `view_synced`. The client's tree is not known to the shell, so the spec's "insert the path" behavior is the test helper below. The engine log still records the request.

In `tests/lua/panel_view_spec.lua`, add `collapsed_payload = vim.fn.tempname()` and `vim.env.FAKE_ENGINE_SET_COLLAPSED_FILE = collapsed_payload` next to the setViewed payload. Helper:

```lua
local function stage_collapsed(paths)
    local next_view = vim.deepcopy(tree_view)
    next_view.collapsedDirs = paths
    vim.fn.writefile({ vim.json.encode(next_view) }, collapsed_payload)
end
```

Use it before every key or click that changes the collapsed bit, then `vim.wait` until `review.panel.collapsed_dirs["src"]` matches and the log gained one `"method":"setCollapsed"` line. Keep these assertions, now after that wait:

- `h` on `src/a.rs` (line 11) moves to line 9 and does not send `setCollapsed`.
- `h` on expanded `src` sends `"path":"src","collapsed":true` and the buffer line is `▸ src/ (0/2)`.
- `o` on collapsed `src` sends `"collapsed":false`. `o` on an already expanded `src` sends nothing and leaves the cursor on line 9.
- `<CR>` collapses, then expands, with one request each.
- `l` on collapsed `src` sends `"collapsed":false` and leaves the cursor on the directory. `l` on an expanded directory, on a file, on Diff summary, and on Conversation sends nothing.
- The later `v` on collapsed `src` still sends one batched `setViewed`. Stage `collapsedDirs = { "src" }` before that `h`, and stage the setViewed payload as the test already does.
- Each `<LeftMouse>` on line 9 that changes the bit waits for `setCollapsed`. The three-click sequence still ends with `src/a.rs` visible.
- `stage_collapsed({})` is not required for `press_panel`: `panel.render(review, tree_view)` with no `collapsedDirs` clears a previously collapsed `src`. Add an assertion that `review.panel.collapsed_dirs["src"] = true` followed by `panel_view.render(review, tree_view)` leaves `collapsed_dirs["src"] == nil`. (Review Focus #5.)
- Before any collapse key, `tree_view.collapsedDirs = { "src" }`, `panel_view.render(review, tree_view)`, and the `src/` line is collapsed. Clear `collapsedDirs` and render again so the key tests start expanded.
- `require("jpr.session").show(review, tree_view)` after a collapsed render, with `tree_view.collapsedDirs` removed, draws `src/` expanded and shows `src/a.rs`. (Review Focus #5.)
- `session.request(review, "setCollapsed", { path = "../x", collapsed = true }, function() error("applied") end)` leaves the panel lines unchanged. (Review Focus #5.)

In `tests/lua/layout_and_panel_toggle_spec.lua`, replace `review.panel.collapsed_dirs["src"] = true` with `review.view.collapsedDirs = { "src" }` and `panel_view.render(review, review.view)` before closing the sidebar. After `gP`, `review.panel.collapsed_dirs["src"] == true`.

Add one more layout assertion: close the sidebar while `src` is collapsed, `require("jpr.session").show(review, view_without_collapsed_src)`, reopen with `gP`, and assert `collapsed_dirs["src"] == nil`. (Review Focus #5.)

- [ ] **Step 2: Run the Lua specs to verify they fail**

Run: `nvim --headless -u NONE -l tests/lua/panel_view_spec.lua`
Expected: FAIL (`h` does not send `setCollapsed`, or the directory is not collapsed after the response).

- [ ] **Step 3: Read collapse state from the view**

In `lua/jpr/views/panel.lua`:

- Build the set at the start of `M.render` from `view.collapsedDirs`: an array of strings becomes `{ [path] = true }`; a missing value or a non-array becomes `{}`. Ignore non-string entries. Assign that set to `panel.collapsed_dirs` and pass it to `render.build`. Do not keep a previous local set across this render.
- `M.open` uses that same derivation from `session.view`, not `session.panel_collapsed_dirs`.
- `handle_left` on an expanded directory, `handle_open_key` on a collapsed directory, `handle_right` on a collapsed directory, `handle_enter_key` on a directory, and a directory click call `request_set_collapsed(session, row.path, not row.is_collapsed)` only when that boolean differs from `row.is_collapsed`. `h` on a file, `o` on an expanded directory, and `l` on an expanded directory keep their current behavior and send nothing.
- `request_set_collapsed` calls `require("jpr.session").request(session, "setCollapsed", { path = path, collapsed = collapsed }, function(updated_view) require("jpr.session").show(session, updated_view) end)`. Do not mutate `collapsed_dirs` before the response. A request error uses the existing `request` failure path and leaves the previous view on screen.

- [ ] **Step 4: Update the docs**

- `docs/protocol.md`: `protocolVersion` examples become 11. Add a `setCollapsed` row after `setViewed`: params `{ "path": "src/core", "collapsed": true }`, result `SessionView`, no event, stdio-only. Mention it in the stdio-only sentence next to `refreshWorktree`. Document `collapsedDirs` on `SessionView` as a sorted array of joined directory paths, omitted when empty. Add a version 11 note: `setCollapsed` and `collapsedDirs`.
- `docs/architecture.md`: `PROTOCOL_VERSION = 11`. Add `collapsedDirs` to the `local.json` row. In the `jpr.views.panel` row, say collapse is read from `view.collapsedDirs` on every render and that a directory key sends `setCollapsed` only when the bit changes. Mention `create_collapsed_dirs_after_pull` on the `session/sync.rs` row.
- Append this section to `docs/decisions.md`:

```markdown
## Collapsed sidebar directories are local review state

**Decision.** The set of collapsed sidebar directories lives in `local.json`
(`collapsedDirs`) and on every `SessionView`. A successful GitHub pull removes
a collapsed path only when a file inside it changes to `UNVIEWED` or
`DISMISSED` in both the forge snapshot and the reconciled state, and that
differs from the saved viewed state. `setViewed`, a queued mark that
disagrees with GitHub, and a failed pull do not expand anything.

**Why.** Viewed files and local threads already survive a restart. Collapse
was process memory, so every directory opened again. Reopening on any
unviewed file would throw away a collapse the reviewer just made.

**Consequences.** `PROTOCOL_VERSION` advances to `11`. `setCollapsed` is
stdio-only. Renames rewrite the paths. Linking a local review unions the
two sets, and the pull that follows can still expand a path when GitHub
newly marks a file under it for review.

**Revisit when.** A second frontend draws the file tree and needs its own
collapse set per client instead of one set per review.
```

- [ ] **Step 5: Run the full check**

Run: `just check`
Expected: PASS (format, clippy, Rust tests, Lua specs).

- [ ] **Step 6: Commit**

```bash
git add lua/jpr/views/panel.lua tests/lua/fixtures/fake_engine.sh tests/lua/panel_view_spec.lua tests/lua/layout_and_panel_toggle_spec.lua docs/protocol.md docs/architecture.md docs/decisions.md
git commit -m "feat(panel): restore collapsed directories from the review session"
```
