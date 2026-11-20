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
   +-- draws view models                         +--> state files
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
| `review-model` | Domain types (pull requests, changed files, threads, anchors, messages) and read models (`SessionView`, `FileRow`, `SyncState`, `Event`). Pure data. |
| `review-core` | The ports (`Forge`, `ReviewStore`, `Clock`), the `ReviewSession` facade, and the presenter that builds read models. The `fakes` feature adds in-memory fakes and the port contract tests. |
| `review-store-fs` | The `ReviewStore` adapter: one directory per PR, two versioned JSON files written atomically (see "State on disk"). |
| `review-forge-github` | The `Forge` adapter: `gh pr view` and `gh api graphql`, with a 30 second timeout per call. Adapted from dif. |
| `review-workspace-git` | Checks a PR out into a worktree: the default (`git worktree add` plus `gh pr checkout`) or a custom command that prints the path. |
| `review-rpc` | The JSON-RPC protocol and a server over any line-based transport, with a background poller. |

## Patterns

- **Ports and adapters.** The engine reaches the outside world only through
  traits in `review_core::ports`. The store adapter passes the shared contract
  test for its port (`review_core::contract`).
- **Facade.** Frontends talk only to `ReviewSession`.
- **Command/query split.** `sync` changes state; `view` reads it. The RPC
  methods follow the same split (`sync` and `snapshot`).
- **Observer.** `ReviewSession::subscribe` returns a channel of `Event`s; the
  RPC server forwards them as `event` notifications.
- **Presenter.** `review_core::session_view` builds the `SessionView` every
  frontend draws.
- **Composition root.** Only `crates/jpr-review` builds real adapters.

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
A sync failure keeps the last view and is announced as an event. Threads run
the poller and the event forwarder around one `Mutex<ReviewSession>`; there is
no async runtime.

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

## State on disk

The state of PR `n` lives in `$XDG_STATE_HOME/jpr/<owner>/<repo>/pr-<n>/`
(`~/.local/state/...` when `XDG_STATE_HOME` is unset or relative).
`jpr-review state-path` prints it. The owner and repository must each be one
plain name: empty, `.`, `..` and anything holding a path separator are
rejected.

| File | Holds |
| --- | --- |
| `session.json` | `{"version":1,"pid","worktree","pr","lastSyncedAt"}`: the daemon's pid, the worktree, the pull request, the last successful sync (Unix seconds) |
| `viewed.json` | `{"version":1,"files":[{"path","additions","deletions","viewed"}]}`: the changed files with their counts and viewed state |

- **Versioned envelopes.** A file without a `version` is rejected as corrupt.
  A file with a newer version is refused and never overwritten, so an older
  build cannot drop what a newer one added. Both files are checked before
  either is written.
- **Atomic writes.** Each write goes to a temporary file unique to that write,
  is flushed, renamed over the target, and the directory is flushed. Files are
  created with mode 0600.
- **Known limits.** The two files are not written atomically as a pair, and
  the directory key ignores the forge host and letter case.

Later milestones add local threads, the sync registry and agent rounds.

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
| `jpr.session` | One review per tab: checkout, engine process, panel updates, and the one teardown path |
| `jpr.render.panel` | Pure: `SessionView` to lines, highlights and paths |
| `jpr.views.panel` | The panel window; `<CR>` opens a file |

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
  that dies at startup).
- `just check` runs both plus formatting and clippy.
