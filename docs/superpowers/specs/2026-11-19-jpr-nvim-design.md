# jpr-nvim design

Date: 2026-11-19. Status: approved design, pending spec review.

## Purpose

jpr-nvim is a pull-request **review** tool that lives entirely inside Neovim.
It ports the review workflow of `dif` (the terminal and web review app that
ships with the `diff-review` agent skill) to a pure Neovim workflow:

- Open a GitHub PR by number into its own worktree and review it with
  GitHub-style diffs, while keeping full Neovim editing, LSP and saving.
- Leave GitHub review comments that sync both ways, and leave **local**
  comments that only an agent sees.
- Hand all local comments to an agent (Claude Code by default) in a Neovim side
  panel, in one batch, and see its answers inline as thread replies.

It is not a general GitHub or git shell. Anything that does not serve
reviewing a PR is out of scope.

## Requirements

| Area | Requirement |
| --- | --- |
| Open | Point at a PR number or URL; the PR is checked out into a new worktree. |
| Views | Split and unified diff views, toggled with one key. The choice is global and remembered. |
| Files | Opening any file the PR changed shows it as a diff in the current view automatically. Every file stays a normal editable buffer. |
| Stream | One continuous view of every changed file (like GitHub's Files tab) with a file panel. |
| Viewed | Mark files viewed; this syncs to GitHub. GitHub's own "changed since viewed" reset syncs back. |
| GitHub comments | Line, range, file-level and PR-level comments. Reply, edit, delete, resolve, react. Suggestions. `@` mentions with completion. |
| Bulk | New GitHub comments go into a pending review and are submitted together with a review-level summary and event. Thread replies post immediately, as on github.com. |
| Local comments | Same anchors as GitHub comments, stored locally, never sent to GitHub unless promoted. |
| Agent | Send all unsent local comments to an agent side panel in one batch. The agent answers or makes changes, and replies inline per thread. |
| Pre-pass | The agent can review the PR first and leave its findings as local threads. |
| Edits | You and the agent can edit files; `:Jpr push` pushes commits to the PR head branch. |
| Sync | A command to pull and resync with GitHub at any time, plus periodic background sync. |

## Decisions

| Topic | Decision |
| --- | --- |
| Agent | Claude Code by default; Codex selectable in `setup()`. Interactive CLI in a terminal split. |
| Agent replies | The agent appends inline replies to local threads through `jpr-review reply`. |
| Split view | Native `diff` mode: read-only base buffer on the left, real file on the right. |
| Unified view | The real file with extmark overlays: green added lines, word highlights, deleted lines as red virtual lines. |
| Stream | File panel plus one scrolling stream that follows the split/unified toggle. |
| Comment display | Sign plus dim end-of-line preview; a key opens a floating thread view; another key expands all threads inline. |
| Destination | Compose float shows a `[GitHub draft]` or `[Local → agent]` badge; one key flips it (sticky per session); separate keys save straight to either destination. |
| GitHub drafts | Mirrored into the user's GitHub pending review on save, as github.com and dif do. |
| Pushing | Push only. The user or the agent commits. The panel shows dirty/ahead/behind. |
| Submit | A Markdown summary buffer listing every draft; choose Comment, Approve or Request changes. |
| Extras in v1 | Code suggestions, edit → suggestion, `@` completion, reactions. |
| Pre-pass | Yes, as local threads authored by the agent. No guide groups in v1. |
| Promotion | A local thread's root comment can be promoted (edited first) into a GitHub draft at the same anchor. Agent replies never go to GitHub. |
| State | `$XDG_STATE_HOME/jpr/<owner>/<repo>/pr-<n>/` (default `~/.local/state/...`), so it survives worktree removal. |
| Names | Neovim plugin and `:Jpr` commands; Rust binary `jpr-review`. |
| Architecture | One long-lived `jpr-review serve` daemon per open PR. It owns all state. |

## Architecture

```
Neovim (lua/jpr)  ──JSON-RPC over stdio──▶  jpr-review serve (one per PR)
   ▲  events                                   │  owns store + GitHub sync
   │                                           ├──▶ gh api graphql / REST
agent terminal ── jpr-review reply ──socket──▶ ┘
```

- The daemon is the only writer of the store. Neovim talks to it over
  newline-delimited JSON-RPC on stdio (`vim.fn.jobstart`). The agent's CLI
  calls reach the same daemon through a Unix socket whose path is in
  `session.json` and in the agent's `JPR_SOCKET` environment variable.
- If no daemon is running, `jpr-review reply` falls back to a locked, atomic
  write of `local.json`, which the daemon reads on its next start.
- The daemon pushes events to Neovim: threads changed, viewed changed, head
  moved, files changed on disk, sync status.

### Repository layout

The repository is both a Rust crate and a Neovim plugin.

- `src/`: the `jpr-review` binary. Large parts are copied from dif and
  trimmed.
  - `github/`: dif's `gh`-backed GraphQL client, anchor conversion, pull,
    sync, offline queues and viewed sync, extended with file-level threads
    (`subjectType: FILE`), PR conversation comments, suggestions, reactions
    and mention candidates.
  - `store/`: the per-PR state files (see "Data model").
  - `diff/`: base…worktree hunks and per-file content hashes.
  - `inject/`: dif's dispatch and prompt builder, returning prompt text
    instead of typing keystrokes into a PTY.
  - `rpc/`: the JSON-RPC protocol shared by stdio and the socket.
  - `commands/`: `serve`, `reply`, `threads`, `state-path`,
    `prepass-write`, `guide`.
- `lua/jpr/` and `plugin/jpr.lua`: the Neovim plugin:
  `rpc.lua`, `session.lua`, `views/{split,unified,stream,panel}.lua`,
  `comments/{render,popup,compose}.lua`, `agent.lua`, `submit.lua`.
- `install.sh` builds `jpr-review` with cargo and installs it into `BIN_DIR`
  (default `~/.local/bin`). It supports `--name <command>` and `--help`.
- The scaffold's unrelated design-agent boilerplate (`impeccable` agents,
  commands and skills) is removed. The scaffold's TUI dependencies (ratatui,
  crossterm) are dropped; the dependency choices are recorded in
  `docs/decisions.md`.

