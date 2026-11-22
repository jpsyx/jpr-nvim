-- jpr: review GitHub pull requests in Neovim, backed by the jpr-review engine.
local M = {}

--- Release version of the Neovim plugin, paired with the jpr-review binary.
M.VERSION = "0.5.0"

--- The options `setup` starts from; a user's options override any of them.
M.defaults = {
    -- The engine binary.
    binary = "jpr-review",
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
M.subcommands = {
    "open",
    "sync",
    "toggle",
    "stream",
    "comment",
    "suggest",
    "expand",
    "conversation",
    "submit",
    "push",
    "agent",
    "send",
    "prepass",
    "close",
}

--- Links the panel's and thread UI's highlight groups to the colorscheme's,
--- without replacing any link the user set. Runs at `setup` and again when a
--- review starts, so the groups exist even without a `setup` call.
function M.define_highlights()
    local links = {
        JprTitle = "Title",
        JprMuted = "Comment",
        JprViewed = "DiagnosticOk",
        JprDismissed = "DiagnosticWarn",
        JprModified = "Special",
        JprAdded = "Added",
        JprRemoved = "Removed",
        JprError = "DiagnosticError",
        JprDiffAdd = "DiffAdd",
        JprDiffAddText = "DiffText",
        JprDiffDelete = "DiffDelete",
        JprDiffDeleteText = "DiffText",
        JprDiffFiller = "NonText",
        JprHunk = "Special",
        JprFileHeader = "Title",
        JprThreadPublished = "DiagnosticInfo",
        JprThreadDraft = "DiagnosticWarn",
        JprThreadLocal = "DiagnosticHint",
        JprThreadFailed = "DiagnosticError",
        JprThreadResolved = "Comment",
        JprReactionActive = "DiagnosticOk",
        JprAuthor = "Identifier",
    }
    for name, target in pairs(links) do
        vim.api.nvim_set_hl(0, name, { link = target, default = true })
    end
end

--- Configures the plugin from a user's `opts` (see `defaults`), for example
--- from `require("jpr").setup({ worktree_cmd = "wt pr {n}" })`.
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
    M.define_highlights()
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

--- Completes `:Jpr <subcommand>`; arguments after it have no completion.
function M.complete(arglead, cmdline)
    local words = vim.split(vim.trim(cmdline), "%s+")
    if #words > 2 or (#words == 2 and arglead == "") then
        return {}
    end
    return vim.tbl_filter(function(name)
        return vim.startswith(name, arglead)
    end, M.subcommands)
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

--- Runs `:Jpr <fargs>` with optional command options `cmd_opts` (such as range).
function M.command(fargs, cmd_opts)
    local subcommand = fargs[1]
    local session = require("jpr.session")
    if subcommand == "open" then
        local number, repo = M.parse_pr_arg(fargs[2])
        if not number then
            return M.error("usage: :Jpr open <number | #number | pull request URL>")
        end
        return session.open(number, repo)
    end
    local dispatch = {
        sync = session.sync_current,
        toggle = session.toggle_view,
        stream = session.stream_current,
        comment = function()
            session.comment_current(cmd_opts)
        end,
        suggest = session.suggest_current,
        expand = session.expand_current,
        conversation = session.conversation_current,
        submit = session.submit_current,
        push = session.push_current,
        agent = session.agent_current,
        send = session.send_current,
        prepass = session.prepass_current,
        close = session.close_current,
    }
    local handler = dispatch[subcommand]
    if handler then
        return handler()
    end
    M.error(("unknown subcommand %q; expected one of: %s"):format(tostring(subcommand), table.concat(M.subcommands, ", ")))
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
