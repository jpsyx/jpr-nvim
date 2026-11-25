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

--- Unique buffer-name suffix for `session`: numeric PR number or `local-<tab>`.
function M.buf_key(session)
    if type(session) == "table" and type(session.number) == "number" then
        return tostring(session.number)
    end
    return "local-" .. tostring(type(session) == "table" and session.tab or 0)
end

--- Human-readable label for `session` (`PR #7` or `local review (branch)`).
function M.display_label(session)
    return crash.build_session_label(session)
end

--- Reports that `session` is in read-only mode after an engine crash.
function M.report_read_only(session)
    local reopen_hint = session.number and (":Jpr open %d"):format(session.number) or ":Jpr local"
    return jpr().error(
        ("%s is in read-only mode after an engine crash; run :Jpr close and %s"):format(
            M.display_label(session),
            reopen_hint
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
        local reopen_hint = session.number and (":Jpr open %d"):format(session.number) or ":Jpr local"
        return jpr().error(
            ("the review engine for %s is not running; run %s"):format(M.display_label(session), reopen_hint)
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

local function is_clean_unnamed_buffer(buf)
    return buf and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == "" and not vim.bo[buf].modified
end

--- Wipes the empty buffer `tabnew` made for `session`, unless it was named,
--- edited or is still on screen.
local function wipe_placeholder(session)
    local buf = session.placeholder_buf
    if is_clean_unnamed_buffer(buf) and #vim.fn.win_findbuf(buf) == 0 then
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
    close_optional_view("jpr.views.loading", session)
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
    M.cancel_closed_pending_tabs()
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
        local log_path = crash.append_crash_log(session.number, "handshake", error_message, session.branch)
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
        if session.loading then
            require("jpr.views.loading").update(session, { stage = 3 })
        end
        client:request("snapshot", nil, function(_, view)
            if session.closing or session.client ~= client then
                return
            end
            if view then
                M.show(session, view)
            end
        end)
        if session.mode ~= "local" then
            M.sync(session)
        end
    end)
end

local function build_serve_args_from_session(session)
    if session.mode == "local" then
        local args = { jpr().binary_path(), "serve", "--local" }
        if type(session.base_ref) == "string" and session.base_ref ~= "" then
            vim.list_extend(args, { "--base", session.base_ref })
        end
        return args
    end
    return {
        jpr().binary_path(),
        "serve",
        "--pr",
        tostring(session.number),
        "--repo",
        session.repo,
    }
end

local function spawn_engine(session)
    local spawned_client
    local client, spawn_error = rpc.start(build_serve_args_from_session(session), {
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

local function setup_session_autocmds()
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
end

local function is_empty_unnamed_buffer(buf)
    return is_clean_unnamed_buffer(buf)
        and vim.api.nvim_buf_line_count(buf) == 1
        and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

local function prepare_session_tab(info, pending_session)
    local loading = require("jpr.views.loading")
    local initial_view = (type(info.title) == "string" and info.title ~= "")
        and { pr = { number = info.number, title = info.title } }
        or {}
    local is_reusing = pending_session ~= nil and vim.api.nvim_tabpage_is_valid(pending_session.tab)
    local session = is_reusing and pending_session or {}
    if is_reusing then
        local is_switched, switch_error = pcall(vim.api.nvim_set_current_tabpage, session.tab)
        if not is_switched then
            forget(session)
            jpr().error("could not switch to loading tab: " .. crash.build_clean_text_from_raw(switch_error))
            return nil
        end
    else
        vim.cmd("tabnew")
        session.tab = vim.api.nvim_get_current_tabpage()
        session.placeholder_buf = vim.api.nvim_get_current_buf()
    end
    session.mode = "pr"
    session.number, session.repo, session.worktree = info.number, info.repo, info.worktree
    session.view, session.process = initial_view, nil
    -- Escaped: Ex commands expand `%` and `#` in a path.
    local is_tcd_ok, tcd_error = pcall(vim.cmd.tcd, vim.fn.fnameescape(info.worktree))
    if not is_tcd_ok then
        forget(session)
        jpr().error("could not enter worktree: " .. crash.build_clean_text_from_raw(tcd_error))
        return nil
    end
    if session.loading then
        loading.update(session, { number = info.number, title = info.title, stage = 2, detail = "" })
    elseif not is_reusing or is_empty_unnamed_buffer(vim.api.nvim_get_current_buf()) then
        session.placeholder_buf = session.placeholder_buf or vim.api.nvim_get_current_buf()
        loading.open(session, { number = info.number, title = info.title, stage = 2 })
        wipe_placeholder(session)
    end
    return session
end

--- Opens a tab for a checked-out PR and starts its engine, reusing an existing
--- `pending_session` loading tab when provided.
--- info: { worktree, repo = "owner/name", number, title? }.
function M.start(info, pending_session)
    jpr().define_highlights()
    setup_session_autocmds()
    local session = prepare_session_tab(info, pending_session)
    if not session then
        return
    end
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

--- Opens a tab for an unlinked local worktree review and starts `serve --local`.
--- info: { worktree, branch, baseRef, baseSha, repo? }.
function M.start_local(info)
    jpr().define_highlights()
    setup_session_autocmds()
    vim.cmd("tabnew")
    local session = {
        mode = "local",
        tab = vim.api.nvim_get_current_tabpage(),
        placeholder_buf = vim.api.nvim_get_current_buf(),
        worktree = info.worktree,
        branch = info.branch,
        base_ref = info.baseRef,
        repo = info.repo,
        view = {
            localContext = {
                branch = info.branch,
                baseRef = info.baseRef,
                baseSha = info.baseSha,
                repo = info.repo,
            },
        },
    }
    local is_tcd_ok, tcd_error = pcall(vim.cmd.tcd, vim.fn.fnameescape(info.worktree))
    if not is_tcd_ok then
        forget(session)
        return jpr().error("could not enter worktree: " .. crash.build_clean_text_from_raw(tcd_error))
    end
    require("jpr.views.diff").attach(session)
    local is_opened, open_error = pcall(panel.open, session)
    if not is_opened then
        forget(session)
        return jpr().error("could not open the panel: " .. tostring(open_error))
    end
    spawn_engine(session)
end

--- Whether the pull request's head/base commit or local base SHA moved between
--- `previous_view` and `view`, which changes every diff.
function M.have_commits_changed(previous_view, view)
    local previous_pr, current_pr = previous_view and previous_view.pr, view.pr
    if previous_pr and current_pr then
        if previous_pr.headSha == nil and previous_pr.baseSha == nil then
            return false
        end
        return previous_pr.headSha ~= current_pr.headSha or previous_pr.baseSha ~= current_pr.baseSha
    end
    local previous_local = previous_view and previous_view.localContext
    local current_local = view.localContext
    if previous_local and current_local then
        return previous_local.baseSha ~= current_local.baseSha
    end
    return (previous_local ~= nil and current_pr ~= nil)
end

local function upgrade_local_session_to_pr(session, pr)
    session.mode = "pr"
    session.number = pr.number
    if type(pr.owner) == "string" and type(pr.repo) == "string" then
        session.repo = pr.owner .. "/" .. pr.repo
    end
    local title = type(pr.title) == "string" and pr.title or ""
    local suffix = title ~= "" and (": " .. crash.build_clean_text_from_raw(title)) or ""
    jpr().info(("Linked to PR #%d%s"):format(pr.number, suffix))
end

--- Keeps `view` as the session's latest and redraws from it: the panel
--- always, and the stream and the diffs once the PR or local context is known.
function M.show(session, view)
    if session.is_read_only and type(view) == "table" then
        view.isReadOnly = true
    end
    local previous_view = session.view
    local has_synced_pr = type(view.pr) == "table"
    local has_local_context = type(view.localContext) == "table"
    if has_synced_pr and session.mode == "local" then
        upgrade_local_session_to_pr(session, view.pr)
    end
    if
        not has_synced_pr
        and previous_view
        and type(previous_view.pr) == "table"
        and previous_view.pr.headSha == nil
        and previous_view.pr.baseSha == nil
    then
        view = vim.tbl_extend("force", view, { pr = previous_view.pr })
    end
    session.view = view
    panel.render(session, view)
    if (not has_synced_pr and not has_local_context) or session.is_read_only then
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

require("jpr.session.open").attach(M)
require("jpr.session.open_local").attach(M)
require("jpr.session.commands").attach(M, forget)
require("jpr.session.comments").attach(M)

return M
