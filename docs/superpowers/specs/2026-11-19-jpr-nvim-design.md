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

The review engine underneath is deliberately frontend-neutral. Neovim is its
first frontend; dif's terminal UI is meant to reuse the same engine later, so
reviewers who do not use Neovim get the same workflow (see "Modularity and
layering").

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
| Modularity | A generic review engine (ports and adapters, a `ReviewSession` facade, events, view models) in frontend-neutral crates; Neovim is a thin adapter. dif's TUI is the second intended consumer. |

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

### Modularity and layering

**Goal.** Everything that is not inherently about Neovim must be reusable by
other review frontends, first of all dif's terminal UI, so that TUI-based
reviews can later run on the same engine without Neovim. Neovim is one
frontend among several, not the center of the design.

**Rule.** The code splits into two kinds of module, and the boundary between
them is enforced, not just conventional:

| Kind | May depend on | Must not depend on |
| --- | --- | --- |
| Generic (review engine) | The standard library, other generic crates, small general-purpose crates (serde, anyhow, etc.) | Neovim, Lua, any terminal or UI library, any specific frontend's concepts (buffers, windows, extmarks, keymaps, panes) |
| Frontend (Neovim adapter) | Generic crates through their public API, Neovim | Another frontend |

Generic crate names never contain `nvim` or `jpr`. A test in CI fails if a
generic crate's dependency tree gains a frontend crate or a UI library.

**Patterns used to bridge the engine to frontends:**

- **Ports and adapters (hexagonal architecture).** The engine defines traits
  (ports) for everything it needs from the outside world and never calls the
  outside world directly. Adapters implement them:
  - `Forge`: pull PR data and write review actions. Adapter: GitHub through
    `gh` (dif's `GithubApi`, extended).
  - `ReviewStore`: load and save threads, sync registry, viewed state, rounds.
    Adapter: atomic JSON files under the XDG state directory.
  - `Workspace`: PR checkout into a worktree, git status, fast-forward,
    stash/restore, file watching. Adapter: `git`, `gh` and a configurable
    worktree command.
  - `AgentChannel`: deliver a prompt to the agent. The engine produces the
    prompt and an `AgentProfile` (paste style, submit key); each frontend
    implements delivery (Neovim: `chansend` into a terminal; dif: its PTY).
  - `Clock`: time, for tests and retry scheduling.
- **Facade (application service).** One `ReviewSession` type exposes every
  use case (open, sync, comment, reply, edit, resolve, react, toggle viewed,
  submit, send to agent, pre-pass, promote) as plain Rust methods over the
  ports. Frontends only ever talk to this facade.
- **Command/query split.** Facade methods are either commands (change state,
  return the result or an error) or queries (return read models). The same
  split defines the RPC protocol, so an in-process caller and an
  out-of-process caller see the same API.
- **Observer (event stream).** The session publishes domain events (threads
  changed, viewed changed, head moved, files changed, sync status, agent
  round). In-process frontends subscribe directly; the RPC layer forwards
  them as notifications.
- **Presenter / view model.** Anything a reviewer sees that is not
  frontend-specific is computed in Rust as a frontend-neutral read model:
  the changed-file list with badges, the stream rows (file headers, hunk
  lines, filler rows that align split view, thread markers, folds), the
  stream-row-to-anchor mapping, thread summaries for end-of-line previews,
  the submit summary, and status counts. Frontends only draw these models.
  The Neovim plugin turns rows into buffer lines and extmarks; dif's TUI turns
  the same rows into ratatui widgets.
- **Strategy.** Behavior that varies by choice is a strategy object: the agent
  profile (Claude or Codex), the diff view mode (split or unified row
  layout), and the forge (GitHub today).
- **Composition root.** Only the binaries wire concrete adapters into the
  facade. No generic crate constructs an adapter.

**Versioned protocol.** The JSON-RPC protocol is documented in
`docs/protocol.md` with a protocol version. It is the out-of-process contract
for any frontend (Neovim today; dif's TUI could use it or link the crates
directly).

### Repository layout

The repository is a Cargo workspace plus a Neovim plugin.

Generic crates (`crates/`), reusable outside Neovim:

| Crate | Responsibility |
| --- | --- |
| `review-model` | Domain types: threads, anchors, messages, sync status, viewed state, PR metadata, events. Pure data, serde only. |
| `review-core` | The ports (traits), the `ReviewSession` facade, sync rules (pending vs immediate), offline queue logic, viewed reconciliation, anchor re-anchoring, agent dispatch and prompt building (from dif's `inject/`), the agent contract text printed by `guide`. No IO of its own. |
| `review-diff` | Hunks and word diffs between two texts, content hashes, and the view-model builders for the stream and file views (rows, filler alignment, folds, anchor mapping). |
| `review-forge-github` | The `Forge` adapter: dif's `gh`-backed GraphQL client, anchor conversion, pull and sync, extended with file-level threads (`subjectType: FILE`), PR conversation comments, suggestions, reactions and mention candidates. |
| `review-store-fs` | The `ReviewStore` adapter: atomic JSON files and the lock-based fallback write used when no daemon is running. |
| `review-workspace-git` | The `Workspace` adapter: worktree command, git status, fast-forward with stash/restore, file watcher. |
| `review-rpc` | JSON-RPC server over stdio and a Unix socket that exposes the facade's commands, queries and events. Frontend-neutral. |

Frontend-specific code:

| Path | Responsibility |
| --- | --- |
| `crates/jpr-review` | The binary and composition root: `serve`, `reply`, `threads`, `state-path`, `prepass-write`, `guide`, `--version`. Wires the adapters into `ReviewSession` and `review-rpc`. |
| `lua/jpr/`, `plugin/jpr.lua` | The Neovim adapter. `rpc.lua` (protocol client), `session.lua`, `render/` (draw view models as lines, extmarks, signs and folds), `views/{split,unified,stream,panel}.lua` (window and buffer management only), `comments/{popup,compose}.lua`, `agent.lua` (the `AgentChannel` for Neovim), `submit.lua`. No review rules live in Lua: if a decision would be the same in a TUI, it belongs in Rust. |

Other files:

- `build.lua` (with `lua/jpr/build.lua`, superseding standalone `install.sh`;
  see `2026-11-23-lazy-nvim-bundled-binary-design.md`) builds
  `target/release/jpr-review` inside the plugin checkout via `cargo` on
  `lazy.nvim` install and `:Lazy update`.
- `docs/protocol.md` (RPC contract) and `docs/architecture.md` (layers and the
  dependency rule).
- The scaffold's unrelated design-agent boilerplate (`impeccable` agents,
  commands and skills) is removed. The scaffold's TUI dependencies (ratatui,
  crossterm) are dropped; the dependency choices are recorded in
  `docs/decisions.md`.

### Reuse path for dif

dif's TUI is the second intended consumer. This spec does not change dif, but
the crates are shaped so it can adopt them incrementally:

1. dif depends on the generic crates (a git dependency on this repository)
   and replaces its copies of the GitHub layer and the dispatch and prompt
   code with `review-forge-github` and `review-core`.
2. dif replaces difit's comment store with `review-store-fs` behind
   `ReviewStore`.
3. dif renders `review-diff` view models with ratatui, giving terminal-only
   users the same review flow without Neovim or a browser.

Because dif already has its own PTY agent pane, it implements `AgentChannel`
with that pane, and everything else is shared.

### Installation and host integration

- `build.lua` is the single build entry point (superseding standalone
  `install.sh`; see `2026-11-23-lazy-nvim-bundled-binary-design.md`):
  `lazy.nvim` runs it automatically on install and `:Lazy update` to compile
  `target/release/jpr-review` inside the plugin checkout.
- The plugin resolves its bundled `target/release/jpr-review` binary from the
  same checkout by default (and prepends that directory to `PATH` inside
  `:Jpr agent` terminals), so Lua and Rust always come from one commit. The
  plugin checks both `protocolVersion` and `version` during the `initialize`
  handshake (and in `:checkhealth jpr`) and prompts to run
  `:Lazy build jpr-nvim` on mismatch.
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
  commit, snapshot}`. `snapshot` is the anchored code text (as in dif).
  Re-anchoring is engine logic: when a file changes, `review-core` uses the
  snapshot to move local anchors whose lines shifted. A frontend may also
  report live positions (Neovim tracks anchors with extmarks while a buffer is
  open and sends the new lines on save), but it never decides anchors itself.
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

`jpr://stream` is read-only and drawn from the engine's stream view model: one section per
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

