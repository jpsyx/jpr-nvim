# Architecture

jpr-nvim is a pull-request review engine in Rust with a Neovim plugin on top.
The engine is frontend-neutral on purpose: Neovim is its first frontend, and
other frontends (a terminal UI, for reviewers who do not use Neovim) are meant
to reuse it. Extend this document as the shape changes.

## Layers

```
Neovim (lua/jpr)  --JSON-RPC over stdio-->  jpr-review serve (one per PR)
   ^  events                                     | owns the session
   |                                             +--> gh (GitHub)
   +-- draws view models                         +--> git (the worktree)
                                                 +--> state files
```

| Kind | Crates and paths | May depend on |
| --- | --- | --- |
| Generic engine | `crates/review-*` | std, small general-purpose crates, other `review-*` crates |
| Composition root | `crates/jpr-review` | everything above |
| Neovim adapter | `lua/jpr`, `plugin/jpr.lua` | the protocol in `docs/protocol.md` |

**The dependency rule.** A generic crate never depends on Neovim, Lua, a
terminal UI library, or a frontend crate, directly or transitively.
`crates/jpr-review/tests/dependency_rule.rs` enforces it against
`cargo metadata`: a `review-*` crate may not reach a known UI or editor crate,
or a workspace crate outside `review-*`, through its runtime dependencies.
Dev-dependencies are exempt. Generic crate names never contain `nvim` or `jpr`.

**Where logic goes.** If a decision would be the same in a terminal UI, it is
Rust in a generic crate. Lua manages windows, buffers and keys, and draws the
read models the engine returns.

## The generic crates

| Crate | Responsibility |
| --- | --- |
| `review-model` | Domain types (pull requests, changed files, threads, anchors, messages) and read models (`SessionView` with its file tree, `FileDiffView`, `StreamView`, `Event`). Pure data. |
| `review-diff` | Line diffs (Histogram) and word diffs (Myers) between two texts through `similar`, and the builders of `FileDiffView` and `StreamView`. Pure functions. |
| `review-core` | The ports (`Forge`, `ReviewStore`, `Workspace`, `Clock`), bundled as one `Ports` value a session opens on, the `ReviewSession` facade (one module per use case under `session/`), the viewed rules, and the presenter that builds `SessionView`. The `fakes` feature adds in-memory fakes, `create_fake_ports`, and the port contract tests. |
| `review-store-fs` | The `ReviewStore` adapter: one directory per PR, three versioned JSON files written atomically (see "State on disk"). |
| `review-forge-github` | The `Forge` adapter: `gh pr view` and `gh api graphql` (queries, and the `markFileAsViewed` / `unmarkFileAsViewed` mutations with the pull request id and path sent as GraphQL variables on stdin), with a 30 second timeout per call. Adapted from dif. |
| `review-workspace-git` | Checks a PR out into a worktree: the default (`git worktree add` plus `gh pr checkout`) or a custom command that prints the path. `GitWorkspace` is the `Workspace` adapter, opened at the worktree's root (`git rev-parse --show-toplevel`) so paths stay root-relative even when `serve` starts in a subdirectory: the merge base, a file at a commit (`git cat-file --batch`), a file on disk, and renames (`git diff-index`). A missing base commit is fetched with a 90 second deadline. |
| `review-rpc` | The JSON-RPC protocol and a server over any line-based transport, with a background poller that syncs and retries refused viewed marks. |

### Inside the crates

The modules worth knowing before changing a crate. Test fixtures
(`test_support.rs`) are left out.

