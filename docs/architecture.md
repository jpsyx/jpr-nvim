# Architecture

jpr-nvim is a pull-request review engine in Rust with a Neovim plugin on top.
The engine is frontend-neutral on purpose: Neovim is its first frontend, and
other frontends (a terminal UI, for reviewers who do not use Neovim) are meant
to reuse it. Extend this document as the shape changes.

## Layers

```
Neovim (lua/jpr)  --JSON-RPC over stdio-->  jpr-review serve (one per PR)
   ^  events                                     ^  ^ owns the session
   |                                             |  |
   +-- draws view models                         |  +-- Unix socket (agent CLI)
                                                 |
                                                 +--> gh (GitHub)
                                                 +--> git (the worktree)
                                                 +--> state files + rounds.jsonl
```

| Kind | Crates and paths | May depend on |
| --- | --- | --- |
| Generic engine | `crates/review-*` | std, small general-purpose crates, other `review-*` crates |
| Frontend TUI library | `crates/cli-tui` | std, `anyhow`, `crossterm` (never depended on by `crates/review-*`) |
| Composition root | `crates/jpr-review` | `crates/review-*`, `crates/cli-tui` |
| Neovim adapter | `build.lua`, `lua/jpr`, `plugin/jpr.lua` | the protocol in `docs/protocol.md` |

**The dependency rule.** A generic crate never depends on Neovim, Lua, a
terminal UI library, or a frontend crate, directly or transitively.
`crates/cli-tui` is a reusable frontend-layer TUI crate that lives outside
`crates/review-*` specifically so `crossterm` and terminal rendering never leak
into the generic engine. `crates/jpr-review/tests/dependency_rule.rs` enforces
this against `cargo metadata`: a `review-*` crate may not reach a known UI or
editor crate, or a workspace crate outside `review-*`, through its runtime
dependencies. Dev-dependencies are exempt. Generic crate names never contain
`nvim` or `jpr`.

**Where logic goes.** If a decision would be the same in a terminal UI, it is
Rust in a generic crate. Lua manages windows, buffers and keys, and draws the
read models the engine returns.

## The generic crates

| Crate | Responsibility |
| --- | --- |
| `review-model` | Domain types (pull requests, changed files, threads, local/GitHub origin, anchors, messages, reactions, review events, mention candidates, submit previews, agent rounds/profiles/plans, forge owner/repo discovery) and read models (`SessionView` with its file tree and `WorktreeStatus`, `PushResult`, `HeadMoveOutcome`, `FileDiffView`, `StreamView`, `SuggestedEdit`, `ThreadPreview`, `Event`). Pure data. |
| `review-diff` | Line diffs (Histogram) and word diffs (Myers) between two texts through `similar`, suggestion extraction from local edits (`suggest.rs`), and the builders of `FileDiffView` and `StreamView` (with attached `ThreadPreview`s). Pure functions. |
| `review-core` | The ports (`Forge`, `ReviewStore`, `Workspace`, `Clock`), bundled as one `Ports` value a session opens on, structured auth classification (`auth.rs`: `ForgeAuthError`, `AUTH_EXIT_CODE = 3`), the `ReviewSession` facade (one module per use case under `session/`), pure viewed, comment, re-anchoring, and agent prompt/guide rules, and the presenter that builds `SessionView`. The `fakes` feature adds in-memory fakes, `create_fake_ports`, and the port contract tests. |
| `review-store-fs` | The `ReviewStore` adapter: one directory per PR, four versioned JSON files written atomically (`session.json`, `viewed.json`, `github.json`, `local.json`) plus `rounds.jsonl` and `local.lock` (see "State on disk"). |
| `review-forge-github` | The `Forge` adapter: `gh pr view`, `gh api graphql` (queries and mutations for viewed marks, pending reviews, review threads, PR comments, edits, deletions, resolution, reactions, and review submission), `gh api` REST immediate thread replies with pending-review GraphQL fallback, owner/repository discovery (`discovery.rs`), and structured `ForgeAuthError` classification, with a 30 second timeout per call. Adapted from dif. |
| `review-workspace-git` | Checks a PR out into a worktree: the default (`git worktree add` plus `gh pr checkout`) or a custom command that prints the path, plus on-demand managed repository clones under `$XDG_CACHE_HOME/jpr/repos/<owner>/<repo>` (`cache.rs`) when checking out outside any local git repository. `GitWorkspace` is the `Workspace` adapter, opened at the worktree's root (`git rev-parse --show-toplevel`) so paths stay root-relative even when `serve` starts in a subdirectory: the merge base, `HEAD` and unlocked worktree dirty/ahead/behind status, a file at a commit (`git cat-file --batch`), a file on disk, renames (`git diff-index`), changed worktree files since base/commit, branch-safe `HEAD:refs/heads/<head_ref>` push, and auto-stash `--ff-only` fast-forward. Missing commits and pushes run unattended with a 90 second deadline. |
| `review-rpc` | The JSON-RPC protocol (`PROTOCOL_VERSION = 9`, including `-32001` `AUTH_REQUIRED` and `syncFailed.{authRequired, isBackground}`), stdio server (including `refreshWorktree`, `serve --local`, and `streamProgress` notifications during `stream`), allowlisted Unix domain socket listener, and background poller that syncs and retries linked PR sessions (`sync_background`, `flush_queued_background`) while always watching worktree files and git status for re-anchoring and live refresh. |

### Inside the crates

The modules worth knowing before changing a crate. Test fixtures
(`test_support.rs`) are left out.

