-- One open pull-request review per tab: the checkout, the engine process, and
-- the panel. Every review rule lives in the engine; this only wires it up.
local crash = require("jpr.session.crash")
local panel = require("jpr.views.panel")
local rpc = require("jpr.rpc")

local M = {}

--- The open sessions, keyed by tab page handle. A session is registered only
--- once its panel and engine are up.
M.by_tab = {}

local function jpr()
    return require("jpr")
end

--- The session open in the current tab, or nil, for the commands that act on
--- the current review.
function M.current()
    return M.by_tab[vim.api.nvim_get_current_tabpage()]
end

--- Returns a set `{ [number] = true }` of pull request numbers currently open
--- in valid tabs, used to mark `[open]` badges in the PR picker.
function M.open_tab_numbers()
    local open_numbers = {}
    for tab, existing in pairs(M.by_tab) do
        if vim.api.nvim_tabpage_is_valid(tab) and type(existing.number) == "number" then
            open_numbers[existing.number] = true
        end
    end
    return open_numbers
end

--- Runs `jpr-review prs` asynchronously in the current working directory and
--- calls `on_result(prs)` with the decoded PR list or `on_error(message)`.
function M.list_open_prs(on_result, on_error)
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

--- Reports that `session` is in read-only mode after an engine crash.
function M.report_read_only(session)
    return jpr().error(
        ("PR #%d is in read-only mode after an engine crash; run :Jpr close and :Jpr open %d"):format(
            session.number,
            session.number
        )
    )
end

--- Sends `method` with `params` to `session`'s engine. `on_result(result)`
--- runs on success; a failure is passed to `on_error`, when given, and
--- reported to the user unless the session is closing (a request still in
--- flight then fails because the engine was stopped on purpose).
function M.request(session, method, params, on_result, on_error)
    if session.is_read_only then
        if on_error then
            on_error()
        end
        return M.report_read_only(session)
    end
    if not session.client then
        if on_error then
            on_error()
        end
        return jpr().error(
            ("the review engine for PR #%d is not running; run :Jpr open %d"):format(session.number, session.number)
        )
    end
    session.client:request(method, params, function(request_error, result)
        if request_error then
            if on_error then
                on_error(request_error)
            end
            if session.closing then
                return
            end
            return jpr().error(("%s failed: %s"):format(method, request_error.message))
        end
        on_result(result)
    end)
end

--- The `jpr-review checkout` command for PR `number`. With `repo`
--- (owner/name), checkout refuses a PR from any other repository.
function M.checkout_args(number, repo)
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

--- The JSON object on the last non-empty line of `checkout`'s stdout.
function M.parse_checkout(stdout)
    local last_line
    for line in (stdout or ""):gmatch("[^\n]+") do
        if vim.trim(line) ~= "" then
            last_line = line
        end
    end
    if not last_line then
        return nil, "jpr-review checkout printed nothing"
    end
    local ok, info = pcall(vim.json.decode, last_line)
    if not ok or type(info) ~= "table" or not info.worktree or not info.repo then
        return nil, "unexpected checkout output: " .. last_line
    end
    return info
end

--- `:Jpr open <number>`: reuse its tab, or check it out and start a session.
--- `repo` (owner/name, from a URL) must match too, when given.
function M.open(number, repo)
    for tab, existing in pairs(M.by_tab) do
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
    vim.system(M.checkout_args(number, repo), { cwd = vim.fn.getcwd(), text = true }, vim.schedule_wrap(function(result)
        if result.code ~= 0 then
            local stderr = vim.trim(result.stderr or "")
            return jpr().error(stderr ~= "" and stderr or "checkout failed")
        end
        local info, err = M.parse_checkout(result.stdout)
        if not info then
            return jpr().error(err)
        end
        M.start(info)
    end))
end

--- Wipes the empty buffer `tabnew` made for `session`, unless it was named,
--- edited or is still on screen.
local function wipe_placeholder(session)
    local buf = session.placeholder_buf
    if
        buf
        and vim.api.nvim_buf_is_valid(buf)
        and vim.api.nvim_buf_get_name(buf) == ""
        and not vim.bo[buf].modified
        and #vim.fn.win_findbuf(buf) == 0
    then
        vim.api.nvim_buf_delete(buf, { force = true })
    end
