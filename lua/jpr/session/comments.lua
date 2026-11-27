-- Comment, thread navigation, suggestion, conversation, and review-submit
-- commands attached onto `jpr.session`.
local M = {}

local function jpr()
    return require("jpr")
end

local function is_stream_buffer(session, buf)
    local buffers = session.stream and session.stream.buffers
    return buffers ~= nil and (buf == buffers.main or buf == buffers.left)
end

local function get_line_range_from_opts(win, opts)
    local has_range = (opts.range ~= nil and opts.range > 0) or (opts.range == nil and opts.line1 ~= nil)
    if has_range then
        local first_input = opts.line1
        local second_input = opts.line2 or first_input
        return math.min(first_input, second_input), math.max(first_input, second_input)
    end
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
    return cursor_line, cursor_line
end

local function create_anchor_from_stream(session, win, opts)
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
    local first_line, last_line = get_line_range_from_opts(win, opts)
    local anchor = stream.anchor_at_range(session, win, first_line, last_line)
    if not anchor then
        return nil, "cannot anchor a comment on this line or range"
    end
    return anchor
end

local function create_anchor_from_diff(session, win, buf, opts)
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
    local first_line, last_line = get_line_range_from_opts(win, opts)
    local kind = "line"
    if first_line ~= last_line then
        kind = "range"
    end
    return { file = path, kind = kind, side = side, start = first_line, ["end"] = last_line }
end

local function has_explicit_range(opts)
    return type(opts.range) == "number" and opts.range > 0
end

local function comment_request(opts)
    if opts.suggest == true then
        return "suggest"
    end
    if opts.file == true then
        return "file"
    end
    return "versatile"
end

local function stream_file_path(session, win)
    local layout = session.stream and session.stream.layout
    if not layout then
        return nil
    end
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
    local file = require("jpr.render.stream").find_file_at_line(layout, cursor_line)
    return file and file.path or nil
end

local function diff_file_path(session, buf)
    local path = vim.b[buf].jpr_base_path
    if type(path) == "string" and path ~= "" then
        return path
    end
    return require("jpr.views.diff").buffer_to_changed_path(session, buf)
end

--- Sidebar location for the panel buffer, or nil when `buf` is not the panel.
local function describe_panel_location(session)
    local panel = session.panel
    if not panel or vim.api.nvim_get_current_buf() ~= panel.buf then
        return nil
    end
    local info = require("jpr.views.panel").get_row_under_cursor(session)
    local row = info and info.row or nil
    if row == nil then
        return { is_on_diff_line = false, is_pr_surface = false }
    end
    return {
        is_on_diff_line = false,
        file_path = row.kind == "file" and row.path or nil,
        is_pr_surface = row.kind == "summary" or row.kind == "conversation",
    }
end

--- Where a comment can land: a diff line, a file, a PR conversation surface, or none.
local function describe_location(session, win, buf)
    local panel_location = describe_panel_location(session)
    if panel_location then
        return panel_location
    end
    local conversation = session.conversation
    if conversation ~= nil and conversation.buf == buf then
        return { is_on_diff_line = false, is_pr_surface = true }
    end
    if is_stream_buffer(session, buf) then
        local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
        local anchor = require("jpr.views.stream").anchor_at_range(session, win, cursor_line, cursor_line)
        local is_on_diff_line = anchor ~= nil and (anchor.kind == "line" or anchor.kind == "range")
        return { is_on_diff_line = is_on_diff_line, file_path = stream_file_path(session, win) }
    end
    local path = diff_file_path(session, buf)
    return { is_on_diff_line = path ~= nil, file_path = path }
end

local function create_line_anchor(session, win, buf, opts)
    if is_stream_buffer(session, buf) then
        return create_anchor_from_stream(session, win, opts)
    end
    return create_anchor_from_diff(session, win, buf, opts)
end

local function create_static_anchor(kind, file_path)
    if kind == "pr" then
        return { kind = "pr", side = "RIGHT" }
    end
    return { file = file_path, kind = "file", side = "RIGHT" }
end

--- Line, file, or standalone PR anchor for `opts`, using the only available
--- comment when the cursor is not on a diff line.
local function create_comment_anchor(session, win, buf, opts)
    if comment_request(opts) == "suggest" or has_explicit_range(opts) then
        return create_line_anchor(session, win, buf, opts)
    end
    local location = describe_location(session, win, buf)
    local request = comment_request(opts)
    if location.is_on_diff_line == true and request == "versatile" then
        return create_line_anchor(session, win, buf, opts)
    end
    local kind, error_message = require("jpr.comments.target").classify_comment_kind(location, request)
    if kind == "file" or kind == "pr" then
        return create_static_anchor(kind, location.file_path)
    end
    if kind == "line" then
        return create_line_anchor(session, win, buf, opts)
    end
    return nil, error_message
end

local function with_current_session(session_mod, action)
    local session = session_mod.current()
    if not session then
        return jpr().error("no pull request is open in this tab")
    end
    return action(session)
end

local function expand_session_threads(session)
    session.threads_expanded = not session.threads_expanded
    require("jpr.views.threads").redraw_all(session)
    require("jpr.views.stream").refresh(session, true)
end

local function jump_session_thread(session, step)
    local buf = vim.api.nvim_get_current_buf()
    if is_stream_buffer(session, buf) then
        return require("jpr.views.stream").jump(session, "threads", step)
    end
    require("jpr.views.threads").jump(session, step)
end

local function open_session_popup(session)
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local threads = is_stream_buffer(session, buf)
            and require("jpr.views.stream").threads_at_cursor(session, line, win)
        or require("jpr.views.threads").threads_at_cursor(session, buf, line)
    require("jpr.comments.popup").open(session, threads)
end

local function open_session_comment(session, opts)
    local comment_opts = opts or {}
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local anchor, error_message = create_comment_anchor(session, win, buf, comment_opts)
    if not anchor then
        return jpr().error(error_message)
    end
    require("jpr.comments.compose").open_new(session, anchor, { suggest = comment_opts.suggest == true })
end

--- Attaches thread, comment, conversation, suggest, and submit commands onto `session_mod`.
function M.attach(session_mod)
    session_mod.expand_current = function()
        return with_current_session(session_mod, expand_session_threads)
    end
    session_mod.jump_thread_current = function(step)
        return with_current_session(session_mod, function(session)
            return jump_session_thread(session, step)
        end)
    end
    session_mod.popup_current = function()
        return with_current_session(session_mod, open_session_popup)
    end
    session_mod.comment_current = function(opts)
        return with_current_session(session_mod, function(session)
            return open_session_comment(session, opts)
        end)
    end
    session_mod.pr_comment_current = function()
        return with_current_session(session_mod, function(session)
            require("jpr.comments.compose").open_new(session, { kind = "pr", side = "RIGHT" })
        end)
    end
    session_mod.summary_current = function()
        return with_current_session(session_mod, function(session)
            require("jpr.views.conversation").show(session, { target = "summary" })
        end)
    end
    session_mod.conversation_current = function()
        return with_current_session(session_mod, function(session)
            require("jpr.views.conversation").show(session, { target = "conversation" })
        end)
    end
    session_mod.suggest_current = function()
        return with_current_session(session_mod, function(session)
            require("jpr.comments.suggest").run(session)
        end)
    end
    session_mod.submit_current = function()
        return with_current_session(session_mod, function(session)
            require("jpr.views.submit").open(session)
        end)
    end
end

return M
