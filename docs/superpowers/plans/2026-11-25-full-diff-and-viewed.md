# Full Branch Diff Navigation, Single-Line Collapsed Viewed Files, and Directory Viewed Toggling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let reviewers return to the full branch diff view via `gF`, `:Jpr full`, or a conditional `"Full Branch Diff"` Command Palette entry, render collapsed viewed files in the full diff view as a single `▸ ✓ path  +N -M` header line with live collapse/expand repaints, toggle viewed on files or recursive directories (`v` / `gv`) via a single batched Rust/GraphQL call, and automatically advance to the next unviewed file whenever a viewed file is marked done.

**Architecture:** `review-core` owns batched multi-path viewed validation, mixed linked-PR + local-only file partitioning, queue management, and single-event announcement (`set_viewed_paths`), while `review-forge-github` executes parameterized aliased GraphQL mutations in 50-file chunks (`set_viewed_many`). `review-rpc` bumps `PROTOCOL_VERSION` to `10` so `setViewed` accepts either `path` or `paths`. In Neovim Lua, `jpr.render.stream` and `jpr.views.stream` fold each viewed file onto its own header line with virtual-text `foldtext()` and split-pane fold sync; `jpr.render.panel` and `jpr.views.panel` add recursive directory toggling and tree-order next-unviewed lookup; `jpr.tui.schema`, `jpr.commands.schema`, `jpr.init`, `plugin/jpr.lua`, and `jpr.session.commands` wire conditional palette visibility, `:Jpr full`, `gF`, and `gv`.

**Tech Stack:** Rust (edition 2024, Cargo workspace: `review-core`, `review-forge-github`, `review-rpc`), Lua (Neovim 0.11+ APIs: `foldtext`, `fillchars`, `<Plug>` mappings, headless Neovim spec runner `./scripts/test-lua.sh`), `just check`.

**Spec:** `docs/superpowers/specs/2026-11-25-full-diff-and-viewed-design.md`

## Global Constraints

- Dependency rule: generic crates (`crates/review-*`) never depend on Neovim, Lua, `cli-tui`, or any frontend crate (`crates/jpr-review/tests/dependency_rule.rs`).
- Protocol lockstep: `PROTOCOL_VERSION = 10` matches across `crates/review-rpc/src/protocol.rs`, `lua/jpr/rpc.lua`, `tests/lua/fixtures/fake_engine.sh`, `docs/protocol.md`, and `docs/architecture.md`.
- Schema-to-TUI invariant: all 16 `:Jpr` commands remain registered in `lua/jpr/commands/schema.lua`; `full` is registered in `COMMAND_ALIASES` (not a duplicate palette entry or completion candidate).
- Security: untrusted PR file paths are always passed as GraphQL JSON variables (`$p0`, `$p1`, ...) and sanitized via `vim.fn.strtrans` in `foldtext()`.
- Code style: zero em dashes in code, comments, tests, or docs; functions `<= 45` lines; descriptive variable and builder names; clippy pedantic + nursery clean (`-D warnings`).
- Red/Green TDD for every task; `just check` passes cleanly before finishing.

## Review Focus

- **Untrusted / special-character file paths in GraphQL batching and `foldtext`:** Paths with quotes, backslashes, or control characters (`evil\27.md`, `a"b\c.rs`) never break GraphQL syntax (variables only) and render safely via `strtrans` in `foldtext()`. (Pinned in Tasks 2 and 4.)
- **Mixed linked-PR + `[local]` files and partially viewed directories:** Pressing `v` on a directory containing pushed PR files (some already `VIEWED`) and `[local]` worktree files marks all descendants `VIEWED` atomically, sends GitHub mutations only for linked PR files needing remote updates, updates local-only files locally, and saves/announces once. (Pinned in Tasks 1 and 5.)
- **Stale async `setViewed` callback after manual file switch:** If a reviewer presses `gv` in `src/a.rs` and manually switches to `src/c.rs` before the engine responds, the `setViewed` callback does not yank the main window away from `src/c.rs`. (Pinned in Task 6.)
- **Window option leakage on leaving stream & tab leakage of `gF`:** Opening a file from the full diff view restores prior window-local `foldtext`, `fillchars`, and `foldminlines`; `gF` bound on a normal worktree buffer falls back to native `gF` when invoked in a non-review tab. (Pinned in Tasks 4 and 6.)
- **All-files-viewed terminal state and unmark-viewed non-jump:** Marking the last remaining unviewed file viewed in editor view (or via sidebar while that file is open) switches to the full branch diff view with `"all files viewed"`; unmarking a file (`viewed = false`) in editor or stream view stays on that file. (Pinned in Tasks 4, 5, and 6.)

---

## File Map

