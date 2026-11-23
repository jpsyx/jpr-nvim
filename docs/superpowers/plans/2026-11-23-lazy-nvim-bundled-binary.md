# Pure `lazy.nvim` Bundled Binary Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `jpr-nvim` installable and updatable purely through `lazy.nvim` (`"jpsyx/jpr-nvim"`) via a root `build.lua`, plugin-local `target/release/jpr-review` binary discovery, coding-agent `PATH` injection, and `:checkhealth jpr`, removing `install.sh` completely and installing `jpsyx/jpr-nvim` in `jpsyx-configs` identically to any public user.

**Architecture:** `build.lua` at the repository root delegates to `lua/jpr/build.lua`, which locates `cargo` (including `~/.cargo/bin` fallback for GUI Neovim) and compiles `target/release/jpr-review` inside the plugin directory without changing Neovim's global `cwd`. `lua/jpr/binary.lua` resolves that bundled binary by default (preserving `opts.binary` overrides for tests and custom builds), `lua/jpr/agent.lua` prepends its directory to `PATH` inside `:Jpr agent` terminals so `jpr-review` subcommands work with zero `~/.local/bin` footprint, and `lua/jpr/health.lua` implements `:checkhealth jpr`.

**Tech Stack:** Neovim 0.11+ Lua (`vim.system`, `vim.health`), `lazy.nvim` `build.lua` coroutine convention, Rust (`cargo build --release -p jpr-review`), `gh` CLI.

---

## File Structure

### Part A - `jpr-nvim` (in isolated `wt new feat/lazy-build` worktree)
- Create: `lua/jpr/binary.lua`: resolves the plugin checkout root, bundled `target/release/jpr-review` path, `opts.binary` override, and agent `PATH` prepending helper.
- Create: `lua/jpr/build.lua`: finds `cargo` (with `$CARGO_HOME/bin` and `~/.cargo/bin` fallback), reports progress to `lazy.nvim` coroutine when active, runs `cargo build --release -p jpr-review` in `plugin_root`, and validates the resulting executable.
- Create: `build.lua`: root `lazy.nvim` build hook delegating to `lua/jpr/build.lua` without mutating global `cwd`.
- Create: `lua/jpr/health.lua`: `:checkhealth jpr` checks for Neovim `>= 0.11`, bundled/configured `jpr-review` binary + version lockstep, `git`, `gh`, and `cargo`.
- Modify: `lua/jpr/init.lua`: change `M.defaults.binary = nil` (defaulting to bundled binary), add `M.binary_path()`.
- Modify: `lua/jpr/session/init.lua`: read `jpr().binary_path()` across `checkout_args`, `M.open`, `spawn_engine`, and `build_handshake_error_from_result`, updating remediation messages from `./install.sh` to `:Lazy build jpr-nvim`.
- Modify: `lua/jpr/agent.lua`: use `binary.build_agent_env_from_session(...)` in `spawn_terminal` so `<plugin_root>/target/release` is prepended to `PATH` inside agent terminals.
- Create: `tests/lua/build_and_binary_spec.lua`: headless Neovim spec testing `binary.lua`, `build.lua` (with fake `cargo`), `build.lua` root entrypoint, `agent.lua` `PATH` prepending, and `health.lua`.
- Modify: `tests/lua/command_spec.lua`: assert `jpr.config.binary == nil` by default and `jpr.binary_path()` points to `<root>/target/release/jpr-review` while honoring explicit `setup({ binary = ... })`.
- Modify: `tests/lua/session_lifecycle_spec.lua`: assert version-mismatch remediation names `:Lazy build jpr-nvim` instead of `./install.sh`, and missing bundled binary in `session.open` names `:Lazy build jpr-nvim`.
- Delete: `install.sh`: removed completely.
- Delete: `docs/superpowers/plans/2026-11-22-jpr-nvim-m5-polish.md`: finished M5 plan removed before making repo public.
- Modify: `justfile`: remove `install:` recipe referencing `./install.sh`.
- Modify: `README.md`, `docs/architecture.md`, `docs/decisions.md` (append-only), `docs/superpowers/specs/2026-11-19-jpr-nvim-design.md`: document pure `lazy.nvim` installation, `build.lua`, `:checkhealth jpr`, and bundled binary layout.

