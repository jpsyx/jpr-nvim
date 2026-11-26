-- jpr: review GitHub pull requests in Neovim, backed by the jpr-review engine.
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
        thread_popup = "gt",
        next_thread = "]t",
        prev_thread = "[t",
        send_agent = "gS",
        submit_review = "gs",
        toggle_agent = "ga",
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

local bound_palette_key = M.defaults.keys.palette

--- Binds the configured global `<Plug>(jpr-palette)` shortcut (default `<leader>J`),
--- removing any previous plugin-owned palette mapping when changed or disabled.
function M.bind_global_keys()
    if type(bound_palette_key) == "string" and bound_palette_key ~= "" then
        local existing = vim.fn.maparg(bound_palette_key, "n", false, true)
        if existing and existing.rhs == "<Plug>(jpr-palette)" then
            pcall(vim.keymap.del, "n", bound_palette_key)
        end
    end
    bound_palette_key = nil
    local palette_key = M.config.keys and M.config.keys.palette
    if type(palette_key) == "string" and palette_key ~= "" then
        vim.keymap.set("n", palette_key, "<Plug>(jpr-palette)", {
            remap = true,
            silent = true,
            desc = "Open Jpr command palette",
        })
        bound_palette_key = palette_key
    end
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

local function bind_plug_key(buf, modes, lhs, plug, desc)
    if type(lhs) == "string" and lhs ~= "" then
        vim.keymap.set(
            modes,
            lhs,
            plug,
            { buffer = buf, remap = true, silent = true, nowait = true, desc = desc }
        )
    end
end

--- Binds review-wide session keys (`send_agent`, `submit_review`,
--- `toggle_agent`) on `buf`, skipping any entry set to `false` or empty.
function M.bind_session_keys(buf)
    local keys = M.config.keys or {}
    bind_plug_key(buf, "n", keys.send_agent, "<Plug>(jpr-send-agent)", "Send local threads to coding agent")
    bind_plug_key(buf, "n", keys.submit_review, "<Plug>(jpr-submit-review)", "Open GitHub review submission modal")
    bind_plug_key(buf, "n", keys.toggle_agent, "<Plug>(jpr-toggle-agent)", "Toggle coding agent terminal panel")
end

--- Binds configured comment, thread, and review session keys in buffer `buf`
--- to their `<Plug>(jpr-*)` mappings, skipping any entry set to `false`.
function M.bind_buffer_keys(buf)
    local keys = M.config.keys or {}
    bind_plug_key(buf, { "n", "x" }, keys.comment, "<Plug>(jpr-comment)", "New GitHub draft comment")
    bind_plug_key(buf, { "n", "x" }, keys.suggest_comment, "<Plug>(jpr-suggest-comment)", "New GitHub suggestion comment")
    bind_plug_key(buf, "n", keys.file_comment, "<Plug>(jpr-file-comment)", "New file-level GitHub comment")
    bind_plug_key(buf, "n", keys.thread_popup, "<Plug>(jpr-thread-popup)", "Open review thread popup")
    bind_plug_key(buf, "n", keys.next_thread, "<Plug>(jpr-next-thread)", "Next review thread")
    bind_plug_key(buf, "n", keys.prev_thread, "<Plug>(jpr-prev-thread)", "Previous review thread")
    M.bind_session_keys(buf)
end

--- The PR number in a `:Jpr open` argument: `123`, `#123`, or a pull request
--- URL. A URL also gives its repository as a second value, `owner/name`.
function M.parse_pr_arg(arg)
    if type(arg) ~= "string" then
        return nil
    end
    local repo, url_number = arg:match("^%a+://[^/]+/([^/]+/[^/]+)/pull/(%d+)")
    local raw_number = url_number or arg:match("^#?(%d+)$") or arg:match("/pull/(%d+)")
    local parsed_number = raw_number and tonumber(raw_number) or nil
    if not parsed_number or parsed_number < 1 then
        return nil
    end
    return parsed_number, repo
end

local function filter_by_prefix(items, prefix)
    return vim.tbl_filter(function(name)
        return vim.startswith(name, prefix)
    end, items)
end

local function slice_from_jpr_command(cmdline)
    local raw = cmdline or ""
    local start_index = raw:find("%f[%a]Jpr%f[%A]")
    if start_index then
        return raw:sub(start_index)
    end
    return raw
end

