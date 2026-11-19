# jpr-nvim Milestone 1 (Core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the scaffold into a Cargo workspace with a frontend-neutral review engine and a Neovim plugin, so `:Jpr open <n>` checks a GitHub pull request out into a worktree, starts the `jpr-review` engine, and shows a live panel of the PR's changed files, viewed state and thread counts.

**Architecture:** Generic `review-*` crates hold the domain model, the ports and the `ReviewSession` facade, plus adapters for GitHub (`gh`), the file store, git worktrees and JSON-RPC. The `jpr-review` binary is the only composition root. The Lua plugin talks to `jpr-review serve` over newline-delimited JSON-RPC and only draws what the engine returns. Spec: `docs/superpowers/specs/2026-11-19-jpr-nvim-design.md` (milestone 1).

**Tech Stack:** Rust 2024 (anyhow, clap, serde, serde_json; threads and channels, no async runtime), the GitHub CLI (`gh`), git, Neovim 0.11+ Lua (headless `nvim -l` specs).

---

## Ground rules for every task

- Work in a worktree on branch `feat/core`, created with the user's worktree tool (Task 0). Commit after every task. Do not push, merge or open a PR.
- Run commands from the worktree root unless a step says otherwise.
- `just check` must pass at the end of every task from Task 2 on (format, clippy with `-D warnings`, Rust tests, and from Task 13 on the Lua specs). If clippy (pedantic + nursery) flags code from this plan, fix the lint without changing behavior and mention it in the commit message.
- **The dependency rule:** nothing in `crates/review-*` may depend on Neovim, Lua, a terminal UI library, or the `jpr-review` crate. Task 12 adds a test that enforces it.
- Code copied from dif comes from the `diff-review` skill's `scripts/dif/src/github/` (installed at `.agents/skills/diff-review/scripts/dif` after `just skills-install`). The code you need is already inlined below.
- **High-risk tasks** (per the execution rules: persistence formats and installers) are Task 2 (installer) and Task 6 (store format). They get a task-level review.

## File map

| Path | Responsibility |
| --- | --- |
| `Cargo.toml` | Workspace: members, shared dependencies, lints, release profile |
| `crates/review-model/` | Domain types and read models (pure data, serde) |
| `crates/review-core/` | Ports, `ReviewSession`, presenter, fakes and port contract tests (`fakes` feature) |
| `crates/review-store-fs/` | `ReviewStore` adapter: atomic JSON files under the XDG state dir |
| `crates/review-forge-github/` | `Forge` adapter over `gh` (copied and adapted from dif) |
| `crates/review-workspace-git/` | PR worktree checkout (default git + gh, or a custom command) |
| `crates/review-rpc/` | JSON-RPC protocol and server over any line transport |
| `crates/jpr-review/` | Binary and composition root: `checkout`, `serve`, `state-path`; the dependency-rule test |
| `plugin/jpr.lua` | Defines `:Jpr` |
| `lua/jpr/init.lua` | Config, highlights, command parsing and dispatch |
| `lua/jpr/rpc.lua` | JSON-RPC client over `jobstart` |
| `lua/jpr/session.lua` | One review per tab: checkout, engine process, panel updates |
| `lua/jpr/render/panel.lua` | Pure: `SessionView` to lines, highlights and a line-to-path map |
| `lua/jpr/views/panel.lua` | Panel window and buffer; `<CR>` opens a file |
| `tests/lua/*_spec.lua`, `tests/lua/fixtures/fake_engine.sh` | Lua specs and a fake engine |
| `scripts/test-lua.sh` | Runs every Lua spec headless |
| `docs/architecture.md`, `docs/protocol.md`, `docs/decisions.md`, `README.md`, `AGENTS.md` | Docs updated to match |

---

### Task 0: Worktree

- [ ] **Step 1: Create the worktree for `feat/core`**

Follow the user's worktree conventions (their global rules name the tool and the skill to load first). From the main checkout:

```bash
cd "$(wt new feat core)"
git branch --show-current
```

Expected: `feat/core`.

- [ ] **Step 2: Restore the agent skills**

```bash
just skills-install
```

Expected: completes. `.agents/skills/diff-review/scripts/dif/src/github/client.rs` exists.

---

### Task 1: Remove the scaffold's unrelated design-agent boilerplate

Mechanical. Removes the `impeccable` UI-design agents, skill and hooks that the scaffolder added.

**Files:**
- Delete: `.claude/agents/impeccable-*.md` (tracked)
- Delete (untracked, local only): impeccable skill copies and hook files
- Modify: `scripts/skills/update-skills.sh`, `docs/skills.md`, `AGENTS.md`

- [ ] **Step 1: Delete the tracked and local impeccable files**

```bash
git rm -q .claude/agents/impeccable-asset-producer.md .claude/agents/impeccable-documenter.md \
  .claude/agents/impeccable-finish-reviewer.md .claude/agents/impeccable-manual-edit-applier.md \
  .claude/agents/impeccable-motion-reviewer.md
rm -rf .agents/skills/impeccable .claude/skills/impeccable .cursor/skills/impeccable \
  .opencode/skills/impeccable .opencode/commands/impeccable.md
rm -f .cursor/agents/impeccable-*.md .cursor/hooks.json .codex/hooks.json
```

- [ ] **Step 2: Make the update script lock-only**

Replace everything in `scripts/skills/update-skills.sh` from the line `# Space separated npm package names, written by the scaffolder.` to the end of the file with:

```bash
echo "Updating the skills in skills-lock.json..."
npx --yes skills update --project --yes </dev/null
```

Then replace the header comment block (the lines between `# Updates every agent skill this project has, whatever installed it.` and `# This script is the one place a skill update happens, so a project updates its`) with:

```bash
# Updates every agent skill this project has. `npx skills` owns them all,
# through `skills-lock.json`.
#
```

Run: `bash -n scripts/skills/update-skills.sh`
Expected: no output (valid syntax).

- [ ] **Step 3: Rewrite `docs/skills.md`**

Replace the whole file with:

````markdown
# Agent skills

This project ships a curated set of agent skills so every coding agent working
here starts with the same tooling. This document explains how they get onto
disk.

## One manager

**`npx skills`** installs everything listed in `skills-lock.json`. It writes
the real skill directories to `.agents/skills/`, symlinks them into
`.claude/skills/` for Claude Code, and relies on Cursor, OpenCode, and Codex
reading `.agents/skills/` natively.

- `npx skills list`: every skill, flagging any that are missing.
- `just skills-install`: install the locked skills that are not on disk yet.
- `just skills-update`: update every skill (`scripts/skills/update-skills.sh`).

Never create the per-frontend symlinks by hand: the manager owns the layout its
frontends expect.

## What git tracks

**Only `skills-lock.json`.** The installed directories (`.agents/`,
`.claude/skills/`, `.cursor/skills/`, `.opencode/`, `.codex/`) are gitignored.

- `just skills-install` restores them after a clone. It adds whatever the lock
  asks for that is not on disk and leaves everything else untouched.
- Install and update are separate: `just skills-install` materializes what is
  locked without upgrading anything, and `just skills-update` is the deliberate
  "get the latest" step.
- Where the restore runs automatically, `CI=true` or `SKIP_SKILLS_INSTALL=1`
  turns it off.

## Changing the skill set

```sh
npx skills add <owner>/<repo> --skill <name> --agent claude-code cursor opencode codex
npx skills remove <name>
```

Both commands update `skills-lock.json`. Commit that change.
````

- [ ] **Step 4: Fix the Agent skills section of `AGENTS.md`**

Replace:

```markdown
- This project's agent skills are installed by two tools and neither should be
  driven by hand: `npx skills` for everything in `skills-lock.json`, and
  `npx impeccable` for the `impeccable` skill, which ships its own installer.
```

with:

```markdown
- This project's agent skills are installed by `npx skills` from
  `skills-lock.json`; never install or copy skills by hand.
```

and replace:

```markdown
- `just skills-update` runs `scripts/skills/update-skills.sh`, which
  updates both managers: `npx skills` for the lock, and each self-installing
  skill (the list at the top of the script) through its own CLI. Update skills
  there, never by calling one manager by hand.
```

with:

```markdown
- `just skills-update` runs `scripts/skills/update-skills.sh`, which updates
  everything in the lock.
```

- [ ] **Step 5: Verify nothing references impeccable**

Run: `git grep -n -i impeccable -- . ':!docs/superpowers'`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add -A scripts/skills/update-skills.sh docs/skills.md AGENTS.md .claude/agents
git commit -m "chore: remove the scaffold's impeccable design-agent boilerplate"
```

---

### Task 2: Cargo workspace and the `jpr-review` crate (HIGH-RISK: installer)

Moves the scaffold binary into `crates/jpr-review` unchanged (its example commands stay until Task 12), makes the root a workspace, and points the installer and `justfile` at it.

**Files:**
- Move: `src/` to `crates/jpr-review/src/`, `tests/` to `crates/jpr-review/tests/`
- Create: `crates/jpr-review/Cargo.toml`
- Replace: `Cargo.toml`, `justfile`
- Modify: `install.sh`

- [ ] **Step 1: Move the scaffold**

```bash
mkdir -p crates/jpr-review
git mv src crates/jpr-review/src
git mv tests crates/jpr-review/tests
```

- [ ] **Step 2: Replace the root `Cargo.toml`**

```toml
# A workspace: generic review crates (`crates/review-*`) that any frontend can
# reuse, and one binary (`crates/jpr-review`) that wires them together for the
# Neovim plugin. The dependency rule is in docs/architecture.md.
[workspace]
resolver = "3"
members = ["crates/*"]

[workspace.package]
version = "0.1.0"
edition = "2024"
rust-version = "1.85"
license = "MIT"

