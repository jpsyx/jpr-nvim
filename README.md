# jpr-nvim

Review GitHub pull requests in Neovim. `:Jpr open <number>` checks the pull
request out into its own worktree and opens a tab with a file tree of its
changes and a stream of every diff, kept in sync with GitHub. Every changed
file opens as a diff, unified or split.

The review engine (`jpr-review`) is a Rust workspace of frontend-neutral crates;
the Neovim plugin is a thin Lua frontend over its JSON-RPC protocol. See
[`docs/architecture.md`](docs/architecture.md) and
[`docs/protocol.md`](docs/protocol.md).

## Requirements

- A Rust toolchain ([rustup.rs](https://rustup.rs)) to build the engine.
- The GitHub CLI (`gh`), logged in.
- git and Neovim 0.11 or newer.

## Install

```sh
./install.sh                  # builds jpr-review into ~/.local/bin (BIN_DIR to change)
```

Load the plugin from the same checkout, so the Lua and the engine always come
from one commit. With lazy.nvim:

```lua
{
  dir = "/path/to/jpr-nvim",
  name = "jpr",
  cmd = "Jpr",
  config = function()
    require("jpr").setup({
      -- Optional: a command that creates the worktree and prints its path.
      -- worktree_cmd = "my-worktree-tool pr {n}",
      -- Optional: the diff view until you first run :Jpr toggle,
      -- "unified" (the default) or "split".
      -- view = "split",
    })
  end,
}
```

## Use

| Command | What it does |
| --- | --- |
| `:Jpr open <n \| #n \| URL>` | Check the pull request out and open its review tab. A URL must be for the repository Neovim's directory is a checkout of |
| `:Jpr sync` | Sync with GitHub now (it also syncs every minute) |
| `:Jpr toggle` | Flip every diff between unified and split; the choice is remembered |
| `:Jpr stream` | Show the stream of every change beside the panel |
| `:Jpr close` | Stop the engine and close the tab |

In the panel, `<CR>` opens the file under the cursor from the worktree and `v`
toggles it viewed. In the stream:

| Key | What it does |
| --- | --- |
| `<CR>` | Open the file at that line |
| `v` | Toggle viewed and move to the next unviewed file |
| `]f` / `[f` | Next / previous file |
| `]h` / `[h` | Next / previous hunk |

Viewed files are folded (`zo` opens one). `setup({ view = "split" })` picks
the view until you first toggle it.

## Develop

```sh
just check        # fmt, clippy, Rust tests, Lua specs
just test         # Rust tests only
just test-lua     # Lua specs only
just run --help   # the engine's commands
```

## Agent skills

Agent skills are not tracked in git, but `skills-lock.json` is.
`just skills-install` restores them after a clone.
