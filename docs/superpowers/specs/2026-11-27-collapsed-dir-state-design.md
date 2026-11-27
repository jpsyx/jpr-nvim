# Persisted Sidebar Directory Collapse Design

**Date:** 2026-11-27
**Branch:** `feat/collapsed-dir-state`
**Size:** Medium

## Intent and Why

Viewed files and local threads survive a restarted review session because they live in the review state directory. Sidebar directory collapse lives only in the Neovim process, so every directory opens again after a restart. Collapse should persist the same way, and a GitHub pull should reopen a collapsed directory only when a file under it newly needs review.

## Goals

- Persist the collapsed sidebar directories in `local.json` and restore them when a session opens.
- Include that set on every `SessionView` as `collapsedDirs`.
- Add `setCollapsed` so the sidebar can collapse or expand one directory.
- On a successful GitHub pull, expand every collapsed ancestor of a file whose reconciled viewed state became `UNVIEWED` or `DISMISSED` because the forge snapshot says so.
- Leave a collapsed directory collapsed when that file's viewed state did not change, when the reviewer toggles `v`, and when a queued mark keeps the reconciled state at `VIEWED`.

## Non-Goals

- A new `:Jpr` or `jpr-review` command. Collapse stays a sidebar key and mouse action.
- Auto-collapse when a file becomes viewed.
- Expanding because a local-only file's viewed state changed, or because the reviewer edited a file on disk.
- Changing how the diff stream folds viewed files.
- A file tree in the CLI.

## Decisions

- Expand for `UNVIEWED` or `DISMISSED`, including a file that was not in the saved list. A file that stays `UNVIEWED` or `DISMISSED` does not expand.
- The engine owns the set, sends it on the session view, and applies the expand rule during a GitHub pull. The sidebar draws the set and sends toggles.

## Constraints

- Generic crates under `crates/review-*` stay free of Neovim, Lua, and TUI dependencies.
- `local.json` stays version 1. `collapsedDirs` defaults to empty so older files still load.
- `PROTOCOL_VERSION` becomes 11 in `crates/review-rpc/src/protocol.rs`, `lua/jpr/rpc.lua`, the fake engine default, `docs/protocol.md`, and `docs/architecture.md`.
- `setCollapsed` is stdio-only. The Unix socket refuses it with `-32600`, the same way it refuses `setViewed`.
- No em dashes in comments, docs, or user-facing copy.
- New functions stay at or under 45 lines.
- Write a failing test before the implementation that makes it pass.

## Approaches Considered

1. **Engine-owned set on `SessionView` (chosen).** `local.json` stores the paths. Every session view carries them. `setCollapsed` updates one path. A successful pull expands ancestors and the next `synced` view redraws the sidebar.
2. **Same store, separate request/event.** Rejected. Frontends already redraw from `SessionView`, so a second channel only creates a view that can be stale.
3. **Neovim-only file.** Rejected. The expand rule depends on saved viewed state versus the forge snapshot, which the engine already reconciles.

## Design Details

### 1. Persisted shape

`LocalStoreState` in `crates/review-core/src/ports/store.rs` gains:

```rust
#[serde(default)]
pub collapsed_dirs: BTreeSet<String>,
```

The JSON field is `collapsedDirs`: a sorted array of repository-relative directory paths. A missing field means nothing is collapsed. `encode_local` and `decode_local` already flatten `LocalStoreState`, so the file version stays 1.

A path is one joined directory row from the sidebar, such as `src`, `src/core`, or `docs/x`. Collapsed path `P` hides a file when the file path starts with `P/`.

Retarget moves `local.json` as a whole, so this field needs no retarget-specific code. `merge_preexisting_pr_snapshot` unions the prior pull-request set into the local set: a path collapsed on either side stays collapsed.

### 2. Session view

`SessionView` gains:

```rust
#[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
pub collapsed_dirs: BTreeSet<String>,
```

`session_view` in `crates/review-core/src/presenter.rs` copies the set onto the view. `ReviewSession::view_with_status` passes `self.saved.local.collapsed_dirs`. Snapshot, sync, push, and every event that embeds `SessionView` therefore carry the current set. An empty set is omitted. Clients treat a missing or non-array value as no collapsed directories.

### 3. `setCollapsed`

Request: `{ "path": "src/core", "collapsed": true }`

Result: `SessionView`. There is no new event. The response is the update, and later events include the saved set.

`path` must pass `validate_safe_relative_path`. A missing path, an unsafe path, or a non-boolean `collapsed` is RPC `-32602`, and the set is unchanged. `collapsed: true` inserts the path. `collapsed: false` removes it. When membership is already correct, return the current view and do not write. Otherwise save the snapshot the same way `set_viewed` does, then return `view()`. If the save fails, restore the previous set and return `-32000`.

`setCollapsed` does not expand other directories, prune the set, or call GitHub. The socket allowlist is unchanged. `allowlist_permits_only_expected_socket_methods` gains `"setCollapsed"` in its refused list.

### 4. Expand and prune on a GitHub pull

This runs only inside `reconcile_viewed_and_local_files`, which a successful `apply_pull` calls. A failed pull leaves the set unchanged. `set_viewed`, disk edits, and local-only dismiss do not expand anything.

Before `apply_queued`, remember:

- `previous`: each saved file path and its viewed state
- `forge`: each incoming snapshot path and its viewed state

After queued marks are applied, `self.saved.files` is replaced, and local files are refreshed, update `collapsed_dirs`.

A file triggers expansion when all of these are true:

- Its reconciled viewed state is `UNVIEWED` or `DISMISSED`.
- The forge snapshot has that same path at `UNVIEWED` or `DISMISSED`, so the change came from GitHub rather than from a queued mark that overrode GitHub.
- `previous` has no entry for the path, or that entry differs from the reconciled state.

For each triggering file path `F`, remove every collapsed path `P` such that `F` starts with `P/`.

Then drop any collapsed path that is not a strict directory prefix of at least one current file. Current files are the reconciled pull-request files plus local-only worktree files. A directory that still contains only local-only files stays collapsed. A directory that left the tree is forgotten.

`split_and_save_threads` already saves the snapshot, so the updated `local.json` is written with the rest of the pull. The `synced` view includes the result, and the sidebar redraws from it.

Examples:

- Saved `src/a.rs` is `VIEWED`, GitHub now says `DISMISSED`, and `src` is collapsed. `src` expands.
- Saved `src/a.rs` is `UNVIEWED`, GitHub still says `UNVIEWED`, and `src` is collapsed. `src` stays collapsed.
- New `src/b.rs` arrives as `UNVIEWED`. Every collapsed ancestor of `src/b.rs` expands.
- GitHub says `UNVIEWED`, but a queued viewed mark reconciles the file back to `VIEWED`. Nothing expands.
- GitHub says `VIEWED`, but a queued unviewed mark reconciles the file to `UNVIEWED`. Nothing expands. The reviewer's own mark is not a GitHub change.
- `docs/x/y.md` becomes `DISMISSED` and `docs/x` is collapsed. `docs/x` expands. The tree joins a lone `docs` directory into `docs/x`, and the prefix rule still matches that row.

### 5. Renames

`migrate_renames` rewrites each collapsed path with the existing `rewrite_renamed_path` helper: an exact match, or a path under `old_path/`. `refreshWorktree` saves when that rewrite changes the set, as it does for `localViewed`. A rename does not expand directories.

### 6. Sidebar

`jpr.render.panel.build` keeps accepting `opts.collapsed_dirs`, so its drawing tests stay direct.

`jpr.views.panel` treats `view.collapsedDirs` as the source of truth:

- Each `render` builds the set from `view.collapsedDirs` (an array of strings; anything else means nothing is collapsed) and passes it to `build`.
- `h`, `l`, `<CR>`, `o`, and a directory click send `setCollapsed` with that row's `path` and the new boolean, then render from the returned view.
- The local set does not flip before the response. A failed request leaves the previous view and reports the error the same way other panel requests do.
- Closing and reopening the sidebar with `gp` reads the last `session.view.collapsedDirs`. `session.panel_collapsed_dirs` may mirror that view, and must not override a newer view.

`panel.render` already runs for `synced` and the other view events, so a pull that expands a directory shows up without a new event type.

### 7. Docs

Update these in the same change:

- `docs/protocol.md`: version 11, `collapsedDirs` on `SessionView`, the `setCollapsed` row, the socket refusal, and a version note.
- `docs/architecture.md`: the protocol version, the `local.json` row, and the panel row so collapse comes from the view.
- `docs/decisions.md`: collapse is local review state, and a pull expands a directory only when GitHub changes a file under it to `UNVIEWED` or `DISMISSED`.

### 8. Tests

Rust tests, each failing before its implementation:

- An old `local.json` without `collapsedDirs` decodes to an empty set.
- `set_collapsed(path, true)` persists the path on `view().collapsed_dirs`. `set_collapsed(path, false)` removes it. Calling it again with the same path and value leaves the set unchanged.
- An unsafe path returns an error and leaves the set unchanged.
- A pull that changes `VIEWED` to `DISMISSED` expands every matching ancestor and leaves an unrelated collapsed directory collapsed.
- A pull that leaves a file `UNVIEWED` does not expand its collapsed parent.
- A pull that adds a new `UNVIEWED` file expands that file's collapsed ancestors.
- A forge `UNVIEWED` overridden to `VIEWED` by the queue does not expand.
- A forge `VIEWED` overridden to `UNVIEWED` by the queue does not expand.
- A pull drops a collapsed path that is no longer a prefix of any pull-request or local-only file.
- Renaming `src/old` to `src/new` rewrites collapsed paths `src/old` and `src/old/nested`.
- Linking a local review into a pull request unions the two collapsed sets.
- The socket allowlist refuses `setCollapsed`.

Lua tests:

- The fake engine's default protocol becomes 11. It answers `setCollapsed` by inserting the path when `collapsed` is true, removing it when false, returning that view, and logging the request.
- A snapshot whose `collapsedDirs` is `["src"]` renders `src/` collapsed before any keypress.
- `h` on an expanded directory sends `setCollapsed` with `"collapsed":true` and renders the directory collapsed only after that response.
- A `synced` event whose view drops a previously collapsed parent redraws that parent expanded.
- Specs that assign `panel.collapsed_dirs` or `panel_collapsed_dirs` directly (`tests/lua/panel_view_spec.lua`, `tests/lua/layout_and_panel_toggle_spec.lua`) seed `view.collapsedDirs` and re-render instead, and wait for `setCollapsed` when they press a collapse key.
- `tests/lua/panel_render_spec.lua` keeps passing `opts.collapsed_dirs` into the pure builder.

## Error Handling

- Invalid `path`, or a missing or mistyped `collapsed`: `-32602`, set unchanged.
- Save failure: restore the previous set, then return `-32000`.
- Failed GitHub pull: leave `collapsedDirs` as it was.