[workspace.dependencies]
anyhow = "1"
clap = { version = "4", features = ["derive", "env"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tempfile = "3"
review-model = { path = "crates/review-model" }
review-core = { path = "crates/review-core" }
review-store-fs = { path = "crates/review-store-fs" }
review-forge-github = { path = "crates/review-forge-github" }
review-workspace-git = { path = "crates/review-workspace-git" }
review-rpc = { path = "crates/review-rpc" }

[workspace.lints.rust]
unsafe_code = "forbid"

[workspace.lints.clippy]
pedantic = { level = "warn", priority = -1 }
nursery = { level = "warn", priority = -1 }
# Help and about strings would render literal backticks in a terminal.
doc_markdown = "allow"
missing_errors_doc = "allow"
missing_panics_doc = "allow"

[profile.release]
lto = "thin"
codegen-units = 1
strip = true
```

- [ ] **Step 3: Create `crates/jpr-review/Cargo.toml`**

```toml
[package]
name = "jpr-review"
description = "The review engine behind the jpr Neovim plugin."
version.workspace = true
edition.workspace = true
rust-version.workspace = true
license.workspace = true

# The library half holds everything worth testing; the binary is a thin shell
# around it. Tests and the binary both say `use app::...`.
[lib]
name = "app"
path = "src/lib.rs"

[[bin]]
name = "jpr-review"
path = "src/main.rs"

[dependencies]
anyhow.workspace = true
clap.workspace = true
serde.workspace = true
# Only the scaffold's example `config` command uses TOML; Task 12 removes both.
toml = { version = "1", features = ["preserve_order"] }

[lints]
workspace = true
```

- [ ] **Step 4: Run the moved tests**

Run: `cargo test --workspace`
Expected: PASS (the scaffold's existing tests, now in `jpr-review`).

- [ ] **Step 5: Point `install.sh` at `jpr-review`**

In `install.sh`, make exactly these replacements:

| Old | New |
| --- | --- |
| `# Install or update jpr-nvim as a command on this machine.` | `# Install or update jpr-review, the engine behind the jpr Neovim plugin.` |
| `printf '%s\n' 'Install or update jpr-nvim as an executable command.` | `printf '%s\n' 'Install or update jpr-review as an executable command.` |
| `  --name <command>  Command filename (default: jpr-nvim).` | `  --name <command>  Command filename (default: jpr-review).` |
| `  BIN_DIR="$HOME/bin" ./install.sh --name jpr-nvim-dev'` | `  BIN_DIR="$HOME/bin" ./install.sh --name jpr-review-dev'` |
| `binary_name="jpr-nvim"` | `binary_name="jpr-review"` |
| `  echo "error: 'cargo' not found; jpr-nvim builds from source and needs a Rust toolchain." >&2` | `  echo "error: 'cargo' not found; jpr-review builds from source and needs a Rust toolchain." >&2` |
| `echo "Building jpr-nvim (release)..." >&2` | `echo "Building jpr-review (release)..." >&2` |
| `(cd "$script_dir" && cargo build --release) >&2` | `(cd "$script_dir" && cargo build --release -p jpr-review) >&2` |

- [ ] **Step 6: Verify the installer contract**

```bash
tmp="$(mktemp -d)"
./install.sh --help >/dev/null; echo "help exit=$?"
BIN_DIR="$tmp" ./install.sh --bogus 2>/dev/null; echo "bogus exit=$?"
ls -A "$tmp"
BIN_DIR="$tmp" ./install.sh
BIN_DIR="$tmp" ./install.sh --name jpr-review-dev
ls "$tmp"
"$tmp/jpr-review" --version
rm -rf "$tmp"
```

Expected: `help exit=0`, `bogus exit=2`, an empty listing after the bogus run, then `jpr-review` and `jpr-review-dev` in the listing, and `jpr-review 0.1.0`.

- [ ] **Step 7: Replace the `justfile`**

```just
# Task entry points for jpr-nvim.
#
# `just` is a convenience, never a dependency: every recipe below is a single
# command you can also type by hand. Install it with `cargo install just`.

# Recipe arguments arrive as "$@" rather than just's own interpolation.
set positional-arguments

# Show the available tasks.
default:
    @just --list

# Compile every crate (debug).
build:
    cargo build --workspace

# Run the engine binary, for example: just run state-path --pr 7 --repo octo/widgets
run *args:
    cargo run -p jpr-review -- "$@"

# Run every Rust test, including the shared fakes and port contracts.
test:
    cargo test --workspace --all-features

# Run every Lua spec in a clean headless Neovim.
test-lua:
    ./scripts/test-lua.sh

# Lint with clippy (pedantic + nursery are on); any warning fails.
lint:
    cargo clippy --workspace --all-targets --all-features -- -D warnings

# Format the source.
fmt:
    cargo fmt --all

# Fail if anything is unformatted, without rewriting it.
fmt-check:
    cargo fmt --all --check

# Everything that has to pass before a change lands (reports only: `just fmt` fixes).
check: fmt-check lint test

# Build release and install `jpr-review` into $BIN_DIR (default ~/.local/bin).
install:
    ./install.sh

# Restore the agent skills pinned in skills-lock.json (run once after cloning).
skills-install:
    npx --yes skills experimental_install

# Update every agent skill this project has.
skills-update:
    ./scripts/skills/update-skills.sh
```

Task 13 adds `test-lua` to `check` once `scripts/test-lua.sh` exists.

- [ ] **Step 8: Run the gate and commit**

Run: `just check`
Expected: PASS.

```bash
git add -A Cargo.toml Cargo.lock crates justfile install.sh
git commit -m "build: make the repo a workspace and install the jpr-review binary"
```

---

### Task 3: `review-model`

**Files:**
- Create: `crates/review-model/Cargo.toml`, `crates/review-model/src/{lib,pr,thread,view}.rs`

- [ ] **Step 1: Create the crate manifest**

`crates/review-model/Cargo.toml`:

```toml
[package]
name = "review-model"
description = "Frontend-neutral review domain types and read models."
version.workspace = true
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[dependencies]
serde.workspace = true

[dev-dependencies]
serde_json.workspace = true

[lints]
workspace = true
```

- [ ] **Step 2: Write the failing tests**

`crates/review-model/src/lib.rs`:

```rust
//! The review domain: pull requests, changed files, threads, and the read
//! models every frontend draws. Pure data: no IO and no frontend concepts.

mod pr;
mod thread;
mod view;

pub use pr::{ChangedFile, PullRequest, ViewedState};
pub use thread::{Anchor, AnchorKind, Message, MessageSync, Origin, Side, Thread, ThreadState};
pub use view::{Event, FileRow, SessionView, SyncState};
```

`crates/review-model/src/pr.rs` (tests only for now):

```rust
//! Pull requests and the files they change.

#[cfg(test)]
mod tests {
    use super::*;

    fn pr() -> PullRequest {
        PullRequest {
            owner: "octo".into(),
            repo: "widgets".into(),
            number: 7,
            title: "Fix the widget".into(),
            url: "https://github.com/octo/widgets/pull/7".into(),
            node_id: "PR_7".into(),
            author: "alice".into(),
            head_ref: "fix/widget".into(),
            head_sha: "abc123".into(),
            base_ref: "main".into(),
        }
    }

    #[test]
    fn viewed_state_parses_github_spellings() {
        assert_eq!(ViewedState::parse("VIEWED"), Some(ViewedState::Viewed));
        assert_eq!(ViewedState::parse("UNVIEWED"), Some(ViewedState::Unviewed));
        assert_eq!(ViewedState::parse("DISMISSED"), Some(ViewedState::Dismissed));
        assert_eq!(ViewedState::parse("viewed"), None);
    }

    #[test]
    fn viewed_state_serializes_as_github_spells_it() {
        assert_eq!(serde_json::to_string(&ViewedState::Dismissed).unwrap(), "\"DISMISSED\"");
    }

    #[test]
    fn pull_request_uses_camel_case_keys() {
        let json = serde_json::to_value(pr()).unwrap();
        assert_eq!(json["nodeId"], "PR_7");
        assert_eq!(json["headSha"], "abc123");
        assert_eq!(json["headRef"], "fix/widget");
        assert_eq!(json["baseRef"], "main");
    }
}
```

`crates/review-model/src/thread.rs` (tests only for now):

```rust
//! Review threads. GitHub's and local ones share one shape.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_thread_round_trips_through_json_with_its_wire_spellings() {
        let thread = Thread {
            id: "T1".into(),
            origin: Origin::Github,
            anchor: Anchor::line("src/a.rs", 12),
            state: ThreadState::Open,
            outdated: false,
            messages: vec![Message {
                id: "C1".into(),
                author: "bob".into(),
                body: "why?".into(),
                created: "2026-11-19T00:00:00Z".into(),
                updated: "2026-11-19T00:00:00Z".into(),
                sync: Some(MessageSync::Draft),
            }],
        };
        let json = serde_json::to_value(&thread).unwrap();
        assert_eq!(json["origin"], "github");
        assert_eq!(json["anchor"]["kind"], "line");
        assert_eq!(json["anchor"]["side"], "RIGHT");
        assert_eq!(json["state"], "open");
        assert_eq!(json["messages"][0]["sync"], "draft");
        let back: Thread = serde_json::from_value(json).unwrap();
        assert_eq!(back, thread);
    }

    #[test]
    fn a_local_message_omits_sync_and_outdated_defaults_to_false() {
        let json = serde_json::json!({
            "id": "L1", "origin": "local",
            "anchor": { "file": null, "kind": "pr", "side": "RIGHT", "start": null, "end": null, "commit": null, "snapshot": null },
            "state": "resolved",
            "messages": [{ "id": "m", "author": "me", "body": "b", "created": "c", "updated": "u" }]
        });
        let thread: Thread = serde_json::from_value(json).unwrap();
        assert!(!thread.outdated);
        assert_eq!(thread.anchor.kind, AnchorKind::Pr);
        assert_eq!(thread.messages[0].sync, None);
        let out = serde_json::to_value(&thread).unwrap();
        assert!(out["messages"][0].get("sync").is_none());
    }
}
```

`crates/review-model/src/view.rs` (tests only for now):

```rust
//! The read models a frontend draws, and the events that announce changes.
//! Their JSON shape is the wire format in docs/protocol.md.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sync_states_are_tagged_by_state() {
        assert_eq!(serde_json::to_value(SyncState::Never).unwrap(), serde_json::json!({ "state": "never" }));
        assert_eq!(
            serde_json::to_value(SyncState::Synced { at: 5 }).unwrap(),
            serde_json::json!({ "state": "synced", "at": 5 })
        );
        assert_eq!(
            serde_json::to_value(SyncState::Failed { at: 6, message: "offline".into() }).unwrap(),
            serde_json::json!({ "state": "failed", "at": 6, "message": "offline" })
        );
    }

    #[test]
    fn events_are_tagged_by_type_and_views_use_camel_case() {
        let view = SessionView {
            pr: None,
            files: vec![FileRow { path: "a.rs".into(), additions: 1, deletions: 2, viewed: ViewedState::Viewed, threads: 3 }],
            viewed_count: 1,
            thread_count: 3,
            sync: SyncState::Never,
        };
        let json = serde_json::to_value(Event::Synced { view }).unwrap();
        assert_eq!(json["type"], "synced");
        assert_eq!(json["view"]["viewedCount"], 1);
        assert_eq!(json["view"]["threadCount"], 3);
        assert_eq!(json["view"]["files"][0]["viewed"], "VIEWED");
        let failed = serde_json::to_value(Event::SyncFailed { message: "offline".into() }).unwrap();
        assert_eq!(failed, serde_json::json!({ "type": "syncFailed", "message": "offline" }));
    }
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cargo test -p review-model`
Expected: FAIL to compile (`cannot find type PullRequest`, `ViewedState`, `Thread`, ...).

- [ ] **Step 4: Implement `pr.rs`**

Insert above the `#[cfg(test)]` line in `crates/review-model/src/pr.rs`:

```rust
use serde::{Deserialize, Serialize};

/// A pull request under review.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullRequest {
    /// The repository owner, e.g. `octo`.
    pub owner: String,
    /// The repository name, e.g. `widgets`.
    pub repo: String,
    pub number: u64,
    pub title: String,
    pub url: String,
    /// The forge's own id for the pull request (GitHub's GraphQL node id).
    pub node_id: String,
    /// The author's login.
    pub author: String,
    /// The branch being merged, e.g. `fix/widget`.
    pub head_ref: String,
    /// The head commit new comments are anchored to.
    pub head_sha: String,
    /// The branch it merges into, e.g. `main`.
    pub base_ref: String,
}

/// Whether the reviewer has viewed a file, as the forge tracks it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ViewedState {
    Viewed,
    Unviewed,
    /// Viewed once, but the file changed since.
    Dismissed,
}

impl ViewedState {
    /// Parses GitHub's `FileViewedState` spelling.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "VIEWED" => Some(Self::Viewed),
            "UNVIEWED" => Some(Self::Unviewed),
            "DISMISSED" => Some(Self::Dismissed),
            _ => None,
        }
    }
}

/// One file the pull request changes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangedFile {
    pub path: String,
    pub additions: u64,
    pub deletions: u64,
    pub viewed: ViewedState,
}
```

- [ ] **Step 5: Implement `thread.rs`**

Insert above the `#[cfg(test)]` line in `crates/review-model/src/thread.rs`:

```rust
use serde::{Deserialize, Serialize};

/// Where a thread lives.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    /// On the forge (GitHub).
    Github,
    /// Only on this machine, for the agent.
    Local,
}

/// Which side of the diff a thread is anchored to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum Side {
    /// The old file.
    Left,
    /// The new file.
    Right,
}

/// What a thread is attached to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AnchorKind {
    Line,
    Range,
    File,
    Pr,
}

/// Where a thread is attached.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Anchor {
    /// The file, for every kind but `pr`.
    pub file: Option<String>,
    pub kind: AnchorKind,
    pub side: Side,
    /// The first line, for `line` and `range`.
    pub start: Option<u64>,
    /// The last line, for `line` and `range`.
    pub end: Option<u64>,
    /// The commit the line numbers refer to, when known.
    pub commit: Option<String>,
    /// The anchored code, used to re-anchor a thread whose lines moved.
    pub snapshot: Option<String>,
}

impl Anchor {
    /// A single line on the new side of `file`.
    #[must_use]
    pub fn line(file: &str, line: u64) -> Self {
        Self {
            file: Some(file.to_owned()),
            kind: AnchorKind::Line,
            side: Side::Right,
            start: Some(line),
            end: Some(line),
            commit: None,
            snapshot: None,
        }
    }
}

/// Whether a thread still needs attention.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThreadState {
    Open,
    Resolved,
}

/// Where a forge message stands. Local messages have none.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageSync {
    /// In the reviewer's pending review, visible only to them.
    Draft,
    /// Being written to the forge.
    Pending,
    Published,
    Failed,
    /// Waiting for the network.
    Queued,
}

/// One message in a thread.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub id: String,
    pub author: String,
    pub body: String,
    pub created: String,
    pub updated: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sync: Option<MessageSync>,
}

/// A conversation attached to an anchor.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Thread {
    pub id: String,
    pub origin: Origin,
    pub anchor: Anchor,
    pub state: ThreadState,
    /// The forge says the anchored code changed since the thread was opened.
    #[serde(default)]
    pub outdated: bool,
    pub messages: Vec<Message>,
}
```

- [ ] **Step 6: Implement `view.rs`**

Insert above the `#[cfg(test)]` line in `crates/review-model/src/view.rs`:

```rust
use serde::{Deserialize, Serialize};

use crate::{PullRequest, ViewedState};

/// When the session last talked to the forge, and how it went.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum SyncState {
    /// Never synced.
    Never,
    /// The last sync succeeded at `at` (Unix seconds).
    Synced { at: u64 },
    /// The last sync failed at `at` with `message`.
    Failed { at: u64, message: String },
}

/// One changed file as the file list shows it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileRow {
    pub path: String,
    pub additions: u64,
    pub deletions: u64,
    pub viewed: ViewedState,
    /// Threads anchored to this file, open or resolved.
    pub threads: usize,
}

/// Everything a frontend needs to draw the session's status.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionView {
    pub pr: Option<PullRequest>,
    pub files: Vec<FileRow>,
    pub viewed_count: usize,
    pub thread_count: usize,
    pub sync: SyncState,
}

/// A change the session announces to its subscribers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Event {
    /// A sync finished; `view` is the new state.
    Synced { view: SessionView },
    /// A sync failed; the previous view still stands.
    SyncFailed { message: String },
}
```

- [ ] **Step 7: Run the tests**

Run: `cargo test -p review-model`
Expected: PASS (7 tests).

- [ ] **Step 8: Gate and commit**

Run: `just check`
Expected: PASS.

```bash
git add crates/review-model Cargo.lock
git commit -m "feat(model): add the review domain types and read models"
```

---

### Task 4: `review-core` ports, presenter, fakes and the store contract

**Files:**
- Create: `crates/review-core/Cargo.toml`, `crates/review-core/src/{lib,ports,presenter,fakes,contract}.rs`

- [ ] **Step 1: Create the crate manifest**

`crates/review-core/Cargo.toml`:

```toml
[package]
name = "review-core"
description = "The frontend-neutral review engine: ports, the ReviewSession facade, and its rules."
version.workspace = true
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[features]
# In-memory fakes of every port and the shared port contract tests, for other
# crates' tests. Never enabled by a binary.
fakes = []

[dependencies]
anyhow.workspace = true
serde.workspace = true
review-model.workspace = true

[lints]
workspace = true
```

- [ ] **Step 2: Write the ports, fakes and contract (no tests of their own yet)**

`crates/review-core/src/lib.rs`:

```rust
//! The review engine. Frontends talk only to the `ReviewSession` facade; the
//! outside world is reached only through the traits in [`ports`]. See
//! docs/architecture.md.

pub mod ports;
mod presenter;

#[cfg(any(test, feature = "fakes"))]
pub mod contract;
#[cfg(any(test, feature = "fakes"))]
pub mod fakes;

pub use presenter::session_view;
```

`crates/review-core/src/ports.rs`:

```rust
//! The ports: everything the engine needs from the outside world. Adapters
//! (GitHub, the file store, the system clock) implement them, and tests use
//! the in-memory fakes.

use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use review_model::{ChangedFile, PullRequest, Thread};
use serde::{Deserialize, Serialize};

/// What the forge reports about a pull request in one pull.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ForgeSnapshot {
    pub head_sha: String,
    /// Whether the reviewer has a pending (unsubmitted) review.
    pub has_pending_review: bool,
    pub threads: Vec<Thread>,
    pub files: Vec<ChangedFile>,
}

/// The code forge that hosts the pull request (GitHub today).
pub trait Forge: Send {
    /// The open pull request numbered `number`.
    fn pull_request(&self, number: u64) -> Result<PullRequest>;
    /// Its threads, changed files and viewed state.
    fn fetch(&self, pr: &PullRequest) -> Result<ForgeSnapshot>;
}

/// The running daemon and what it last saw, persisted between runs.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SessionRecord {
    pub pid: Option<u32>,
    pub worktree: Option<String>,
    pub pr: Option<PullRequest>,
    /// Unix seconds of the last successful sync.
    pub last_synced_at: Option<u64>,
}

/// Everything the engine persists for one pull request. Later milestones add
/// local threads, the sync registry and agent rounds as new fields.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StoreSnapshot {
    pub session: SessionRecord,
    /// The changed files and their viewed state as last synced.
    pub files: Vec<ChangedFile>,
}

/// Durable storage for one pull request's review state.
pub trait ReviewStore: Send {
    /// What was saved last, or an empty snapshot when nothing was.
    fn load(&self) -> Result<StoreSnapshot>;
    /// Replaces what is saved.
    fn save(&self, snapshot: &StoreSnapshot) -> Result<()>;
}

/// The time in Unix seconds. A port so tests control it.
pub trait Clock: Send {
    fn now(&self) -> u64;
}

/// The real clock.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_secs())
    }
}
```

`crates/review-core/src/fakes.rs`:

```rust
//! In-memory fakes of every port, for tests here and in other crates. Each
//! fake is a cheap handle: clones share state, so a test can keep one and give
//! another to the session.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use anyhow::{Result, anyhow};
use review_model::{
    Anchor, ChangedFile, Message, MessageSync, Origin, PullRequest, Thread, ThreadState,
    ViewedState,
};

use crate::ports::{Clock, Forge, ForgeSnapshot, ReviewStore, StoreSnapshot};

/// A pull request with plausible values (#7 in octo/widgets).
#[must_use]
pub fn sample_pr() -> PullRequest {
    PullRequest {
        owner: "octo".into(),
        repo: "widgets".into(),
        number: 7,
        title: "Fix the widget".into(),
        url: "https://github.com/octo/widgets/pull/7".into(),
        node_id: "PR_7".into(),
        author: "alice".into(),
        head_ref: "fix/widget".into(),
        head_sha: "abc123".into(),
        base_ref: "main".into(),
    }
}

/// A changed file with three additions and one deletion.
#[must_use]
pub fn changed_file(path: &str, viewed: ViewedState) -> ChangedFile {
    ChangedFile {
        path: path.into(),
        additions: 3,
        deletions: 1,
        viewed,
    }
}

/// A published GitHub thread with one comment on line 1 of `path`.
#[must_use]
pub fn github_thread(id: &str, path: &str) -> Thread {
    Thread {
        id: id.into(),
        origin: Origin::Github,
        anchor: Anchor::line(path, 1),
        state: ThreadState::Open,
        outdated: false,
        messages: vec![Message {
            id: format!("{id}-c1"),
            author: "bob".into(),
            body: "why?".into(),
            created: "2026-11-19T00:00:00Z".into(),
            updated: "2026-11-19T00:00:00Z".into(),
            sync: Some(MessageSync::Published),
        }],
    }
}

#[derive(Debug, Default)]
struct ForgeState {
    pr: Option<PullRequest>,
    snapshot: ForgeSnapshot,
    failure: Option<String>,
    fetches: usize,
}

/// A forge that answers from memory.
#[derive(Debug, Clone, Default)]
pub struct FakeForge {
    state: Arc<Mutex<ForgeState>>,
}

impl FakeForge {
    /// A forge that knows `pr` and reports `snapshot` for it.
    #[must_use]
    pub fn new(pr: PullRequest, snapshot: ForgeSnapshot) -> Self {
        let forge = Self::default();
        {
            let mut state = forge.lock();
            state.pr = Some(pr);
            state.snapshot = snapshot;
        }
        forge
    }

    /// Makes every later call fail with `message`, or succeed again with `None`.
    pub fn fail_with(&self, message: Option<&str>) {
        self.lock().failure = message.map(str::to_owned);
    }

    /// Replaces what `fetch` reports.
    pub fn set_snapshot(&self, snapshot: ForgeSnapshot) {
        self.lock().snapshot = snapshot;
    }

    /// How many times `fetch` succeeded.
    #[must_use]
    pub fn fetches(&self) -> usize {
        self.lock().fetches
    }

    fn lock(&self) -> MutexGuard<'_, ForgeState> {
        self.state.lock().expect("the fake forge lock is poisoned")
    }
}

impl Forge for FakeForge {
    fn pull_request(&self, number: u64) -> Result<PullRequest> {
        let state = self.lock();
        if let Some(message) = &state.failure {
            return Err(anyhow!("{message}"));
        }
        state
            .pr
            .clone()
            .filter(|pr| pr.number == number)
            .ok_or_else(|| anyhow!("no pull request #{number}"))
    }

    fn fetch(&self, _pr: &PullRequest) -> Result<ForgeSnapshot> {
        let mut state = self.lock();
        if let Some(message) = &state.failure {
            return Err(anyhow!("{message}"));
        }
        state.fetches += 1;
        Ok(state.snapshot.clone())
    }
}

/// A store that keeps the snapshot in memory.
#[derive(Debug, Clone, Default)]
pub struct MemoryStore {
    saved: Arc<Mutex<StoreSnapshot>>,
}

impl MemoryStore {
    /// What was saved last.
    #[must_use]
    pub fn saved(&self) -> StoreSnapshot {
        self.saved.lock().expect("the memory store lock is poisoned").clone()
    }
}

impl ReviewStore for MemoryStore {
    fn load(&self) -> Result<StoreSnapshot> {
        Ok(self.saved())
    }

    fn save(&self, snapshot: &StoreSnapshot) -> Result<()> {
        *self.saved.lock().expect("the memory store lock is poisoned") = snapshot.clone();
        Ok(())
    }
}

/// A clock a test sets by hand.
#[derive(Debug, Clone, Default)]
pub struct FixedClock {
    now: Arc<AtomicU64>,
}

impl FixedClock {
    /// A clock that reads `now`.
    #[must_use]
    pub fn at(now: u64) -> Self {
        Self {
            now: Arc::new(AtomicU64::new(now)),
        }
    }

    /// Moves the clock to `now`.
    pub fn set(&self, now: u64) {
        self.now.store(now, Ordering::SeqCst);
    }
}

impl Clock for FixedClock {
    fn now(&self) -> u64 {
        self.now.load(Ordering::SeqCst)
    }
}
```

`crates/review-core/src/contract.rs`:

```rust
//! Contract tests every adapter of a port must pass. Call them from the
//! adapter's own tests with a fresh, empty instance.

use review_model::ViewedState;

use crate::fakes::{changed_file, sample_pr};
use crate::ports::{ReviewStore, SessionRecord, StoreSnapshot};

/// Checks a [`ReviewStore`] that starts empty.
pub fn check_review_store(store: &dyn ReviewStore) {
    assert_eq!(
        store.load().expect("an empty store loads"),
        StoreSnapshot::default(),
        "an empty store loads as the default snapshot"
    );
    let first = StoreSnapshot {
        session: SessionRecord {
            pid: Some(42),
            worktree: Some("/tmp/widgets-worktrees/pr-7".into()),
            pr: Some(sample_pr()),
            last_synced_at: Some(100),
        },
        files: vec![
            changed_file("src/a.rs", ViewedState::Viewed),
            changed_file("src/b.rs", ViewedState::Dismissed),
        ],
    };
    store.save(&first).expect("saving works");
    assert_eq!(store.load().expect("loads after a save"), first, "a save round-trips");
    let second = StoreSnapshot {
        files: vec![changed_file("src/c.rs", ViewedState::Unviewed)],
        ..first
    };
    store.save(&second).expect("saving again works");
    assert_eq!(
        store.load().expect("loads after a second save"),
        second,
        "a later save replaces the earlier one"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fakes::MemoryStore;

    #[test]
    fn the_memory_store_passes_the_contract() {
        check_review_store(&MemoryStore::default());
    }
}
```

- [ ] **Step 3: Write the failing presenter tests**

`crates/review-core/src/presenter.rs` (tests only for now):

```rust
//! Builds the read models frontends draw. Pure functions only.

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fakes::{changed_file, github_thread, sample_pr};

    #[test]
    fn counts_threads_per_file_and_viewed_files() {
        let files = [
            changed_file("a.rs", ViewedState::Viewed),
            changed_file("b.rs", ViewedState::Dismissed),
            changed_file("c.rs", ViewedState::Unviewed),
        ];
        let threads = [
            github_thread("T1", "a.rs"),
            github_thread("T2", "a.rs"),
            github_thread("T3", "c.rs"),
        ];
        let view = session_view(Some(&sample_pr()), &files, &threads, &SyncState::Synced { at: 5 });
        let counts: Vec<(&str, usize)> = view.files.iter().map(|row| (row.path.as_str(), row.threads)).collect();
        assert_eq!(counts, [("a.rs", 2), ("b.rs", 0), ("c.rs", 1)]);
        assert_eq!(view.viewed_count, 1, "a dismissed file is not viewed");
        assert_eq!(view.thread_count, 3);
        assert_eq!(view.pr.map(|pr| pr.number), Some(7));
        assert_eq!(view.sync, SyncState::Synced { at: 5 });
    }

    #[test]
    fn keeps_the_forge_file_order() {
        let files = [changed_file("z.rs", ViewedState::Unviewed), changed_file("a.rs", ViewedState::Unviewed)];
        let view = session_view(None, &files, &[], &SyncState::Never);
        let paths: Vec<&str> = view.files.iter().map(|row| row.path.as_str()).collect();
        assert_eq!(paths, ["z.rs", "a.rs"]);
        assert!(view.pr.is_none());
    }
}
```

- [ ] **Step 4: Run the tests to see them fail**

Run: `cargo test -p review-core`
Expected: FAIL to compile (`cannot find function session_view`).

- [ ] **Step 5: Implement the presenter**

Insert above the `#[cfg(test)]` line in `crates/review-core/src/presenter.rs`:

```rust
use review_model::{
    ChangedFile, FileRow, PullRequest, SessionView, SyncState, Thread, ViewedState,
};

/// The session's status view: the pull request, its files with viewed state
/// and thread counts, and how the last sync went.
#[must_use]
pub fn session_view(
    pr: Option<&PullRequest>,
    files: &[ChangedFile],
    threads: &[Thread],
    sync: &SyncState,
) -> SessionView {
    let rows = files
        .iter()
        .map(|file| FileRow {
            path: file.path.clone(),
            additions: file.additions,
            deletions: file.deletions,
            viewed: file.viewed,
            threads: threads
                .iter()
                .filter(|thread| thread.anchor.file.as_deref() == Some(file.path.as_str()))
                .count(),
        })
        .collect();
    SessionView {
        pr: pr.cloned(),
        files: rows,
        viewed_count: files.iter().filter(|file| file.viewed == ViewedState::Viewed).count(),
        thread_count: threads.len(),
        sync: sync.clone(),
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `cargo test -p review-core --all-features`
Expected: PASS (3 tests).

- [ ] **Step 7: Gate and commit**

Run: `just check`
Expected: PASS.

```bash
git add crates/review-core Cargo.lock
git commit -m "feat(core): add the ports, presenter, fakes and store contract"
```

---

### Task 5: `ReviewSession`

**Files:**
- Create: `crates/review-core/src/session.rs`
- Modify: `crates/review-core/src/lib.rs`

- [ ] **Step 1: Write the failing tests**

`crates/review-core/src/session.rs` (tests only for now):

```rust
//! The facade every frontend talks to. It owns the session state, reaches the
//! outside world only through the ports, and announces changes as events.

#[cfg(test)]
mod tests {
    use review_model::ViewedState;

    use super::*;
    use crate::fakes::{FakeForge, FixedClock, MemoryStore, changed_file, github_thread, sample_pr};

    fn snapshot() -> ForgeSnapshot {
        ForgeSnapshot {
            head_sha: "abc123".into(),
            has_pending_review: false,
            threads: vec![github_thread("T1", "src/a.rs")],
            files: vec![
                changed_file("src/a.rs", ViewedState::Viewed),
                changed_file("src/b.rs", ViewedState::Unviewed),
            ],
        }
    }

    fn open(forge: &FakeForge, store: &MemoryStore, clock: &FixedClock) -> ReviewSession {
        ReviewSession::open(7, Box::new(forge.clone()), Box::new(store.clone()), Box::new(clock.clone()))
            .expect("the session opens")
    }

    #[test]
    fn a_new_session_has_not_synced() {
        let session = open(&FakeForge::new(sample_pr(), snapshot()), &MemoryStore::default(), &FixedClock::at(10));
        let view = session.view();
        assert_eq!(view.sync, SyncState::Never);
        assert!(view.pr.is_none());
        assert!(view.files.is_empty());
    }

    #[test]
    fn sync_pulls_saves_and_announces() {
        let (forge, store, clock) = (FakeForge::new(sample_pr(), snapshot()), MemoryStore::default(), FixedClock::at(100));
        let mut session = open(&forge, &store, &clock);
        let events = session.subscribe();
        let view = session.sync().expect("the sync succeeds");
        assert_eq!(view.files.len(), 2);
        assert_eq!(view.thread_count, 1);
        assert_eq!(view.viewed_count, 1);
        assert_eq!(view.sync, SyncState::Synced { at: 100 });
        let saved = store.saved();
        assert_eq!(saved.session.pr.map(|pr| pr.number), Some(7));
        assert_eq!(saved.session.last_synced_at, Some(100));
        assert_eq!(saved.files.len(), 2);
        assert_eq!(events.try_recv().expect("an event was sent"), Event::Synced { view });
    }

    #[test]
    fn a_reopened_session_shows_the_saved_files_before_syncing() {
        let (forge, store, clock) = (FakeForge::new(sample_pr(), snapshot()), MemoryStore::default(), FixedClock::at(100));
        open(&forge, &store, &clock).sync().expect("the first sync succeeds");
        let view = open(&forge, &store, &clock).view();
        assert_eq!(view.files.len(), 2);
        assert_eq!(view.pr.map(|pr| pr.title), Some("Fix the widget".to_owned()));
        assert_eq!(view.sync, SyncState::Synced { at: 100 });
    }

    #[test]
    fn a_failed_sync_keeps_the_last_view_and_announces_the_failure() {
        let (forge, store, clock) = (FakeForge::new(sample_pr(), snapshot()), MemoryStore::default(), FixedClock::at(100));
        let mut session = open(&forge, &store, &clock);
        session.sync().expect("the first sync succeeds");
        let events = session.subscribe();
        forge.fail_with(Some("gh timed out after 30s"));
        clock.set(160);
        let error = session.sync().expect_err("the forge fails");
        assert!(error.to_string().contains("timed out"));
        let view = session.view();
        assert_eq!(view.files.len(), 2, "the last synced files are kept");
        assert_eq!(view.sync, SyncState::Failed { at: 160, message: "gh timed out after 30s".into() });
        assert_eq!(
            events.try_recv().expect("an event was sent"),
            Event::SyncFailed { message: "gh timed out after 30s".into() }
        );
        assert_eq!(store.saved().session.last_synced_at, Some(100), "a failure saves nothing");
    }

    #[test]
    fn github_resetting_a_viewed_file_reaches_the_view() {
        let (forge, store, clock) = (FakeForge::new(sample_pr(), snapshot()), MemoryStore::default(), FixedClock::at(1));
        let mut session = open(&forge, &store, &clock);
        session.sync().expect("the first sync succeeds");
        let mut changed = snapshot();
        changed.files[0].viewed = ViewedState::Dismissed;
        forge.set_snapshot(changed);
        let view = session.sync().expect("the second sync succeeds");
        assert_eq!(view.files[0].viewed, ViewedState::Dismissed);
        assert_eq!(view.viewed_count, 0);
    }

    #[test]
    fn record_daemon_saves_the_pid_and_worktree() {
        let store = MemoryStore::default();
        let mut session = open(&FakeForge::new(sample_pr(), snapshot()), &store, &FixedClock::at(1));
        session.record_daemon(4242, "/tmp/widgets-worktrees/pr-7").expect("it saves");
        let saved = store.saved();
        assert_eq!(saved.session.pid, Some(4242));
        assert_eq!(saved.session.worktree.as_deref(), Some("/tmp/widgets-worktrees/pr-7"));
    }

    #[test]
    fn a_dropped_subscriber_does_not_stop_the_others() {
        let mut session = open(&FakeForge::new(sample_pr(), snapshot()), &MemoryStore::default(), &FixedClock::at(1));
        drop(session.subscribe());
        let events = session.subscribe();
        session.sync().expect("the sync succeeds");
        assert!(events.try_recv().is_ok());
    }
}
```

Add to `crates/review-core/src/lib.rs`, after `mod presenter;`:

```rust
mod session;
```

and after `pub use presenter::session_view;`:

```rust
pub use session::ReviewSession;
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cargo test -p review-core --all-features`
Expected: FAIL to compile (`cannot find type ReviewSession`).

- [ ] **Step 3: Implement the session**

Insert above the `#[cfg(test)]` line in `crates/review-core/src/session.rs`:

```rust
use std::sync::mpsc::{self, Receiver, Sender};

use anyhow::Result;
use review_model::{Event, PullRequest, SessionView, SyncState, Thread};

use crate::ports::{Clock, Forge, ForgeSnapshot, ReviewStore, StoreSnapshot};
use crate::presenter::session_view;

/// One pull request's review session.
pub struct ReviewSession {
    number: u64,
    forge: Box<dyn Forge>,
    store: Box<dyn ReviewStore>,
    clock: Box<dyn Clock>,
    saved: StoreSnapshot,
    threads: Vec<Thread>,
    sync: SyncState,
    subscribers: Vec<Sender<Event>>,
}

impl ReviewSession {
    /// Opens pull request `number`'s session from what `store` saved. Nothing
    /// talks to the forge until [`sync`](Self::sync).
    pub fn open(
        number: u64,
        forge: Box<dyn Forge>,
        store: Box<dyn ReviewStore>,
        clock: Box<dyn Clock>,
    ) -> Result<Self> {
        let saved = store.load()?;
        let sync = saved
            .session
            .last_synced_at
            .map_or(SyncState::Never, |at| SyncState::Synced { at });
        Ok(Self {
            number,
            forge,
            store,
            clock,
            saved,
            threads: Vec::new(),
            sync,
            subscribers: Vec::new(),
        })
    }

    /// Records the process serving this session, so others can find it.
    pub fn record_daemon(&mut self, pid: u32, worktree: &str) -> Result<()> {
        self.saved.session.pid = Some(pid);
        self.saved.session.worktree = Some(worktree.to_owned());
        self.store.save(&self.saved)
    }

    /// A channel that receives every later [`Event`].
    pub fn subscribe(&mut self) -> Receiver<Event> {
        let (sender, receiver) = mpsc::channel();
        self.subscribers.push(sender);
        receiver
    }

    /// The current status view.
    #[must_use]
    pub fn view(&self) -> SessionView {
        session_view(
            self.saved.session.pr.as_ref(),
            &self.saved.files,
            &self.threads,
            &self.sync,
        )
    }

    /// Pulls the pull request from the forge, saves it, and announces it. A
    /// failure keeps the previous view, announces the failure, and saves nothing.
    pub fn sync(&mut self) -> Result<SessionView> {
        let now = self.clock.now();
        match self.pull() {
            Ok((pr, snapshot)) => {
                self.saved.session.pr = Some(pr);
                self.saved.session.last_synced_at = Some(now);
                self.saved.files = snapshot.files;
                self.threads = snapshot.threads;
                self.sync = SyncState::Synced { at: now };
                self.store.save(&self.saved)?;
                let view = self.view();
                self.publish(&Event::Synced { view: view.clone() });
                Ok(view)
            }
            Err(error) => {
                let message = format!("{error:#}");
                self.sync = SyncState::Failed {
                    at: now,
                    message: message.clone(),
                };
                self.publish(&Event::SyncFailed { message });
                Err(error)
            }
        }
    }

    fn pull(&self) -> Result<(PullRequest, ForgeSnapshot)> {
        let pr = self.forge.pull_request(self.number)?;
        let snapshot = self.forge.fetch(&pr)?;
        Ok((pr, snapshot))
    }

    fn publish(&mut self, event: &Event) {
        self.subscribers
            .retain(|subscriber| subscriber.send(event.clone()).is_ok());
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cargo test -p review-core --all-features`
Expected: PASS (10 tests).

- [ ] **Step 5: Gate and commit**

Run: `just check`
Expected: PASS.

```bash
git add crates/review-core
git commit -m "feat(core): add the ReviewSession facade with sync and events"
```

---

### Task 6: `review-store-fs` (HIGH-RISK: persistence format)

**Files:**
- Create: `crates/review-store-fs/Cargo.toml`, `crates/review-store-fs/src/lib.rs`

- [ ] **Step 1: Create the crate manifest**

`crates/review-store-fs/Cargo.toml`:

```toml
[package]
name = "review-store-fs"
description = "A file-backed review store: atomic JSON files per pull request."
version.workspace = true
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[dependencies]
anyhow.workspace = true
serde.workspace = true
serde_json.workspace = true
review-core.workspace = true
review-model.workspace = true

[dev-dependencies]
review-core = { workspace = true, features = ["fakes"] }
tempfile.workspace = true

[lints]
workspace = true
```

- [ ] **Step 2: Write the failing tests**

`crates/review-store-fs/src/lib.rs` (tests only for now):

```rust
//! The file-backed review store: one directory per pull request and one JSON
//! file per concern, each written atomically (temporary file, then rename) so
//! a crash leaves either the old file or the new one, never half of either.

#[cfg(test)]
mod tests {
    use std::fs;

    use review_core::contract::check_review_store;

    use super::*;

    #[test]
    fn passes_the_review_store_contract() {
        let dir = tempfile::tempdir().unwrap();
        check_review_store(&FsStore::new(dir.path().join("pr-7")));
    }

    #[test]
    fn a_missing_directory_loads_as_empty_and_creates_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let store = FsStore::new(dir.path().join("absent"));
        assert_eq!(store.load().unwrap(), StoreSnapshot::default());
        assert!(!dir.path().join("absent").exists());
    }

    #[test]
    fn a_corrupt_file_is_an_error_that_names_it() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(SESSION_FILE), "{not json").unwrap();
        let error = FsStore::new(dir.path()).load().unwrap_err();
        assert!(format!("{error:#}").contains("session.json"), "{error:#}");
    }

    #[test]
    fn save_leaves_no_temporary_files() {
        let dir = tempfile::tempdir().unwrap();
        FsStore::new(dir.path()).save(&StoreSnapshot::default()).unwrap();
        let mut names: Vec<String> = fs::read_dir(dir.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names, ["session.json", "viewed.json"]);
    }

    #[test]
    fn the_session_file_uses_camel_case_keys() {
        let dir = tempfile::tempdir().unwrap();
        let mut snapshot = StoreSnapshot::default();
        snapshot.session.last_synced_at = Some(5);
        FsStore::new(dir.path()).save(&snapshot).unwrap();
        let text = fs::read_to_string(dir.path().join(SESSION_FILE)).unwrap();
        assert!(text.contains("\"lastSyncedAt\": 5"), "{text}");
    }

    #[test]
    fn state_dir_prefers_an_absolute_xdg_state_home() {
        assert_eq!(
            state_dir(Some(Path::new("/x/state")), Path::new("/home/u"), "jpr", "octo", "widgets", 7),
            PathBuf::from("/x/state/jpr/octo/widgets/pr-7")
        );
    }

    #[test]
    fn state_dir_ignores_a_relative_xdg_state_home() {
        assert_eq!(
            state_dir(Some(Path::new("rel")), Path::new("/home/u"), "jpr", "octo", "widgets", 7),
            PathBuf::from("/home/u/.local/state/jpr/octo/widgets/pr-7")
        );
    }

    #[test]
    fn state_dir_defaults_under_home() {
        assert_eq!(
            state_dir(None, Path::new("/home/u"), "jpr", "octo", "widgets", 7),
            PathBuf::from("/home/u/.local/state/jpr/octo/widgets/pr-7")
        );
    }
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cargo test -p review-store-fs`
Expected: FAIL to compile (`cannot find type FsStore`).

- [ ] **Step 4: Implement the store**

Insert above the `#[cfg(test)]` line in `crates/review-store-fs/src/lib.rs`:

```rust
use std::fs;
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use review_core::ports::{ReviewStore, SessionRecord, StoreSnapshot};
use review_model::ChangedFile;
use serde::Serialize;
use serde::de::DeserializeOwned;

/// The daemon and what it last saw.
pub const SESSION_FILE: &str = "session.json";
/// The changed files and their viewed state.
pub const VIEWED_FILE: &str = "viewed.json";

/// Where a pull request's review state lives:
/// `<state home>/<app>/<owner>/<repo>/pr-<number>`. The state home is
/// `$XDG_STATE_HOME` when it is absolute (the XDG rule), else `~/.local/state`.
#[must_use]
pub fn state_dir(
    xdg_state_home: Option<&Path>,
    home: &Path,
    app: &str,
    owner: &str,
    repo: &str,
    number: u64,
) -> PathBuf {
    let base = xdg_state_home
        .filter(|path| path.is_absolute())
        .map_or_else(|| home.join(".local").join("state"), Path::to_path_buf);
    base.join(app)
        .join(owner)
        .join(repo)
        .join(format!("pr-{number}"))
}

/// A [`ReviewStore`] in one directory.
#[derive(Debug, Clone)]
pub struct FsStore {
    dir: PathBuf,
}

impl FsStore {
    /// A store in `dir`, created on the first save.
    #[must_use]
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    /// The directory this store writes.
    #[must_use]
    pub fn dir(&self) -> &Path {
        &self.dir
    }
}

impl ReviewStore for FsStore {
    fn load(&self) -> Result<StoreSnapshot> {
        let session: Option<SessionRecord> = read_json(&self.dir.join(SESSION_FILE))?;
        let files: Option<Vec<ChangedFile>> = read_json(&self.dir.join(VIEWED_FILE))?;
        Ok(StoreSnapshot {
            session: session.unwrap_or_default(),
            files: files.unwrap_or_default(),
        })
    }

    fn save(&self, snapshot: &StoreSnapshot) -> Result<()> {
        fs::create_dir_all(&self.dir)
            .with_context(|| format!("creating {}", self.dir.display()))?;
        write_json_atomic(&self.dir.join(SESSION_FILE), &snapshot.session)?;
        write_json_atomic(&self.dir.join(VIEWED_FILE), &snapshot.files)
    }
}

/// Reads `path` as JSON; a missing file is `None`, a corrupt one an error.
fn read_json<T: DeserializeOwned>(path: &Path) -> Result<Option<T>> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .with_context(|| format!("reading {} (fix or delete the file)", path.display())),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("reading {}", path.display())),
    }
}

/// Writes `value` as pretty JSON to a temporary file beside `path`, then
/// renames it over `path`.
fn write_json_atomic<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let temporary = path.with_extension("json.tmp");
    let mut bytes = serde_json::to_vec_pretty(value).context("encoding review state")?;
    bytes.push(b'\n');
    let mut file = fs::File::create(&temporary)
        .with_context(|| format!("writing {}", temporary.display()))?;
    file.write_all(&bytes)
        .with_context(|| format!("writing {}", temporary.display()))?;
    file.sync_all()
        .with_context(|| format!("flushing {}", temporary.display()))?;
    fs::rename(&temporary, path).with_context(|| format!("replacing {}", path.display()))
}
```

- [ ] **Step 5: Run the tests**

Run: `cargo test -p review-store-fs`
Expected: PASS (8 tests).

- [ ] **Step 6: Gate and commit**

Run: `just check`
Expected: PASS.

```bash
git add crates/review-store-fs Cargo.lock
git commit -m "feat(store): add the atomic JSON file store"
```

---

### Task 7: `review-forge-github`: running `gh` and reading a pull request

Copied from dif's `github/client.rs` with one fix: dif reported "reading GitHub's GraphQL answer" when a non-GraphQL `gh` command failed, which hid `gh`'s own error. Here the GraphQL message is used only when stdout really is a GraphQL error.

**Files:**
- Create: `crates/review-forge-github/Cargo.toml`, `crates/review-forge-github/src/{lib,gh,pr,graphql}.rs`

- [ ] **Step 1: Create the crate manifest and module skeleton**

`crates/review-forge-github/Cargo.toml`:

```toml
[package]
name = "review-forge-github"
description = "The GitHub forge adapter for the review engine, over the gh CLI."
version.workspace = true
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[dependencies]
anyhow.workspace = true
serde_json.workspace = true
review-core.workspace = true
review-model.workspace = true

[lints]
workspace = true
```

`crates/review-forge-github/src/lib.rs` (Task 8 adds `GhForge`):

```rust
//! The GitHub forge: `gh pr view` for the pull request and `gh api graphql`
//! for threads, files and viewed state. Adapted from dif's `github/` module.

mod gh;
pub mod graphql;
pub mod pr;

pub use gh::{GH_TIMEOUT, Gh};
```

`crates/review-forge-github/src/graphql.rs` (Task 8 fills in the queries and parsers):

```rust
//! The GitHub GraphQL documents the forge sends, and pure parsing of the
//! answers. Queries address the pull request by its node id.

use anyhow::{Context, Result, anyhow};
use serde_json::Value;

/// The `data` of a `gh api graphql` answer, or GitHub's error message.
pub fn parse_data_from_answer(stdout: &str) -> Result<Value> {
    let value: Value = serde_json::from_str(stdout).context("reading GitHub's GraphQL answer")?;
    if let Some(message) = value.pointer("/errors/0/message").and_then(Value::as_str) {
        return Err(anyhow!("{message}"));
    }
    value
        .get("data")
        .cloned()
        .ok_or_else(|| anyhow!("GitHub's answer had no data"))
}

/// GitHub's error message, when `stdout` is a GraphQL error answer.
#[must_use]
pub fn error_message(stdout: &str) -> Option<String> {
    let value: Value = serde_json::from_str(stdout).ok()?;
    value
        .pointer("/errors/0/message")
        .and_then(Value::as_str)
        .map(str::to_owned)
}
```

- [ ] **Step 2: Write the failing tests**

`crates/review-forge-github/src/gh.rs` (tests only for now):

```rust
//! Running `gh`, the GitHub CLI, with a timeout. `gh` is how the reviewer is
//! already logged in, so everything happens as that account. Copied from dif.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_hung_command_is_killed_and_reported_as_timed_out() {
        let child = Command::new("sleep")
            .arg("5")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let started = Instant::now();
        let error = wait_with_timeout(child, Duration::from_millis(100)).unwrap_err();
        assert!(started.elapsed() < Duration::from_secs(2));
        assert!(error.to_string().contains("timed out"), "{error}");
    }

    #[test]
    fn a_command_that_finishes_in_time_returns_its_output() {
        let child = Command::new("sh")
            .args(["-c", "echo out; echo err >&2"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let output = wait_with_timeout(child, Duration::from_secs(5)).unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "out\n");
        assert_eq!(String::from_utf8_lossy(&output.stderr), "err\n");
    }
}
```

`crates/review-forge-github/src/pr.rs` (tests only for now):

```rust
//! Reading `gh pr view`'s JSON into a pull request.

#[cfg(test)]
mod tests {
    use super::*;

    const OPEN: &str = r#"{"number":7,"title":"Fix the widget","url":"https://github.com/octo/widgets/pull/7",
        "id":"PR_7","headRefName":"fix/widget","headRefOid":"abc123","state":"OPEN",
        "baseRefName":"main","author":{"login":"alice"}}"#;

    #[test]
    fn parses_an_open_pull_request() {
        let pr = parse_pr(OPEN).unwrap();
        assert_eq!((pr.owner.as_str(), pr.repo.as_str(), pr.number), ("octo", "widgets", 7));
        assert_eq!(pr.title, "Fix the widget");
        assert_eq!(pr.node_id, "PR_7");
        assert_eq!(pr.author, "alice");
        assert_eq!((pr.head_ref.as_str(), pr.head_sha.as_str(), pr.base_ref.as_str()), ("fix/widget", "abc123", "main"));
    }

    #[test]
    fn rejects_a_merged_pull_request() {
        let error = parse_pr(&OPEN.replace("OPEN", "MERGED")).unwrap_err();
        assert_eq!(error.to_string(), "pull request #7 is not open (merged)");
    }

    #[test]
    fn reads_owner_and_repo_from_urls() {
        assert_eq!(
            owner_repo_from_url("https://github.com/octo/widgets/pull/7"),
            Some(("octo".to_owned(), "widgets".to_owned()))
        );
        assert_eq!(
            owner_repo_from_url("https://ghe.example.com/team/tool/pull/1"),
            Some(("team".to_owned(), "tool".to_owned()))
        );
        assert_eq!(owner_repo_from_url("not a url"), None);
        assert_eq!(owner_repo_from_url("https://github.com/octo"), None);
    }
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cargo test -p review-forge-github`
Expected: FAIL to compile (`cannot find function wait_with_timeout`, `parse_pr`).

- [ ] **Step 4: Implement `gh.rs`**

Insert above the `#[cfg(test)]` line in `crates/review-forge-github/src/gh.rs`:

```rust
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use serde_json::Value;

use crate::graphql;

/// How long one `gh` call may take. On a network that drops packets rather
/// than refusing connections, `gh` hangs instead of failing.
pub const GH_TIMEOUT: Duration = Duration::from_secs(30);

/// Runs `gh` in one directory.
#[derive(Debug, Clone)]
pub struct Gh {
    dir: PathBuf,
}

impl Gh {
    /// A runner whose `gh` calls start in `dir`.
    #[must_use]
    pub const fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    /// Runs `gh <args>`, writing `input` as JSON to its stdin, and returns stdout.
    pub fn run(&self, args: &[&str], input: Option<&Value>) -> Result<String> {
        let mut child = Command::new("gh")
            .args(args)
            .current_dir(&self.dir)
            .stdin(if input.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("running gh (is the GitHub CLI installed?)")?;
        if let (Some(input), Some(mut stdin)) = (input, child.stdin.take()) {
            stdin.write_all(input.to_string().as_bytes())?;
        }
        let output = wait_with_timeout(child, GH_TIMEOUT)?;
        let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
        if !output.status.success() {
            if let Some(message) = graphql::error_message(&stdout) {
                bail!("{message}");
            }
            bail!("{}", String::from_utf8_lossy(&output.stderr).trim());
        }
        Ok(stdout)
    }
}

/// Waits for `child` like [`Child::wait_with_output`], killing it once
/// `timeout` passes.
fn wait_with_timeout(mut child: Child, timeout: Duration) -> Result<Output> {
    // Drain both pipes while waiting, so a large answer cannot block `gh`.
    let stdout = child.stdout.take().map(read_in_background);
    let stderr = child.stderr.take().map(read_in_background);
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            bail!("gh timed out after {}s", timeout.as_secs_f32());
        }
        thread::sleep(Duration::from_millis(20));
    };
    let collect = |reader: Option<JoinHandle<Vec<u8>>>| {
        reader
            .and_then(|handle| handle.join().ok())
            .unwrap_or_default()
    };
    Ok(Output {
        status,
        stdout: collect(stdout),
        stderr: collect(stderr),
    })
}

fn read_in_background(mut pipe: impl Read + Send + 'static) -> JoinHandle<Vec<u8>> {
    thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = pipe.read_to_end(&mut bytes);
        bytes
    })
}
```

- [ ] **Step 5: Implement `pr.rs`**

Insert above the `#[cfg(test)]` line in `crates/review-forge-github/src/pr.rs`:

```rust
use anyhow::{Context, Result, anyhow, bail};
use review_model::PullRequest;
use serde_json::Value;

/// The fields `gh pr view --json` must report.
pub const PR_FIELDS: &str =
    "number,title,url,id,headRefName,headRefOid,state,baseRefName,author";

/// The owner and repository in a pull request URL such as
/// `https://github.com/octo/widgets/pull/7`.
#[must_use]
pub fn owner_repo_from_url(url: &str) -> Option<(String, String)> {
    let path = url.split("://").nth(1)?;
    let mut parts = path.split('/').skip(1);
    let owner = parts.next().filter(|part| !part.is_empty())?;
    let repo = parts.next().filter(|part| !part.is_empty())?;
    Some((owner.to_owned(), repo.to_owned()))
}

/// Parses `gh pr view --json PR_FIELDS`. Only an open pull request can be reviewed.
pub fn parse_pr(stdout: &str) -> Result<PullRequest> {
    let value: Value = serde_json::from_str(stdout).context("reading gh pr view output")?;
    let number = value["number"]
        .as_u64()
        .context("gh pr view did not report the number")?;
    match value["state"].as_str() {
        Some("OPEN") => {}
        Some(state) => bail!("pull request #{number} is not open ({})", state.to_lowercase()),
        None => bail!("gh pr view did not report the state"),
    }
    let text = |pointer: &str| {
        value
            .pointer(pointer)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| anyhow!("gh pr view did not report {pointer}"))
    };
    let url = text("/url")?;
    let (owner, repo) =
        owner_repo_from_url(&url).with_context(|| format!("unexpected pull request URL {url}"))?;
    Ok(PullRequest {
        owner,
        repo,
        number,
        title: text("/title")?,
        url,
        node_id: text("/id")?,
        author: text("/author/login")?,
        head_ref: text("/headRefName")?,
        head_sha: text("/headRefOid")?,
        base_ref: text("/baseRefName")?,
    })
}
```

- [ ] **Step 6: Run the tests**

Run: `cargo test -p review-forge-github`
Expected: PASS (5 tests).

- [ ] **Step 7: Gate and commit**

Run: `just check`
Expected: PASS.

```bash
git add crates/review-forge-github Cargo.lock
git commit -m "feat(forge): run gh with a timeout and read pull requests"
```

---

### Task 8: `review-forge-github`: GraphQL pulls and `GhForge`

dif's queries plus `isOutdated`, `subjectType` (file-level threads), and `additions`/`deletions`. dif dropped threads without a line; here they become file-level anchors.

**Files:**
- Modify: `crates/review-forge-github/src/graphql.rs`, `crates/review-forge-github/src/lib.rs`

- [ ] **Step 1: Write the failing tests**

Append to `crates/review-forge-github/src/graphql.rs`:

```rust
#[cfg(test)]
mod tests {
    use review_model::{AnchorKind, MessageSync, Side, ThreadState, ViewedState};
    use serde_json::json;

    use super::*;

    fn comment(id: &str, login: &str, kind: &str, state: &str) -> Value {
        json!({ "id": id, "body": "why?", "url": "u", "createdAt": "c", "updatedAt": "u",
                "state": state, "viewerDidAuthor": false, "author": { "login": login, "__typename": kind } })
    }

    #[test]
    fn parses_line_range_outdated_and_file_threads() {
        let data = json!({ "node": {
            "headRefOid": "head1",
            "reviewThreads": {
                "pageInfo": { "hasNextPage": true, "endCursor": "CUR" },
                "nodes": [
                    { "id": "T1", "isResolved": false, "isOutdated": false, "subjectType": "LINE", "path": "a.rs",
                      "line": 12, "startLine": null, "diffSide": "RIGHT", "originalLine": 12, "originalStartLine": null,
                      "comments": { "nodes": [comment("C1", "bob", "User", "SUBMITTED")] } },
                    { "id": "T2", "isResolved": true, "isOutdated": false, "subjectType": "LINE", "path": "a.rs",
                      "line": 20, "startLine": 18, "diffSide": "LEFT", "originalLine": 20, "originalStartLine": 18,
                      "comments": { "nodes": [comment("C2", "dependabot", "Bot", "PENDING")] } },
                    { "id": "T3", "isResolved": false, "isOutdated": true, "subjectType": "LINE", "path": "b.rs",
                      "line": null, "startLine": null, "diffSide": "RIGHT", "originalLine": 4, "originalStartLine": null,
                      "comments": { "nodes": [] } },
                    { "id": "T4", "isResolved": false, "isOutdated": false, "subjectType": "FILE", "path": "c.rs",
                      "line": null, "startLine": null, "diffSide": "RIGHT", "originalLine": null, "originalStartLine": null,
                      "comments": { "nodes": [] } }
                ]
            }
        } });
        let (head, threads, cursor) = parse_threads_page(&data).unwrap();
        assert_eq!(head, "head1");
        assert_eq!(cursor.as_deref(), Some("CUR"));
        let line = &threads[0];
        assert_eq!((line.anchor.kind, line.anchor.start, line.anchor.end), (AnchorKind::Line, Some(12), Some(12)));
        assert_eq!(line.messages[0].sync, Some(MessageSync::Published));
        let range = &threads[1];
        assert_eq!((range.anchor.kind, range.anchor.side, range.anchor.start, range.anchor.end), (AnchorKind::Range, Side::Left, Some(18), Some(20)));
        assert_eq!(range.state, ThreadState::Resolved);
        assert_eq!(range.messages[0].author, "dependabot[bot]");
        assert_eq!(range.messages[0].sync, Some(MessageSync::Draft));
        let outdated = &threads[2];
        assert!(outdated.outdated);
        assert_eq!((outdated.anchor.kind, outdated.anchor.end), (AnchorKind::Line, Some(4)));
        let file = &threads[3];
        assert_eq!((file.anchor.kind, file.anchor.file.as_deref(), file.anchor.start), (AnchorKind::File, Some("c.rs"), None));
    }

    #[test]
    fn parses_files_with_counts_and_viewed_state() {
        let data = json!({ "node": { "files": {
            "pageInfo": { "hasNextPage": false, "endCursor": "X" },
            "nodes": [
                { "path": "a.rs", "additions": 12, "deletions": 3, "viewerViewedState": "VIEWED" },
                { "path": "b.rs", "additions": 1, "deletions": 0, "viewerViewedState": "DISMISSED" }
            ]
        } } });
        let (files, cursor) = parse_files_page(&data).unwrap();
        assert_eq!(cursor, None);
        assert_eq!((files[0].path.as_str(), files[0].additions, files[0].deletions, files[0].viewed), ("a.rs", 12, 3, ViewedState::Viewed));
        assert_eq!(files[1].viewed, ViewedState::Dismissed);
    }

    #[test]
    fn finds_only_the_viewers_pending_review() {
        let data = json!({ "node": { "reviews": { "nodes": [
            { "id": "R1", "viewerDidAuthor": false },
            { "id": "R2", "viewerDidAuthor": true }
        ] } } });
        assert_eq!(parse_pending_review(&data).as_deref(), Some("R2"));
        assert_eq!(parse_pending_review(&json!({ "node": { "reviews": { "nodes": [] } } })), None);
    }

    #[test]
    fn reports_graphql_errors() {
        let answer = r#"{"errors":[{"message":"Could not resolve to a node"}]}"#;
        assert_eq!(parse_data_from_answer(answer).unwrap_err().to_string(), "Could not resolve to a node");
        assert_eq!(error_message(answer).as_deref(), Some("Could not resolve to a node"));
        assert_eq!(error_message("not json"), None);
        assert_eq!(parse_data_from_answer(r#"{"data":{"ok":1}}"#).unwrap()["ok"], 1);
    }
}
```

Append to `crates/review-forge-github/src/lib.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn view_args_pin_the_repository_when_known() {
        let forge = GhForge::new(PathBuf::from("."), Some("octo/widgets".into()));
        assert_eq!(
            forge.view_args(7),
            ["pr", "view", "7", "--json", pr::PR_FIELDS, "--repo", "octo/widgets"]
        );
        let local = GhForge::new(PathBuf::from("."), None);
        assert_eq!(local.view_args(7), ["pr", "view", "7", "--json", pr::PR_FIELDS]);
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cargo test -p review-forge-github`
Expected: FAIL to compile (`cannot find function parse_threads_page`, `GhForge`).

- [ ] **Step 3: Implement the queries and parsers**

In `crates/review-forge-github/src/graphql.rs`, replace the import lines with:

```rust
use anyhow::{Context, Result, anyhow};
use review_model::{
    Anchor, AnchorKind, ChangedFile, Message, MessageSync, Origin, Side, Thread, ThreadState,
    ViewedState,
};
use serde_json::Value;
```

and insert after the imports (above `parse_data_from_answer`):

```rust
/// The reviewer's pending review on a pull request, if any.
pub const PENDING_REVIEW: &str = r"query($pr: ID!) {
  node(id: $pr) { ... on PullRequest {
    reviews(states: PENDING, first: 20) { nodes { id viewerDidAuthor } }
  } }
}";

/// One page of review threads (with their comments) and the head commit.
pub const THREADS: &str = r"query($pr: ID!, $after: String) {
  node(id: $pr) { ... on PullRequest {
    headRefOid
    reviewThreads(first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        id isResolved isOutdated subjectType path line startLine diffSide originalLine originalStartLine
        comments(first: 100) {
          nodes { id body url createdAt updatedAt state viewerDidAuthor author { login __typename } }
        }
      }
    }
  } }
}";

/// One page of the pull request's files with counts and the viewer's viewed state.
pub const FILES: &str = r"query($pr: ID!, $after: String) {
  node(id: $pr) { ... on PullRequest {
    files(first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { path additions deletions viewerViewedState }
    }
  } }
}";

