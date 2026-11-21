-- The stream: every changed file in one scrolling buffer (unified), or in two
-- scroll-bound buffers padded to align (split), in the window beside the
-- panel. The engine builds the rows; render.stream lays them out.
local main_window = require("jpr.views.main_window")
local render = require("jpr.render.stream")
local view_mode = require("jpr.view_mode")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-stream")

local function session_module()
    return require("jpr.session")
end

--- `session`'s stream state: its buffers, the left window, the last build.
function M.state(session)
    session.stream = session.stream or { buffers = {} }
    return session.stream
end

--- Lets go of the left window once it shows something other than the left
--- buffer (the reviewer opened their own buffer there): it is theirs now, so
--- it stops being a side window and is never reused or closed.
local function release_left_window(session)
    local state = session.stream
    local win = state and state.left_win
    if not win then
        return
    end
    if not vim.api.nvim_win_is_valid(win) then
        state.left_win = nil
    elseif vim.api.nvim_win_get_buf(win) ~= state.buffers.left then
        vim.w[win].jpr_side = nil
        state.left_win = nil
    end
end

--- The stream's `main` or `left` buffer, made on first use.
local function get_or_create_stream_buffer(session, key)
    local state = M.state(session)
    local existing = state.buffers[key]
    if existing and vim.api.nvim_buf_is_valid(existing) then
        return existing
    end
    local buf = vim.api.nvim_create_buf(false, true)
    local suffix = key == "left" and "/base" or ""
    pcall(vim.api.nvim_buf_set_name, buf, ("jpr://stream/%d%s"):format(session.number, suffix))
    vim.bo[buf].filetype = "jpr-stream"
    vim.bo[buf].modifiable = false
    M.map_keys(session, buf)
    if key == "left" then
        -- The left half lives only while its window does, so going back to
        -- unified (or opening a file) leaves no hidden buffer behind.
        vim.bo[buf].bufhidden = "wipe"
    end
    vim.api.nvim_create_autocmd("BufWinLeave", {
        buffer = buf,
        callback = function()
            vim.schedule(function()
                -- Leaving the stream for a file takes its left half with it;
                -- a buffer opened in the left half makes that window theirs.
                if key == "left" then
                    release_left_window(session)
                else
                    M.close_left_window(session)
                end
            end)
        end,
    })
    state.buffers[key] = buf
    return buf
end

--- The window in `session`'s tab that shows the stream, or else the main
--- window. Asked in that order because a left half the reviewer took over
--- is no longer a side window, so `main_window.find` may return it first.
local function find_stream_window(session)
    local buf = session.stream and session.stream.buffers.main
    if buf and vim.api.nvim_buf_is_valid(buf) then
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            if vim.api.nvim_win_get_tabpage(win) == session.tab then
                return win
            end
        end
    end
    return main_window.find(session)
end

--- Whether the stream is on screen.
function M.is_visible(session)
    local buf = session.stream and session.stream.buffers.main
    return buf ~= nil and vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0
end

--- What the stream drawn in `mode` from `session`'s current view is keyed
--- by: a drawn stream whose key differs from the current one is out of date.
local function build_stream_key(session, mode)
    return mode .. "\n" .. render.build_key_from_view(session.view or {})
end

--- The `after_draw` bound to stream request `request_id`, now taken off the
--- state: it runs with that request's answer or not at all.
local function take_after_draw(session, request_id)
    local pending = session.stream and session.stream.after_draw
    if pending and pending.request_id == request_id then
        session.stream.after_draw = nil
        return pending.run
    end
    return nil
end

