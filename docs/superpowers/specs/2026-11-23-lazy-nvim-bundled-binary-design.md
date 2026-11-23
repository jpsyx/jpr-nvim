# Pure `lazy.nvim` Installation & Bundled Binary Design

## Goal

Make `jpr-nvim` installable and updatable purely through `lazy.nvim` (and compatible plugin managers) with **zero manual shell steps** and **no `install.sh`**. Adding `"jpsyx/jpr-nvim"` to a user's Neovim configuration must build and wire the `jpr-review` Rust engine automatically on install and `:Lazy update`, keep all artifacts self-contained inside the plugin directory, expose `:checkhealth jpr`, and support the interactive coding-agent CLI subcommands (`jpr-review guide`, `jpr-review reply`, `jpr-review threads`, `jpr-review prepass-write`) without polluting `~/.local/bin`.

## Scope

1. **`jpr-nvim` repository (`0.5.0`):**
   - Root `build.lua` + `lua/jpr/build.lua` for automatic `lazy.nvim` install/update builds.
   - Plugin-local binary resolution in `lua/jpr/binary.lua` (with `opts.binary` override preserved for custom paths and headless Lua test fixtures).
   - Automatic `PATH` injection in `lua/jpr/agent.lua` so coding-agent terminal splits find the bundled `jpr-review` binary.
   - `:checkhealth jpr` (`lua/jpr/health.lua`) following the standard Neovim binary-plugin convention.
   - Removal of `install.sh`, the `just install` recipe, and the finished Milestone 5 plan file (`docs/superpowers/plans/2026-11-22-jpr-nvim-m5-polish.md`).
   - Updated error hints and documentation (`README.md`, `docs/architecture.md`, `docs/decisions.md`, `docs/superpowers/specs/2026-11-19-jpr-nvim-design.md`).
2. **Publishing & `jpsyx-configs` integration (post-merge):**
   - Make `jpsyx/jpr-nvim` public on GitHub and push `main`.
   - Remove the stale manual `~/.local/bin/jpr-review` binary and obsolete `jpsyx-configs/docs/superpowers/plans/2026-11-19-jpr-host-integration.md`.
   - Add `home/.config/nvim/lua/plugins/jpr.lua` in `jpsyx-configs` installing `"jpsyx/jpr-nvim"` via `lazy.nvim` identically to any public user (plus `commands.yaml`, `lualine.lua` statusline component, `docs/plugins.md`, and `docs/CHANGELOG.md`).

## Architecture & Components

### 1. Root `build.lua` and `lua/jpr/build.lua`

`lazy.nvim` automatically detects and runs `<plugin_root>/build.lua` inside an async coroutine on plugin install, `:Lazy update`, and `:Lazy build jpr-nvim` whenever the user has not overridden `build = ...` in their plugin spec.

- **`build.lua` (repo root):**
  - Resolves `plugin_root` dynamically from `debug.getinfo(1, "S").source:sub(2)` without mutating Neovim's global `cwd` (safe under `lazy.nvim` parallel builds).
  - Prepends `plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;"` to `package.path` if `jpr.build` is not yet on runtimepath during initial install, then delegates to `require("jpr.build").build_release_binary(plugin_root)`.
