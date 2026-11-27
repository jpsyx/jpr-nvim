---
id: JPR-6
title: Add agent rule for shortcut conventions (g-prefix, leader modals, bare menu keys, Ctrl modal actions)
status: backlog
priority: none
assignee: jpsyx
labels: [docs, chore]
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

# JPR-6: Add agent rule for shortcut conventions (`g`-prefix, `<leader>` modals, bare menu keys, `<C-*>` modal actions)

## Description

Document the plugin's binding shortcut conventions as an explicit agent rule in `AGENTS.md` (and relevant `docs/`):

1. **Editor mode (`g`-prefix by default):** In general, shortcuts active in editor buffers must be `g`-prefixed (short for GitHub) to avoid colliding with user Neovim bindings.
2. **Leader-key shortcuts (`<leader>`):** Reserved strictly for opening panels or modals for only the most common interactions (currently Command Palette `<leader>a` and Agent Panel `<leader>A`). Never assume or invent new `<leader>` shortcuts; adding any `<leader>` mapping must be explicitly user-request driven.
3. **Non-editing menus and diff sidebar (bare single keys):** In read-only surfaces where editing is disabled (menus, diff sidebar, popups), single-character shortcuts (like `v`, `o`, etc.) are allowed for file, menu, and diff exploration because the plugin owns input there.
4. **Modal / text-input actions (`<C-*>`):** Control-based shortcuts (e.g., `<C-s>`, mode toggles) are reserved for actions performed inside a modal or text input box (toggling a mode, saving/sending a comment, etc.).

Also audit existing plugin-default keybindings against these rules and adjust any non-conforming bindings to `g`-prefixed alternatives if needed.

## Acceptance criteria

- [ ] `AGENTS.md` includes a clear, binding "Keybinding / Shortcut Conventions" section codifying all four tiers above.
- [ ] Any related keymap documentation in `docs/` aligns with the rule.
- [ ] Existing default keymaps in `plugin/jpr.lua`, `lua/jpr/init.lua`, sidebar, menus, and modals are audited against the convention (noting `JPR-4` handles `<leader>a` and `<leader>A`).

## Notes

### Pointers (as of 2026-11-27)

- `AGENTS.md`: add the binding shortcut convention section alongside the Interactive Command Palette & Schema-to-TUI Invariant.
- `plugin/jpr.lua` and `lua/jpr/init.lua` (`M.defaults.keys`): current plugin defaults. As of 2026-11-27, the only default `<leader>` key is `palette = "<leader>J"` (moving to `<leader>a` in `JPR-4`); `toggle_agent = "ga"` (moving to `<leader>A` in `JPR-4`); all other editor shortcuts are `g`-prefixed (`gc`, `gC`, `gf`, `gp`, `gF`, `gv`, `gt`, `gS`, `gs`, `gP`) except Vim bracket jumps `]t` / `[t`.
- `lua/jpr/views/panel.lua`, `lua/jpr/views/stream/navigation.lua`, `lua/jpr/comments/compose/editor.lua`: sidebar, stream, and compose-modal keybindings to cross-check during the audit.

### Log

- 2026-11-27 created.
