-- Open-PR listing and pull-request checkout/tab-reuse commands attached onto `jpr.session`.
local crash = require("jpr.session.crash")

local M = {}

local function jpr()
    return require("jpr")
end

local function collect_open_tab_numbers(session_mod)
    local open_numbers = {}
    for tab, existing in pairs(session_mod.by_tab) do
        if vim.api.nvim_tabpage_is_valid(tab) and type(existing.number) == "number" then
            open_numbers[existing.number] = true
        end
    end
    return open_numbers
end

local function list_open_prs_from_cli(on_result, on_error)
    local binary_path = jpr().binary_path()
    if vim.fn.executable(binary_path) ~= 1 then
        return on_error("jpr-review binary is missing; run :Lazy build jpr-nvim")
    end
    local is_started, start_error = pcall(
        vim.system,
        { binary_path, "prs" },
        { cwd = vim.fn.getcwd(), text = true },
        vim.schedule_wrap(function(result)
            if result.code ~= 0 then
                local stderr = crash.build_clean_text_from_raw(result.stderr)
                return on_error(stderr ~= "" and stderr or "failed to list open pull requests")
            end
            local is_decoded, prs = pcall(vim.json.decode, result.stdout or "")
            if not is_decoded or not vim.islist(prs) then
                return on_error("failed to parse open pull requests response")
            end
            on_result(prs)
        end)
    )
    if not is_started then
        on_error(crash.build_clean_text_from_raw(start_error))
    end
end

local function build_checkout_args(number, repo)
    local config = jpr().config
    local args = { jpr().binary_path(), "checkout", "--pr", tostring(number) }
    if repo then
        vim.list_extend(args, { "--repo", repo })
    end
    if config.worktree_cmd then
        vim.list_extend(args, { "--worktree-cmd", config.worktree_cmd })
    end
    return args
end

local function parse_checkout_output(stdout)
    local last_line
    for line in (stdout or ""):gmatch("[^\n]+") do
        if vim.trim(line) ~= "" then
            last_line = line
        end
    end
    if not last_line then
        return nil, "jpr-review checkout printed nothing"
    end
    local is_decoded, info = pcall(vim.json.decode, last_line)
    if not is_decoded or type(info) ~= "table" or not info.worktree or not info.repo then
        return nil, "unexpected checkout output: " .. last_line
    end
    return info
end

local function open_pull_request(session_mod, number, repo)
    for tab, existing in pairs(session_mod.by_tab) do
        local same_repo = not repo or existing.repo:lower() == repo:lower()
        if existing.number == number and same_repo and vim.api.nvim_tabpage_is_valid(tab) then
            return vim.api.nvim_set_current_tabpage(tab)
        end
    end
    local binary_path = jpr().binary_path()
    if vim.fn.executable(binary_path) ~= 1 then
        local clean_binary_path = crash.build_clean_text_from_raw(binary_path)
        return jpr().error(("jpr-review binary not found at %s; run :Lazy build jpr-nvim"):format(clean_binary_path))
    end
    jpr().info(("checking out PR #%d…"):format(number))
    vim.system(
        session_mod.checkout_args(number, repo),
        { cwd = vim.fn.getcwd(), text = true },
        vim.schedule_wrap(function(result)
            if result.code ~= 0 then
                local stderr = vim.trim(result.stderr or "")
                return jpr().error(stderr ~= "" and stderr or "checkout failed")
            end
            local info, parse_error = session_mod.parse_checkout(result.stdout)
            if not info then
                return jpr().error(parse_error)
            end
            session_mod.start(info)
        end)
    )
end

--- Attaches PR listing, checkout argument building/parsing, and `:Jpr open`
--- handlers onto `session_mod`.
function M.attach(session_mod)
    --- Returns a set `{ [number] = true }` of pull request numbers currently open
    --- in valid tabs, used to mark `[open]` badges in the PR picker.
    function session_mod.open_tab_numbers()
        return collect_open_tab_numbers(session_mod)
    end

    --- Runs `jpr-review prs` asynchronously in the current working directory and
    --- calls `on_result(prs)` with the decoded PR list or `on_error(message)`.
    function session_mod.list_open_prs(on_result, on_error)
        return list_open_prs_from_cli(on_result, on_error)
    end

    --- The `jpr-review checkout` command for PR `number`. With `repo`
    --- (owner/name), checkout refuses a PR from any other repository.
    function session_mod.checkout_args(number, repo)
        return build_checkout_args(number, repo)
    end

    --- The JSON object on the last non-empty line of `checkout`'s stdout.
    function session_mod.parse_checkout(stdout)
        return parse_checkout_output(stdout)
    end

    --- `:Jpr open <number>`: reuse its tab, or check it out and start a session.
    --- `repo` (owner/name, from a URL) must match too, when given.
    function session_mod.open(number, repo)
        return open_pull_request(session_mod, number, repo)
    end
end

return M
