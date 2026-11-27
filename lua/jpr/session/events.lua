-- Handles engine JSON-RPC notifications (`event`, `protocolError`) for an
-- active pull-request review session, including worktree status and head moves.
local crash = require("jpr.session.crash")
local panel = require("jpr.views.panel")

local M = {}

local function jpr()
    return require("jpr")
end

local function apply_session_view(session, incoming_view)
    if type(incoming_view) == "table" then
        session.view = incoming_view
    end
    if session.is_read_only == true and type(session.view) == "table" then
        session.view.isReadOnly = true
    end
end

local function has_git_segment(path)
    return path == ".git"
        or path:find("^%.git/") ~= nil
        or path:find("/%.git/") ~= nil
        or path:find("/%.git$") ~= nil
end

--- Whether `candidate` is a safe plain relative path inside `session.worktree`
--- with no control bytes and no `.git` path segment.
function M.is_safe_worktree_path(session, candidate)
    if type(candidate) ~= "string" or candidate == "" or candidate:find("%c") ~= nil or has_git_segment(candidate) then
        return false
    end
    local full_path = session.worktree .. "/" .. candidate
    return require("jpr.views.diff").name_to_relative_path(session.worktree, full_path) == candidate
end

--- Filters `raw_paths` down to safe worktree-relative paths for `session`.
function M.collect_safe_worktree_paths(session, raw_paths)
    if type(raw_paths) ~= "table" then
        return {}
    end
    local safe_paths = {}
    for _, candidate in ipairs(raw_paths) do
        if M.is_safe_worktree_path(session, candidate) then
            safe_paths[#safe_paths + 1] = candidate
        end
    end
    return safe_paths
end

local function prompt_conflict_resolution(session, raw_paths, fallback_detail)
    local safe_paths = M.collect_safe_worktree_paths(session, raw_paths)
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

local function refresh_worktree_views_after_head_move(session, did_commits_change, previous_stream_request_id)
    if session.is_read_only or not (session.view and session.view.pr) then
        return
    end
    if not did_commits_change then
        require("jpr.views.diff").redraw_all(session)
    end
    if (session.stream and session.stream.request_id) == previous_stream_request_id then
        require("jpr.views.stream").refresh(session, true)
    end
end

local function handle_head_moved(session, params, show_session)
    local previous_view = session.view
    local previous_stream_request_id = session.stream and session.stream.request_id
    local did_commits_change = type(params.view) == "table"
        and require("jpr.session").have_commits_changed(previous_view, params.view)
    pcall(vim.cmd, "silent! checktime")
    if type(params.view) == "table" then
        show_session(session, params.view)
    end
    local outcome = params.outcome
    if outcome == "fastForwarded" or outcome == "restoreConflict" then
        refresh_worktree_views_after_head_move(session, did_commits_change, previous_stream_request_id)
    end
    local short_head = crash.build_clean_text_from_raw(params.headSha):sub(1, 7)
    local short_previous = crash.build_clean_text_from_raw(params.previousSha):sub(1, 7)
    local detail = crash.build_clean_text_from_raw(params.message)
    if outcome == "fastForwarded" then
        local transition = (short_previous ~= "" and short_head ~= "") and (short_previous .. " -> " .. short_head) or short_head
        local suffix = transition ~= "" and (" (" .. transition .. ")") or ""
        jpr().info(("PR #%d fast-forwarded%s"):format(session.number, suffix))
    elseif outcome == "aheadOfTarget" and detail ~= "" then
        jpr().info(detail)
    elseif outcome == "diverged" or outcome == "failed" then
        local target_label = short_head ~= "" and (" to " .. short_head) or ""
        local fallback = ("PR #%d head moved%s (%s)"):format(session.number, target_label, tostring(outcome))
        jpr().warn(detail ~= "" and detail or fallback)
    elseif outcome == "restoreConflict" then
        prompt_conflict_resolution(session, params.conflictedPaths, detail)
    end
end

local function handle_sync_failed(session, params)
    session.view.sync = { state = "failed", at = os.time(), message = params.message }
    panel.render(session, session.view)
    if session.loading then
        require("jpr.views.loading").close(session)
    end
    if params.authRequired == true then
        require("jpr.auth").prompt_and_resume({
            key = "sync:" .. tostring(session.tab),
            is_background = params.isBackground == true,
            on_authenticated = function()
                if not session.closing and session.client then
                    require("jpr.session").sync(session)
                end
            end,
        })
    end
end

local function pluralize(count, singular, plural)
    return ("%d %s"):format(count, count == 1 and singular or plural)
end

--- Builds a concise human-readable summary for a non-empty `SyncDelta`, or nil.
function M.build_sync_delta_message(session, delta)
    if type(delta) ~= "table" then
        return nil
    end
    local parts = {}
    local files_changed = tonumber(delta.filesChanged) or 0
    local new_comments = tonumber(delta.newComments) or 0
    local updated_comments = tonumber(delta.updatedComments) or 0
    local resolved_threads = tonumber(delta.resolvedThreads) or 0
    local reopened_threads = tonumber(delta.reopenedThreads) or 0
    if files_changed > 0 then
        parts[#parts + 1] = pluralize(files_changed, "file changed", "files changed")
    end
    if new_comments > 0 then
        parts[#parts + 1] = pluralize(new_comments, "new comment", "new comments")
    end
    if updated_comments > 0 then
        parts[#parts + 1] = pluralize(updated_comments, "comment edited", "comments edited")
    end
    if resolved_threads > 0 then
        parts[#parts + 1] = pluralize(resolved_threads, "thread resolved", "threads resolved")
    end
    if reopened_threads > 0 then
        parts[#parts + 1] = pluralize(reopened_threads, "thread reopened", "threads reopened")
    end
    if #parts == 0 then
        return nil
    end
    local prefix = crash.build_session_label(session)
    return ("%s updated: %s"):format(prefix, table.concat(parts, ", "))
end

--- Builds a concise notification message for an `agentReplied` event payload.
function M.build_agent_reply_message(params)
    local author = crash.build_clean_text_from_raw(params and params.author)
    if author == "" then
        author = "agent"
    end
    local file = crash.build_clean_text_from_raw(params and params.file)
    local line = type(params) == "table" and tonumber(params.line) or nil
    if file ~= "" and line ~= nil then
        return ("%s replied on %s:%d"):format(author, file, line)
    end
    if file ~= "" then
        return ("%s replied on %s"):format(author, file)
    end
    return ("%s replied on PR conversation"):format(author)
end

local function refresh_open_thread_views(session, target_thread_id)
    local conversation = package.loaded["jpr.views.conversation"]
    if conversation and conversation.refresh then
        conversation.refresh(session)
    end
    local popup = package.loaded["jpr.comments.popup"]
    if popup and popup.refresh_open then
        popup.refresh_open(session, target_thread_id)
    end
end

local function handle_synced_notification(session, params, show_session)
    show_session(session, params.view)
    local delta = type(params.delta) == "table" and params.delta or nil
    if not delta then
        return
    end
    local has_file_changes = (tonumber(delta.filesChanged) or 0) > 0 or delta.headMoved == true
    local has_comment_changes = (tonumber(delta.newComments) or 0) > 0
        or (tonumber(delta.updatedComments) or 0) > 0
        or (tonumber(delta.resolvedThreads) or 0) > 0
        or (tonumber(delta.reopenedThreads) or 0) > 0
    if has_file_changes then
        require("jpr.views.diff").redraw_all(session)
    end
    if has_comment_changes then
        require("jpr.views.diff").redraw_threads(session)
        refresh_open_thread_views(session, nil)
    end
    if has_file_changes or has_comment_changes then
        require("jpr.views.stream").refresh(session, true)
    end
    local summary = M.build_sync_delta_message(session, delta)
    if summary then
        jpr().info(summary)
    end
end

local function handle_event_notification(session, params, show_session)
    if params.type == "synced" then
        handle_synced_notification(session, params, show_session)
    elseif params.type == "viewedChanged" then
        show_session(session, params.view)
    elseif params.type == "threadsChanged" then
        apply_session_view(session, params.view)
        panel.render(session, session.view)
        require("jpr.views.diff").redraw_threads(session)
        require("jpr.views.stream").refresh(session, true)
        refresh_open_thread_views(session, nil)
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
    elseif params.type == "agentReplied" then
        apply_session_view(session, params.view)
        panel.render(session, session.view)
        refresh_open_thread_views(session, params.threadId)
        jpr().info(M.build_agent_reply_message(params))
    elseif params.type == "agentPrepassWritten" then
        apply_session_view(session, params.view)
        panel.render(session, session.view)
        local count = tonumber(params.count) or 0
        if count > 0 then
            jpr().info("Agent added " .. pluralize(count, "pre-pass finding", "pre-pass findings"))
        end
    elseif params.type == "worktreeStatusChanged" then
        apply_session_view(session, params.view)
        panel.render(session, session.view)
    elseif params.type == "headMoved" then
        handle_head_moved(session, params, show_session)
    elseif params.type == "syncFailed" then
        handle_sync_failed(session, params)
    end
end

local function handle_stream_progress(session, params)
    if type(params) ~= "table" then
        return
    end
    local total = math.max(0, math.floor(tonumber(params.total) or 0))
    local completed = math.max(0, math.min(math.floor(tonumber(params.completed) or 0), total))
    local path = type(params.path) == "string" and params.path or ""
    if session.loading then
        require("jpr.views.loading").update(session, {
            stage = 4,
            progress = { completed = completed, total = total, path = path },
        })
        return
    end
    if total <= 0 then
        return
    end
    if completed >= total then
        if session.stream_progress_handle then
            session.stream_progress_handle:cancel()
            session.stream_progress_handle = nil
        end
        return
    end
    local percent = math.floor((completed * 100) / total + 0.5)
    local clean_path = crash.build_clean_text_from_raw(path)
    local suffix = clean_path ~= "" and (" " .. clean_path) or ""
    local message = ("Computing diffs %d/%d (%d%%)%s"):format(completed, total, percent, suffix)
    if not session.stream_progress_handle then
        session.stream_progress_handle = jpr().progress(message, { delay_ms = 0 })
    else
        session.stream_progress_handle:update(message)
    end
end

--- Updates `session`'s views and error reporting in response to engine notifications.
function M.on_notification(session, method, params, show_session)
    if method == "event" and params then
        handle_event_notification(session, params, show_session)
    elseif method == "streamProgress" then
        handle_stream_progress(session, params)
    elseif method == "protocolError" then
        jpr().error(crash.build_clean_text_from_raw(params and params.message))
    end
end

return M
