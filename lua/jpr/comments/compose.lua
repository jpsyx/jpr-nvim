-- Floating markdown compose buffer for new comments, replies, edits, and
-- suggestion blocks. `<C-s>` submits; `q` / `<Esc>` cancels; `<C-g>s` inserts
-- a suggestion fence pre-filled with the anchored lines.
local mentions = require("jpr.comments.mentions")

local M = {}

local function next_request_id(session)
    if not session then
        return 0
    end
    session.compose_request_id = (session.compose_request_id or 0) + 1
    return session.compose_request_id
end

--- Closes the active floating compose buffer for `session`, if any.
function M.close(session)
    if not session then
        return
    end
    next_request_id(session)
    local compose = session.compose
    if not compose then
        return
    end
    session.compose = nil
    if compose.win and vim.api.nvim_win_is_valid(compose.win) then
        pcall(vim.api.nvim_win_close, compose.win, true)
    end
    if compose.buf and vim.api.nvim_buf_is_valid(compose.buf) then
        pcall(vim.api.nvim_buf_delete, compose.buf, { force = true })
    end
end

local function buffer_body(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function insert_suggestion_fence(session, buf, anchor)
    if not anchor or (anchor.kind ~= "line" and anchor.kind ~= "range") then
        return require("jpr").info("suggestion blocks apply to line or range comments")
    end
    local compose = session and session.compose
    require("jpr.session").request(session, "anchoredLines", { anchor = anchor }, function(res)
        if session.closing or session.compose ~= compose or not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        local win = compose and compose.win
        if not win or not vim.api.nvim_win_is_valid(win) then
            return
        end
        local fence = { "```suggestion" }
        for line in ((res and res.text or "") .. "\n"):gmatch("(.-)\n") do
            fence[#fence + 1] = line
        end
        fence[#fence + 1] = "```"
        local row = vim.api.nvim_win_get_cursor(win)[1]
        vim.api.nvim_buf_set_lines(buf, row, row, false, fence)
    end)
end

local function bind_compose_keys(session, buf, initial_text, anchor, on_submit)
    local submit = function()
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        local text = buffer_body(buf)
        if vim.trim(text) == "" then
            return require("jpr").error("comment body cannot be empty")
        end
        pcall(vim.cmd, "stopinsert")
        M.close(session)
        on_submit(text)
    end
    local cancel = function()
        if vim.api.nvim_buf_is_valid(buf) and buffer_body(buf) ~= initial_text then
            if vim.fn.confirm("Discard unsaved comment text?", "&Discard\n&Keep editing", 2) ~= 1 then
                return
            end
        end
        M.close(session)
    end
    vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, silent = true, desc = "Save comment" })
    vim.keymap.set("n", "q", cancel, { buffer = buf, nowait = true, silent = true, desc = "Cancel comment" })
    vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, nowait = true, silent = true, desc = "Cancel comment" })
    vim.keymap.set("i", "<C-g>s", function()
        insert_suggestion_fence(session, buf, anchor)
    end, { buffer = buf, nowait = true, silent = true, desc = "Insert GitHub suggestion block" })
end

local function open_editor(session, opts)
    M.close(session)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    local initial = opts.initial or ""
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial, "\n", { plain = true }))
    local width = math.min(86, math.max(54, vim.o.columns - 12))
    local height = 12
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(2, math.floor((vim.o.columns - width) / 2)),
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = " " .. opts.title .. " ",
        title_pos = "center",
        footer = " <C-s> save · <C-g>s suggestion · @ mention · q cancel ",
        footer_pos = "center",
    })
    vim.api.nvim_set_option_value("wrap", true, { win = win, scope = "local" })
    local compose = { buf = buf, win = win }
    session.compose = compose
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            if session.compose == compose then
                session.compose = nil
            end
        end,
    })
    mentions.attach(session, buf)
    bind_compose_keys(session, buf, initial, opts.anchor, opts.on_submit)
    return buf
end

local function build_new_title(anchor)
    if anchor.kind == "pr" then
        return "[GitHub comment] PR Conversation"
    end
    if anchor.kind == "file" then
        return "[GitHub draft] " .. anchor.file
    end
    if anchor.kind == "range" and anchor.start and anchor["end"] and anchor.start ~= anchor["end"] then
        return ("[GitHub draft] %s:%d-%d"):format(anchor.file, anchor.start, anchor["end"])
    end
    return ("[GitHub draft] %s:%d"):format(anchor.file, anchor["end"] or anchor.start or 1)
end

--- Opens the floating compose buffer for a new comment at `anchor`.
--- When `opts.suggest` is true on a line/range anchor, pre-fills a GitHub
--- `suggestion` block from `anchoredLines`.
function M.open_new(session, anchor, opts)
    if session.closing then
        return
    end
    local open_with_body = function(initial)
        open_editor(session, {
            title = build_new_title(anchor),
            initial = initial,
            anchor = anchor,
            on_submit = function(body)
                require("jpr.session").request(session, "comment", { anchor = anchor, body = body }, function() end)
            end,
        })
    end
    if opts and opts.suggest and (anchor.kind == "line" or anchor.kind == "range") then
        local request_id = next_request_id(session)
        return require("jpr.session").request(session, "anchoredLines", { anchor = anchor }, function(res)
            if session.closing or session.compose_request_id ~= request_id then
                return
            end
            if session.tab ~= nil and not vim.api.nvim_tabpage_is_valid(session.tab) then
                return
            end
            open_with_body(("```suggestion\n%s\n```"):format((res and res.text) or ""))
        end)
    end
    open_with_body("")
end

--- Opens the floating compose buffer to reply to `thread`.
function M.open_reply(session, thread)
    local badge = "[GitHub reply]"
    if session.view and (session.view.draftCount or 0) > 0 then
        badge = "[GitHub draft]"
    end
    local thread_id = thread.threadId or thread.id
    open_editor(session, {
        title = badge .. " Reply",
        initial = "",
        anchor = thread.anchor,
        on_submit = function(body)
            require("jpr.session").request(session, "reply", { threadId = thread_id, body = body }, function() end)
        end,
    })
end

--- Opens the floating compose buffer to edit `message` (pre-populating
--- `recoverableBody` when present).
function M.open_edit(session, message)
    local initial = message.recoverableBody or message.body or ""
    open_editor(session, {
        title = "[Edit GitHub comment]",
        initial = initial,
        on_submit = function(body)
            require("jpr.session").request(session, "editMessage", { messageId = message.id, body = body }, function() end)
        end,
    })
end

return M
