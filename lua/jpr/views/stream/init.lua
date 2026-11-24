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
    if session.loading then
        require("jpr.views.loading").update(session, { stage = 4 })
    end
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
        if session.loading then
            require("jpr.views.loading").close(session)
        end
    end)
end

--- Fetches the stream again if it is on screen and its view or mode
--- changed, or always when `force` is set (a file was saved, or the mode
--- changed). If the reviewer opened a file meanwhile, the answer only fills
--- the buffers.
function M.refresh(session, force)
    local state = session.stream
    if not state or session.is_read_only or not M.is_visible(session) then
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
        vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, { line_hl_group = group, priority = 100 })
    end
    for _, highlight in ipairs(column.highlights) do
        vim.api.nvim_buf_set_extmark(buf, namespace, highlight.line, highlight.col_start, {
            end_col = highlight.col_end,
            hl_group = highlight.group,
            priority = 110,
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
    require("jpr.views.stream.syntax").apply(buf, column)
    for win, cursor in pairs(cursors) do
        pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, math.min(cursor[1], #column.lines)), 0 })
    end
end

--- Whether `win` shows nothing the reviewer chose: an empty unnamed buffer
--- (a new tab's), the loading buffer, or the stream itself.
local function is_free(session, win)
    local buf = vim.api.nvim_win_get_buf(win)
    local buffers = session.stream.buffers
    if buf == buffers.main or buf == buffers.left then
        return true
    end
    if require("jpr.views.loading").is_loading_buffer(session, buf) then
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
        if session.loading then
            require("jpr.views.loading").close(session)
        end
        return
    end
    local wins = M.place(session, buffers)
    if session.loading then
        require("jpr.views.loading").close(session)
    end
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
            main_window.release_windows(buf)
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end
    session.stream = nil
end

require("jpr.views.stream.anchors").attach(M)
require("jpr.views.stream.navigation").attach(M, find_stream_window)

return M