end

--- Closes an optional view module when it has already been loaded.
local function close_optional_view(module_name, session)
    local view_module = package.loaded[module_name]
    if view_module and view_module.close then
        view_module.close(session)
    end
end

--- The one teardown path, for `:Jpr close`, `:tabclose`, an engine exit and a
--- failed start: stops the engine, wipes the panel and drops the session, so
--- `:Jpr open` can start the pull request again from scratch. The tab closes
--- too when `close_tab` is set or the session never finished starting; one
--- whose engine dies mid-review keeps its tab and the user's windows.
local function forget(session, close_tab)
    session.closing = true
    if session.client then
        session.client:request("shutdown", nil, function() end)
        session.client:stop()
    end
    if M.by_tab[session.tab] == session then
        M.by_tab[session.tab] = nil
    end
    close_optional_view("jpr.views.conversation", session)
    close_optional_view("jpr.comments.popup", session)
    close_optional_view("jpr.comments.compose", session)
    close_optional_view("jpr.views.submit", session)
    close_optional_view("jpr.agent", session)
    require("jpr.views.stream").close(session)
    require("jpr.views.diff").detach(session)
    panel.close(session)
    local tab = session.tab
    if (close_tab or not session.ready) and vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
        vim.cmd.tabclose(vim.api.nvim_tabpage_get_number(tab))
    end
    wipe_placeholder(session)
end

--- Forgets the sessions whose tab was closed, e.g. by `:tabclose`.
function M.forget_closed_tabs()
    for tab, session in pairs(M.by_tab) do
        if not vim.api.nvim_tabpage_is_valid(tab) then
            forget(session)
        end
    end
end

local function fail_handshake(session, client, error_message)
    if session.has_restarted and session.ready then
        session.client = nil
        client:stop()
        local log_path = crash.append_crash_log(session.number, "handshake", error_message)
        return crash.transition_to_read_only(session, "handshake", log_path, error_message)
    end
    forget(session)
    return jpr().error(error_message)
end

local function build_handshake_error_from_result(result)
    if type(result) ~= "table" or type(result.protocolVersion) ~= "number" then
        return "invalid handshake response: missing protocolVersion"
    end
    local binary_label = crash.build_clean_text_from_raw(jpr().binary_path())
    if result.protocolVersion ~= rpc.PROTOCOL_VERSION then
        return ("protocol mismatch: the plugin speaks %d and %s speaks %d; run :Lazy build jpr-nvim"):format(
            rpc.PROTOCOL_VERSION,
            binary_label,
            result.protocolVersion
        )
    end
    if type(result.version) ~= "string" or result.version == "" then
        return ("invalid handshake response from %s: missing engine version"):format(binary_label)
    end
    if result.version ~= "test" and result.version ~= jpr().VERSION then
        return ("version mismatch: plugin is %s and %s is %s; run :Lazy build jpr-nvim"):format(
            jpr().VERSION,
            binary_label,
            crash.build_clean_text_from_raw(result.version)
        )
    end
    return nil
end

--- Checks the engine speaks our protocol and release version, then loads and
--- syncs the view. A failed startup handshake stops the engine and forgets the
--- session; a failed restart handshake falls back to read-only mode.
local function handshake(session, client)
    local params = { protocolVersion = rpc.PROTOCOL_VERSION, client = "jpr.nvim" }
    client:request("initialize", params, function(init_error, result)
        if session.closing or session.client ~= client then
            return
        end
        if init_error then
            -- An engine that died is handled by on_exit, with its stderr.
            if client.exited then
                return
            end
            local clean_message = crash.build_clean_text_from_raw(init_error.message)
            return fail_handshake(session, client, "could not start the review engine: " .. clean_message)
        end
        local handshake_error = build_handshake_error_from_result(result)
        if handshake_error then
            return fail_handshake(session, client, handshake_error)
        end
        session.ready = true
        client:request("snapshot", nil, function(_, view)
            if session.closing or session.client ~= client then
                return
            end
            if view then
                M.show(session, view)
            end
        end)
        M.sync(session)
    end)
end