### Installation and host integration

- `install.sh` is the single build entry point, so any dotfiles manager can
  install the binary.
- The host Neovim config loads the plugin from the same checkout that built
  the binary (a lazy.nvim spec with `dir = <checkout>`), so Lua and Rust always
  come from one commit. The plugin checks `jpr-review --version` against its
  own expected protocol version on start and reports a mismatch.
- The plugin ships `<Plug>` mappings and `setup({ keys = ... })` defaults. A
  host config may bind them its own way.
- Required external tools: `gh` (logged in) and `git`. The worktree command is
  configurable (`setup({ worktree_cmd = ... })`); it prints the worktree path
  on stdout. The default creates `<repo>-worktrees/pr-<n>` with
  `git worktree add --detach` followed by `gh pr checkout <n>`.

### Runtime flow

1. `:Jpr open 123` (or a PR URL) runs the worktree command, sets the tab-local
   directory to the worktree, and starts `jpr-review serve --pr 123`.
2. The daemon loads the store, pulls from GitHub and streams events.
3. Lua opens the PR tab (panel and stream) and renders events as they arrive.
4. `:Jpr close` stops the daemon; the store keeps all state.

## Data model

### Threads

Local and GitHub threads share one shape:

- `id`, `origin`: `github` or `local`.
- `anchor`: `{file, kind: line|range|file|pr, side: LEFT|RIGHT, start, end,
  commit, snapshot}`. `snapshot` is the anchored code text (as in dif). While
  a buffer is open an extmark tracks the anchor through edits; on reload the
  snapshot re-anchors local threads whose lines moved.
- `state`: `open` or `resolved`, plus `outdated` from GitHub's `isOutdated`.
- `messages[]`: `{id, author, body, created, updated, reactions[], sync}`.
  `sync` (GitHub only) is `draft`, `pending`, `published`, `failed` or
  `queued`, as in dif.
- Local only: `agent` (`unsent`, `sent` with a round number, `answered`) and
  `promotedTo` (a GitHub thread id).

### Store

`$XDG_STATE_HOME/jpr/<owner>/<repo>/pr-<n>/`, atomic writes (temp file and
rename), daemon is the only writer:

| File | Holds |
| --- | --- |
| `local.json` | Local threads and agent replies. |
| `github.json` | dif's sync registry: id map, last agreed bodies, offline queues (viewed, submit, removals). |
| `viewed.json` | Last known GitHub viewed state per file, plus a content hash. |
| `session.json` | Daemon pid, socket path, worktree path, PR head, agent session id. |
| `rounds.jsonl` | One line per agent send: round, thread ids, prompt. |

## GitHub sync

### When each action reaches GitHub

| Action | When |
| --- | --- |
| New line, range or file comment | Saved into the pending review (`addPullRequestReviewThread`, `subjectType` LINE or FILE). |
| Reply to a published thread | Immediately, through the REST replies endpoint. |
| Reply to your own draft thread | Stays in the pending review. |
| Edit or delete your comment, resolve, react | Immediately. |
| PR conversation comment | Immediately (`addComment`). |
| Mark viewed or unviewed | Immediately, one call per file (`markFileAsViewed`, `unmarkFileAsViewed`). |
| Submit | `submitPullRequestReview` with the summary body and chosen event. |

