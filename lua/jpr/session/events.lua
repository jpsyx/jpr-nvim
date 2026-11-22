-- Handles engine JSON-RPC notifications (`event`, `protocolError`) and
-- unexpected engine process exits for an active review session.
local panel = require("jpr.views.panel")

local M = {}

local function jpr()
    return require("jpr")
end

local function handle_event_notification(session, params, show_session)
    if params.type == "synced" or params.type == "viewedChanged" then
        show_session(session, params.view)
    elseif params.type == "threadsChanged" then
        session.view = params.view
        panel.render(session, params.view)
        require("jpr.views.diff").redraw_threads(session)
        require("jpr.views.stream").refresh(session, true)
        local conversation = package.loaded["jpr.views.conversation"]
        if conversation and conversation.refresh then
            conversation.refresh(session)
        end
    elseif params.type == "filesChanged" then
        session.view = params.view or session.view
        -- Guarded with pcall: Ex checktime errors inside the command-line window (`q:`).
        pcall(vim.cmd, "silent! checktime")
        panel.render(session, session.view)
        require("jpr.views.diff").redraw_all(session)
        require("jpr.views.stream").refresh(session, true)
    elseif params.type == "agentRound" then
        session.view = params.view or session.view
        panel.render(session, session.view)
        require("jpr.views.diff").redraw_threads(session)
        require("jpr.views.stream").refresh(session, true)
    elseif params.type == "syncFailed" then
        session.view.sync = { state = "failed", at = os.time(), message = params.message }
        panel.render(session, session.view)
    end
end

--- Updates `session`'s views and error reporting in response to engine notifications.
function M.on_notification(session, method, params, show_session)
    if method == "event" and params then
        handle_event_notification(session, params, show_session)
    elseif method == "protocolError" then
        jpr().error(params.message)
    end
end

--- Handles `session`'s engine exiting. An exit the session did not ask for
--- forgets the session and reports the exit code and the engine's stderr.
function M.on_exit(session, code, stderr, forget_session)
    session.client = nil
    if session.closing then
        return
    end
    forget_session(session)
    local detail = (stderr and stderr ~= "") and (": " .. stderr) or ""
    jpr().error(("the review engine for PR #%d stopped (exit %d)%s"):format(session.number, code, detail))
end

return M