| Module | Responsibility |
| --- | --- |
| `review-model` `pr.rs`, `thread.rs`, `review.rs`, `forge.rs` | The pull request (with its base and head commits), changed files with viewed state, review threads (`Origin`, `Anchor`, `Message`, `MessageSync`, `ThreadPreview`, `promotedTo`), review metadata (`Reaction`, `ReactionContent`, `ReviewEvent`, `MentionCandidate`, `SubmitPreview`), and forge discovery records (`OwnerKind`, `ForgeOwner`, `ForgeRepo`) |
| `review-model` `agent.rs` | Local agent types: `AgentThreadState` (`unsent`, `sent`, `answered`), `AgentKind` (`claude`, `codex`), `AgentProfile`, `AgentLaunchPlan`, `AgentRoundKind` (`send`, `prepass`, `conflict`), `AgentRound`, `AgentDispatch`, `PrepassFinding`, and `LocalAnchorUpdate` |
| `review-model` `view.rs` | `SessionView` (`FileRow` with `isModified`, `localThreads`, and `isLocalOnly`, file tree, viewed/thread/draft/conversation/local-unsent/queue counts, sync state, `WorktreeStatus`), `PushResult`, `HeadMoveOutcome`, and the `Event`s (`Synced`, `SyncFailed`, `ViewedChanged`, `ThreadsChanged`, `FilesChanged`, `AgentRound`, `WorktreeStatusChanged`, `HeadMoved`) |
| `review-model` `diff.rs` | The diff read models: `FileDiffView` (with `threads`), `StreamView` (with `StreamRow::Thread` and per-line `threads`), `SuggestedEdit`, and `ViewMode` |
| `review-diff` `text.rs` | `FileText`: one side of a diff as missing, binary (a NUL in the first 8000 bytes, as git decides) or text split into lines without their endings |
| `review-diff` `lines.rs` | The line diff as blocks of equal and changed lines, with a 2 second deadline, and the pairing of a changed block's lines for word highlights |
| `review-diff` `words.rs` | The changed words inside a pair of lines, or none when fewer than half the tokens match |
| `review-diff` `overlay.rs` | `create_file_diff_view_from_texts` and `create_file_diff_view_with_threads`: added lines, removed blocks above them, and `ThreadPreview`s placed at `display_line` |
| `review-diff` `stream.rs` | `create_stream_view_from_inputs`: each file's header, unplaced/file `StreamRow::Thread` banners, then hunks with 3 lines of context (and line-attached `ThreadPreview`s) or a note, as unified or split rows |
| `review-diff` `suggest.rs` | `create_suggestion_from_edit`: diffs local edits around the cursor against `head_sha` to build a fenced GitHub `suggestion` block and `reverted_text` for only that hunk |
| `review-core` `auth.rs` | Structured `gh` auth-failure classification (`AUTH_EXIT_CODE = 3`, `ForgeAuthError`, `is_auth_error`, `is_gh_auth_failure_text`) shared across `review-forge-github`, `review-workspace-git`, `review-rpc`, and `jpr-review` |
| `review-core` `ports.rs` | The port traits (`Forge`, `Workspace`, `ReviewStore`, `Clock`), `FastForwardOutcome`, `QueuedCommentOp`, `ForgeWriteError` (including `AuthRequired`), and what the store keeps (`SessionRecord` with socket/agent fields, `SyncRegistry`, `LocalStoreState`, `StoreSnapshot`) |
| `review-core` `session/mod.rs` | `ReviewSession`: opening on `Ports` in PR (`open`) or unlinked local worktree (`open_local`) mode via `SessionTarget::{Pr, Local}`, shared state (`pushed_head`, `last_worktree_status`, `pending_head_move_from`), and the event channel |
| `review-core` `session/link.rs` | Mid-session local-to-PR upgrade (`sync_or_link_local`): probes `current_branch_pr`, fetches snapshot before retargeting, merges preexisting PR state (renumbering colliding `loc-*` IDs and keeping live daemon/agent fields and authoritative local `VIEWED` state), pins forge repo, switches `SessionTarget::Pr`, runs `apply_pull` (promoting local `VIEWED` to GitHub), and calls `finalize_retarget()` |
| `review-core` `session/sync.rs` | `sync`: resend queued viewed marks, pull, reconcile concurrent edits and unflushed threads, replay queued comment ops, save, fast-forward and re-anchor non-conflicted local threads when `pr.head_sha` moves (`HeadMoved` before `Synced`, retaining `pending_head_move_from` to self-heal failed fast-forwards or saves on the next sync), and announce |
| `review-core` `session/push.rs` | `push`: ahead/behind/dirty guards, pushing `HEAD` to `head_ref`, `PushedHead` tracking so GitHub `headRefOid` propagation lag or post-push sync failure does not report spurious `ahead` commits, and returning `PushResult` |
| `review-core` `session/diffs.rs` | `file_diff`, `stream`, and `stream_with_progress` (invoking a pure Rust `(completed, total, path)` callback per file so `review-core` stays UI-free): the two sides of each diff, `BaseCache` keyed on `(base_sha, head_sha)` (merge base, renames, and base texts invalidated whenever `base_sha` or checked-out `HEAD` moves), and the 4 MiB size limit |
| `review-core` `session/viewed.rs` | `set_viewed` and `flush_queued`: a mark changes at once, queued marks and comment ops are flushed between syncs |
| `review-core` `session/comments.rs` (with `session/comments/` `helpers.rs`, `queue/mod.rs`, `queue/prune.rs`, `reconcile.rs`, `replay.rs`) | GitHub comment creation, replies, edits, deletions, resolution, reactions, `retry_message`, origin-split anchor validation (`validate_github_anchor_file` blocking GitHub comments on local-only files until pushed vs `validate_local_anchor_file` allowing effective files), optimistic `tmp-*` IDs, FIFO queue replay, ID remapping (`id_map`), and `threadsChanged` announcements |
| `review-core` `session/local.rs` | Local-only threads (`loc-*`): creation (`origin = local`), local replies, edits, deletions, resolution, reactions, `agent_reply` (marks thread `answered` and enforces non-local refusal), and `promote_thread` (creates GitHub comment with snapshot stripped and links `promotedTo`, refusing local-only files until pushed) |
| `review-core` `session/local_files.rs` | Effective worktree file merging (`effective_files`, `refresh_local_files`), `local_viewed` persistence/dismissal/promotion/pruning (`dismiss_edited_local_viewed`, `promote_adopted_local_viewed`, `prune_stale_local_viewed`), rename anchor and `local_viewed` migration (`PathRename`, `rewrite_renamed_path`), and immediate `refresh_worktree` refresh |
| `review-core` `session/agent_loop.rs` | `prepare_agent_launch`, `prepare_send`, `confirm_send` (`send`, `prepass`, and `conflict`), `prepare_prepass`, `prepare_conflict_resolution`, and `prepass_write` (round numbering, `rounds.jsonl` logging, rollback on store failure) |
| `review-core` `session/worktree_watch.rs` | `update_local_anchors` (from editor extmarks) and `poll_worktree_files` (file digest change detection, `FilesChanged` emission, automatic local thread re-anchoring, and `WorktreeStatusChanged` emission when git dirty/ahead/behind status changes) |
| `review-core` `session/submit.rs` | `anchored_lines`, `suggest_from_edit`, `submit_preview`, and `submit_review` (blocking self-approval and queued/failed comments) |
| `review-core` `comments.rs` | Pure comment transitions: `remap_queued_ops`, `record_agreed_bodies`, `reconcile_concurrent_edits`, `merge_unflushed_threads`, `toggle_reaction_in_list`, `create_submit_preview_from_threads`, `count_code_threads` |
| `review-core` `reanchor.rs` | Pure local anchor utilities: `extract_snapshot_from_text`, `reanchor_thread_in_text`, `normalize_line_bounds`, `apply_anchor_update`, `validate_safe_relative_path`, `normalize_prepass_anchor` |
| `review-core` `agent.rs` | Pure agent helpers: `is_thread_dispatchable`, `select_dispatchable_threads`, `build_send_prompt_from_threads`, `build_prepass_prompt_from_pr`, `build_conflict_prompt_from_paths`, deterministic RFC 4122 v4 UUID generation, `AgentKind`/`AgentProfile` helpers |
| `review-core` `guide.rs` | `build_agent_guide`: the agent contract printed by `jpr-review guide` |
| `review-core` `viewed.rs` | Pure viewed rules: what a mark means, a queued mark winning over a pull or a stale save, and dropping marks for files no longer changed |
| `review-core` `tree.rs` | Pure: the changed paths as `TreeRow`s, directories first, a directory holding only one directory joined to it |
| `review-core` `presenter.rs` | `session_view`: the `SessionView` (including `is_modified` and `local_threads` per file, `local_unsent_count`, and `worktree_status`) every frontend draws |
| `review-core` `fakes.rs` (with `fakes/workspace.rs`, `fakes/comments.rs`), `contract.rs` | The `fakes` feature: in-memory fakes of every port, `create_fake_ports`, and the contract every `ReviewStore` adapter passes |
| `review-store-fs` `format.rs`, `atomic.rs`, `lock.rs`, `paths.rs`, `retarget.rs` | The versioned on-disk shapes (`session.json` v3 with v1/v2 compat, `viewed.json` v1, `github.json` v2 with v1 compat, `local.json` v1), append-only `rounds.jsonl`, advisory exclusive `local.lock` (`mutate_local_locked`), crash-safe replaces, PR and local state directories (`state_dir`, `local_state_dir`), and two-phase crash-safe `retarget_to_pr` / `finalize_retarget` |
| `review-forge-github` `gh.rs`, `pr.rs`, `graphql.rs`, `discovery.rs`, `mutations.rs` (with `mutations/documents.rs`) | Running `gh` with a timeout and wrapping unauthenticated failures as `ForgeAuthError`, reading `gh pr view` (including `current_branch_pr` auto-detection and dynamic `pin_repo`), paginated viewer/org and repository discovery (`list_owners`, `list_repos`), GraphQL queries/mutations (threads, PR comments, pending reviews, mentions, reactions, review submission), REST immediate replies with 422 GraphQL fallback, and transient vs rejected vs `AuthRequired` error classification |
| `review-workspace-git` `checkout.rs`, `default_checkout.rs`, `cache.rs`, `custom.rs`, `repo.rs`, `local_ref.rs`, `worktree_reuse.rs` | Checking a pull request out (reusing an already checked-out worktree via `git worktree list --porcelain` and `session.json` before invoking default or custom checkout), on-demand managed clones under `$XDG_CACHE_HOME/jpr/repos/<owner>/<repo>` (`ensure_managed_clone`) for out-of-repo checkouts, finding the main checkout, and inspecting the current worktree (`inspect_local_worktree`, `resolve_default_base_branch`, `validate_git_ref`, `read_current_branch`) |
| `review-workspace-git` `workspace.rs` | `GitWorkspace`, the `Workspace` adapter (`merge_base`, `head_commit`, `file_at`, `file_on_disk`, `renames`, `list_changed_files_since`, `worktree_status`, `push_head`, and `fast_forward_to`) |
| `review-workspace-git` `status.rs` | Unlocked (`GIT_OPTIONAL_LOCKS=0`) `read_head_commit` and `read_worktree_status` (`git status --porcelain=v1 -z --untracked-files=all` plus `git rev-list --left-right --count` against the remote PR head or `@{upstream}`) |
| `review-workspace-git` `push.rs` | Branch-safe `push_head_to_pr_branch`: validates `head_ref`, resolves `branch.<local>.pushRemote`/`remote` (or `origin`), rejects mismatched `branch.<local>.merge` targets, and pushes `HEAD:refs/heads/<head_ref>` unattended |
| `review-workspace-git` `fast_forward/mod.rs`, `fast_forward/stash.rs` | `fast_forward_worktree`: ancestry and active git sequencer/rebase/merge/bisect checks, nonce-pinned auto-stash (`git stash push --include-untracked` matched by parent SHA and `[pid-seq]` marker), `git merge --ff-only --no-overwrite-ignore`, and SHA-pinned `git stash apply <stash_sha>` restore with conflict/untracked-collision detection |
| `review-workspace-git` `worktree_path.rs` | Reading a file the pull request names without leaving the worktree |
| `review-workspace-git` `git_output.rs` | Pure guards for what reaches git (commit ids, batch requests) and readers of its output (`cat-file --batch`, renames, NUL-delimited porcelain/diff paths) |
| `review-workspace-git` `process.rs` | Running git (`run`, unlocked `run_bytes_unlocked`), gh and custom commands, optionally with input on stdin, with git's repository variables cleared |
| `review-workspace-git` `unattended.rs` | Running a command nobody watches (base/head fetches and `git push`): no prompts, a deadline, a process group when there is a terminal, and a bounded wait for its output |
| `review-rpc` `protocol.rs` | The wire format, `RpcError::AUTH_REQUIRED` (`-32001`), and the protocol version (`PROTOCOL_VERSION = 9`) |
| `review-rpc` `params.rs` | Reading request params (`path`, `paths`, `viewed`, `mode`, `anchor`, `origin`, `content`, `agent`, `kind`, `round`, `findings`, `updates`, `renames`, etc.); a missing or mistyped one is an invalid-params error |
| `review-rpc` `socket.rs`, `socket/io.rs` | Unix domain socket listener with `0600` permissions, 64-client cap, bounded 1 MiB framing, and method allowlist (`snapshot`, `threads`, `agentReply`, `prepassWrite`) |
| `review-rpc` `server.rs`, `server/comments.rs`, `server/agent.rs`, `server/ticker.rs` | Routing requests to the session (including `push`, `refreshWorktree`, comment, suggestion, review submission, agent launch/dispatch, pre-pass, conflict resolution, and anchor update methods), handling `stream` via `ReviewSession::stream_with_progress` to write `streamProgress` JSON-RPC notifications directly to stdio per file before the `stream` response arrives, writing events immediately to stdio, and the poller (`get_poll_step_from_elapsed` + 2 second worktree file and git status watch) |

