-- Cursor jumps, target file opening, viewed-state toggling, and buffer keymaps
-- for stream buffers (`jpr.views.stream`).
local main_window = require("jpr.views.main_window")
local render = require("jpr.render.stream")

local M = {}

--- What `line` of the current window opens: its own target or, inside a
--- closed fold, its file header's, since the hidden line under the cursor is
--- not what the reviewer sees.
local function find_target_at_line(layout, line)
    if vim.fn.foldclosed(line) ~= -1 then
        local file = render.find_file_at_line(layout, line)
        return file and layout.targets[file.line]
    end
    return layout.targets[line]
end

--- Moves the cursor to the next (`step` 1) or previous (-1) file header
--- (`kind` "files"), hunk ("hunks"), or thread ("threads"). A hunk or thread
--- inside a closed fold (a viewed file) is skipped, since the cursor would
--- stay on the same folded line.
local function jump(session, kind, step)
    local layout = session.stream and session.stream.layout
    if not layout then
        return
    end
    local lines = layout.hunks
    if kind == "files" then
        lines = vim.tbl_map(function(file)
            return file.line
        end, layout.files)
    elseif kind == "threads" then
        lines = layout.thread_lines or {}
    end
    lines = vim.tbl_filter(function(line)
        local closed_start = vim.fn.foldclosed(line)
        if kind == "files" then
            return closed_start == -1 or closed_start == line
        end
        return closed_start == -1
    end, lines)
    local target = render.find_adjacent_line(lines, vim.api.nvim_win_get_cursor(0)[1], step)
    if target then
        vim.api.nvim_win_set_cursor(0, { target, 0 })
    end
end

--- Opens the real file at the cursor line's place, in the main window,
--- through `main_window.edit`, which refuses a path that leaves the worktree.
local function open_target(stream_mod, find_stream_window, session)
    local layout = session.stream and session.stream.layout
    local target = layout and find_target_at_line(layout, vim.api.nvim_win_get_cursor(0)[1])
    if not target then
        return
    end
    local win = find_stream_window(session)
    main_window.edit(session, win, target.path, target.line)
    -- A refused path leaves the stream on screen, with its left half.
    local state = session.stream
    if state and vim.api.nvim_win_get_buf(win) ~= state.buffers.main then
        stream_mod.close_left_window(session)
    end
end

--- Marks the file under the cursor viewed, or unviewed again; once the
--- stream redraws, moves to the next file that is not viewed.
local function toggle_viewed(session)
    local layout = session.stream and session.stream.layout
    local file = layout and render.find_file_at_line(layout, vim.api.nvim_win_get_cursor(0)[1])
    if not file then
        return
    end
    local win = vim.api.nvim_get_current_win()
    local function move_to_next_unviewed(new_layout)
        local next_file = render.find_next_unviewed_file(new_layout, file.line)
        if next_file and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_set_cursor, win, { next_file.line, 0 })
        end
    end
    local target_viewed = file.viewed ~= "VIEWED"
    local request_id_when_sent = session.stream.request_id
    session.stream.after_draw = nil
    require("jpr.session").request(
        session,
        "setViewed",
        { path = file.path, viewed = target_viewed },
        function()
            -- The engine's viewedChanged event comes before this answer, and asks
            -- for the redraw if the stream changed; when none was asked for, or
            -- when unmarking a file, the cursor stays in place.
            local state = session.stream
            if target_viewed and state and state.request_id ~= request_id_when_sent then
                state.after_draw = { request_id = state.request_id, run = move_to_next_unviewed }
            end
        end,
        function()
            if session.stream then
                session.stream.after_draw = nil
            end
        end
    )
end

--- The stream's keys on `buf`.
local function map_keys(stream_mod, session, buf)
    local function map(lhs, action, desc)
        vim.keymap.set("n", lhs, function()
            action(session)
        end, { buffer = buf, desc = desc, nowait = true })
    end
    map("<CR>", stream_mod.open_target, "Open the file at this line")
    map("v", stream_mod.toggle_viewed, "Toggle viewed and go to the next unviewed file")
    map("]f", function(current_session) stream_mod.jump(current_session, "files", 1) end, "Next file")
    map("[f", function(current_session) stream_mod.jump(current_session, "files", -1) end, "Previous file")
    map("]h", function(current_session) stream_mod.jump(current_session, "hunks", 1) end, "Next hunk")
    map("[h", function(current_session) stream_mod.jump(current_session, "hunks", -1) end, "Previous hunk")
    map("zo", function(current_session) stream_mod.toggle_fold(current_session, "zo") end, "Open folded file diff")
    map("zc", function(current_session) stream_mod.toggle_fold(current_session, "zc") end, "Close file diff fold")
    map("za", function(current_session) stream_mod.toggle_fold(current_session, "za") end, "Toggle file diff fold")
    vim.keymap.set("n", "?", function()
        require("jpr.views.cheatsheet").open()
    end, { buffer = buf, nowait = true, silent = true, desc = "Show Jpr keyboard shortcuts" })
    require("jpr").bind_buffer_keys(buf)
end

--- Attaches `jump`, `open_target`, `toggle_viewed`, and `map_keys` onto `stream_mod`.
function M.attach(stream_mod, find_stream_window)
    stream_mod.jump = jump
    stream_mod.open_target = function(session)
        return open_target(stream_mod, find_stream_window, session)
    end
    stream_mod.toggle_viewed = toggle_viewed
    stream_mod.map_keys = function(session, buf)
        return map_keys(stream_mod, session, buf)
    end
end

return M