/// One page of `THREADS`: the head commit, the threads, and the next cursor.
pub type ThreadsPage = (String, Vec<Thread>, Option<String>);

/// One page of `FILES`: the files and the next cursor.
pub type FilesPage = (Vec<ChangedFile>, Option<String>);
```

and append, above the `#[cfg(test)]` line:

```rust
/// The viewer's pending review id among `PENDING_REVIEW`'s nodes.
#[must_use]
pub fn parse_pending_review(data: &Value) -> Option<String> {
    data.pointer("/node/reviews/nodes")?
        .as_array()?
        .iter()
        .find(|review| review["viewerDidAuthor"] == Value::Bool(true))
        .and_then(|review| review["id"].as_str())
        .map(str::to_owned)
}

/// Parses one page of `THREADS`.
pub fn parse_threads_page(data: &Value) -> Result<ThreadsPage> {
    let pr = data.get("node").context("the pull request was not found")?;
    let head = pr["headRefOid"].as_str().unwrap_or_default().to_owned();
    let threads = pr
        .pointer("/reviewThreads/nodes")
        .and_then(Value::as_array)
        .context("GitHub returned no review threads")?
        .iter()
        .filter_map(parse_thread)
        .collect();
    Ok((head, threads, next_cursor(&pr["reviewThreads"])))
}

/// Parses one page of `FILES`.
pub fn parse_files_page(data: &Value) -> Result<FilesPage> {
    let files = data
        .pointer("/node/files")
        .context("GitHub returned no pull request files")?;
    let parsed = files["nodes"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .filter_map(|file| {
            Some(ChangedFile {
                path: file["path"].as_str()?.to_owned(),
                additions: file["additions"].as_u64().unwrap_or(0),
                deletions: file["deletions"].as_u64().unwrap_or(0),
                viewed: ViewedState::parse(file["viewerViewedState"].as_str()?)?,
            })
        })
        .collect();
    Ok((parsed, next_cursor(files)))
}

fn parse_thread(node: &Value) -> Option<Thread> {
    let path = node["path"].as_str()?.to_owned();
    let side = if node["diffSide"].as_str() == Some("LEFT") {
        Side::Left
    } else {
        Side::Right
    };
    let is_file = node["subjectType"].as_str() == Some("FILE");
    let line = node["line"]
        .as_u64()
        .or_else(|| node["originalLine"].as_u64());
    let anchor = match (is_file, line) {
        (false, Some(end)) => {
            let start = node["startLine"]
                .as_u64()
                .or_else(|| node["originalStartLine"].as_u64())
                .filter(|start| *start != end);
            Anchor {
                file: Some(path),
                kind: if start.is_some() {
                    AnchorKind::Range
                } else {
                    AnchorKind::Line
                },
                side,
                start: Some(start.unwrap_or(end)),
                end: Some(end),
                commit: None,
                snapshot: None,
            }
        }
        _ => Anchor {
            file: Some(path),
            kind: AnchorKind::File,
            side,
            start: None,
            end: None,
            commit: None,
            snapshot: None,
        },
    };
    let comments = node.pointer("/comments/nodes")?.as_array()?;
    Some(Thread {
        id: node["id"].as_str()?.to_owned(),
        origin: Origin::Github,
        anchor,
        state: if node["isResolved"].as_bool().unwrap_or(false) {
            ThreadState::Resolved
        } else {
            ThreadState::Open
        },
        outdated: node["isOutdated"].as_bool().unwrap_or(false),
        messages: comments.iter().filter_map(parse_comment).collect(),
    })
}

fn parse_comment(node: &Value) -> Option<Message> {
    let login = node
        .pointer("/author/login")
        .and_then(Value::as_str)
        .unwrap_or("ghost");
    let is_bot = node.pointer("/author/__typename").and_then(Value::as_str) == Some("Bot");
    Some(Message {
        id: node["id"].as_str()?.to_owned(),
        author: if is_bot && !login.ends_with("[bot]") {
            format!("{login}[bot]")
        } else {
            login.to_owned()
        },
        body: node["body"].as_str().unwrap_or_default().to_owned(),
        created: node["createdAt"].as_str().unwrap_or_default().to_owned(),
        updated: node["updatedAt"].as_str().unwrap_or_default().to_owned(),
        sync: Some(if node["state"].as_str() == Some("PENDING") {
            MessageSync::Draft
        } else {
            MessageSync::Published
        }),
    })
}

fn next_cursor(connection: &Value) -> Option<String> {
    if connection.pointer("/pageInfo/hasNextPage") != Some(&Value::Bool(true)) {
        return None;
    }
    connection
        .pointer("/pageInfo/endCursor")?
        .as_str()
        .map(str::to_owned)
}
```

