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

local function build_location_from_anchor(anchor)
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

local function build_title_from_anchor(anchor, origin)
    local location = build_location_from_anchor(anchor)
    if origin == "local" then
        return "[Local → agent] " .. location
    end
    local badge = (anchor and anchor.kind == "pr") and "[GitHub comment]" or "[GitHub draft]"
    return badge .. " " .. location
end

local function is_local_only_anchor(session, anchor)
    if type(anchor) ~= "table" or type(anchor.file) ~= "string" or anchor.file == "" then
        return false
    end
    local files = session and session.view and session.view.files or {}
    for _, file in ipairs(files) do
        if file.path == anchor.file then
            return file.isLocalOnly == true
        end
    end
    return false
end

local function build_footer(allow_destination_toggle, is_local_only)
    if is_local_only then
        return " <C-s> save · local only (unpushed file) · q cancel "
    end
    if allow_destination_toggle then
        return " <C-s> save · <C-g> flip dest · <M-s> other dest · <C-g>s suggest · q cancel "
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
        title = " " .. build_title_from_anchor(compose.anchor, compose.origin) .. " ",
        title_pos = "center",
    })
end

local function bind_compose_keys(session, compose, opts)
    local buf = compose.buf
    local initial_text = opts.initial_text or ""
    local cancel = function()
        if vim.api.nvim_buf_is_valid(buf) and buffer_body(buf) ~= initial_text then
            if vim.fn.confirm("Discard unsaved comment text?", "&Discard\n&Keep editing", 2) ~= 1 then
                return
            end
        end
        M.close(session)
    end
    vim.keymap.set({ "n", "i" }, "<C-s>", function()
        submit_compose(session, buf, opts.on_submit, compose.origin)
    end, { buffer = buf, silent = true, desc = "Save comment" })
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
    vim.keymap.set("n", "q", cancel, { buffer = buf, nowait = true, silent = true, desc = "Cancel comment" })
    vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, nowait = true, silent = true, desc = "Cancel comment" })
    vim.keymap.set("i", "<C-g>s", function()
        insert_suggestion_fence(session, buf, opts.anchor)
    end, { buffer = buf, nowait = true, silent = true, desc = "Insert GitHub suggestion block" })
end

local function open_editor(session, opts)
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
        footer = build_footer(opts.allow_destination_toggle, opts.is_local_only),
        footer_pos = "center",
    })
    vim.api.nvim_set_option_value("wrap", true, { win = win, scope = "local" })
    local compose = { buf = buf, win = win, origin = opts.origin, anchor = opts.anchor }
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
    bind_compose_keys(session, compose, opts)
    return buf
end

--- Opens the floating compose buffer for a new comment at `anchor`, optionally
--- pre-filling a GitHub suggestion block on line or range anchors (`opts.suggest`).
function M.open_new(session, anchor, opts)
    if not session or session.closing then
        return
    end
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local open_opts = opts or {}
    local is_local_only = is_local_only_anchor(session, anchor)
    local open_with_body = function(initial_text)
        local origin = is_local_only and "local" or (open_opts.initial_origin or session.compose_destination or "github")
        open_editor(session, {
            title = build_title_from_anchor(anchor, origin),
            initial_text = initial_text,
            anchor = anchor,
            origin = origin,
            allow_destination_toggle = not is_local_only,
            is_local_only = is_local_only,
            on_submit = function(body, submit_origin)
                require("jpr.session").request(session, "comment", {
                    anchor = anchor,
                    body = body,
                    origin = submit_origin,
                }, function() end)
            end,
        })
    end
    if open_opts.suggest and (anchor.kind == "line" or anchor.kind == "range") then
        local request_id = next_request_id(session)
        return require("jpr.session").request(session, "anchoredLines", { anchor = anchor }, function(result)
            if session.closing or session.compose_request_id ~= request_id then
                return
            end
            if session.tab ~= nil and not vim.api.nvim_tabpage_is_valid(session.tab) then
                return
            end
            open_with_body(("```suggestion\n%s\n```"):format((result and result.text) or ""))
        end)
    end
    open_with_body("")
end

--- Opens the floating compose buffer to reply to `thread`.
function M.open_reply(session, thread)
    if not session or session.closing then
        return
    end
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local is_local = thread.origin == "local" or thread.kind == "local"
    local badge = is_local and "[Local reply]" or "[GitHub reply]"
    if not is_local and session.view and (session.view.draftCount or 0) > 0 then
        badge = "[GitHub draft]"
    end
    local thread_id = thread.threadId or thread.id
    open_editor(session, {
        title = badge .. " Reply",
        initial_text = "",
        anchor = thread.anchor,
        allow_destination_toggle = false,
        on_submit = function(body)
            require("jpr.session").request(session, "reply", { threadId = thread_id, body = body }, function() end)
        end,
    })
end

--- Opens the floating compose buffer to edit `message` (pre-populating
--- `recoverableBody` when present).
function M.open_edit(session, message, thread)
    if not session or session.closing then
        return
    end
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local is_local = (thread ~= nil and (thread.origin == "local" or thread.kind == "local"))
        or message.sync == nil
        or message.sync == vim.NIL
    local title = is_local and "[Edit local comment]" or "[Edit GitHub comment]"
    local initial_text = (type(message.recoverableBody) == "string" and message.recoverableBody)
        or (type(message.body) == "string" and message.body)
        or ""
    local anchor = type(thread) == "table" and type(thread.anchor) == "table" and thread.anchor or nil
    open_editor(session, {
        title = title,
        initial_text = initial_text,
        anchor = anchor,
        allow_destination_toggle = false,
        on_submit = function(body)
            require("jpr.session").request(session, "editMessage", { messageId = message.id, body = body }, function() end)
        end,
    })
end

--- Opens the floating compose buffer to promote a local `thread`'s root
--- comment into a GitHub draft or PR comment.
function M.open_promote(session, thread)
    if not session or session.closing or not thread then
        return
    end
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    if type(thread.promotedTo) == "string" and thread.promotedTo ~= "" then
        return require("jpr").info("local thread was already promoted to " .. thread.promotedTo)
    end
    local thread_id = thread.threadId or thread.id
    local messages = type(thread.messages) == "table" and thread.messages or {}
    local first_message = messages[1]
    local raw_body = type(first_message) == "table" and first_message.body or ""
    local initial_text = type(raw_body) == "string" and raw_body or ""
    open_editor(session, {
        title = "[Promote → GitHub] " .. build_location_from_anchor(thread.anchor),
        initial_text = initial_text,
        anchor = thread.anchor,
        allow_destination_toggle = false,
        on_submit = function(body)
            require("jpr.session").request(session, "promoteThread", {
                threadId = thread_id,
                body = body,
            }, function() end)
        end,
    })
end

return M
