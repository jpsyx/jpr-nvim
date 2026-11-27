-- Command-line parsing, completion, `:Jpr` subcommand dispatch, and `<Plug>(jpr-*)`
-- action dispatch.
local M = {}

local OPTIONAL_ARG_SUBCOMMANDS = { open = true, ["local"] = true, toggle = true, comment = true, agent = true }
local ZERO_ARG_SESSION_METHODS = {
    sync = "sync_current",
    panel = "panel_current",
    stream = "stream_current",
    suggest = "suggest_current",
    expand = "expand_current",
    summary = "summary_current",
    conversation = "conversation_current",
    ["pr-comment"] = "pr_comment_current",
    submit = "submit_current",
    push = "push_current",
    send = "send_current",
    prepass = "prepass_current",
    close = "close_current",
}

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
function M.complete(subcommands, arglead, cmdline)
    local command_tail = slice_from_jpr_command(cmdline)
    local trimmed = vim.trim(command_tail)
    local words = trimmed ~= "" and vim.split(trimmed, "%s+") or {}
    local has_trailing_space = command_tail:match("%s$") ~= nil
    local token_index = has_trailing_space and (#words + 1) or #words
    if token_index <= 2 then
        return filter_by_prefix(subcommands, arglead or "")
    end
    if token_index == 3 then
        local candidates = require("jpr.commands.schema").subcommand_arg_completions(words[2])
        return filter_by_prefix(candidates, arglead or "")
    end
    return {}
end

local function build_tui_context(session, cmd_opts)
    return require("jpr.tui.context").create_context_from_session(session, cmd_opts)
end

local function open_pr_picker_for_context(context)
    local open_spec = require("jpr.commands.schema").find_command_spec("open")
    return require("jpr.tui.wizard").open_command(open_spec, { source = "list" }, context, { start_step_id = "pr" })
end

local function dispatch_open_subcommand(jpr, session, argument, context)
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
        return jpr.error(("invalid pull request %q; expected a PR number, #number, or pull request URL"):format(argument))
    end
    return session.open(number, repo)
end

local function dispatch_validated_arg(jpr, subcommand, argument, label, on_valid)
    local valid_values = require("jpr.commands.schema").subcommand_arg_completions(subcommand)
    if vim.tbl_contains(valid_values, argument) then
        return on_valid(argument)
    end
    return jpr.error(("invalid %s %q; expected one of: %s"):format(label, tostring(argument), table.concat(valid_values, ", ")))
end

local function dispatch_comment_subcommand(jpr, session, argument, cmd_opts, context)
    if argument == nil or argument == "" then
        return session.comment_current(cmd_opts)
    end
    return dispatch_validated_arg(jpr, "comment", argument, "comment scope", function(kind)
        local comment_spec = require("jpr.commands.schema").find_command_spec("comment")
        return comment_spec.execute({ kind = kind }, context)
    end)
end

local function dispatch_optional_arg_subcommand(jpr, session, subcommand, argument, cmd_opts, context)
    if subcommand == "open" then
        return dispatch_open_subcommand(jpr, session, argument, context)
    end
    if subcommand == "local" then
        local base_ref = (type(argument) == "string" and vim.trim(argument) ~= "") and vim.trim(argument) or nil
        return session.open_local(base_ref)
    end
    if subcommand == "toggle" then
        if argument == nil or argument == "" then
            return session.toggle_view()
        end
        return dispatch_validated_arg(jpr, "toggle", argument, "diff view", session.set_view_mode)
    end
    if subcommand == "comment" then
        return dispatch_comment_subcommand(jpr, session, argument, cmd_opts, context)
    end
    if subcommand == "agent" then
        if argument == nil or argument == "" then
            return session.agent_current()
        end
        return dispatch_validated_arg(jpr, "agent", argument, "agent", session.agent_current)
    end
    return nil
end

local function is_numeric_pr_attempt(token)
    if type(token) ~= "string" then
        return false
    end
    return tonumber(token) ~= nil or token:match("^#%-?%d") ~= nil
end

local function dispatch_direct_subcommand(jpr, session, args, cmd_opts, context)
    local subcommand = args[1]
    if subcommand == "keys" then
        if #args > 1 then
            return jpr.error(":Jpr keys does not accept arguments")
        end
        return require("jpr.views.cheatsheet").open()
    end
    if OPTIONAL_ARG_SUBCOMMANDS[subcommand] then
        if #args > 2 then
            return jpr.error(("too many arguments for :Jpr %s"):format(subcommand))
        end
        return dispatch_optional_arg_subcommand(jpr, session, subcommand, args[2], cmd_opts, context)
    end
    local method_name = ZERO_ARG_SESSION_METHODS[subcommand]
    if method_name then
        if #args > 1 then
            return jpr.error((":Jpr %s does not accept arguments"):format(subcommand))
        end
        return session[method_name]()
    end
    local pr_number, pr_repo = M.parse_pr_arg(subcommand)
    if pr_number then
        if #args > 1 then
            return jpr.error(("too many arguments for :Jpr %s"):format(subcommand))
        end
        return session.open(pr_number, pr_repo)
    end
    if is_numeric_pr_attempt(subcommand) then
        return jpr.error(("invalid pull request %q; expected a positive PR number, #number, or pull request URL"):format(subcommand))
    end
    jpr.error(("unknown subcommand %q; expected one of: %s"):format(tostring(subcommand), table.concat(jpr.subcommands, ", ")))
end

local function canonicalize_command_args(args)
    if type(args[1]) ~= "string" then
        return args
    end
    local resolved = require("jpr.commands.schema").canonicalize_command_id(args[1])
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

--- Dispatches `:Jpr [subcommand [arg]]` with optional command options `cmd_opts` (such as range),
--- opening the interactive floating command palette when no subcommand is given.
function M.command(jpr, fargs, cmd_opts)
    local args = canonicalize_command_args(fargs or {})
    local session = require("jpr.session")
    local context = build_tui_context(session, cmd_opts)
    if #args == 0 then
        local commands = require("jpr.commands.schema").create_command_specs()
        return open_palette_with_repo_picker(commands, context)
    end
    return dispatch_direct_subcommand(jpr, session, args, cmd_opts, context)
end

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
function M.action(jpr, name)
    local session = require("jpr.session")
    if name == "comment" or name == "suggest_comment" then
        local opts = visual_range_opts() or {}
        if name == "suggest_comment" then
            opts.suggest = true
        end
        return session.comment_current(opts)
    end
    local dispatch = {
        file_comment = function() session.comment_current({ file = true }) end,
        pr_comment = session.pr_comment_current,
        full_diff = session.stream_current,
        toggle_viewed = session.toggle_viewed_current,
        thread_popup = session.popup_current,
        next_thread = function() session.jump_thread_current(1) end,
        prev_thread = function() session.jump_thread_current(-1) end,
        send_agent = session.send_current,
        submit_review = session.submit_current,
        toggle_agent = session.agent_current,
        toggle_panel = session.panel_current,
    }
    local handler = dispatch[name]
    if handler then
        return handler()
    end
    jpr.error(("unknown action %q"):format(tostring(name)))
end

return M