To verify during implementation: that the REST replies endpoint publishes
immediately even while a pending review exists. If it does not, use the
single-comment path github.com uses for replies.

### Pull and resync

- Runs every 60 seconds, on `:Jpr sync`, and after submit or push.
- Fetches PR metadata (`headRefOid`), threads (paged), the pending review,
  files with `viewerViewedState`, conversation comments and reactions.
- When the head commit moves, dif's checkout logic fast-forwards the worktree:
  stash dirty changes, fast-forward, restore. A conflicting restore asks
  whether the user or the agent resolves it.
- GitHub is the authority for viewed state. A file GitHub reports as
  `DISMISSED` shows as unviewed with a ● marker.
- Failed calls are queued and retried every 20 seconds.
- Mentions are sent as plain `@handle` text, which GitHub links. Completion
  candidates come from PR participants, assignable users and bots that have
  commented on the PR.

## Neovim UI

### PR tab

- **Panel (left).** Header: PR title, head status (`dirty · ↑2 ↓0`),
  `viewed 3/7`, `drafts 4`, `local unsent 2`, sync state. Nodes: Conversation
  (PR-level comments, opens a Markdown buffer), then the file tree with ✓
  viewed, ● changed since viewed, ✎ locally modified, `+12 −3`, and GitHub
  and local comment counts.
- **Stream (right).** See below.

### Changed files open as diffs

A `BufEnter` autocmd scoped to the worktree checks the daemon's changed-file
list and applies the current view:

- **Unified:** extmark overlays on the real buffer. Green added lines,
  word-level highlights, deleted lines as red `virt_lines`.
- **Split:** a read-only `jpr://base/<path>` buffer opens on the left with
  `diffthis` and `scrollbind`. The window closes when the file is left.

The diff is always base versus the file on disk, so local edits show as part
of the change. The toggle key flips the view globally and redraws every open
window. Unchanged files open normally.

### Stream

`jpr://stream` is read-only and built from the daemon's hunks: one section per
file with a header line, viewed files folded, file-level threads under the
header. Split mode uses two scroll-bound buffers padded to align.

| Key | Action |
| --- | --- |
| `<CR>` | Jump to the real file at that line. |
| `v` | Toggle viewed, fold the file, move to the next unviewed file. |
| `]f` / `[f` | Next and previous file. |
| `]h` / `[h` | Next and previous hunk. |
| `]t` / `[t` | Next and previous thread. |

Comment keys work in the stream; a stream line maps back to file, side and
line.

### Comments

- **Markers:** one sign per thread, with distinct icons and colors for GitHub
  published, GitHub draft and local. Dim end-of-line text shows the count and
  the first author and snippet. File-level threads appear as a virtual line at
  the top of the file.
- **Thread popup:** a float in the host's float style. Keys: `r` reply, `e`
  edit, `d` delete, `R` resolve or unresolve, `+` react, `p` promote (local
  only), `s` send this thread to the agent now, `q` close.
