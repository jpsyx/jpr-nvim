# CLI experience rules

This is a tool people type at, and a tool agents script. Both are first-class,
and the rules below are what keeps them from pulling the design apart.

These rules hold whatever language the tool is written in. Where each one lives
in this project's code (the prompt module, the theme module, the argument
parser) is in the language-specific CLI rules linked from `AGENTS.md`.

## Stdout is data, stderr is the conversation

Stdout carries only intentional output: the answer the command was asked for,
in a shape something else can consume (`key=value` lines, a path, a JSON
document). Everything else goes to stderr: progress, prompts, warnings,
failures, and the argument parser's own errors. Anyone may pipe this tool into
another, so a diagnostic on stdout is a bug, and so is a decorated,
hand-aligned table where a machine expected a value.

## Two audiences, both first-class

- **An agent must be able to drive everything non-interactively.** Every action
  has a subcommand or a flag. No action is reachable only by answering a
  prompt, and no command blocks on input it was given on the command line.
- **A human who omits a subcommand or value gets guided, not rejected.** When
  invoked bare on an interactive terminal (both stdin and stderr are a TTY),
  the tool opens its interactive Command Palette on stderr; without a TTY (a
  pipe, a CI job, an agent), it prints help to stderr and exits non-zero (exit
  code `2`) without blocking. When a required value is missing on a TTY, the
  command launches its schema-driven interactive stepper (prefilled with any
  flags already supplied) or falls back to the themed prompt module. Never make
  somebody read `--help` to do the obvious thing. With no terminal, fail with a
  message that names the flag that would have answered the question.

Both paths stay synchronized through declarative command schemas and the
project's prompt module. A command describes its inputs (display label, helper
text, smart default, choices, and the flag that answers each value) and hands
interactive execution to the TUI/prompt layer, which decides whether to ask on
stderr or to fail. A command that reads from stdin itself is a command that
will eventually hang on a pipe.

A value that a person would otherwise pass every day belongs in the
configuration file as well, so the order is: the flag, then the configuration,
then the interactive stepper or question, then the failure that names the flag.

Adding a command means providing both paths (flags and declarative schema) in
the same change.

## Interactive Command Palette & Schema-to-TUI Invariant

**This invariant is binding for every command and option change.**

- Every command and option in **both** `:Jpr` (`lua/jpr/commands/schema.lua`)
  and `jpr-review` (`crates/jpr-review/src/tui_schema/`) MUST be registered in
  its declarative command schema so it is interactively launchable from the
  Command Palette (bare `:Jpr` in Neovim, bare `jpr-review` on a TTY).
- Every schema entry MUST define:
  1. A human-readable display label (never just the raw command literal) paired
     with `[<id>]`.
  2. Concise helper text (at most 1 sentence unless the option is genuinely
     confusing), shown on hover in menus (indented dim second line underneath
     only the hovered item) and on every stepper screen.
  3. Smart prefilled or preselected defaults wherever inferable from context.
  4. Discriminant-first step ordering with `when` predicates whenever a boolean
     or enum controls downstream options, so irrelevant steps are skipped and
     abandoned branch answers are pruned on completion.
  5. Neovim-conventional keyboard controls:
     - Normal-mode menus and toggles: `j`/`k`/`<Down>`/`<Up>` move,
       `h`/`<Left>`/`<S-Tab>` Back, `l`/`<Right>`/`<Tab>`/`<CR>` Confirm or
       Forward, `gg`/`<Home>` first item, `G`/`<End>` last item, `q`/`<Esc>`
       Cancel.
     - Insert-mode text inputs: prefilled smart default, `<Left>`/`<Right>`
       cursor movement, `<S-Tab>` Back, `<Tab>`/`<CR>` Validate & Forward,
       `<Esc>` to Normal mode then `q`/`<Esc>` Cancel.
  6. Full non-interactive flag and argument parity so scripts, pipes, CI, and
     coding agents never hit interactive prompts.
- Schema completeness is enforced by automated unit tests in both Rust
  (`crates/jpr-review/src/tui_schema/tests/`) and Lua
  (`tests/lua/palette_and_open_picker_spec.lua`).

## Narrate by default, detail under `--verbose`

If a command may spend noticeable time (reading many files, touching the
network, waiting on a child process), print a short line on stderr before each
phase saying what it is about to do. A person should never wonder whether the
tool is hung. `--verbose` is for detail and debugging, not for basic
reassurance, and the narration stays factual: it is a progress trace, not a
log dump.

## All color is semantic, and the terminal is dark

Every color decision names a role, never an escape code: `heading`, `accent`,
`value`, `muted`, `success`, `warning`, `error`, `info`, `prompt`. They live in
the project's theme module, and that is the only file allowed to know what a
role looks like. Style by meaning (a failure is `error`, a command name is `accent`, a
hint is `muted`), and be sparing: color guides the eye, it does not paint
everything.

Terminals do not reliably report whether they are light or dark, so the palette
assumes **dark** and uses the bright half of the ANSI palette. A dark
foreground on a dark background is unreadable, and a test in the theme module
fails if a tone drifts out of that range. Color is emitted only when stderr is
a terminal and `NO_COLOR` is unset, so piped output is always plain text.

## Exit codes are part of the interface

Exit `0` only when the command did what it was asked. Any failure exits
non-zero, after printing what went wrong and, when there is one, the command
or flag that fixes it. Scripts and agents branch on the exit code before they
read a word of the output:

- `0`: success.
- `1`: operational or runtime failure.
- `2`: usage error or missing required input without a TTY.
- `3`: GitHub authentication required (`gh` is not logged in or credentials
  expired), signaling frontends and scripts to run `gh auth login` and retry.
