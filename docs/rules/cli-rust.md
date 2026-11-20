# Rust CLI rules

These rules say where [`cli-ux.md`](cli-ux.md) lives in this Rust code. Read
that file first: it holds the rules, and this one holds the mechanics.

## Arguments are clap derive

The command-line surface is declared once, in `crates/jpr-review/src/cli.rs`, with clap's derive
API. Every value a command needs is a flag or an argument there, which is what
keeps every action scriptable. `crates/jpr-review/src/main.rs` stays thin: it parses and hands
the result to the library, so every decision is reachable from a test.

## Asking for a missing value: `crates/jpr-review/src/prompt.rs`

Describe the missing value as a `Question` (what it is, the flag that answers
it, the choices if there is a fixed set) and call `prompt::ask`. It asks only
when stdin is a terminal; otherwise it fails with a message naming the flag.
The decisions it makes (`interpret`, `render`, `unanswerable_message`) are pure
functions, tested in the same file.

```rust
let question = Question::new("pull request number", "Which pull request?", "--pr <NUMBER>");
let answer = prompt::ask(&question, theme)?;
```

## Color: `crates/jpr-review/src/theme.rs`

Every role in `cli-ux.md` is a method on `Theme`, and no other file writes an
escape code. The test in `crates/jpr-review/src/theme.rs` keeps every tone in the bright half of
the ANSI palette. Color is emitted only when stderr is a terminal and
`NO_COLOR` is unset.

## Errors and exit codes

Failures travel as `anyhow` errors carrying the context that produced them.
`main` prints the chain on stderr with `theme.error_line` and returns
`ExitCode::FAILURE`. Never
call `std::process::exit` below `main`: it skips destructors and makes the
code untestable.
