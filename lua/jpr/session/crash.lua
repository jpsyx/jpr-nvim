-- Crash logging, single auto-restart, read-only fallback, and display-text
-- sanitization for unexpected review engine exits.
local panel = require("jpr.views.panel")

local M = {}

local function jpr()
    return require("jpr")
end

--- Collapses line breaks and tabs to single spaces and strips ASCII control bytes.
function M.build_clean_text_from_raw(raw_text)
    if type(raw_text) ~= "string" then
        return ""
    end
    local collapsed = raw_text:gsub("[\r\n\t]+", " ")
    return vim.trim((collapsed:gsub("%c", "")))
end

local function sanitize_log_slug(value)
    local slug = tostring(value or "local"):gsub("[^%w%-_]+", "-")
    slug = slug:gsub("^%-+", ""):gsub("%-+$", "")
    return slug ~= "" and slug or "local"
end

--- Human-readable label for `session` (`PR #7` or `local review (feat/x)`).
function M.build_session_label(session)
    if type(session) == "table" and type(session.number) == "number" then
        return ("PR #%d"):format(session.number)
    end
    local branch = type(session) == "table"
            and ((session.view and session.view.localContext and session.view.localContext.branch) or session.branch)
        or "worktree"
    return ("local review (%s)"):format(M.build_clean_text_from_raw(branch))
end

--- Builds the state-directory crash log file path for pull request `pr_number`
--- or local branch identifier when `pr_number` is nil/non-numeric.
function M.build_log_path_from_number(pr_number, branch)
    if type(pr_number) == "number" then
        return vim.fn.stdpath("state") .. "/jpr/engine-pr-" .. tostring(pr_number) .. ".log"
    end
    return vim.fn.stdpath("state") .. "/jpr/engine-local-" .. sanitize_log_slug(branch) .. ".log"
end

--- Appends a timestamped crash entry (`exit_code` and `stderr`) for `pr_number`
--- with mode `0700` directory / `0600` file permissions and returns the path.
function M.append_crash_log(pr_number, exit_code, stderr, branch)
    local log_path = M.build_log_path_from_number(pr_number, branch)
    pcall(vim.fn.mkdir, vim.fs.dirname(log_path), "p", tonumber("700", 8))
    local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local lines = { ("[%s] engine exited with code %s"):format(timestamp, tostring(exit_code)) }
    if type(stderr) == "string" and stderr ~= "" then
        for line in stderr:gmatch("[^\r\n]+") do
            lines[#lines + 1] = line
        end
    end
    pcall(vim.fn.writefile, lines, log_path, "a")
    pcall(vim.uv.fs_chmod, log_path, tonumber("600", 8))
    return log_path
end

--- Switches `session` into read-only mode after a second crash or failed
--- restart handshake, keeping its tab and buffers open with `[read-only]`.
function M.transition_to_read_only(session, exit_code, log_path, extra_detail)
    session.client = nil
    session.is_read_only = true
    session.view = type(session.view) == "table" and session.view or {}
    session.view.isReadOnly = true
    panel.render(session, session.view)
    local clean_detail = M.build_clean_text_from_raw(extra_detail)
    local suffix = clean_detail ~= "" and (": " .. clean_detail) or ""
    jpr().error(
        ("the review engine for %s crashed again (exit %s)%s; session is now read-only (see %s)"):format(
            M.build_session_label(session),
            tostring(exit_code),
            suffix,
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
    local label = M.build_session_label(session)
    if not session.ready then
        callbacks.forget(session)
        local clean_stderr = M.build_clean_text_from_raw(stderr)
        local detail = clean_stderr ~= "" and (": " .. clean_stderr) or ""
        return jpr().error(("the review engine for %s stopped (exit %s)%s"):format(label, tostring(exit_code), detail))
    end
    local log_path = M.append_crash_log(session.number, exit_code, stderr, session.branch)
    if not session.has_restarted then
        session.has_restarted = true
        session.client = nil
        jpr().warn(("the review engine for %s exited (code %s); restarting once (log: %s)"):format(label, tostring(exit_code), log_path))
        local did_spawn = callbacks.spawn(session)
        if not did_spawn then
            M.transition_to_read_only(session, exit_code, log_path)
        end
        return
    end
    M.transition_to_read_only(session, exit_code, log_path)
end

return M
