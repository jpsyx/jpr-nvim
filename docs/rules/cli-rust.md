# Rust CLI rules

These rules say where [`cli-ux.md`](cli-ux.md) lives in this Rust code. Read
that file first: it holds the rules, and this one holds the mechanics.

## Arguments are clap derive

The command-line surface is declared once, in `crates/jpr-review/src/cli.rs`, with clap's derive
API. Every value a command needs is a flag or an argument there, which is what
keeps every action scriptable. `crates/jpr-review/src/main.rs` stays thin: it parses and hands
the result to the library, so every decision is reachable from a test.

## Interactive Command Palette & steppers: `crates/cli-tui` and `crates/jpr-review/src/tui_schema/`

`crates/cli-tui` is a reusable frontend-layer schema-to-TUI crate that lives
outside `crates/review-*` so every generic `review-*` engine crate remains
UI-free (enforced by `crates/jpr-review/tests/dependency_rule.rs`).

- **Pure state and render separation.** `crates/cli-tui/src/schema/`
  (command/step specs, `when` predicate evaluation, validation, and abandoned
  branch pruning), `crates/cli-tui/src/state/` (`palette.rs` and `wizard/`
  key-handling state machines), and `crates/cli-tui/src/render/` (ANSI frame
  builders with hover-only menu helper text) perform zero terminal I/O and are
  unit-tested directly without a PTY.
- **Raw-mode stderr rendering with RAII cleanup.** `crates/cli-tui/src/runner/`
  is the thin `crossterm` shell that enables raw mode and hides the cursor
  inside a `RawModeGuard` RAII struct whose `Drop` restores cursor visibility
  and raw mode on completion, cancellation, or error. All TUI frames render to
  stderr so stdout remains reserved for machine-readable command output.
- **Strict TTY gating.** `cli_tui::is_interactive_terminal()` returns `true`
  only when both stdin and stderr are terminals; non-TTY callers (pipes, CI,
  coding agents) never enter raw mode or wait on prompts. Color respects
  `NO_COLOR`.
- **Schema registration and completeness tests.**
  `crates/jpr-review/src/tui_schema/` (`mod.rs`, `specs.rs`, `steps.rs`,
  `prefill.rs`, `convert.rs`) registers every `Command` variant from
  `crates/jpr-review/src/cli.rs` with human-readable labels, helper text, smart
  defaults, and discriminant-first steps. `crates/jpr-review/src/tui_schema/tests/`
  verifies that every clap subcommand has a valid schema entry and converts
  collected answers back into typed `Command` values.

## Asking for a missing value: `crates/jpr-review/src/prompt.rs`

For line-prompt fallback and non-TTY flag errors, describe the missing value as
a `Question` (what it is, the flag that answers it, the choices if there is a
fixed set) and call `prompt::ask`. It asks only when stdin is a terminal;
otherwise it fails with a message naming the flag. The decisions it makes
(`interpret`, `render`, `unanswerable_message`) are pure functions, tested in
the same file.

```rust
let question = Question::new("pull request number", "Which pull request?", "--pr <NUMBER>");
let answer = prompt::ask(&question, theme)?;
```

## Color: `crates/jpr-review/src/theme.rs`

Every role in `cli-ux.md` is a method on `Theme`, and no other file in
`crates/jpr-review` writes an escape code (TUI frame styling lives inside
`crates/cli-tui/src/render/`). The test in `crates/jpr-review/src/theme.rs`
keeps every tone in the bright half of the ANSI palette. Color is emitted only
when stderr is a terminal and `NO_COLOR` is unset.

## Errors and exit codes

Failures travel as `anyhow` errors carrying the context that produced them.
`main` prints the chain on stderr with `theme.error_line` and returns
`ExitCode::FAILURE` (bare non-TTY invocations print clap help to stderr and
return exit code `2`). Never call `std::process::exit` below `main`: it skips
destructors and makes the code untestable.
