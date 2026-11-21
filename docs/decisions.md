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