| Task | Files | Responsibility |
| --- | --- | --- |
| Task 1 | Modify `crates/review-core/src/viewed.rs`, `crates/review-core/src/ports.rs`, `crates/review-core/src/fakes.rs`, `crates/review-core/src/session/viewed.rs` | Pure directory viewed helpers, `Forge::set_viewed_many` trait method + fake support, and atomic `ReviewSession::set_viewed_paths` |
| Task 2 | Modify `crates/review-forge-github/src/graphql.rs`, `crates/review-forge-github/src/lib.rs` | Pure parameterized aliased GraphQL batch builder (`build_batch_viewed_mutation`) and 50-path chunked `GhForge::set_viewed_many` |
| Task 3 | Modify `crates/review-rpc/src/protocol.rs`, `crates/review-rpc/src/params.rs`, `crates/review-rpc/src/params/tests.rs`, `crates/review-rpc/src/server.rs`, `crates/review-rpc/tests/serve.rs`, `crates/review-rpc/tests/serve/refresh_worktree.rs`, `lua/jpr/rpc.lua`, `tests/lua/rpc_spec.lua`, `tests/lua/fixtures/fake_engine.sh` | Protocol v10 bump, `setViewed` `path` or `paths` param parser, server routing, and fake engine multi-path support |
| Task 4 | Modify `lua/jpr/render/stream.lua`, `lua/jpr/views/stream/init.lua`, `lua/jpr/views/stream/navigation.lua`, `tests/lua/stream_render_spec.lua`, `tests/lua/stream_view_spec/core.lua`, `tests/lua/stream_view_spec/threads.lua` | Single-line header folding (`foldtext()`, `fillchars`, `foldminlines = 0`), option save/restore, split `zo`/`zc`/`za` sync, and jump-only-on-mark-viewed with wrap-around |
| Task 5 | Modify `lua/jpr/render/panel.lua`, `lua/jpr/views/panel.lua`, `tests/lua/panel_render_spec.lua`, `tests/lua/panel_view_spec.lua` | Pure `collect_directory_toggle_from_files` and `find_next_unviewed_path` helpers, recursive directory `v` dispatch, live full-diff repaint verification, and main-window advancement when single file is marked viewed |
| Task 6 | Modify `plugin/jpr.lua`, `lua/jpr/init.lua`, `lua/jpr/commands/schema.lua`, `lua/jpr/tui/schema.lua`, `lua/jpr/tui/wizard/palette.lua`, `lua/jpr/tui/render.lua`, `lua/jpr/session/commands.lua`, `lua/jpr/views/diff/init.lua`, `lua/jpr/views/panel.lua`, `lua/jpr/views/conversation.lua`, `lua/jpr/views/cheatsheet.lua`, `tests/lua/tui_schema_spec.lua`, `tests/lua/tui_render_spec.lua`, `tests/lua/command_spec.lua`, `tests/lua/cheatsheet_spec.lua`, `tests/lua/palette_and_open_picker_spec/palette.lua`, `tests/lua/diff_view_spec.lua` | `:Jpr full` alias, `"Full Branch Diff"` label + `when` palette filtering on `is_stream_visible`, `gF` and `gv` `<Plug>`/buffer bindings (including binary and unchanged worktree files), `session.toggle_viewed_current()` with next-file advancement, and cheatsheet updates |
| Task 7 | Modify `docs/protocol.md`, `docs/architecture.md`, `docs/decisions.md`, `README.md` | Document protocol v10, batched `setViewed`, single-line collapsed viewed files, `:Jpr full`, `gF`, `gv`, recursive directory `v`, and next-file advancement; run full `just check` |

---

### Task 1: Batched Multi-Path Viewed Rules & Session API (`review-core`)

help-me-pick: implement L2 (hours=1.5 cause=known material=familiar stakes=high verified=yes)

High-risk: yes

**Files:**
- Modify: `crates/review-core/src/viewed.rs`
- Modify: `crates/review-core/src/ports.rs`
- Modify: `crates/review-core/src/fakes.rs`
- Modify: `crates/review-core/src/session/viewed.rs`

**Interfaces:**
- Consumes: existing `ChangedFile`, `ViewedState`, `Event::ViewedChanged`, `Event::SyncFailed`, `ReviewSession::save_and_announce_viewed`.
- Produces:
  - `review_core::viewed::is_path_in_directory(path: &str, dir: &str) -> bool`
  - `review_core::viewed::collect_directory_toggle_paths(files: &[ChangedFile], dir: &str) -> Option<(Vec<String>, bool)>`
  - `Forge::set_viewed_many(&self, pr: &PullRequest, paths: &[String], viewed: bool) -> Result<()>` (with default sequential fallback in trait; batch-recording implementation in `FakeForge` with `viewed_batch_calls(&self) -> Vec<(Vec<String>, bool)>`)
  - `ReviewSession::set_viewed_paths(&mut self, paths: &[String], viewed: bool) -> Result<SessionView>`

- [ ] **Step 1: Write failing unit tests in `crates/review-core/src/viewed.rs` and `crates/review-core/src/session/viewed.rs`**

In `crates/review-core/src/viewed.rs` tests, assert:
1. `is_path_in_directory("src/core/a.rs", "src")` and `is_path_in_directory("src/core/a.rs", "src/core/")` are `true`; `is_path_in_directory("src_extra/a.rs", "src")`, `is_path_in_directory("src", "src")`, and `is_path_in_directory("src/a.rs", "")` are `false`.
2. `collect_directory_toggle_paths` on `[("src/a.rs", Viewed), ("src/sub/b.rs", Unviewed), ("README.md", Unviewed)]` for `"src"` returns `Some((vec!["src/a.rs", "src/sub/b.rs"], true))`; when both `src/` files are `Viewed`, returns `Some((vec!["src/a.rs", "src/sub/b.rs"], false))`; when one is `Dismissed`, returns `Some((..., true))`; for `"docs"` returns `None`.

