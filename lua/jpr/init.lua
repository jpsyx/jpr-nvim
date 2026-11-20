-- jpr: review GitHub pull requests in Neovim, backed by the jpr-review engine.
local M = {}

--- The options `setup` starts from; a user's options override any of them.
M.defaults = {
    -- The engine binary.
    binary = "jpr-review",
    -- A shell command that creates the PR worktree and prints its path; `{n}` is
    -- the PR number. nil uses the engine's default (git worktree + gh pr checkout).
    worktree_cmd = nil,
    -- Width of the PR panel.
    panel_width = 44,
    -- The diff view until the reviewer flips it with :Jpr toggle, which is
    -- then remembered: "unified" or "split".
    view = "unified",
}

--- The options in effect: the defaults merged with what `setup` was given.
--- Every module reads its settings from here.
M.config = vim.deepcopy(M.defaults)

--- The `:Jpr` subcommands, in the order completion offers them.
M.subcommands = { "open", "sync", "toggle", "stream", "close" }

--- Links the panel's highlight groups to the colorscheme's, without
--- replacing any link the user set. Runs at `setup` and again when a review
--- starts, so the groups exist even without a `setup` call.
function M.define_highlights()
    local links = {
        JprTitle = "Title",
        JprMuted = "Comment",
        JprViewed = "DiagnosticOk",
        JprDismissed = "DiagnosticWarn",
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

--- Tells the user what the plugin is doing, as a `jpr:` notification.
function M.info(message)
    vim.notify("jpr: " .. message, vim.log.levels.INFO)
end

--- Runs `:Jpr <fargs>`.
function M.command(fargs)
    local subcommand = fargs[1]
    if subcommand == "open" then
        local number, repo = M.parse_pr_arg(fargs[2])
        if not number then
            return M.error("usage: :Jpr open <number | #number | pull request URL>")
        end
        require("jpr.session").open(number, repo)
    elseif subcommand == "sync" then
        require("jpr.session").sync_current()
    elseif subcommand == "toggle" then
        require("jpr.session").toggle_view()
    elseif subcommand == "stream" then
        require("jpr.session").stream_current()
    elseif subcommand == "close" then
        require("jpr.session").close_current()
    else
        M.error(("unknown subcommand %q; expected one of: %s"):format(tostring(subcommand), table.concat(M.subcommands, ", ")))
    end
end

return M