- **Expand all:** a toggle draws every thread inline as virtual lines.
- **Compose:** a Markdown float titled `[GitHub draft]` or `[Local → agent]`.
  `<C-g>` flips the destination; `<C-s>` saves to the shown destination;
  `<M-s>` saves to the other one. A key inserts a ```` ```suggestion ```` block
  prefilled with the anchored lines. `@` completion is available through
  `omnifunc` and through an nvim-cmp source when nvim-cmp is installed.
- **Edit → suggestion:** `:Jpr suggest` on an edited hunk turns the local edit
  into a GitHub draft suggestion on those lines, then reverts the edit.

### Submit

`:Jpr submit` opens a Markdown buffer: the review summary at the top, then a
list of every pending draft (each line jumps to its anchor). Writing the
buffer asks for the event (Comment, Approve, Request changes) and submits.
Submit refuses while any draft is `pending` or `failed`.

### Commands

| Command | Action |
| --- | --- |
| `:Jpr open <n\|url>` | Check out the PR into a worktree and open the PR tab. |
| `:Jpr sync` | Pull and resync with GitHub now. |
| `:Jpr toggle` | Flip between split and unified views. |
| `:Jpr stream` | Focus the stream. |
| `:Jpr comment` | New comment on the line, visual range, or `file`. |
| `:Jpr conversation` | Open PR-level comments. |
| `:Jpr suggest` | Turn an edited hunk into a suggestion. |
| `:Jpr submit` | Open the submit buffer. |
| `:Jpr push` | Push commits to the PR head branch. |
| `:Jpr agent` | Toggle the agent side panel. |
| `:Jpr send` | Send all unsent local threads to the agent. |
| `:Jpr prepass` | Ask the agent to review the PR into local threads. |
| `:Jpr close` | Close the PR tab and stop the daemon. |

`require("jpr").statusline()` returns a short summary for statusline plugins.

## Agent loop

### Side panel

`:Jpr agent` toggles a right vertical terminal split in the PR tab running
`claude` (or `codex`). Its working directory is the worktree, with
`JPR_SOCKET` and `JPR_PR` in its environment. The agent session id is stored
in `session.json`, so reopening the PR resumes the conversation.

### Sending local comments

1. `:Jpr send` (or `s` in a popup for one thread) asks the daemon for every
   local thread that is open, whose last message is the user's, and that has
   not been sent (dif's dispatch rules).
2. The daemon builds dif's numbered batch prompt. Each item has its anchor
   (`file:L7-9`, `file`, or `PR`), the thread's earlier messages and the new
   comment. The prompt tells the agent to run `jpr-review guide` first.
3. Lua opens the panel if needed, pastes the prompt with `chansend` using
   bracketed paste, then sends the submit key (Enter for Claude, Tab for
   Codex), as dif does.
4. Only after the paste succeeds are the threads marked `sent` and the round
   appended to `rounds.jsonl`.

### Agent contract

`jpr-review guide` prints the contract, adapted from diff-review's Continue
mode, reply style and review-comment style:

- Classify each item as a question (answer, no code change) or a change
  request (edit and commit in the PR worktree).
- Reply on every item with `jpr-review reply <thread-id> --body ...`. The
  default reply to a change is `Done.` with the commit.
- Never push and never touch GitHub. `jpr-review reply` refuses GitHub thread
  ids, so the agent cannot post on the PR.

A user reply in a local thread makes it unsent again; the next `:Jpr send`
includes it. Resolving a local thread closes it.

### Pre-pass

`:Jpr prepass` asks the agent to review the PR (adapted from diff-review's
PR-review mode). The agent writes findings with `jpr-review prepass-write` as
local threads authored by the agent. The user replies, promotes or resolves
them.

### Agent edits

The daemon watches the worktree and emits file-change events; Neovim runs
`checktime` and redraws overlays. GitHub viewed state does not change until a
push, after which GitHub's own reset applies.

## Error handling

| Failure | Behavior |
| --- | --- |
| Daemon crash | Banner, one automatic restart, reload from the store. Every mutation is persisted before it is acknowledged. A second crash makes the session read-only and names the log file. |
| `gh` missing, logged out, or PR not found | `:Jpr open` fails up front with the exact fix. |
| GitHub write failure | `failed` badge with GitHub's message, plus retry and edit actions. Network errors are `queued` and retried. |
| Concurrent edit of a comment | dif's agreed-body rule: GitHub wins; the local text is kept as a recoverable note. |
| Dirty worktree on resync | Stash, fast-forward, restore; on conflict the user picks who resolves it. |
| Agent panel closed | `:Jpr send` reopens and resumes it before pasting. |
| Plugin and binary versions differ | Clear error naming both versions and the install command. |

## Testing

- **Rust (`cargo test`):** a fake `GithubApi` (dif's trait) drives GraphQL and
  REST fixture tests for anchors, pending-vs-immediate rules, queues and viewed
  sync. Store round-trip and crash-safety tests. Golden tests for the prompt
  and the `guide` text. Socket tests for `reply`, including its refusal of
  GitHub ids.
- **Lua:** headless `nvim -l` specs against a fake RPC that replays recorded
  events: overlays, view toggling, stream line-to-anchor mapping, signs, popup
  and compose actions.
- **End to end:** a scripted smoke run against a throwaway PR in a private
  scratch repository: open, comment, reply, mark viewed, push a change and
  confirm the DISMISSED reset, submit.
- `just check` (format, clippy, tests) gates every commit.

## Delivery milestones

Each milestone ends usable and tested.

1. **Core.** Daemon, store, GitHub pull, RPC, `:Jpr open`, `install.sh`, host
   loading. Usable for dogfooding from here on.
2. **Review views.** Unified and split overlays, stream, panel, viewed sync
   including DISMISSED.
3. **GitHub comments.** Drafts (line, range, file), immediate replies,
   conversation comments, edit, delete, resolve, reactions, mentions,
   suggestions, edit → suggestion, submit buffer.
4. **Local comments and the agent loop.** Local threads, compose toggle, side
   panel, `send`, `reply`, `guide`, pre-pass, promotion.
5. **Polish.** `:Jpr push` status, statusline, docs.

## Out of scope

- Creating, merging or closing PRs, branch management, and other general
  GitHub or git features.
- GitLab and other forges.
- Guide groups (dif's logical file grouping) and the web shell.
- Posting anything to GitHub on the agent's behalf.
