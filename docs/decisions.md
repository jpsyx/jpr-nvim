# Decisions

One section per decision worth remembering: what was chosen, what it rules
out, and what would make it worth revisiting. Add to the bottom; do not rewrite
history.

## The dependency set stays at four crates

**Decision.** The project starts with `anyhow`, `clap`, `serde` and `toml`, and
nothing else.

**Why.** Each of the four answers a question this tool cannot avoid: how errors
travel, how arguments are declared, how the settings become a struct, and what
the settings file looks like on disk. Everything else a starter usually reaches
for (a logging framework, an async runtime, an HTTP client, a color crate, a
crate that finds the config directory) answers a question this tool has not
been asked yet. A dependency is cheap to add later and expensive to remove, so
the default answer is no until a real need names it.

**Consequences.** Color is our own nine semantic tokens in `src/theme.rs`
rather than a color crate, progress lines are `eprintln!` rather than a logger,
the prompts are a few lines of `read_line` in `src/prompt.rs` rather than a
prompting library, and the configuration directory is resolved from
`XDG_CONFIG_HOME` and `HOME` in `src/config.rs` rather than by a crate that
knows every platform's conventions. That last one is the trade most likely to
be revisited: a tool that has to feel native on Windows wants `directories`.

**Revisit when.** A need arrives that the standard library and these four
cannot meet without an awkward hand-rolled substitute. Add the crate, say in
`docs/architecture.md` what it is for, and record the trade here.

## The settings are one typed struct in one TOML file

**Decision.** Everything the tool remembers is one `serde` struct (`Config` in
`src/config.rs`), serialized as TOML to
`$XDG_CONFIG_HOME/<package>/config.toml` (or `~/.config/<package>/config.toml`),
and `--config <PATH>` points at a different file.

**Why.** A typed struct with `#[serde(default)]` makes a partial file valid, a
missing file mean "nothing configured yet", and a new setting one more field.
`deny_unknown_fields` turns a typo in a hand-edited file into an error that
names the settings that do exist, which is worth more than tolerating a line
that silently does nothing. TOML is the format the reader already meets in
`Cargo.toml`, and it survives hand editing better than JSON, which has no
comments and objects to a trailing comma. The XDG location is where other
command-line tools keep their settings, and `--config` exists so a test, a
script, or a second profile never has to touch the real file.

**Consequences.** Saving rewrites the file from the struct, so comments a
person wrote in it are lost: `config set` says so under `--verbose`. Settings
are flat, one level deep, which is all this shape supports without nesting
tables. `toml`'s `preserve_order` keeps a table in the order it was read rather
than sorting it, so a file this tool rewrites keeps the shape its author
recognizes.

**Revisit when.** The settings grow a nested section, a profile per
environment, or a value that must not be written in plain text. The first two
are more TOML; the third is a different mechanism entirely.

## Asking for a missing value happens in exactly one module

**Decision.** `src/prompt.rs` owns every question: whether there is anybody to
ask, how the question is drawn, what a typed answer means, and what the failure
says when stdin is not a terminal. Commands describe the value they are missing
and call `prompt::ask`.

**Why.** The two-audiences rule in `docs/rules/cli-ux.md` (an agent drives
everything with flags, a person who omits a value is asked rather than
rejected) is easy to state and easy to break one command at a time. Keeping it
in one module means a new command inherits the behavior instead of
reimplementing it, and the tricky parts (an empty answer taking the default, a
choice picked by number, the message that names the flag) are pure functions
with tests rather than something only reachable by typing at a terminal.

**Consequences.** A question is data (`Question`), so a command cannot ask
without also naming the flag that would have answered, which is what keeps the
non-interactive path honest. The terminal half stays untested on purpose: it
reads a line and writes a line, and everything it decides lives next to it in a
pure function.

**Revisit when.** The tool needs a question this shape cannot express: a
password with no echo, a multi-select, or a full-screen picker. That is the
moment to weigh a prompting crate against the four dependencies above.

## `just` is the task runner, and it is optional

**Decision.** Tasks live in a `justfile`, and every recipe is a single command
a person could also type by hand.

**Why.** Cargo has no place to hang project tasks (install, lint with the flags
we mean, update the agent skills), so a Rust project either invents a script
directory, a `cargo xtask` crate, or uses a task runner. `just` is itself a
Rust tool (`cargo install just`), a recipe costs one line, and `just --list`
makes the tasks discoverable the way a `package.json` scripts block is. A
`cargo xtask` crate earns its keep when a task needs real Rust code (codegen,
packaging, a release pipeline); a whole crate that shells out to `cargo clippy`
does not. A `Makefile` needs nothing installed, but its tab rules are a trap
for a one-line recipe and it is not what a Rust project reaches for.

**Consequences.** Nobody is blocked by not having `just`: `just lint` is
`cargo clippy --all-targets -- -D warnings` and `just install` is
`./install.sh`. Recipes take their arguments through
`set positional-arguments` and `"$@"` rather than just's own interpolation, so
the file stays readable as shell.

**Revisit when.** A task needs logic rather than a command line. That is the
moment `cargo xtask` starts paying for itself.

## A workspace of generic crates and one composition root

**Decision.** The engine is split into `review-*` crates that know nothing
about Neovim, plus `jpr-review`, the only crate that wires real adapters
together. This supersedes "The dependency set stays at four crates": that was
the scaffold's starting point for a single-crate tool. It also retires "The
settings are one typed struct in one TOML file": the scaffold's settings file
left with the example commands that used it.

**Why.** The review engine is meant to be reused by other frontends, starting
with dif's terminal UI. Crate boundaries make the dependency rule mechanical,
and a test enforces it.

**Consequences.** `serde_json` joins (the protocol and the state files are
JSON). `toml` and the scaffold's example `greet`, `info` and `config` commands
leave. `tempfile` joins: `review-store-fs` writes each state file through a
unique temporary file, and the filesystem tests use temporary directories.

**Revisit when.** A crate is only ever used by one other crate and never by a
frontend; merge it then.

## Threads and channels, not an async runtime