## Patterns

- **Ports and adapters.** The engine reaches the outside world only through
  traits in `review_core::ports`. The store adapter passes the shared contract
  test for its port (`review_core::contract`).
- **Facade.** Frontends talk only to `ReviewSession`.
- **Command/query split.** `sync`, `push`, `set_viewed`, comment/local mutations,
  agent launch/confirm/reply/prepass, anchor updates, and `submit_review`
  change state; `view`, `threads`, `mentions`, `anchored_lines`,
  `submit_preview`, `file_diff`, and `stream` read it. The RPC methods follow
  the same split.
- **Observer.** `ReviewSession::subscribe` returns a channel of `Event`s; the
  RPC server forwards them as `event` notifications to stdio even when triggered
  by a Unix socket client or the background worktree watcher.
- **Presenter.** `review_core::session_view` builds the `SessionView` every
  frontend draws, file tree included; `review-diff` builds `FileDiffView`
  (one file) and `StreamView` (every file, laid out unified or split).
- **Composition root.** Only `crates/jpr-review` builds real adapters, into
  the `Ports` that `ReviewSession::open` takes.

## Process model

`:Jpr open <n>` immediately opens a PR tab showing the 4-stage loading view
(`jpr.views.loading`) and runs `jpr-review checkout --pr <n>` in Neovim's
current directory, streaming checkout stderr into stage 1 while `checkout`
prints the worktree as JSON on stdout (closing the tab mid-checkout cancels the
pending process). A pull request URL adds `--repo <owner/name>`: `checkout`
resolves the number in the current directory's repository, so it refuses, before
creating any worktree, a pull request from a different repository than the URL
names. Once checkout finishes, the plugin sets the tab's directory to the
worktree, opens the panel, starts `jpr-review serve --pr <n> --repo <owner/name>`
(stage 2), runs the `initialize` handshake (which checks both `protocolVersion`
and release `version`), asks for a `snapshot` (what was saved last) and a `sync`
(stage 3), and streams per-file `streamProgress` percentages (stage 4) until the
first stream draws and replaces the loading buffer.

