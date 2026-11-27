-- RPC request dispatch, progress toast lifecycle, auth-prompt retry, and
-- read-only error reporting for review sessions.
local progress = require("jpr.session.progress")

local M = {}

local function jpr()
    return require("jpr")
end

--- Reports that `session` is in read-only mode after an engine crash.
function M.report_read_only(session_mod, session)
    local reopen_hint = session.number and (":Jpr open %d"):format(session.number) or ":Jpr local"
    return jpr().error(
        ("%s is in read-only mode after an engine crash; run :Jpr close and %s"):format(
            session_mod.display_label(session),
            reopen_hint
        )
    )
end

local function build_success_message(opts, result)
    local message = opts and opts.success_message
    if type(message) == "function" then
        return message(result)
    end
    return type(message) == "string" and message or nil
end

local function handle_request_error(session_mod, session, method, params, on_result, on_error, opts, progress_handle, request_error)
    if session.closing then
        if progress_handle then
            progress_handle:cancel()
        end
        if on_error then
            on_error(request_error)
        end
        return
    end
    local auth = require("jpr.auth")
    if auth.is_rpc_auth_error(request_error) then
        if progress_handle then
            progress_handle:cancel()
        end
        return auth.prompt_and_resume({
            is_background = false,
            on_authenticated = function()
                if session.closing or not session.client then
                    return
                end
                session_mod.request(session, method, params, on_result, on_error, opts)
            end,
            on_cancel = function()
                if on_error then
                    on_error(request_error)
                end
            end,
        })
    end
    if on_error then
        on_error(request_error)
    end
    local error_message = ("%s failed: %s"):format(method, request_error.message)
    if progress_handle then
        return progress_handle:fail(error_message)
    end
    return jpr().error(error_message)
end

--- Sends `method` with `params` to `session`'s engine, handling read-only guards,
--- progress toasts, and interactive auth retries.
function M.send(session_mod, session, method, params, on_result, on_error, opts)
    if session.is_read_only then
        if on_error then
            on_error()
        end
        return M.report_read_only(session_mod, session)
    end
    if not session.client then
        if on_error then
            on_error()
        end
        local reopen_hint = session.number and (":Jpr open %d"):format(session.number) or ":Jpr local"
        return jpr().error(
            ("the review engine for %s is not running; run %s"):format(session_mod.display_label(session), reopen_hint)
        )
    end
    local progress_handle = progress.start(session, method, params, opts)
    session.client:request(method, params, function(request_error, result)
        if request_error then
            return handle_request_error(
                session_mod,
                session,
                method,
                params,
                on_result,
                on_error,
                opts,
                progress_handle,
                request_error
            )
        end
        if progress_handle then
            local success_message = build_success_message(opts, result)
            if success_message then
                progress_handle:succeed(success_message)
            else
                progress_handle:cancel()
            end
        end
        on_result(result)
    end)
end

return M
