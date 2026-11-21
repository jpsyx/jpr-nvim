-- Places thread signs, EOL previews, and expanded blocks on diff buffers, and
-- answers thread queries for `gt`, `]t`, `[t`, and `:Jpr expand`.
local render = require("jpr.render.threads")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-threads")

--- Stores `threads` on `buf` and draws their extmarks.
function M.draw_on_buffer(session, buf, threads)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    session.buf_threads = session.buf_threads or {}
    session.buf_threads[buf] = threads or {}
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    local marks = render.create_extmarks_from_threads(threads or {}, vim.api.nvim_buf_line_count(buf), {
        expanded = session.threads_expanded == true,
    })
    for _, mark in ipairs(marks) do
        local opts = vim.tbl_extend("force", mark.opts, { strict = false })
        pcall(vim.api.nvim_buf_set_extmark, buf, namespace, mark.line, mark.col, opts)
    end
end

--- Draws `diff.threads` for split mode: `LEFT` threads on `base_buf` at their
--- base line, and `RIGHT` + `file` threads on `buf`.
function M.draw_split(session, base_buf, buf, diff)
    local raw_left_threads, right_threads = render.partition_threads_by_side(diff.threads)
    local left_threads = vim.tbl_map(function(thread)
        local copy = vim.deepcopy(thread)
        copy.displayLine = thread.anchor["end"] or thread.anchor.start or 1
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
    if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    end
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