The server reads requests on stdin, writes responses and notifications on
stdout, binds an allowlisted Unix domain socket (recorded in `session.json`),
and syncs with GitHub in the background every 60 seconds (`--poll`). Between
syncs the poller wakes every 20 seconds to retry queued viewed marks or comment
ops (`get_poll_step_from_elapsed`), and wakes every 2 seconds to check
worktree files and git status (`poll_worktree_files`) for disk edits, local
thread re-anchoring, and dirty/ahead/behind changes. A sync failure keeps the
last view and is announced as an event.
The reader loop, Unix socket client handlers, and poller share one
`Mutex<ReviewSession>`. Requests handled over the Unix socket (`agentReply`,
`prepassWrite`) flush the events they emit straight to stdout so Neovim redraws
immediately. On `shutdown` or end of input the server stops the socket and
poller, clears `socket` from `session.json`, writes any event still pending,
and only then answers `shutdown`.

### Checkout

The default checkout puts PR `n` at `<repo>-worktrees/pr-<n>` beside the main
checkout: `git worktree add --detach`, then `gh pr checkout <n> -b pr-<n>`
inside it. When `jpr-review checkout --pr <n> --repo <owner/name>` runs outside
any local git repository, `ensure_managed_clone` clones `<owner>/<repo>` once
on demand into `$XDG_CACHE_HOME/jpr/repos/<owner>/<repo>` (default
`~/.cache/jpr/repos/<owner>/<repo>`) using `gh repo clone` and reuses that
managed clone as the main checkout (putting PR worktrees beside it at
`$XDG_CACHE_HOME/jpr/repos/<owner>/<repo>-worktrees/pr-<n>`). If that worktree
path already exists, it is reused only when it is a worktree of this repository
on branch `pr-<n>`. Anything else there is an error and is never removed,
because it may hold work git cannot see. The only forced removal is of a
worktree the same call just created, when `gh pr checkout` fails in it. A
custom `worktree_cmd` (`{n}` is the number) replaces all of this: it must print
an existing directory as its last line.

### Session lifecycle in the plugin

Each tab holds at most one session, and `:Jpr open` on a PR that already has
a tab switches to it (for a URL, only when the repository matches too).
Intentional closes (`:Jpr close`, `:tabclose`) and startup failures (engine
cannot spawn or fails the initial `initialize` handshake) go through one
`forget` path: it stops any live agent terminal job, sends `shutdown`, stops
the engine, wipes the panel and unregisters the session, so a later `:Jpr open`
starts fresh. Once `session.ready` is reached, an unexpected engine exit is
handled by `jpr.session.crash`: it appends the exit code and stderr to
`stdpath("state")/jpr/engine-pr-<n>.log` (`0600`), restarts the engine once
from the persisted `$XDG_STATE_HOME/jpr` files, and on a second crash (or
failed restart handshake) transitions the session into `[read-only]` mode while
preserving open buffers and compose drafts. A session is registered only once
its panel and engine are up. `rpc.start` returns `nil, err` rather than raising
when the engine cannot be started.

### Diffs

A diff compares the merge base of the pull request's base commit
(`baseRefOid`) and the checked-out `HEAD` with the file on disk, so local edits
show as part of the change once saved. The session finds the merge base once
per `(baseSha, HEAD)` pair (fetching the base commit from `origin` when the
repository lacks it, and invalidating the cache whenever `baseSha` or
checked-out `HEAD` moves) and caches it with the renames since it and every base
text it has read. A renamed file is compared with its old name. A side over 4 MiB is not
diffed. Paths come from GitHub's file list, so they are untrusted: the session
serves diffs only for files in that list, and `GitWorkspace` refuses absolute
paths, `..`, `.git` and directory symlinks out of the worktree, reads a
symlink as its target's path instead of following it, and accepts only full
hex commit ids (see `docs/decisions.md`).

The engine computes the unified overlay and the stream. The split view of a
single file is Neovim's own `diff` mode against the engine's base text.

### Viewed marks and comment operations

`setViewed` changes the mark at once and sends it to GitHub at once. A mark
GitHub refuses stands, is saved in `github.json`, and is counted in the view's
`queuedCount`. Every sync first resends the viewed queue (stopping at the first
failure), pulls, reconciles concurrent comment edits and unflushed threads,
replays `queuedOps` in FIFO order, drops queued marks for files the pull
request no longer changes, and lets the rest win over what it pulled; while the
server polls, `flush_queued` also resends both queues every 20 seconds between
syncs. Every `setViewed`, and every retry that gets a queued mark through, is
announced with `viewedChanged`; every comment write or background retry that
progresses `queuedOps` announces `threadsChanged`. GitHub stays the authority:
when a push changes a viewed file, the next sync reports it `DISMISSED`.

For comments, transient forge failures queue the operation in `queuedOps` with
optimistic `tmp-*` ids (`nextTempId`, resolved later via `idMap`), while
validation rejections on `comment`, `reply`, or `editMessage` mark the message
`failed` with `syncError` so the reviewer can edit, retry (`retryMessage`), or
delete it without blocking subsequent queued operations. `agreedBodies` records
the last forge-confirmed body per message so an offline edit whose remote body
changed on GitHub preserves the local edit in `recoverableBody` instead of
overwriting the remote edit.

Local threads (`origin = "local"`, `loc-*` ids) live exclusively in
`local.json` and are never pushed to GitHub unless explicitly promoted with
`promoteThread` (which strips the anchored snapshot before creating the GitHub
comment and records `promotedTo`). Local `RIGHT`-side `line` and `range`
anchors track live buffer edits via extmarks (`BufWritePost` ->
`updateLocalAnchors`) and background disk edits (`poll_worktree_files`),
re-anchoring against surrounding snapshot text or marking `outdated` when
removed.

## State on disk

The state of PR `n` lives in `$XDG_STATE_HOME/jpr/<owner>/<repo>/pr-<n>/`
(`~/.local/state/...` when `XDG_STATE_HOME` is unset or relative).
`jpr-review state-path` prints it. The owner and repository must each be one
plain name: empty, `.`, `..` and anything holding a path separator are
rejected.