| Module | Responsibility |
| --- | --- |
| `review-model` `pr.rs`, `thread.rs` | The pull request (with its base and head commits), its changed files with their viewed state, and review threads with their anchors and messages |
| `review-model` `view.rs` | `SessionView` (files, the file tree, counts, the queue count, the sync state) and the `Event`s that announce a change |
| `review-model` `diff.rs` | The diff read models: `FileDiffView` for one file, `StreamView` and its rows for the stream, and `ViewMode` |
| `review-diff` `text.rs` | `FileText`: one side of a diff as missing, binary (a NUL in the first 8000 bytes, as git decides) or text split into lines without their endings |
| `review-diff` `lines.rs` | The line diff as blocks of equal and changed lines, with a 2 second deadline, and the pairing of a changed block's lines for word highlights |
| `review-diff` `words.rs` | The changed words inside a pair of lines, or none when fewer than half the tokens match |
| `review-diff` `overlay.rs` | `create_file_diff_view_from_texts`: the added lines and the removed blocks to draw above them |
| `review-diff` `stream.rs` | `create_stream_view_from_inputs`: each file's header, then its hunks with 3 lines of context or a note, as unified or split rows |
| `review-core` `ports.rs` | The port traits, the `Ports` bundle, and what the store keeps (`SessionRecord`, `SyncRegistry` with the viewed queue, `StoreSnapshot`) |
| `review-core` `session/mod.rs` | `ReviewSession`: opening on `Ports`, the state the use cases share, and the event channel |
| `review-core` `session/sync.rs` | `sync`: resend the queue, pull, let queued marks win over the pull, save, announce |
| `review-core` `session/diffs.rs` | `file_diff` and `stream`: the two sides of each diff, the base cache (merge base, renames and base texts, per base commit) and the 4 MiB size limit |
| `review-core` `session/viewed.rs` | `set_viewed` and `flush_queued`: a mark changes at once, and a mark the forge refuses is queued |
| `review-core` `viewed.rs` | Pure viewed rules: what a mark means, a queued mark winning over a pull or a stale save, and dropping marks for files no longer changed |
| `review-core` `tree.rs` | Pure: the changed paths as `TreeRow`s, directories first, a directory holding only one directory joined to it |
| `review-core` `presenter.rs` | `session_view`: the `SessionView` every frontend draws |
| `review-core` `fakes.rs` (with `fakes/workspace.rs`), `contract.rs` | The `fakes` feature: in-memory fakes of every port, `create_fake_ports`, and the contract every `ReviewStore` adapter passes |
| `review-store-fs` `format.rs`, `atomic.rs`, `paths.rs` | The versioned on-disk shapes, crash-safe replaces, and where a pull request's state lives |
| `review-forge-github` `gh.rs`, `pr.rs`, `graphql.rs` | Running `gh` with a timeout, reading `gh pr view`, and the GraphQL documents with pure parsing of their answers |
| `review-workspace-git` `checkout.rs`, `default_checkout.rs`, `custom.rs`, `repo.rs` | Checking a pull request out: the default worktree, a custom command, and finding the main checkout |
| `review-workspace-git` `workspace.rs` | `GitWorkspace`, the `Workspace` adapter |
| `review-workspace-git` `worktree_path.rs` | Reading a file the pull request names without leaving the worktree |
| `review-workspace-git` `git_output.rs` | Pure guards for what reaches git (commit ids, batch requests) and readers of its output (`cat-file --batch`, renames) |
| `review-workspace-git` `process.rs` | Running git, gh and custom commands, optionally with input on stdin, with git's repository variables cleared |
| `review-workspace-git` `unattended.rs` | Running a command nobody watches (the base fetch): no prompts, a deadline, a process group when there is a terminal, and a bounded wait for its output |
| `review-rpc` `protocol.rs` | The wire format and the protocol version |
| `review-rpc` `params.rs` | Reading request params; a missing or mistyped one is an invalid-params error |
| `review-rpc` `server.rs` | Routing requests to the session, writing events before responses, and the poller (`get_poll_step_from_elapsed` decides whether a wake-up syncs, retries or waits) |

## Patterns

- **Ports and adapters.** The engine reaches the outside world only through
  traits in `review_core::ports`. The store adapter passes the shared contract
  test for its port (`review_core::contract`).
- **Facade.** Frontends talk only to `ReviewSession`.
- **Command/query split.** `sync` and `set_viewed` change state; `view`,
  `file_diff` and `stream` read it. The RPC methods follow the same split
  (`sync` and `setViewed`; `snapshot`, `fileDiff` and `stream`).
- **Observer.** `ReviewSession::subscribe` returns a channel of `Event`s; the
  RPC server forwards them as `event` notifications.
- **Presenter.** `review_core::session_view` builds the `SessionView` every
  frontend draws, file tree included; `review-diff` builds `FileDiffView`
  (one file) and `StreamView` (every file, laid out unified or split).
- **Composition root.** Only `crates/jpr-review` builds real adapters, into
  the `Ports` that `ReviewSession::open` takes.

## Process model

`:Jpr open <n>` runs `jpr-review checkout --pr <n>` in Neovim's current
directory, which prints the worktree as JSON. A pull request URL adds
`--repo <owner/name>`: `checkout` resolves the number in the current
directory's repository, so it refuses, before creating any worktree, a pull
request from a different repository than the URL names. The plugin then opens a tab whose
directory is the worktree, opens the panel, and starts
`jpr-review serve --pr <n> --repo <owner/name>` there. After the `initialize`
handshake it asks for a `snapshot` (what was saved last) and then a `sync`.

The server reads requests on stdin, writes responses and notifications on
stdout, and syncs with GitHub in the background every 60 seconds (`--poll`).
Between syncs the poller wakes every 20 seconds and, when viewed marks are
queued, resends them; a pure `get_poll_step_from_elapsed` decides whether
a wake-up syncs, retries or waits. A sync failure keeps the last view and is announced as an
event. The reader loop and a poller thread share one `Mutex<ReviewSession>`,
and whichever one syncs writes the events it caused before doing anything
else; there is no async runtime. On `shutdown` or end of input the server
stops and joins the poller, writes any event still pending, and only then
answers `shutdown`.

