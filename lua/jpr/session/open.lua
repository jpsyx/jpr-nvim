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

local pending_by_number = {}

local function close_tab_if_not_last(tab)
    if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
        vim.cmd.tabclose(vim.api.nvim_tabpage_get_number(tab))
    end
end

local function wipe_initial_empty_buffer(buf)
    if
        buf
        and vim.api.nvim_buf_is_valid(buf)
        and vim.api.nvim_buf_get_name(buf) == ""
        and not vim.bo[buf].modified
        and #vim.fn.win_findbuf(buf) == 0
    then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
end

local function find_existing_tab(session_mod, number, repo)
    for tab, existing in pairs(session_mod.by_tab) do
        local is_same_repo = not repo or existing.repo:lower() == repo:lower()
        if existing.number == number and is_same_repo and vim.api.nvim_tabpage_is_valid(tab) then
            return tab
        end
    end
    local pending = pending_by_number[number]
    if pending then
        if not vim.api.nvim_tabpage_is_valid(pending.tab) then
            require("jpr.views.loading").close(pending)
            pending_by_number[number] = nil
        else
            local is_same_repo = not repo or not pending.repo or pending.repo:lower() == repo:lower()
            if is_same_repo then
                return pending.tab
            end
        end
    end
    return nil
end

local function close_pending_tab(tab)
    for number, pending in pairs(pending_by_number) do
        if pending.tab == tab then
            pending_by_number[number] = nil
            local proc = pending.process
            pending.process = nil
            if type(proc) == "table" and type(proc.kill) == "function" then
                pcall(proc.kill, proc, 15)
            end
            require("jpr.views.loading").close(pending)
            close_tab_if_not_last(tab)
            return true
        end
    end
    return false
end

local function create_stderr_collector(number, pending_session)
    local stderr_chunks = {}
    local stderr_pending = ""
    local loading = require("jpr.views.loading")
    local function on_stderr(_, data)
        if type(data) ~= "string" or data == "" then
            return
        end
        stderr_chunks[#stderr_chunks + 1] = data
        local combined = stderr_pending .. data
        local latest_line
        for line in combined:gmatch("[^\r\n]+") do
            local clean_line = crash.build_clean_text_from_raw(line)
            if clean_line ~= "" then
                latest_line = clean_line
            end
        end
        stderr_pending = combined:match("[\r\n]$") and "" or (combined:match("[^\r\n]*$") or "")
        if latest_line then
            vim.schedule(function()
                if pending_by_number[number] == pending_session then
                    loading.update(pending_session, { detail = latest_line })
                end
            end)
        end
    end
    return stderr_chunks, on_stderr
end

local function handle_checkout_exit(session_mod, number, pending_session, stderr_chunks, result)
    local loading = require("jpr.views.loading")
    local was_active = pending_by_number[number] == pending_session
    if was_active then
        pending_by_number[number] = nil
    end
    pending_session.process = nil
    if not was_active or not vim.api.nvim_tabpage_is_valid(pending_session.tab) then
        return loading.close(pending_session)
    end
    if result.code ~= 0 then
        local raw_stderr = #stderr_chunks > 0 and table.concat(stderr_chunks) or (result.stderr or "")
        local stderr = vim.trim(raw_stderr)
        loading.close(pending_session)
        close_tab_if_not_last(pending_session.tab)
        return jpr().error(stderr ~= "" and stderr or "checkout failed")
    end
    local info, parse_error = session_mod.parse_checkout(result.stdout)
    if not info then
        loading.close(pending_session)
        close_tab_if_not_last(pending_session.tab)
        return jpr().error(parse_error)
    end
    session_mod.start(info, pending_session)
end

local function open_pull_request(session_mod, number, repo)
    local existing_tab = find_existing_tab(session_mod, number, repo)
    if existing_tab then
        return vim.api.nvim_set_current_tabpage(existing_tab)
    end
    local binary_path = jpr().binary_path()
    if vim.fn.executable(binary_path) ~= 1 then
        local clean_binary_path = crash.build_clean_text_from_raw(binary_path)
        return jpr().error(("jpr-review binary not found at %s; run :Lazy build jpr-nvim"):format(clean_binary_path))
    end
    jpr().define_highlights()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    local initial_buf = vim.api.nvim_get_current_buf()
    local pending_session = { number = number, repo = repo, tab = tab }
    pending_by_number[number] = pending_session
    require("jpr.views.loading").open(pending_session, {
        number = number,
        stage = 1,
        detail = ("Looking up pull request #%d..."):format(number),
    })
    wipe_initial_empty_buffer(initial_buf)
    local stderr_chunks, on_stderr = create_stderr_collector(number, pending_session)
    pending_session.process = vim.system(
        session_mod.checkout_args(number, repo),
        { cwd = vim.fn.getcwd(), text = true, stderr = on_stderr },
        vim.schedule_wrap(function(result)
            handle_checkout_exit(session_mod, number, pending_session, stderr_chunks, result)
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

    --- Cancels and closes an in-flight loading checkout tab if `tab` is one.
    function session_mod.close_pending_tab(tab)
        return close_pending_tab(tab)
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
