-- Open-PR listing and pull-request checkout/tab-reuse commands attached onto `jpr.session`.
local crash = require("jpr.session.crash")

local M = {}

local function jpr()
    return require("jpr")
end

local function collect_open_tab_numbers(session_mod, repo)
    local open_numbers = {}
    local target_repo = type(repo) == "string" and repo ~= "" and repo:lower() or nil
    for tab, existing in pairs(session_mod.by_tab) do
        if vim.api.nvim_tabpage_is_valid(tab) and type(existing.number) == "number" then
            local existing_repo = type(existing.repo) == "string" and existing.repo:lower() or nil
            local is_same_repo = not target_repo or existing_repo == target_repo
            if is_same_repo then
                open_numbers[existing.number] = true
            end
        end
    end
    return open_numbers
end

local function handle_prs_cli_exit(result, on_result, on_error, options, retry_fn)
    if type(options.is_active) == "function" and not options.is_active() then
        return
    end
    if result.code ~= 0 then
        local auth = require("jpr.auth")
        if auth.is_cli_auth_error(result) then
            return auth.prompt_and_resume({
                is_background = false,
                on_authenticated = function()
                    if type(options.on_reopen) == "function" then
                        options.on_reopen()
                    else
                        retry_fn()
                    end
                end,
                on_cancel = function()
                    on_error("GitHub authentication is required to list pull requests")
                end,
            })
        end
        local stderr = crash.build_clean_text_from_raw(result.stderr)
        return on_error(stderr ~= "" and stderr or "failed to list open pull requests")
    end
    local is_decoded, prs = pcall(vim.json.decode, result.stdout or "")
    if not is_decoded or not vim.islist(prs) then
        return on_error("failed to parse open pull requests response")
    end
    on_result(prs)
end

