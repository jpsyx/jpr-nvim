---
id: JPR-5
title: Show active comment mode prominently and add standalone mode toggle shortcut
status: backlog
priority: none
assignee: jpsyx
labels: [feature, enhancement]
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

# JPR-5: Show active comment mode prominently and add standalone mode toggle shortcut

## Description

Make the current default comment mode (`local` vs `github`) obvious and easy to see (in the statusline and/or another prominent review UI surface) so the reviewer always knows what `gc` will open by default.

Behavior:
- The active comment mode is a sticky, toggleable default, not just a per-comment override.
- Flipping the mode inside an open comment box updates the session's active comment mode so all future comment boxes default to that mode (flip to `local` -> stays `local`; flip to `github` -> stays `github`).
- Add a standalone `g`-prefixed shortcut (and matching `:Jpr` / Command Palette action if appropriate per the schema invariant) so the reviewer can toggle the active comment mode even when no comment box is open.

## Acceptance criteria

- [ ] Current comment mode (`local` or `github`) is prominently visible in the statusline (and/or diff panel header) whenever a review session is active.
- [ ] Toggling destination inside a comment compose box persists as the session's active default mode for subsequent comments.
- [ ] A standalone `g`-prefixed shortcut toggles the active comment mode outside of a compose box (respecting locked-local sessions where GitHub mode is unavailable, with clear feedback).
- [ ] UI indicator updates immediately when toggled either inside a comment box or via the standalone shortcut.
- [ ] Schema/Command Palette parity, tests, and docs are updated, and `just check` passes.

## Notes

### Pointers (as of 2026-11-27)

- `lua/jpr/comments/compose/init.lua` and `lua/jpr/comments/compose/editor.lua`: `session.compose_destination` already tracks sticky destination on `session`; verify `flip_destination` updates it and triggers a statusline/panel redraw.
- `lua/jpr/render/statusline.lua`: `M.build_statusline_from_session(session)` builds the O(1) statusline string; add an obvious `[github]` / `[local]` (or similar concise) comment-mode segment here and consider mirroring it in the diff sidebar header (`lua/jpr/render/panel.lua`).
- `plugin/jpr.lua`, `lua/jpr/init.lua`, and `lua/jpr/commands/schema.lua`: register the new `<Plug>` mapping, default `g`-prefixed key in `M.defaults.keys`, and Command Palette entry if exposed as a command (follow `AGENTS.md` schema-to-TUI invariant and the `g`-prefix shortcut convention in `JPR-6`).

### Log

- 2026-11-27 created.