**Decision.** The server uses a reader loop and a poller thread around one
`Mutex<ReviewSession>`. Each writes the events its own sync caused; there is
no separate event-forwarding thread, because a detached forwarder could lose
the last events when the server exited.

**Why.** Every outside call is a short blocking `gh` or file operation, which
is also how dif works. An async runtime would add weight without a need.

**Consequences.** A request waits while a background sync holds the session
lock. One sync is at least four sequential `gh` calls (`pr view`, the thread
pages, the file pages, the pending review), each with its own 30 second
timeout, so on a bad network a `snapshot` or `sync` can wait 2 minutes or
more.

**Revisit when.** Requests need to stay responsive during a long sync.

## The Unix socket waits for the agent milestone

**Decision.** Milestone 1 serves JSON-RPC on stdio only. The socket for agent
commands (`jpr-review reply`) arrives with the agent loop, on the same
line-based `serve` function.

**Why.** Nothing outside Neovim talks to the engine until the agent does.

## `checkout` prints JSON

**Decision.** `jpr-review checkout` prints `{ "worktree", "repo", "number",
"title" }` as its last stdout line and narrates on stderr.

**Why.** The plugin needs the worktree path and the `owner/name` that `serve`
uses for its state directory, and the state directory must be known even when
GitHub is unreachable later.

## The state files are versioned envelopes

**Decision.** `session.json`, `viewed.json` and `github.json` each carry a
top-level `"version"`. A file without one is corrupt, and a file with a newer
version is refused and never overwritten.

**Why.** The state outlives any one build, and later milestones add fields. An
older build that rewrote a newer file would silently drop what it did not
understand.

**Consequences.** Changing a file's shape means bumping its version in
`review-store-fs` and reading the old one. The files are still written one
after the other, not as a set, and the state directory ignores the forge host
and letter case; both are known limits for a later milestone. `github.json` is
written first: the queue only shrinks after GitHub accepts a mark and only
grows for a mark held locally, so a crash between files can resend a mark but
never lose a refused one or revive one the reviewer undid. A crash can leave
`viewed.json` behind the queue, so opening a session applies the queued marks
to the saved files.

## Queued viewed marks are sent in order, stopping at the first refusal

**Decision.** A viewed mark GitHub refuses stands locally and is queued in
`github.json`. Every sync, and the retry between syncs, sends the queue in
path order and stops at the first refusal. Every pull then drops the queued
marks for files the pull request no longer changes, and lets the rest win
over the viewed state it pulled.

**Why.** A refusal is almost always GitHub being unreachable, and each send
waits up to 30 seconds, so carrying on past a failure would only multiply the
wait. A mark for a file a force-push or rename took out of the pull request
is refused every time; dropping it on the next pull keeps it from holding up
the marks queued after it.

**Consequences.** A mark for a file that leaves the pull request is lost,
which is harmless because GitHub has nothing to mark. A stale mark still
holds up the queue until the next successful pull. A mark GitHub refuses
every time for a file that is still changed would hold up the queue for
good.

**Revisit when.** GitHub refuses a mark for a reason other than being
unreachable: tell the two apart and skip a mark refused for its own sake.

## Paths and commits a pull request names are untrusted

**Decision.** `GitWorkspace` reads a path only when it is written the way git
names a file: relative, with no empty, `.` or `..` segment, and no `.git`
segment in any letter case, which would reach the repository's own files
(`.github/x` and `.gitignore` are fine, `./a`, `a/./b`, `a//b` and
`.git/config` are not). The same rule applies on disk and
at a commit, so both sides always read the same file. On disk, a path whose
directories resolve out of the worktree is refused, a symlink reads as its
target's path, the way git stores it, and is never followed, and anything
else that is not a file, such as a directory or a named pipe, reads as
nothing. A commit must be a full id, exactly 40 or 64 hex digits. File
contents at a commit come from `git cat-file --batch`, which takes
`commit:path` on stdin, and a path holding a newline, a carriage return or a
NUL byte is refused because git would read a different file. Every git call
clears `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`,
`GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_COMMON_DIR`, `GIT_SHALLOW_FILE` and
`GIT_PREFIX` (each one `git rev-parse --local-env-vars` lists), and renames come from the plumbing `git diff-index`,
which never writes the reviewer's index.

**Why.** Paths and commit ids come from GitHub, so anyone who opens a pull
request chooses them. Without these checks a pull request could show the
reviewer a file from outside the worktree, pass an option such as `--output`
to git, or, with a short id, have git read a branch the pull request named
instead of the commit. The repository variables would point git somewhere
else when Neovim was started by `git commit`, which sets them for its editor.

**Consequences.** No path ever reaches git as an argument or a pathspec, so
none can be read as an option. Fetching a missing base commit runs with git's
terminal prompts off and a deadline (`FETCH_TIMEOUT`, 90 seconds). Its
output is read for at most a second after git exits or is killed, since a
helper can hold the pipes open, and a timeout reports whatever git printed
on stderr by then. `GIT_TERMINAL_PROMPT=0` does not stop an ssh passphrase
or host key prompt, so where it goes depends on whether the engine has a
terminal (`/dev/tty` opens):

- With a terminal (run from a shell), the fetch gets its own process group.
  A prompt in it cannot read the terminal's keystrokes, and the deadline
  kills the whole group, ssh included, through the `kill` command. Where
  `kill` cannot be run, only git is killed and the error says so.