### Checkout

The default checkout puts PR `n` at `<repo>-worktrees/pr-<n>` beside the main
checkout: `git worktree add --detach`, then `gh pr checkout <n> -b pr-<n>`
inside it. If that path already exists, it is reused only when it is a
worktree of this repository on branch `pr-<n>`. Anything else there is an
error and is never removed, because it may hold work git cannot see. The only
forced removal is of a worktree the same call just created, when
`gh pr checkout` fails in it. A custom `worktree_cmd` (`{n}` is the number)
replaces all of this: it must print an existing directory as its last line.

### Session lifecycle in the plugin

Each tab holds at most one session, and `:Jpr open` on a PR that already has
a tab switches to it (for a URL, only when the repository matches too). Every way a session ends (`:Jpr close`,
`:tabclose`, the engine exiting, a failed start or handshake) goes through one
`forget` path: it sends `shutdown`, stops the engine, wipes the panel and
unregisters the session, so a later `:Jpr open` starts fresh. A session is
registered only once its panel and engine are up. `rpc.start` returns
`nil, err` rather than raising when the engine cannot be started.

### Diffs

A diff compares the merge base of the pull request's base commit
(`baseRefOid`) and the checked-out head with the file on disk, so local edits
show as part of the change once saved. The session finds the merge base once
per base commit (fetching the base commit from `origin` when the repository
lacks it) and caches it with the renames since it and every base text it has
read. A renamed file is compared with its old name. A side over 4 MiB is not
diffed. Paths come from GitHub's file list, so they are untrusted: the session
serves diffs only for files in that list, and `GitWorkspace` refuses absolute
paths, `..`, `.git` and directory symlinks out of the worktree, reads a
symlink as its target's path instead of following it, and accepts only full
hex commit ids (see `docs/decisions.md`).

The engine computes the unified overlay and the stream. The split view of a
single file is Neovim's own `diff` mode against the engine's base text.

### Viewed marks

`setViewed` changes the mark at once and sends it to GitHub at once. A mark
GitHub refuses stands, is saved in `github.json`, and is counted in the view's
`queuedCount`. Every sync first resends the queue (stopping at the first
failure), drops queued marks for files the pull request no longer changes,
and lets the rest win over what it pulled; while the server polls, it also
resends the queue every 20 seconds between syncs. Every `setViewed`, and
every retry that gets a queued mark through, is announced with
`viewedChanged`. GitHub stays the authority: when a push changes a viewed
file, the next sync reports it `DISMISSED`.

## State on disk

The state of PR `n` lives in `$XDG_STATE_HOME/jpr/<owner>/<repo>/pr-<n>/`
(`~/.local/state/...` when `XDG_STATE_HOME` is unset or relative).
`jpr-review state-path` prints it. The owner and repository must each be one
plain name: empty, `.`, `..` and anything holding a path separator are
rejected.

| File | Holds |
| --- | --- |
| `session.json` | `{"version":2,"pid","worktree","pr","lastSyncedAt"}`: the daemon's pid, the worktree, the pull request (with its `baseSha`), the last successful sync (Unix seconds). Version 1 still loads, with an empty `baseSha` |
| `viewed.json` | `{"version":1,"files":[{"path","additions","deletions","viewed"}]}`: the changed files with their counts and viewed state |
| `github.json` | `{"version":1,"queuedViewed":{"<path>":true}}`: viewed marks GitHub has not accepted yet. Later milestones add the comment queues here |

- **Versioned envelopes.** A file without a `version` is rejected as corrupt.
  A file with a newer version is refused and never overwritten, so an older
  build cannot drop what a newer one added. Every file is checked before
  any is written.
- **Atomic writes.** Each write goes to a temporary file unique to that write,
  is flushed, renamed over the target, and the directory is flushed. Files are
  created with mode 0600.
- **Known limits.** The files are not written atomically as a set, and
  the directory key ignores the forge host and letter case. `github.json` is
  written first: the queue only shrinks after GitHub accepts a mark and only
  grows for a mark held locally, so a crash between files can resend a mark
  but never lose a refused one or revive one the reviewer undid. Opening a
  session applies the queue to the saved files, which a crash can leave
  behind it.

Later milestones add local threads, the comment queues in `github.json` and
agent rounds.

## The binary

`crates/jpr-review` keeps the scaffold's library-plus-thin-binary shape:
`src/main.rs` parses, calls `commands::run`, and turns an error into a stderr
line and exit code 1. Its commands are `checkout`, `serve` and `state-path`.
`prompt.rs` asks for a value left out on a terminal, and `theme.rs` holds the
semantic colors. `serve` takes only flags, because its stdin is the protocol.