--- Fetches the stream in the current view mode and draws it. opts:
--- `only_if_free` leaves the main window alone when it shows something the
--- reviewer chose; `focus` moves the cursor into the stream. Only the answer
--- to the latest request is drawn, and it is drawn as the view and mode the
--- request was sent for, so a view that changes meanwhile still looks new to
--- the next refresh. A mode that changes meanwhile is fetched again at once:
--- the toggle found the stream hidden and asked for nothing.
function M.show(session, opts)
    if session.closing then
        return
    end
    local state = M.state(session)
    state.request_id = (state.request_id or 0) + 1
    local request_id = state.request_id
    local mode = view_mode.get()
    local key = build_stream_key(session, mode)
    session_module().request(session, "stream", { mode = mode }, function(stream)
        local after_draw = take_after_draw(session, request_id)
        if session.stream and session.stream.request_id == request_id then
            M.draw(session, stream, vim.tbl_extend("force", opts or {}, { key = key, after_draw = after_draw }))
            if view_mode.get() ~= mode then
                M.refresh(session)
            end
        end
    end, function()
        take_after_draw(session, request_id)
    end)
end

--- Fetches the stream again if it is on screen and its view or mode
--- changed, or always when `force` is set (a file was saved, or the mode
--- changed). If the reviewer opened a file meanwhile, the answer only fills
--- the buffers.
function M.refresh(session, force)
    local state = session.stream
    if not state or not M.is_visible(session) then
        return
    end
    release_left_window(session)
    if force or build_stream_key(session, view_mode.get()) ~= state.key then
        M.show(session, { only_if_free = true })
    end
end

