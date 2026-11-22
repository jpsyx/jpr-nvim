-- Places thread signs, EOL previews, and expanded blocks on diff buffers, and
-- answers thread queries for `gt`, `]t`, `[t`, and `:Jpr expand`.
local render = require("jpr.render.threads")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-threads")
local anchor_namespace = vim.api.nvim_create_namespace("jpr-local-anchors")

local function is_trackable_local_thread(thread)
    local anchor = type(thread) == "table" and thread.anchor or nil
    if not render.is_local_thread(thread) or type(anchor) ~= "table" then
        return false
    end
    return anchor.side == "RIGHT" and (anchor.kind == "line" or anchor.kind == "range")
end

local function get_anchor_bounds_from_thread(thread)
    local anchor = thread.anchor
    local start_line = type(anchor.start) == "number" and anchor.start
        or (type(anchor.line) == "number" and anchor.line)
        or (type(thread.displayLine) == "number" and thread.displayLine)
    if not start_line or start_line < 1 then
        return nil
    end
    local end_line = type(anchor["end"]) == "number" and anchor["end"] or start_line
    return start_line, math.max(start_line, end_line)
end

local function track_local_anchor_marks(session, buf, threads, line_count)
    session.local_anchor_marks = session.local_anchor_marks or {}
    session.local_anchor_marks[buf] = {}
    vim.api.nvim_buf_clear_namespace(buf, anchor_namespace, 0, -1)
    if line_count < 1 then
        return
    end
    local tracked = {}
    for _, thread in ipairs(threads or {}) do
        local thread_id = type(thread) == "table" and (type(thread.threadId) == "string" and thread.threadId or thread.id) or nil
        if type(thread_id) == "string" and thread_id ~= "" and is_trackable_local_thread(thread) then
            local start_line, end_line = get_anchor_bounds_from_thread(thread)
            if start_line and start_line <= line_count then
                local start_row = math.max(0, start_line - 1)
                local end_row = math.max(start_row, math.min(end_line - 1, line_count - 1))
                local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, buf, anchor_namespace, start_row, 0, {
                    end_row = end_row,
                    end_col = 0,
                    right_gravity = true,
                    end_right_gravity = true,
                    strict = false,
                })
                if ok and mark_id then
                    tracked[#tracked + 1] = {
                        thread_id = thread_id,
                        mark_id = mark_id,
                        start = start_row + 1,
                        finish = end_row + 1,
                    }
                end
            end
        end
    end
    session.local_anchor_marks[buf] = tracked
end

--- Stores `threads` on `buf` and draws their extmarks.
function M.draw_on_buffer(session, buf, threads)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local thread_list = threads or {}
    local line_count = vim.api.nvim_buf_line_count(buf)
    session.buf_threads = session.buf_threads or {}
    session.buf_threads[buf] = thread_list
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    local marks = render.create_extmarks_from_threads(thread_list, line_count, {
        expanded = session.threads_expanded == true,
    })
    for _, mark in ipairs(marks) do
        local opts = vim.tbl_extend("force", mark.opts, { strict = false })
        pcall(vim.api.nvim_buf_set_extmark, buf, namespace, mark.line, mark.col, opts)
    end
    track_local_anchor_marks(session, buf, thread_list, line_count)
end

--- Draws `diff.threads` for split mode: `LEFT` threads on `base_buf` at their
--- base line, and `RIGHT` + `file` threads on `buf`.
function M.draw_split(session, base_buf, buf, diff)
    local raw_left_threads, right_threads = render.partition_threads_by_side(diff.threads)
    local left_threads = vim.tbl_map(function(thread)
        local copy = vim.deepcopy(thread)
        local anchor = type(thread.anchor) == "table" and thread.anchor or {}
        copy.displayLine = (type(anchor["end"]) == "number" and anchor["end"])
            or (type(anchor.start) == "number" and anchor.start)
            or 1
        return copy
    end, raw_left_threads)
    M.draw_on_buffer(session, base_buf, left_threads)
    M.draw_on_buffer(session, buf, right_threads)
end

--- Redraws every cached buffer's threads in `session` without touching windows.
function M.redraw_all(session)
    for buf, thread_list in pairs(session.buf_threads or {}) do
        if vim.api.nvim_buf_is_valid(buf) then
            M.draw_on_buffer(session, buf, thread_list)
        end
    end
end

--- Clears thread extmarks and cached thread metadata from `buf`.
function M.clear_buffer(session, buf)
    if session.buf_threads then
        session.buf_threads[buf] = nil
    end
    if session.local_anchor_marks then
        session.local_anchor_marks[buf] = nil
    end
    if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
        vim.api.nvim_buf_clear_namespace(buf, anchor_namespace, 0, -1)
    end
end

--- Returns `{ threadId, start, end }` anchor updates for any `RIGHT`-side local
--- thread in `buf` whose extmark moved since it was drawn.
function M.collect_shifted_local_anchors(session, buf)
    local tracked = session and session.local_anchor_marks and session.local_anchor_marks[buf]
    if not tracked or not vim.api.nvim_buf_is_valid(buf) then
        return {}
    end
    local line_count = vim.api.nvim_buf_line_count(buf)
    if line_count < 1 then
        return {}
    end
    local updates = {}
    for _, item in ipairs(tracked) do
        local mark = vim.api.nvim_buf_get_extmark_by_id(buf, anchor_namespace, item.mark_id, { details = true })
        if type(mark) == "table" and type(mark[1]) == "number" then
            local new_start = math.max(1, mark[1] + 1)
            if new_start <= line_count then
                local details = type(mark[3]) == "table" and mark[3] or {}
                local end_row = type(details.end_row) == "number" and details.end_row or mark[1]
                local new_finish = math.max(new_start, math.min(end_row + 1, line_count))
                if new_start ~= item.start or new_finish ~= item.finish then
                    updates[#updates + 1] = {
                        threadId = item.thread_id,
                        start = new_start,
                        ["end"] = new_finish,
                    }
                end
            end
        end
    end
    return updates
end

--- Returns the threads placed at 1-based `line` in `buf` (including file-level
--- threads when `line == 1`).
function M.threads_at_cursor(session, buf, line)
    local list = (session.buf_threads and session.buf_threads[buf]) or {}
    return vim.tbl_filter(function(thread)
        return thread.displayLine == line or (line == 1 and thread.displayLine == 0)
    end, list)
end

--- Sorted unique 1-based lines holding threads in `buf`.
function M.thread_lines(session, buf)
    local list = (session.buf_threads and session.buf_threads[buf]) or {}
    local seen, lines = {}, {}
    for _, thread in ipairs(list) do
        local line = math.max(1, thread.displayLine or 1)
        if not seen[line] then
            seen[line] = true
            lines[#lines + 1] = line
        end
    end
    table.sort(lines)
    return lines
end

--- Jumps to the next (`step == 1`) or previous (`step == -1`) thread in the current window.
function M.jump(session, step)
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local lines = M.thread_lines(session, buf)
    local cursor = vim.api.nvim_win_get_cursor(win)[1]
    local target = require("jpr.render.stream").find_adjacent_line(lines, cursor, step)
    if target then
        vim.api.nvim_win_set_cursor(win, { target, 0 })
    end
end

return M