## The Neovim plugin

| Module | Responsibility |
| --- | --- |
| `plugin/jpr.lua` | Defines `:Jpr` |
| `jpr` | Config, highlight groups, argument parsing, subcommand dispatch |
| `jpr.rpc` | JSON-RPC client over `jobstart` |
| `jpr.session` | One review per tab: checkout, engine process, requests, redraws of the panel, the stream and the diffs, `:Jpr toggle` and `:Jpr stream`, and the one teardown path |
| `jpr.view_mode` | The global view mode (unified or split): the one remembered in `stdpath("state")/jpr/view-mode`, else `setup({ view = ... })`'s |
| `jpr.render.panel` | Pure: `SessionView` to lines, highlights and paths. Draws the engine's `tree` (directories muted with a trailing `/`, files indented under them; a view without a tree lists each file at the top level) and adds `· N waiting for GitHub` to the counts line while viewed marks are queued |
| `jpr.render.overlay` | Pure: `FileDiffView` to extmark specs (added lines and their changed words highlighted, removed lines as virtual lines with their tabs expanded), and a base text to buffer lines |
| `jpr.render.stream` | Pure: `StreamView` to one column (unified) or two aligned columns (split), with each line's target, the file and hunk lines for navigation, the folds of viewed files, and the key that says when the stream must be fetched again |
| `jpr.views.panel` | The panel window, with its options local to it so windows split from it do not inherit them. `<CR>` opens a file only through `jpr.views.main_window`, `v` toggles viewed for the file under the cursor |
| `jpr.views.main_window` | The window beside the panel where files open; side windows (`vim.w.jpr_side`) never count. Only a plain path inside the worktree opens: `..`, `.`, an absolute path or any symlink that resolves elsewhere (dangling and looping ones included) is refused, so a save never writes outside it |
| `jpr.views.diff` | Every window in the review's tab that shows a changed file gets its `fileDiff`: extmark overlays (unified) or a read-only `jpr://base/...` window with `diffthis` (split). A window that moves to another buffer is cleared (the overlay stays while another window shows the buffer); a toggle or a moved head redraws all, a save redraws that buffer. A failed `fileDiff` is asked for again only after a toggle or moved commits |
| `jpr.views.stream` | `jpr://stream/<n>` in the main window: opened once the pull request first syncs (never over a file the reviewer opened), fetched again when its key (the view and the mode) changes, after a save and on a toggle; a toggle while a request is in flight fetches it again in the new mode. Split adds a scroll- and cursor-bound `jpr://stream/<n>/base` window on the left, wiped with its window; once the reviewer opens their own buffer there, that window is theirs (no longer a side window, never reused as the left half) and the next draw opens a new left half. Only the answer to the latest `stream` request is drawn, recorded as the view it was asked for. `<CR>` opens a file only through `jpr.views.main_window` (on a viewed file's closed fold, at the file's top; a refused path leaves the stream as it was), `v` toggles viewed and moves on only when the redraw it caused arrives, `]f` `[f` `]h` `[h` move between files and hunks (skipping hunks in closed folds). An answer that arrives after the review closed is dropped |

The panel, a split view's base window and the stream's left half are side
windows (the panel by its window id, the others by the window variable
`jpr_side`), so files and the stream always open in the main window.

Removed lines are virtual text, so Neovim draws any control character in them
as `^[`, `^M` or `^@` rather than sending it to the terminal. Lines removed
above line 1 are virtual lines above it, which Neovim keeps hidden until the
user scrolls up, so `jpr.views.diff` scrolls a window at the top of the file to
show them.

Text from the pull request (file names, the title, `gh`'s errors) is
untrusted. It reaches Ex commands only through `vim.fn.fnameescape`, and a file
is opened by its path inside the worktree, so a name like `+cmd` or `%` is
taken literally. The renderer folds newlines into spaces, because a buffer
line cannot hold one. `jpr.rpc` dispatches each line of engine output on its
own, so a callback that raises cannot swallow the messages after it.

## Tests

- `cargo test --workspace --all-features`: the engine against fakes, the
  adapters, the protocol over in-memory streams, and the dependency rule.
- `./scripts/test-lua.sh`: headless Neovim specs against
  `tests/lua/fixtures/fake_engine.sh` (and `crashing_engine.sh`, an engine
  that dies at startup). The fake engine speaks protocol 2, answers
  `fileDiff`, `stream` and `setViewed`, and logs the requests it gets. The
  script points `XDG_STATE_HOME` at a temporary directory, so specs never
  touch the real remembered view mode.
- `just check` runs both plus formatting and clippy.