--- Replaces `buf`'s lines and highlights with `column`'s, keeping each
--- window's cursor line.
function M.fill(buf, column)
    local cursors = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        cursors[win] = vim.api.nvim_win_get_cursor(win)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, column.lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    for line, group in pairs(column.line_groups) do
        vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, { line_hl_group = group })
    end
    for _, highlight in ipairs(column.highlights) do
        vim.api.nvim_buf_set_extmark(buf, namespace, highlight.line, highlight.col_start, {
            end_col = highlight.col_end,
            hl_group = highlight.group,
            strict = false,
        })
    end
    for _, mark in ipairs(column.eol_marks or {}) do
        vim.api.nvim_buf_set_extmark(buf, namespace, mark.line, 0, {
            virt_text = mark.chunks,
            virt_text_pos = "eol",
            strict = false,
        })
    end
    for win, cursor in pairs(cursors) do
        pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, math.min(cursor[1], #column.lines)), 0 })
    end
end

--- Whether `win` shows nothing the reviewer chose: an empty unnamed buffer
--- (a new tab's) or the stream itself.
local function is_free(session, win)
    local buf = vim.api.nvim_win_get_buf(win)
    local buffers = session.stream.buffers
    if buf == buffers.main or buf == buffers.left then
        return true
    end
    return vim.api.nvim_buf_get_name(buf) == "" and not vim.bo[buf].modified
end

--- Draws `stream` into its buffers and, unless `opts.only_if_free` finds the
--- main window taken, into the windows beside the panel. `opts.key` is the
--- view and mode it was fetched for (the current view in the stream's own
--- mode when left out), and
--- `opts.after_draw(layout)` runs once it is on screen. An answer that
--- arrives after the review closed, or its tab went away, is dropped.
function M.draw(session, stream, opts)
    if session.closing or not vim.api.nvim_tabpage_is_valid(session.tab) then
        return
    end
    local state = M.state(session)
    local layout = render.create_layout_from_stream(stream, { expanded = session.threads_expanded == true })
    state.layout, state.key = layout, opts.key or build_stream_key(session, stream.mode or view_mode.get())
    local main_buf = get_or_create_stream_buffer(session, "main")
    local buffers = #layout.columns == 2 and { get_or_create_stream_buffer(session, "left"), main_buf } or { main_buf }
    for index, column in ipairs(layout.columns) do
        M.fill(buffers[index], column)
    end
    release_left_window(session)
    if opts.only_if_free and not is_free(session, find_stream_window(session)) then
        return
    end
    local wins = M.place(session, buffers)
    for _, win in ipairs(wins) do
        M.set_folds(win, layout.folds)
    end
    if opts.focus then
        vim.api.nvim_set_current_win(wins[#wins])
    end
    if opts.after_draw then
        opts.after_draw(layout)
    end
end

--- The stream's look in `win`, local to the stream's buffer: no wrapping,
--- numbers or sign column, manual folds, and, when `is_bound`, scrolling
--- and the cursor bound to the other half.
local function style_window(win, is_bound)
    local function set(name, value)
        vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
    end
    set("wrap", false)
    set("number", false)
    set("relativenumber", false)
    set("signcolumn", "no")
    set("cursorline", true)
    set("foldmethod", "manual")
    set("foldenable", true)
    set("scrollbind", is_bound)
    set("cursorbind", is_bound)
end

--- Shows `buffers` (the main one last) beside the panel: the main buffer in
--- the main window and, when split, the left buffer in a bound window on its
--- left. Returns the windows, left to right.
function M.place(session, buffers)
    local state = M.state(session)
    local main_win = find_stream_window(session)
    -- Cleared first: a base window's diffoff would undo the stream's options.
    require("jpr.views.diff").clear(session, main_win)
    vim.api.nvim_win_set_buf(main_win, buffers[#buffers])
    if #buffers == 1 then
        M.close_left_window(session)
        style_window(main_win, false)
        return { main_win }
    end
    if not (state.left_win and vim.api.nvim_win_is_valid(state.left_win)) then
        state.left_win = vim.api.nvim_open_win(buffers[1], false, { split = "left", win = main_win })
        vim.w[state.left_win].jpr_side = true
    end
    vim.api.nvim_win_set_buf(state.left_win, buffers[1])
    style_window(state.left_win, true)
    style_window(main_win, true)
    vim.api.nvim_win_call(main_win, function()
        vim.cmd("syncbind")
    end)
    return { state.left_win, main_win }
end

--- Folds the bodies of viewed files in `win`.
function M.set_folds(win, folds)
    vim.api.nvim_win_call(win, function()
        vim.cmd("silent! normal! zE")
        for _, fold in ipairs(folds) do
            vim.cmd(("%d,%dfold"):format(fold.first, fold.last))
        end
    end)
end

--- Closes the split stream's left window, which wipes its buffer, unless
--- the reviewer opened their own buffer there.
function M.close_left_window(session)
    release_left_window(session)
    local state = session.stream
    if state and state.left_win and vim.api.nvim_win_is_valid(state.left_win) then
        pcall(vim.api.nvim_win_close, state.left_win, true)
    end
    if state then
        state.left_win = nil
    end
end

--- Shows an empty buffer in every window that shows `buf`, so wiping `buf`
--- does not close the main window (and, once the panel goes too, the tab).
local function release_windows(buf)
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        local empty = vim.api.nvim_create_buf(false, true)
        vim.bo[empty].bufhidden = "wipe"
        pcall(vim.api.nvim_win_set_buf, win, empty)
    end
end

--- Closes the stream's left window and wipes its buffers, for a review that
--- ends. The main window stays, empty, for a review whose engine stopped.
function M.close(session)
    local state = session.stream
    if not state then
        return
    end
    M.close_left_window(session)
    for _, buf in pairs(state.buffers) do
        if vim.api.nvim_buf_is_valid(buf) then
            release_windows(buf)
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end
    session.stream = nil
end

--- Moves the cursor to the next (`step` 1) or previous (-1) file header
--- (`kind` "files"), hunk ("hunks"), or thread ("threads"). A hunk or thread
--- inside a closed fold (a viewed file) is skipped, since the cursor would
--- stay on the same folded line.
function M.jump(session, kind, step)
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
        return vim.fn.foldclosed(line) == -1
    end, lines)
    local target = render.find_adjacent_line(lines, vim.api.nvim_win_get_cursor(0)[1], step)
    if target then
        vim.api.nvim_win_set_cursor(0, { target, 0 })
    end
end

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

--- Returns the review threads placed at `line` (or the cursor's current line
--- in `win`), filtered to the active side in split mode.
function M.threads_at_cursor(session, line, win)
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
        local is_left_thread = thread.anchor ~= nil and thread.anchor.kind ~= "file" and thread.anchor.side == "LEFT"
        return is_left_thread == want_left
    end, bucket)
end

local function collect_anchor_entries(layout, first, last)
    local entries, target_file = {}, nil
    for row_line = first, last do
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

local function build_range_anchor(file, side, lines)
    if #lines == 0 then
        return nil
    end
    local start_line, end_line = lines[1], lines[1]
    for _, line_num in ipairs(lines) do
        start_line = math.min(start_line, line_num)
        end_line = math.max(end_line, line_num)
    end
    return {
        file = file,
        kind = start_line == end_line and "line" or "range",
        side = side,
        start = start_line,
        ["end"] = end_line,
    }
end

local function resolve_unified_anchor(file, entries)
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
        return build_range_anchor(file, "LEFT", left_lines)
    end
    if not has_left_only and #right_lines == #entries then
        return build_range_anchor(file, "RIGHT", right_lines)
    end
    return nil
end

local function resolve_split_anchor(file, entries, is_left_win)
    local side = is_left_win and "LEFT" or "RIGHT"
    local lines = {}
    for _, entry in ipairs(entries) do
        local line_num
        if is_left_win then
            line_num = entry.left_line
        else
            line_num = entry.right_line
        end
        if line_num then
            lines[#lines + 1] = line_num
        end
    end
    if #lines ~= #entries then
        return nil
    end
    return build_range_anchor(file, side, lines)
end

--- Resolves an engine `Anchor` for 1-based inclusive `[line1, line2]` in
--- stream window `win`, returning `nil` when no commentable row matches.
function M.anchor_at_range(session, win, line1, line2)
    local layout = session.stream and session.stream.layout
    if not layout then
        return nil
    end
    local target_win = win or vim.api.nvim_get_current_win()
    local first_input = line1 or vim.api.nvim_win_get_cursor(target_win)[1]
    local second_input = line2 or first_input
    local first, last = math.min(first_input, second_input), math.max(first_input, second_input)
    if first == last and layout.anchors[first] and layout.anchors[first].kind == "file" then
        local file_anchor = layout.anchors[first]
        return { file = file_anchor.file, kind = "file", side = file_anchor.side or "RIGHT" }
    end
    local file, entries = collect_anchor_entries(layout, first, last)
    if not file or #entries == 0 then
        return nil
    end
    if layout.mode == "split" then
        return resolve_split_anchor(file, entries, is_left_stream_window(session, target_win))
    end
    return resolve_unified_anchor(file, entries)
end

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

--- Opens the real file at the cursor line's place, in the main window,
--- through `main_window.edit`, which refuses a path that leaves the worktree.
function M.open_target(session)
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
        M.close_left_window(session)
    end
end

--- Marks the file under the cursor viewed, or unviewed again; once the
--- stream redraws, moves to the next file that is not viewed.
function M.toggle_viewed(session)
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
    local request_id_when_sent = session.stream.request_id
    session.stream.after_draw = nil
    session_module().request(session, "setViewed", { path = file.path, viewed = file.viewed ~= "VIEWED" }, function()
        -- The engine's viewedChanged event comes before this answer, and asks
        -- for the redraw if the stream changed; when none was asked for,
        -- nothing follows and the cursor stays.
        local state = session.stream
        if state and state.request_id ~= request_id_when_sent then
            state.after_draw = { request_id = state.request_id, run = move_to_next_unviewed }
        end
    end, function()
        if session.stream then
            session.stream.after_draw = nil
        end
    end)
end

--- The stream's keys on `buf`.
function M.map_keys(session, buf)
    local function map(lhs, action, desc)
        vim.keymap.set("n", lhs, function()
            action(session)
        end, { buffer = buf, desc = desc, nowait = true })
    end
    map("<CR>", M.open_target, "Open the file at this line")
    map("v", M.toggle_viewed, "Toggle viewed and go to the next unviewed file")
    map("]f", function(current_session) M.jump(current_session, "files", 1) end, "Next file")
    map("[f", function(current_session) M.jump(current_session, "files", -1) end, "Previous file")
    map("]h", function(current_session) M.jump(current_session, "hunks", 1) end, "Next hunk")
    map("[h", function(current_session) M.jump(current_session, "hunks", -1) end, "Previous hunk")
    require("jpr").bind_buffer_keys(buf)
end

return M