- [ ] **Step 4: Implement `GhForge`**

Replace the body of `crates/review-forge-github/src/lib.rs` above the `#[cfg(test)]` line with:

```rust
//! The GitHub forge: `gh pr view` for the pull request and `gh api graphql`
//! for threads, files and viewed state. Adapted from dif's `github/` module.

mod gh;
pub mod graphql;
pub mod pr;

use std::path::PathBuf;

use anyhow::Result;
use review_core::ports::{Forge, ForgeSnapshot};
use review_model::PullRequest;
use serde_json::{Value, json};

pub use gh::{GH_TIMEOUT, Gh};

/// [`Forge`] over the GitHub CLI.
#[derive(Debug, Clone)]
pub struct GhForge {
    gh: Gh,
    repo: Option<String>,
}

impl GhForge {
    /// Runs `gh` in `dir`. `repo` (`owner/name`) pins the repository
    /// `gh pr view` looks in; without it `gh` infers it from `dir`'s remotes.
    #[must_use]
    pub const fn new(dir: PathBuf, repo: Option<String>) -> Self {
        Self {
            gh: Gh::new(dir),
            repo,
        }
    }

    /// The `gh pr view` arguments for pull request `number`.
    #[must_use]
    pub fn view_args(&self, number: u64) -> Vec<String> {
        let mut args = vec![
            "pr".to_owned(),
            "view".to_owned(),
            number.to_string(),
            "--json".to_owned(),
            pr::PR_FIELDS.to_owned(),
        ];
        if let Some(repo) = &self.repo {
            args.push("--repo".to_owned());
            args.push(repo.clone());
        }
        args
    }

    fn graphql(&self, query: &str, variables: &Value) -> Result<Value> {
        let body = json!({ "query": query, "variables": variables });
        graphql::parse_data_from_answer(
            &self
                .gh
                .run(&["api", "graphql", "--input", "-"], Some(&body))?,
        )
    }

    fn paged<T>(
        &self,
        query: &str,
        pr: &PullRequest,
        mut page: impl FnMut(&Value) -> Result<(Vec<T>, Option<String>)>,
    ) -> Result<Vec<T>> {
        let mut items = Vec::new();
        let mut after: Option<String> = None;
        loop {
            let data = self.graphql(query, &json!({ "pr": pr.node_id, "after": after }))?;
            let (batch, next) = page(&data)?;
            items.extend(batch);
            match next {
                Some(cursor) => after = Some(cursor),
                None => return Ok(items),
            }
        }
    }
}

impl Forge for GhForge {
    fn pull_request(&self, number: u64) -> Result<PullRequest> {
        let args = self.view_args(number);
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        pr::parse_pr(&self.gh.run(&args, None)?)
    }

    fn fetch(&self, pr: &PullRequest) -> Result<ForgeSnapshot> {
        let mut head_sha = pr.head_sha.clone();
        let threads = self.paged(graphql::THREADS, pr, |data| {
            let (head, threads, next) = graphql::parse_threads_page(data)?;
            if !head.is_empty() {
                head_sha = head;
            }
            Ok((threads, next))
        })?;
        let files = self.paged(graphql::FILES, pr, graphql::parse_files_page)?;
        let pending = graphql::parse_pending_review(
            &self.graphql(graphql::PENDING_REVIEW, &json!({ "pr": pr.node_id }))?,
        );
        Ok(ForgeSnapshot {
            head_sha,
            has_pending_review: pending.is_some(),
            threads,
            files,
        })
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `cargo test -p review-forge-github`
Expected: PASS (10 tests).

- [ ] **Step 6: Gate and commit**

Run: `just check`
Expected: PASS.

```bash
git add crates/review-forge-github
git commit -m "feat(forge): pull threads, files and viewed state through GraphQL"
```

`GhForge` itself is exercised against GitHub in Task 17. Its parsing is covered here.

---

### Task 9: `review-workspace-git`

**Files:**
- Create: `crates/review-workspace-git/Cargo.toml`, `crates/review-workspace-git/src/lib.rs`

- [ ] **Step 1: Create the crate manifest**

`crates/review-workspace-git/Cargo.toml`:

```toml
[package]
name = "review-workspace-git"
description = "Checks a pull request out into its own git worktree."
version.workspace = true
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[dependencies]
anyhow.workspace = true

[dev-dependencies]
tempfile.workspace = true

[lints]
workspace = true
```

- [ ] **Step 2: Write the failing tests**

`crates/review-workspace-git/src/lib.rs` (tests only for now):

```rust
//! Checking a pull request out into its own worktree. Generic: it knows git
//! and `gh`, and nothing about any editor.

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    fn git(dir: &Path, args: &[&str]) {
        let status = Command::new("git")
            .args(args)
            .current_dir(dir)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@example.com")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@example.com")
            .status()
            .unwrap();
        assert!(status.success(), "git {args:?}");
    }

    /// A temporary directory holding a one-commit repository named `widgets`.
    fn repo() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("widgets");
        fs::create_dir(&root).unwrap();
        git(&root, &["init", "-q", "-b", "main"]);
        fs::write(root.join("a.txt"), "a\n").unwrap();
        git(&root, &["add", "."]);
        git(&root, &["commit", "-q", "-m", "init"]);
        dir
    }

    #[test]
    fn render_custom_substitutes_the_number() {
        assert_eq!(render_custom("wt pr {n}", 42), "wt pr 42");
    }

    #[test]
    fn the_default_path_sits_beside_the_repository() {
        assert_eq!(
            default_worktree_path(Path::new("/src/widgets"), 7),
            PathBuf::from("/src/widgets-worktrees/pr-7")
        );
    }

    #[test]
    fn last_path_line_skips_trailing_blank_lines() {
        assert_eq!(last_path_line("noise\n/tmp/wt\n\n"), Some(PathBuf::from("/tmp/wt")));
        assert_eq!(last_path_line("\n \n"), None);
    }

    #[test]
    fn main_repo_root_finds_the_main_checkout_from_a_worktree() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let linked = dir.path().join("linked");
        git(&root, &["worktree", "add", "-q", "--detach", linked.to_str().unwrap()]);
        let found = main_repo_root(&linked).unwrap();
        assert_eq!(found.canonicalize().unwrap(), root.canonicalize().unwrap());
    }

    #[test]
    fn main_repo_root_outside_git_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let error = main_repo_root(dir.path()).unwrap_err();
        assert!(format!("{error:#}").contains("git checkout"), "{error:#}");
    }

    #[test]
    fn a_custom_command_returns_the_directory_it_prints() {
        let dir = tempfile::tempdir().unwrap();
        let base = dir.path().display();
        let template = format!("mkdir -p '{base}/pr-{{n}}' && echo creating >&2 && echo '{base}/pr-{{n}}'");
        let path = checkout_pr(dir.path(), 9, &WorktreeCommand::Custom(template)).unwrap();
        assert_eq!(path, dir.path().join("pr-9").canonicalize().unwrap());
    }

    #[test]
    fn a_failing_custom_command_reports_its_stderr() {
        let dir = tempfile::tempdir().unwrap();
        let error = checkout_pr(dir.path(), 9, &WorktreeCommand::Custom("echo nope >&2; exit 3".into())).unwrap_err();
        assert!(format!("{error:#}").contains("nope"), "{error:#}");
    }

    #[test]
    fn a_custom_command_must_print_a_directory() {
        let dir = tempfile::tempdir().unwrap();
        let error = checkout_pr(dir.path(), 9, &WorktreeCommand::Custom("echo /definitely/not/here".into())).unwrap_err();
        assert!(format!("{error:#}").contains("not a directory"), "{error:#}");
    }

    #[test]
    fn the_default_checkout_reuses_an_existing_worktree() {
        let dir = repo();
        let root = dir.path().join("widgets");
        let existing = dir.path().join("widgets-worktrees").join("pr-5");
        fs::create_dir_all(&existing).unwrap();
        let path = checkout_pr(&root, 5, &WorktreeCommand::Default).unwrap();
        assert_eq!(path.canonicalize().unwrap(), existing.canonicalize().unwrap());
    }
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cargo test -p review-workspace-git`
Expected: FAIL to compile (`cannot find function render_custom`, ...).

- [ ] **Step 4: Implement the checkout**

Insert above the `#[cfg(test)]` line in `crates/review-workspace-git/src/lib.rs`:

