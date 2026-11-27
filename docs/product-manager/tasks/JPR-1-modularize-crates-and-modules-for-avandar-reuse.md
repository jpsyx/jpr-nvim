---
id: JPR-1
title: Modularize crates and modules for reuse in other Avandar diff-review tools
status: backlog
priority: none
assignee: jpsyx
labels: [tech-debt, enhancement]
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

# JPR-1: Modularize crates and modules for reuse in other Avandar diff-review tools

## Description

Audit and modularize the Rust crates (`crates/review-*`, `crates/cli-tui`, `crates/jpr-review`) and reusable Lua modules so that shared diff-review logic, domain models, diff parsing, forge integrations, and TUI primitives can be consumed cleanly by other diff-review tools across Avandar without dragging in Neovim-specific or app-specific coupling.

## Acceptance criteria

- [ ] Review boundaries across `crates/review-*`, `crates/cli-tui`, and `crates/jpr-review` are audited for reusable vs app-specific logic.
- [ ] Any reusable review, diff, git-workspace, storage, forge, or CLI-TUI logic currently living in `crates/jpr-review` is extracted into generic library crates with clean public APIs.
- [ ] Crate metadata, feature flags, and dependency edges support external consumption (workspace/path/git dependency) from other Avandar tools.
- [ ] `docs/architecture.md` documents the modular crate boundaries and how external Avandar tools consume them.
- [ ] `just check` passes.

## Notes

### Pointers (as of 2026-11-27)

- `Cargo.toml`: workspace members list (`cli-tui`, `jpr-review`, `review-core`, `review-diff`, `review-forge-github`, `review-model`, `review-rpc`, `review-store-fs`, `review-workspace-git`).
- `docs/architecture.md`: binding dependency rule keeping `crates/review-*` free of Neovim, Lua, and frontend crates; read first before moving modules.
- `crates/jpr-review/src/`: composition root; audit for reusable business logic that should move down into `review-*` or `cli-tui`.
- `lua/jpr/render/`: pure view-model renderers; evaluate whether any Lua rendering/UI helpers should also be cleanly separated from session wiring.

### Log

- 2026-11-27 created.
