# Track 1 Design: Menu-Style Collapsible Sidebar, Inline LSP File Ops, Immediate Worktree Diff Merging, and `<leader>gj` (`0.6.0`)

## Intent and Why

During PR review in Neovim, the left sidebar currently behaves like a plain read-only text buffer: horizontal cursor keys (`h`/`l`/`w`/`$`) wander across filenames and diff stats, directories cannot be collapsed or expanded, and renaming, moving, or creating files requires leaving the review sidebar for another file manager (and then waiting for a push before those files appear in the PR sidebar or diff stream).

This design upgrades `jpr-nvim` to `0.6.0` (`PROTOCOL_VERSION = 7`) so the PR sidebar feels like a crisp, vertical-only menu with collapsible directories, supports inline file/directory rename/move (`r`) and creation (`a`) with live path-resolution hints and automatic LSP import updates, immediately reflects local worktree additions/renames/edits in the sidebar and diff stream, and binds `<leader>gj` to bare `:Jpr` in personal Neovim configuration.

Track 2 (`0.7.0`, separate spec) will build directly on this engine worktree-diff foundation to add current-worktree local reviews, active PR auto-detection, and local-to-PR linking.

## Goals

1. **Menu-style vertical-only left sidebar:** Eliminate horizontal cursor wandering in `jpr://panel/<n>` so navigating the sidebar feels like the `:Jpr` Command Palette (`j`/`k` navigate selectable rows, `h`/`<Left>` collapses directories or jumps to parent, `l`/`<Right>` expands directories or opens files/Conversation, `o` opens files/Conversation or expands a collapsed directory and is a no-op on an already-expanded directory).
2. **Inline rename/move (`r`) and create (`a`) directly under the hovered row:** Open a compact floating input box anchored underneath the target sidebar row with smart path syntax (plain name = sibling/child; path with `/` = relative to project/worktree root with an immediate live notice; `../` or `./` = relative to the target's directory), automatic intermediate directory creation (`mkdir -p`), and worktree-boundary enforcement.
3. **Automatic LSP import updates on rename/move:** Invoke standard Neovim LSP `workspace/willRenameFiles` (applying returned `WorkspaceEdit`s and saving edited buffers) and `workspace/didRenameFiles` (plus `willCreateFiles`/`didCreateFiles` on create) without requiring third-party file-operation plugins.
4. **Immediate sidebar and diff-stream reflection of local changes:** Merge local uncommitted/untracked changes against merge-base into the engine's effective file list so newly created, renamed, or edited files appear immediately in the sidebar and diff views after `r`/`a` (via a fast `refreshWorktree` RPC) and on background worktree polls.
5. **Global shortcut `<leader>gj` for bare `:Jpr`:** Wire `<leader>gj` in the personal Neovim configuration (`jpsyx-configs`) through `commands.yaml` and `lua/plugins/jpr.lua` (lazy-loaded on `<leader>gj` and `:Jpr`).
6. **Cheatsheet and catalog parity:** Keep `:Jpr keys` (`lua/jpr/views/cheatsheet.lua`), `docs/`, and `jpsyx-configs` `commands.yaml` accurate for all new sidebar shortcuts.

## Non-Goals

- Current-worktree local-only review (without a PR), active PR auto-detection on current branch, and local-to-PR upgrade with authoritative local viewed marks (deferred to Track 2, `0.7.0`).
- File deletion (`d`), copy/paste, or bulk multi-file rename inside the sidebar.
- Showing unchanged repository files in the review sidebar (the sidebar remains scoped to files changed vs. the PR merge-base, including newly added/renamed local files).
- Mutating GitHub PR file lists before `:Jpr push` (local-only worktree additions/renames live in the local view until pushed).

## Anti-Goals

- Depending on `nvim-file-operations` or `oil.nvim` inside the public `jpr-nvim` plugin.
- Leaving stale or mismatched Neovim buffers open at old paths after a file or directory rename.
- Allowing rename/create targets to escape the worktree root via `..`, absolute paths, or symlinks.
- Sending `setViewed` mutations to GitHub for local-only files that GitHub's PR does not yet know about (which would poison the viewed queue with perpetual rejections).

## Constraints

- **Dependency rule:** `crates/review-*` crates remain strictly UI-free (`crates/jpr-review/tests/dependency_rule.rs`).
- **Interactive Command Palette & Schema-to-TUI invariant:** No new `:Jpr` subcommands are required for Track 1 (all new actions are sidebar buffer keymaps plus `<leader>gj` opening bare `:Jpr`), and existing schema tests continue passing.
- **Code style:** Zero em dashes across code, comments, tests, and docs; functions `<= 45` lines; source and test files `<= 400` lines; Red/Green TDD; `just check` green.
- **Lockstep release & protocol:** Bump `Cargo.toml` and `lua/jpr/init.lua` to `0.6.0`, and `PROTOCOL_VERSION` in `crates/review-rpc/src/protocol.rs` and `lua/jpr/rpc.lua` to `7`.

## Approaches

Three implementation approaches were evaluated and presented:

| Approach | Summary | Trade-offs |
| --- | --- | --- |
| **1. Native LSP + instant `refreshWorktree` RPC (Chosen)** | Implement `workspace/willRenameFiles`/`didRenameFiles` and `willCreateFiles`/`didCreateFiles` directly via `vim.lsp.get_clients()` in `jpr-nvim` (auto-attaching LSP on demand when no client is attached yet); merge local worktree diff files against merge-base in `review-core` and expose `refreshWorktree` (`PROTOCOL_VERSION = 7`) so `r`/`a` refresh the sidebar and stream immediately. | Zero external plugin dependencies, instant feedback after `r`/`a`, and establishes the reusable worktree-diff merging machinery in `review-core` for Track 2. Costs a clean protocol bump (`v6` -> `v7`). |
| **2. Native LSP + existing 2 s poller (Rejected)** | Same Lua sidebar and native LSP file operations, but rely solely on `poll_worktree_files`'s 2-second ticker to discover renamed/created files. | Avoids bumping `PROTOCOL_VERSION`, but creates up to a 2-second lag between pressing Enter on `r`/`a` and seeing the change in the sidebar. |
| **3. Delegate to `nvim-file-operations` (Rejected)** | Call `require("nvim-file-operations").rename()` when installed, falling back to `vim.uv.fs_rename`. | Breaks self-contained behavior for public `jpr-nvim` users, does not handle cold-start LSP attachment when no buffer of that language is open yet, and removes control over timeout/autosave behavior. |

Approach 1 was selected because instant UI feedback, self-contained LSP support, and shared `review-core` worktree diffing directly serve both Track 1 and Track 2.

---

## Detailed Design

### 1. Menu-Style Collapsible Left Sidebar (`lua/jpr/render/panel.lua`, `lua/jpr/views/panel.lua`)

#### Tree Representation & Collapse State
- `session.panel` tracks `collapsed_dirs = {}` (set keyed by canonical worktree-relative directory path without trailing slash, e.g., `"src"`, `"src/core"`, `"docs/x"`).
- `render.build(view, now, opts)` accepts optional `opts = { collapsed_dirs = table<string, boolean>, selected_line = integer|nil }`:
  - Walks `view.tree` (produced by `review_core::tree::create_file_tree_from_paths`) maintaining a `(depth, full_path)` stack so every directory row gets its canonical `dir_path` (handling lone-child joined names like `docs/x` seamlessly).
  - Precomputes the total descendant file count for each directory row so a collapsed directory displays a subtle count suffix (e.g., `▸ tests/ (3)`).
  - When `collapsed_dirs[dir_path]` is true, renders the directory with `▸ ` (`JprMuted`), skips all subsequent tree rows whose `depth > dir_row.depth`, and records `rows[line_1based] = { kind = "dir", path = dir_path, depth = row.depth, parent_dir = parent_dir_path, is_collapsed = true }`.
  - When expanded, renders the directory with `▾ ` (`JprMuted`) and records `rows[line_1based] = { kind = "dir", path = dir_path, depth = row.depth, parent_dir = parent_dir_path, is_collapsed = false }`.
  - File rows record `rows[line_1based] = { kind = "file", path = file.path, depth = row.depth, parent_dir = parent_dir_path }`, and `paths[line_1based] = file.path` stays populated for backwards compatibility with existing callers/specs.
  - When `file.isLocalOnly == true`, append a subtle `[local]` badge (highlighted `JprThreadLocal`) after the diff stats/threads badge so the reviewer can distinguish unpushed local files from files already on the GitHub PR (even after committing locally before `:Jpr push`).
  - The Conversation row records `rows[conversation_line] = { kind = "conversation" }`.
  - Returns `{ lines, highlights, paths, rows, selectable_lines, conversation_line }`, where `selectable_lines` is the ordered list of 1-based line numbers for `Conversation` and every visible directory/file row.

#### Menu-Style Vertical-Only Navigation
- **Cursor clamping:** A buffer-local `CursorMoved` autocmd in `jpr://panel/<n>` clamps the cursor to column `0` and, if the cursor lands on a non-selectable header/progress/blank line (lines `1..conversation_line - 1`), snaps it to the first selectable line (`conversation_line`).
- **Disabled horizontal motions:** Buffer-local Normal-mode no-ops on `0`, `^`, `$`, `w`, `W`, `b`, `B`, `e`, `E`, `ge`, `gE`, `f`, `F`, `t`, `T`, `;`, `,` prevent horizontal wandering or accidental sideways scrolling (`sidescrolloff = 0` window-local on the panel).
- **Navigation keys:**
  - `j` / `<Down>`: move to next line in `selectable_lines` (stay on last item at bottom).
  - `k` / `<Up>`: move to previous line in `selectable_lines` (stay on first item `Conversation` at top).
  - `gg` / `<Home>`: jump to first selectable item (`Conversation`).
  - `G` / `<End>`: jump to last selectable item.
  - `h` / `<Left>`:
    - On an **expanded directory**: set `collapsed_dirs[row.path] = true`, re-render, keep cursor on that directory row.
    - On a **collapsed directory** or a **file** with a `parent_dir`: jump cursor to that parent directory's row.
    - On a top-level file, top-level collapsed dir, or `Conversation`: no-op.
  - `l` / `<Right>`:
    - On a **collapsed directory**: clear `collapsed_dirs[row.path] = nil`, re-render, keep cursor on that directory row.
    - On an **expanded directory**: move cursor down one row to its first child (no-op if none).
    - On a **file** or `Conversation`: open it in the main window (identical to `<CR>` and `o`).
  - `o`:
    - On a **collapsed directory**: expand it (`collapsed_dirs[row.path] = nil`) and re-render.
    - On an **already-expanded directory**: **no-op** (explicitly does nothing).
    - On a **file** or `Conversation`: open it in the main window.
  - `<CR>`:
    - On a **collapsed directory**: expand it (`collapsed_dirs[row.path] = nil`) and re-render.
    - On an **expanded directory**: collapse it (standard toggle on Enter, while `o` stays strictly expand-only/no-op-when-open as requested).
    - On a **file** or `Conversation`: open it in the main window.
  - `v`: toggle viewed on a file row (no-op on directory/Conversation rows; for local-only files not yet on GitHub, updates local viewed state without queueing a GitHub mutation).
  - `r`: open inline rename/move input box under the hovered file or directory row (no-op on Conversation).
  - `a`: open inline create file/directory input box under the hovered row.
  - `?`: open `:Jpr keys` cheatsheet modal.
- **Cursor preservation across re-renders:** When `M.render` redraws after an engine event or collapse/expand, restore the cursor to the same `row.path` (or `Conversation`, or nearest valid selectable row) at column `0`.

---

### 2. Inline Rename/Move (`r`) and Create (`a`) Input Box & Path Rules (`lua/jpr/views/panel_input.lua`)

#### Anchored Floating Input UI
- Pressing `r` (on a file or directory row) or `a` (on any selectable row) opens a compact, rounded-border floating window (`filetype = "jpr-panel-input"`) anchored directly underneath the hovered row in `panel.win`:
  - Uses `relative = "win"`, `win = panel.win`, `row = (cursor_line - topline) + 1`, `col = 0`, `height = 1` (plus 1-2 virtual lines below for the live path-resolution hint and optional validation error), `width = math.max(panel_width, 46)` clamped within the editor viewport.
  - If the hovered row is on the bottom-most visible row of `panel.win`, anchor immediately above the row (`row = cursor_line - topline - 1`) so the float never clips off-screen.
  - Starts in Insert mode (`startinsert!`):
    - **`r` (Rename / Move):** Title `" Rename · <basename> "` (or `" Rename dir · <name> "`), prefilled with the item's basename (for a lone-child joined dir row like `docs/x`, prefill `"x"` with current parent `"docs"`, targeting `docs/x`).
    - **`a` (Create):** Title `" New file or dir (trailing / for dir) "`, empty initial text.
  - Keybindings inside the float:
    - `<CR>` (Insert & Normal): validate and execute.
    - `<Esc>` (Insert -> Normal; Normal -> close/cancel) and `q` (Normal -> close/cancel).
    - `BufLeave` / `WinClosed` cleanup guards ensure no dangling float remains if the user switches windows.

#### Path Resolution Rules (Pure Module `lua/jpr/views/panel_paths.lua`)
Given `(raw_input, context)` where `context = { mode = "rename" | "create", worktree = string, current_dir = string, target_path = string|nil }`:
- For `mode == "rename"`, `current_dir` is the parent directory of `target_path` (`""` when at worktree root).
- For `mode == "create"`, `current_dir` is `row.path` when hovering a directory row, the parent directory of `row.path` when hovering a file row, or `""` when hovering `Conversation`.
- Trim leading/trailing whitespace; reject empty input, `"."`, `".."`, leading `"/"`, `NUL`, or newlines.
- Detect trailing `"/"` in `create` mode -> `is_directory = true` (strip trailing slashes for normalization). Reject trailing `"/"` in `rename` mode unless renaming a directory (strip trailing slash cleanly).
- **Path-base rule:**
  1. **Starts with `"../"` or `"./"`:** Resolve **relative to `current_dir`** (collapsing `.` and `..` segments cleanly). If `..` climbs above the worktree root, return a validation error (`"Path escapes the worktree root"`). Mode tag: `"current_dir"`.
  2. **Contains `"/"` anywhere else (e.g., `"some/new/path/module.ts"`):** Resolve **relative to the project/worktree root** (`""` base). Mode tag: `"project_root"`.
  3. **Contains no `"/"` (plain name, e.g., `"utils.ts"`):** Resolve **relative to `current_dir`** (in-place rename or sibling/child creation). Mode tag: `"same_dir"`.
- Normalize segments, forbid `.git` path components and any segment resolving outside `worktree` via symlinks (reusing `jpr.views.diff.name_to_relative_path` boundary checks).
- **Live helper text (updated on `TextChangedI` / `TextChanged`):**
  - `mode_tag == "project_root"`: `"Path is relative to project root -> <resolved_path>"` (highlighted `JprHunk` / `JprTitle` so the user notices immediately as soon as they type `/`).
  - `mode_tag == "current_dir"`: `"Path is relative to current directory -> <resolved_path>"` (`JprMuted`).
  - `mode_tag == "same_dir"`: shows target preview `"-> <resolved_path>"` (`JprMuted`).
  - Validation error (empty, escapes root, destination already exists, renaming dir into itself): shows inline red `JprError` text and keeps the float open for correction.

---

### 3. Native LSP File Operations (`lua/jpr/lsp_files.lua`)

A self-contained module with zero third-party plugin dependencies:

#### Rename / Move (`M.rename(old_abs, new_abs, opts)`)
1. **Validation & directory preparation:** Refuse if `old_abs == new_abs`, if `old_abs` does not exist, if `new_abs` already exists (note: handle case-only renames on case-insensitive macOS APFS via `fs_stat` inode comparison so `Foo.ts` -> `foo.ts` works cleanly!), or if moving a directory inside itself.
2. **Ensure LSP client availability (cold-start support):**
   - Collect active LSP clients from `vim.lsp.get_clients()` that support `workspace.fileOperations.willRename` (matching `filters` if present) and whose root covers `old_abs` or `new_abs`.
   - If NO matching LSP client is attached yet and `old_abs` is a regular file (not a directory), briefly load `old_abs` into an unlisted hidden buffer (`bufload`), wait up to `config.lsp_attach_timeout_ms` (default `3000` ms) with `vim.wait` for a `willRename`-capable client to attach (displaying `"Waiting for LSP to attach..."` via non-intrusive echo), and clean up the temporary hidden buffer afterward if it was not previously open.
3. **Request `workspace/willRenameFiles`:**
   - Show non-intrusive status `"Updating imports via LSP..."`.
   - For each matching client, call `client:request_sync("workspace/willRenameFiles", { files = { { oldUri = vim.uri_from_fname(old_abs), newUri = vim.uri_from_fname(new_abs) } } }, config.lsp_file_ops_timeout_ms)` (default `30000` ms, matching `oil.lua` for large TypeScript workspaces).
   - **Timeout / error policy (our call):** Collect responses from all matching clients before applying any `WorkspaceEdit`. If any client times out or returns an LSP error, do NOT silently half-apply edits or silently break imports: warn with the failing client name and prompt via `vim.ui.select` (`"Proceed with rename without full LSP import updates"` vs. `"Cancel rename"`; default/cancel if dismissed). Only apply collected `WorkspaceEdit`s and run `fs_rename` after either all clients succeed or the user explicitly confirms proceeding.
   - If the response contains a `WorkspaceEdit`, apply it with `vim.lsp.util.apply_workspace_edit(edit, client.offset_encoding)` and record every modified buffer so it is written (`:silent update`) after the rename completes (autosaving buffers modified by the `WorkspaceEdit` that were clean prior to the edit, and notifying if any pre-dirty buffer needs manual save).
4. **Filesystem move:**
   - Ensure parent directory of `new_abs` exists (`vim.fn.mkdir(parent, "p")`).
   - Execute `vim.uv.fs_rename(old_abs, new_abs)`. (If `old_abs` and `new_abs` differ only in case on APFS, `vim.uv.fs_rename` handles it cleanly, or two-step temp rename if needed.)
5. **Update open Neovim buffers:**
   - For a file rename: find any valid buffer whose real/normalized path equals `old_abs`, rename the buffer (`nvim_buf_set_name(buf, new_abs)`), and reload/re-mark unmodified cleanly (`:silent edit!` if unmodified, or update name preserving modified lines if dirty).
   - For a directory rename: update every valid open buffer whose path begins with `old_abs .. "/"` to the corresponding path under `new_abs .. "/"`.
6. **Notify `workspace/didRenameFiles`:**
   - Send `client:notify("workspace/didRenameFiles", { files = { { oldUri = ..., newUri = ... } } })` to every matching client supporting `didRename`.
7. **Refresh engine & migrate local metadata:** Trigger `refreshWorktree` RPC on `session` with `renames = { { oldPath = old_rel, newPath = new_rel } }` so the engine immediately migrates any `Origin::Local` thread anchors and `local_viewed` marks under `old_rel` (exact file or directory prefix) to `new_rel` and redraws the sidebar, diff overlays, and stream right away.

#### Create (`M.create(target_abs, is_directory, opts)`)
1. Refuse if `target_abs` already exists.
2. If `is_directory`: `vim.fn.mkdir(target_abs, "p")`, refresh worktree, and notify `"Created directory <rel>"` cleanly (git does not track empty directories in diffs).
3. If regular file:
   - Request `workspace/willCreateFiles` on matching attached clients; if a client times out or errors, warn and proceed with creation (creating an empty file cannot break existing imports). Apply any returned `WorkspaceEdit`s cleanly.
   - `vim.fn.mkdir(parent_dir, "p")` and create the empty file (`vim.uv.fs_open(..., "w", 438)` + `fs_close`).
   - Send `workspace/didCreateFiles` to matching clients.
   - Trigger `refreshWorktree` RPC (`{}`) immediately and open the new file in `main_window`.

---

### 4. Engine Immediate Worktree Diff Merging & `refreshWorktree` RPC (`0.6.0`, `PROTOCOL_VERSION = 7`)

#### Effective File List in `crates/review-core`
- Currently, `ReviewSession` serves `self.saved.files` (from GitHub) in `view()`, `file_diff()`, and `stream_with_progress()`.
- Add a cached local-worktree delta in `ReviewSession` (`local_files: Vec<ChangedFile>`, refreshed during `sync()`, `poll_worktree_files()`, and the new `refresh_worktree()`):
  - When `self.prepare_base()` succeeds (we have a valid `merge_base`), call `self.ports.workspace.list_changed_files_since(&merge_base)`.
  - For any path returned by `list_changed_files_since` that is **not** in `self.saved.files`:
    - Compute `(additions, deletions)` using `review_diff` (comparing `base_text` at `merge_base` against `file_on_disk`, respecting `MAX_DIFF_BYTES` and binary checks; binary/oversized files get `0/0`).
    - Look up any remembered local viewed state for that path (`local_viewed: BTreeMap<String, ViewedState>`, persisted in `local.json` so local viewed marks survive restarts and prepare directly for Track 2).
    - Include it in `effective_files` with `is_local_only = true` (new `#[serde(default)] pub is_local_only: bool` field on `FileRow` in `review-model/src/view.rs`, so Lua knows whether a file is local-only vs. known to GitHub).
  - For any path in `self.saved.files` that has local edits (e.g., modified or renamed away on disk):
    - Keep it in `effective_files` with `is_modified = true` (already computed from `worktree_status.modified_paths`) and live disk-vs-merge-base diffing when opened!
    - Note: if a PR file was renamed locally (`old.ts` -> `new.ts`), `old.ts` stays visible as modified/deleted on disk until pushed, and `new.ts` appears immediately with its full diff against `merge_base` (and `renames()` in `BaseCache` is invalidated whenever `refresh_worktree` / `poll_worktree_files` detects changed paths, so git's `-M` rename detection pairs `new.ts` with `old.ts`'s base text when staged or shows `new.ts` cleanly!).
- **Viewed marks on local-only files (`crates/review-core/src/session/viewed.rs` & `sync.rs`):**
  - When `set_viewed(path, viewed)` is called on a `path` present in `self.saved.files`: existing GitHub behavior is 100% unchanged.
  - When `set_viewed(path, viewed)` is called on a **local-only** file (`!saved.files.contains(path)` and `local_files.contains(path)`): update `local_viewed` in `local.json`, emit `Event::ViewedChanged`, and **do NOT** send or queue a GitHub `setViewed` mutation (preventing GitHub 422 rejections for unpushed paths).
  - **Local edit dismissal (our call):** When `poll_worktree_files` detects a content digest change on a local-only file whose `local_viewed` state is `VIEWED`, transition it to `DISMISSED` (mirroring GitHub's viewed-dismissal semantics).
  - **Promotion on push/sync:** When a previously local-only file appears in `self.saved.files` during `sync()` (e.g., after `:Jpr push`) and its `local_viewed` entry is `VIEWED`, promote it by inserting `(path, true)` into `queued_viewed` and removing it from `local_viewed` so `apply_queued` keeps it `VIEWED` immediately and `send_queued` marks it viewed on GitHub. Drop `local_viewed` entries for non-`VIEWED` adopted files or paths no longer changed.
- **Comments, pre-pass, and suggestions on local-only files (our call):**
  - Split anchor-file validation in `crates/review-core/src/session/comments/helpers.rs` by origin: `Origin::Local` comments and `prepassWrite` validate against `effective_files` (both PR files and local-only files), while `Origin::Github` comments, `promoteThread`, and `:Jpr suggest` remain restricted to `self.saved.files` with a clear error (`"Push this file to GitHub before adding GitHub comments"`).
  - In `lua/jpr/comments/compose.lua`, when opening a compose box for a file with `isLocalOnly == true`, default `destination` to `"local"`, disable `<C-g>` / `<M-s>` flipping to `"github"`, and show `"local only (unpushed file)"` in the compose footer.
- **Diff serving (`crates/review-core/src/session/diffs.rs`):**
  - `file_texts(path)` allows any path present in `effective_files` (either `self.saved.files` or `self.local_files`), while still enforcing `GitWorkspace` path-safety rules so arbitrary paths outside the diff remain refused.
  - `stream_with_progress` iterates `effective_files`.
  - Invalidate `base_cache.renamed_from` on `refresh_worktree` / `poll_worktree_files` when files change so newly renamed files resolve against their base cleanly.
- **New RPC method `refreshWorktree` (`crates/review-rpc/src/server.rs`, `PROTOCOL_VERSION = 7`):**
  - Request: `{ "jsonrpc": "2.0", "id": N, "method": "refreshWorktree", "params": { "renames"?: [{ "oldPath": string, "newPath": string }] } }` (empty `{}` is valid).
  - Handler calls `session.refresh_worktree(&renames)`:
    1. If `renames` is non-empty, migrates matching `Origin::Local` thread anchors (`anchor.file == oldPath` or directory prefix `oldPath/` -> `newPath/...`) and `local_viewed` keys, saving `local.json` and emitting `Event::ThreadsChanged` if any threads moved.
    2. Refreshes `local_files`, `base_cache.renamed_from`, `disk_digests`, and `worktree_status`, re-anchoring affected local threads and emitting `Event::FilesChanged` / `Event::WorktreeStatusChanged` if anything changed.
    3. Returns the updated `SessionView`.
  - Note: `review-store-fs` `local.json` adds an optional `#[serde(default)] local_viewed: BTreeMap<String, ViewedState>` field while staying backward-compatible with existing v1 `local.json` files (existing files without the field deserialize cleanly to an empty map).

---

### 5. `<leader>gj` Shortcut & Neovim Config Updates (`jpsyx-configs`)

After `jpr-nvim` `0.6.0` is merged and pushed (post-approval):
- In `jpsyx-configs/home/.config/nvim/commands.yaml`:
  - Add `keys: ["<leader>gj"]` and `modes: ["n"]` to `jpr-nvim-jpr` (or a dedicated catalog entry matching `jpr-nvim-jpr`) so `<leader>gj` opens bare `:Jpr`.
  - Update `jpr-panel` shortcuts in `commands.yaml` for `h`/`<Left>`, `l`/`<Right>`, `r` (rename/move), `a` (create), and `jpr-panel-input` modal keys.
- In `jpsyx-configs/home/.config/nvim/lua/plugins/jpr.lua`:
  - Wire `keys = catalog.lazy_keys("jpr-nvim", ...)` (or standard `keys` referencing `catalog.key(...)`) so pressing `<leader>gj` lazy-loads `jpr-nvim` and runs `:Jpr`.
- Update `jpsyx-configs/home/.config/nvim/docs/CHANGELOG.md` and `docs/plugins.md`, run `:Lazy! update jpr-nvim`, `jpsyx sync`, verify `:checkhealth jpr` (`0.6.0`) and `:CommandPaletteAudit`.

---

## Left to the Builder

- Exact module splitting under `lua/jpr/views/` and `crates/review-core/src/session/` to keep every file `<= 400` lines and every function `<= 45` lines.
- Exact highlight group choices for the inline input float border/title/hint (reusing existing `JprTitle`, `JprHunk`, `JprMuted`, `JprError` groups).
- Whether `local_files` stores a small cached struct alongside `disk_digests` or recomputes line counts lazily per changed path (caching counts keyed by `(path, disk_digest)` avoids re-diffing unchanged local files every 2 seconds).
- Exact headless Lua test fixtures for mocking `vim.lsp.get_clients()` `request_sync` / `notify` and verifying `WorkspaceEdit` application, buffer renaming, and directory renaming.