- **Engine (`cargo test`, no Neovim):** `ReviewSession` is tested through
  in-memory fakes of every port (`Forge`, `ReviewStore`, `Workspace`,
  `AgentChannel`, `Clock`): pending-vs-immediate rules, queues, viewed
  reconciliation, re-anchoring, dispatch, and golden tests for the prompt and
  the `guide` text. View-model tests cover stream rows, split filler alignment,
  folds and the row-to-anchor mapping. Most behavior is verified at this
  level, which is what makes it reusable by dif.
- **Adapters:** GraphQL and REST fixture tests for `review-forge-github`;
  round-trip and crash-safety tests for `review-store-fs`; temporary-repo tests
  for `review-workspace-git`. Each adapter also passes a shared contract test
  suite written against its port, so a future adapter (another forge, another
  store) is checked the same way.
- **Protocol:** `review-rpc` tests over stdio and the socket, including
  `reply` refusing GitHub ids and the protocol version handshake.
- **Dependency rule:** a test fails if any generic crate depends on a frontend
  crate or a UI library.
- **Lua:** headless `nvim -l` specs against a fake RPC that replays recorded
  events and view models. They test drawing and window behavior only (overlays,
  view toggling, signs, popup and compose actions), since the rules are
  already tested in Rust.
- **End to end:** a scripted smoke run against a throwaway PR in a private
  scratch repository: open, comment, reply, mark viewed, push a change and
  confirm the DISMISSED reset, submit.
- `just check` (format, clippy, tests) gates every commit.

## Delivery milestones

Each milestone ends usable and tested.

1. **Core.** The workspace with the generic crates and the dependency-rule
   test, `review-model`, the ports and `ReviewSession` skeleton, the store and
   GitHub pull adapters, `review-rpc`, `docs/protocol.md`, the `jpr-review`
   composition root, `:Jpr open`, `build.lua` (superseding standalone
   `install.sh`; see `2026-11-23-lazy-nvim-bundled-binary-design.md`), host
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
