---
id: JPR-7
title: Shorten comment box mode badges to [github] and [local]
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

# JPR-7: Shorten comment box mode badges to `[github]` and `[local]`

## Description

Simplify the comment compose box destination badges. Currently the compose box displays wordy labels like `[local -> agent]` and `[github draft]` (or `[GitHub draft]` / `[GitHub comment]`). Replace them with concise `[github]` and `[local]` badges.

## Acceptance criteria

- [ ] Comment compose box displays `[github]` for GitHub comments/drafts and `[local]` for local comments.
- [ ] Any related compose title builders (new comment, reply, edit if applicable) are checked for consistency and brevity.
- [ ] Lua tests asserting the old badge text are updated and `just check` passes.

## Notes

### Pointers (as of 2026-11-27)

- `lua/jpr/comments/compose/editor.lua`: title/badge builder around lines 90-98 (formats `[GitHub draft]`, `[GitHub comment]`, and local badge) and `flip_destination`.
- `lua/jpr/comments/compose/init.lua`: reply and edit title badges around lines 98-102 and 134 (`[Local reply]`, `[GitHub reply]`, `[GitHub draft]`).
- `tests/lua/`: grep for `GitHub draft` / `local → agent` / `Local` in compose specs to update assertions.

### Log

- 2026-11-27 created.
