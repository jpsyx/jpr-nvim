---
id: JPR-4
title: Change default shortcuts for command palette to <leader>a and agent panel to <leader>A
status: backlog
priority: none
assignee: jpsyx
labels: [enhancement]
estimate:
project:
milestone:
cycle:
parent:
github:
blocked_by: []
created: 2026-11-27
updated: 2026-11-27
---

# JPR-4: Change default shortcuts for command palette to `<leader>a` and agent panel to `<leader>A`

## Description

Update the plugin's default leader-key shortcuts so that:
- Command Palette opens with `<leader>a` (lowercase `a`, replacing `<leader>J`).
- Agent panel toggles with `<leader>A` (shift `A`, replacing `ga`).

Both remain configurable via `setup({ keys = ... })` and disableable with `false`, keeping their `<Plug>` mappings intact.

## Acceptance criteria

- [ ] Default `keys.palette` is `<leader>a` in both `plugin/jpr.lua` and `lua/jpr/init.lua`.
- [ ] Default `keys.toggle_agent` is `<leader>A` in `lua/jpr/init.lua` (and any agent window/terminal toggle handlers).
- [ ] Existing `<leader>J` and `ga` defaults are replaced cleanly without leaving stale default bindings.
- [ ] Lua tests, `README.md`, and `docs/` reflect the new default shortcuts.
- [ ] `just check` passes.

## Notes

### Pointers (as of 2026-11-27)

- `plugin/jpr.lua`: binds the initial global default `<leader>J` to `<Plug>(jpr-palette)` if unmapped; update to `<leader>a`.
- `lua/jpr/init.lua`: `M.defaults.keys` defines `palette = "<leader>J"` and `toggle_agent = "ga"`, plus `M.bind_global_keys()` and `M.bind_session_keys()`. Check whether `toggle_agent` should remain session-scoped or also bind cleanly inside the agent terminal (`lua/jpr/agent/terminal.lua` and `lua/jpr/agent/window.lua`).
- `tests/lua/`: update keybinding tests expecting `<leader>J` or `ga`.
- `README.md` and `docs/`: update shortcut tables and command palette docs.

### Log

- 2026-11-27 created.
