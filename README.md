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
      -- Optional: coding agent for :Jpr agent, :Jpr send, and :Jpr prepass:
      -- "claude" (the default) or "codex".
      -- agent = "claude",
      -- claude_cmd = "claude",
      -- codex_cmd = "codex",
      -- agent_width = 56,
      -- Optional: override or disable (false) diff/stream comment & thread keys.
      -- keys = {
      --   comment = "gc",
      --   suggest_comment = "gC",
      --   file_comment = "gf",
      --   thread_popup = "gt",
      --   next_thread = "]t",
      --   prev_thread = "[t",
      -- },
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
| `:[range]Jpr comment` | Open the compose float for a draft or local comment on the cursor line or visual range |
| `:Jpr suggest` | Turn an uncommitted edit around the cursor into a GitHub draft suggestion and revert just that hunk |
| `:Jpr expand` | Toggle inline expansion of review thread messages across diff and stream buffers |
| `:Jpr conversation` | Open the top-level PR conversation view beside the panel |
| `:Jpr submit` | Open the review submission modal (`COMMENT`, `APPROVE`, or `REQUEST_CHANGES`) |
| `:Jpr agent` | Toggle the coding-agent terminal split on the right (keeps the session running when hidden) |
| `:Jpr send` | Dispatch all unsent local threads to the coding agent in a numbered round |
| `:Jpr prepass` | Dispatch a pre-pass review prompt asking the agent to write local findings via `jpr-review prepass-write` |
| `:Jpr close` | Stop the engine and close the tab |

In the panel, `<CR>` opens the PR conversation view on the `Conversation` row
or opens the file under the cursor from the worktree, and `v` toggles it viewed.

In the stream:

| Key | What it does |
| --- | --- |
| `<CR>` | Open the file at that line |
| `v` | Toggle viewed and move to the next unviewed file |
| `]f` / `[f` | Next / previous file |
| `]h` / `[h` | Next / previous hunk |

Viewed files are folded (`zo` opens one). `setup({ view = "split" })` picks
the view until you first toggle it.

In both changed diff buffers (and their base split buffers) and the stream:

| Key | `<Plug>` mapping | What it does |
| --- | --- | --- |
| `gc` (normal/visual) | `<Plug>(jpr-comment)` | New draft or local comment on the cursor line or visual range |
| `gC` (normal/visual) | `<Plug>(jpr-suggest-comment)` | New draft comment pre-filled with a `suggestion` block |
| `gf` | `<Plug>(jpr-file-comment)` | New file-level draft or local comment |
| `gt` | `<Plug>(jpr-thread-popup)` | Open the floating thread popup at the cursor |
| `]t` / `[t` | `<Plug>(jpr-next-thread)` / `<Plug>(jpr-prev-thread)` | Jump to the next / previous review thread |

Set any entry in `setup({ keys = { ... } })` to `false` (or another key) to
disable or remap the default buffer-local binding while keeping the
`<Plug>(jpr-...)` mappings available.

Inside the comment and review windows:

- **Thread popup (`gt`)**: `r` reply, `e` edit own comment, `d` delete own
  comment, `R` resolve/unresolve thread, `p` promote local thread to GitHub,
  `s` send local thread to agent, `+` toggle reaction, `X` retry failed
  message, `q` or `<Esc>` close.
- **Compose float**: `<C-s>` (normal/insert) save/submit to the active target
  (`github` or `local`), `<C-g>` (normal/insert) flip target between GitHub and
  local (remembered per session), `<M-s>` (normal/insert) submit once to the
  alternate target, `<C-g>s` (insert) insert a `suggestion` fence pre-filled
  from the anchored lines, `<C-x><C-o>` (or `nvim-cmp` source `jpr_mentions`)
  for `@mention` completion, `q` or `<Esc>` (normal) cancel.
- **PR conversation (`:Jpr conversation`)**: `c` new PR comment, `r` reply to
  local PR thread, `e` edit own comment, `d` delete own comment, `p` promote
  local PR thread to GitHub, `s` send local PR thread to agent, `+` toggle
  reaction, `X` retry failed comment, `q` close.
- **Submit modal (`:Jpr submit`)**: `1` Comment, `2` Approve, `3` Request
  changes, `e` edit review summary (`<C-s>` save, `q`/`<Esc>` cancel), `<CR>`
  jump to draft under cursor or submit, `<C-s>` submit review, `q` or `<Esc>`
  close.

All highlight groups link to standard Neovim groups with `default = true` so
your colorscheme can override them. Local threads use `JprThreadLocal` (linked
to `DiagnosticHint`).

## Agent CLI

The coding agent running inside `:Jpr agent` receives `JPR_SOCKET` and `JPR_PR`
in its environment and drives local review threads through `jpr-review`:

```sh
jpr-review guide                                   # print agent workflow & rules
jpr-review threads --local                         # list local threads as JSON
jpr-review reply <thread-id> --body "..."          # answer a local thread
jpr-review prepass-write --input findings.json     # write answered pre-pass threads
```

All three thread commands talk to the running `jpr-review serve` Unix domain
socket first so Neovim redraws immediately; when no daemon is running, `threads`
falls back to reading the on-disk store while `reply` and `prepass-write`
mutate `local.json` under `local.lock`.

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