- **`lua/jpr/build.lua`:**
  - `find_cargo_executable(env_table)`: checks `vim.fn.exepath("cargo")`; if empty (common when Neovim is launched from macOS Dock/GUI without shell `PATH`), checks `$CARGO_HOME/bin/cargo` and `~/.cargo/bin/cargo`.
  - When running inside a coroutine (`coroutine.running()` is non-nil and not the main thread), yields progress (`"Building jpr-review (cargo build --release)..."`) for the `lazy.nvim` UI.
  - Runs `{ cargo, "build", "--release", "-p", "jpr-review" }` via `vim.system(..., { cwd = plugin_root, env = cargo_env, text = true }):wait()` (ensuring `cargo`'s bin directory is on `env.PATH` so `rustc` is also found in GUI sessions).
  - Verifies `<plugin_root>/target/release/jpr-review` (or `.exe` on Windows) exists and is executable; raises `error(...)` with clear remediation (`Install a Rust toolchain from https://rustup.rs and run :Lazy build jpr-nvim`) if `cargo` is missing or compilation fails.

### 2. Plugin-Local Binary Discovery (`lua/jpr/binary.lua`)

- **`M.plugin_root()`:** resolves the root of the `jpr-nvim` checkout from `lua/jpr/binary.lua`'s own source path (`:p:h:h:h`).
- **`M.default_binary_path(root)`:** returns `<root>/target/release/jpr-review` (`.exe` on Windows).
- **`M.get_binary_path_from_config(config, root)`:**
  - If `config.binary` is a non-empty string, returns `config.binary` verbatim (preserving `FAKE_ENGINE` overrides in `tests/lua/*_spec.lua` and explicit user overrides).
  - Otherwise returns `M.default_binary_path(root)`.
- **`lua/jpr/init.lua`:**
  - `M.defaults.binary = nil` (defaulting to the bundled plugin-local binary via `binary.get_binary_path_from_config(M.config)`).
  - Exposes `M.binary_path()` convenience helper returning the active binary path/command.
- **`lua/jpr/session/init.lua`:**
  - Uses `jpr().binary_path()` everywhere `jpr().config.binary` was read (`checkout_args`, `M.open` executable check, `spawn_engine`, and `build_handshake_error_from_result`).
  - Updates missing-binary and version-mismatch error messages to instruct the user to run `:Lazy build jpr-nvim` (never `./install.sh`):
    - Missing binary: `"jpr-review binary not found at <path>; run :Lazy build jpr-nvim"`
    - Version mismatch: `"version mismatch: plugin is <v1> and <bin> is <v2>; run :Lazy build jpr-nvim"`

### 3. Agent Terminal `PATH` Injection (`lua/jpr/agent.lua`)

Coding agents launched in `:Jpr agent`, `:Jpr send`, and `:Jpr prepass` invoke `jpr-review guide`, `jpr-review threads`, `jpr-review reply`, and `jpr-review prepass-write` by bare command name (`jpr-review`).

- `M.build_agent_env_from_session(binary_path, socket, pr_number, current_path)`:
  - Computes `binary_dir = vim.fn.fnamemodify(binary_path, ":p:h")` whenever `binary_path` contains a path separator (`/` or `\`) and is executable.
  - Prepends `binary_dir` to `current_path` (`vim.env.PATH`) if not already the leading entry, returning `{ JPR_SOCKET = socket, JPR_PR = tostring(pr_number), PATH = updated_path }`.
  - Used by `spawn_terminal` in `lua/jpr/agent.lua` so the bundled `<plugin_root>/target/release/jpr-review` is always first on `PATH` inside the agent terminal, even if an older `jpr-review` exists elsewhere or `~/.local/bin` has nothing installed.

### 4. `:checkhealth jpr` (`lua/jpr/health.lua`)

Standard Neovim healthcheck module reporting:
- Neovim version (`>= 0.11`).
- Bundled/configured `jpr-review` binary path, executable status, and `jpr-review --version` lockstep check against `require("jpr").VERSION`.
- External tool checks: `git`, `gh` (and `gh auth status`), and `cargo` (for `:Lazy update` rebuilds).

### 5. Removal of `install.sh` & Documentation Updates

- Delete `install.sh` and remove the `install:` recipe from `justfile`.
- Delete finished `docs/superpowers/plans/2026-11-22-jpr-nvim-m5-polish.md`.
- Update `README.md` `## Install` so `lazy.nvim` is the sole installation method:
  ```lua
  {
    "jpsyx/jpr-nvim",
    cmd = "Jpr",
    opts = {},
  }
  ```
  Documenting that `lazy.nvim` automatically runs `build.lua` (`cargo build --release -p jpr-review`) on install and `:Lazy update`, and mentioning `:checkhealth jpr` and `:Lazy build jpr-nvim`.
- Update `docs/architecture.md` and append a decision entry to `docs/decisions.md` recording the move from standalone `install.sh` to `lazy.nvim` `build.lua` + plugin-local binary discovery and agent `PATH` injection.

## Error Handling

- **Missing Rust toolchain during `:Lazy install` / `:Lazy update`:** `build.lua` fails fast with a clear message naming `cargo` and `https://rustup.rs`.
- **GUI Neovim without `~/.cargo/bin` on `PATH`:** `find_cargo_executable` locates `~/.cargo/bin/cargo` (or `$CARGO_HOME/bin/cargo`) and prepends its directory to `env.PATH` for `cargo build` so `rustc` resolves cleanly.
- **User runs `:Jpr open` before `build.lua` has run (e.g. local `dir =` dev checkout):** `:Jpr open` reports the exact missing path and tells the user to run `:Lazy build jpr-nvim`.
- **Out-of-sync binary after switching git branches locally:** Handshake catches version/protocol mismatch and tells the user to run `:Lazy build jpr-nvim`.

## Testing

- **`tests/lua/build_and_binary_spec.lua` (new headless Neovim spec):**
  - Default `binary.get_binary_path_from_config` resolves `<plugin_root>/target/release/jpr-review` when `config.binary == nil` and honors explicit `config.binary` overrides.
  - `build.find_cargo_executable` finds `cargo` on `PATH` and falls back to `CARGO_HOME` / `~/.cargo/bin` when `PATH` is empty.
  - `build.build_release_binary` invokes `cargo build --release -p jpr-review` in `plugin_root` (tested against a temporary fake `cargo` script so unit specs stay sub-second) and errors cleanly when `cargo` fails or produces no executable.
  - `agent.build_agent_env_from_session` prepends the bundled binary directory to `PATH` while preserving `JPR_SOCKET` and `JPR_PR`.
  - `:checkhealth jpr` (`lua/jpr/health.lua`) runs without error against fake `vim.health` reporters.
- Update existing `tests/lua/command_spec.lua` and `tests/lua/session_lifecycle_spec.lua` assertions for `config.binary == nil` default, `jpr.binary_path()`, and `:Lazy build jpr-nvim` hint text.
- Full `just check` green + end-to-end `:Lazy sync` + `:checkhealth jpr` verification once wired into `jpsyx-configs`.
