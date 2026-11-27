-- jpr: review GitHub pull requests in Neovim, backed by the jpr-review engine.
local dispatch = require("jpr.commands.dispatch")
local keymaps = require("jpr.keymaps")

local M = {}

--- Release version of the Neovim plugin, paired with the jpr-review binary.
M.VERSION = "0.8.0"

--- The options `setup` starts from; a user's options override any of them.
M.defaults = {
    -- Optional override path or command for the engine binary; nil uses the
    -- bundled `<plugin_root>/target/release/jpr-review` built by `build.lua`.
    binary = nil,
    -- A shell command that creates the PR worktree and prints its path; `{n}` is
    -- the PR number. nil uses the engine's default (git worktree + gh pr checkout).
    worktree_cmd = nil,
    -- Width of the PR panel.
    panel_width = 44,
    -- Interactive agent CLI for `:Jpr agent`, `:Jpr send`, and `:Jpr prepass`:
    -- "claude" or "codex".
    agent = "claude",
    -- Executable name, command string with flags, or argv list for Claude Code.
    claude_cmd = "claude",
    -- Claude Code model passed as `--model` when `claude_cmd` does not set one.
    -- nil omits the flag.
    claude_model = nil,
    -- Claude Code reasoning effort passed as `--effort` when `claude_cmd` does
    -- not set one. nil omits the flag.
    claude_effort = nil,
    -- Executable name, command string with flags, or argv list for Codex.
    codex_cmd = "codex",
    -- Layout direction for the coding agent terminal: "vertical", "horizontal",
    -- "float", or "tab".
    agent_direction = "vertical",
    -- Width in columns for vertical split; nil computes ~40% of editor columns.
    agent_width = nil,
    -- Whether to lazy-load toggleterm.nvim (if installed) before spawning the
    -- agent terminal so user TermOpen mappings and shading attach automatically.
    agent_load_toggleterm = true,
    -- The diff view until the reviewer flips it with :Jpr toggle, which is
    -- then remembered: "unified" or "split".
    view = "unified",
    -- Timeout in milliseconds for LSP workspace/willRenameFiles and willCreateFiles.
    lsp_file_ops_timeout_ms = 30000,
    -- Timeout in milliseconds to wait for an LSP client to attach on cold-start rename.
    lsp_attach_timeout_ms = 3000,
    -- Global (`palette`) and buffer-local keybindings; set any entry to false
    -- to disable it while keeping its `<Plug>(jpr-*)` mapping available.
    keys = {
        palette = "<leader>J",
        comment = "gc",
        suggest_comment = "gC",
        file_comment = "gf",
        pr_comment = "gp",
        full_diff = "gF",
        toggle_viewed = "gv",
        thread_popup = "gt",
        next_thread = "]t",
        prev_thread = "[t",
        send_agent = "gS",
        submit_review = "gs",
        toggle_agent = "ga",
        toggle_panel = "gP",
    },
}

--- The options in effect: the defaults merged with what `setup` was given.
--- Every module reads its settings from here.
M.config = vim.deepcopy(M.defaults)

--- The `:Jpr` subcommands, in the order completion offers them.
M.subcommands = require("jpr.commands.schema").list_command_ids()

--- Defines the plugin's highlight groups (semantic links and soft diff tints),
--- without replacing user overrides. Runs at `setup` and again when a review
--- starts, so the groups exist even without a `setup` call.
function M.define_highlights()
    require("jpr.highlights").define_highlights()
end

--- Binds the configured global `<Plug>(jpr-palette)` shortcut (default `<leader>J`),
--- removing any previous plugin-owned palette mapping when changed or disabled.
function M.bind_global_keys()
    keymaps.bind_global_keys(M.config)
end

--- Configures the plugin from a user's `opts` (see `defaults`), for example
--- from `require("jpr").setup({ worktree_cmd = "wt pr {n}" })`.
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
    M.define_highlights()
    M.bind_global_keys()
end

--- Active engine binary path or command, defaulting to the bundled release binary.
function M.binary_path()
    return require("jpr.binary").get_binary_path_from_config(M.config)
end

--- Binds review-wide session keys on `buf`, skipping any entry set to `false` or empty.
function M.bind_session_keys(buf)
    keymaps.bind_session_keys(M.config, buf)
end

--- Binds configured comment, thread, and review session keys in buffer `buf`.
function M.bind_buffer_keys(buf)
    keymaps.bind_buffer_keys(M.config, buf)
end

--- Binds `keys.full_diff` on a non-changed worktree buffer `buf` with an expr guard.
function M.bind_tab_aware_full_diff_key(buf)
    keymaps.bind_tab_aware_full_diff_key(M.config, buf)
end

--- Binds `keys.pr_comment` on a non-changed worktree buffer `buf` with an expr guard.
function M.bind_tab_aware_pr_comment_key(buf)
    keymaps.bind_tab_aware_pr_comment_key(M.config, buf)
end

--- Binds `keys.toggle_panel` on a non-changed worktree buffer `buf` with an expr guard.
function M.bind_tab_aware_toggle_panel_key(buf)
    keymaps.bind_tab_aware_toggle_panel_key(M.config, buf)
end

--- The PR number in a `:Jpr open` argument: `123`, `#123`, or a pull request URL.
M.parse_pr_arg = dispatch.parse_pr_arg

--- Completes `:Jpr <subcommand>` and schema-defined single-step arguments.
function M.complete(arglead, cmdline)
    return dispatch.complete(M.subcommands, arglead, cmdline)
end

--- Tells the user something failed, as a red top-right `jpr` toast.
function M.error(message)
    return require("jpr.notify").error(message)
end

--- Warns the user about a non-fatal condition, as an amber top-right `jpr` toast.
function M.warn(message)
    return require("jpr.notify").warn(message)
end

--- Confirms a user-initiated action succeeded, as a green top-right `jpr` toast.
function M.success(message)
    return require("jpr.notify").success(message)
end

--- Tells the user about an automatic update or status change, as a blue top-right `jpr` toast.
function M.info(message)
    return require("jpr.notify").info(message)
end

--- Starts an animated top-right progress toast and returns its lifecycle handle.
function M.progress(message, opts)
    return require("jpr.notify").progress(message, opts)
end

--- Short statusline summary for the current tab's review session, or `""`.
function M.statusline()
    local session_module = package.loaded["jpr.session"]
    if not session_module then
        return ""
    end
    return require("jpr.render.statusline").build_statusline_from_session(session_module.current())
end

--- Dispatches `:Jpr [subcommand [arg]]` with optional command options `cmd_opts`.
function M.command(fargs, cmd_opts)
    return dispatch.command(M, fargs, cmd_opts)
end

--- Dispatches a `<Plug>(jpr-*)` action `name` to the active review session.
function M.action(name)
    return dispatch.action(M, name)
end

return M