| File | Holds |
| --- | --- |
| `session.json` | `{"version":3,"pid","socket","agentSessionId","agentKind","worktree","pr","lastSyncedAt"}`: the daemon's pid, live Unix socket path when serving, persistent coding-agent session id and kind, the worktree, the pull request (with its `baseSha`), and the last successful sync (Unix seconds). Versions 1 and 2 still load |
| `viewed.json` | `{"version":1,"files":[{"path","additions","deletions","viewed"}]}`: the changed files with their counts and viewed state |
| `github.json` | `{"version":2,"queuedViewed","pendingReviewId","viewerLogin","nextTempId","idMap","agreedBodies","threads","queuedOps","mentionCandidates"}`: queued viewed marks, active pending review node id, authenticated viewer login, optimistic `tmp-*` id counter and `idMap`, `agreedBodies` for concurrent-edit detection, persisted `threads` (published, draft, queued, and failed), queued comment operations (`queuedOps`), and cached `@mention` candidates. Version 1 (`queuedViewed` only) still loads with defaults for the version 2 fields |
| `local.json` | `{"version":1,"nextLocalId","nextRound","threads","localViewed"}`: monotonic `loc-*` thread/message counter, monotonic agent round counter, persisted local threads (`origin = "local"`, `agent` state, optional `promotedTo`), and `localViewed` map persisting `VIEWED`/`DISMISSED` state for local-only worktree files (defaults to empty for older v1 files) |
| `rounds.jsonl` | Append-only JSON Lines log (`0600`) of `AgentRound` records (`round`, `kind`, `threadIds`, `prompt`, `sentAt`) |
| `local.lock` | Advisory exclusive lockfile (`O_CREAT\|O_EXCL`, 5 second timeout, 30 second stale eviction) serializing `local.json` and `rounds.jsonl` writes between the daemon and offline fallback CLI commands |

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

## Frontend TUI crate (`crates/cli-tui`)

`crates/cli-tui` is a reusable frontend-layer schema-to-TUI crate kept outside
`crates/review-*` so generic engine crates stay UI-free.

| Module | Responsibility |
| --- | --- |
| `cli-tui` `schema/` (`mod.rs`, `validate.rs`, `active.rs`) | Pure declarative schema types (`CommandSpec`, `StepSpec`, `StepKind`, `SelectOption`, `WhenPredicate`), schema validation (`validate_command_specs`), active-step resolution (`get_active_steps_from_command`), and abandoned-branch pruning (`prune_inactive_answers`) |
| `cli-tui` `state/` (`mod.rs`, `palette.rs`, `wizard/mod.rs`, `wizard/input.rs`) | Pure Neovim-conventional Normal-vs-Insert state machines for the top-level Command Palette and discriminant-first steppers (zero terminal I/O) |
| `cli-tui` `render/` (`mod.rs`, `text.rs`, `wizard.rs`) | Pure ANSI frame builders (`render_palette`, `render_wizard`) with human-readable labels paired with `[<id>]`, hover-only dim helper text, step headers, and footer hints |
| `cli-tui` `runner/` (`mod.rs`, `keys.rs`, `terminal.rs`) | Thin `crossterm` terminal shell: strict `is_interactive_terminal()` TTY gating (stdin + stderr), RAII `RawModeGuard` cleanup on exit/cancel/error, and stderr rendering so stdout stays pure data |

## The binary

`crates/jpr-review` keeps the scaffold's library-plus-thin-binary shape:
`src/main.rs` parses, opens the interactive Command Palette (`cli-tui`) when
invoked bare on a TTY (or prints help to stderr with exit code `2` without a
TTY), launches a command's stepper when invoked on a TTY with missing required
inputs, calls `commands::run_command`, and turns any error into a stderr line
with exit code `3` when `is_auth_error` detects missing/expired `gh`
authentication or exit code `1` otherwise. Its subcommands are `checkout`,
`local`, `prs`, `owners`, `repos`, `serve`, `state-path`, `guide`, `threads`,
`reply`, and `prepass-write`:

- `owners` (`crates/jpr-review/src/commands/owners.rs`) lists the authenticated
  viewer followed by their GitHub organizations as a JSON array, backing the
  non-repo owner picker.
- `repos` (`crates/jpr-review/src/commands/repos.rs`) lists repositories for an
  owner (or the authenticated viewer when `--owner` is omitted) as a JSON array
  (`--owner`, `--limit`), backing the non-repo repository picker.
- `prs` (`crates/jpr-review/src/commands/prs.rs`) lists open pull requests in a
  repository as a JSON array (`--repo`, `--limit`), backing both scripting and
  interactive open-PR pickers.
- `crates/jpr-review/src/tui_schema/` (`mod.rs`, `specs.rs`, `steps.rs`,
  `prefill.rs`, `convert.rs`, `tests/`) declares a `CommandSpec` for every
  `Command` variant in `cli.rs` with discriminant-first steps, smart defaults,
  and typed answer-to-`Command` conversions.
- `prompt.rs` handles line-prompt fallback and non-TTY flag errors, and
  `theme.rs` holds the semantic colors.
- `serve` takes only flags when driven non-interactively because its stdin is
  the protocol. `threads`, `reply`, and `prepass-write` connect to the running
  daemon over its Unix domain socket (`--socket`, `$JPR_SOCKET`, or
  `session.json`) and fall back to reading or locking (`local.lock`) the store
  on disk when no daemon is running.

## The Neovim plugin