local function spawn_engine(session)
    local spawned_client
    local client, spawn_error = rpc.start({
        jpr().binary_path(),
        "serve",
        "--pr",
        tostring(session.number),
        "--repo",
        session.repo,
    }, {
        cwd = session.worktree,
        on_notification = function(method, params)
            if session.closing or session.client ~= spawned_client then
                return
            end
            M.on_notification(session, method, params)
        end,
        on_exit = function(code, stderr)
            M.on_exit(session, code, stderr, spawned_client)
        end,
    })
    if not client then
        if not session.has_restarted then
            forget(session)
            local clean_spawn_error = crash.build_clean_text_from_raw(spawn_error)
            jpr().error(clean_spawn_error ~= "" and clean_spawn_error or "could not start the review engine")
        end
        return false
    end
    spawned_client = client
    session.client = client
    M.by_tab[session.tab] = session
    handshake(session, client)
    return true
end

--- Opens a tab for a checked-out PR and starts its engine.
--- info: { worktree, repo = "owner/name", number }.
function M.start(info)
    jpr().define_highlights()
    local augroup = vim.api.nvim_create_augroup("jpr-session", { clear = true })
    vim.api.nvim_create_autocmd("TabClosed", {
        group = augroup,
        callback = M.forget_closed_tabs,
    })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = augroup,
        callback = function()
            for _, active in pairs(M.by_tab) do
                active.closing = true
                if active.client then
                    active.client:stop()
                end
            end
        end,
    })
    vim.cmd("tabnew")
    -- Escaped: Ex commands expand `%` and `#` in a path.
    vim.cmd.tcd(vim.fn.fnameescape(info.worktree))
    local tab = vim.api.nvim_get_current_tabpage()
    local session = { number = info.number, repo = info.repo, worktree = info.worktree, tab = tab, view = {} }
    session.placeholder_buf = vim.api.nvim_get_current_buf()
    require("jpr.views.diff").attach(session)
    -- Registered only once the panel and the engine are up, so a failure here
    -- never leaves a half-built session for `:Jpr open` to refocus.
    local is_opened, open_error = pcall(panel.open, session)
    if not is_opened then
        forget(session)
        return jpr().error("could not open the panel: " .. tostring(open_error))
    end
    spawn_engine(session)
end

--- Whether the pull request's head or base commit moved between
--- `previous_view` and `view`, which changes every diff.
function M.have_commits_changed(previous_view, view)
    local previous_pr, current_pr = previous_view and previous_view.pr, view.pr
    if not previous_pr or not current_pr then
        return false
    end
    return previous_pr.headSha ~= current_pr.headSha or previous_pr.baseSha ~= current_pr.baseSha
end

--- Keeps `view` as the session's latest and redraws from it: the panel
--- always, and the stream and the diffs once the pull request is known (the
--- stream opens on the first such view, and is fetched again when it changes).
function M.show(session, view)
    if session.is_read_only and type(view) == "table" then
        view.isReadOnly = true
    end
    local previous_view = session.view
    session.view = view
    panel.render(session, view)
    if not view.pr or session.is_read_only then
        return
    end
    local stream = require("jpr.views.stream")
    if not session.stream_opened then
        -- The first time only, and never over a file the reviewer opened.
        session.stream_opened = true
        stream.show(session, { only_if_free = true })
    else
        stream.refresh(session)
    end
    local diff = require("jpr.views.diff")
    if M.have_commits_changed(previous_view, view) then
        diff.redraw_all(session)
    else
        diff.reconcile(session)
    end
end

--- Updates `session`'s views and error reporting in response to engine notifications.
function M.on_notification(session, method, params)
    require("jpr.session.events").on_notification(session, method, params, M.show)
end

--- Handles `session`'s engine exiting: restarts once mid-review, or switches
--- into read-only mode on a second crash.
function M.on_exit(session, code, stderr, exited_client)
    if session.client ~= nil and exited_client ~= nil and session.client ~= exited_client then
        return
    end
    session.client = nil
    crash.handle_unexpected_exit(session, code, stderr, {
        forget = forget,
        spawn = spawn_engine,
        is_registered = function(candidate)
            return M.by_tab[candidate.tab] == candidate and vim.api.nvim_tabpage_is_valid(candidate.tab)
        end,
    })
end

require("jpr.session.commands").attach(M, forget)
require("jpr.session.comments").attach(M)

return M