### Part B - Publish `jpsyx/jpr-nvim` & Wire `jpsyx-configs` (after Part A merges to `main`)
- Push `jpr-nvim` `main` to `origin` and make `jpsyx/jpr-nvim` public on GitHub.
- Remove stale manual `~/.local/bin/jpr-review` (`0.3.0`).
- In `/Users/pablo/src/jpsyx/jpsyx-configs`:
  - Delete obsolete `docs/superpowers/plans/2026-11-19-jpr-host-integration.md`.
  - Create `home/.config/nvim/lua/plugins/jpr.lua` (`"jpsyx/jpr-nvim"`, `cmd = "Jpr"`, `opts = { worktree_cmd = "wt pr {n}" }`).
  - Modify `home/.config/nvim/lua/plugins/lualine.lua` to show `require("jpr").statusline()` in `lualine_x` when non-empty (lazy-safe: only calls `require("jpr").statusline()` if `package.loaded["jpr"]` is loaded!).
  - Modify `home/.config/nvim/commands.yaml`, `home/.config/nvim/docs/plugins.md`, and `home/.config/nvim/docs/CHANGELOG.md`.
  - Run `jpsyx build && jpsyx sync`, run headless `lazy.nvim` install/sync so `lazy.nvim` clones `jpsyx/jpr-nvim` and runs `build.lua` to compile `target/release/jpr-review` (`0.5.0`), and verify `:Jpr` + `:checkhealth jpr` + `jpsyx status`.

---

### Task 0: Create Isolated Worktree in `jpr-nvim`

- [ ] **Step 1: Create `feat/lazy-build` worktree via `wt`**

Run in `/Users/pablo/src/jpsyx/jpr-nvim`:
```bash
wt new feat/lazy-build
```
Expected: creates and prints the worktree path (e.g. `/Users/pablo/src/jpsyx/jpr-nvim/.worktrees/jpsyx/feat/lazy-build`). Verify `just check` passes cleanly inside that worktree before making edits.

---

### Task 1: Bundled Binary Discovery, `build.lua`, Agent `PATH` & `:checkhealth jpr`

**Files:**
- Create: `lua/jpr/binary.lua`
- Create: `lua/jpr/build.lua`
- Create: `build.lua`
- Create: `lua/jpr/health.lua`
- Modify: `lua/jpr/init.lua`
- Modify: `lua/jpr/session/init.lua`
- Modify: `lua/jpr/agent.lua`
- Create: `tests/lua/build_and_binary_spec.lua`
- Modify: `tests/lua/command_spec.lua`
- Modify: `tests/lua/session_lifecycle_spec.lua`

- [ ] **Step 1: Write failing spec `tests/lua/build_and_binary_spec.lua` and update `command_spec.lua` & `session_lifecycle_spec.lua`**