- Without one (Neovim's `jobstart`), nothing can prompt, and the fetch stays
  in the engine's process group so Neovim's `jobstop` stops it, ssh
  included, with the engine. The deadline then kills only git; an ssh it
  started ends when the engine's group does.

The fetch does not force ssh into batch mode, because that would override
the reviewer's own ssh command.

**Revisit when.** A real pull request needs a path with a line break in it.
`git cat-file --batch -z` (git 2.38 and later) takes NUL-terminated requests
and could read such a path instead of refusing it.

## Diffs stop at a size and a time limit

**Decision.** Each side of a diff holds at most 4 MiB (`MAX_DIFF_BYTES` in
`review-core`'s `session/diffs.rs`). A file with a bigger side is not diffed:
`fileDiff` fails with "too large to show", and the stream shows the file's
header with a note saying the same. One file's line diff searches for at most
2 seconds (`DIFF_DEADLINE` in `review-diff`) before it settles for a good
answer rather than the best one. Line endings and the final newline are not
diffed, so an added empty file, a change to the final newline only and a
CRLF-only change show "no changes against the base".

**Why.** Pull requests name the files, and a generated bundle or a file
stored with Git LFS can be hundreds of megabytes: a 267 MB blob took 3
seconds and 336 MB of memory to read, and the base cache keeps every base
text it reads. Nobody reviews such a file line by line.

**Consequences.** The size is checked after the `Workspace` port returns the
bytes, so a big file is still read once in full and then dropped at once. A
base found too large is remembered for its base commit and not read again;
the file on disk is read on every request. Base texts under the limit stay
cached with no total budget. The deadline restarts for every file, so a
stream of N pathological files can take up to 2N seconds.

**Revisit when.** Reading a big file once costs too much (ask git for the
size first, with `git cat-file --batch-check`), a stream stalls on many slow
files (pass one deadline down through the stream), or a reviewer needs a
line ending change shown.

## The stream's known limits

**Decision.** The stream ships with four known limits. Folds are rebuilt on
every draw, so a viewed file opened with `zo` closes again after `v`, a save
or a sync. Folds are not mirrored between the split halves. Two reviews of
the same pull request number in different repositories can clash on the
`jpr://stream/<n>` buffer name (the name is only for display, so the second
buffer stays unnamed). `<CR>` on a deleted file's row opens an empty buffer
at that path, as the panel does.

**Why.** Each needs state the stream does not keep yet (open folds per file,
fold events from the other half, the repository in the name), and none loses
or corrupts anything.

**Revisit when.** Reviewers open viewed files in the stream often, or a
second repository's review is open at the same time.

## Line and word diffs come from `similar`

**Decision.** `review-diff` uses `similar` 3 (slice API only, default features
off but `std`): Histogram for line diffs, as git uses for code, and Myers over
word tokens for the changed words inside a pair of lines.

**Why.** A diff algorithm with deadlines and grouping into hunks is a lot of
careful code to own; `similar` is small, has no required dependencies, and is
the common choice in Rust.

**Consequences.** The line diff's deadline is the one in "Diffs stop at a size
and a time limit". Two paired lines get word highlights only when at least
half their tokens match; otherwise the whole line counts as replaced, because
marking nearly every word says less than marking none.

**Revisit when.** Diffs need to match GitHub's line for line, or `similar`
stops being maintained.

## The engine computes every diff except the split view's

**Decision.** The unified overlay and the stream are drawn from the engine's
`FileDiffView` and `StreamView`. The split view of a single file uses
Neovim's own `diff` mode on the engine's base text.

**Why.** The spec chose native diff mode for split view: it scrolls, folds and
edits like any Neovim diff, and the reviewer edits the real file in it. The
other views are read models a terminal UI would draw too, so they belong in
the engine.

**Consequences.** In split view the line pairing is Neovim's, which can
differ from the engine's in a few edge cases, and edits show before they
are saved. The engine compares against the file on disk, so a save refreshes the
overlay and the stream; edits not yet saved are not in them.

## The view mode is a frontend preference

**Decision.** Unified or split is remembered by the plugin in
`stdpath("state")/jpr/view-mode`, not by the engine. The engine is told the
mode on each `stream` request.

**Why.** The choice is global across pull requests and is about how one
frontend draws, which is not review state.

## The base cache follows the base commit only

**Decision.** The session keeps the merge base, the renames since it and the
base texts it has read until the pull request's `baseSha` changes. It does not
look at the worktree's checked-out `HEAD`.

**Why.** The worktree only moves when the reviewer moves it, and finding the
merge base and the renames on every request would cost three git calls each
time (`cat-file -e` to check the base commit is there, `merge-base` and
`diff-index`), plus a fetch when the base commit is missing.

**Consequences.** A rebase, or a `git mv`, in the worktree under the same
base commit keeps the old merge base and rename map until the base commit
changes or the engine restarts, so diffs can compare against the wrong base
text or miss a rename.

**Revisit when.** The worktree fast-forward lands: moving `HEAD` then becomes
the engine's own doing, and the cache should be keyed on `HEAD` too.

## Base texts are read with one git process per file

**Decision.** `GitWorkspace::file_at` starts one `git cat-file --batch`
process per file. The first stream after a base commit is known reads every
changed file's base this way; later requests hit the cache.

**Why.** The `Workspace` port reads one file at a time, which keeps the port
and its fake simple.

**Consequences.** A pull request with hundreds of files starts hundreds of
short git processes for its first stream.

**Revisit when.** That first stream is slow enough to notice: a batched port
method that sends every `commit:path` to one `git cat-file --batch` would fix
it.

## The poller wakes on a 20 second tick

**Decision.** While it polls, the server's poller wakes every 20 seconds (or
every `--poll` seconds when that is shorter) and syncs once a whole `--poll`
interval has passed since the last sync.

**Why.** One loop serves both the syncs and the retries of refused viewed
marks, with the decision in the pure `get_poll_step_from_elapsed`.

**Consequences.** A `--poll` above 20 seconds rounds up to a multiple of 20
(`--poll 30` syncs every 40 seconds). The tick starts after the work of the
last wake-up ends, so every interval also grows by the time spent in retries:
offline, each retry can wait 30 seconds for `gh`.

**Revisit when.** Someone needs syncs on an exact schedule.

## The session lock is held during `gh` calls

**Decision.** `setViewed` and the poller's retries call `gh` while they hold
the one `Mutex<ReviewSession>`, as syncs do (see "Threads and channels, not an
async runtime").

**Why.** The mark, the queue and the saved state change together, and one
lock keeps them consistent without an async runtime.

**Consequences.** Offline, each retry holds the lock for up to 30 seconds and
the next one starts 20 seconds after it ends, so requests that need no
network, such as `fileDiff`, `stream` or `snapshot`, can queue behind a retry
for up to 30 seconds.

**Revisit when.** Diffs need to stay responsive offline: send to the forge
outside the lock and apply the answer under it.

## Some changed files show "no changes against the base"

**Decision.** Line endings and the final newline are not diffed (see "Diffs
stop at a size and a time limit"), so an added or deleted empty file, a
change to the final newline only and a CRLF-only change have no hunks. The
stream shows the note "no changes against the base" for them, and the
unified overlay draws nothing, although GitHub lists the file as changed.

**Why.** Buffer lines carry no line endings, so the overlay could not draw
such a change on the file anyway.

**Revisit when.** A reviewer needs to see these changes, for example as a
note that names what changed.

## The plugin's view-mode file is best effort

**Decision.** `jpr.view_mode` creates `stdpath("state")/jpr` with
`vim.fn.mkdir`, writes the mode with `writefile` inside a `pcall`, and takes
`setup({ view = ... })` as given.

**Why.** The mode is a convenience: a session works without it being
remembered.

**Consequences.** A state directory that cannot be created raises a Lua error
out of `:Jpr toggle` (the mode has flipped in memory, but the views are not
redrawn). A failed write is silent, so the mode is forgotten at the next
start. An invalid `view` is not checked: files open as split diffs and the
engine refuses the `stream` request as invalid params.

**Revisit when.** Reviewers hit any of these: validate `view` in `setup`, and
report a failed save once.

## The panel's tree sorts names by their bytes

**Decision.** `tree.rs` sorts each directory's directories and files by the
bytes of their names, so the order is case-sensitive (`Zeta` before `alpha`).
The stream keeps the order of GitHub's file list.

**Why.** A byte order is simple, stable and the same on every platform.

**Consequences.** The panel's order differs from GitHub's file tree, and the
stream's order can differ from the panel's.

**Revisit when.** Reviewers find files in the wrong place: sort the way
GitHub's file tree does, and lay the stream out in the panel's order.

## A failed save after queued marks landed is silent in serve mode

**Decision.** When the poller's retry, or a sync whose pull failed, gets
queued marks through but then cannot save, the error is dropped. A sync whose
pull succeeded but whose save failed is dropped the same way by the poller.

**Why.** No event carries a store error, and the poller has no request to
answer. A sync whose pull failed reports the pull's error, the one that
matters more, so a `sync` request in that case answers with the pull's error
and the save's is lost. A `setViewed` request, and a `sync` request whose
pull succeeded, still get the save error as their response.

**Consequences.** The marks are on GitHub and the queue in memory has
already shrunk, so the next save that succeeds writes the shorter queue.
Until then no `viewedChanged` is sent (a failed pull still sends
`syncFailed`), so the panel's waiting count can be stale, and a crash would
resend marks that already landed, which is harmless.

**Revisit when.** A store error needs to reach the reviewer: add an event for
it.

## Immediate thread replies use GitHub REST and fall back to pending-review GraphQL

**Decision.** When no pending review is active (`pendingReviewId` is absent)
and the thread's root comment carries a numeric `databaseId`, `GhForge::reply_to_thread`
posts an immediate published reply via GitHub REST
(`POST repos/{owner}/{repo}/pulls/{number}/comments/{id}/replies`). When a
pending review is already active, `databaseId` is missing, or the REST endpoint
rejects with an HTTP 422 / `"Validation Failed"` conflict mentioning a
`"pending review"`, `GhForge` queries (or creates) the active pending review
and falls back to GraphQL `addPullRequestReviewThreadReply`.

**Why.** GitHub's GraphQL `addPullRequestReviewThreadReply` mutation requires a
`pullRequestReviewId`. Creating a pending review just to send a reply turns a
quick answer on an existing thread into an unsubmitted draft hidden from
everyone else until `:Jpr submit`. REST `POST .../comments/{id}/replies`
publishes a single reply immediately when no pending review is open, while
GitHub still refuses that REST endpoint with HTTP 422 if a pending review is
already active on the pull request (for example one opened on GitHub web
since the last sync), requiring the reply to join that pending review via
GraphQL.

**Consequences.** Thread replies publish immediately when no pending review
exists, and join the pending review as drafts when one does. When the 422
fallback discovers a pending review created outside `jpr-review`,
`ReviewSession` refreshes `pending_review_id` from the forge so subsequent
drafts and `:Jpr submit` stay in sync.

**Revisit when.** GitHub's GraphQL `addPullRequestReviewThreadReply` supports
immediate replies without a `pullRequestReviewId`, or reviewers want an explicit
toggle to hold replies as pending drafts even when no pending review exists.

## CLI agent commands talk to the daemon socket first and fall back to local.lock

**Decision.** `jpr-review threads`, `jpr-review reply`, and
`jpr-review prepass-write` try the live daemon's Unix domain socket first
(`--socket`, `$JPR_SOCKET`, or the socket recorded in `session.json`, with an
explicit `--socket` failing loudly rather than falling back), and fall back to
reading the store or mutating `local.json` under an exclusive `local.lock` file
(`O_CREAT|O_EXCL`, 5 second wait, 30 second stale eviction) when no daemon is
reachable. The daemon's socket accepts only `snapshot`, `threads`, `agentReply`,
and `prepassWrite` (refusing all other RPC methods, including `shutdown`, with
`-32600`), and flushes any events produced by socket mutations straight to the
stdio stream so Neovim updates immediately.

**Why.** When Neovim is open, the live `jpr-review serve` process holds the
authoritative in-memory session and must observe every agent reply or pre-pass
write immediately so threads, badges, and counts redraw without polling disk.
When the agent runs standalone or after `:Jpr close`, no daemon is serving, so
`local.lock` still lets `reply` and `prepass-write` update `local.json` safely
without interleaving writes or corrupting atomic renames.

**Consequences.** Any coding agent or hook running inside the session's shell
cannot drive GitHub mutations or shut down the Neovim engine over the socket,
while `agentReply` and `prepassWrite` still reach the live UI in real time.
Offline writes wait up to 5 seconds for `local.lock` and take over locks older
than 30 seconds if a prior CLI process crashed.

**Revisit when.** Multiple concurrent frontends need full read/write session
sharing over a socket rather than one Neovim stdio owner plus an agent helper
channel.

## Two-phase agent dispatch confirms rounds only after bracketed paste succeeds

**Decision.** `:Jpr send` and `:Jpr prepass` split engine state transitions
from terminal I/O into two RPC steps: `prepareSend` (or `preparePrepass`)
returns an `AgentDispatch` containing the round number, prompt, and
`AgentProfile` without advancing threads to `sent` or writing `rounds.jsonl`,
and Neovim calls `confirmSend` only after launching the agent terminal, sanitizing
any raw ESC (`\x1b`) bytes from the payload, wrapping it in bracketed paste
(`\x1b[200~...\x1b[201~`), waiting `submitDelayMs` (200 ms), and sending the
profile's submit key (`\r` for Claude, `\t` for Codex).

**Why.** Spawning the agent split or pasting into its PTY can fail (missing
binary, closed window, channel error). Advancing local threads from `unsent` to
`sent` before the prompt actually reached the agent would strand those threads
and leave `:Jpr send` claiming nothing is unsent. Stripping raw ESC bytes
prevents untrusted PR titles, file paths, or comment text inside a prompt from
breaking out of bracketed paste and injecting terminal control sequences or
premature submits.

**Consequences.** If spawning or pasting fails, local threads remain `unsent`
and no phantom round is appended to `rounds.jsonl`. If Neovim crashes in the
200 ms window between pasting and calling `confirmSend`, the agent may have
received the prompt while the threads stay `unsent` so the reviewer can re-send.

**Revisit when.** Agent CLIs expose a non-PTY structured prompt/session API that
acknowledges receipt directly without terminal paste timing.

## :Jpr push pushes HEAD to the PR branch refspec without auto-committing

**Decision.** `:Jpr push` (`push` on stdio; refused on `JPR_SOCKET`) validates
that the session has synced, that local `HEAD` is neither behind the pull
request head (`ahead == 0` and `behind > 0`) nor already at the effective remote
head (`ahead == 0` at `effective_remote_head_sha`, reporting whether uncommitted
changes still need a commit or `HEAD` is already up to date), and then runs an
unattended `git push --porcelain -- <remote> HEAD:refs/heads/<head_ref>`. It
resolves `<remote>` from `branch.<local>.pushRemote`, `branch.<local>.remote`,
or `origin`, rejects unsafe remote or branch names, and refuses to push if
`branch.<local>.merge` is set to anything other than `refs/heads/<head_ref>`.
Once `git push` succeeds, the session records `PushedHead` (`base_pr_head_sha`
and `pushed_sha`) and runs a follow-up `sync`, returning `PushResult {
isPushed: true, headSha, syncError?, view }` even when the follow-up GitHub sync
fails or `headRefOid` lags behind the pushed commit.

**Why.** Default checkouts run `gh pr checkout <n> -b pr-<n>` (or detached
`HEAD` in custom worktree flows), so the local branch name rarely matches the
pull request's `headRef`; plain `git push` under `push.default=simple` either
fails or pushes to the wrong branch unless an explicit
`HEAD:refs/heads/<head_ref>` refspec is given, while checking
`branch.<local>.merge` prevents pushing a worktree that was switched onto
`main` or another branch's upstream. Refusing dirty zero-ahead worktrees keeps
commit authorship, staging, and commit messages in the reviewer's or coding
agent's hands instead of inventing commits automatically. Recording `PushedHead`
and returning `syncError` inside `PushResult` avoids telling the reviewer a push
failed after `origin` already accepted the commit, and keeps `worktreeStatus`
from reporting spurious `ahead` commits while GitHub's GraphQL `headRefOid`
catches up.

**Consequences.** Reviewers (or the coding agent when explicitly asked to commit
locally) commit with git first and run `:Jpr push` to publish. Uncommitted edits
alongside ahead commits remain on disk untouched while the committed `HEAD` is
pushed. Force-pushes stay manual in a terminal because `HEAD:refs/heads/<head_ref>`
never passes `--force` or `--force-with-lease`.

**Revisit when.** Reviewers want an opt-in `--force-with-lease` confirmation
flow after rebasing a PR branch locally.

## Remote head moves auto-stash, fast-forward, and never rewrite local history

**Decision.** When `sync` observes `pr.headSha` move, `GitWorkspace::fast_forward_to`
fetches `pr.headSha` if needed, checks commit ancestry and active git sequencer
state (`rebase-merge`, `rebase-apply`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`,
`REVERT_HEAD`, `BISECT_LOG`, `sequencer` via `git rev-parse --git-path`), and
leaves the worktree untouched when local `HEAD` is ahead (`aheadOfTarget`),
diverged (`diverged`), or mid-operation (`failed`). Clean behind worktrees run
`git merge --ff-only --no-overwrite-ignore <head_sha>`. Dirty behind worktrees
push a nonce-marked stash (`git stash push --include-untracked -m "... [pid-seq]"`),
resolve the exact stash commit SHA by matching first parent `previous_sha` and
the `[pid-seq]` suffix across `refs/stash` and its reflog, fast-forward with
`--ff-only --no-overwrite-ignore` (rolling back the pinned stash on failure),
and re-apply local edits with `git stash apply <stash_sha>`, dropping
`refs/stash@{0}` only if it still resolves to `<stash_sha>`. Unmerged index
entries or colliding untracked stash paths (`<stash_sha>^3`) surface as
`HeadMoveOutcome::RestoreConflict` with `conflictedPaths`, keeping the stash
entry intact and prompting the reviewer in Neovim to either open the first
conflicted file (`Resolve myself`) or dispatch a `conflict` agent round
(`prepareConflictResolution`, `JPR_SOCKET`-refused). Revisiting "The base cache
follows the base commit only", `BaseCache` in `session/diffs.rs` now keys on
`(base_sha, head_sha)`, and `pending_head_move_from` retries any `Failed` head
move on the next sync even when the remote `headSha` has not moved again.

**Why.** Linked git worktrees share one repository-wide `$GIT_COMMON_DIR/refs/stash`:
a naive `git stash pop` can pop or drop a stash created concurrently in another
worktree, or discard the reviewer's stashed untracked edits when `stash apply`
aborts before writing conflict markers. Matching the stash commit by parent SHA
and nonce and applying by commit SHA makes stash restoration deterministic across
worktrees. Passing `--no-overwrite-ignore` stops a fast-forward from silently
clobbering untracked gitignored build or local config files when a newly tracked
remote file lands at the same path. Keying `BaseCache` on `(base_sha, head_sha)`
ensures merge-base and rename lookups refresh immediately whenever `HEAD` moves.

**Consequences.** Force-pushed (`diverged`) or locally ahead (`aheadOfTarget`)
branches never lose commits or get reset behind the reviewer's back; Neovim
notifies the reviewer and leaves branch surgery to git. Conflicted paths are
excluded from immediate snapshot re-anchoring until the conflict markers are
resolved on disk, while clean files in the same fast-forward re-anchor right
away.

**Revisit when.** Reviewers want an explicit command to reset a diverged PR
worktree onto a force-pushed remote head after stashing local work.

## Mid-review engine crashes restart once and fall back to read-only mode

**Decision.** Once a tab's review session completes its initial `initialize`
handshake (`session.ready`), an unexpected `jpr-review serve` exit appends a
timestamped entry and stderr to `stdpath("state")/jpr/engine-pr-<n>.log` (`0600`
file inside a `0700` directory) and automatically spawns `jpr-review serve` one
time (`session.has_restarted = true`). If the restarted engine crashes again,
fails to spawn, or fails its handshake, the plugin stops restarting, marks the
session `[read-only]` in the panel and statusline, blocks further RPC mutations
with an actionable `:Jpr close` / `:Jpr open <n>` message, and leaves every open
diff buffer, stream buffer, and compose float intact. Crashes before
`session.ready` still run `forget` immediately so broken startups clean up their
tab.

**Why.** `jpr-review serve` persists viewed marks, draft/queued GitHub state,
and local threads atomically under `$XDG_STATE_HOME/jpr` on every mutation, so a
single transient failure can recover seamlessly by re-opening the store and
syncing. An unconditional restart loop on a deterministic panic or corrupt state
file would spam notifications, peg a CPU core, and flood disk logs, whereas
tearing down the tab on a second crash would destroy unsaved buffer edits or an
in-progress comment draft in the compose float.

**Consequences.** Transient mid-review crashes self-heal with one warning
pointing to `engine-pr-<n>.log`, while persistent crashes degrade cleanly to
`[read-only]` after at most two process exits. Startup protocol or version
mismatches still fail fast without retrying.

**Revisit when.** Reviewers want an in-place `:Jpr reconnect` command to clear
`[read-only]` without closing and reopening the review tab.

## Root build.lua and plugin-local target/release/jpr-review replace install.sh

**Decision.** `jpr-nvim` removes `install.sh` and the `just install` recipe in
favor of a root `build.lua` hook (`lua/jpr/build.lua`), plugin-local binary
resolution (`lua/jpr/binary.lua` defaulting `config.binary = nil` to
`<plugin_root>/target/release/jpr-review`), coding-agent `PATH` injection in
`lua/jpr/agent.lua`, and `:checkhealth jpr` (`lua/jpr/health.lua`). `build.lua`
locates `cargo` across `PATH`, `$CARGO_HOME/bin`, and `~/.cargo/bin`, clears
cached `jpr.build` and `jpr.binary` entries in `package.loaded`, yields progress
only when running inside `lazy.nvim`'s `lazy.async` coroutine, and runs
`cargo build --release -p jpr-review` with `cwd = plugin_root` without changing
Neovim's global working directory.

**Why.** A separate `./install.sh` step into `~/.local/bin` forced users and
dotfiles setups to maintain an out-of-band build script and drifted whenever
`:Lazy update` advanced the Lua plugin without rebuilding the Rust binary.
`lazy.nvim` natively executes `<plugin_root>/build.lua` on install, `:Lazy
update`, and `:Lazy build jpr-nvim`, keeping the Lua frontend and compiled
`jpr-review` binary in lockstep inside one checkout. Prepending
`<plugin_root>/target/release` to `PATH` inside `:Jpr agent` terminals lets
coding agents invoke `jpr-review guide`, `jpr-review threads`, `jpr-review
reply`, and `jpr-review prepass-write` by bare name without writing anything to
`~/.local/bin`, while GUI Neovim sessions without shell `PATH` still find
rustup's `cargo` and `rustc` via `$CARGO_HOME/bin` or `~/.cargo/bin`.

**Consequences.** Adding `"jpsyx/jpr-nvim"` to `lazy.nvim` installs and updates
the entire tool in one step, and `:checkhealth jpr` verifies Neovim, the bundled
engine version, `git`, `gh`, and `cargo`. `jpr-review` is no longer placed on
the user's interactive login shell `PATH` outside `:Jpr agent` unless they add
it themselves, and `setup({ binary = ... })` remains available for test fixtures
and custom engine builds.

**Revisit when.** Prebuilt platform release binaries on GitHub Releases become
worth downloading in `build.lua` as a fast path for users without a local Rust
toolchain, falling back to `cargo build --release -p jpr-review` when no
matching artifact exists.

## Declarative command schemas drive interactive TUI palettes and steppers

**Decision.** Both frontends describe their full command surface in declarative
schemas that render an interactive Command Palette and discriminant-first
steppers: in Neovim (`lua/jpr/tui/schema.lua`, `lua/jpr/tui/render.lua`,
`lua/jpr/tui/wizard/`, and `lua/jpr/commands/schema.lua`) for bare `:Jpr` and
`:Jpr open`, and in Rust (`crates/cli-tui` and `crates/jpr-review/src/tui_schema/`)
for bare `jpr-review` and missing-input subcommands on an interactive TTY.
`crates/cli-tui` lives outside `crates/review-*` so generic engine crates stay
UI-free and `crossterm` never enters `review-*`. Every command and option shows
a human-readable display label paired with `[<id>]`, reveals concise helper
text only underneath the currently hovered row in menus (and on every stepper
screen), orders discriminant booleans and enums before dependent steps via
`when` predicates, prunes abandoned branch answers on completion, and uses
Neovim-conventional Normal-vs-Insert keyboard controls (`j`/`k`/`h`/`l`/`gg`/`G`/`<Tab>`/`<S-Tab>`/`<CR>`/`q`/`<Esc>`
in menus and toggles; prefilled text input with `<S-Tab>` back, `<Tab>`/`<CR>`
validate & forward, and `<Esc>` to Normal mode).

**Why.** Remembering every subcommand name and flag slows down human reviewers,
while ad-hoc interactive prompts drift from the actual command surface and risk
hanging scripts or coding agents. Generating the palette, steppers, and
argument completions from one declarative schema per frontend keeps interactive
and non-interactive surfaces in lockstep. Hover-only helper text keeps menus
compact while still explaining every choice, discriminant-first branching skips
irrelevant follow-up steps, and Neovim modal keybindings feel native in both
the editor and the terminal.

**Consequences.** Every new or modified `:Jpr` subcommand or `jpr-review` CLI
option must update its declarative schema in the same change, enforced by
`crates/jpr-review/src/tui_schema/tests/` and
`tests/lua/palette_and_open_picker_spec.lua`. A typed alias of an existing
command lives in `COMMAND_ALIASES` (`lua/jpr/commands/schema.lua`), resolves to
that command before dispatch, and is not an extra palette entry.
`crates/cli-tui` adds `crossterm`
to the workspace strictly at the frontend layer, rendering to stderr inside an
RAII raw-mode guard and gating on `cli_tui::is_interactive_terminal()` so
pipes, CI jobs, and coding agents never hit interactive prompts.

**Revisit when.** A standalone terminal review UI needs richer shared TUI
widgets beyond palettes and linear discriminant-first steppers, or when
multiple Rust binaries reuse `crates/cli-tui` as a published crate.

## Blended background-only diff tints, stream Treesitter syntax, and direct `streamProgress` notifications

**Decision.** Diff readability and live loading feedback rely on two targeted
mechanisms:

1. **Background-only diff tints + per-file stream Treesitter highlighting.**
   `lua/jpr/highlights.lua` computes `JprDiffAdd`, `JprDiffAddText`,
   `JprDiffDelete`, and `JprDiffDeleteText` with a soft `bg` blended onto the
   active colorscheme's `Normal.bg` (explicitly no `fg`, with dark/light
   fallbacks when `Normal.bg` is nil) and refreshes managed groups on
   `ColorScheme` without overwriting explicit user overrides. Split diff
   windows map `DiffAdd`/`DiffChange`/`DiffDelete`/`DiffText` to `JprDiff*`
   through window-local `winhighlight` (`lua/jpr/views/diff/init.lua`) instead
   of mutating global Neovim diff highlight groups. In stream buffers,
   `lua/jpr/views/stream/syntax.lua` parses each file's rendered code rows via
   `vim.treesitter.get_string_parser` and applies `@<capture>` extmarks at
   priority 90 beneath the background-only diff line (100) and word (110)
   extmarks.
2. **Direct `streamProgress` JSON-RPC notifications via a pure Rust callback.**
   `ReviewSession::stream_with_progress` (`crates/review-core/src/session/diffs.rs`)
   accepts a pure Rust callback `FnMut(usize, usize, &str)` invoked before
   reading files and after each file finishes. `crates/review-rpc/src/server.rs`
   handles `stream` requests with `stream_with_progress` and writes
   `streamProgress` JSON-RPC notifications (`{ "completed", "total", "path" }`)
   straight to stdio as each file finishes, before the `stream` response
   arrives, feeding the 4-stage loading view (`lua/jpr/views/loading.lua`).

**Why.** Linking `JprDiff*` directly to `DiffAdd`/`DiffDelete` or setting
foreground colors washes out syntax highlighting on high-contrast themes and
varies wildly across colorschemes, while mutating global `DiffAdd` would affect
the user's non-jpr diff windows. Stream buffers hold multiple languages in one
`jpr-stream` buffer, so per-file string parsing restores authentic Treesitter
syntax colors without breaking diff gutter alignment. On the engine side,
taking a callback in `review-core` and writing `streamProgress` directly in
`review-rpc` keeps `crates/review-*` strictly UI-free and avoids polluting
`review_model::Event` (which carries persisted session state transitions) with
transient per-file progress ticks.

**Consequences.** Both file diffs and stream buffers retain native syntax
contrast across dark and light colorschemes, and `:Jpr open` shows immediate
stage and file-percentage feedback on large pull requests without waiting for
the entire `stream` response. Files without an installed Treesitter parser (or
over 5,000 stream rows) render cleanly without syntax highlighting, and
`streamProgress` is only emitted for `stream` calls on stdio.

**Revisit when.** Large multi-hundred-file streams need incremental chunked
rendering before `stream` finishes, or a second frontend needs `streamProgress`
exposed on a shared event bus rather than per-request callbacks.

## Self-contained native LSP file operations and local-only worktree file merging

**Decision.** Sidebar file creation, renaming, and moving combine two
self-contained layers with zero third-party plugin dependencies:

1. **Native Neovim LSP file operations (`lua/jpr/lsp_files/`).**
   `lua/jpr/lsp_files/` (`init.lua`, `clients.lua`, `buffers.lua`) drives
   `workspace/willRenameFiles`/`didRenameFiles` and
   `workspace/willCreateFiles`/`didCreateFiles` directly through Neovim's
   built-in `vim.lsp` API. Before renaming or creating, `clients.lua` checks
   workspace roots and server `fileOperations` glob filters, cold-starts an
   attached buffer for matching servers when none is attached yet, and waits
   for all `will*` edits with a configurable timeout. Any LSP failure or
   timeout pauses before mutating disk and prompts the user to either proceed
   without full import updates or cancel atomically. Case-only renames on
   case-insensitive filesystems such as APFS perform a two-step rename via a
   unique temporary sibling path (rolling back on step-2 failure), and
   `buffers.lua` snapshots dirty state before applying `WorkspaceEdit`s so
   previously clean buffers autosave while pre-dirty buffers warn instead of
   overwriting unsaved user work.
2. **Effective worktree file merging and `refreshWorktree` (`PROTOCOL_VERSION = 7`).**
   `crates/review-core/src/session/local_files.rs` merges GitHub's `saved.files`
   with local worktree changes since `merge_base` (`isLocalOnly: true` on
   `FileRow`), caching line counts by `(path, disk_digest)`. Comment validation
   splits by origin: local threads (`origin = "local"`) are allowed on both PR
   files and local-only files, whereas GitHub comments, `promoteThread`, and
   `suggestFromEdit` refuse local-only files until pushed to GitHub. Viewed
   state for local-only files persists in `local.json` (`localViewed`),
   transitions to `DISMISSED` when edited on disk, prunes when removed, and
   promotes into `queuedViewed` on sync once GitHub adopts the file. The
   stdio-only `refreshWorktree` RPC (accepting optional `renames`) immediately
   migrates local thread anchors and `localViewed` entries across file or
   directory renames, refreshes digests and `worktreeStatus`, and emits
   `threadsChanged` / `filesChanged` / `worktreeStatusChanged` without waiting
   for the 2-second watcher tick.

**Why.** Requiring an external file-explorer or LSP-file-operations plugin
would break out-of-the-box sidebar renames for reviewers who do not install
those plugins, and mutating disk after a partial or timed-out `willRenameFiles`
response leaves broken imports behind. Merging local-only worktree files in
`review-core` keeps the file list, diffs, viewed state, and comment rules
frontend-neutral so any future TUI shares the same semantics, while
`refreshWorktree` gives sidebar rename/create actions instant UI feedback and
preserves local review threads across path moves.

**Consequences.** Sidebar `r` and `a` update imports across attached LSP
servers and immediately reflect new, renamed, or moved files with `[local]`
badges in the panel and diffs. Local-only files stay clearly separated from
GitHub-backed review actions until `:Jpr push` and sync promote them, and
`PROTOCOL_VERSION` advances to `7`.

**Revisit when.** Neovim ships a built-in high-level `vim.lsp.fs` file
operations helper with cold-start attach and atomic error prompts, or when
reviewers want sidebar delete (`d`) with `workspace/willDeleteFiles` support.

## Unified local worktree review with in-place PR upgrade (`PROTOCOL_VERSION = 8`)

**Decision.** Local worktree reviews (`:Jpr local [base]`, with `:Jpr self [base]` as an Ex alias not shown in the Command Palette, and `jpr-review serve --local`)
run inside the same `ReviewSession` facade via `SessionTarget::{Pr, Local}`
rather than a separate session type or engine binary:

1. **Active PR auto-detection vs explicit base precedence.** Bare `:Jpr local`
   (and `jpr-review local`) probes GitHub via `gh pr view` in the current
   worktree and attaches directly to an open PR in-place (no duplicate checkout
   worktree). Supplying an explicit `--base <ref>` (for example `:Jpr local HEAD`)
   or `--no-pr` bypasses PR detection and stays local-only against that ref.
2. **Fork and non-GitHub safety.** `GhForge::new` receives `Some(repo)` only
   when the user explicitly passed `--repo`, never the `origin`-inferred
   repository name, so `gh` resolves upstream PRs on forks and classifies
   non-GitHub remotes as `Ok(None)`. Once linked, `Forge::pin_repo` pins
   subsequent polls to the linked PR's `owner/repo`.
3. **In-place mid-session upgrade and crash-safe retargeting.** Calling
   `:Jpr sync` in an unlinked local session probes `current_branch_pr()`,
   fetches the PR snapshot before touching disk, retargets `FsStore` from the
   local state directory to `pr-<N>/` (migrating `rounds.jsonl` and merging any
   preexisting PR snapshot while renumbering colliding `loc-*` IDs), keeps
   locally `VIEWED` files authoritative by promoting them to `queued_viewed`
   and pushing `setViewed(path, true)` to GitHub, and retires old local state
   files only after `pr-<N>/` is durably saved (`finalize_retarget`) while
   preserving the still-bound Unix domain socket (`JPR_SOCKET`) for any running
   coding-agent terminal.

**Why.** Preserving the live `jpr-review serve` process and `JPR_SOCKET` across
a mid-session local-to-PR upgrade means an active `:Jpr agent` terminal never
loses its socket or needs restarting when a branch is published as a PR. Keeping
all local-mode rules, viewed promotion, and GitHub-only refusals inside
`review-core` preserves the frontend-neutral dependency rule.

**Consequences.** Every GitHub-only operation (GitHub comments, `promoteThread`,
`:Jpr suggest`, `:Jpr submit`, `:Jpr push`, `retryMessage`,
`prepareConflictResolution`, and 60-second background GitHub polling) is
cleanly gated while unlinked, and `PROTOCOL_VERSION` advances to `8` alongside
release `0.7.0`.

**Revisit when.** Reviewers want to switch between multiple open PRs targeting
different base branches from the same worktree without closing the tab first.

## Reusing existing PR worktrees and fast-forwarding behind `HEAD` on reopen

**Decision.** Before `jpr-review checkout` invokes `gh pr checkout` or a custom
`worktree_cmd`, `find_existing_pr_worktree` scans `git worktree list --porcelain`
(preferring the `worktree` path saved in `session.json`) for any non-bare
worktree already checked out on `pr-<N>` or, for same-repository PRs, the PR's
`head_ref`. When a matching worktree exists, `checkout` returns it directly.
On the session's first `sync()`, `ReviewSession::apply_pull` also compares local
`HEAD` against `pr.head_sha` once (`has_checked_reopen_head`) so a reused
worktree that fell behind while closed runs `fast_forward_to` (nonce-pinned
auto-stash `--ff-only`, keeping the stash and opening the Resolve/Agent prompt
on `RestoreConflict`, and leaving `AheadOfTarget`/`Diverged` untouched without
repeating warnings on subsequent 60-second polls).

**Why.** Reopening a closed review or an already checked-out PR branch should
not re-run slow checkout commands or create duplicate worktrees, while dirty
edits from a prior review session must stay safe when pulling new commits.

**Consequences.** Cross-repository (fork) PRs only match `pr-<N>` (not `head_ref`
alone) to avoid colliding with an unrelated local branch of the same name.
State continues to live under `$XDG_STATE_HOME/jpr/` (`session.json`), never in
`~/.config/`.