--- Completes `:Jpr <subcommand>` and schema-defined single-step arguments
--- (`toggle`, `comment`, `agent`).
function M.complete(arglead, cmdline)
    local command_tail = slice_from_jpr_command(cmdline)
    local trimmed = vim.trim(command_tail)
    local words = trimmed ~= "" and vim.split(trimmed, "%s+") or {}
    local has_trailing_space = command_tail:match("%s$") ~= nil
    local token_index = has_trailing_space and (#words + 1) or #words
    if token_index <= 2 then
        return filter_by_prefix(M.subcommands, arglead or "")
    end
    if token_index == 3 then
        local candidates = require("jpr.commands.schema").subcommand_arg_completions(words[2])
        return filter_by_prefix(candidates, arglead or "")
    end
    return {}
end

--- Tells the user something failed, as a `jpr:` error notification.
function M.error(message)
    vim.notify("jpr: " .. message, vim.log.levels.ERROR)
end

--- Warns the user about a non-fatal condition, as a `jpr:` warning notification.
function M.warn(message)
    vim.notify("jpr: " .. message, vim.log.levels.WARN)
end

--- Tells the user what the plugin is doing, as a `jpr:` notification.
function M.info(message)
    vim.notify("jpr: " .. message, vim.log.levels.INFO)
end

--- Short statusline summary for the current tab's review session, or `""`.
function M.statusline()
    local session_module = package.loaded["jpr.session"]
    if not session_module then
        return ""
    end
    return require("jpr.render.statusline").build_statusline_from_session(session_module.current())
end

local function build_tui_context(session, cmd_opts)
    return require("jpr.tui.context").create_context_from_session(session, cmd_opts)
end

local function open_pr_picker_for_context(context)
    local open_spec = require("jpr.commands.schema").find_command_spec("open")
    return require("jpr.tui.wizard").open_command(open_spec, { source = "list" }, context, { start_step_id = "pr" })
end

local function dispatch_open_subcommand(session, argument, context)
    if argument == nil or argument == "" then
        if not context.has_session and not require("jpr.repo_picker").is_git_repo(vim.fn.getcwd()) then
            return require("jpr.repo_picker").pick(function(selected_repo)
                local repo_context = vim.tbl_extend("force", context, {
                    is_git_repo = false,
                    repo = selected_repo,
                })
                open_pr_picker_for_context(repo_context)
            end)
        end
        return open_pr_picker_for_context(context)
    end
    local number, repo = M.parse_pr_arg(argument)
    if not number then
        return M.error(("invalid pull request %q; expected a PR number, #number, or pull request URL"):format(argument))
    end
    return session.open(number, repo)
end

local function dispatch_validated_arg(subcommand, argument, label, on_valid)
    local valid_values = require("jpr.commands.schema").subcommand_arg_completions(subcommand)
    if vim.tbl_contains(valid_values, argument) then
        return on_valid(argument)
    end
    return M.error(("invalid %s %q; expected one of: %s"):format(label, tostring(argument), table.concat(valid_values, ", ")))
end

local function dispatch_comment_subcommand(session, argument, cmd_opts, context)
    if argument == nil or argument == "" then
        return session.comment_current(cmd_opts)
    end
    return dispatch_validated_arg("comment", argument, "comment scope", function(kind)
        local comment_spec = require("jpr.commands.schema").find_command_spec("comment")
        return comment_spec.execute({ kind = kind }, context)
    end)
end

local function dispatch_optional_arg_subcommand(session, subcommand, argument, cmd_opts, context)
    if subcommand == "open" then
        return dispatch_open_subcommand(session, argument, context)
    end
    if subcommand == "local" then
        local base_ref = (type(argument) == "string" and vim.trim(argument) ~= "") and vim.trim(argument) or nil
        return session.open_local(base_ref)
    end
    if subcommand == "toggle" then
        if argument == nil or argument == "" then
            return session.toggle_view()
        end
        return dispatch_validated_arg("toggle", argument, "diff view", session.set_view_mode)
    end
    if subcommand == "comment" then
        return dispatch_comment_subcommand(session, argument, cmd_opts, context)
    end
    if subcommand == "agent" then
        if argument == nil or argument == "" then
            return session.agent_current()
        end
        return dispatch_validated_arg("agent", argument, "agent", session.agent_current)
    end
    return nil
end

local OPTIONAL_ARG_SUBCOMMANDS = { open = true, ["local"] = true, toggle = true, comment = true, agent = true }
local ZERO_ARG_SESSION_METHODS = {
    sync = "sync_current",
    stream = "stream_current",
    suggest = "suggest_current",
    expand = "expand_current",
    conversation = "conversation_current",
    submit = "submit_current",
    push = "push_current",
    send = "send_current",
    prepass = "prepass_current",
    close = "close_current",
}

local function is_numeric_pr_attempt(token)
    if type(token) ~= "string" then
        return false
    end
    return tonumber(token) ~= nil or token:match("^#%-?%d") ~= nil
end

local function dispatch_direct_subcommand(session, args, cmd_opts, context)
    local subcommand = args[1]
    if subcommand == "keys" then
        if #args > 1 then
            return M.error(":Jpr keys does not accept arguments")
        end
        return require("jpr.views.cheatsheet").open()
    end
    if OPTIONAL_ARG_SUBCOMMANDS[subcommand] then
        if #args > 2 then
            return M.error(("too many arguments for :Jpr %s"):format(subcommand))
        end
        return dispatch_optional_arg_subcommand(session, subcommand, args[2], cmd_opts, context)
    end
    local method_name = ZERO_ARG_SESSION_METHODS[subcommand]
    if method_name then
        if #args > 1 then
            return M.error((":Jpr %s does not accept arguments"):format(subcommand))
        end
        return session[method_name]()
    end
    local pr_number, pr_repo = M.parse_pr_arg(subcommand)
    if pr_number then
        if #args > 1 then
            return M.error(("too many arguments for :Jpr %s"):format(subcommand))
        end
        return session.open(pr_number, pr_repo)
    end
    if is_numeric_pr_attempt(subcommand) then
        return M.error(("invalid pull request %q; expected a positive PR number, #number, or pull request URL"):format(subcommand))
    end
    M.error(("unknown subcommand %q; expected one of: %s"):format(tostring(subcommand), table.concat(M.subcommands, ", ")))
end

--- Rewrites a leading command alias to its canonical id, leaving real
--- subcommands and unknown names unchanged.
local function canonicalize_command_args(args)
    if type(args[1]) ~= "string" then
        return args
    end
    local resolved = require("jpr.commands.schema").resolve_command_id(args[1])
    if resolved == nil or resolved == args[1] then
        return args
    end
    local canonical_args = { resolved }
    for index = 2, #args do
        canonical_args[index] = args[index]
    end
    return canonical_args
end

local function open_palette_with_repo_picker(commands, context)
    local repo_picker = require("jpr.repo_picker")
    local is_in_git_repo = repo_picker.is_git_repo(vim.fn.getcwd())
    if context.has_session or context.has_pending_tab or is_in_git_repo then
        context.is_git_repo = context.has_session or is_in_git_repo
        return require("jpr.tui.wizard").open_palette(commands, context)
    end
    local function pick_and_open()
        repo_picker.pick(function(selected_repo)
            local scoped_context = vim.tbl_extend("force", context, {
                is_git_repo = false,
                repo = selected_repo,
                title = (" Jpr Commands · %s "):format(selected_repo),
                on_back = pick_and_open,
            })
            require("jpr.tui.wizard").open_palette(commands, scoped_context)
        end)
    end
    return pick_and_open()
end

--- Dispatches `:Jpr [subcommand [arg]]` with optional command options `cmd_opts` (such as range), opening the interactive floating command palette when no subcommand is given.
function M.command(fargs, cmd_opts)
    local args = canonicalize_command_args(fargs or {})
    local session = require("jpr.session")
    local context = build_tui_context(session, cmd_opts)
    if #args == 0 then
        local commands = require("jpr.commands.schema").create_command_specs()
        return open_palette_with_repo_picker(commands, context)
    end
    return dispatch_direct_subcommand(session, args, cmd_opts, context)
end

--- Captures the 1-indexed inclusive visual line range and exits visual mode,
--- returning nil when called outside visual mode.
local function visual_range_opts()
    local mode = vim.fn.mode(1):sub(1, 1)
    if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
        return nil
    end
    local first_line, second_line = vim.fn.line("v"), vim.fn.line(".")
    local line1 = math.min(first_line, second_line)
    local line2 = math.max(first_line, second_line)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    return { line1 = line1, line2 = line2, range = 2 }
end

--- Dispatches a `<Plug>(jpr-*)` action `name` to the active review session.
function M.action(name)
    local session = require("jpr.session")
    if name == "comment" or name == "suggest_comment" then
        local opts = visual_range_opts() or {}
        if name == "suggest_comment" then
            opts.suggest = true
        end
        return session.comment_current(opts)
    end
    local dispatch = {
        file_comment = function()
            session.comment_current({ file = true })
        end,
        thread_popup = session.popup_current,
        next_thread = function()
            session.jump_thread_current(1)
        end,
        prev_thread = function()
            session.jump_thread_current(-1)
        end,
        send_agent = session.send_current,
        submit_review = session.submit_current,
        toggle_agent = session.agent_current,
    }
    local handler = dispatch[name]
    if handler then
        return handler()
    end
    M.error(("unknown action %q"):format(tostring(name)))
end

return M