Create `tests/lua/build_and_binary_spec.lua` testing:
1. `binary.plugin_root()` equals repo `root`, `binary.default_binary_path(root)` equals `root .. "/target/release/jpr-review"`, `binary.get_binary_path_from_config({})` returns that default path, and `binary.get_binary_path_from_config({ binary = "/custom/jpr-review" })` returns `"/custom/jpr-review"`.
2. `binary.build_agent_env_from_session(fake_bin, "/tmp/jpr.sock", 42, "/usr/bin:/bin")` prepends `vim.fn.fnamemodify(fake_bin, ":p:h")` to `PATH` when `fake_bin` is an executable path, avoids duplicating it if already first on `PATH`, and leaves `PATH` unchanged when `binary_path` has no directory separator.
3. `build.find_cargo_executable({ PATH = "", CARGO_HOME = fake_cargo_home }, fake_home)` finds `fake_cargo_home .. "/bin/cargo"`, and falls back to `fake_home .. "/.cargo/bin/cargo"` when `CARGO_HOME` is unset.
4. Executing root `dofile(root .. "/build.lua")` inside a temporary fake plugin root with a fake `cargo` script writes `<temp_root>/target/release/jpr-review` with `build --release -p jpr-review` arguments, and raises an actionable error mentioning `https://rustup.rs` when `cargo` is absent or exits non-zero.
5. `require("jpr.health").check()` reports `ok` when `jpr.setup({ binary = fake_version_binary })` points at an executable printing `jpr-review 0.5.0` and reports `error` mentioning `:Lazy build jpr-nvim` when the binary is missing or prints a mismatched version.

Update `tests/lua/command_spec.lua`:
- `assert(jpr.config.binary == nil, "setup keeps nil default binary so bundled target/release/jpr-review is used")`
- `assert(jpr.binary_path() == root .. "/target/release/jpr-review", "binary_path resolves bundled release binary")`

Update `tests/lua/session_lifecycle_spec.lua`:
- Assert version mismatch error message contains `:Lazy build jpr-nvim` (instead of `./install.sh`).
- Add assertion that `session.open(99)` with a missing default binary path reports `:Lazy build jpr-nvim`.

- [ ] **Step 2: Run `./scripts/test-lua.sh` to verify RED failures**

Run: `./scripts/test-lua.sh`
Expected: FAIL on missing `jpr.binary` / `build_and_binary_spec.lua`.

- [ ] **Step 3: Implement `lua/jpr/binary.lua`, `lua/jpr/build.lua`, `build.lua`, `lua/jpr/health.lua`, and wire `init.lua`, `session/init.lua`, and `agent.lua`**

