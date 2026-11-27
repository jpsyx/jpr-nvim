---
id: JPR-3
title: Rename all :Jpr commands to :AvaPr after org move
status: backlog
priority: none
assignee: jpsyx
labels: [chore, enhancement]
estimate:
project:
milestone:
cycle:
parent:
github:
blocked_by: [JPR-2]
created: 2026-11-27
updated: 2026-11-27
---

# JPR-3: Rename all :Jpr commands to :AvaPr after org move

## Description

Once the repository has moved to Avandar Labs and been renamed to `ava-review-nvim` (`JPR-2`), rename the `:Jpr` Neovim user command (and all references in help text, palette labels, tests, README, and docs) to `:AvaPr`.

## Acceptance criteria

- [ ] Neovim user command `:AvaPr` replaces `:Jpr` with full subcommand completion and Command Palette parity.
- [ ] All `<Plug>` mappings, palette titles, error/info messages, and command schema text reference `:AvaPr` (or the updated namespace).
- [ ] All Lua tests, Rust tests (if any reference `:Jpr`), `README.md`, `AGENTS.md`, and `docs/` are updated.
- [ ] `just check` passes.

## Notes

### Pointers (as of 2026-11-27)

- `plugin/jpr.lua` (or its renamed counterpart after `JPR-2`): registers `vim.api.nvim_create_user_command("Jpr", ...)` and `<Plug>` mappings.
- `lua/jpr/commands/schema.lua` and `lua/jpr/init.lua`: command schema, aliases, subcommand dispatch, and completion.
- `tests/lua/`: Lua specs asserting `:Jpr` command registration and palette behavior.
- `README.md`, `AGENTS.md`, and `docs/`: update all `:Jpr` command examples and references.

### Log

- 2026-11-27 created (blocked by JPR-2).
