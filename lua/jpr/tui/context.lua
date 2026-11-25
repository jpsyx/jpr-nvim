-- Captures current tab session, repository, agent, and cursor-view state
-- for interactive `:Jpr` Command Palette filtering and wizard defaults.
local M = {}

local function inspect_stream_cursor(current_session, win)
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local anchor = require("jpr.views.stream").anchor_at_range(current_session, win, line, line)
    local is_on_diff_line = anchor ~= nil and (anchor.kind == "line" or anchor.kind == "range")
    local layout = current_session.stream and current_session.stream.layout
    local can_comment_file = (anchor ~= nil and anchor.kind == "file")
        or (layout ~= nil and require("jpr.render.stream").find_file_at_line(layout, line) ~= nil)
    return {
        is_on_diff_line = is_on_diff_line,
        can_comment_file = can_comment_file,
        is_in_changed_worktree_file = false,
    }
end

local function inspect_cursor_view_context(current_session)
    if not current_session then
        return {
            is_on_diff_line = false,
            can_comment_file = false,
            is_in_changed_worktree_file = false,
        }
    end
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local buffers = current_session.stream and current_session.stream.buffers
    if buffers ~= nil and (buf == buffers.main or buf == buffers.left) then
        return inspect_stream_cursor(current_session, win)
    end
    local is_base_diff_buf = type(vim.b[buf].jpr_base_path) == "string" and vim.b[buf].jpr_base_path ~= ""
    local is_changed_worktree_file = not is_base_diff_buf
        and require("jpr.views.diff").buffer_to_changed_path(current_session, buf) ~= nil
    local is_commentable_diff = is_base_diff_buf or is_changed_worktree_file
    return {
        is_on_diff_line = is_commentable_diff,
        can_comment_file = is_commentable_diff,
        is_in_changed_worktree_file = is_changed_worktree_file,
    }
end

local function is_linked_pr_session(current_session)
    if not current_session then
        return false
    end
    if current_session.mode ~= "local" then
        return true
    end
    return type(current_session.view) == "table" and type(current_session.view.pr) == "table"
end

local function has_cached_conversation_buffer(current_session)
    local conversation = current_session and current_session.conversation
    return conversation ~= nil
        and conversation.buf ~= nil
        and vim.api.nvim_buf_is_valid(conversation.buf)
end

local function read_agent_state(current_session)
    if current_session == nil then
        return false, false
    end
    local agent_module = require("jpr.agent")
    local is_agent_open = type(agent_module.is_open) == "function"
        and agent_module.is_open(current_session) == true
    local has_live_agent = type(agent_module.has_live_agent) == "function"
        and agent_module.has_live_agent(current_session) == true
    return is_agent_open, has_live_agent
end

--- Builds the runtime TUI context snapshot for `session` and `cmd_opts`, used
--- by the Command Palette and steppers to filter commands and preselect defaults.
--- @param session table
--- @param cmd_opts table|nil
--- @return table
function M.create_context_from_session(session, cmd_opts)
    local current_session = type(session.current) == "function" and session.current() or nil
    local current_tab = vim.api.nvim_get_current_tabpage()
    local has_pending_tab = current_session == nil
        and type(session.has_pending_tab) == "function"
        and session.has_pending_tab(current_tab) == true
    local is_agent_open, has_live_agent = read_agent_state(current_session)
    local cursor_view = inspect_cursor_view_context(current_session)
    local local_unsent_count = current_session ~= nil
            and type(current_session.view) == "table"
            and tonumber(current_session.view.localUnsentCount)
        or 0
    return {
        cmd_opts = cmd_opts,
        has_session = current_session ~= nil,
        has_pending_tab = has_pending_tab,
        is_read_only = current_session ~= nil and current_session.is_read_only == true,
        is_linked_pr = is_linked_pr_session(current_session),
        has_cached_conversation = has_cached_conversation_buffer(current_session),
        local_unsent_count = local_unsent_count,
        is_agent_open = is_agent_open,
        has_live_agent = has_live_agent,
        is_on_diff_line = cursor_view.is_on_diff_line,
        can_comment_file = cursor_view.can_comment_file,
        is_in_changed_worktree_file = cursor_view.is_in_changed_worktree_file,
    }
end

return M
