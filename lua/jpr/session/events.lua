-- Handles engine JSON-RPC notifications (`event`, `protocolError`) for an
-- active pull-request review session, including worktree status and head moves.
local panel = require("jpr.views.panel")

local M = {}

local function jpr()
    return require("jpr")
end

local function build_clean_text_from_raw(raw_text)
    if type(raw_text) ~= "string" then
        return ""
    end
    local collapsed = raw_text:gsub("[\r\n\t]+", " ")
    return vim.trim((collapsed:gsub("%c", "")))
end

local function apply_session_view(session, incoming_view)
    if type(incoming_view) == "table" then
        session.view = incoming_view
    end
    if session.is_read_only == true and type(session.view) == "table" then
        session.view.isReadOnly = true
    end
end

local function is_safe_worktree_path(session, candidate)
    if type(candidate) ~= "string" or candidate == "" or candidate:find("%c") ~= nil then
        return false
    end
    local full_path = session.worktree .. "/" .. candidate
    return require("jpr.views.diff").name_to_relative_path(session.worktree, full_path) == candidate
end

local function collect_safe_conflicted_paths(session, raw_paths)
    if type(raw_paths) ~= "table" then
        return {}
    end
    local safe_paths = {}
    for _, candidate in ipairs(raw_paths) do
        if is_safe_worktree_path(session, candidate) then
            safe_paths[#safe_paths + 1] = candidate
        end
    end
    return safe_paths
end

local function prompt_conflict_resolution(session, raw_paths, fallback_detail)
    local safe_paths = collect_safe_conflicted_paths(session, raw_paths)
    if #safe_paths == 0 then
        local fallback = ("PR #%d fast-forwarded with restore conflicts"):format(session.number)
        return jpr().warn(fallback_detail ~= "" and fallback_detail or fallback)
    end
    local choices = { "Resolve myself", "Ask agent to resolve" }
    local prompt = ("PR #%d fast-forwarded with conflicts in %d file(s):"):format(session.number, #safe_paths)
    vim.ui.select(choices, { prompt = prompt }, function(choice)
        if session.closing or not vim.api.nvim_tabpage_is_valid(session.tab) then
            return
        end
        if choice == "Resolve myself" then
            local main_window = require("jpr.views.main_window")
            main_window.edit(session, main_window.find(session), safe_paths[1])
        elseif choice == "Ask agent to resolve" then
            require("jpr.agent").resolve_conflicts(session, safe_paths)
        end
    end)
end

local function handle_head_moved(session, params, show_session)
    pcall(vim.cmd, "silent! checktime")
    if type(params.view) == "table" then
        show_session(session, params.view)
    end
    local short_head = build_clean_text_from_raw(params.headSha):sub(1, 7)
    local short_previous = build_clean_text_from_raw(params.previousSha):sub(1, 7)
    local detail = build_clean_text_from_raw(params.message)
    local outcome = params.outcome
    if outcome == "fastForwarded" then
        local transition = (short_previous ~= "" and short_head ~= "") and (short_previous .. " -> " .. short_head) or short_head
        jpr().info(("PR #%d fast-forwarded (%s)"):format(session.number, transition))
    elseif outcome == "aheadOfTarget" then
        if detail ~= "" then
            jpr().info(detail)
        end
    elseif outcome == "diverged" or outcome == "failed" then
        local fallback = ("PR #%d head moved to %s (%s)"):format(session.number, short_head, tostring(outcome))
        jpr().warn(detail ~= "" and detail or fallback)
    elseif outcome == "restoreConflict" then
        prompt_conflict_resolution(session, params.conflictedPaths, detail)
    end
end

local function handle_event_notification(session, params, show_session)
    if params.type == "synced" or params.type == "viewedChanged" then
        show_session(session, params.view)
    elseif params.type == "threadsChanged" then
        apply_session_view(session, params.view)
        panel.render(session, session.view)
        require("jpr.views.diff").redraw_threads(session)
        require("jpr.views.stream").refresh(session, true)
        local conversation = package.loaded["jpr.views.conversation"]
        if conversation and conversation.refresh then
            conversation.refresh(session)
        end
    elseif params.type == "filesChanged" then
        apply_session_view(session, params.view)
        -- Guarded with pcall: Ex checktime errors inside the command-line window (`q:`).
        pcall(vim.cmd, "silent! checktime")
        panel.render(session, session.view)
        require("jpr.views.diff").redraw_all(session)
        require("jpr.views.stream").refresh(session, true)
    elseif params.type == "agentRound" then
        apply_session_view(session, params.view)
        panel.render(session, session.view)
        require("jpr.views.diff").redraw_threads(session)
        require("jpr.views.stream").refresh(session, true)
    elseif params.type == "worktreeStatusChanged" then
        apply_session_view(session, params.view)
        panel.render(session, session.view)
    elseif params.type == "headMoved" then
        handle_head_moved(session, params, show_session)
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
        jpr().error(build_clean_text_from_raw(params and params.message))
    end
end

return M
