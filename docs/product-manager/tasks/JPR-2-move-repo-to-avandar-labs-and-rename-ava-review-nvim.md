---
id: JPR-2
title: Move repository to Avandar Labs org and rename plugin to ava-review-nvim
status: backlog
priority: none
assignee: jpsyx
labels: [chore]
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

# JPR-2: Move repository to Avandar Labs org and rename plugin to ava-review-nvim

## Description

Transfer the repository into the Avandar Labs GitHub organization and rename the plugin from `jpr-nvim` to `ava-review-nvim`. Update all package names, binary/crate names as appropriate, Lua module/plugin references, installation snippets, README, and documentation accordingly.

## Acceptance criteria

- [ ] Repository is transferred to the Avandar Labs GitHub organization and renamed to `ava-review-nvim`.
- [ ] Cargo package/binary names, `plugin/` entrypoint, Lua namespace/module paths, and build scripts reflect `ava-review-nvim` consistently.
- [ ] `README.md`, `docs/`, `justfile`, CI workflows, and install examples reference the Avandar Labs org URL and new package/plugin names.
- [ ] `just check` passes with no stale `jpr-nvim` package references.

## Notes

### Pointers (as of 2026-11-27)

- `Cargo.toml` and `crates/jpr-review/Cargo.toml`: workspace and binary crate package names, metadata, and repository URLs.
- `plugin/jpr.lua`, `lua/jpr/init.lua`, `lua/jpr/binary.lua`, `lua/jpr/build.lua`, `lua/jpr/health.lua`: plugin loader, binary discovery/build paths, and health checks referencing `jpr` / `jpr-review`.
- `README.md`, `AGENTS.md`, `justfile`, and `docs/`: user-facing install snippets, command references, and architecture docs to update.
- Note: `JPR-3` (`:Jpr` -> `:AvaPr` command rename) is blocked on this move/rename.

### Log

- 2026-11-27 created.