Keep every function `<= 45` lines, every file `<= 400` lines, and zero em dashes (`\u2014`):
- `lua/jpr/binary.lua`:
  - `M.binary_filename(is_windows)` -> `"jpr-review.exe"` or `"jpr-review"`.
  - `M.plugin_root()` -> `vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")`.
  - `M.default_binary_path(plugin_root, is_windows)` -> `(plugin_root or M.plugin_root()) .. "/target/release/" .. M.binary_filename(is_windows)`.
  - `M.get_binary_path_from_config(config, plugin_root)` -> returns `config.binary` when `type(config) == "table" and type(config.binary) == "string" and config.binary ~= ""`, else `M.default_binary_path(plugin_root)`.
  - `M.build_agent_env_from_session(binary_path, socket, pr_number, current_path)` -> builds `{ JPR_SOCKET = socket, JPR_PR = tostring(pr_number), PATH = ... }` prepending `vim.fn.fnamemodify(binary_path, ":p:h")` when `binary_path` contains `/` or `\` and `vim.fn.executable(binary_path) == 1`.
- `lua/jpr/build.lua`:
  - `M.find_cargo_executable(env_map, home_dir)` -> checks `PATH` in `env_map` (via `vim.fn.exepath("cargo")` when `env_map == nil`, or scanning `env_map.PATH`), then `CARGO_HOME/bin/cargo`, then `<home_dir>/.cargo/bin/cargo`.
  - `M.build_release_binary(plugin_root, opts)` -> yields progress if inside a non-main coroutine, spawns `{ cargo, "build", "--release", "-p", "jpr-review" }` with `cwd = root` and `cargo`'s directory prepended to `env.PATH`, checks exit code and executable output at `binary.default_binary_path(root)`, and raises clear `error(...)` on failure.
- `build.lua`:
  - Resolves `root` from `debug.getinfo(1, "S").source:sub(2)`, ensures `root .. "/lua/?.lua;"` is in `package.path`, and calls `require("jpr.build").build_release_binary(root)`.
- `lua/jpr/health.lua`:
  - Implements `M.check()` using `vim.health.start`, `vim.health.ok`, `vim.health.warn`, and `vim.health.error` (checking Neovim `>= 0.11`, binary executable + `--version` matching `jpr.VERSION`, `git`, `gh`, and `cargo`).
- `lua/jpr/init.lua`:
  - Set `M.defaults.binary = nil` and add `function M.binary_path() return require("jpr.binary").get_binary_path_from_config(M.config) end`.
- `lua/jpr/session/init.lua`:
  - Replace `jpr().config.binary` reads with `jpr().binary_path()`.
  - When `vim.fn.executable(binary_path) ~= 1` in `M.open`, report `("jpr-review binary not found at %s; run :Lazy build jpr-nvim"):format(binary_path)`.
  - In `build_handshake_error_from_result`, report `("version mismatch: plugin is %s and %s is %s; run :Lazy build jpr-nvim"):format(...)`.
- `lua/jpr/agent.lua`:
  - Pass `env = require("jpr.binary").build_agent_env_from_session(jpr().binary_path(), socket, session.number, vim.env.PATH)` to `jobstart` in `spawn_terminal`.

- [ ] **Step 4: Run `just check` to verify GREEN**

Run: `just check`
Expected: PASS (all Rust tests, clippy, fmt, and all 23 headless Lua specs including `build_and_binary_spec: ok`).

- [ ] **Step 5: Commit Task 1**

```bash
git add build.lua lua/jpr/binary.lua lua/jpr/build.lua lua/jpr/health.lua lua/jpr/init.lua lua/jpr/session/init.lua lua/jpr/agent.lua tests/lua/build_and_binary_spec.lua tests/lua/command_spec.lua tests/lua/session_lifecycle_spec.lua
git commit -m "feat(nvim): build and resolve bundled jpr-review via lazy.nvim build.lua"
```

---

### Task 2: Remove `install.sh`, Clean Finished Plan, and Update Documentation

**Files:**
- Delete: `install.sh`
- Delete: `docs/superpowers/plans/2026-11-22-jpr-nvim-m5-polish.md`
- Modify: `justfile`
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/decisions.md` (append-only at bottom!)
- Modify: `docs/superpowers/specs/2026-11-19-jpr-nvim-design.md`

- [ ] **Step 1: Delete `install.sh` and finished M5 plan, and remove `install:` from `justfile`**

Remove `install.sh`, `docs/superpowers/plans/2026-11-22-jpr-nvim-m5-polish.md`, and the `install:` recipe from `justfile`.

- [ ] **Step 2: Update `README.md`, `docs/architecture.md`, `docs/decisions.md`, and `docs/superpowers/specs/2026-11-19-jpr-nvim-design.md`**

- `README.md`:
  - Replace `./install.sh` and `dir = "/path/to/jpr-nvim"` with standard `lazy.nvim` installation:
    ```lua
    {
      "jpsyx/jpr-nvim",
      cmd = "Jpr",
      opts = {
        -- Optional: custom worktree command (`{n}` is the PR number).
        -- worktree_cmd = "my-worktree-tool pr {n}",
        -- Optional: initial diff view ("unified" or "split").
        -- view = "split",
        -- Optional: coding agent ("claude" or "codex").
        -- agent = "claude",
      },
    }
    ```
  - Explain that `lazy.nvim` automatically runs `build.lua` (`cargo build --release -p jpr-review`) on install and `:Lazy update`, keeping the compiled engine inside the plugin directory with zero manual steps, and mention `:checkhealth jpr` and `:Lazy build jpr-nvim`.
- `docs/architecture.md`:
  - Update the repository layout and Neovim frontend module list to include `build.lua`, `lua/jpr/binary.lua`, `lua/jpr/build.lua`, and `lua/jpr/health.lua`, and replace any `install.sh` mention with `build.lua`.
