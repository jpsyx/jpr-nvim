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

**Decision.** `session.json` and `viewed.json` each carry a top-level
`"version"`. A file without one is corrupt, and a file with a newer version is
refused and never overwritten.

**Why.** The state outlives any one build, and later milestones add fields. An
older build that rewrote a newer file would silently drop what it did not
understand.

**Consequences.** Changing a file's shape means bumping its version in
`review-store-fs` and reading the old one. The two files are still written one
after the other, not as a pair, and the state directory ignores the forge host
and letter case; both are known limits for a later milestone.
