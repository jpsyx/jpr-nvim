# Unified Diff Summary + Conversation View Design

**Date:** 2026-11-26
**Branch:** `feat/diff-summary-view`
**Size:** Small change

## Intent and Why

Reviewers need to read a pull request's description and high-level diff stats alongside its top-level conversation comments without leaving Neovim. Making **Diff summary** and **Conversation** two entry points into the **same** buffer mirrors how reviewers read a PR: one continuous document where selecting **Diff summary** starts at the very top and selecting **Conversation** jumps straight to the top of the conversation comments.

## Goals

- Add a `Diff summary` row directly above `Conversation` (or `Local Notes` in unlinked local mode) in the sidebar panel.
- Render both the Diff summary section (at the top) and the Conversation section (below a horizontal divider) inside the same main-window buffer (`jpr://conversation/<buf_key>`).
- Scroll to line 1 (top of the buffer) when opened via `Diff summary` or `:Jpr summary`, and scroll to the `Conversation` heading when opened via `Conversation` or `:Jpr conversation`.
- Fetch and persist the GitHub PR `body` (Markdown description) in `PullRequest` without breaking older saved sessions or bumping the RPC protocol version.
- Support unlinked local review sessions (`:Jpr local`) by showing branch metadata, file/line diffstats, and a muted hint to run `:Jpr sync` once a PR exists.
- Register `:Jpr summary` in the `:Jpr` command schema and Command Palette for full non-interactive and interactive parity.

## Non-Goals

- Editing the GitHub PR description from Neovim.
- Rendering a per-commit git log list in the summary section.
- Splitting Diff summary and Conversation into two separate buffers.

## Constraints

- **Dependency rule:** Generic Rust crates (`crates/review-*`) stay free of Neovim, Lua, or TUI dependencies.
- **Backward compatibility:** `PullRequest.body` and `StoredPullRequest.body` must use `#[serde(default)]` so existing `session.json` files and older fixtures deserialize cleanly without a format or protocol version bump.
- **Command Palette invariant:** `:Jpr summary` must be registered in `lua/jpr/commands/schema/init.lua` with a human-readable label, concise helper text, and runtime executability predicate (`predicates.is_conversation_executable`).
- **No em dashes** in code comments or user-facing copy.

## Approaches Considered

1. **Unified buffer with additive `PullRequest.body` (Chosen):** Add `#[serde(default)] pub body: String` to `PullRequest` (populated from `gh pr view --json ...,body` and persisted in `StoredPullRequest`), render both summary and conversation in `lua/jpr/views/conversation.lua`, and pass `opts.target` (`"summary"` or `"conversation"`) to position the cursor and window `topline`. Zero extra `gh` round-trips, zero new RPC methods, and exact alignment with the single-view requirement.
2. **Two separate buffers (`jpr://summary/...` and `jpr://conversation/...`):** Rejected because the summary and conversation must be the same scrollable view.
3. **Dedicated RPC method to fetch PR `body` on demand:** Rejected because `gh pr view --json` already returns `body` in the exact same call used during sync.

## Design Details

### 1. Rust PR Body Persistence & Fetching

- `crates/review-model/src/pr.rs`: Add `#[serde(default)] pub body: String` to `PullRequest`.
- `crates/review-forge-github/src/pr.rs`: Append `body` to `PR_FIELDS` and parse `value["body"].as_str().unwrap_or_default().to_owned()`.
- `crates/review-store-fs/src/format.rs`: Add `body: String` to `StoredPullRequest` (covered by `#[serde(default)]`) and wire both `From` conversions.

### 2. Sidebar Panel

- `lua/jpr/render/panel.lua`: Emit `"  📄 Diff summary"` (`JprTitle`) directly above `"  💬 Conversation"` / `"  💬 Local Notes"`. Record `summary_line`, `rows[summary_line] = { kind = "summary" }`, and include `summary_line` in `selectable_lines`.
- `lua/jpr/views/panel.lua`: Store `panel.summary_line`, preserve cursor on `kind == "summary"`, default initial cursor to `built.summary_line or built.conversation_line or built.selectable_lines[1]`, and route `<CR>` / `o` / mouse click on `summary_line` to `session.summary_current()`.

### 3. Unified Summary + Conversation View

- `lua/jpr/views/conversation.lua`:
  - **Linked PR summary:**
    - `#<number> <title>` (`JprTitle`)
    - `@<author> · <headRef> -> <baseRef>` (`JprMuted`, omitting missing segments gracefully)
    - `<N> files changed · +<adds> -<dels> · <viewed>/<N> viewed` (`JprMuted`)
    - Blank line
    - PR `body` lines (with `\r\n` / `\r` normalized so `nvim_buf_set_lines` never errors), or `  (no PR description)` (`JprMuted`) when blank
    - Blank line + horizontal rule (`────────────────────────────────────────`, `JprMuted`) + blank line
  - **Unlinked local summary:**
    - `LOCAL <branch> vs <baseRef>` (`JprTitle`)
    - `<N> files changed · +<adds> -<dels> · <viewed>/<N> viewed` (`JprMuted`)
    - Blank line + `  (local worktree review; run :Jpr sync once a PR is open to load its description)` (`JprMuted`)
    - Blank line + horizontal rule + blank line
  - **Conversation section:**
    - Record `layout.conversation_start_line` on the heading line (`Conversation (<count> comments)` or `Local Notes (<count> comments)`, `JprTitle`).
    - Render PR conversation threads and footer key hints unchanged.
  - **Scroll targeting (`M.show(session, opts)`):**
    - `target = (opts and opts.target) or "conversation"`.
    - Set `state.pending_target = target`.
    - If `state.layout` is already populated, immediately scroll the main window to line `1` (`summary`) or `state.layout.conversation_start_line` (`conversation`) via `winrestview({ lnum = line, col = 0, topline = line })`.
    - After `fetch_and_draw` repaints, apply and clear `state.pending_target` if set; background `M.refresh(session)` leaves `pending_target` untouched so the user's scroll position is preserved.

### 4. Commands, Palette & Docs

- `lua/jpr/session/comments.lua`: Add `summary_current()` -> `conversation.show(session, { target = "summary" })`; update `conversation_current()` -> `conversation.show(session, { target = "conversation" })`.
- `lua/jpr/init.lua`: Add `summary = "summary_current"` to `ZERO_ARG_SESSION_METHODS`.
- `lua/jpr/commands/schema/init.lua`: Register `"summary"` (`Open Diff Summary`) above `"conversation"` with `predicates.is_conversation_executable`.
- Update `lua/jpr/views/cheatsheet.lua` and `docs/protocol.md`.
