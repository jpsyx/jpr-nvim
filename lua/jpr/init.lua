-- jpr: review GitHub pull requests in Neovim, backed by the jpr-review engine.
local M = {}

M.defaults = {
    -- The engine binary.
    binary = "jpr-review",
    -- A shell command that creates the PR worktree and prints its path; `{n}` is
    -- the PR number. nil uses the engine's default (git worktree + gh pr checkout).
    worktree_cmd = nil,
    -- Width of the PR panel.
    panel_width = 44,
}

M.config = vim.deepcopy(M.defaults)

M.subcommands = { "open", "sync", "close" }

function M.define_highlights()
    local links = {
        JprTitle = "Title",
        JprMuted = "Comment",
        JprViewed = "DiagnosticOk",
        JprDismissed = "DiagnosticWarn",
        JprAdded = "Added",
        JprRemoved = "Removed",
        JprError = "DiagnosticError",
    }
    for name, target in pairs(links) do
        vim.api.nvim_set_hl(0, name, { link = target, default = true })
    end
end

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
    M.define_highlights()
end

--- The PR number in a `:Jpr open` argument: `123`, `#123`, or a pull request URL.
function M.parse_pr_arg(arg)
    if type(arg) ~= "string" then
        return nil
    end
    local number = arg:match("^#?(%d+)$") or arg:match("/pull/(%d+)")
    return number and tonumber(number) or nil
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

function M.error(message)
    vim.notify("jpr: " .. message, vim.log.levels.ERROR)
end

function M.info(message)
    vim.notify("jpr: " .. message, vim.log.levels.INFO)
end

--- Runs `:Jpr <fargs>`.
function M.command(fargs)
    local sub = fargs[1]
    if sub == "open" then
        local number = M.parse_pr_arg(fargs[2])
        if not number then
            return M.error("usage: :Jpr open <number | #number | pull request URL>")
        end
        require("jpr.session").open(number)
    elseif sub == "sync" then
        require("jpr.session").sync_current()
    elseif sub == "close" then
        require("jpr.session").close_current()
    else
        M.error(("unknown subcommand %q; expected one of: %s"):format(tostring(sub), table.concat(M.subcommands, ", ")))
    end
end

return M
