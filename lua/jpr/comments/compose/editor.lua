-- Floating markdown compose editor window, keybindings, wipeout guards,
-- suggestion fence insertion, and docked reply-history lifecycle.
local mentions = require("jpr.comments.mentions")
local render_threads = require("jpr.render.threads")
local reply_history = require("jpr.comments.reply_history")

local M = {}

--- Advances and returns `session`'s compose request token to cancel stale async prefills.
function M.next_request_id(session)
    if not session then
        return 0
    end
    session.compose_request_id = (session.compose_request_id or 0) + 1
    return session.compose_request_id
end

local function close_window_and_buffer(win, buf)
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
end

--- Closes the active floating compose buffer (and any docked history pane) for `session`.
function M.close(session)
    if not session then
        return
    end
    M.next_request_id(session)
    local compose = session.compose
    if not compose then
        return
    end
    session.compose = nil
    close_window_and_buffer(compose.win, compose.buf)
    close_window_and_buffer(compose.history_win, compose.history_buf)
end

local function buffer_body(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function insert_suggestion_fence(session, buf, anchor)
    if not anchor or (anchor.kind ~= "line" and anchor.kind ~= "range") then
        return require("jpr").info("suggestion blocks apply to line or range comments")
    end
    local compose = session and session.compose
    require("jpr.session").request(session, "anchoredLines", { anchor = anchor }, function(result)
        if session.closing or session.compose ~= compose or not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        local win = compose and compose.win
        if not win or not vim.api.nvim_win_is_valid(win) then
            return
        end
        local fence = { "```suggestion" }
        for line in ((result and result.text or "") .. "\n"):gmatch("(.-)\n") do
            fence[#fence + 1] = line
        end
        fence[#fence + 1] = "```"
        local row = vim.api.nvim_win_get_cursor(win)[1]
        vim.api.nvim_buf_set_lines(buf, row, row, false, fence)
    end)
end

local function alternate_origin(origin)
    return origin == "local" and "github" or "local"
end

--- Formats an anchor into a short location label for compose window titles.
function M.build_location_from_anchor(anchor)
    if not anchor or anchor.kind == "pr" then
        return "PR Conversation"
    end
    local file = type(anchor.file) == "string" and anchor.file or ""
    if anchor.kind == "file" then
        return file
    end
    local start_line = type(anchor.start) == "number" and anchor.start or nil
    local end_line = type(anchor["end"]) == "number" and anchor["end"] or nil
    if anchor.kind == "range" and start_line and end_line and start_line ~= end_line then
        return ("%s:%d-%d"):format(file, start_line, end_line)
    end
    return ("%s:%d"):format(file, end_line or start_line or 1)
end

--- Builds the compose float title for `anchor` and destination `origin`.
function M.build_title_from_anchor(anchor, origin)
    local location = M.build_location_from_anchor(anchor)
    if origin == "local" then
        return "[Local → agent] " .. location
    end
    local badge = (anchor and anchor.kind == "pr") and "[GitHub comment]" or "[GitHub draft]"
    return badge .. " " .. location
end

local function build_footer(allow_destination_toggle, is_local_only, is_unlinked_local, has_history)
    if is_unlinked_local then
        return " <C-s> save · local review (no linked PR) · q cancel "
    end
    if is_local_only then
        return " <C-s> save · local only (unpushed file) · q cancel "
    end
    if allow_destination_toggle then
        return " <C-s> save · <C-g> flip dest · <M-s> other dest · <C-g>s suggest · q cancel "
    end
    if has_history then
        return " <C-s> save · <Tab> thread · <C-g>s suggest · @ mention · q cancel "
    end
    return " <C-s> save · <C-g>s suggest · @ mention · q cancel "
end

local function submit_compose(session, buf, on_submit, origin)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    if session and session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local text = buffer_body(buf)
    if vim.trim(text) == "" then
        return require("jpr").error("comment body cannot be empty")
    end
    pcall(vim.cmd, "stopinsert")
    M.close(session)
    on_submit(text, origin)
end

local function flip_destination(session, compose)
    if not vim.api.nvim_win_is_valid(compose.win) then
        return
    end
    compose.origin = alternate_origin(compose.origin)
    session.compose_destination = compose.origin
    vim.api.nvim_win_set_config(compose.win, {
        title = " " .. M.build_title_from_anchor(compose.anchor, compose.origin) .. " ",
        title_pos = "center",
    })
end

local function create_cancel_handler(session, buf, initial_text)
    return function()
        if vim.api.nvim_buf_is_valid(buf) and buffer_body(buf) ~= initial_text then
            if vim.fn.confirm("Discard unsaved comment text?", "&Discard\n&Keep editing", 2) ~= 1 then
                return
            end
        end
        M.close(session)
    end
end

local function bind_compose_keys(session, compose, opts, on_cancel, on_submit)
    local buf = compose.buf
    vim.keymap.set({ "n", "i" }, "<C-s>", on_submit, { buffer = buf, silent = true, desc = "Save comment" })
    if opts.allow_destination_toggle then
        vim.keymap.set({ "n", "i" }, "<M-s>", function()
            submit_compose(session, buf, opts.on_submit, alternate_origin(compose.origin))
        end, { buffer = buf, silent = true, desc = "Save comment to other destination" })
        vim.keymap.set("n", "<C-g>", function()
            flip_destination(session, compose)
        end, { buffer = buf, nowait = true, silent = true, desc = "Flip comment destination" })
        vim.keymap.set("i", "<C-g>", function()
            flip_destination(session, compose)
        end, { buffer = buf, silent = true, desc = "Flip comment destination" })
    end
    vim.keymap.set("n", "q", on_cancel, { buffer = buf, nowait = true, silent = true, desc = "Cancel comment" })
    vim.keymap.set("n", "<Esc>", on_cancel, { buffer = buf, nowait = true, silent = true, desc = "Cancel comment" })
    vim.keymap.set("i", "<C-g>s", function()
        insert_suggestion_fence(session, buf, opts.anchor)
    end, { buffer = buf, nowait = true, silent = true, desc = "Insert GitHub suggestion block" })
end

local function register_wipeout_guard(session, compose, wiped_buf)
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = wiped_buf,
        once = true,
        callback = function()
            if session.compose ~= compose then
                return
            end
            session.compose = nil
            if wiped_buf ~= compose.buf then
                close_window_and_buffer(compose.win, compose.buf)
            end
            if wiped_buf ~= compose.history_buf then
                close_window_and_buffer(compose.history_win, compose.history_buf)
            end
        end,
    })
end

local function create_editor_geometry_from_thread(history_thread)
    local has_messages = type(history_thread) == "table"
        and type(history_thread.messages) == "table"
        and #history_thread.messages > 0
    if has_messages then
        local history_layout = render_threads.create_popup_layout_from_threads(
            { history_thread },
            { include_footer = false }
        )
        local geometry = reply_history.compute_stacked_geometry(vim.o.lines, vim.o.columns, #history_layout.lines)
        return geometry, history_layout
    end
    local width = math.min(86, math.max(54, vim.o.columns - 12))
    local height = 12
    return {
        width = width,
        col = math.max(2, math.floor((vim.o.columns - width) / 2)),
        reply_row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
        reply_height = height,
    }, nil
end

local function attach_docked_history(session, compose, thread, history_layout, geometry, on_cancel, on_submit)
    local history = reply_history.open(thread, geometry, {
        on_focus_reply = function()
            if vim.api.nvim_win_is_valid(compose.win) then
                vim.api.nvim_set_current_win(compose.win)
            end
        end,
        on_cancel = on_cancel,
        on_submit = on_submit,
    }, history_layout)
    compose.history_buf = history.buf
    compose.history_win = history.win
    local focus_history = function()
        if vim.api.nvim_win_is_valid(history.win) then
            vim.api.nvim_set_current_win(history.win)
        end
    end
    vim.keymap.set("n", "<Tab>", focus_history, { buffer = compose.buf, nowait = true, silent = true, desc = "Focus thread history" })
    vim.keymap.set("n", "<C-w>k", focus_history, { buffer = compose.buf, nowait = true, silent = true, desc = "Focus thread history" })
    register_wipeout_guard(session, compose, history.buf)
end

--- Opens the floating compose editor for `session`, optionally docking a
--- read-only thread history pane above it when `opts.history_thread` has messages.
function M.open(session, opts)
    if session and session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    M.close(session)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    local initial_text = opts.initial_text or ""
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial_text, "\n", { plain = true }))
    local geometry, history_layout = create_editor_geometry_from_thread(opts.history_thread)
    local has_history = history_layout ~= nil
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = geometry.reply_row,
        col = geometry.col,
        width = geometry.width,
        height = geometry.reply_height,
        style = "minimal",
        border = "rounded",
        title = " " .. opts.title .. " ",
        title_pos = "center",
        footer = build_footer(opts.allow_destination_toggle, opts.is_local_only, opts.is_unlinked_local, has_history),
        footer_pos = "center",
    })
    vim.api.nvim_set_option_value("wrap", true, { win = win, scope = "local" })
    local compose = { buf = buf, win = win, origin = opts.origin, anchor = opts.anchor }
    session.compose = compose
    local on_cancel = create_cancel_handler(session, buf, initial_text)
    local on_submit = function()
        submit_compose(session, buf, opts.on_submit, compose.origin)
    end
    register_wipeout_guard(session, compose, buf)
    mentions.attach(session, buf)
    bind_compose_keys(session, compose, opts, on_cancel, on_submit)
    if has_history then
        attach_docked_history(session, compose, opts.history_thread, history_layout, geometry, on_cancel, on_submit)
    end
    return buf
end

return M
