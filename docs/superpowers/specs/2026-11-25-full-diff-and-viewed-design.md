# Full Branch Diff Navigation, Single-Line Collapsed Viewed Files, and Directory Viewed Toggling Design

## Intent and Why

Reviewing a pull request in `jpr-nvim` starts in the full branch diff view (`jpr://stream/<n>`), where all changed files appear in one continuous scroll with viewed files collapsed. Once a reviewer opens an individual file to inspect or edit it, returning to that full branch diff view currently requires knowing the internal `:Jpr stream` command name, because the Command Palette labels it `"Open Stream View"`, shows it even when already viewing the stream, and provides no keyboard shortcut back.

At the same time, marking work as viewed has three friction points:

1. **Returning to full view:** Reviewers need an obvious Command Palette command (shown only when no longer in the full diff view), a `:Jpr full` alias, and a `gF` buffer shortcut alongside `gf` (`file_comment`) and `gc`/`gC`.
2. **Marking viewed from any diff view or directory:** `v` toggles a single file in the sidebar or stream, and `gv` should toggle the current file from single-file editor buffers, split base buffers, and the full diff view; in the sidebar, `v` (and `gv`) on a directory should recursively toggle all changed files under that directory.
3. **Clean collapsed headers and live stream updates:** Collapsed viewed files in the full branch diff view should render as a single clean header line (`▸ ✓ path  +N -M`) showing only the file name and `+/-` counts (with `zo` still expanding the diff in place, without Neovim's extra `+-- N lines` fold banner), and any viewed/unviewed change while the full diff view is visible must immediately collapse newly viewed files and expand newly unviewed ones.

## Goals, Non-Goals, and Anti-Goals

- **Goals:**
  - Relabel `:Jpr stream` in the Command Palette to `"Full Branch Diff"` (`[stream]`), add `full = "stream"` to `COMMAND_ALIASES` (`:Jpr full`), and hide `stream` from the interactive Command Palette when the full branch diff view is already visible.
  - Add configurable `gF` (`keys.full_diff`, `<Plug>(jpr-full-diff)`) to return to and focus the full branch diff view from review buffers (changed text and binary files, split base buffers, unchanged worktree files visited in the review tab, PR conversation, sidebar panel, and stream).
  - Add configurable `gv` (`keys.toggle_viewed`, `<Plug>(jpr-toggle-viewed)`) in Normal mode:
    - In single-file editor buffers (and split base buffers, including binary changed files): toggle the current file's viewed state; when marking it **viewed**, automatically advance to the next unviewed file in the review (or return to the full branch diff view with an `"all files viewed"` notice when no unviewed files remain); when marking it **unviewed**, stay in the open file buffer.
    - In the full branch diff view: toggle the file section under the cursor and jump to the next unviewed file when marking viewed (staying put when unmarking, matching `v`).
    - In the sidebar panel: toggle the file or recursive directory under the cursor (matching `v`); if the main window is currently displaying a single file that was just marked viewed (and the full diff view is not visible), advance the main window to the next unviewed file (or full branch diff when none remain) while keeping sidebar focus.
  - Support recursive directory viewed toggling on `v` (and `gv`) in the sidebar panel: if any descendant changed file under `dir/` is not `VIEWED`, mark all descendant files `VIEWED`; if all descendant files are already `VIEWED`, mark all of them `UNVIEWED`.
  - Execute multi-file viewed updates in a single batched Rust engine call (`setViewed` with `paths`) backed by parameterized aliased GitHub GraphQL mutations (chunked at 50 paths per request), saving store state once and emitting a single `viewedChanged` event.
  - Collapse viewed files in the full branch diff view onto a single header line (`▸ ✓ path  +N -M`) with no `+-- N lines` banner below it while preserving `zo`/`zc` manual fold inspection, and repaint any visible full diff view on `viewedChanged` to collapse newly viewed files and expand newly unviewed ones.
- **Non-Goals:**
  - Changing the Rust CLI `jpr-review` subcommand surface or TUI command schema (`viewed` remains a JSON-RPC session mutation).
  - Auto-closing or deleting buffers from Neovim's buffer list when advancing to the next unviewed file (simply switches the main window to the next file or full diff view).
- **Anti-Goals:**
  - Sending N sequential `gh api graphql` subprocess calls, N disk writes, and N full-diff stream redraws when toggling a directory.
  - Interpolating untrusted PR file paths directly into GraphQL query source strings (always pass paths as GraphQL variables).
  - Hijacking `gF` or `gv` in buffers outside an active `jpr` review tab.

## Constraints

- **Dependency & logic placement rule:** Generic crates (`crates/review-*`) remain completely UI-free. Multi-path viewed validation, mixed linked-PR + local-only file handling, queue updates, and single-event announcement live in `review-core`; parameterized GraphQL batching lives in `review-forge-github`.
- **Protocol versioning:** Changing `setViewed` request params bumps `PROTOCOL_VERSION` from `9` to `10` in lockstep across `crates/review-rpc/src/protocol.rs`, `lua/jpr/rpc.lua`, `tests/lua/fixtures/fake_engine.sh`, `docs/protocol.md`, and `docs/architecture.md`.
- **Schema-to-TUI invariant:** All 16 `:Jpr` commands remain declared in `lua/jpr/commands/schema.lua` with human-readable labels, `[<id>]` badges, concise helper text, and full non-interactive `:Jpr <subcommand>` parity; `full` is registered in `COMMAND_ALIASES` (not as a duplicate palette command).
- **Code style:** Zero em dashes anywhere in code, comments, tests, or docs; functions `<= 45` lines; descriptive variable and builder names; red/green TDD; `just check` green.

## Approaches Considered

| Approach | Summary | Trade-offs |
| --- | --- | --- |
| **1. Batched Rust Engine + Parameterized Aliased GraphQL Mutation (Chosen)** | Extend `setViewed` (protocol v10) to accept `path` or `paths`, add `ReviewSession::set_viewed_paths` in `review-core` and `Forge::set_viewed_many` in `review-forge-github` using parameterized GraphQL aliases (`$p0`, `$p1`, ...), save once, and emit one `viewedChanged` event. | Marks an entire directory on GitHub in one `gh` round-trip (per 50-file chunk), writes disk state once, handles mixed PR + `[local]` directories atomically, and triggers a single sidebar + full-diff repaint. Requires bumping `PROTOCOL_VERSION` to `10`. |
| **2. Sequential Per-File `setViewed` Calls from Lua (Rejected)** | Keep protocol v9 unchanged and loop `setViewed` in Lua for every descendant file under a directory. | No Rust changes, but spawns N sequential `gh` processes (blocking the server thread for seconds on medium directories), writes 4 JSON files N times, and triggers N full-diff stream recomputations. |

Pablo selected **Approach 1**, along with advancing to the next unviewed file whenever a viewed file is marked done (never leaving the reviewer looking at a file they just marked viewed) and rendering collapsed viewed files in the full diff view as a single header line (`▸ ✓ path  +N -M`) with `zo` expand preserved.

---

## Detailed Design

### 1. Protocol v10 & Batched Rust Engine (`crates/review-core`, `crates/review-forge-github`, `crates/review-rpc`)

#### Wire Protocol (`crates/review-rpc/src/protocol.rs`, `crates/review-rpc/src/params.rs`, `crates/review-rpc/src/server.rs`)

- Bump `PROTOCOL_VERSION` from `9` to `10`.
- `setViewed` accepts either single-file or multi-file parameters:
  - `{ "path": "src/a.rs", "viewed": true }` (existing shape, preserved for single-file callers)
  - `{ "paths": ["src/a.rs", "src/sub/b.rs"], "viewed": true }` (non-empty string array)
- `get_viewed_paths_from_params(params)` validates that exactly one of `"path"` or `"paths"` is provided and returns a non-empty `Vec<String>`, returning `-32602` (`INVALID_PARAMS`) when neither, both, an empty `"paths"` array, or non-string elements are given.

#### Session Logic (`crates/review-core/src/viewed.rs`, `crates/review-core/src/session/viewed.rs`, `crates/review-core/src/ports.rs`)

- **Pure helpers (`crates/review-core/src/viewed.rs`):**
  - `is_path_in_directory(path: &str, dir: &str) -> bool`: returns `true` when `dir` (trimmed of trailing `/`) is non-empty and `path` starts with `"{dir}/"`.
  - `collect_directory_toggle_paths(files: &[ChangedFile], dir: &str) -> Option<(Vec<String>, bool)>`: collects all changed file paths under `dir`; returns `None` when none match, `(paths, true)` when any matching file has `viewed != ViewedState::Viewed`, and `(paths, false)` when all matching files are already `ViewedState::Viewed`.
- **Port trait (`crates/review-core/src/ports.rs`):**
  - Add `fn set_viewed_many(&self, pr: &PullRequest, paths: &[String], viewed: bool) -> Result<()>` to `Forge`, with a default implementation calling `self.set_viewed(pr, path, viewed)` sequentially so minimal fakes stay concise while `FakeForge` and `GhForge` implement batched behavior.
- **Session facade (`crates/review-core/src/session/viewed.rs`):**
  - `ReviewSession::set_viewed(&mut self, path: &str, viewed: bool)` delegates to `self.set_viewed_paths(&[path.to_owned()], viewed)`.
  - `ReviewSession::set_viewed_paths(&mut self, paths: &[String], viewed: bool) -> Result<SessionView>`:
    1. Reject empty `paths`. Deduplicate `paths` while preserving order.
    2. Classify each path against `self.saved.files` (when `self.is_linked()`, requiring `self.synced_pr()` first) or `self.local_files`. If any path is absent from both, bail with `"{path} is not a file changed in this review"` before mutating any state.
    3. Partition into linked PR paths and local-only worktree paths; set `target_state = viewed_flag_to_state(viewed)`.
    4. For linked PR paths: determine `forge_paths` whose remote sync is needed (paths where `file.viewed != target_state` or `queued_viewed` currently holds an entry for `path`), update `file.viewed = target_state` for all linked paths, and if `forge_paths` is non-empty call `self.ports.forge.set_viewed_many(&pr, &forge_paths, viewed)`:
       - On `Ok(())`: remove all `forge_paths` from `queued_viewed`.
       - On `Err(error)`: insert `(path, viewed)` into `queued_viewed` for each path in `forge_paths` and capture `auth_message` when `crate::is_auth_error(&error)`.
    5. For local-only paths: update `local_file.viewed = target_state` and `self.saved.local.local_viewed.insert(path, target_state)` without calling GitHub.
    6. Call `self.save_and_announce_viewed()` once (writing store files once and publishing one `Event::ViewedChanged`), then publish one `Event::SyncFailed { auth_required: true, is_background: false }` if `auth_message` is `Some`.

#### Parameterized Aliased GraphQL Batching (`crates/review-forge-github/src/graphql.rs`, `crates/review-forge-github/src/lib.rs`)

- Add pure builder `build_batch_viewed_mutation(paths: &[String], viewed: bool) -> (String, Value)`:
  - Declares `$pr: ID!` and `$p0: String!`, `$p1: String!`, ... in the mutation signature.
  - Emits aliased mutations `f0: markFileAsViewed(input: { pullRequestId: $pr, path: $p0 }) { clientMutationId }` (or `unmarkFileAsViewed` when `viewed == false`).
  - Populates `variables` JSON object with `"pr": pr.node_id` and `"p0": paths[0]`, `"p1": paths[1]`, ... so untrusted file paths never enter the GraphQL document text.
- `GhForge::set_viewed_many` returns `Ok(())` immediately on empty `paths`, delegates to `set_viewed` when `paths.len() == 1`, and executes `build_batch_viewed_mutation` in chunks of `50` paths when `paths.len() > 1`.

### 2. Command Palette Filtering, `:Jpr full` Alias, and `gF` / `gv` Shortcuts (`lua/jpr/`)

#### Command Schema & Conditional Palette Visibility (`lua/jpr/commands/schema.lua`, `lua/jpr/tui/schema.lua`, `lua/jpr/tui/wizard/palette.lua`, `lua/jpr/tui/render.lua`, `lua/jpr/init.lua`)

- **`COMMAND_ALIASES` (`lua/jpr/commands/schema.lua`):** Add `full = "stream"` so `:Jpr full` resolves to `stream` before dispatch without adding a duplicate palette entry.
- **Command spec (`lua/jpr/commands/schema.lua`):** Update `stream` spec to:
  - `label = "Full Branch Diff"` (`[stream]`)
  - `help = "Return to the full branch diff view showing all changed files in a continuous scroll."`
  - `when = function(context) return not (context and context.is_stream_visible == true) end` (compatible with executable-only palette `command.when(context)` predicates).
- **Schema predicate support (`lua/jpr/tui/schema.lua`, `lua/jpr/tui/wizard/palette.lua`):**
  - Validate optional `command.when` (`function`) in `validate_command_specs`.
  - Add pure `M.get_visible_commands(commands, context)` (or honor `command.when(context) ~= false` when `command.when` is present) in `palette.lua` before rendering and binding keys so `stream` is omitted from the floating Command Palette whenever `context.is_stream_visible == true`, while remaining directly invocable via `:Jpr stream`, `:Jpr full`, and `gF`.
- **Context snapshot (`lua/jpr/init.lua`):**
  - `build_tui_context` sets `is_stream_visible = current_session ~= nil and require("jpr.views.stream").is_visible(current_session) == true`.

#### Keybindings & Dispatch (`plugin/jpr.lua`, `lua/jpr/init.lua`, `lua/jpr/session/commands.lua`, `lua/jpr/views/diff/init.lua`, `lua/jpr/views/panel.lua`, `lua/jpr/views/conversation.lua`, `lua/jpr/views/cheatsheet.lua`)

- **Defaults (`lua/jpr/init.lua`):**
  - Add `full_diff = "gF"` and `toggle_viewed = "gv"` to `M.defaults.keys`.
- **`<Plug>` registrations (`plugin/jpr.lua`):**
  - `<Plug>(jpr-full-diff)` -> `require("jpr").action("full_diff")` (`session.stream_current()`)
  - `<Plug>(jpr-toggle-viewed)` -> `require("jpr").action("toggle_viewed")` (`session.toggle_viewed_current()`)
- **Buffer key attachment:**
  - `M.bind_buffer_keys(buf)` binds `keys.full_diff` (`"n"`) and `keys.toggle_viewed` (`"n"`) on stream buffers, split base buffers, and changed worktree file buffers.
  - In `lua/jpr/views/diff/init.lua`: call `require("jpr").bind_buffer_keys(buf)` **before** the `if diff.binary then` return so binary changed files also receive `gf`, `gF`, and `gv`. Also bind a tab-aware `keys.full_diff` on any normal worktree file buffer (`buftype == ""`) entered in `session.tab` that is not a changed file (falling back to native `gF` when invoked in a non-review tab), so reviewers who jump into an unchanged file via `gd` can still press `gF` to return to the full diff view.
  - In `lua/jpr/views/panel.lua` and `lua/jpr/views/conversation.lua`: bind `keys.full_diff` -> `<Plug>(jpr-full-diff)` (and on `panel.lua`, `keys.toggle_viewed` -> `<Plug>(jpr-toggle-viewed)` when distinct from `"v"`).
- **`session.toggle_viewed_current()` (`lua/jpr/session/commands.lua`):**
  - Resolves `session = session_mod.current()` (reporting `"no pull request is open in this tab"` when absent).
  - Routes by active window/buffer:
    1. Sidebar panel buffer -> `panel.toggle_viewed_under_cursor(session)`.
    2. Stream buffer (`main` or `left`) -> `stream.toggle_viewed(session)` (toggles the file section at the cursor; when marking viewed, jumps to the next unviewed file with wrap-around once redrawn; when unmarking, stays on the newly expanded file).
    3. Changed worktree file buffer or split base buffer (`vim.b[buf].jpr_base_path` or `diff.buffer_to_changed_path(session, buf)`) -> looks up `file.viewed` in `session.view.files`, computes `target_viewed = file.viewed ~= "VIEWED"`, and sends `setViewed` (`{ path = path, viewed = target_viewed }`). When `target_viewed == true` and the main window is still displaying `path` when the reply arrives, automatically opens and focuses the next unviewed file in tree order (wrapping around via `find_next_unviewed_path(updated_view, path)`), or switches to and focuses the full branch diff view with `jpr.info("all files viewed")` when no unviewed files remain. When `target_viewed == false`, keeps focus in the open file buffer.
    4. Any other buffer -> `jpr.error("move to a changed file, directory, or the full diff view to toggle viewed")`.
- **Cheatsheet & docs (`lua/jpr/views/cheatsheet.lua`, `README.md`, `docs/architecture.md`, `docs/protocol.md`, `docs/decisions.md`):**
  - Update `:Jpr keys` (`?`) cheatsheet entries for `PR Sidebar Panel` (`v`: `"Toggle file or directory viewed"`) and `Diff & Stream Views` (`full_diff` `gF`, `toggle_viewed` `gv`), plus `README.md` and `docs/`.

### 3. Recursive Directory `'v'` & Next-Unviewed Navigation (`lua/jpr/render/panel.lua`, `lua/jpr/views/panel.lua`)

- Add pure helper `M.collect_directory_toggle_from_files(files, dir_path)` in `lua/jpr/render/panel.lua`:
  - Matches all entries in `files` whose `path` starts with `dir_path .. "/"` (works identically whether `dir_path` or any nested subdirectory is expanded or collapsed in the sidebar, and handles joined single-child directory rows such as `docs/x`).
  - Returns `nil` when zero files match; otherwise returns `{ paths = matching_paths, viewed = has_any_not_viewed }` where `has_any_not_viewed` is `true` if at least one matching file has `file.viewed ~= "VIEWED"`, and `false` when all matching files are already `"VIEWED"`.
- Add pure helper `M.find_next_unviewed_path(view, current_path)` in `lua/jpr/render/panel.lua`:
  - Walks changed files in tree display order (`view.tree` when present, else `view.files`).
  - Scans forward after `current_path`, then wraps around from the start up to `current_path`, returning the first file path whose `viewed ~= "VIEWED"`, or `nil` when every file is `"VIEWED"`.
- Update `M.toggle_viewed_under_cursor(session)` in `lua/jpr/views/panel.lua`:
  - Inspect `M.get_row_under_cursor(session)`:
    - `row.kind == "file"`: send `{ path = row.path, viewed = viewed ~= "VIEWED" }`.
    - `row.kind == "dir"`: compute `toggle = render.collect_directory_toggle_from_files((session.view and session.view.files) or {}, row.path)` and, when non-nil, send `{ paths = toggle.paths, viewed = toggle.viewed }`.
    - `row.kind == "conversation"` or header lines: no-op.
  - When marking `viewed == true` and the full branch diff view is **not** visible, check whether the main window is currently displaying one of the newly marked file paths: if so, advance the main window to `find_next_unviewed_path(updated_view, open_path)` (or show the full branch diff view with `jpr.info("all files viewed")` when none remain) while keeping focus in the sidebar panel. That lookup must not create a window. A closed editor stays closed until the reviewer opens a diff summary, the conversation, or a file.

### 4. Single-Line Collapsed Viewed Files & Live Repaint in Full Branch Diff (`lua/jpr/render/stream.lua`, `lua/jpr/views/stream/init.lua`, `lua/jpr/views/stream/navigation.lua`)

- **Fold range includes file header (`lua/jpr/render/stream.lua`):**
  - Change `fold_start = row.folded and line + 1 or nil` to `fold_start = row.folded and line or nil`, and change `close_fold` to emit `{ first = first_line, last = last_line }` when `first_line and first_line < last_line` (when at least one body/hunk/note/thread row follows the header).
  - Viewed file headers continue to format as `▸ ✓ path  +N -M` (`M.build_file_header(row)`), showing the file name and `+/-` counts.
- **Single-line `foldtext` without banner (`lua/jpr/views/stream/init.lua`):**
  - Add `M.foldtext()` returning `{ { vim.fn.strtrans(vim.fn.getline(vim.v.foldstart)), "JprFileHeader" } }`.
  - In `style_window(win, is_bound)`, set window-local `foldmethod = "manual"`, `foldenable = true`, `foldminlines = 0`, `foldtext = "v:lua.require('jpr.views.stream').foldtext()"`, and `fillchars` with `fold: ` (preserving existing window fillchars and restoring saved window-local `foldtext`, `foldminlines`, and `fillchars` when a non-stream buffer replaces the stream in that window so opened files inherit zero stream fold styling).
  - Bind `zo`, `zc`, and `za` on stream buffers so toggling a manual fold in split stream mode keeps `left_win` and `main_win` folds synchronized alongside `scrollbind`.
- **Navigation compatibility (`lua/jpr/views/stream/navigation.lua`):**
  - In `jump(session, kind, step)`:
    - When `kind == "files"`, every file header line is visible (either unfolded `foldclosed(line) == -1` or the top line of its own closed fold `foldclosed(line) == line`), so `]f` and `[f` step cleanly across both unviewed and collapsed viewed file headers.
    - When `kind == "hunks"` or `kind == "threads"`, hunks and threads inside a collapsed file have `foldclosed(line) ~= -1` (`foldclosed(line) == file.line < line`), so `]h`/`[h` and `]t`/`[t` continue skipping folded hunks and threads while visiting any fold opened with `zo`.
  - `find_target_at_line(layout, line)` already resolves any line with `foldclosed(line) ~= -1` to `file.line`'s target (`{ path = file.path, line = 1 }`), so `<CR>` on a collapsed viewed file header opens that file at line 1.
- **Live collapse & expand when full view is visible:**
  - `viewedChanged` notifications call `session.show(session, params.view)` -> `stream.refresh(session)`.
  - Whenever `stream.is_visible(session)` is true (including when focused in the sidebar panel or in an editor split alongside the stream), `build_stream_key` detects the updated per-file `viewed` states, redraws the stream without stealing window focus, clears prior folds (`normal! zE`), and applies `layout.folds` - collapsing newly viewed files to their single `▸ ✓ path  +N -M` header line and expanding newly unviewed files immediately.

## What Is Left to the Builder

- Exact internal helper decomposition inside `lua/jpr/views/stream/init.lua` and `lua/jpr/init.lua` to keep every function under 45 lines.
- Ordering of new unit and headless Neovim integration specs across Rust (`review-core`, `review-forge-github`, `review-rpc`) and Lua (`panel_render_spec`, `panel_view_spec`, `stream_render_spec`, `stream_view_spec`, `diff_view_spec`, `command_spec`, `cheatsheet_spec`, `palette_and_open_picker_spec`).
