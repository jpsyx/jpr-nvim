-- One open pull-request review per tab: the checkout, the engine process, and
-- the panel. Every review rule lives in the engine; this only wires it up.
local rpc = require("jpr.rpc")
local panel = require("jpr.views.panel")

local M = {}

M.by_tab = {}

local function jpr()
    return require("jpr")
end

function M.current()
    return M.by_tab[vim.api.nvim_get_current_tabpage()]
end

--- The `jpr-review checkout` command for PR `number`.
function M.checkout_args(number)
    local config = jpr().config
    local args = { config.binary, "checkout", "--pr", tostring(number) }
    if config.worktree_cmd then
        vim.list_extend(args, { "--worktree-cmd", config.worktree_cmd })
    end
    return args
end

--- The JSON object on the last non-empty line of `checkout`'s stdout.
function M.parse_checkout(stdout)
    local last
    for line in (stdout or ""):gmatch("[^\n]+") do
        if vim.trim(line) ~= "" then
            last = line
        end
    end
    if not last then
        return nil, "jpr-review checkout printed nothing"
    end
    local ok, info = pcall(vim.json.decode, last)
    if not ok or type(info) ~= "table" or not info.worktree or not info.repo then
        return nil, "unexpected checkout output: " .. last
    end
    return info
end

--- `:Jpr open <number>`: reuse its tab, or check it out and start a session.
function M.open(number)
    for tab, existing in pairs(M.by_tab) do
        if existing.number == number and vim.api.nvim_tabpage_is_valid(tab) then
            return vim.api.nvim_set_current_tabpage(tab)
        end
    end
    if vim.fn.executable(jpr().config.binary) ~= 1 then
        return jpr().error(("%s is not installed or not on PATH"):format(jpr().config.binary))
    end
    jpr().info(("checking out PR #%d…"):format(number))
    vim.system(M.checkout_args(number), { cwd = vim.fn.getcwd(), text = true }, vim.schedule_wrap(function(result)
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

--- Drops `session` from its tab and wipes its panel, so `:Jpr open` starts a
--- fresh engine and can name a new panel after the same pull request.
local function unregister(session)
    if M.by_tab[session.tab] == session then
        M.by_tab[session.tab] = nil
        panel.close(session)
    end
end

--- Shuts down `session`'s engine on purpose, so its exit is not reported.
local function stop_engine(session)
    session.closing = true
    if session.client then
        session.client:request("shutdown", nil, function() end)
        session.client:stop()
    end
end

--- Stops the engines of sessions whose tab was closed, e.g. by `:tabclose`.
function M.forget_closed_tabs()
    for tab, session in pairs(M.by_tab) do
        if not vim.api.nvim_tabpage_is_valid(tab) then
            stop_engine(session)
            M.by_tab[tab] = nil
        end
    end
end

--- Checks the engine speaks our protocol, then loads and syncs the view. A
--- failed handshake stops the engine and forgets the session.
local function handshake(session, client)
    client:request("initialize", { protocolVersion = rpc.PROTOCOL_VERSION, client = "jpr.nvim" }, function(init_err, result)
        if init_err then
            unregister(session)
            -- An engine that died is reported by on_exit, with its stderr.
            if client.exited then
                return
            end
            stop_engine(session)
            return jpr().error("could not start the review engine: " .. init_err.message)
        end
        if result.protocolVersion ~= rpc.PROTOCOL_VERSION then
            unregister(session)
            stop_engine(session)
            return jpr().error(
                ("protocol mismatch: the plugin speaks %d and %s speaks %d; install both from the same checkout"):format(
                    rpc.PROTOCOL_VERSION,
                    jpr().config.binary,
                    result.protocolVersion
                )
            )
        end
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
    vim.cmd.tcd(info.worktree)
    local tab = vim.api.nvim_get_current_tabpage()
    local session = { number = info.number, repo = info.repo, worktree = info.worktree, tab = tab, view = {} }
    -- Registered only once the panel and the engine are up, so a failure here
    -- never leaves a half-built session for `:Jpr open` to refocus.
    local opened, open_err = pcall(panel.open, session)
    if not opened then
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
        panel.close(session)
        return jpr().error(err)
    end
    session.client = client
    M.by_tab[tab] = session
    handshake(session, client)
end

function M.show(session, view)
    session.view = view
    panel.render(session, view)
end

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

function M.on_notification(session, method, params)
    if method == "event" and params and params.type == "synced" then
        M.show(session, params.view)
    elseif method == "event" and params and params.type == "syncFailed" then
        session.view.sync = { state = "failed", at = os.time(), message = params.message }
        panel.render(session, session.view)
    elseif method == "protocolError" then
        jpr().error(params.message)
    end
end

function M.on_exit(session, code, stderr)
    session.client = nil
    unregister(session)
    if session.closing then
        return
    end
    local detail = (stderr and stderr ~= "") and (": " .. stderr) or ""
    jpr().error(("the review engine for PR #%d stopped (exit %d)%s"):format(session.number, code, detail))
end

function M.sync_current()
    local session = M.current()
    if not session then
        return jpr().error("no pull request is open in this tab")
    end
    M.sync(session)
end

function M.close_current()
    local session = M.current()
    if not session then
        return jpr().error("no pull request is open in this tab")
    end
    stop_engine(session)
    M.by_tab[session.tab] = nil
    if vim.api.nvim_tabpage_is_valid(session.tab) and #vim.api.nvim_list_tabpages() > 1 then
        vim.api.nvim_set_current_tabpage(session.tab)
        vim.cmd("tabclose")
    end
end

return M