In `crates/review-core/src/session/viewed.rs` tests, assert:
1. `set_viewed_paths(&["src/a.rs", "src/b.rs"], true)` with `src/a.rs` already `Viewed` and `src/b.rs` `Unviewed` invokes `forge.set_viewed_many` once with only `["src/b.rs"]`, saves once, and emits exactly one `Event::ViewedChanged` with `viewed_count == 2`.
2. `set_viewed_paths` with a mix of a linked PR file and a local-only file (`self.local_files`) updates both in one save and one `Event::ViewedChanged`, calling `forge.set_viewed_many` only for the linked PR path and updating `saved.local.local_viewed` for the local-only path.
3. `set_viewed_paths` rejects an empty slice and rejects a slice containing any unknown path **before** mutating any valid path in the same batch (zero forge calls, zero state mutations).
4. `set_viewed_paths` deduplicates repeated paths and queues all failed linked paths in `queued_viewed` when the forge fails, emitting a single `Event::ViewedChanged` (plus one `Event::SyncFailed { auth_required: true, is_background: false }` on auth failure).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p review-core --all-features viewed`
Expected: FAIL with missing functions/methods (`is_path_in_directory`, `collect_directory_toggle_paths`, `set_viewed_paths`).

- [ ] **Step 3: Implement pure helpers, `Forge::set_viewed_many`, `FakeForge`, and `ReviewSession::set_viewed_paths`**

1. In `crates/review-core/src/viewed.rs`: implement `is_path_in_directory` and `collect_directory_toggle_paths`.
2. In `crates/review-core/src/ports.rs`: add `fn set_viewed_many(&self, pr: &PullRequest, paths: &[String], viewed: bool) -> Result<()>` on `Forge` with a default loop calling `self.set_viewed(pr, path, viewed)`.
3. In `crates/review-core/src/fakes.rs`: record batch calls in `FakeForge::set_viewed_many` (also pushing each `(path, viewed)` into `viewed_calls` on success and honoring `write_failure` / `auth_failure`), plus expose `viewed_batch_calls(&self) -> Vec<(Vec<String>, bool)>`.
4. In `crates/review-core/src/session/viewed.rs`: implement `set_viewed_paths` (validate non-empty, deduplicate preserving order, validate every path exists in linked `saved.files` or `local_files` before any mutation, compute `forge_paths` needing remote sync, update linked and local-only states, call `set_viewed_many` once for `forge_paths`, save & announce once, and emit `SyncFailed` once on auth error). Delegate `set_viewed(path, viewed)` to `set_viewed_paths(&[path.to_owned()], viewed)`. Keep every helper function `<= 45` lines.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p review-core --all-features viewed`
Expected: PASS (all `viewed` and `session::viewed` tests green).

- [ ] **Step 5: Commit Task 1**

```bash
git add crates/review-core/src/viewed.rs crates/review-core/src/ports.rs crates/review-core/src/fakes.rs crates/review-core/src/session/viewed.rs
git commit -m "feat(core): add batched multi-path viewed updates and directory helpers"
```

---

### Task 2: Parameterized Aliased GraphQL Batching (`review-forge-github`)

help-me-pick: implement L1 (hours=0.75 cause=known material=familiar stakes=none verified=yes)

High-risk: no

**Files:**
- Modify: `crates/review-forge-github/src/graphql.rs`
- Modify: `crates/review-forge-github/src/lib.rs`

**Interfaces:**
- Consumes: `Forge::set_viewed_many` from Task 1, `GhForge::graphql`, `PullRequest`.
- Produces:
  - `review_forge_github::graphql::BATCH_VIEWED_CHUNK_SIZE: usize` (`50`)
  - `review_forge_github::graphql::build_batch_viewed_mutation(pr_node_id: &str, paths: &[String], viewed: bool) -> (String, Value)`
  - `GhForge::set_viewed_many(&self, pr: &PullRequest, paths: &[String], viewed: bool) -> Result<()>`

- [ ] **Step 1: Write failing unit tests in `crates/review-forge-github/src/graphql.rs` (or its `tests` module) and `crates/review-forge-github/src/lib.rs`**

Assert:
1. `build_batch_viewed_mutation("PR_7", &["src/a.rs", "src/b\"quote\\x.rs"], true)` produces a GraphQL mutation declaring `($pr: ID!, $p0: String!, $p1: String!)` with aliased fields `f0: markFileAsViewed(input: { pullRequestId: $pr, path: $p0 }) { clientMutationId }` and `f1: markFileAsViewed(...)`, NEVER embedding raw path strings into the query document text, and returning variables `{ "pr": "PR_7", "p0": "src/a.rs", "p1": "src/b\"quote\\x.rs" }`.
2. When `viewed == false`, the mutation uses `unmarkFileAsViewed`.
3. `BATCH_VIEWED_CHUNK_SIZE == 50`, and a helper `split_viewed_chunks` splits 120 paths into chunks of `[50, 50, 20]` and 0 paths into `[]`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p review-forge-github`
Expected: FAIL with missing `build_batch_viewed_mutation` / `BATCH_VIEWED_CHUNK_SIZE`.

- [ ] **Step 3: Implement `build_batch_viewed_mutation` and `GhForge::set_viewed_many`**

1. In `crates/review-forge-github/src/graphql.rs`: add `pub const BATCH_VIEWED_CHUNK_SIZE: usize = 50;` and `pub fn build_batch_viewed_mutation(pr_node_id: &str, paths: &[String], viewed: bool) -> (String, Value)` using strictly parameterized `$p{index}: String!` variables and `f{index}` aliases.
2. In `crates/review-forge-github/src/lib.rs`: implement `Forge::set_viewed_many`:
   - `paths.is_empty()` -> `Ok(())`
   - `paths.len() == 1` -> `self.set_viewed(pr, &paths[0], viewed)`
   - `paths.len() > 1` -> iterate `paths.chunks(graphql::BATCH_VIEWED_CHUNK_SIZE)`, call `self.graphql(&query, &variables)` with context naming chunk count and mark state.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p review-forge-github`
Expected: PASS.

- [ ] **Step 5: Commit Task 2**

```bash
git add crates/review-forge-github/src/graphql.rs crates/review-forge-github/src/lib.rs
git commit -m "feat(forge-github): batch viewed mutations with parameterized GraphQL aliases"
```

---

### Task 3: Protocol v10 Multi-Path `setViewed` RPC & Lockstep Updates (`review-rpc`, `lua/jpr/rpc.lua`, `fake_engine.sh`)

help-me-pick: implement L2 (hours=1 cause=known material=familiar stakes=high verified=yes)

