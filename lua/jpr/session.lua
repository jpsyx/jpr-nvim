-- One open pull-request review per tab: the checkout, the engine process, and
-- the panel. Every review rule lives in the engine; this only wires it up.
local rpc = require("jpr.rpc")
local panel = require("jpr.views.panel")

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

--- Sends `method` with `params` to `session`'s engine. `on_result(result)`
--- runs on success; a failure is passed to `on_error`, when given, and
--- reported to the user unless the session is closing (a request still in
--- flight then fails because the engine was stopped on purpose).
function M.request(session, method, params, on_result, on_error)
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
    local args = { config.binary, "checkout", "--pr", tostring(number) }
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
    if vim.fn.executable(jpr().config.binary) ~= 1 then
        return jpr().error(("%s is not installed or not on PATH"):format(jpr().config.binary))
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

--- Checks the engine speaks our protocol, then loads and syncs the view. A
--- failed handshake stops the engine and forgets the session.
local function handshake(session, client)
    client:request("initialize", { protocolVersion = rpc.PROTOCOL_VERSION, client = "jpr.nvim" }, function(init_err, result)
        if init_err then
            -- An engine that died is forgotten and reported by on_exit, with its stderr.
            if client.exited then
                return
            end
            forget(session)
            return jpr().error("could not start the review engine: " .. init_err.message)
        end
        if result.protocolVersion ~= rpc.PROTOCOL_VERSION then
            forget(session)
            return jpr().error(
                ("protocol mismatch: the plugin speaks %d and %s speaks %d; install both from the same checkout"):format(
                    rpc.PROTOCOL_VERSION,
                    jpr().config.binary,
                    result.protocolVersion
                )
            )
        end
        session.ready = true
        client:request("snapshot", nil, function(_, view)
            if view then
                M.show(session, view)
            end
        end)
        M.sync(session)
    end)
end

