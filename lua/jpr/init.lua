-- jpr: review GitHub pull requests in Neovim, backed by the jpr-review engine.
local M = {}

--- Release version of the Neovim plugin, paired with the jpr-review binary.
M.VERSION = "0.6.0"

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
    -- Command or path invoked for Claude Code in the agent panel.
    claude_cmd = "claude",
    -- Command or path invoked for Codex in the agent panel.
    codex_cmd = "codex",
    -- Width in columns of the right-hand `:Jpr agent` vertical split.
    agent_width = 56,
    -- The diff view until the reviewer flips it with :Jpr toggle, which is
    -- then remembered: "unified" or "split".
    view = "unified",
    -- Buffer-local keybindings inside diff and stream buffers; set any entry to
    -- false to disable it while keeping its <Plug>(jpr-*) mapping available.
    keys = {
        comment = "gc",
        suggest_comment = "gC",
        file_comment = "gf",
        thread_popup = "gt",
        next_thread = "]t",
        prev_thread = "[t",
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

--- Configures the plugin from a user's `opts` (see `defaults`), for example
--- from `require("jpr").setup({ worktree_cmd = "wt pr {n}" })`.
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
    M.define_highlights()
end

--- Active engine binary path or command, defaulting to the bundled release binary.
function M.binary_path()
    return require("jpr.binary").get_binary_path_from_config(M.config)
end

--- Binds configured comment and thread keys in buffer `buf` to their
--- `<Plug>(jpr-*)` mappings, skipping any entry set to `false`.
function M.bind_buffer_keys(buf)
    local keys = M.config.keys or {}
    local map = function(modes, lhs, plug, desc)
        if lhs and lhs ~= false then
            vim.keymap.set(
                modes,
                lhs,
                plug,
                { buffer = buf, remap = true, silent = true, nowait = true, desc = desc }
            )
        end
    end
    map({ "n", "x" }, keys.comment, "<Plug>(jpr-comment)", "New GitHub draft comment")
    map({ "n", "x" }, keys.suggest_comment, "<Plug>(jpr-suggest-comment)", "New GitHub suggestion comment")
    map("n", keys.file_comment, "<Plug>(jpr-file-comment)", "New file-level GitHub comment")
    map("n", keys.thread_popup, "<Plug>(jpr-thread-popup)", "Open review thread popup")
    map("n", keys.next_thread, "<Plug>(jpr-next-thread)", "Next review thread")
    map("n", keys.prev_thread, "<Plug>(jpr-prev-thread)", "Previous review thread")
end

--- The PR number in a `:Jpr open` argument: `123`, `#123`, or a pull request
--- URL. A URL also gives its repository as a second value, `owner/name`.
function M.parse_pr_arg(arg)
    if type(arg) ~= "string" then
        return nil
    end
    local repo, url_number = arg:match("^%a+://[^/]+/([^/]+/[^/]+)/pull/(%d+)")
    local number = url_number or arg:match("^#?(%d+)$") or arg:match("/pull/(%d+)")
    return number and tonumber(number) or nil, repo
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

local function is_cursor_on_diff_line(current_session)
    if not current_session then
        return false
    end
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local buffers = current_session.stream and current_session.stream.buffers
    if buffers ~= nil and (buf == buffers.main or buf == buffers.left) then
        local line = vim.api.nvim_win_get_cursor(win)[1]
        return require("jpr.views.stream").anchor_at_range(current_session, win, line, line) ~= nil
    end
    if type(vim.b[buf].jpr_base_path) == "string" and vim.b[buf].jpr_base_path ~= "" then
        return true
    end
    return require("jpr.views.diff").buffer_to_changed_path(current_session, buf) ~= nil
end

local function build_tui_context(session, cmd_opts)
    local current_session = type(session.current) == "function" and session.current() or nil
    local is_agent_open = false
    local has_live_agent = false
    if current_session ~= nil then
        local agent_module = require("jpr.agent")
        is_agent_open = type(agent_module.is_open) == "function" and agent_module.is_open(current_session) == true
        has_live_agent = type(agent_module.has_live_agent) == "function" and agent_module.has_live_agent(current_session) == true
    end
    return {
        cmd_opts = cmd_opts,
        has_session = current_session ~= nil,
        is_agent_open = is_agent_open,
        has_live_agent = has_live_agent,
        is_on_diff_line = is_cursor_on_diff_line(current_session),
    }
end

local function dispatch_open_subcommand(session, argument, context)
    if argument == nil or argument == "" then
        local open_spec = require("jpr.commands.schema").find_command_spec("open")
        return require("jpr.tui.wizard").open_command(open_spec, { source = "list" }, context, { start_step_id = "pr" })
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

local OPTIONAL_ARG_SUBCOMMANDS = { open = true, toggle = true, comment = true, agent = true }
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
    M.error(("unknown subcommand %q; expected one of: %s"):format(tostring(subcommand), table.concat(M.subcommands, ", ")))
end

--- Dispatches `:Jpr [subcommand [arg]]` with optional command options `cmd_opts` (such as range), opening the interactive floating command palette when no subcommand is given.
function M.command(fargs, cmd_opts)
    local args = fargs or {}
    local session = require("jpr.session")
    local context = build_tui_context(session, cmd_opts)
    if #args == 0 then
        local commands = require("jpr.commands.schema").create_command_specs()
        return require("jpr.tui.wizard").open_palette(commands, context)
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
    }
    local handler = dispatch[name]
    if handler then
        return handler()
    end
    M.error(("unknown action %q"):format(tostring(name)))
end

return M
