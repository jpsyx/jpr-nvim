# Agent skills

This project ships a curated set of agent skills so every coding agent working
here starts with the same tooling. This document explains how they get onto
disk.

## One manager

**`npx skills`** installs everything listed in `skills-lock.json`. It writes
the real skill directories to `.agents/skills/`, symlinks them into
`.claude/skills/` for Claude Code, and relies on Cursor, OpenCode, and Codex
reading `.agents/skills/` natively.

- `npx skills list`: every skill, flagging any that are missing.
- `just skills-install`: install the locked skills that are not on disk yet.
- `just skills-update`: update every skill (`scripts/skills/update-skills.sh`).

Never create the per-frontend symlinks by hand: the manager owns the layout its
frontends expect.

## What git tracks

**Only `skills-lock.json`.** The installed directories (`.agents/`,
`.claude/skills/`, `.cursor/skills/`, `.opencode/`, `.codex/`) are gitignored.

- `just skills-install` restores them after a clone. It adds whatever the lock
  asks for that is not on disk and leaves everything else untouched.
- Install and update are separate: `just skills-install` materializes what is
  locked without upgrading anything, and `just skills-update` is the deliberate
  "get the latest" step.
- Where the restore runs automatically, `CI=true` or `SKIP_SKILLS_INSTALL=1`
  turns it off.

## Changing the skill set

```sh
npx skills add <owner>/<repo> --skill <name> --agent claude-code cursor opencode codex
npx skills remove <name>
```

Both commands update `skills-lock.json`. Commit that change.
