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

--- Attaches thread, comment, conversation, suggest, and submit commands onto `session_mod`.
function M.attach(session_mod)
    --- `:Jpr expand`: toggles inline thread expansion across diff and stream buffers.
    function session_mod.expand_current()
        local session = session_mod.current()
        if not session then
            return jpr().error("no pull request is open in this tab")
        end
        session.threads_expanded = not session.threads_expanded
        require("jpr.views.threads").redraw_all(session)
        require("jpr.views.stream").refresh(session, true)
    end

    --- Jumps to the next (`step == 1`) or previous (`step == -1`) review thread in
    --- the active diff or stream buffer.
    function session_mod.jump_thread_current(step)
        local session = session_mod.current()
        if not session then
            return jpr().error("no pull request is open in this tab")
        end
        local buf = vim.api.nvim_get_current_buf()
        if is_stream_buffer(session, buf) then
            return require("jpr.views.stream").jump(session, "threads", step)
        end
        require("jpr.views.threads").jump(session, step)
    end

    --- Opens the floating thread popup for the review thread(s) at the cursor
    --- in the active diff or stream buffer.
    function session_mod.popup_current()
        local session = session_mod.current()
        if not session then
            return jpr().error("no pull request is open in this tab")
        end
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(win)
        local line = vim.api.nvim_win_get_cursor(win)[1]
        local threads
        if is_stream_buffer(session, buf) then
            threads = require("jpr.views.stream").threads_at_cursor(session, line, win)
        else
            threads = require("jpr.views.threads").threads_at_cursor(session, buf, line)
        end
        require("jpr.comments.popup").open(session, threads)
    end

    --- Opens the comment compose buffer anchored to the current diff line,
    --- visual range, base buffer line, stream row, or file (`opts.file`).
    function session_mod.comment_current(opts)
        local session = session_mod.current()
        if not session then
            return jpr().error("no pull request is open in this tab")
        end
        local comment_opts = opts or {}
        local win = vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_win_get_buf(win)
        local anchor, error_message
        if is_stream_buffer(session, buf) then
            anchor, error_message = create_anchor_from_stream(session, win, comment_opts)
        else
            anchor, error_message = create_anchor_from_diff(session, win, buf, comment_opts)
        end
        if not anchor then
            return jpr().error(error_message)
        end
        require("jpr.comments.compose").open_new(session, anchor, { suggest = comment_opts.suggest == true })
    end

    --- `:Jpr conversation`: opens the pull request's top-level conversation
    --- buffer in the main window beside the panel.
    function session_mod.conversation_current()
        local session = session_mod.current()
        if not session then
            return jpr().error("no pull request is open in this tab")
        end
        require("jpr.views.conversation").show(session)
    end

    --- `:Jpr suggest`: turns the local edit at the cursor line into a GitHub
    --- draft suggestion comment and reverts just that hunk.
    function session_mod.suggest_current()
        local session = session_mod.current()
        if not session then
            return jpr().error("no pull request is open in this tab")
        end
        require("jpr.comments.suggest").run(session)
    end

    --- `:Jpr submit`: opens the review submission modal for the current PR.
    function session_mod.submit_current()
        local session = session_mod.current()
        if not session then
            return jpr().error("no pull request is open in this tab")
        end
        require("jpr.views.submit").open(session)
    end
end

return M
