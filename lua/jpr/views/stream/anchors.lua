-- Thread lookup and comment-anchor creation for stream buffers (`jpr.views.stream`).
local threads_render = require("jpr.render.threads")

local M = {}

local function is_left_stream_window(session, win)
    local stream = session.stream
    if not stream then
        return false
    end
    if stream.left_win == win then
        return true
    end
    local left_buf = stream.buffers and stream.buffers.left
    return left_buf ~= nil and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == left_buf
end

local function collect_anchor_entries(layout, first_line, last_line)
    local entries, target_file = {}, nil
    for row_line = first_line, last_line do
        local entry = layout.anchors[row_line]
        if not entry or entry.kind == "file" then
            return nil, nil
        end
        if target_file and entry.file ~= target_file then
            return nil, nil
        end
        target_file = entry.file
        entries[#entries + 1] = entry
    end
    return target_file, entries
end

local function create_anchor_from_lines(file, side, lines)
    if #lines == 0 then
        return nil
    end
    local start_line, end_line = lines[1], lines[1]
    for _, line_number in ipairs(lines) do
        start_line = math.min(start_line, line_number)
        end_line = math.max(end_line, line_number)
    end
    return {
        file = file,
        kind = start_line == end_line and "line" or "range",
        side = side,
        start = start_line,
        ["end"] = end_line,
    }
end

local function create_unified_anchor_from_entries(file, entries)
    local left_lines, right_lines = {}, {}
    local has_left_only, has_right_only = false, false
    for _, entry in ipairs(entries) do
        if entry.left_line then
            left_lines[#left_lines + 1] = entry.left_line
        end
        if entry.right_line then
            right_lines[#right_lines + 1] = entry.right_line
        end
        has_left_only = has_left_only or (entry.left_line ~= nil and entry.right_line == nil)
        has_right_only = has_right_only or (entry.right_line ~= nil and entry.left_line == nil)
    end
    if has_left_only and not has_right_only and #left_lines == #entries then
        return create_anchor_from_lines(file, "LEFT", left_lines)
    end
    if not has_left_only and #right_lines == #entries then
        return create_anchor_from_lines(file, "RIGHT", right_lines)
    end
    return nil
end

local function create_split_anchor_from_entries(file, entries, is_left_win)
    local side = is_left_win and "LEFT" or "RIGHT"
    local lines = {}
    for _, entry in ipairs(entries) do
        local line_number
        if is_left_win then
            line_number = entry.left_line
        else
            line_number = entry.right_line
        end
        if line_number then
            lines[#lines + 1] = line_number
        end
    end
    if #lines ~= #entries then
        return nil
    end
    return create_anchor_from_lines(file, side, lines)
end

--- Attaches `threads_at_cursor` and `anchor_at_range` onto `stream_mod`.
function M.attach(stream_mod)
    --- Returns the review threads placed at `line` (or the cursor's current line
    --- in `win`), filtered to the active side in split mode.
    function stream_mod.threads_at_cursor(session, line, win)
        local layout = session.stream and session.stream.layout
        if not layout then
            return {}
        end
        local target_win = win or vim.api.nvim_get_current_win()
        local cursor_line = line or vim.api.nvim_win_get_cursor(target_win)[1]
        local bucket = layout.threads_by_line[cursor_line] or {}
        local anchor = layout.anchors[cursor_line]
        if #bucket == 0 or layout.mode ~= "split" or (anchor and anchor.kind == "file") then
            return bucket
        end
        local want_left = is_left_stream_window(session, target_win)
        return vim.tbl_filter(function(thread)
            return threads_render.is_left_thread(thread) == want_left
        end, bucket)
    end

    --- Creates an engine `Anchor` for 1-based inclusive `[line1, line2]` in
    --- stream window `win`, returning `nil` when no commentable row matches.
    function stream_mod.anchor_at_range(session, win, line1, line2)
        local layout = session.stream and session.stream.layout
        if not layout then
            return nil
        end
        local target_win = win or vim.api.nvim_get_current_win()
        local first_input = line1 or vim.api.nvim_win_get_cursor(target_win)[1]
        local second_input = line2 or first_input
        local first_line = math.min(first_input, second_input)
        local last_line = math.max(first_input, second_input)
        if first_line == last_line and layout.anchors[first_line] and layout.anchors[first_line].kind == "file" then
            local file_anchor = layout.anchors[first_line]
            return { file = file_anchor.file, kind = "file", side = file_anchor.side or "RIGHT" }
        end
        local file, entries = collect_anchor_entries(layout, first_line, last_line)
        if not file or #entries == 0 then
            return nil
        end
        if layout.mode == "split" then
            return create_split_anchor_from_entries(file, entries, is_left_stream_window(session, target_win))
        end
        return create_unified_anchor_from_entries(file, entries)
    end
end

return M