```rust
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};

/// How to create a pull request's worktree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorktreeCommand {
    /// `git worktree add` beside the repository, then `gh pr checkout`.
    Default,
    /// A shell command that creates the worktree and prints its path as its
    /// last line of output. `{n}` is replaced with the pull request number.
    Custom(String),
}

/// `template` with `{n}` replaced by `number`.
#[must_use]
pub fn render_custom(template: &str, number: u64) -> String {
    template.replace("{n}", &number.to_string())
}

/// Where the default checkout puts pull request `number`:
/// `<parent>/<repo>-worktrees/pr-<number>`.
#[must_use]
pub fn default_worktree_path(main_root: &Path, number: u64) -> PathBuf {
    let name = main_root.file_name().map_or_else(
        || "repo".to_owned(),
        |name| name.to_string_lossy().into_owned(),
    );
    main_root
        .parent()
        .unwrap_or(main_root)
        .join(format!("{name}-worktrees"))
        .join(format!("pr-{number}"))
}

/// The last non-blank line of `stdout`, as a path.
#[must_use]
pub fn last_path_line(stdout: &str) -> Option<PathBuf> {
    stdout
        .lines()
        .map(str::trim)
        .rfind(|line| !line.is_empty())
        .map(PathBuf::from)
}

/// The main checkout's root, even when `dir` is inside a linked worktree.
pub fn main_repo_root(dir: &Path) -> Result<PathBuf> {
    let common = run(
        "git",
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
        dir,
    )
    .context("finding the repository (is this a git checkout?)")?;
    let common = PathBuf::from(common.trim());
    if common.file_name().is_some_and(|name| name == ".git") {
        return common
            .parent()
            .map(Path::to_path_buf)
            .context("the git directory has no parent");
    }
    bail!(
        "{} is a bare repository; open the pull request from a checkout",
        common.display()
    )
}

/// Checks pull request `number` out into a worktree and returns its path. An
/// existing default worktree is reused as it is.
pub fn checkout_pr(dir: &Path, number: u64, command: &WorktreeCommand) -> Result<PathBuf> {
    match command {
        WorktreeCommand::Custom(template) => checkout_custom(dir, &render_custom(template, number)),
        WorktreeCommand::Default => checkout_default(dir, number),
    }
}

fn checkout_custom(dir: &Path, command: &str) -> Result<PathBuf> {
    let stdout = run("sh", &["-c", command], dir)
        .with_context(|| format!("running the worktree command `{command}`"))?;
    let path = last_path_line(&stdout)
        .with_context(|| format!("the worktree command `{command}` printed no path"))?;
    let path = if path.is_absolute() { path } else { dir.join(path) };
    if !path.is_dir() {
        bail!(
            "the worktree command `{command}` printed {}, which is not a directory",
            path.display()
        );
    }
    path.canonicalize()
        .with_context(|| format!("resolving {}", path.display()))
}

fn checkout_default(dir: &Path, number: u64) -> Result<PathBuf> {
    let main = main_repo_root(dir)?;
    let path = default_worktree_path(&main, number);
    if path.is_dir() {
        return Ok(path);
    }
    let path_text = path.to_string_lossy().into_owned();
    run("git", &["worktree", "add", "--detach", &path_text], &main)
        .context("creating the worktree")?;
    let branch = format!("pr-{number}");
    if let Err(error) = run(
        "gh",
        &["pr", "checkout", &number.to_string(), "-b", &branch],
        &path,
    ) {
        // Remove the empty worktree we just made, so a retry starts clean.
        let _ = run("git", &["worktree", "remove", "--force", &path_text], &main);
        return Err(error.context(format!("checking out pull request #{number}")));
    }
    Ok(path)
}

/// Runs `program` in `dir` and returns its stdout, or fails with its stderr.
fn run(program: &str, args: &[&str], dir: &Path) -> Result<String> {
    let output = Command::new(program)
        .args(args)
        .current_dir(dir)
        .output()
        .with_context(|| format!("running {program}"))?;
    if output.status.success() {
        return Ok(String::from_utf8_lossy(&output.stdout).into_owned());
    }
    bail!(
        "{program} failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    )
}
```

- [ ] **Step 5: Run the tests**

Run: `cargo test -p review-workspace-git`
Expected: PASS (9 tests).

- [ ] **Step 6: Gate and commit**

Run: `just check`
Expected: PASS.

```bash
git add crates/review-workspace-git Cargo.lock
git commit -m "feat(workspace): check pull requests out into worktrees"
```

---

### Task 10: `review-rpc` protocol

**Files:**
- Create: `crates/review-rpc/Cargo.toml`, `crates/review-rpc/src/{lib,protocol}.rs`

- [ ] **Step 1: Create the crate manifest and root**

`crates/review-rpc/Cargo.toml`:

```toml
[package]
name = "review-rpc"
description = "JSON-RPC access to a review session over any line-based transport."
version.workspace = true
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[dependencies]
anyhow.workspace = true
serde.workspace = true
serde_json.workspace = true
review-core.workspace = true
review-model.workspace = true

[dev-dependencies]
review-core = { workspace = true, features = ["fakes"] }

[lints]
workspace = true
```

`crates/review-rpc/src/lib.rs` (Task 11 adds the server):

```rust
//! JSON-RPC access to a review session for out-of-process frontends.
//! Frontend-neutral: any client that speaks docs/protocol.md can drive it.

pub mod protocol;

pub use protocol::{PROTOCOL_VERSION, Request, RpcError};
```

- [ ] **Step 2: Write the failing tests**

`crates/review-rpc/src/protocol.rs` (tests only for now):

```rust
//! The wire format: newline-delimited JSON-RPC 2.0. See docs/protocol.md.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_request_with_and_without_params() {
        let request = parse_request(r#"{"jsonrpc":"2.0","id":3,"method":"sync","params":{"x":1}}"#).unwrap();
        assert_eq!(request, Request { id: json!(3), method: "sync".into(), params: json!({ "x": 1 }) });
        let bare = parse_request(r#"{"id":"a","method":"snapshot"}"#).unwrap();
        assert_eq!(bare.params, Value::Null);
    }

    #[test]
    fn invalid_json_is_a_parse_error_with_a_null_id() {
        let (id, error) = parse_request("{oops").unwrap_err();
        assert_eq!(id, Value::Null);
        assert_eq!(error.code, RpcError::PARSE_ERROR);
    }

    #[test]
    fn a_request_needs_a_method_and_an_id() {
        let (id, error) = parse_request(r#"{"id":4}"#).unwrap_err();
        assert_eq!((id, error.code), (json!(4), RpcError::INVALID_REQUEST));
        let (id, error) = parse_request(r#"{"method":"sync"}"#).unwrap_err();
        assert_eq!((id, error.code), (Value::Null, RpcError::INVALID_REQUEST));
    }

    #[test]
    fn builds_responses_and_notifications() {
        assert_eq!(success(&json!(1), json!(true)), json!({ "jsonrpc": "2.0", "id": 1, "result": true }));
        assert_eq!(
            failure(&json!(2), &RpcError::new(RpcError::METHOD_NOT_FOUND, "nope")),
            json!({ "jsonrpc": "2.0", "id": 2, "error": { "code": -32601, "message": "nope" } })
        );
        assert_eq!(
            notification("event", json!({ "type": "synced" })),
            json!({ "jsonrpc": "2.0", "method": "event", "params": { "type": "synced" } })
        );
    }
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cargo test -p review-rpc`
Expected: FAIL to compile (`cannot find function parse_request`).

- [ ] **Step 4: Implement the protocol**

Insert above the `#[cfg(test)]` line in `crates/review-rpc/src/protocol.rs`:

```rust
use serde_json::{Value, json};

/// Bumped whenever a request, response or event changes shape.
pub const PROTOCOL_VERSION: u32 = 1;

/// A request from the client.
#[derive(Debug, Clone, PartialEq)]
pub struct Request {
    pub id: Value,
    pub method: String,
    /// `null` when the request had none.
    pub params: Value,
}

/// A JSON-RPC error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

impl RpcError {
    pub const PARSE_ERROR: i64 = -32700;
    pub const INVALID_REQUEST: i64 = -32600;
    pub const METHOD_NOT_FOUND: i64 = -32601;
    pub const INVALID_PARAMS: i64 = -32602;
    /// The request was valid, but the review engine could not do it.
    pub const ENGINE_ERROR: i64 = -32000;

    /// An error with `code` and `message`.
    #[must_use]
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

/// Parses one line into a request, or the id and error to answer with.
pub fn parse_request(line: &str) -> Result<Request, (Value, RpcError)> {
    let value: Value = serde_json::from_str(line).map_err(|error| {
        (
            Value::Null,
            RpcError::new(RpcError::PARSE_ERROR, format!("invalid JSON: {error}")),
        )
    })?;
    let id = value.get("id").cloned().unwrap_or(Value::Null);
    let Some(method) = value.get("method").and_then(Value::as_str) else {
        return Err((
            id,
            RpcError::new(RpcError::INVALID_REQUEST, "a request needs a string \"method\""),
        ));
    };
    if id.is_null() {
        return Err((
            Value::Null,
            RpcError::new(RpcError::INVALID_REQUEST, "a request needs an \"id\""),
        ));
    }
    Ok(Request {
        id,
        method: method.to_owned(),
        params: value.get("params").cloned().unwrap_or(Value::Null),
    })
}

/// A success response.
#[must_use]
pub fn success(id: &Value, result: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": result })
}

/// An error response.
#[must_use]
pub fn failure(id: &Value, error: &RpcError) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": error.code, "message": error.message } })
}

/// A notification (no id, no response expected).
#[must_use]
pub fn notification(method: &str, params: Value) -> Value {
    json!({ "jsonrpc": "2.0", "method": method, "params": params })
}
```

- [ ] **Step 5: Run the tests**

Run: `cargo test -p review-rpc`
Expected: PASS (4 tests).

- [ ] **Step 6: Gate and commit**

Run: `just check`
Expected: PASS.

```bash
git add crates/review-rpc Cargo.lock
git commit -m "feat(rpc): add the JSON-RPC wire format"
```

---

### Task 11: `review-rpc` server

**Files:**
- Create: `crates/review-rpc/src/server.rs`, `crates/review-rpc/tests/serve.rs`
- Modify: `crates/review-rpc/src/lib.rs`

- [ ] **Step 1: Write the failing tests**

`crates/review-rpc/tests/serve.rs`:

```rust
//! The server end to end, over in-memory streams and the fake ports.

use std::io::{BufReader, Cursor, Read};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use review_core::ReviewSession;
use review_core::fakes::{FakeForge, FixedClock, MemoryStore, changed_file, github_thread, sample_pr};
use review_core::ports::ForgeSnapshot;
use review_model::ViewedState;
use review_rpc::{ServeOptions, serve};
use serde_json::Value;

fn forge() -> FakeForge {
    FakeForge::new(
        sample_pr(),
        ForgeSnapshot {
            head_sha: "abc123".into(),
            has_pending_review: false,
            threads: vec![github_thread("T1", "src/a.rs")],
            files: vec![changed_file("src/a.rs", ViewedState::Viewed)],
        },
    )
}

fn session(forge: &FakeForge) -> Arc<Mutex<ReviewSession>> {
    let session = ReviewSession::open(
        7,
        Box::new(forge.clone()),
        Box::new(MemoryStore::default()),
        Box::new(FixedClock::at(100)),
    )
    .unwrap();
    Arc::new(Mutex::new(session))
}

fn options(poll_every: Option<Duration>) -> ServeOptions {
    ServeOptions {
        server_version: "9.9.9".into(),
        poll_every,
    }
}

fn request(id: u64, method: &str) -> String {
    format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"{method}\"}}\n")
}

fn messages(output: &Mutex<Vec<u8>>) -> Vec<Value> {
    let bytes = output.lock().unwrap().clone();
    String::from_utf8(bytes)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// Serves `input` and returns what was written, waiting up to a second for
/// `expected` messages because events arrive from another thread.
fn run(input: &str, forge: &FakeForge, expected: usize) -> Vec<Value> {
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    serve(Cursor::new(input.to_owned()), &output, &session(forge), &options(None)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        let written = messages(&output);
        if written.len() >= expected || Instant::now() > deadline {
            return written;
        }
        thread::sleep(Duration::from_millis(10));
    }
}

fn response(messages: &[Value], id: u64) -> &Value {
    messages
        .iter()
        .find(|message| message["id"] == id)
        .unwrap_or_else(|| panic!("no response {id} in {messages:?}"))
}

fn event(messages: &[Value]) -> &Value {
    messages
        .iter()
        .find(|message| message["method"] == "event")
        .unwrap_or_else(|| panic!("no event in {messages:?}"))
}

#[test]
fn initialize_reports_the_protocol_and_server_versions() {
    let written = run(&request(1, "initialize"), &forge(), 1);
    let result = &response(&written, 1)["result"];
    assert_eq!(result["protocolVersion"], 1);
    assert_eq!(result["version"], "9.9.9");
}

#[test]
fn snapshot_before_any_sync_is_empty() {
    let written = run(&request(1, "snapshot"), &forge(), 1);
    let result = &response(&written, 1)["result"];
    assert_eq!(result["sync"]["state"], "never");
    assert_eq!(result["files"], serde_json::json!([]));
}

#[test]
fn sync_answers_with_the_view_and_announces_it() {
    let written = run(&request(1, "sync"), &forge(), 2);
    let result = &response(&written, 1)["result"];
    assert_eq!(result["files"][0]["path"], "src/a.rs");
    assert_eq!(result["files"][0]["threads"], 1);
    assert_eq!(result["sync"], serde_json::json!({ "state": "synced", "at": 100 }));
    assert_eq!(event(&written)["params"]["type"], "synced");
}

#[test]
fn a_failed_sync_is_an_engine_error_and_an_event() {
    let forge = forge();
    forge.fail_with(Some("offline"));
    let written = run(&request(1, "sync"), &forge, 2);
    let error = &response(&written, 1)["error"];
    assert_eq!(error["code"], -32000);
    assert!(error["message"].as_str().unwrap().contains("offline"));
    assert_eq!(event(&written)["params"]["type"], "syncFailed");
}

#[test]
fn unknown_methods_and_bad_json_get_error_responses() {
    let written = run(&format!("{}{{oops\n", request(1, "frobnicate")), &forge(), 2);
    assert_eq!(response(&written, 1)["error"]["code"], -32601);
    let parse_error = written.iter().find(|message| message["id"].is_null()).unwrap();
    assert_eq!(parse_error["error"]["code"], -32700);
}

#[test]
fn shutdown_answers_and_stops_reading() {
    let written = run(&format!("{}{}", request(1, "shutdown"), request(2, "initialize")), &forge(), 2);
    assert_eq!(response(&written, 1)["result"], Value::Null);
    assert!(written.iter().all(|message| message["id"] != 2), "{written:?}");
}

/// A reader that ends after a while, to keep the server running.
struct EndsLater {
    at: Instant,
}

impl Read for EndsLater {
    fn read(&mut self, _buffer: &mut [u8]) -> std::io::Result<usize> {
        let now = Instant::now();
        if now < self.at {
            thread::sleep(self.at - now);
        }
        Ok(0)
    }
}

#[test]
fn the_poller_syncs_in_the_background() {
    let forge = forge();
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    let reader = BufReader::new(EndsLater { at: Instant::now() + Duration::from_millis(300) });
    serve(reader, &output, &session(&forge), &options(Some(Duration::from_millis(20)))).unwrap();
    assert!(forge.fetches() >= 2, "fetched {} times", forge.fetches());
}
```

In `crates/review-rpc/src/lib.rs`, add after `pub mod protocol;`:

```rust
mod server;
```

and after the `pub use protocol::...` line:

```rust
pub use server::{ServeOptions, handle, serve};
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cargo test -p review-rpc`
Expected: FAIL to compile (file `src/server.rs` not found).

- [ ] **Step 3: Implement the server**

`crates/review-rpc/src/server.rs`:

```rust
//! Serving a `ReviewSession` over any line-based transport: stdio today, a
//! Unix socket for agent commands later. Responses and event notifications
//! share one writer, one JSON message per line.

use std::io::{BufRead, Write};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use review_core::ReviewSession;
use serde::Serialize;
use serde_json::{Value, json};

use crate::protocol::{
    PROTOCOL_VERSION, Request, RpcError, failure, notification, parse_request, success,
};

/// How a server runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServeOptions {
    /// The engine's version, reported by `initialize`.
    pub server_version: String,
    /// How often to sync in the background; `None` syncs only on request.
    pub poll_every: Option<Duration>,
}

/// Answers one request. Routing only: every rule lives in the session.
pub fn handle(
    session: &Mutex<ReviewSession>,
    request: &Request,
    server_version: &str,
) -> Result<Value, RpcError> {
    match request.method.as_str() {
        "initialize" => Ok(json!({ "protocolVersion": PROTOCOL_VERSION, "version": server_version })),
        "snapshot" => to_value(&lock(session)?.view()),
        "sync" => {
            let view = lock(session)?
                .sync()
                .map_err(|error| RpcError::new(RpcError::ENGINE_ERROR, format!("{error:#}")))?;
            to_value(&view)
        }
        "shutdown" => Ok(Value::Null),
        other => Err(RpcError::new(
            RpcError::METHOD_NOT_FOUND,
            format!("unknown method {other:?}"),
        )),
    }
}

/// Serves requests read from `reader` until it ends or a `shutdown` request
/// arrives, writing responses and `event` notifications to `writer`.
pub fn serve<R: BufRead, W: Write + Send + 'static>(
    reader: R,
    writer: &Arc<Mutex<W>>,
    session: &Arc<Mutex<ReviewSession>>,
    options: &ServeOptions,
) -> Result<()> {
    forward_events(session, Arc::clone(writer))?;
    let (stop, stopped) = mpsc::channel::<()>();
    if let Some(every) = options.poll_every {
        let session = Arc::clone(session);
        thread::spawn(move || {
            loop {
                match stopped.recv_timeout(every) {
                    Err(RecvTimeoutError::Timeout) => {
                        // A failure is announced as an event by the session.
                        if let Ok(mut session) = session.lock() {
                            let _ = session.sync();
                        }
                    }
                    Ok(()) | Err(RecvTimeoutError::Disconnected) => break,
                }
            }
        });
    }
    for line in reader.lines() {
        let line = line.context("reading a request")?;
        if line.trim().is_empty() {
            continue;
        }
        let (reply, done) = match parse_request(&line) {
            Ok(request) => {
                let reply = match handle(session, &request, &options.server_version) {
                    Ok(result) => success(&request.id, result),
                    Err(error) => failure(&request.id, &error),
                };
                (reply, request.method == "shutdown")
            }
            Err((id, error)) => (failure(&id, &error), false),
        };
        write_line(writer, &reply)?;
        if done {
            break;
        }
    }
    drop(stop);
    Ok(())
}

/// Writes every session event to `writer` as an `event` notification.
fn forward_events<W: Write + Send + 'static>(
    session: &Mutex<ReviewSession>,
    writer: Arc<Mutex<W>>,
) -> Result<()> {
    let events = session
        .lock()
        .map_err(|_| anyhow!("the review session lock is poisoned"))?
        .subscribe();
    thread::spawn(move || {
        for event in events {
            let Ok(params) = serde_json::to_value(&event) else {
                continue;
            };
            if write_line(&writer, &notification("event", params)).is_err() {
                break;
            }
        }
    });
    Ok(())
}

fn write_line<W: Write>(writer: &Mutex<W>, message: &Value) -> Result<()> {
    let mut writer = writer
        .lock()
        .map_err(|_| anyhow!("the output lock is poisoned"))?;
    serde_json::to_writer(&mut *writer, message).context("writing a message")?;
    writer.write_all(b"\n").context("writing a message")?;
    writer.flush().context("flushing a message")
}

fn lock(session: &Mutex<ReviewSession>) -> Result<MutexGuard<'_, ReviewSession>, RpcError> {
    session
        .lock()
        .map_err(|_| RpcError::new(RpcError::ENGINE_ERROR, "the review session lock is poisoned"))
}

fn to_value<T: Serialize>(value: &T) -> Result<Value, RpcError> {
    serde_json::to_value(value).map_err(|error| {
        RpcError::new(RpcError::ENGINE_ERROR, format!("encoding the result: {error}"))
    })
}
```

- [ ] **Step 4: Run the tests**

Run: `cargo test -p review-rpc`
Expected: PASS (4 unit tests, 7 integration tests).