| Module | Responsibility |
| --- | --- |
| `build.lua` | Root `lazy.nvim` build hook: prepends the checkout's `lua/` search path, clears cached `jpr.build` and `jpr.binary` entries in `package.loaded` on `:Lazy update`, and delegates to `jpr.build` without changing Neovim's global working directory |
| `plugin/jpr.lua` | Defines `:Jpr` (with range support), the `<Plug>(jpr-*)` mappings (including `<Plug>(jpr-palette)`), and the default `<leader>J` normal-mode shortcut for bare `:Jpr` |
| `jpr` | Release `VERSION`, config (including optional `binary` override, `agent`, `claude_cmd`, `codex_cmd`, `agent_width`, and `keys` with global `palette = "<leader>J"`), `binary_path()`, highlight registration via `jpr.highlights`, lazy `require("jpr").statusline()` (`""` without loading `jpr.session` until a review opens), argument parsing, schema-derived subcommand and direct-argument completion (`toggle`, `comment`, `agent`), command-alias resolution before dispatch (`review` for `open`, `self` for `local`), bare `:Jpr` Command Palette, `:Jpr keys`, and `:Jpr open` PR picker dispatch (plus `:Jpr <n|#n|URL>` shorthand for `:Jpr open`), global (`bind_global_keys`) and buffer (`bind_buffer_keys`) keybinding, and `<Plug>(jpr-*)` action dispatch |
| `jpr.highlights` (`lua/jpr/highlights/`: `init.lua`, `contrast.lua`) | Defines semantic `Jpr*` highlight links (`default = true`), computes soft background-only diff tints (`JprDiffAdd`, `JprDiffAddText`, `JprDiffDelete`, `JprDiffDeleteText`) blended from `Normal.bg` (with dark/light presets when `Normal.bg` is nil), and lazily derives hue-locked OKLCH contrast-adjusted foreground companion groups (`JprDiffAddFg_*`, `JprDiffDeleteFg_*`) with a same-hue guard, automatically refreshed (or relinked on fg loss) on `ColorScheme` without overwriting user overrides |
| `jpr.commands.schema` (`lua/jpr/commands/schema.lua`) | Declarative schema for all 16 `:Jpr` subcommands (including `keys`; human-readable labels paired with `[<id>]`, concise helper text, smart defaults, runtime executability `when` predicates for commands and comment scope options, discriminant-first steps including the async open-PR picker backed by `jpr-review prs`, and single-step argument completion). `COMMAND_ALIASES` maps extra typed names onto those ids (`review` to `open`, `self` to `local`). Aliases resolve before dispatch and stay out of the palette and completion |
| `jpr.tui.schema` (`lua/jpr/tui/schema.lua`) | Pure declarative command/step schema validation (`select`, `async_select`, `toggle`, `text`, plus command and option `when` predicates), executable-command and select-option filtering (`is_command_executable`, `get_active_commands`, `get_active_options_from_step`), step `when` predicate resolution (`get_active_steps_from_command`), default resolution, and abandoned-branch pruning |
| `jpr.tui.render` (`lua/jpr/tui/render.lua`) | Pure layout builder for the floating Command Palette and steppers: filters palette commands to executable items only, draws human-readable labels (unselected in normal text, selected in `JprTitle`), `[<id>]` badges, indented dim hover-only helper text underneath the selected row, step progress headers, and footer key hints |
| `jpr.tui.wizard` (`lua/jpr/tui/wizard/`: `init.lua`, `window.lua`, `palette.lua`, `step_menu.lua`, `step_text.lua`) | Floating Command Palette and multi-step wizard modal controller implementing executable-only palette filtering on open, select-option `when` filtering, centered rounded floating windows, viewport geometry clamping, extmark painting, Neovim-conventional Normal-mode (`j`/`k`/`h`/`l`/`gg`/`G`/`<Tab>`/`<S-Tab>`/`<CR>`/`q`/`<Esc>`) and Insert-mode text-step controls, async option loading, and step-back/return-to-palette navigation |
| `jpr.binary` (`lua/jpr/binary.lua`) | Resolves the plugin checkout root, the bundled `target/release/jpr-review` binary path (`.exe` on Windows), `config.binary` overrides, and `:Jpr agent` terminal `PATH` prepending (`create_agent_env_from_session`) |
| `jpr.build` (`lua/jpr/build.lua`) | Finds `cargo` across `PATH`, `$CARGO_HOME/bin`, and `~/.cargo/bin`, yields build progress only inside `lazy.nvim`'s `lazy.async` coroutine, compiles `target/release/jpr-review` in the plugin root via `vim.system`, and verifies the resulting executable |
| `jpr.health` (`lua/jpr/health.lua`) | `:checkhealth jpr` diagnostics checking Neovim `>= 0.11`, the bundled or configured `jpr-review` binary and version lockstep against `jpr.VERSION`, `git`, `gh` (including `gh auth status`), and `cargo` |
| `jpr.auth` (`lua/jpr/auth/`: `init.lua`, `modal.lua`, `terminal.lua`) | Global single-flight `gh` authentication recovery across all CLI (`exit code 3`), JSON-RPC (`-32001`), and `syncFailed` (`authRequired = true`) auth failures: shows a keyboard-selectable and mouse-clickable (`<LeftMouse>`) floating modal, runs `gh auth login` in a floating terminal, verifies via `gh auth status`, and automatically resumes queued callers (or re-prompts on failure and notifies callers on cancel) |
| `jpr.repo_picker` (`lua/jpr/repo_picker.lua`) | Non-git-repository detection (`is_git_repo` via synchronous upward `.git` lookup) and pre-palette GitHub discovery flow: lists viewer + organizations via `jpr-review owners` (skipping the owner step when the viewer has zero orgs), lists repositories via `jpr-review repos`, integrates with `jpr.auth`, and opens the scoped Command Palette or `:Jpr open` PR picker with `h`/`<Left>`/`<S-Tab>` back-navigation to switch repositories |
| `jpr.rpc` | JSON-RPC client over `jobstart` (`M.PROTOCOL_VERSION = 9`, `M.ERROR_AUTH_REQUIRED = -32001`) |
| `jpr.session` (`lua/jpr/session/init.lua`, `open.lua`, `open_local.lua`, `commands.lua`, `comments.lua`, `events.lua`, `crash.lua`) | One review per tab: open-PR listing via `jpr-review prs`, immediate loading tab with cancelable checkout and streamed stderr (`open.lua`, keyed by `repo#number` and using collision-safe `buf_key` for multi-repo buffer names), local worktree review startup (`open_local.lua`), engine process, protocol + release version handshake check, requests wrapped with `jpr.auth` recovery (preserving compose drafts when auth is canceled), redraws of the panel, the stream, the diffs, and the PR conversation view, `:Jpr toggle`, `:Jpr stream`, `:Jpr comment`, `:Jpr suggest`, `:Jpr expand`, `:Jpr conversation`, `:Jpr submit`, `:Jpr push`, `:Jpr agent`, `:Jpr send`, `:Jpr prepass`, `streamProgress` and `threadsChanged`/`filesChanged`/`agentRound`/`worktreeStatusChanged`/`headMoved` handling (including the `Resolve myself` vs `Ask agent to resolve` restore-conflict prompt), and the one teardown path |
| `jpr.session.crash` (`lua/jpr/session/crash.lua`) | Mid-review crash recovery: single automatic engine restart, `0600` timestamped crash log at `stdpath("state")/jpr/engine-pr-<n>.log` (inside a `0700` state directory), `[read-only]` fallback on a second crash or failed restart handshake, and control-character sanitization for error messages |
| `jpr.agent` | Right-hand interactive coding-agent terminal split (`claude` or `codex` with `JPR_SOCKET`, `JPR_PR`, and the bundled binary directory prepended to `PATH` in its environment), session resume detection, bracketed-paste prompt dispatch (`confirmSend` after `submitDelayMs` for `send`, `prepass`, and `resolve_conflicts`), and hide/show toggling without killing the live process |
| `jpr.view_mode` | The global view mode (unified or split): the one remembered in `stdpath("state")/jpr/view-mode`, else `setup({ view = ... })`'s |
| `jpr.render.panel` | Pure: `SessionView` (and `collapsed_dirs`) to lines, highlights, `rows`, `selectable_lines`, `paths`, and `conversation_line`. Draws `[read-only]` and `dirty · ↑N ↓M` worktree status prefixes, the visual reviewed-files progress bar (`create_progress_bar_from_counts`: `█`/`░` + `X/Y (Z%)`) above `Conversation`, the engine's `tree` as menu-style collapsible directories (`▾`/`▸`, omitting children under collapsed dirs) and indented files with `✎` on locally modified files, `[local]` (`JprLocalOnly`) on local-only worktree files, and `[G]`, `[NL]`, or `[G · NL]` thread badges (e.g. `[2 · 1L]`), the Conversation row with count, and `drafts N`, `local unsent N`, and `N waiting for GitHub` on the counts line |
| `jpr.render.statusline` (`lua/jpr/render/statusline.lua`) | Pure O(1) in-memory formatter backing `require("jpr").statusline()`: formats `PR #N`, `[read-only]`, `dirty ↑A ↓B` (with `dirty`, `↑A`, and `↓B` each included only when active/non-zero), `V/F viewed`, `D drafts`, `L local`, and `sync!` without spawning processes or making RPC calls |
| `jpr.render.overlay` | Pure: `FileDiffView` to extmark specs (added lines and their changed words highlighted, removed lines as virtual lines with tabs expanded and optional syntax/contrast chunk splitting into `{ bg_group, fg_group }` arrays), and a base text to buffer lines |
| `jpr.render.stream` | Pure: `StreamView` to one column (unified) or two aligned columns (split), with each line's target, `code_rows` metadata (including `change`) for per-file Treesitter highlighting and diff foreground contrast, file/hunk/thread navigation lines, inline thread EOL badges or expanded thread lines, commentable row anchors, folds of viewed files, and the key that says when the stream must be fetched again |
| `jpr.render.threads` | Pure: `ThreadPreview` lists to sign + EOL extmarks (`!` failed, `✎` draft, `◆` local via `JprThreadLocal`, `💬` open published, `✓` resolved), local status/promotion badges (`[local · unsent]`, `[local · sent #N]`, `[local · answered]`, `[promoted]`), expanded virtual lines (`:Jpr expand`), reaction pills, and floating popup message layouts |
| `jpr.render.submit` | Pure: `SubmitPreview`, selected `ReviewEvent`, and summary body to lines, highlights, and cursor-to-draft anchors for `:Jpr submit` |
| `jpr.views.panel` | The panel window, with its options local to it so windows split from it do not inherit them. Operates as a vertical-only collapsible menu (`j`/`k` move between selectable rows, `h`/`<Left>` collapse directory or jump to parent, `l`/`<Right>` expand directory or open item, `<CR>`/`o` open the PR conversation view or a file through `jpr.views.main_window` with `<CR>` toggling directories, `r` inline rename/move, `a` inline create, `v` toggles viewed for the file under the cursor, and `?` opens the keyboard shortcuts cheatsheet) |
| `jpr.views.panel_paths` (`lua/jpr/views/panel_paths.lua`) | Pure path resolution and validation for inline sidebar rename and create inputs: plain names resolve as siblings/children, paths containing `/` resolve from project root, `./` and `../` resolve from the current directory, trailing `/` in create marks a directory, and worktree-escape or `.git` targets are rejected |
| `jpr.views.panel_input` (`lua/jpr/views/panel_input.lua`) | Anchored inline floating input box for sidebar `r` (rename/move) and `a` (create) with live virtual-line path-resolution hints, inline validation errors, `jpr.lsp_files` dispatch, and immediate `refreshWorktree` RPC refresh |
| `jpr.lsp_files` (`lua/jpr/lsp_files/`: `init.lua`, `clients.lua`, `buffers.lua`) | Self-contained native Neovim LSP `workspace/willRenameFiles`/`didRenameFiles` and `workspace/willCreateFiles`/`didCreateFiles` orchestration with cold-start client attach, atomic failure/timeout confirmation prompt, APFS case-only two-step rename safety, dirty-buffer snapshots, `WorkspaceEdit` application, clean-buffer autosave, and open-buffer path updates |
| `jpr.views.main_window` | The window beside the panel where files open; side windows (`vim.w.jpr_side`) never count. Only a plain path inside the worktree opens: `..`, `.`, an absolute path or any symlink that resolves elsewhere (dangling and looping ones included) is refused, so a save never writes outside it |
| `jpr.views.diff` (`lua/jpr/views/diff/`: `init.lua`, `contrast.lua`, `paths.lua`, `threads.lua`) | Every window in the review's tab that shows a changed file gets its `fileDiff`: extmark overlays with contrast-adjusted syntax chunks on removed virtual lines plus thread signs/previews (unified) or a read-only `jpr://base/...` window with `diffthis`, window-local `winhighlight` mapping `DiffAdd`/`DiffChange`/`DiffDelete`/`DiffText` to the softer `JprDiff*` background-only tints, and side-split thread markers (split). `contrast.lua` attaches a single viewport-scoped `nvim_set_decoration_provider` gated strictly to active `jpr` diff windows (lifting `Normal` at priority 45, Treesitter at 115, and LSP semantic tokens at 135 on visible diff lines up to 1,000 bytes, using `nvim_win_call` + `diff_hlID` for split windows). Manages window `signcolumn` when threads exist, redraws threads on `threadsChanged`, and collects moved local anchor extmarks on `BufWritePost` (`updateLocalAnchors`). A window that moves to another buffer is cleared (the overlay stays while another window shows the buffer); a toggle or a moved head redraws all, a save redraws that buffer. A failed `fileDiff` is asked for again only after a toggle or moved commits |
| `jpr.views.stream` | `jpr://stream/<n>` in the main window: opened once the pull request first syncs (replacing the loading buffer, never over a file the reviewer opened), fetched again when its key (the view and the mode) changes, after a save, on `threadsChanged` / `filesChanged`, and on a toggle; a toggle while a request is in flight fetches it again in the new mode. Applies per-file Treesitter highlighting via `jpr.views.stream.syntax` underneath background-only line/word diff extmarks. Split adds a scroll- and cursor-bound `jpr://stream/<n>/base` window on the left, wiped with its window; once the reviewer opens their own buffer there, that window is theirs (no longer a side window, never reused as the left half) and the next draw opens a new left half. Only the answer to the latest `stream` request is drawn, recorded as the view it was asked for. `<CR>` opens a file only through `jpr.views.main_window` (on a viewed file's closed fold, at the file's top; a refused path leaves the stream as it was), `v` toggles viewed and moves on only when the redraw it caused arrives, `]f` `[f` `]h` `[h` `]t` `[t` move between files, hunks, and threads (skipping hunks and threads in closed folds), `?` opens the keyboard shortcuts cheatsheet, and buffer comment keys (`gc`, `gC`, `gf`, `gt`) resolve anchors/threads per active side. An answer that arrives after the review closed is dropped |
| `jpr.views.stream.syntax` (`lua/jpr/views/stream/syntax.lua`) | Per-file Treesitter highlighting over rendered diff stream buffers (`jpr-stream-syntax` namespace beneath background-only diff tints): groups `code_rows` by file path, applies contrast-adjusted `Normal` fallbacks (priority 85) and contrast-adjusted Treesitter groups (priority 90) on added/removed rows while keeping context rows raw, exports `collect_line_spans` for reuse in unified overlay removed virtual lines, and skips files over 5,000 rows |
| `jpr.views.cheatsheet` (`lua/jpr/views/cheatsheet.lua`) | Centered scrollable rounded floating keyboard shortcuts modal (`:Jpr keys` and `?` in read-only Jpr UI buffers), covering PR Sidebar Panel navigation and file ops (`j`/`k`, `h`/`<Left>`, `l`/`<Right>`, `<CR>`/`o`, `r`, `a`, `v`, `?`) and reflecting live `jpr.config.keys` overrides and disabled keys (`q`/`<Esc>`/`?` close) |
| `jpr.views.loading` (`lua/jpr/views/loading.lua`) | Live 4-stage PR open loading view (`jpr://loading/<n>`) with a 100 ms `uv` spinner showing checkout stderr, engine startup, GitHub sync, and `streamProgress` per-file percentage progress bar until the first stream draws |
| `jpr.views.threads` | Places thread signs, EOL previews, and expanded blocks on diff buffers (`LEFT` threads on the base buffer in split mode, `RIGHT` and `file` threads on the file buffer), maintains live `jpr-local-anchors` extmarks for `RIGHT` local `line`/`range` threads, and handles `gt`, `]t` / `[t`, and `:Jpr expand` |
| `jpr.views.conversation` | `jpr://conversation/<n>` in the main window beside the panel: lists top-level PR comments (`anchor.kind == "pr"`) with `c` (new comment), `r` (reply to local PR thread), `e` (edit), `d` (delete), `p` (promote local thread to GitHub), `s` (send local thread to agent), `+` (react), `X` (retry), `?` (keyboard shortcuts), and `q` (close), refreshing on `threadsChanged` |
| `jpr.views.submit` | Centered floating `:Jpr submit` modal (`1`/`2`/`3` review event, `e` summary sub-editor, `<CR>` jump to draft or submit, `<C-s>` submit, `q`/`<Esc>` cancel) |
| `jpr.comments.popup` | Floating thread inspector at the cursor (`r` reply, `e` edit, `d` delete, `R` resolve/unresolve, `p` promote local thread to GitHub, `s` send local thread to agent, `+` reaction picker, `X` retry, `q`/`<Esc>` close) |
| `jpr.comments.compose` | Floating markdown compose buffer for new comments, replies, edits, local-thread promotion (`open_promote`), `<C-g>` target switching (`github` vs `local`), `<M-s>` alternate-target submit, local-only destination lock (locks target to `local` and disables GitHub switching on local-only worktree files), and `<C-g>s` suggestion fences (`<C-s>` submits, `q`/`<Esc>` cancels) |
| `jpr.comments.mentions` | `@mention` completion via `<C-x><C-o>` (`omnifunc`) and an optional `nvim-cmp` source (`jpr_mentions`) backed by `mentions` |
| `jpr.comments.suggest` | `:Jpr suggest`: turns the local edit around the cursor into a GitHub draft `suggestion` comment via `suggestFromEdit` and reverts only that hunk in the buffer (and on disk when already saved) |