- `docs/decisions.md`:
  - Strictly append a new decision at the bottom explaining why `build.lua` + plugin-local `target/release/jpr-review` + agent `PATH` injection replaced standalone `install.sh`.
- `docs/superpowers/specs/2026-11-19-jpr-nvim-design.md`:
  - Update the historical `install.sh` note to note `build.lua` via `lazy.nvim` so nothing confuses future readers.

- [ ] **Step 3: Verify `just check`, zero em dashes, and zero remaining `install.sh` references in active docs/code**

Run:
```bash
just check
! rg "\x{2014}" Cargo.toml crates lua plugin tests docs README.md build.lua
git diff --numstat main..HEAD -- docs/decisions.md
```
Expected: `just check` passes, 0 em dashes, `docs/decisions.md` has `0` deletions.

- [ ] **Step 4: Commit Task 2**

```bash
git add -A
git commit -m "docs: replace install.sh with zero-step lazy.nvim installation"
```

---

### Task 3: Post-Implementation Quality Gate (`/avandar-code-review` + Full `/diff-review`) & Merge to `main`

- [ ] **Step 1: Run `/avandar-code-review` across `main...HEAD`**

Fix any findings on `+` lines, verify every touched `.lua`/`.rs` file `<= 400` lines and every function `<= 45` lines, run `just check`, and commit if needed.

- [ ] **Step 2: Run full `/diff-review` (Initial mode) and archive walkthrough**

Generate `.difit/` review artifacts + `.difit/feat-lazy-build-difit-at-main-walkthrough.md`, copy the walkthrough to `docs/code-walkthroughs/2026-11-23_lazy-nvim-bundled-binary.md`, verify zero em dashes and `just check`, and commit `docs(walkthrough): add lazy.nvim bundled binary walkthrough`.

---

### Task 4: Publish `jpsyx/jpr-nvim` & Install via `lazy.nvim` in `jpsyx-configs` (Post-Approval / Integration)

- [ ] **Step 1: Remove finished plan, merge `feat/lazy-build` into `main`, push `jpr-nvim` `main`, and make `jpsyx/jpr-nvim` public**

- Merge `feat/lazy-build` to `main`, delete the finished plan file from `docs/superpowers/plans/`, push `origin main`, and run:
  ```bash
  gh repo edit jpsyx/jpr-nvim --visibility public --accept-visibility-change-consequences
  rm -f ~/.local/bin/jpr-review
  ```

- [ ] **Step 2: Configure `"jpsyx/jpr-nvim"` in `jpsyx-configs` like any public `lazy.nvim` plugin**

In `/Users/pablo/src/jpsyx/jpsyx-configs`:
1. Delete obsolete `docs/superpowers/plans/2026-11-19-jpr-host-integration.md`.
2. Create `home/.config/nvim/lua/plugins/jpr.lua`:
   ```lua
   -- Pull request review in Neovim; lazy.nvim runs build.lua to compile jpr-review.
   return {
   	"jpsyx/jpr-nvim",
   	cmd = "Jpr",
   	opts = {
   		worktree_cmd = "wt pr {n}",
   	},
   }
   ```
3. Add a lazy-safe statusline component in `home/.config/nvim/lua/plugins/lualine.lua` (`lualine_x`) that checks `package.loaded["jpr"]` so `jpr` stays lazy-loaded until `:Jpr` runs.
4. Add `jpr-nvim-jpr` in `home/.config/nvim/commands.yaml`, document `jpsyx/jpr-nvim` in `home/.config/nvim/docs/plugins.md`, and add an entry in `home/.config/nvim/docs/CHANGELOG.md`.
5. Run `jpsyx build && jpsyx sync`, run `nvim --headless "+Lazy! sync" +qa` so `lazy.nvim` clones `https://github.com/jpsyx/jpr-nvim` and runs `build.lua` to compile `target/release/jpr-review`, verify `:Jpr` and `:checkhealth jpr` in headless Neovim, and commit + push `jpsyx-configs`.
