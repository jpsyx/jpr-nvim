-- Crash logging, single auto-restart, and read-only fallback for unexpected
-- review engine exits after a session has finished starting.
local panel = require("jpr.views.panel")

local M = {}

local function jpr()
    return require("jpr")
end

--- Builds the state-directory crash log file path for pull request `pr_number`.
function M.build_log_path_from_number(pr_number)
    return vim.fn.stdpath("state") .. "/jpr/engine-pr-" .. tostring(pr_number) .. ".log"
end

--- Appends a timestamped crash entry (`exit_code` and `stderr`) for `pr_number`
--- and returns the crash log path.
function M.append_crash_log(pr_number, exit_code, stderr)
    local log_path = M.build_log_path_from_number(pr_number)
    pcall(vim.fn.mkdir, vim.fs.dirname(log_path), "p")
    local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local lines = { ("[%s] engine exited with code %s"):format(timestamp, tostring(exit_code)) }
    if type(stderr) == "string" and stderr ~= "" then
        for line in stderr:gmatch("[^\r\n]+") do
            lines[#lines + 1] = line
        end
    end
    pcall(vim.fn.writefile, lines, log_path, "a")
    return log_path
end

--- Switches `session` into read-only mode after a second crash, keeping its tab
--- and buffers open with `[read-only]` rendered in the panel.
function M.transition_to_read_only(session, exit_code, log_path)
    session.client = nil
    session.is_read_only = true
    session.view = type(session.view) == "table" and session.view or {}
    session.view.isReadOnly = true
    panel.render(session, session.view)
    jpr().error(
        ("the review engine for PR #%d crashed again (exit %s); session is now read-only (see %s)"):format(
            session.number,
            tostring(exit_code),
            log_path
        )
    )
end

--- Handles an unexpected exit of `session`'s engine: forgets startup failures,
--- restarts once mid-review, and transitions to read-only on a second crash.
function M.handle_unexpected_exit(session, exit_code, stderr, callbacks)
    if session.closing or session.is_read_only or vim.v.exiting ~= vim.NIL or vim.v.dying > 0 then
        return
    end
    if callbacks.is_registered and not callbacks.is_registered(session) then
        return
    end
    if not session.ready then
        callbacks.forget(session)
        local detail = (stderr and stderr ~= "") and (": " .. stderr) or ""
        return jpr().error(("the review engine for PR #%d stopped (exit %s)%s"):format(session.number, tostring(exit_code), detail))
    end
    local log_path = M.append_crash_log(session.number, exit_code, stderr)
    if not session.has_restarted then
        session.has_restarted = true
        session.client = nil
        jpr().warn(("the review engine for PR #%d exited (code %s); restarting once (log: %s)"):format(session.number, tostring(exit_code), log_path))
        local did_spawn = callbacks.spawn(session)
        if not did_spawn then
            M.transition_to_read_only(session, exit_code, log_path)
        end
        return
    end
    M.transition_to_read_only(session, exit_code, log_path)
end

return M