The panel, the agent split, a split view's base window, and the stream's left
half are side windows (the panel by its window id, the others by the window
variable `jpr_side`), so files and the stream always open in the main window.

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
  adapters, the protocol and Unix socket server over in-memory streams and
  sockets (including ordered `streamProgress` notifications before `stream`
  responses), `cli-tui` pure schema/state/render unit tests, CLI schema
  completeness and answer conversions (`crates/jpr-review/src/tui_schema/tests/`),
  CLI socket/fallback flows (`crates/jpr-review/tests/agent_cli.rs`), and the
  dependency rule (`crates/jpr-review/tests/dependency_rule.rs`).
- `./scripts/test-lua.sh`: headless Neovim specs against
  `tests/lua/fixtures/fake_engine.sh` (and `crashing_engine.sh`, an engine
  that dies at startup). The fake engine speaks protocol 9, emits
  `streamProgress` during `stream`, answers plugin-issued v9 requests (`push`,
  `fileDiff`, `stream`, `setViewed`, `threads`, `mentions`, `comment`, `reply`,
  `editMessage`, `deleteMessage`, `setResolved`, `toggleReaction`,
  `retryMessage`, `anchoredLines`, `suggestFromEdit`, `submitPreview`,
  `submitReview`, `promoteThread`, `prepareAgentLaunch`, `prepareSend`,
  `confirmSend`, `preparePrepass`, `prepareConflictResolution`,
  `updateLocalAnchors`, `refreshWorktree`; `agentReply` and `prepassWrite` are
  driven by `jpr-review` over the Unix socket and covered in `review-rpc` /
  `jpr-review` Rust tests), and logs the requests it gets
  (`tests/lua/tui_schema_spec.lua`, `tests/lua/tui_render_spec.lua`,
  `tests/lua/tui_wizard_spec.lua`, `tests/lua/palette_and_open_picker_spec.lua`,
  `tests/lua/highlights_spec.lua`, `tests/lua/highlights_contrast_spec.lua`,
  `tests/lua/stream_syntax_spec.lua`, `tests/lua/diff_contrast_spec.lua`,
  `tests/lua/cheatsheet_spec.lua`, `tests/lua/loading_view_spec.lua`,
  `tests/lua/agent_spec.lua`, `tests/lua/build_and_binary_spec.lua`,
  `tests/lua/push_and_head_moved_spec.lua`,
  `tests/lua/session_lifecycle_spec.lua`, `tests/lua/statusline_spec.lua`,
  `tests/lua/panel_render_spec.lua`, `tests/lua/panel_view_spec.lua`,
  `tests/lua/panel_paths_spec.lua`, `tests/lua/panel_input_spec.lua`,
  `tests/lua/lsp_files_spec.lua`, `tests/lua/compose_spec.lua`,
  `tests/lua/auth_spec.lua`, `tests/lua/auth_integration_spec.lua`,
  `tests/lua/repo_picker_spec.lua`, and `tests/lua/rpc_spec.lua` cover the
  declarative TUI engine, Command Palette, non-repo owner/repository picker,
  global `gh` authentication recovery, `:Jpr open` PR picker, blended diff
  highlights, stream Treesitter syntax,
  `:Jpr keys` cheatsheet, live 4-stage loading view, agent dispatch, bundled
  binary discovery/`build.lua`/`:checkhealth jpr`, push, head-move conflict
  prompts, crash auto-restart/read-only fallback, `statusline()`, collapsible
  sidebar menu, inline path resolution/input, native LSP rename/create, and
  local-only compose destination locking).
  The script points `XDG_STATE_HOME` at a temporary directory, so specs never
  touch the real remembered view mode or crash logs.
- `just check` runs both plus formatting and clippy.