local function list_open_prs_from_cli(on_result, on_error, opts)
    local options = opts or {}
    local binary_path = jpr().binary_path()
    if vim.fn.executable(binary_path) ~= 1 then
        return on_error("jpr-review binary is missing; run :Lazy build jpr-nvim")
    end
    local args = { binary_path, "prs" }
    if type(options.repo) == "string" and options.repo ~= "" then
        vim.list_extend(args, { "--repo", options.repo })
    end
    local is_started, start_error = pcall(
        vim.system,
        args,
        { cwd = vim.fn.getcwd(), text = true },
        vim.schedule_wrap(function(result)
            handle_prs_cli_exit(result, on_result, on_error, options, function()
                list_open_prs_from_cli(on_result, on_error, options)
            end)
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

local pending_by_key = {}

local function build_pending_key(number, repo)
    local repo_part = type(repo) == "string" and repo:lower() or ""
    return repo_part .. "#" .. tostring(number)
end

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

local function cancel_pending_checkout(pending)
    if not pending then
        return
    end
    if pending.pending_key and pending_by_key[pending.pending_key] == pending then
        pending_by_key[pending.pending_key] = nil
    end
    pending.is_canceled = true
    local process = pending.process
    pending.process = nil
    if type(process) == "table" and type(process.kill) == "function" then
        pcall(process.kill, process, 15)
    end
    require("jpr.views.loading").close(pending)
end

local function cancel_closed_pending_tabs()
    for _, pending in pairs(pending_by_key) do
        if not vim.api.nvim_tabpage_is_valid(pending.tab) then
            cancel_pending_checkout(pending)
        end
    end
end

local function register_pending_tab_close_autocmd()
    local augroup = vim.api.nvim_create_augroup("jpr-pending-open", { clear = true })
    vim.api.nvim_create_autocmd("TabClosed", {
        group = augroup,
        callback = cancel_closed_pending_tabs,
    })
end

local function find_existing_tab(session_mod, number, repo)
    for tab, existing in pairs(session_mod.by_tab) do
        if existing.number == number and vim.api.nvim_tabpage_is_valid(tab) then
            local is_same_repo = not repo
                or (type(existing.repo) == "string" and existing.repo:lower() == repo:lower())
            if is_same_repo then
                return tab
            end
        end
    end
    for _, pending in pairs(pending_by_key) do
        if not vim.api.nvim_tabpage_is_valid(pending.tab) then
            cancel_pending_checkout(pending)
        elseif pending.number == number then
            local is_same_repo = not repo or not pending.repo or pending.repo:lower() == repo:lower()
            if is_same_repo then
                return pending.tab
            end
        end
    end
    return nil
end

local function is_pending_buf_key_taken(session, candidate)
    for _, pending in pairs(pending_by_key) do
        if pending ~= session and vim.api.nvim_tabpage_is_valid(pending.tab) then
            local pending_key = pending.buf_key_value
                or (type(pending.number) == "number" and tostring(pending.number) or nil)
            if pending_key == candidate then
                return true
            end
        end
    end
    return false
end

local function close_pending_tab(tab)
    for _, pending in pairs(pending_by_key) do
        if pending.tab == tab then
            cancel_pending_checkout(pending)
            close_tab_if_not_last(tab)
            return true
        end
    end
    return false
end

local function create_stderr_collector(pending_key, pending_session)
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
                if pending_by_key[pending_key] == pending_session then
                    loading.update(pending_session, { detail = latest_line })
                end
            end)
        end
    end
    return stderr_chunks, on_stderr
end

local open_pull_request

local function on_checkout_exit(session_mod, pending_key, number, repo, pending_session, stderr_chunks, result)
    local loading = require("jpr.views.loading")
    local was_active = pending_by_key[pending_key] == pending_session
    if was_active then
        pending_by_key[pending_key] = nil
    end
    pending_session.process = nil
    if pending_session.is_canceled or not was_active or not vim.api.nvim_tabpage_is_valid(pending_session.tab) then
        return loading.close(pending_session)
    end
    if result.code ~= 0 then
        local raw_stderr = #stderr_chunks > 0 and table.concat(stderr_chunks) or (result.stderr or "")
        local stderr = vim.trim(raw_stderr)
        loading.close(pending_session)
        close_tab_if_not_last(pending_session.tab)
        local auth = require("jpr.auth")
        if auth.is_cli_auth_error(result) then
            return auth.prompt_and_resume({
                is_background = false,
                on_authenticated = function()
                    open_pull_request(session_mod, number, repo)
                end,
            })
        end
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

open_pull_request = function(session_mod, number, repo)
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
    register_pending_tab_close_autocmd()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    local initial_buf = vim.api.nvim_get_current_buf()
    local pending_key = build_pending_key(number, repo)
    local pending_session = { number = number, repo = repo, tab = tab, pending_key = pending_key }
    pending_by_key[pending_key] = pending_session
    require("jpr.views.loading").open(pending_session, {
        number = number,
        stage = 1,
        detail = ("Looking up pull request #%d..."):format(number),
    })
    wipe_initial_empty_buffer(initial_buf)
    local stderr_chunks, on_stderr = create_stderr_collector(pending_key, pending_session)
    local is_started, process_or_error = pcall(
        vim.system,
        session_mod.checkout_args(number, repo),
        { cwd = vim.fn.getcwd(), text = true, stderr = on_stderr },
        vim.schedule_wrap(function(result)
            on_checkout_exit(session_mod, pending_key, number, repo, pending_session, stderr_chunks, result)
        end)
    )
    if not is_started then
        cancel_pending_checkout(pending_session)
        close_tab_if_not_last(tab)
        local clean_error = crash.build_clean_text_from_raw(process_or_error)
        return jpr().error(clean_error ~= "" and clean_error or "failed to start checkout")
    end
    pending_session.process = process_or_error
end

--- Attaches PR listing, checkout argument building/parsing, and `:Jpr open`
--- handlers onto `session_mod`.
function M.attach(session_mod)
    --- Returns a set `{ [number] = true }` of pull request numbers currently open
    --- in valid tabs (optionally filtered to `repo`), used for `[open]` badges.
    function session_mod.open_tab_numbers(repo)
        return collect_open_tab_numbers(session_mod, repo)
    end

    --- Cancels and closes an in-flight loading checkout tab if `tab` is one.
    function session_mod.close_pending_tab(tab)
        return close_pending_tab(tab)
    end

    --- Returns whether another in-flight checkout already claims `candidate` as its buffer key.
    function session_mod.is_pending_buf_key_taken(session, candidate)
        return is_pending_buf_key_taken(session, candidate)
    end

    --- Cancels any in-flight checkouts whose loading tabs have been closed.
    function session_mod.cancel_closed_pending_tabs()
        return cancel_closed_pending_tabs()
    end

    --- Runs `jpr-review prs` asynchronously in the current working directory
    --- (or for `opts.repo`) and calls `on_result(prs)` or `on_error(message)`.
    function session_mod.list_open_prs(on_result, on_error, opts)
        return list_open_prs_from_cli(on_result, on_error, opts)
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