--- Opens a tab for a checked-out PR and starts its engine.
--- info: { worktree, repo = "owner/name", number }.
function M.start(info)
    jpr().define_highlights()
    vim.api.nvim_create_autocmd("TabClosed", {
        group = vim.api.nvim_create_augroup("jpr-session", { clear = true }),
        callback = M.forget_closed_tabs,
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
    local opened, open_err = pcall(panel.open, session)
    if not opened then
        forget(session)
        return jpr().error("could not open the panel: " .. open_err)
    end

    local client, err = rpc.start({ jpr().config.binary, "serve", "--pr", tostring(info.number), "--repo", info.repo }, {
        cwd = info.worktree,
        on_notification = function(method, params)
            M.on_notification(session, method, params)
        end,
        on_exit = function(code, stderr)
            M.on_exit(session, code, stderr)
        end,
    })
    if not client then
        forget(session)
        return jpr().error(err)
    end
    session.client = client
    M.by_tab[tab] = session
    handshake(session, client)
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
    local previous_view = session.view
    session.view = view
    panel.render(session, view)
    if not view.pr then
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

--- Asks the engine to sync `session` with GitHub now; the panel, the stream
--- and the diffs redraw from the answer, and a failure is reported to the
--- user.
function M.sync(session)
    if not session.client then
        return jpr().error(
            ("the review engine for PR #%d is not running; run :Jpr open %d"):format(session.number, session.number)
        )
    end
    session.client:request("sync", nil, function(err, view)
        if err then
            return jpr().error("sync failed: " .. err.message)
        end
        M.show(session, view)
    end)
end

--- Handles a notification from `session`'s engine: `synced`, `viewedChanged`,
--- and `threadsChanged` redraw from `params.view`, `syncFailed` updates the
--- panel, and a protocol error is reported to the user.
function M.on_notification(session, method, params)
    if method == "event" and params and (params.type == "synced" or params.type == "viewedChanged") then
        M.show(session, params.view)
    elseif method == "event" and params and params.type == "threadsChanged" then
        session.view = params.view
        panel.render(session, params.view)
        require("jpr.views.diff").redraw_threads(session)
        require("jpr.views.stream").refresh(session, true)
        local conversation = package.loaded["jpr.views.conversation"]
        if conversation and conversation.refresh then
            conversation.refresh(session)
        end
    elseif method == "event" and params and params.type == "syncFailed" then
        session.view.sync = { state = "failed", at = os.time(), message = params.message }
        panel.render(session, session.view)
    elseif method == "protocolError" then
        jpr().error(params.message)
    end
end

--- Handles `session`'s engine exiting. An exit the session did not ask for
--- forgets the session and reports the exit code and the engine's stderr.
function M.on_exit(session, code, stderr)
    session.client = nil
    if session.closing then
        return
    end
    forget(session)
    local detail = (stderr and stderr ~= "") and (": " .. stderr) or ""
    jpr().error(("the review engine for PR #%d stopped (exit %d)%s"):format(session.number, code, detail))
end

--- `:Jpr sync`: syncs the current tab's session now.
function M.sync_current()
    local session = M.current()
    if not session then
        return jpr().error("no pull request is open in this tab")
    end
    M.sync(session)
end

--- `:Jpr close`: stops the current tab's engine, closes the tab (unless it is
--- the last one) and forgets the session.
function M.close_current()
    local session = M.current()
    if not session then
        return jpr().error("no pull request is open in this tab")
    end
    forget(session, true)
end

--- `:Jpr toggle`: flips every review between unified and split views, and
--- remembers the choice.
function M.toggle_view()
    local mode = require("jpr.view_mode").toggle()
    for _, session in pairs(M.by_tab) do
        require("jpr.views.diff").redraw_all(session)
        require("jpr.views.stream").refresh(session, true)
    end
    jpr().info(("%s view"):format(mode))
end

--- `:Jpr stream`: shows the current review's stream beside the panel and
--- focuses it.
function M.stream_current()
    local session = M.current()
    if not session then
        return jpr().error("no pull request is open in this tab")
    end
    require("jpr.views.stream").show(session, { focus = true })
end

--- `:Jpr expand`: toggles inline thread expansion across diff and stream buffers.
function M.expand_current()
    local session = M.current()
    if not session then
        return jpr().error("no pull request is open in this tab")
    end
    session.threads_expanded = not session.threads_expanded
    require("jpr.views.threads").redraw_all(session)
    require("jpr.views.stream").refresh(session, true)
end

local function is_stream_buffer(session, buf)
    local buffers = session.stream and session.stream.buffers
    return buffers ~= nil and (buf == buffers.main or buf == buffers.left)
end

--- Jumps to the next (`step == 1`) or previous (`step == -1`) review thread in
--- the active diff or stream buffer.
function M.jump_thread_current(step)
    local session = M.current()
    if not session then
        return jpr().error("no pull request is open in this tab")
    end
    local buf = vim.api.nvim_get_current_buf()
    if is_stream_buffer(session, buf) then
        return require("jpr.views.stream").jump(session, "threads", step)
    end
    require("jpr.views.threads").jump(session, step)
end

--- Opens the floating thread popup for the review thread(s) at the cursor
--- in the active diff or stream buffer.
function M.popup_current()
    local session = M.current()
    if not session then
        return jpr().error("no pull request is open in this tab")
    end
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local threads
    if is_stream_buffer(session, buf) then
        threads = require("jpr.views.stream").threads_at_cursor(session, line, win)
    else
        threads = require("jpr.views.threads").threads_at_cursor(session, buf, line)
    end
    require("jpr.comments.popup").open(session, threads)
end

local function resolve_line_range(win, opts)
    local has_range = (opts.range ~= nil and opts.range > 0) or (opts.range == nil and opts.line1 ~= nil)
    if has_range then
        local first_input = opts.line1
        local second_input = opts.line2 or first_input
        return math.min(first_input, second_input), math.max(first_input, second_input)
    end
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
    return cursor_line, cursor_line
end

local function resolve_stream_anchor(session, win, opts)
    local stream = require("jpr.views.stream")
    if opts.file then
        local layout = session.stream and session.stream.layout
        local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
        local file = layout and require("jpr.render.stream").find_file_at_line(layout, cursor_line)
        if not file then
            return nil, "no changed file under the cursor"
        end
        return { file = file.path, kind = "file", side = "RIGHT" }
    end
    local first, last = resolve_line_range(win, opts)
    local anchor = stream.anchor_at_range(session, win, first, last)
    if not anchor then
        return nil, "cannot anchor a comment on this line or range"
    end
    return anchor
end

local function resolve_diff_anchor(session, win, buf, opts)
    local path = vim.b[buf].jpr_base_path
    local side = "LEFT"
    if type(path) ~= "string" or path == "" then
        path = require("jpr.views.diff").buffer_to_changed_path(session, buf)
        side = "RIGHT"
    end
    if not path then
        return nil, "move to a changed file or the review stream to comment"
    end
    if opts.file then
        return { file = path, kind = "file", side = "RIGHT" }
    end
    local first, last = resolve_line_range(win, opts)
    local kind = "line"
    if first ~= last then
        kind = "range"
    end
    return { file = path, kind = kind, side = side, start = first, ["end"] = last }
end

--- Opens the comment compose buffer anchored to the current diff line,
--- visual range, base buffer line, stream row, or file (`opts.file`).
function M.comment_current(opts)
    local session = M.current()
    if not session then
        return jpr().error("no pull request is open in this tab")
    end
    local comment_opts = opts or {}
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local anchor, err_msg
    if is_stream_buffer(session, buf) then
        anchor, err_msg = resolve_stream_anchor(session, win, comment_opts)
    else
        anchor, err_msg = resolve_diff_anchor(session, win, buf, comment_opts)
    end
    if not anchor then
        return jpr().error(err_msg)
    end
    require("jpr.comments.compose").open_new(session, anchor, { suggest = comment_opts.suggest == true })
end

--- `:Jpr conversation`: opens the pull request's top-level conversation
--- buffer in the main window beside the panel.
function M.conversation_current()
    local session = M.current()
    if not session then
        return jpr().error("no pull request is open in this tab")
    end
    require("jpr.views.conversation").show(session)
end

--- `:Jpr suggest`: turns the local edit at the cursor line into a GitHub
--- draft suggestion comment and reverts just that hunk.
function M.suggest_current()
    local session = M.current()
    if not session then
        return jpr().error("no pull request is open in this tab")
    end
    require("jpr.comments.suggest").run(session)
end

--- `:Jpr submit`: opens the review submission modal for the current PR.
function M.submit_current()
    local session = M.current()
    if not session then
        return jpr().error("no pull request is open in this tab")
    end
    require("jpr.views.submit").open(session)
end

return M