High-risk: yes

**Files:**
- Modify: `crates/review-rpc/src/protocol.rs`
- Modify: `crates/review-rpc/src/params.rs`
- Modify: `crates/review-rpc/src/params/tests.rs`
- Modify: `crates/review-rpc/src/server.rs`
- Modify: `crates/review-rpc/tests/serve.rs`
- Modify: `crates/review-rpc/tests/serve/refresh_worktree.rs`
- Modify: `lua/jpr/rpc.lua`
- Modify: `tests/lua/rpc_spec.lua`
- Modify: `tests/lua/fixtures/fake_engine.sh`

**Interfaces:**
- Consumes: `ReviewSession::set_viewed_paths` from Task 1.
- Produces:
  - `PROTOCOL_VERSION = 10` (`crates/review-rpc/src/protocol.rs` and `lua/jpr/rpc.lua`)
  - `review_rpc::params::get_viewed_paths_from_params(params: &Value) -> Result<Vec<String>, RpcError>`
  - JSON-RPC `setViewed` accepting `{ "path": string, "viewed": bool }` OR `{ "paths": string[], "viewed": bool }` (non-empty array; error `-32602` on neither, both, empty array, or non-string items).

- [ ] **Step 1: Write failing param, server, and Lua RPC tests**

1. In `crates/review-rpc/src/params/tests.rs`: test `get_viewed_paths_from_params` accepts `{ "path": "src/a.rs" }`, accepts `{ "paths": ["src/a.rs", "src/b.rs"] }`, and rejects `{}` (missing both), `{ "path": "a", "paths": ["b"] }` (both present), `{ "paths": [] }` (empty), `{ "paths": [1] }` (non-string), and `{ "path": 1 }` with `RpcError::INVALID_PARAMS` (`-32602`).
2. In `crates/review-rpc/tests/serve.rs`: update `protocolVersion` assertions from `9` to `10` (and in `serve/refresh_worktree.rs`), and add an integration test sending `setViewed` with `{ "paths": ["src/a.rs", "src/b.rs"], "viewed": true }` asserting one `viewedChanged` notification followed by the updated `SessionView` response, plus one sending `{ "paths": [], "viewed": true }` expecting `-32602`.
3. In `tests/lua/rpc_spec.lua`: update `protocolVersion == 10`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p review-rpc && nvim --headless -u NONE -i NONE -l tests/lua/rpc_spec.lua`
Expected: FAIL on protocol version mismatch and missing `get_viewed_paths_from_params`.

- [ ] **Step 3: Implement protocol v10, `get_viewed_paths_from_params`, `server.rs` routing, and `fake_engine.sh` multi-path support**

1. Bump `PROTOCOL_VERSION` to `10` in `crates/review-rpc/src/protocol.rs`, `lua/jpr/rpc.lua`, and `tests/lua/fixtures/fake_engine.sh`.
2. Add `get_viewed_paths_from_params` in `crates/review-rpc/src/params.rs` and wire `"setViewed"` in `crates/review-rpc/src/server.rs` to call `lock(session)?.set_viewed_paths(&paths, viewed)`.
3. Update `tests/lua/fixtures/fake_engine.sh` `setViewed` handler:
   - Keep `"BROKEN.md"` error behavior.
   - If `FAKE_ENGINE_SET_VIEWED_FILE` is set and exists, announce `viewedChanged` and reply with its contents; else if the request contains `"viewed":false`, announce and reply with `$view_synced`; else announce and reply with `$view_viewed`.

- [ ] **Step 4: Run Rust and Lua RPC tests to verify they pass**

Run: `cargo test --workspace --all-features && nvim --headless -u NONE -i NONE -l tests/lua/rpc_spec.lua`
Expected: PASS across all Rust crates and `rpc_spec: ok`.

- [ ] **Step 5: Commit Task 3**

```bash
git add crates/review-rpc lua/jpr/rpc.lua tests/lua/rpc_spec.lua tests/lua/fixtures/fake_engine.sh
git commit -m "feat(rpc): bump protocol to v10 and support multi-path setViewed"
```

---

### Task 4: Single-Line Collapsed Viewed Files & Navigation in Full Branch Diff (`lua/jpr/render/stream.lua`, `lua/jpr/views/stream/`)

help-me-pick: implement L2 (hours=1.25 cause=known material=familiar stakes=none verified=yes)

High-risk: no

**Files:**
- Modify: `lua/jpr/render/stream.lua`
- Modify: `lua/jpr/views/stream/init.lua`
- Modify: `lua/jpr/views/stream/navigation.lua`
- Modify: `tests/lua/stream_render_spec.lua`
- Modify: `tests/lua/stream_view_spec/core.lua`
- Modify: `tests/lua/stream_view_spec/threads.lua`

**Interfaces:**
- Consumes: `StreamView` (`StreamRow::File.folded`), `jpr.render.stream`, `jpr.views.stream`.
- Produces:
  - `render.stream.create_layout_from_stream`: `layout.folds` entries `{ first = file_header_line, last = file_last_line }` whenever `row.folded == true` and `file_header_line < file_last_line`
  - `render.stream.find_next_unviewed_file(layout, line_or_path)`: scans forward after the current file and wraps around to earlier unviewed files if none follow
  - `stream_view.foldtext()`: returns `{ { vim.fn.strtrans(vim.fn.getline(vim.v.foldstart)), "JprFileHeader" } }`
  - Split-synced `zo` / `zc` / `za` mappings on stream buffers and clean restoration of window-local `foldtext`, `fillchars`, and `foldminlines` when leaving the stream buffer

- [ ] **Step 1: Write failing stream render and view tests**

1. In `tests/lua/stream_render_spec.lua`:
   - Update fold assertion: `b.rs` (header line 6, body lines 7..8) produces `{ first = 6, last = 8 }` (header included in fold), and a viewed file with a 1-line `binary file` note produces `{ first = header, last = header + 1 }`, while a header-only file with zero body rows produces no fold.
   - Add test for `find_next_unviewed_file` wrap-around: when `a.rs` is unviewed, `b.rs` is viewed, and `c.png` is unviewed (line 9), `find_next_unviewed_file(unified, 9)` wraps around and returns `a.rs`, whereas when all files are viewed it returns `nil`.
2. In `tests/lua/stream_view_spec/core.lua`:
   - Assert `b.md` (line 4 header, lines 5..8 body) is folded as `{ first = 4, last = 8 }` (`foldclosed(4) == 4 and foldclosedend(4) == 8`), occupies **exactly 1 screen row** showing `▸ ✓ b.md  +1 -0` with no `+--` banner row below it (`screen_row(4)` starts with `▸ ✓ b.md` and `screen_row(5)` starts with `▾   c.md`!).
   - Assert untrusted control bytes in a folded file header (`evil\27.md`) render safely via `strtrans` (`evil^[.md`), never raw ESC.
   - Assert `]f` / `[f` still visit `{ 4, 9, 9, 4 }`, `]h` / `[h` skip folded hunks, `<CR>` on line 4 opens `b.md` at line 1, and pressing `zo` on line 4 expands `b.md` in place (and in split mode expands both `left_win` and `main_win`).
   - Assert opening `fresh.md` from the stream restores window-local `foldtext`, `fillchars`, and `foldminlines` to the window's global/prior values.
   - Assert unmarking a viewed file via `v` (`viewed = false`) does NOT jump the cursor away to another file.

- [ ] **Step 2: Run stream specs to verify they fail**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/stream_render_spec.lua && nvim --headless -u NONE -i NONE -l tests/lua/stream_view_spec.lua`
Expected: FAIL on fold start line (`7` vs `6`), extra `+--` screen line, and missing wrap-around / `foldtext`.

- [ ] **Step 3: Implement single-line header folding, `foldtext()`, option restore, split fold sync, and navigation updates**

1. In `lua/jpr/render/stream.lua`:
   - Set `fold_start = row.folded and line or nil` and `close_fold` guard `first_line and first_line < last_line`.
   - Update `find_next_unviewed_file(layout, line)` to scan files after `line` first, then wrap around to files before `line` (skipping the file containing `line`).
2. In `lua/jpr/views/stream/init.lua`:
   - Add `M.foldtext()` returning `{ { vim.fn.strtrans(vim.fn.getline(vim.v.foldstart)), "JprFileHeader" } }`.
   - In `style_window(win, is_bound)`: save prior window-local `foldtext`, `fillchars`, and `foldminlines` (once per window while not already saved), then set `foldmethod = "manual"`, `foldenable = true`, `foldminlines = 0`, `foldtext = "v:lua.require('jpr.views.stream').foldtext()"`, and `fillchars` merging `fold: ` onto existing fillchars.
   - Add `restore_window_fold_options(win)` called in `BufWinLeave` (when the window now shows a non-stream buffer) and in `M.close` so opened files inherit zero stream fold options.
   - Add `M.toggle_fold_command(session, command)` mapped to `zo`, `zc`, `za` on stream buffers so split stream panes execute the same fold command on both `main_win` and `left_win` at the cursor line.
3. In `lua/jpr/views/stream/navigation.lua`:
   - In `jump(session, kind, step)`: keep `lines` unfiltered for `kind == "files"` (or filter only lines strictly inside a closed fold: `foldclosed(line) == -1 or foldclosed(line) == line`), while continuing `foldclosed(line) == -1` for `kind == "hunks"` and `kind == "threads"`.
   - In `toggle_viewed(session)`: compute `target_viewed = file.viewed ~= "VIEWED"` and only arm `state.after_draw = { request_id = state.request_id, run = move_to_next_unviewed }` when `target_viewed == true`.

- [ ] **Step 4: Run stream specs to verify they pass**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/stream_render_spec.lua && nvim --headless -u NONE -i NONE -l tests/lua/stream_view_spec.lua`
Expected: PASS (`stream_render_spec: ok` and `stream_view_spec: ok`).

- [ ] **Step 5: Commit Task 4**

```bash
git add lua/jpr/render/stream.lua lua/jpr/views/stream/init.lua lua/jpr/views/stream/navigation.lua tests/lua/stream_render_spec.lua tests/lua/stream_view_spec/core.lua tests/lua/stream_view_spec/threads.lua
git commit -m "feat(stream): collapse viewed files to a single header line with zo support"
```

---

### Task 5: Recursive Directory `'v'`, Live Full-Diff Collapse/Expand, and Main-Window Advancement (`lua/jpr/render/panel.lua`, `lua/jpr/views/panel.lua`)

help-me-pick: implement L2 (hours=1.25 cause=known material=familiar stakes=none verified=yes)

High-risk: no

**Files:**
- Modify: `lua/jpr/render/panel.lua`
- Modify: `lua/jpr/views/panel.lua`
- Modify: `tests/lua/panel_render_spec.lua`
- Modify: `tests/lua/panel_view_spec.lua`

**Interfaces:**
- Consumes: Protocol v10 `setViewed` (`path` or `paths`) from Task 3, single-line folding from Task 4.
- Produces:
  - `render.panel.collect_directory_toggle_from_files(files, dir_path) -> { paths: string[], viewed: boolean } | nil`
  - `render.panel.find_next_unviewed_path(view, current_path) -> string | nil`
  - `panel.advance_after_viewed(session, updated_view, marked_paths, opts)` (reused by Task 6's `session.toggle_viewed_current`)

- [ ] **Step 1: Write failing panel render and view tests**

1. In `tests/lua/panel_render_spec.lua`:
   - Test `collect_directory_toggle_from_files`:
     - Recursive match across `src/a.rs`, `src/sub/b.rs`, `src/sub/deep/c.rs` while ignoring `src_other/d.rs`.
     - Mixed viewed states (`VIEWED` + `UNVIEWED` or `DISMISSED`) -> `{ paths = {...}, viewed = true }`.
     - All descendants `VIEWED` -> `{ paths = {...}, viewed = false }`.
     - Joined single-child directory `docs/x` matches `docs/x/y.md`.
     - Empty/non-matching directory returns `nil`.
   - Test `find_next_unviewed_path`:
     - Follows `view.tree` display order (not raw `view.files` order).
     - Wraps around from last file to earlier unviewed file.
     - Treats `DISMISSED` as unviewed.
     - Returns `nil` when all files are `VIEWED`.
2. In `tests/lua/panel_view_spec.lua`:
   - Test pressing `v` on an **expanded** directory (`src/`) sends a single `setViewed` request with `paths = ["src/a.rs", "src/sub/b.rs"]` and `viewed = true`, and pressing `v` again when all are `VIEWED` sends `viewed = false`.
   - Test pressing `v` on a **collapsed** directory (`▸ src/ (2)`) still recursively collects and sends all descendant paths.
   - Test live full-diff repaint: with the full diff view (`stream`) visible beside the panel, pressing `v` on a directory to mark its files viewed repaints the stream so those files collapse to single header lines, and pressing `v` again to unmark them repaints the stream so those files expand again.
   - Test main-window advancement from sidebar `v`: when `src/a.rs` is open in the main window (stream hidden) and the user presses `v` on `src/a.rs` (or on `src/`) to mark it viewed, the main window advances to the next unviewed file (`README.md`) while cursor focus stays in the sidebar panel; marking the last unviewed file switches the main window to the full diff stream.

- [ ] **Step 2: Run panel specs to verify they fail**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/panel_render_spec.lua && nvim --headless -u NONE -i NONE -l tests/lua/panel_view_spec.lua`
Expected: FAIL with missing `collect_directory_toggle_from_files` / `find_next_unviewed_path` and directory `v` no-op.

- [ ] **Step 3: Implement pure panel helpers, recursive directory `v`, and main-window advancement**

1. In `lua/jpr/render/panel.lua`:
   - Implement `M.collect_directory_toggle_from_files(files, dir_path)` (strip trailing `/` from `dir_path`, require non-empty, match `vim.startswith(file.path, prefix)`).
   - Implement `M.find_next_unviewed_path(view, current_path)` iterating tree order (`view.tree` -> `files[row.file + 1]`, fallback to `view.files`) forward then wrapping around.
2. In `lua/jpr/views/panel.lua`:
   - Export `M.advance_after_viewed(session, updated_view, marked_paths, opts)` (`opts.focus_next` boolean):
     - If `stream.is_visible(session)` -> return (stream already repaints via `viewedChanged`).
     - Inspect `main_win = main_window.find(session)` and its buffer (`vim.b[buf].jpr_base_path` or `diff.buffer_to_changed_path(session, buf)`).
     - If that open file path is in `marked_paths`:
       - Compute `next_path = render.find_next_unviewed_path(updated_view, open_path)`.
       - Save `previous_win = vim.api.nvim_get_current_win()`.
       - If `next_path`: `main_window.edit(session, main_win, next_path, 1)`; else `stream.show(session, { focus = opts.focus_next == true })` and `require("jpr").info("all files viewed")`.
       - If `opts.focus_next ~= true` and `vim.api.nvim_win_is_valid(previous_win)`: `vim.api.nvim_set_current_win(previous_win)`.
   - Update `M.toggle_viewed_under_cursor(session)` to read `M.get_row_under_cursor(session)`:
     - `row.kind == "file"`: send `{ path = row.path, viewed = target_viewed }`; on `target_viewed == true` result, call `M.advance_after_viewed(session, updated_view, { row.path }, { focus_next = false })`.
     - `row.kind == "dir"`: call `render.collect_directory_toggle_from_files((session.view and session.view.files) or {}, row.path)`; send `{ paths = toggle.paths, viewed = toggle.viewed }`; on `toggle.viewed == true` result, call `M.advance_after_viewed(session, updated_view, toggle.paths, { focus_next = false })`.
   - Update `v` keymap description to `"Toggle viewed for the file or directory under the cursor"`.

- [ ] **Step 4: Run panel specs to verify they pass**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/panel_render_spec.lua && nvim --headless -u NONE -i NONE -l tests/lua/panel_view_spec.lua`
Expected: PASS (`panel_render_spec: ok` and `panel_view_spec: ok`).

- [ ] **Step 5: Commit Task 5**

```bash
git add lua/jpr/render/panel.lua lua/jpr/views/panel.lua tests/lua/panel_render_spec.lua tests/lua/panel_view_spec.lua
git commit -m "feat(panel): support recursive directory viewed toggling and next-file advancement"
```

---

### Task 6: Conditional `"Full Branch Diff"` Palette Command, `:Jpr full` Alias, and `gF` / `gv` Shortcuts

help-me-pick: implement L2 (hours=1.5 cause=known material=familiar stakes=none verified=yes)

High-risk: no

**Files:**
- Modify: `plugin/jpr.lua`
- Modify: `lua/jpr/init.lua`
- Modify: `lua/jpr/commands/schema.lua`
- Modify: `lua/jpr/tui/schema.lua`
- Modify: `lua/jpr/tui/wizard/palette.lua`
- Modify: `lua/jpr/tui/render.lua`
- Modify: `lua/jpr/session/commands.lua`
- Modify: `lua/jpr/views/diff/init.lua`
- Modify: `lua/jpr/views/panel.lua`
- Modify: `lua/jpr/views/conversation.lua`
- Modify: `lua/jpr/views/cheatsheet.lua`
- Modify: `tests/lua/tui_schema_spec.lua`
- Modify: `tests/lua/tui_render_spec.lua`
- Modify: `tests/lua/command_spec.lua`
- Modify: `tests/lua/cheatsheet_spec.lua`
- Modify: `tests/lua/palette_and_open_picker_spec/palette.lua`
- Modify: `tests/lua/diff_view_spec.lua`

**Interfaces:**
- Consumes: `panel.advance_after_viewed` from Task 5, `stream.is_visible` and `stream.toggle_viewed` from Task 4.
- Produces:
  - `tui.schema.get_active_commands(commands, context) -> table[]` (honoring optional `command.when(context)`)
  - `COMMAND_ALIASES.full = "stream"` and `stream` spec labeled `"Full Branch Diff"` with `when = function(context) return not (context and context.is_stream_visible == true) end`
  - `jpr.defaults.keys.full_diff = "gF"` (`<Plug>(jpr-full-diff)`) and `jpr.defaults.keys.toggle_viewed = "gv"` (`<Plug>(jpr-toggle-viewed)`)
  - `jpr.bind_review_nav_keys(buf)` for tab-aware `gF` on non-changed worktree buffers, plus panel/conversation bindings
  - `session.toggle_viewed_current()` dispatching across panel, stream, and editor/base buffers (advancing to next unviewed file or full branch diff on `viewed == true`, staying put on `viewed == false` or if the reviewer already switched away before the reply arrived)

- [ ] **Step 1: Write failing tests across TUI schema, command, palette, cheatsheet, and diff specs**

1. In `tests/lua/tui_schema_spec.lua`: test `validate_command_specs` rejects non-function `command.when`, and `get_active_commands(commands, context)` filters out commands whose `when(context)` returns `false`.
2. In `tests/lua/tui_render_spec.lua`: test `create_palette_layout_from_commands` omits commands filtered out by `command.when(context)`.
3. In `tests/lua/command_spec.lua`:
   - Assert `full` resolves to `"stream"`, stays out of `list_command_ids()` and `jpr.complete("f", "Jpr f")`, and `:Jpr full` dispatches `session.stream_current()`.
   - Assert `<Plug>(jpr-full-diff)` and `<Plug>(jpr-toggle-viewed)` exist in Normal mode (and NOT Visual mode for `gv`).
   - Assert `jpr.defaults.keys.full_diff == "gF"` and `jpr.defaults.keys.toggle_viewed == "gv"`, and `bind_buffer_keys` binds both with `nowait` and skips them when set to `false`.
4. In `tests/lua/palette_and_open_picker_spec/palette.lua`:
   - Assert `stream` spec has `label == "Full Branch Diff"`.
   - Assert when a session has `stream` visible (`is_stream_visible == true`), opening the Command Palette hides `"Full Branch Diff  [stream]"`.
   - Assert when the reviewer opens a single file (`is_stream_visible == false`), opening the Command Palette displays `"Full Branch Diff  [stream]"` and selecting it calls `session.stream_current()`.
5. In `tests/lua/cheatsheet_spec.lua`: assert default cheatsheet includes `gF`, `gv`, and `"Toggle file or directory viewed"`, and reflects custom/disabled `full_diff` and `toggle_viewed` keys.
6. In `tests/lua/diff_view_spec.lua`:
   - Test `gF` from a changed file buffer, a binary changed file buffer, an unchanged worktree file opened in the review tab, PR conversation, and the sidebar panel switches to and focuses the full branch diff view; test `gF` on an unchanged buffer in a **non-review** tab does not call `session.stream_current()`.
   - Test `gv` from a changed worktree file buffer (and from a split `jpr://base/...` buffer, and from a binary changed file buffer):
     - Marking `src/a.rs` viewed opens and focuses the next unviewed file (`src/b.rs`).
     - Marking the last unviewed file viewed opens and focuses the full branch diff view and emits `"all files viewed"`.
     - Unmarking a viewed file (`viewed = false`) stays in that open file buffer.
     - If the reviewer manually switches from `src/a.rs` to `src/c.rs` while `setViewed` is still in flight, the response does not yank the window away from `src/c.rs`.
   - Test `gv` in the full branch diff view toggles the file under the cursor just like `v`.

- [ ] **Step 2: Run affected Lua specs to verify they fail**

Run:
```bash
for spec in tests/lua/tui_schema_spec.lua tests/lua/tui_render_spec.lua tests/lua/command_spec.lua tests/lua/cheatsheet_spec.lua tests/lua/palette_and_open_picker_spec.lua tests/lua/diff_view_spec.lua; do
  nvim --headless -u NONE -i NONE -l "$spec" || true
done
```
Expected: FAIL on each newly added assertion.

- [ ] **Step 3: Implement schema `when` filtering, `:Jpr full`, `gF` / `gv`, `toggle_viewed_current`, and cheatsheet updates**

1. `lua/jpr/tui/schema.lua`: validate `command.when` is nil or function; add `M.get_active_commands(commands, context)`.
2. `lua/jpr/tui/wizard/palette.lua` and `lua/jpr/tui/render.lua`: filter `command_list = schema.get_active_commands(commands, current_context)`.
3. `lua/jpr/commands/schema.lua`: add `full = "stream"` to `COMMAND_ALIASES`; update `stream` spec with `label = "Full Branch Diff"`, updated `help`, and `when = function(context) return not (context and context.is_stream_visible == true) end`.
4. `plugin/jpr.lua`: register `<Plug>(jpr-full-diff)` -> `require("jpr").action("full_diff")` and `<Plug>(jpr-toggle-viewed)` -> `require("jpr").action("toggle_viewed")` in `"n"` mode.
5. `lua/jpr/init.lua`:
   - Add `full_diff = "gF"` and `toggle_viewed = "gv"` to `M.defaults.keys`.
   - Add `is_stream_visible` in `build_tui_context`.
   - In `M.bind_buffer_keys(buf)`: map `keys.full_diff` and `keys.toggle_viewed` in `"n"` mode.
   - Add `M.bind_tab_aware_full_diff_key(buf)`: binds `keys.full_diff` with `expr = true` on non-changed normal worktree buffers entered in a review tab so it returns `"<Plug>(jpr-full-diff)"` when `package.loaded["jpr.session"] and require("jpr.session").current() ~= nil` and falls back to literal `keys.full_diff` otherwise.
   - Add `full_diff` and `toggle_viewed` entries in `M.action(name)`.
6. `lua/jpr/session/commands.lua`: implement `session_mod.toggle_viewed_current()` routing panel -> `panel.toggle_viewed_under_cursor`, stream -> `stream.toggle_viewed`, and changed file / split base buffer -> `setViewed` with stale-navigation guard (`is_still_showing_path` check before calling `panel.advance_after_viewed(session, updated_view, { path }, { focus_next = true })` when `target_viewed == true`).
7. `lua/jpr/views/diff/init.lua`: call `require("jpr").bind_buffer_keys(buf)` BEFORE `if diff.binary then` return; in `M.reconcile(session)`, for windows in `session.tab` showing a normal worktree file (`buftype == ""`) that is not a changed file, call `require("jpr").bind_tab_aware_full_diff_key(buf)`.
8. `lua/jpr/views/panel.lua` and `lua/jpr/views/conversation.lua`: bind configured `keys.full_diff` (`<Plug>(jpr-full-diff)`) on panel and conversation buffers, and configured `keys.toggle_viewed` (`<Plug>(jpr-toggle-viewed)`) on panel buffers when distinct from `"v"`.
9. `lua/jpr/views/cheatsheet.lua`: update panel `v` copy to `"Toggle file or directory viewed"`, add dynamic `configured.full_diff` (`"Return to full branch diff view"`) and `configured.toggle_viewed` (`"Toggle viewed for current file"`) entries in `Diff & Stream Views`.

- [ ] **Step 4: Run all Lua specs to verify they pass**

Run: `./scripts/test-lua.sh`
Expected: PASS across every Lua spec file.

- [ ] **Step 5: Commit Task 6**

```bash
git add plugin/jpr.lua lua/jpr tests/lua
git commit -m "feat(nvim): add Full Branch Diff palette filter, :Jpr full, gF, and gv"
```

---

### Task 7: Documentation & Full Workspace Verification

help-me-pick: implement L1 (hours=0.5 cause=known material=familiar stakes=none verified=yes)

High-risk: no

**Files:**
- Modify: `docs/protocol.md`
- Modify: `docs/architecture.md`
- Modify: `docs/decisions.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: all finalized interfaces from Tasks 1-6.
- Produces: up-to-date project documentation and verified green `just check`.

- [ ] **Step 1: Update `docs/protocol.md`, `docs/architecture.md`, `docs/decisions.md`, and `README.md`**

1. `docs/protocol.md`: update heading to `(version 10)`, update `initialize` response example to `protocolVersion: 10`, document `setViewed` accepting `{ "path": string, "viewed": bool }` or `{ "paths": string[], "viewed": bool }`, and add the **Version 10** bullet under `## Versioning`.
2. `docs/architecture.md`: update `PROTOCOL_VERSION = 10`, note `set_viewed_paths` / aliased GraphQL batching in `review-core` / `review-forge-github`, note `full` alias and conditional `Full Branch Diff` palette visibility (`command.when`), single-line `foldtext()` viewed-file collapsing in `jpr.views.stream`, recursive directory `v` + next-file advancement in `jpr.views.panel`, and `gF` / `gv` keybindings.
3. `docs/decisions.md`: record the decision rationale for parameterized aliased GraphQL batching (50-file chunks), single-line `foldtext()` collapsing (preserving `zo` without a 2-line banner), and auto-advancing to the next unviewed file on mark-viewed.
4. `README.md`: update `setup({ keys = { ... } })` example with `full_diff = "gF"` and `toggle_viewed = "gv"`, document `:Jpr full` alias for `:Jpr stream` (`Full Branch Diff`), update sidebar `v` to file or directory recursively, and add `gF` and `gv` to the buffer-local keys table.

- [ ] **Step 2: Verify zero em dashes in changed docs and run full `just check`**

Run: `just check`
Expected: PASS (`cargo fmt --check`, `cargo clippy --workspace --all-targets --all-features -- -D warnings`, `cargo test --workspace --all-features`, and `./scripts/test-lua.sh` all green).

- [ ] **Step 3: Commit Task 7**

```bash
git add docs/protocol.md docs/architecture.md docs/decisions.md README.md
git commit -m "docs: document full diff navigation, single-line folds, and directory viewed toggling"
```

---

## Final Review

help-me-pick: bug-hunting-and-code-review L3 (hours=3 cause=unknown material=familiar stakes=high verified=yes)

After Task 7 passes `just check`, run the repository's mandatory completion sequence on `feat/full-diff-and-viewed`:
1. Run `/avandar-code-review`, fix any findings, re-verify with `just check`, and commit.
2. Run full `/diff-review` (Initial mode, never walkthrough-only), copy `.difit/<stem>-walkthrough.md` to `docs/code-walkthroughs/2026-11-25_full-diff-and-viewed.md`, and commit.
