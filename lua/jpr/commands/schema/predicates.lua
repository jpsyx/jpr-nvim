-- Runtime executability predicates for `:Jpr` Command Palette entries and
-- conditional select-step options.
local M = {}

--- Returns `true` when an active, writable (non-read-only) review session exists.
--- @param context table|nil
--- @return boolean
function M.is_live_session(context)
    return type(context) == "table" and context.has_session == true and context.is_read_only ~= true
end

--- Returns `true` when a live session is linked to a GitHub pull request.
--- @param context table|nil
--- @return boolean
function M.is_live_linked_pr_session(context)
    return M.is_live_session(context) and context.is_linked_pr == true
end

--- Returns `true` when `:Jpr comment` can anchor to the cursor's line or file.
--- @param context table|nil
--- @return boolean
function M.is_comment_executable(context)
    return M.is_live_session(context)
        and (context.is_on_diff_line == true or context.can_comment_file == true)
end

--- Returns `true` when `:Jpr suggest` can run in the active changed worktree buffer.
--- @param context table|nil
--- @return boolean
function M.is_suggest_executable(context)
    return M.is_live_linked_pr_session(context) and context.is_in_changed_worktree_file == true
end

--- Returns `true` when `:Jpr conversation` can open live or cached conversation notes.
--- @param context table|nil
--- @return boolean
function M.is_conversation_executable(context)
    return type(context) == "table"
        and context.has_session == true
        and (context.is_read_only ~= true or context.has_cached_conversation == true)
end

--- Returns `true` when `:Jpr agent` can launch or toggle the coding-agent split.
--- @param context table|nil
--- @return boolean
function M.is_agent_executable(context)
    return type(context) == "table"
        and context.has_session == true
        and (context.is_read_only ~= true or context.has_live_agent == true)
end

--- Returns `true` when unsent local comments exist in a live session for `:Jpr send`.
--- @param context table|nil
--- @return boolean
function M.is_send_executable(context)
    return M.is_live_session(context) and (tonumber(context.local_unsent_count) or 0) > 0
end

--- Returns `true` when `:Jpr close` has an active session or pending checkout tab.
--- @param context table|nil
--- @return boolean
function M.is_close_executable(context)
    return type(context) == "table" and (context.has_session == true or context.has_pending_tab == true)
end

--- Option-level predicate returning `true` when cursor sits on a commentable diff line.
--- @param _answers table|nil
--- @param context table|nil
--- @return boolean
function M.is_on_diff_line_option(_answers, context)
    return type(context) == "table" and context.is_on_diff_line == true
end

--- Option-level predicate returning `true` when cursor sits on a commentable file.
--- @param _answers table|nil
--- @param context table|nil
--- @return boolean
function M.can_comment_file_option(_answers, context)
    return type(context) == "table" and context.can_comment_file == true
end

return M