- [ ] **Step 5: Gate and commit**

Run: `just check`
Expected: PASS.

```bash
git add crates/review-rpc
git commit -m "feat(rpc): serve a review session with background sync and events"
```

---

### Task 12: `jpr-review` commands and the dependency rule

Replaces the scaffold's example commands (`greet`, `info`, `config`) with `checkout`, `serve` and `state-path`, and drops TOML. `prompt.rs` and `theme.rs` stay: `checkout` and `state-path` ask for a missing value on a terminal; `serve` takes only flags because its stdin is the protocol.

**Files:**
- Delete: `crates/jpr-review/src/config.rs`, `crates/jpr-review/src/commands/{greet,info}.rs`, `crates/jpr-review/src/commands/config/`, `crates/jpr-review/tests/public_api.rs`
- Replace: `crates/jpr-review/Cargo.toml`, `crates/jpr-review/src/{lib,cli}.rs`, `crates/jpr-review/src/commands/mod.rs`
- Create: `crates/jpr-review/src/commands/{checkout,serve,state_path}.rs`, `crates/jpr-review/tests/dependency_rule.rs`

- [ ] **Step 1: Remove the example commands**

```bash
git rm -q -r crates/jpr-review/src/config.rs crates/jpr-review/src/commands/greet.rs \
  crates/jpr-review/src/commands/info.rs crates/jpr-review/src/commands/config \
  crates/jpr-review/tests/public_api.rs
```

- [ ] **Step 2: Replace `crates/jpr-review/Cargo.toml`**

```toml
[package]
name = "jpr-review"
description = "The review engine behind the jpr Neovim plugin."
version.workspace = true
edition.workspace = true
rust-version.workspace = true
license.workspace = true

# The library half holds everything worth testing; the binary is a thin shell
# around it. Tests and the binary both say `use app::...`.
[lib]
name = "app"
path = "src/lib.rs"

[[bin]]
name = "jpr-review"
path = "src/main.rs"

[dependencies]
anyhow.workspace = true
clap.workspace = true
serde_json.workspace = true
review-core.workspace = true
review-model.workspace = true
review-store-fs.workspace = true
review-forge-github.workspace = true
review-workspace-git.workspace = true
review-rpc.workspace = true

[dev-dependencies]
review-core = { workspace = true, features = ["fakes"] }

[lints]
workspace = true
```

- [ ] **Step 3: Write the dependency-rule test (it fails to build until the crate compiles)**

`crates/jpr-review/tests/dependency_rule.rs`:

```rust
//! The dependency rule from docs/architecture.md: a generic crate
//! (`review-*`) never depends on a frontend crate or a UI library, directly
//! or through another crate. Checked against `cargo metadata`'s resolved graph.

use std::collections::{BTreeSet, HashMap};
use std::process::Command;

use serde_json::{Value, json};

/// Libraries that tie code to a terminal UI or to an editor.
const UI_CRATES: &[&str] = &[
    "ratatui", "crossterm", "termion", "cursive", "tui-term", "portable-pty", "vt100",
    "nvim-rs", "nvim-oxi", "mlua", "neovim-lib",
];

const GENERIC_PREFIX: &str = "review-";

/// Every way a generic crate reaches a frontend crate or a UI library.
fn violations(metadata: &Value) -> Vec<String> {
    let names: HashMap<&str, &str> = metadata["packages"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|package| Some((package["id"].as_str()?, package["name"].as_str()?)))
        .collect();
    let members: BTreeSet<&str> = metadata["workspace_members"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let edges: HashMap<&str, Vec<&str>> = metadata["resolve"]["nodes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|node| {
            let deps = node["deps"]
                .as_array()?
                .iter()
                .filter(|dep| runtime(dep))
                .filter_map(|dep| dep["pkg"].as_str())
                .collect();
            Some((node["id"].as_str()?, deps))
        })
        .collect();
    let mut found = Vec::new();
    for &member in &members {
        let member_name = names.get(member).copied().unwrap_or(member);
        if !member_name.starts_with(GENERIC_PREFIX) {
            continue;
        }
        let mut seen = BTreeSet::new();
        let mut stack = vec![member];
        while let Some(id) = stack.pop() {
            for &dep in edges.get(id).map(Vec::as_slice).unwrap_or_default() {
                if !seen.insert(dep) {
                    continue;
                }
                let name = names.get(dep).copied().unwrap_or(dep);
                if UI_CRATES.contains(&name) {
                    found.push(format!("{member_name} depends on the UI library {name}"));
                }
                if members.contains(dep) && !name.starts_with(GENERIC_PREFIX) {
                    found.push(format!("{member_name} depends on the frontend crate {name}"));
                }
                stack.push(dep);
            }
        }
    }
    found
}

/// Whether an edge is a normal or build dependency. Dev-dependencies may be anything.
fn runtime(dep: &Value) -> bool {
    dep["dep_kinds"].as_array().is_some_and(|kinds| {
        kinds
            .iter()
            .any(|kind| kind["kind"].is_null() || kind["kind"] == "build")
    })
}

fn workspace_metadata() -> Value {
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_owned());
    let manifest = concat!(env!("CARGO_MANIFEST_DIR"), "/../../Cargo.toml");
    let output = Command::new(cargo)
        .args(["metadata", "--format-version", "1", "--manifest-path", manifest])
        .output()
        .expect("cargo metadata runs");
    assert!(
        output.status.success(),
        "cargo metadata failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("cargo metadata prints JSON")
}

#[test]
fn generic_crates_stay_frontend_neutral() {
    let found = violations(&workspace_metadata());
    assert!(found.is_empty(), "the dependency rule is broken:\n{}", found.join("\n"));
}

#[test]
fn the_rule_catches_a_ui_library_and_a_frontend_crate() {
    let metadata = json!({
        "packages": [
            { "id": "core", "name": "review-core" },
            { "id": "ui", "name": "ratatui" },
            { "id": "app", "name": "jpr-review" }
        ],
        "workspace_members": ["core", "app"],
        "resolve": { "nodes": [
            { "id": "core", "deps": [
                { "pkg": "ui", "dep_kinds": [{ "kind": null }] },
                { "pkg": "app", "dep_kinds": [{ "kind": null }] }
            ] },
            { "id": "ui", "deps": [] },
            { "id": "app", "deps": [] }
        ] }
    });
    assert_eq!(
        violations(&metadata),
        [
            "review-core depends on the UI library ratatui",
            "review-core depends on the frontend crate jpr-review",
        ]
    );
}

#[test]
fn dev_dependencies_are_exempt() {
    let metadata = json!({
        "packages": [{ "id": "core", "name": "review-core" }, { "id": "ui", "name": "ratatui" }],
        "workspace_members": ["core"],
        "resolve": { "nodes": [
            { "id": "core", "deps": [{ "pkg": "ui", "dep_kinds": [{ "kind": "dev" }] }] },
            { "id": "ui", "deps": [] }
        ] }
    });
    assert!(violations(&metadata).is_empty());
}
```

- [ ] **Step 4: Replace `crates/jpr-review/src/lib.rs`**

```rust
//! jpr-review: the composition root. It wires the generic review crates
//! (`review-*`) to real adapters and exposes them as commands. No review rule
//! lives here; see docs/architecture.md.

pub mod cli;
pub mod commands;
pub mod prompt;
pub mod theme;

/// The product name shown to people.
pub const APP_NAME: &str = "jpr-review";

/// The directory under the XDG state home where review state lives.
pub const STATE_APP: &str = "jpr";
```

- [ ] **Step 5: Replace `crates/jpr-review/src/cli.rs`**

```rust
//! The command-line surface. The Neovim plugin drives these commands with
//! flags. `checkout` and `state-path` ask for an omitted value on a terminal;
//! `serve` takes only flags because its stdin is the protocol.

use clap::{Parser, Subcommand};

/// jpr-review: the review engine behind the jpr Neovim plugin.
#[derive(Debug, Clone, Parser)]
#[command(version, propagate_version = true, arg_required_else_help = true)]
pub struct Cli {
    /// The command to run.
    #[command(subcommand)]
    pub command: Command,
}

/// The things this tool can be asked to do.
#[derive(Debug, Clone, PartialEq, Eq, Subcommand)]
pub enum Command {
    /// Check a pull request out into a worktree and print where, as JSON.
    Checkout {
        /// The pull request number. Left out on a terminal, you are asked.
        #[arg(long)]
        pr: Option<u64>,
        /// A shell command that creates the worktree and prints its path; `{n}` is the number.
        #[arg(long, value_name = "COMMAND", env = "JPR_WORKTREE_CMD")]
        worktree_cmd: Option<String>,
    },
    /// Serve a pull request's review session as JSON-RPC on stdin and stdout.
    Serve {
        /// The pull request number.
        #[arg(long)]
        pr: u64,
        /// The repository, as owner/name.
        #[arg(long, value_name = "OWNER/NAME")]
        repo: String,
        /// Seconds between background syncs; 0 syncs only on request.
        #[arg(long, value_name = "SECONDS", default_value_t = 60)]
        poll: u64,
    },
    /// Print the directory that holds a pull request's review state.
    StatePath {
        /// The pull request number. Left out on a terminal, you are asked.
        #[arg(long)]
        pr: Option<u64>,
        /// The repository, as owner/name. Left out on a terminal, you are asked.
        #[arg(long, value_name = "OWNER/NAME")]
        repo: Option<String>,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    #[test]
    fn the_surface_is_well_formed() {
        Cli::command().debug_assert();
    }

    #[test]
    fn a_bare_invocation_shows_the_help() {
        let error = Cli::try_parse_from(["jpr-review"]).expect_err("a subcommand is required");
        assert_eq!(error.kind(), clap::error::ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand);
    }

    #[test]
    fn checkout_takes_a_number_and_a_worktree_command() {
        let cli = Cli::try_parse_from(["jpr-review", "checkout", "--pr", "7", "--worktree-cmd", "wt pr {n}"]).unwrap();
        assert_eq!(cli.command, Command::Checkout { pr: Some(7), worktree_cmd: Some("wt pr {n}".into()) });
    }

    #[test]
    fn serve_polls_every_minute_by_default() {
        let cli = Cli::try_parse_from(["jpr-review", "serve", "--pr", "7", "--repo", "octo/widgets"]).unwrap();
        assert_eq!(cli.command, Command::Serve { pr: 7, repo: "octo/widgets".into(), poll: 60 });
    }

    #[test]
    fn serve_requires_the_repository() {
        assert!(Cli::try_parse_from(["jpr-review", "serve", "--pr", "7"]).is_err());
    }
}
```

- [ ] **Step 6: Replace `crates/jpr-review/src/commands/mod.rs`**

```rust
//! Subcommand dispatch and the helpers commands share.

pub mod checkout;
pub mod serve;
pub mod state_path;

use std::env;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};

use crate::cli::{Cli, Command};
use crate::prompt::{self, Question};
use crate::theme::Theme;

/// Runs the command the arguments selected.
pub fn run(cli: &Cli, theme: Theme) -> Result<()> {
    match &cli.command {
        Command::Checkout { pr, worktree_cmd } => {
            checkout::run(pr_number(*pr, theme)?, worktree_cmd.as_deref(), theme)
        }
        Command::Serve { pr, repo, poll } => serve::run(*pr, repo, *poll),
        Command::StatePath { pr, repo } => {
            let number = pr_number(*pr, theme)?;
            state_path::run(number, &repo_name(repo.as_deref(), theme)?)
        }
    }
}

/// The pull request number: the flag, else asked for on a terminal.
pub fn pr_number(flag: Option<u64>, theme: Theme) -> Result<u64> {
    if let Some(number) = flag {
        return Ok(number);
    }
    let question = Question::new("pull request number", "Which pull request?", "--pr <NUMBER>");
    parse_pr_number(&prompt::ask(&question, theme)?)
}

/// Reads `12` or `#12`.
pub fn parse_pr_number(answer: &str) -> Result<u64> {
    let trimmed = answer.trim();
    trimmed
        .strip_prefix('#')
        .unwrap_or(trimmed)
        .parse()
        .with_context(|| format!("{trimmed:?} is not a pull request number"))
}

/// The repository: the flag, else asked for on a terminal.
pub fn repo_name(flag: Option<&str>, theme: Theme) -> Result<String> {
    if let Some(repo) = flag {
        return Ok(repo.to_owned());
    }
    let question = Question::new("repository", "Which repository (owner/name)?", "--repo <OWNER/NAME>");
    prompt::ask(&question, theme)
}

/// Splits `owner/name`.
pub fn parse_repo(value: &str) -> Result<(String, String)> {
    match value.split_once('/') {
        Some((owner, name)) if !owner.is_empty() && !name.is_empty() && !name.contains('/') => {
            Ok((owner.to_owned(), name.to_owned()))
        }
        _ => bail!("expected the repository as owner/name, got {value:?}"),
    }
}

/// This machine's state directory for a pull request.
pub fn state_dir(owner: &str, name: &str, number: u64) -> Result<PathBuf> {
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME is not set")?;
    let xdg = env::var_os("XDG_STATE_HOME").map(PathBuf::from);
    Ok(review_store_fs::state_dir(
        xdg.as_deref(),
        &home,
        crate::STATE_APP,
        owner,
        name,
        number,
    ))
}

/// Says what the tool is about to do, on stderr.
pub fn narrate(theme: Theme, message: &str) {
    eprintln!("{}", theme.info(message));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_pull_request_numbers() {
        assert_eq!(parse_pr_number("12").unwrap(), 12);
        assert_eq!(parse_pr_number(" #34\n").unwrap(), 34);
        assert!(parse_pr_number("abc").is_err());
    }

    #[test]
    fn splits_owner_and_name() {
        assert_eq!(parse_repo("octo/widgets").unwrap(), ("octo".to_owned(), "widgets".to_owned()));
        assert!(parse_repo("widgets").is_err());
        assert!(parse_repo("/widgets").is_err());
        assert!(parse_repo("a/b/c").is_err());
    }
}
```

- [ ] **Step 7: Create the three commands**

`crates/jpr-review/src/commands/checkout.rs`:

```rust
//! `checkout`: put a pull request in its own worktree and say where.

use std::env;
use std::path::Path;

use anyhow::{Context, Result};
use review_core::ports::Forge;
use review_forge_github::GhForge;
use review_model::PullRequest;
use review_workspace_git::{WorktreeCommand, checkout_pr};
use serde_json::json;

use crate::theme::Theme;

pub fn run(number: u64, worktree_cmd: Option<&str>, theme: Theme) -> Result<()> {
    let cwd = env::current_dir().context("reading the current directory")?;
    super::narrate(theme, &format!("Looking up pull request #{number}..."));
    let pr = GhForge::new(cwd.clone(), None).pull_request(number)?;
    super::narrate(theme, &format!("Checking out #{number} ({})...", pr.head_ref));
    let command = worktree_cmd.map_or(WorktreeCommand::Default, |template| {
        WorktreeCommand::Custom(template.to_owned())
    });
    let worktree = checkout_pr(&cwd, number, &command)?;
    println!("{}", output_line(&pr, &worktree));
    Ok(())
}

/// The JSON line `checkout` prints for its caller.
#[must_use]
pub fn output_line(pr: &PullRequest, worktree: &Path) -> String {
    json!({
        "worktree": worktree,
        "repo": format!("{}/{}", pr.owner, pr.repo),
        "number": pr.number,
        "title": pr.title,
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use review_core::fakes::sample_pr;

    use super::*;

    #[test]
    fn prints_the_worktree_and_the_repository() {
        let line = output_line(&sample_pr(), Path::new("/tmp/widgets-worktrees/pr-7"));
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(value["worktree"], "/tmp/widgets-worktrees/pr-7");
        assert_eq!(value["repo"], "octo/widgets");
        assert_eq!(value["number"], 7);
        assert_eq!(value["title"], "Fix the widget");
    }
}
```

`crates/jpr-review/src/commands/serve.rs`:

```rust
//! `serve`: one pull request's review session, as JSON-RPC on stdin/stdout.

use std::env;
use std::io;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use review_core::ReviewSession;
use review_core::ports::SystemClock;
use review_forge_github::GhForge;
use review_rpc::ServeOptions;
use review_store_fs::FsStore;

pub fn run(number: u64, repo: &str, poll: u64) -> Result<()> {
    let (owner, name) = super::parse_repo(repo)?;
    let cwd = env::current_dir().context("reading the current directory")?;
    let store = FsStore::new(super::state_dir(&owner, &name, number)?);
    let forge = GhForge::new(cwd.clone(), Some(repo.to_owned()));
    let mut session = ReviewSession::open(number, Box::new(forge), Box::new(store), Box::new(SystemClock))?;
    session.record_daemon(std::process::id(), &cwd.to_string_lossy())?;
    let options = ServeOptions {
        server_version: env!("CARGO_PKG_VERSION").to_owned(),
        poll_every: poll_interval(poll),
    };
    review_rpc::serve(
        io::stdin().lock(),
        &Arc::new(Mutex::new(io::stdout())),
        &Arc::new(Mutex::new(session)),
        &options,
    )
}

/// `--poll` seconds as an interval; 0 turns background syncing off.
#[must_use]
pub const fn poll_interval(seconds: u64) -> Option<Duration> {
    if seconds == 0 {
        None
    } else {
        Some(Duration::from_secs(seconds))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_turns_polling_off() {
        assert_eq!(poll_interval(0), None);
        assert_eq!(poll_interval(60), Some(Duration::from_secs(60)));
    }
}
```

`crates/jpr-review/src/commands/state_path.rs`:

```rust
//! `state-path`: where a pull request's review state lives on this machine.

use anyhow::Result;

pub fn run(number: u64, repo: &str) -> Result<()> {
    let (owner, name) = super::parse_repo(repo)?;
    println!("{}", super::state_dir(&owner, &name, number)?.display());
    Ok(())
}
```

`crates/jpr-review/src/main.rs` stays as it is (it calls `app::commands::run(&cli, theme)`).

- [ ] **Step 8: Run the tests**

Run: `cargo test -p jpr-review`
Expected: PASS (the cli, commands, checkout, serve, prompt and theme unit tests, plus 3 dependency-rule tests).

- [ ] **Step 9: Check the binary by hand**

```bash
cargo run -q -p jpr-review -- state-path --pr 7 --repo octo/widgets
XDG_STATE_HOME=/tmp/x cargo run -q -p jpr-review -- state-path --pr 7 --repo octo/widgets
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' '{"jsonrpc":"2.0","id":2,"method":"snapshot"}' '{"jsonrpc":"2.0","id":3,"method":"shutdown"}' \
  | XDG_STATE_HOME="$(mktemp -d)" cargo run -q -p jpr-review -- serve --pr 7 --repo octo/widgets --poll 0
cargo run -q -p jpr-review -- checkout < /dev/null; echo "exit=$?"
```

Expected:
- `<home>/.local/state/jpr/octo/widgets/pr-7`
- `/tmp/x/jpr/octo/widgets/pr-7`
- three JSON responses: `protocolVersion` 1, a view with `"sync":{"state":"never"}`, then `null`
- an error naming `--pr <NUMBER>` and `exit=1`

- [ ] **Step 10: Gate and commit**

Run: `just check`
Expected: PASS.

```bash
git add -A crates/jpr-review Cargo.lock
git commit -m "feat(cli): add checkout, serve and state-path, and enforce the dependency rule"
```

---

### Task 13: Lua plugin entry, command parsing and the Lua test runner

**Files:**
- Create: `plugin/jpr.lua`, `lua/jpr/init.lua`, `scripts/test-lua.sh`, `tests/lua/command_spec.lua`
- Modify: `justfile`

- [ ] **Step 1: Create the test runner**

`scripts/test-lua.sh`:

```bash
#!/usr/bin/env bash
# Runs every Lua spec in a clean headless Neovim. A spec fails by raising an error.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
status=0
for spec in "$root"/tests/lua/*_spec.lua; do
  if ! nvim --headless -u NONE -i NONE -l "$spec"; then
    echo "FAILED: ${spec#"$root"/}" >&2
    status=1
  fi
done
exit "$status"
```

```bash
chmod +x scripts/test-lua.sh
```

In `justfile`, change the `check` recipe to:

```just
check: fmt-check lint test test-lua
```

- [ ] **Step 2: Write the failing spec**

`tests/lua/command_spec.lua`:

```lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")

assert(jpr.parse_pr_arg("123") == 123, "a bare number")
assert(jpr.parse_pr_arg("#45") == 45, "a hash number")
assert(jpr.parse_pr_arg("https://github.com/octo/widgets/pull/678") == 678, "a pull request URL")
assert(jpr.parse_pr_arg("https://github.com/octo/widgets/pull/678/files") == 678, "a files URL")
assert(jpr.parse_pr_arg("abc") == nil, "not a number")
assert(jpr.parse_pr_arg(nil) == nil, "missing")

assert(vim.deep_equal(jpr.complete("", "Jpr "), { "open", "sync", "close" }), "all subcommands")
assert(vim.deep_equal(jpr.complete("s", "Jpr s"), { "sync" }), "filtered subcommands")
assert(vim.deep_equal(jpr.complete("", "Jpr open "), {}), "nothing after the subcommand")

jpr.setup({ worktree_cmd = "wt pr {n}" })
assert(jpr.config.worktree_cmd == "wt pr {n}", "setup takes options")
assert(jpr.config.binary == "jpr-review", "setup keeps the defaults")

dofile(root .. "/plugin/jpr.lua")
assert(vim.api.nvim_get_commands({})["Jpr"] ~= nil, ":Jpr exists")

local messages = {}
vim.notify = function(msg, level)
	messages[#messages + 1] = { msg = msg, level = level }
end
jpr.command({ "frobnicate" })
assert(messages[1].level == vim.log.levels.ERROR, "an unknown subcommand is an error")
assert(messages[1].msg:find("unknown subcommand", 1, true), messages[1].msg)
jpr.command({ "open", "abc" })
assert(messages[2].msg:find("usage", 1, true), "open without a number shows the usage")

print("command_spec: ok")
```

- [ ] **Step 3: Run it to see it fail**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/command_spec.lua`
Expected: FAIL with `module 'jpr' not found`.

- [ ] **Step 4: Implement the entry points**

`lua/jpr/init.lua`:

```lua
-- jpr: review GitHub pull requests in Neovim, backed by the jpr-review engine.
local M = {}

M.defaults = {
	-- The engine binary.
	binary = "jpr-review",
	-- A shell command that creates the PR worktree and prints its path; `{n}` is
	-- the PR number. nil uses the engine's default (git worktree + gh pr checkout).
	worktree_cmd = nil,
	-- Width of the PR panel.
	panel_width = 44,
}

M.config = vim.deepcopy(M.defaults)

M.subcommands = { "open", "sync", "close" }

function M.define_highlights()
	local links = {
		JprTitle = "Title",
		JprMuted = "Comment",
		JprViewed = "DiagnosticOk",
		JprDismissed = "DiagnosticWarn",
		JprAdded = "Added",
		JprRemoved = "Removed",
		JprError = "DiagnosticError",
	}
	for name, target in pairs(links) do
		vim.api.nvim_set_hl(0, name, { link = target, default = true })
	end
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
	M.define_highlights()
end

--- The PR number in a `:Jpr open` argument: `123`, `#123`, or a pull request URL.
function M.parse_pr_arg(arg)
	if type(arg) ~= "string" then
		return nil
	end
	local number = arg:match("^#?(%d+)$") or arg:match("/pull/(%d+)")
	return number and tonumber(number) or nil
end

--- Completes `:Jpr <subcommand>`; arguments after it have no completion.
function M.complete(arglead, cmdline)
	local words = vim.split(vim.trim(cmdline), "%s+")
	if #words > 2 or (#words == 2 and arglead == "") then
		return {}
	end
	return vim.tbl_filter(function(name)
		return vim.startswith(name, arglead)
	end, M.subcommands)
end

function M.error(message)
	vim.notify("jpr: " .. message, vim.log.levels.ERROR)
end

function M.info(message)
	vim.notify("jpr: " .. message, vim.log.levels.INFO)
end

--- Runs `:Jpr <fargs>`.
function M.command(fargs)
	local sub = fargs[1]
	if sub == "open" then
		local number = M.parse_pr_arg(fargs[2])
		if not number then
			return M.error("usage: :Jpr open <number | #number | pull request URL>")
		end
		require("jpr.session").open(number)
	elseif sub == "sync" then
		require("jpr.session").sync_current()
	elseif sub == "close" then
		require("jpr.session").close_current()
	else
		M.error(("unknown subcommand %q; expected one of: %s"):format(tostring(sub), table.concat(M.subcommands, ", ")))
	end
end

return M
```

`plugin/jpr.lua`:

```lua
-- Defines :Jpr. Everything else loads on first use.
if vim.g.loaded_jpr then
	return
end
vim.g.loaded_jpr = true

vim.api.nvim_create_user_command("Jpr", function(opts)
	require("jpr").command(opts.fargs)
end, {
	nargs = "+",
	desc = "Review a GitHub pull request (open, sync, close)",
	complete = function(arglead, cmdline)
		return require("jpr").complete(arglead, cmdline)
	end,
})
```

- [ ] **Step 5: Run the spec**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/command_spec.lua`
Expected: prints `command_spec: ok`, exit 0. The `open abc` branch never reaches `jpr.session`, so the missing module is not an error yet.

- [ ] **Step 6: Gate and commit**

Run: `just check`
Expected: PASS.

```bash
git add plugin lua scripts/test-lua.sh tests/lua justfile
git commit -m "feat(nvim): add :Jpr, its argument parsing, and the Lua spec runner"
```

---

### Task 14: Lua JSON-RPC client

**Files:**
- Create: `lua/jpr/rpc.lua`, `tests/lua/fixtures/fake_engine.sh`, `tests/lua/rpc_spec.lua`

- [ ] **Step 1: Create the fake engine**

`tests/lua/fixtures/fake_engine.sh`:

```sh
#!/bin/sh
# A stand-in for `jpr-review serve` in the Lua specs: answers by method name and
# ignores its arguments.
view_synced='{"pr":{"number":7,"title":"Fix the widget"},"files":[{"path":"README.md","additions":2,"deletions":1,"viewed":"VIEWED","threads":1}],"viewedCount":1,"threadCount":1,"sync":{"state":"synced","at":1}}'
view_empty='{"files":[],"viewedCount":0,"threadCount":0,"sync":{"state":"never"}}'
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"version":"test"}}\n' "$id" ;;
    *'"method":"snapshot"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$view_empty" ;;
    *'"method":"sync"'*)
      printf '{"jsonrpc":"2.0","method":"event","params":{"type":"synced","view":%s}}\n' "$view_synced"
      printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$view_synced" ;;
    *'"method":"shutdown"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":null}\n' "$id"
      exit 0 ;;
    *)
      printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"method not found"}}\n' "$id" ;;
  esac
done
```

```bash
chmod +x tests/lua/fixtures/fake_engine.sh
```

- [ ] **Step 2: Write the failing spec**

`tests/lua/rpc_spec.lua`:

```lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local rpc = require("jpr.rpc")

local lines, pending = rpc.split_chunks("", { '{"a":1}', '{"b"' })
assert(vim.deep_equal(lines, { '{"a":1}' }) and pending == '{"b"', "a partial line waits")
lines, pending = rpc.split_chunks(pending, { ":2}", "" })
assert(vim.deep_equal(lines, { '{"b":2}' }) and pending == "", "the rest completes it")

assert(rpc.decode("not json") == nil, "invalid JSON decodes to nil")
assert(rpc.decode('{"id":1,"result":null}').id == 1, "valid JSON decodes")

local notifications, exited = {}, nil
local client = assert(rpc.start({ root .. "/tests/lua/fixtures/fake_engine.sh" }, {
	on_notification = function(method, params)
		notifications[#notifications + 1] = { method = method, params = params }
	end,
	on_exit = function(code)
		exited = code
	end,
}))

local init
client:request("initialize", { protocolVersion = rpc.PROTOCOL_VERSION }, function(err, result)
	init = { err = err, result = result }
end)
assert(vim.wait(2000, function()
	return init ~= nil
end), "initialize is answered")
assert(init.err == nil and init.result.protocolVersion == 1, vim.inspect(init))

local synced
client:request("sync", nil, function(err, result)
	synced = { err = err, result = result }
end)
assert(vim.wait(2000, function()
	return synced ~= nil
end), "sync is answered")
assert(synced.result.pr.number == 7, vim.inspect(synced))
assert(#notifications == 1 and notifications[1].method == "event", vim.inspect(notifications))
assert(notifications[1].params.type == "synced", "the event is a sync")

local unknown
client:request("frobnicate", nil, function(err)
	unknown = err
end)
assert(vim.wait(2000, function()
	return unknown ~= nil
end), "an unknown method is answered")
assert(unknown.code == -32601, vim.inspect(unknown))

local stopped
client:request("shutdown", nil, function()
	stopped = true
end)
assert(vim.wait(2000, function()
	return stopped and exited ~= nil
end), "shutdown ends the process")

local late
client:request("snapshot", nil, function(err)
	late = err
end)
assert(late and late.message:find("not running", 1, true), "requests after exit fail at once")

print("rpc_spec: ok")
```

- [ ] **Step 3: Run it to see it fail**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/rpc_spec.lua`
Expected: FAIL with `module 'jpr.rpc' not found`.

- [ ] **Step 4: Implement the client**

`lua/jpr/rpc.lua`:

```lua
-- Newline-delimited JSON-RPC client for the jpr-review engine (docs/protocol.md).
local M = {}

M.PROTOCOL_VERSION = 1

--- Splits job output into complete lines. `data` follows jobstart's on_stdout
--- contract: the first item continues the pending partial line, and the last
--- item is the new partial line ("" right after a newline).
function M.split_chunks(pending, data)
	local lines = {}
	local current = pending .. (data[1] or "")
	for i = 2, #data do
		lines[#lines + 1] = current
		current = data[i]
	end
	return lines, current
end

--- Decodes one line into a message, or nil and an error.
function M.decode(line)
	local ok, message = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
	if not ok or type(message) ~= "table" then
		return nil, "invalid JSON from the engine: " .. line
	end
	return message
end

local Client = {}
Client.__index = Client

--- Starts `cmd` and returns a client, or nil and an error.
--- opts: cwd, on_notification(method, params), on_exit(code, stderr).
function M.start(cmd, opts)
	local self = setmetatable({ next_id = 1, callbacks = {}, pending = "", stderr = {}, opts = opts or {} }, Client)
	self.job = vim.fn.jobstart(cmd, {
		cwd = self.opts.cwd,
		on_stdout = function(_, data)
			self:_on_stdout(data)
		end,
		on_stderr = function(_, data)
			for _, line in ipairs(data) do
				if line ~= "" then
					self.stderr[#self.stderr + 1] = line
				end
			end
		end,
		on_exit = function(_, code)
			self:_on_exit(code)
		end,
	})
	if self.job <= 0 then
		return nil, "could not start " .. cmd[1]
	end
	return self
end

function Client:_on_stdout(data)
	local lines
	lines, self.pending = M.split_chunks(self.pending, data)
	for _, line in ipairs(lines) do
		if line ~= "" then
			self:_dispatch(line)
		end
	end
end

function Client:_dispatch(line)
	local message, err = M.decode(line)
	if not message then
		if self.opts.on_notification then
			self.opts.on_notification("protocolError", { message = err })
		end
		return
	end
	if message.id ~= nil and message.method == nil then
		local callback = self.callbacks[message.id]
		self.callbacks[message.id] = nil
		if callback then
			if message.error then
				callback(message.error, nil)
			else
				callback(nil, message.result)
			end
		end
	elseif message.method and self.opts.on_notification then
		self.opts.on_notification(message.method, message.params)
	end
end

function Client:_on_exit(code)
	self.exited = true
	for id, callback in pairs(self.callbacks) do
		self.callbacks[id] = nil
		callback({ code = -1, message = ("the engine exited (%d)"):format(code) }, nil)
	end
	if self.opts.on_exit then
		self.opts.on_exit(code, table.concat(self.stderr, "\n"))
	end
end

--- Sends `method` with `params`; `callback(err, result)` runs on the answer.
function Client:request(method, params, callback)
	if self.exited then
		return callback({ code = -1, message = "the engine is not running" }, nil)
	end
	local id = self.next_id
	self.next_id = id + 1
	self.callbacks[id] = callback
	local payload = vim.json.encode({ jsonrpc = "2.0", id = id, method = method, params = params or vim.empty_dict() })
	vim.fn.chansend(self.job, payload .. "\n")
end

function Client:stop()
	if not self.exited then
		vim.fn.jobstop(self.job)
	end
end

return M
```

- [ ] **Step 5: Run the spec**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/rpc_spec.lua`
Expected: prints `rpc_spec: ok`, exit 0.

- [ ] **Step 6: Gate and commit**

Run: `just check`
Expected: PASS.

```bash
git add lua/jpr/rpc.lua tests/lua
git commit -m "feat(nvim): add the JSON-RPC client"
```

---

### Task 15: Panel rendering, the panel window and the session

**Files:**
- Create: `lua/jpr/render/panel.lua`, `lua/jpr/views/panel.lua`, `lua/jpr/session.lua`, `tests/lua/panel_render_spec.lua`, `tests/lua/session_spec.lua`

- [ ] **Step 1: Write the failing render spec**

`tests/lua/panel_render_spec.lua`:

```lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local panel = require("jpr.render.panel")

assert(panel.age(5) == "5s ago" and panel.age(125) == "2m ago" and panel.age(7300) == "2h ago", "ages")

local view = {
	pr = { number = 7, title = "Fix the widget" },
	files = {
		{ path = "src/a.rs", additions = 12, deletions = 3, viewed = "VIEWED", threads = 2 },
		{ path = "src/b.rs", additions = 1, deletions = 0, viewed = "DISMISSED", threads = 0 },
		{ path = "docs/x.md", additions = 4, deletions = 4, viewed = "UNVIEWED", threads = 0 },
	},
	viewedCount = 1,
	threadCount = 2,
	sync = { state = "synced", at = 100 },
}
local built = panel.build(view, 112)
assert(vim.deep_equal(built.lines, {
	"#7 Fix the widget",
	"viewed 1/3 · threads 2",
	"synced 12s ago",
	"",
	"✓ src/a.rs  +12 -3 [2]",
	"● src/b.rs  +1 -0",
	"  docs/x.md  +4 -4",
}), vim.inspect(built.lines))
assert(built.paths[5] == "src/a.rs" and built.paths[7] == "docs/x.md" and built.paths[4] == nil, vim.inspect(built.paths))

local function highlighted(result, group)
	local out = {}
	for _, hl in ipairs(result.highlights) do
		if hl.group == group then
			out[#out + 1] = result.lines[hl.line + 1]:sub(hl.col_start + 1, hl.col_end)
		end
	end
	return out
end
assert(vim.deep_equal(highlighted(built, "JprAdded"), { "+12", "+1", "+4" }), vim.inspect(highlighted(built, "JprAdded")))
assert(vim.deep_equal(highlighted(built, "JprRemoved"), { "-3", "-0", "-4" }), vim.inspect(highlighted(built, "JprRemoved")))
assert(vim.deep_equal(highlighted(built, "JprViewed"), { "✓" }), "viewed mark")
assert(vim.deep_equal(highlighted(built, "JprDismissed"), { "●" }), "dismissed mark")
assert(vim.deep_equal(highlighted(built, "JprTitle"), { "#7 Fix the widget" }), "title")

local failed = panel.build({ files = {}, sync = { state = "failed", at = 1, message = "offline" } }, 2)
assert(failed.lines[1] == "Loading pull request…", failed.lines[1])
assert(failed.lines[3] == "sync failed: offline", failed.lines[3])
assert(vim.deep_equal(highlighted(failed, "JprError"), { "sync failed: offline" }), "failure is an error")
assert(panel.build({}, 0).lines[3] == "not synced yet", "a fresh view")

print("panel_render_spec: ok")
```

- [ ] **Step 2: Run it to see it fail**

Run: `nvim --headless -u NONE -i NONE -l tests/lua/panel_render_spec.lua`
Expected: FAIL with `module 'jpr.render.panel' not found`.

- [ ] **Step 3: Implement the renderer**

`lua/jpr/render/panel.lua`:

```lua
-- Pure: turns the engine's SessionView into panel lines, highlights and a
-- line-to-path map. No windows or buffers here.
local M = {}

local VIEWED_MARK = { VIEWED = "✓", DISMISSED = "●", UNVIEWED = " " }

function M.age(seconds)
	if seconds < 60 then
		return ("%ds ago"):format(seconds)
	end
	if seconds < 3600 then
		return ("%dm ago"):format(math.floor(seconds / 60))
	end
	return ("%dh ago"):format(math.floor(seconds / 3600))
end

--- The sync status line and its highlight group.
function M.sync_text(sync, now)
	if not sync or sync.state == "never" then
		return "not synced yet", "JprMuted"
	end
	if sync.state == "synced" then
		return "synced " .. M.age(math.max(0, now - sync.at)), "JprMuted"
	end
	return "sync failed: " .. (sync.message or "unknown error"), "JprError"
end

--- @return table { lines: string[], highlights: { line, col_start, col_end, group }[], paths: table<integer, string> }
--- `line` is 0-based and columns are byte offsets; `paths` is keyed by 1-based line number.
function M.build(view, now)
	local lines, highlights, paths = {}, {}, {}
	local function add(text, group)
		lines[#lines + 1] = text
		if group then
			highlights[#highlights + 1] = { line = #lines - 1, col_start = 0, col_end = #text, group = group }
		end
	end

	local pr = view.pr
	add(pr and ("#%d %s"):format(pr.number, pr.title) or "Loading pull request…", "JprTitle")
	local files = view.files or {}
	add(("viewed %d/%d · threads %d"):format(view.viewedCount or 0, #files, view.threadCount or 0), "JprMuted")
	add(M.sync_text(view.sync, now))
	add("")

	for _, file in ipairs(files) do
		local mark = VIEWED_MARK[file.viewed] or " "
		local plus = ("+%d"):format(file.additions)
		local stats = ("%s -%d"):format(plus, file.deletions)
		local threads = file.threads > 0 and (" [%d]"):format(file.threads) or ""
		add(("%s %s  %s%s"):format(mark, file.path, stats, threads))
		local line = #lines - 1
		paths[#lines] = file.path
		if file.viewed == "VIEWED" then
			highlights[#highlights + 1] = { line = line, col_start = 0, col_end = #mark, group = "JprViewed" }
		elseif file.viewed == "DISMISSED" then
			highlights[#highlights + 1] = { line = line, col_start = 0, col_end = #mark, group = "JprDismissed" }
		end
		local stats_start = #mark + 1 + #file.path + 2
		highlights[#highlights + 1] = { line = line, col_start = stats_start, col_end = stats_start + #plus, group = "JprAdded" }
		highlights[#highlights + 1] =
			{ line = line, col_start = stats_start + #plus + 1, col_end = stats_start + #stats, group = "JprRemoved" }
	end

	return { lines = lines, highlights = highlights, paths = paths }
end

return M
```

Run: `nvim --headless -u NONE -i NONE -l tests/lua/panel_render_spec.lua`
Expected: prints `panel_render_spec: ok`.

- [ ] **Step 4: Write the failing session spec**

`tests/lua/session_spec.lua`:

```lua
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local session = require("jpr.session")
local panel_view = require("jpr.views.panel")
local fixture = root .. "/tests/lua/fixtures/fake_engine.sh"

jpr.setup({ binary = fixture })
assert(vim.deep_equal(session.checkout_args(7), { fixture, "checkout", "--pr", "7" }), "checkout args")
jpr.setup({ binary = fixture, worktree_cmd = "wt pr {n}" })
assert(
	vim.deep_equal(session.checkout_args(7), { fixture, "checkout", "--pr", "7", "--worktree-cmd", "wt pr {n}" }),
	"checkout args with a worktree command"
)

local info = session.parse_checkout('Checking out...\n{"worktree":"/tmp/w","repo":"octo/widgets","number":7,"title":"T"}\n')
assert(info.worktree == "/tmp/w" and info.repo == "octo/widgets" and info.number == 7, vim.inspect(info))
local missing, err = session.parse_checkout("")
assert(missing == nil and err:find("printed nothing", 1, true), "empty checkout output")
local bad, bad_err = session.parse_checkout("{}")
assert(bad == nil and bad_err:find("unexpected", 1, true), "checkout output without a worktree")

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello" }, worktree .. "/README.md")

session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local s = session.current()
assert(s and s.number == 7, "the tab has a session")
assert(vim.fn.resolve(vim.fn.getcwd(-1, 0)) == vim.fn.resolve(worktree), "the tab's directory is the worktree")

assert(vim.wait(3000, function()
	return vim.api.nvim_buf_get_lines(s.panel.buf, 0, 1, false)[1] == "#7 Fix the widget"
end), "the panel shows the synced pull request")
local lines = vim.api.nvim_buf_get_lines(s.panel.buf, 0, -1, false)
assert(lines[5] == "✓ README.md  +2 -1 [1]", vim.inspect(lines))

vim.api.nvim_set_current_win(s.panel.win)
vim.api.nvim_win_set_cursor(s.panel.win, { 5, 0 })
panel_view.open_file_under_cursor(s)
assert(vim.api.nvim_get_current_win() ~= s.panel.win, "the file opens beside the panel")
assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/README.md"), "the worktree file opens")

local tabs = #vim.api.nvim_list_tabpages()
session.close_current()
assert(session.current() == nil, "closing forgets the session")
assert(#vim.api.nvim_list_tabpages() == tabs - 1, "closing closes the tab")

print("session_spec: ok")
```

Run: `nvim --headless -u NONE -i NONE -l tests/lua/session_spec.lua`
Expected: FAIL with `module 'jpr.session' not found`.

- [ ] **Step 5: Implement the panel window**

`lua/jpr/views/panel.lua`:

```lua
-- The PR panel window: draws render.panel output and opens files on <CR>.
local render = require("jpr.render.panel")

local M = {}

local ns = vim.api.nvim_create_namespace("jpr-panel")

--- Opens the panel on the left of the current tab for `session`.
function M.open(session)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, ("jpr://panel/%d"):format(session.number))
	vim.bo[buf].filetype = "jpr-panel"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false
	vim.cmd("topleft vsplit")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_width(win, require("jpr").config.panel_width)
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].winfixwidth = true
	vim.wo[win].cursorline = true
	vim.wo[win].wrap = false
	session.panel = { buf = buf, win = win, paths = {} }
	vim.keymap.set("n", "<CR>", function()
		M.open_file_under_cursor(session)
	end, { buffer = buf, desc = "Open the file under the cursor" })
	M.render(session, session.view or {})
end

--- Redraws the panel from `view`.
function M.render(session, view)
	local panel = session.panel
	if not panel or not vim.api.nvim_buf_is_valid(panel.buf) then
		return
	end
	local built = render.build(view, os.time())
	panel.paths = built.paths
	vim.bo[panel.buf].modifiable = true
	vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, built.lines)
	vim.bo[panel.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(panel.buf, ns, 0, -1)
	for _, hl in ipairs(built.highlights) do
		vim.api.nvim_buf_set_extmark(panel.buf, ns, hl.line, hl.col_start, { end_col = hl.col_end, hl_group = hl.group })
	end
end

--- Opens the file on the cursor line in the window beside the panel.
function M.open_file_under_cursor(session)
	local panel = session.panel
	local path = panel.paths[vim.api.nvim_win_get_cursor(panel.win)[1]]
	if not path then
		return
	end
	local target
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if win ~= panel.win then
			target = win
			break
		end
	end
	if not target then
		vim.cmd("rightbelow vsplit")
		target = vim.api.nvim_get_current_win()
	end
	vim.api.nvim_set_current_win(target)
	-- Relative to the tab's directory, which is the worktree.
	vim.cmd.edit(path)
end

return M
```

- [ ] **Step 6: Implement the session**

`lua/jpr/session.lua`:

```lua
-- One open pull-request review per tab: the checkout, the engine process, and
-- the panel. Every review rule lives in the engine; this only wires it up.
local rpc = require("jpr.rpc")
local panel = require("jpr.views.panel")

local M = {}

M.by_tab = {}

local function jpr()
	return require("jpr")
end

function M.current()
	return M.by_tab[vim.api.nvim_get_current_tabpage()]
end

--- The `jpr-review checkout` command for PR `number`.
function M.checkout_args(number)
	local config = jpr().config
	local args = { config.binary, "checkout", "--pr", tostring(number) }
	if config.worktree_cmd then
		vim.list_extend(args, { "--worktree-cmd", config.worktree_cmd })
	end
	return args
end

--- The JSON object on the last non-empty line of `checkout`'s stdout.
function M.parse_checkout(stdout)
	local last
	for line in (stdout or ""):gmatch("[^\n]+") do
		if vim.trim(line) ~= "" then
			last = line
		end
	end
	if not last then
		return nil, "jpr-review checkout printed nothing"
	end
	local ok, info = pcall(vim.json.decode, last)
	if not ok or type(info) ~= "table" or not info.worktree or not info.repo then
		return nil, "unexpected checkout output: " .. last
	end
	return info
end

--- `:Jpr open <number>`: reuse its tab, or check it out and start a session.
function M.open(number)
	for tab, existing in pairs(M.by_tab) do
		if existing.number == number and vim.api.nvim_tabpage_is_valid(tab) then
			return vim.api.nvim_set_current_tabpage(tab)
		end
	end
	if vim.fn.executable(jpr().config.binary) ~= 1 then
		return jpr().error(("%s is not installed or not on PATH"):format(jpr().config.binary))
	end
	jpr().info(("checking out PR #%d…"):format(number))
	vim.system(M.checkout_args(number), { cwd = vim.fn.getcwd(), text = true }, vim.schedule_wrap(function(result)
		if result.code ~= 0 then
			local stderr = vim.trim(result.stderr or "")
			return jpr().error(stderr ~= "" and stderr or "checkout failed")
		end
		local info, err = M.parse_checkout(result.stdout)
		if not info then
			return jpr().error(err)
		end
		M.start(info)
	end))
end

--- Opens a tab for a checked-out PR and starts its engine.
--- info: { worktree, repo = "owner/name", number }.
function M.start(info)
	jpr().define_highlights()
	vim.cmd("tabnew")
	vim.cmd.tcd(info.worktree)
	local tab = vim.api.nvim_get_current_tabpage()
	local session = { number = info.number, repo = info.repo, worktree = info.worktree, tab = tab, view = {} }
	M.by_tab[tab] = session
	panel.open(session)

	local client, err = rpc.start({ jpr().config.binary, "serve", "--pr", tostring(info.number), "--repo", info.repo }, {
		cwd = info.worktree,
		on_notification = function(method, params)
			M.on_notification(session, method, params)
		end,
		on_exit = function(code, stderr)
			M.on_exit(session, code, stderr)
		end,
	})
	if not client then
		return jpr().error(err)
	end
	session.client = client
	client:request("initialize", { protocolVersion = rpc.PROTOCOL_VERSION, client = "jpr.nvim" }, function(init_err, result)
		if init_err then
			return jpr().error("could not start the review engine: " .. init_err.message)
		end
		if result.protocolVersion ~= rpc.PROTOCOL_VERSION then
			client:stop()
			return jpr().error(
				("protocol mismatch: the plugin speaks %d and %s speaks %d; install both from the same checkout"):format(
					rpc.PROTOCOL_VERSION,
					jpr().config.binary,
					result.protocolVersion
				)
			)
		end
		client:request("snapshot", nil, function(_, view)
			if view then
				M.show(session, view)
			end
		end)
		M.sync(session)
	end)
end

function M.show(session, view)
	session.view = view
	panel.render(session, view)
end

function M.sync(session)
	if not session.client then
		return jpr().error("the review engine is not running; reopen the pull request")
	end
	session.client:request("sync", nil, function(err, view)
		if err then
			return jpr().error("sync failed: " .. err.message)
		end
		M.show(session, view)
	end)
end

function M.on_notification(session, method, params)
	if method == "event" and params and params.type == "synced" then
		M.show(session, params.view)
	elseif method == "event" and params and params.type == "syncFailed" then
		session.view.sync = { state = "failed", at = os.time(), message = params.message }
		panel.render(session, session.view)
	elseif method == "protocolError" then
		jpr().error(params.message)
	end
end

function M.on_exit(session, code, stderr)
	session.client = nil
	if session.closing then
		return
	end
	local detail = (stderr and stderr ~= "") and (": " .. stderr) or ""
	jpr().error(("the review engine for PR #%d stopped (exit %d)%s"):format(session.number, code, detail))
end

function M.sync_current()
	local session = M.current()
	if not session then
		return jpr().error("no pull request is open in this tab")
	end
	M.sync(session)
end

function M.close_current()
	local session = M.current()
	if not session then
		return jpr().error("no pull request is open in this tab")
	end
	session.closing = true
	if session.client then
		session.client:request("shutdown", nil, function() end)
		session.client:stop()
	end
	M.by_tab[session.tab] = nil
	if vim.api.nvim_tabpage_is_valid(session.tab) and #vim.api.nvim_list_tabpages() > 1 then
		vim.api.nvim_set_current_tabpage(session.tab)
		vim.cmd("tabclose")
	end
end

return M
```

- [ ] **Step 7: Run every Lua spec**

Run: `just test-lua`
Expected: `command_spec: ok`, `rpc_spec: ok`, `panel_render_spec: ok`, `session_spec: ok`, exit 0.

- [ ] **Step 8: Gate and commit**

Run: `just check`
Expected: PASS.

```bash
git add lua tests/lua
git commit -m "feat(nvim): open a PR tab with a live panel driven by the engine"
```

---

### Task 16: Documentation

**Files:**
- Replace: `docs/architecture.md`, `README.md`
- Create: `docs/protocol.md`
- Modify: `docs/decisions.md`, `AGENTS.md`, `docs/rules/cli-rust.md`

- [ ] **Step 1: Replace `docs/architecture.md`**

````markdown
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
`cargo metadata`. Generic crate names never contain `nvim` or `jpr`.

**Where logic goes.** If a decision would be the same in a terminal UI, it is
Rust in a generic crate. Lua manages windows, buffers and keys, and draws the
read models the engine returns.

## The generic crates

| Crate | Responsibility |
| --- | --- |
| `review-model` | Domain types (pull requests, changed files, threads, anchors, messages) and read models (`SessionView`, `FileRow`, `SyncState`, `Event`). Pure data. |
| `review-core` | The ports (`Forge`, `ReviewStore`, `Clock`), the `ReviewSession` facade, and the presenter that builds read models. The `fakes` feature adds in-memory fakes and the port contract tests. |
| `review-store-fs` | The `ReviewStore` adapter: one directory per PR under `$XDG_STATE_HOME/<app>/<owner>/<repo>/pr-<n>/`, atomic JSON writes. |
| `review-forge-github` | The `Forge` adapter: `gh pr view` and `gh api graphql`, with a 30 second timeout per call. Adapted from dif. |
| `review-workspace-git` | Checks a PR out into a worktree: the default (`git worktree add` plus `gh pr checkout`) or a custom command that prints the path. |
| `review-rpc` | The JSON-RPC protocol and a server over any line-based transport, with a background poller. |

## Patterns

- **Ports and adapters.** The engine reaches the outside world only through
  traits in `review_core::ports`. Each adapter passes the shared contract test
  for its port (`review_core::contract`).
- **Facade.** Frontends talk only to `ReviewSession`.
- **Command/query split.** `sync` changes state; `view` reads it. The RPC
  methods follow the same split.
- **Observer.** `ReviewSession::subscribe` returns a channel of `Event`s; the
  RPC server forwards them as `event` notifications.
- **Presenter.** `review_core::session_view` builds the `SessionView` every
  frontend draws.
- **Composition root.** Only `crates/jpr-review` builds real adapters.

## Process model

`:Jpr open <n>` runs `jpr-review checkout`, which prints the worktree as JSON.
The plugin then opens a tab whose directory is the worktree and starts
`jpr-review serve` there. The server reads requests on stdin, writes responses
and notifications on stdout, and syncs with GitHub in the background every 60
seconds. A sync failure keeps the last view and is announced as an event.
Threads run the poller and the event forwarder; there is no async runtime.

## State on disk

| File | Holds |
| --- | --- |
| `session.json` | Daemon pid, worktree, the pull request, the last sync time |
| `viewed.json` | The changed files with their counts and viewed state |

Later milestones add local threads, the sync registry and agent rounds.

## The binary

`crates/jpr-review` keeps the scaffold's library-plus-thin-binary shape:
`src/main.rs` parses, calls `commands::run`, and turns an error into a stderr
line and exit code 1. `prompt.rs` asks for a value left out on a terminal, and
`theme.rs` holds the semantic colors. `serve` takes only flags, because its
stdin is the protocol.

## The Neovim plugin

| Module | Responsibility |
| --- | --- |
| `plugin/jpr.lua` | Defines `:Jpr` |
| `jpr` | Config, highlight groups, argument parsing, subcommand dispatch |
| `jpr.rpc` | JSON-RPC client over `jobstart` |
| `jpr.session` | One review per tab: checkout, engine process, panel updates |
| `jpr.render.panel` | Pure: `SessionView` to lines, highlights and paths |
| `jpr.views.panel` | The panel window; `<CR>` opens a file |

## Tests

- `cargo test --workspace --all-features`: the engine against fakes, the
  adapters, the protocol over in-memory streams, and the dependency rule.
- `./scripts/test-lua.sh`: headless Neovim specs against
  `tests/lua/fixtures/fake_engine.sh`.
- `just check` runs both plus formatting and clippy.
````

- [ ] **Step 2: Create `docs/protocol.md`**

````markdown
# Engine protocol (version 1)

`jpr-review serve` speaks JSON-RPC 2.0, one JSON message per line, UTF-8.
Requests arrive on stdin. Responses and notifications leave on stdout and may
interleave, so clients match responses by `id`. Logs go to stderr.

```
jpr-review serve --pr <number> --repo <owner/name> [--poll <seconds>]
```

Run it in the pull request's worktree. `--poll 0` turns background syncing off.

## Handshake

The client sends `initialize` first and compares `protocolVersion` with its
own. On a mismatch it stops the server and tells the user to install the plugin
and the engine from the same checkout.

## Requests

| Method | Params | Result |
| --- | --- | --- |
| `initialize` | `{ "protocolVersion": 1, "client": "..." }` | `{ "protocolVersion": 1, "version": "0.1.0" }` |
| `snapshot` | none | `SessionView` |
| `sync` | none | `SessionView`; error `-32000` when GitHub fails |
| `shutdown` | none | `null`; the server stops reading and exits |

## Notifications (server to client)

`event`, with one of:

```json
{ "type": "synced", "view": SessionView }
{ "type": "syncFailed", "message": "gh timed out after 30s" }
```

## Types

`SessionView`:

```json
{
  "pr": { "owner": "octo", "repo": "widgets", "number": 7, "title": "Fix the widget",
          "url": "https://github.com/octo/widgets/pull/7", "nodeId": "PR_7", "author": "alice",
          "headRef": "fix/widget", "headSha": "abc123", "baseRef": "main" },
  "files": [ { "path": "src/a.rs", "additions": 12, "deletions": 3, "viewed": "VIEWED", "threads": 2 } ],
  "viewedCount": 1,
  "threadCount": 2,
  "sync": { "state": "synced", "at": 1763510400 }
}
```

- `pr` is `null` until the first successful sync.
- `viewed` is `VIEWED`, `UNVIEWED` or `DISMISSED` (viewed, then changed on GitHub).
- `sync` is `{ "state": "never" }`, `{ "state": "synced", "at": <unix seconds> }`
  or `{ "state": "failed", "at": <unix seconds>, "message": "..." }`.

## Errors

| Code | Meaning |
| --- | --- |
| -32700 | The line is not JSON (the response `id` is `null`) |
| -32600 | Not a request (no `method` or no `id`) |
| -32601 | Unknown method |
| -32602 | Invalid params |
| -32000 | The engine could not do it; `message` says why |

## Versioning

Change `PROTOCOL_VERSION` in `crates/review-rpc/src/protocol.rs` and
`M.PROTOCOL_VERSION` in `lua/jpr/rpc.lua` together whenever a request, a
result or an event changes shape, and update this document in the same commit.
````

- [ ] **Step 3: Append to `docs/decisions.md`**

```markdown
## A workspace of generic crates and one composition root

**Decision.** The engine is split into `review-*` crates that know nothing
about Neovim, plus `jpr-review`, the only crate that wires real adapters
together. This supersedes "The dependency set stays at four crates": that was
the scaffold's starting point for a single-crate tool.

**Why.** The review engine is meant to be reused by other frontends, starting
with dif's terminal UI. Crate boundaries make the dependency rule mechanical,
and a test enforces it.

**Consequences.** `serde_json` joins (the protocol and the state files are
JSON). `toml` and the scaffold's example `config` command leave. `tempfile` is
a dev-dependency for filesystem tests.

**Revisit when.** A crate is only ever used by one other crate and never by a
frontend; merge it then.

## Threads and channels, not an async runtime

**Decision.** The server uses a reader loop, a poller thread and an
event-forwarding thread around one `Mutex<ReviewSession>`.

**Why.** Every outside call is a short blocking `gh` or file operation, which
is also how dif works. An async runtime would add weight without a need.

**Consequences.** A request waits while a background sync holds the session
lock, up to `gh`'s 30 second timeout on a bad network.

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
```

- [ ] **Step 4: Update `AGENTS.md`**

Replace the whole `## Stack` section (from `## Stack` up to, not including, `## Documentation`) with:

```markdown
## Stack

- This project is a pull-request review engine written in Rust (edition 2024,
  a Cargo workspace under `crates/`) plus a Neovim plugin in Lua (`lua/`,
  `plugin/`). There is no web server and no browser.
- **The dependency rule is binding.** Generic crates (`crates/review-*`) never
  depend on Neovim, Lua, a terminal UI library, or a frontend crate. Review
  rules live in Rust; Lua only draws view models and manages windows. Read
  [`docs/architecture.md`](docs/architecture.md) before adding a module, and
  [`docs/protocol.md`](docs/protocol.md) before changing a request or event.
- The binary crate `crates/jpr-review` is the composition root: clap (derive)
  for the command-line surface, anyhow errors with context, and a thin
  `src/main.rs`.
- Every command is reachable with flags alone. A value left out on a terminal
  is asked for through `crates/jpr-review/src/prompt.rs`; `serve` takes only
  flags because its stdin is the protocol.
- Tasks live in the `justfile` (`just --list`). Every recipe is a single
  command you could type by hand. `just check` runs formatting, clippy, the
  Rust tests and the Lua specs.

```

Then, in the rules list further down, replace:

```markdown
  this Rust code: `src/prompt.rs` for questions, `src/theme.rs` for color.
```

with:

```markdown
  this Rust code: `crates/jpr-review/src/prompt.rs` for questions,
  `crates/jpr-review/src/theme.rs` for color.
```

- [ ] **Step 5: Update the paths in `docs/rules/cli-rust.md`**

```bash
sed -i.bak 's#`src/#`crates/jpr-review/src/#g' docs/rules/cli-rust.md && rm docs/rules/cli-rust.md.bak
git diff --stat docs/rules/cli-rust.md
```

Expected: one file changed, five paths updated.

- [ ] **Step 6: Replace `README.md`**

````markdown
# jpr-nvim

Review GitHub pull requests in Neovim. `:Jpr open <number>` checks the pull
request out into its own worktree and opens a tab with a panel of its changed
files, viewed state and review threads, kept in sync with GitHub.

The review engine (`jpr-review`) is a Rust workspace of frontend-neutral crates;
the Neovim plugin is a thin Lua frontend over its JSON-RPC protocol. See
[`docs/architecture.md`](docs/architecture.md) and
[`docs/protocol.md`](docs/protocol.md).

## Requirements

- A Rust toolchain ([rustup.rs](https://rustup.rs)) to build the engine.
- The GitHub CLI (`gh`), logged in.
- git and Neovim 0.11 or newer.

## Install

```sh
./install.sh                  # builds jpr-review into ~/.local/bin (BIN_DIR to change)
```

Load the plugin from the same checkout, so the Lua and the engine always come
from one commit. With lazy.nvim:

```lua
{
  dir = "/path/to/jpr-nvim",
  name = "jpr",
  cmd = "Jpr",
  config = function()
    require("jpr").setup({
      -- Optional: a command that creates the worktree and prints its path.
      -- worktree_cmd = "my-worktree-tool pr {n}",
    })
  end,
}
```

## Use

| Command | What it does |
| --- | --- |
| `:Jpr open <n \| #n \| URL>` | Check the pull request out and open its review tab |
| `:Jpr sync` | Sync with GitHub now (it also syncs every minute) |
| `:Jpr close` | Stop the engine and close the tab |

In the panel, `<CR>` opens the file under the cursor from the worktree.

## Develop

```sh
just check        # fmt, clippy, Rust tests, Lua specs
just test         # Rust tests only
just test-lua     # Lua specs only
just run --help   # the engine's commands
```

## Agent skills

Agent skills are not tracked in git, but `skills-lock.json` is.
`just skills-install` restores them after a clone.
````

- [ ] **Step 7: Gate and commit**

Run: `just check`
Expected: PASS.

```bash
git add docs README.md AGENTS.md
git commit -m "docs: describe the engine, the protocol and the plugin"
```

---

### Task 17: Smoke test against GitHub

Needs network, a logged-in `gh`, and an open pull request the reviewer can read. **Ask the user which repository and PR number to use**; do not open a PR to create one.

- [ ] **Step 1: Install the branch build to a scratch directory**

```bash
scratch="$(mktemp -d)"
BIN_DIR="$scratch" ./install.sh
export PATH="$scratch:$PATH"
jpr-review --version
```

Expected: `jpr-review 0.1.0`.

- [ ] **Step 2: Check out and sync from the command line**

From a checkout of the chosen repository (`<repo-checkout>`, PR `<n>`, `owner/name` `<owner/name>`):

```bash
cd <repo-checkout>
jpr-review checkout --pr <n>
```

Expected: progress on stderr, then one JSON line with `worktree`, `repo`, `number` and `title`. The worktree exists and is on branch `pr-<n>`.

```bash
cd <worktree from the JSON>
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}' '{"jsonrpc":"2.0","id":2,"method":"sync"}' '{"jsonrpc":"2.0","id":3,"method":"shutdown"}' \
  | jpr-review serve --pr <n> --repo <owner/name> --poll 0
```

Expected: the `initialize` result, then a `synced` event and the `sync` result listing the PR's files with counts, viewed state and thread counts that match the PR's Files tab on github.com, then `null`.

- [ ] **Step 3: Drive it from Neovim**

```bash
cd <repo-checkout>
nvim --cmd "set rtp^=$(git -C <jpr-nvim worktree> rev-parse --show-toplevel)" -c "lua require('jpr').setup({})"
```

In Neovim: `:Jpr open <n>`. Expected: a new tab whose `:pwd` is the worktree, a panel with `#<n> <title>`, `viewed x/y · threads z`, `synced Ns ago`, and the files. `<CR>` on a file opens it. On github.com, mark one file viewed, run `:Jpr sync`, and see ✓ appear. `:Jpr close` closes the tab.

- [ ] **Step 4: Record the result**

Write two or three lines in the final report: the repository and PR used, whether the counts matched github.com, and anything that misbehaved. Clean up: remove the scratch directory, and remove the PR worktree if the user does not want to keep it.

---

## After this plan

- The final branch review runs before finishing the branch (per the execution rules).
- Merging `feat/core` and publishing it are the user's call.
- Installing the published engine and loading the plugin in the user's own Neovim config is a separate, host-specific step that lives outside this repository.
- Milestone 2 (review views: unified and split overlays, the stream, viewed toggling) gets its own plan.
