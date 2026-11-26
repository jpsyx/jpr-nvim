-- Floating review submission modal (`:Jpr submit`): shows pending drafts,
-- blocked reasons, action selection (COMMENT / APPROVE / REQUEST_CHANGES), an
-- editable review summary buffer, and a final confirmation dialog.
local confirm = require("jpr.views.confirm")
local main_window = require("jpr.views.main_window")
local mouse = require("jpr.mouse")
local render = require("jpr.render.submit")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-submit")

local SUBMIT_FOOTER_SPECS = {
    { token = "[e] summary", action = "summary" },
    { token = "[<C-s>] submit", action = "submit" },
    { token = "[q] cancel", action = "close" },
}

local EVENT_LABELS = {
    COMMENT = "Comment",
    APPROVE = "Approve",
    REQUEST_CHANGES = "Request changes",
}

local function next_request_id(session)
    if not session then
        return 0
    end
    session.submit_request_id = (session.submit_request_id or 0) + 1
    return session.submit_request_id
end

local function close_confirm(state)
    local dialog = state and state.confirm
    if not dialog then
        return
    end
    state.confirm = nil
    confirm.close(dialog)
end

local function close_editor(state)
    local editor = state and state.editor
    if not editor then
        return
    end
    state.editor = nil
    if editor.win and vim.api.nvim_win_is_valid(editor.win) then
        pcall(vim.api.nvim_win_close, editor.win, true)
    end
    if editor.buf and vim.api.nvim_buf_is_valid(editor.buf) then
        pcall(vim.api.nvim_buf_delete, editor.buf, { force = true })
    end
end

local function close_active_submit(session)
    local state = session and session.submit
    if not state then
        return
    end
    session.submit = nil
    close_confirm(state)
    close_editor(state)
    if state.win and vim.api.nvim_win_is_valid(state.win) then
        pcall(vim.api.nvim_win_close, state.win, true)
    end
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
    end
end

--- Closes the active review submission modal and any open summary editor for `session`.
function M.close(session)
    if not session then
        return
    end
    next_request_id(session)
    close_active_submit(session)
end

local function paint_modal(state)
    if not vim.api.nvim_buf_is_valid(state.buf) then
        return
    end
    local rendered = render.build(state.preview, state.event, state.body_lines)
    state.rendered = rendered
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, rendered.lines)
    vim.bo[state.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
    for _, highlight in ipairs(rendered.highlights) do
        vim.api.nvim_buf_set_extmark(state.buf, namespace, highlight.line, highlight.col_start, {
            end_col = highlight.col_end,
            hl_group = highlight.group,
            strict = false,
        })
    end
    if state.win and vim.api.nvim_win_is_valid(state.win) then
        local saved_cursor = vim.api.nvim_win_get_cursor(state.win)
        pcall(vim.api.nvim_win_set_height, state.win, math.min(26, math.max(10, #rendered.lines)))
        local clamped_line = math.max(1, math.min(saved_cursor[1], #rendered.lines))
        pcall(vim.api.nvim_win_set_cursor, state.win, { clamped_line, saved_cursor[2] })
    end
end

local function select_event(state, event)
    if state.in_flight or confirm.is_open(state.confirm) then
        return
    end
    if event ~= "COMMENT" and not state.preview.canApproveOrRequestChanges then
        return require("jpr").info("cannot approve or request changes on your own PR")
    end
    state.event = event
    paint_modal(state)
end

local function build_submit_confirm_headline(event, draft_count, body)
    local action_label = EVENT_LABELS[event] or tostring(event)
    local count = tonumber(draft_count) or 0
    local draft_noun = count == 1 and "draft comment" or "draft comments"
    local has_summary = vim.trim(body) ~= ""
    if count == 0 and has_summary then
        return ("Submit %s review with 0 draft comments (summary only) to GitHub?"):format(action_label)
    end
    if has_summary then
        return ("Submit %s review with %d %s and a summary to GitHub?"):format(action_label, count, draft_noun)
    end
    return ("Submit %s review with %d %s to GitHub?"):format(action_label, count, draft_noun)
end

local function execute_submit_review(session, state, event, body)
    if state.in_flight or session.closing or session.submit ~= state then
        return
    end
    state.in_flight = true
    require("jpr.session").request(session, "submitReview", {
        event = event,
        body = body,
    }, function()
        state.in_flight = false
        if session.closing or session.submit ~= state then
            return
        end
        M.close(session)
        require("jpr").info("review submitted")
    end, function()
        state.in_flight = false
        if session.submit == state and state.win and vim.api.nvim_win_is_valid(state.win) then
            pcall(vim.api.nvim_set_current_win, state.win)
        end
    end)
end

local function submit_review(session, state)
    if state.in_flight or confirm.is_open(state.confirm) then
        return
    end
    local blocked_reason = state.preview.blockedReason
    if blocked_reason and blocked_reason ~= "" then
        return require("jpr").error(blocked_reason)
    end
    local confirmed_event = state.event
    if confirmed_event ~= "COMMENT" and not state.preview.canApproveOrRequestChanges then
        return require("jpr").info("cannot approve or request changes on your own PR")
    end
    local body = table.concat(state.body_lines or {}, "\n")
    local draft_count = state.preview.draftCount or 0
    if confirmed_event == "COMMENT" and draft_count == 0 and vim.trim(body) == "" then
        return require("jpr").error("a comment review with zero drafts needs a summary body")
    end
    local dialog
    dialog = confirm.open({
        title = " Confirm GitHub Review Submission ",
        headline = build_submit_confirm_headline(confirmed_event, draft_count, body),
        confirm_label = "Submit to GitHub",
        confirm_badge = "[submit]",
        confirm_help = "Publish this review and its pending draft comments on GitHub.",
        cancel_label = "Cancel",
        cancel_help = "Return to the Submit Review preview without publishing.",
        on_confirm = function()
            if state.confirm == dialog then
                state.confirm = nil
            end
            execute_submit_review(session, state, confirmed_event, body)
        end,
        on_cancel = function()
            if state.confirm == dialog then
                state.confirm = nil
            end
            if session.submit == state and state.win and vim.api.nvim_win_is_valid(state.win) then
                pcall(vim.api.nvim_set_current_win, state.win)
            end
        end,
    })
    state.confirm = dialog
end

local function activate_cursor_row(session, state)
    if not state.win or not vim.api.nvim_win_is_valid(state.win) then
        return
    end
    local cursor_line = vim.api.nvim_win_get_cursor(state.win)[1]
    local anchor = state.rendered and state.rendered.draft_anchors[cursor_line]
    if not anchor then
        return submit_review(session, state)
    end
    M.close(session)
    if anchor.file then
        local target_line = anchor["end"] or anchor.start or 1
        main_window.edit(session, main_window.find(session), anchor.file, target_line)
    else
        require("jpr.views.conversation").show(session)
    end
end

local function bind_editor_keys(session, state, editor)
    local save = function()
        pcall(vim.cmd, "stopinsert")
        local lines = vim.api.nvim_buf_is_valid(editor.buf)
            and vim.api.nvim_buf_get_lines(editor.buf, 0, -1, false)
            or state.body_lines
        close_editor(state)
        if session.submit ~= state or not vim.api.nvim_buf_is_valid(state.buf) then
            return
        end
        state.body_lines = lines
        paint_modal(state)
        if state.win and vim.api.nvim_win_is_valid(state.win) then
            pcall(vim.api.nvim_set_current_win, state.win)
        end
    end
    local cancel = function()
        close_editor(state)
        if session.submit == state and state.win and vim.api.nvim_win_is_valid(state.win) then
            pcall(vim.api.nvim_set_current_win, state.win)
        end
    end
    vim.keymap.set({ "n", "i" }, "<C-s>", save, { buffer = editor.buf, silent = true, desc = "Save review summary" })
    vim.keymap.set("n", "q", cancel, { buffer = editor.buf, nowait = true, silent = true, desc = "Cancel summary edit" })
    vim.keymap.set("n", "<Esc>", cancel, { buffer = editor.buf, nowait = true, silent = true, desc = "Cancel summary edit" })
end

local function open_summary_editor(session, state)
    if state.in_flight or confirm.is_open(state.confirm) then
        return
    end
    close_editor(state)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    local initial_lines = (state.body_lines and #state.body_lines > 0) and state.body_lines or { "" }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)
    local width = math.min(82, math.max(52, vim.o.columns - 14))
    local height = 10
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(2, math.floor((vim.o.columns - width) / 2)),
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = " Review Summary ",
        title_pos = "center",
        footer = " <C-s> save · q cancel ",
        footer_pos = "center",
    })
    vim.api.nvim_set_option_value("wrap", true, { win = win, scope = "local" })
    local editor = { buf = buf, win = win }
    state.editor = editor
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            if state.editor == editor then
                state.editor = nil
            end
        end,
    })
    bind_editor_keys(session, state, editor)
end

local function handle_modal_click(session, state)
    local click = mouse.get_click()
    if not click then
        return
    end
    if not mouse.is_click_in_window(click, state.win) then
        return M.close(session)
    end
    local rendered = state.rendered
    if not rendered then
        return
    end
    local event = rendered.event_lines and rendered.event_lines[click.line]
    if event then
        return select_event(state, event)
    end
    if rendered.draft_anchors and rendered.draft_anchors[click.line] then
        mouse.set_cursor_from_click(state.win, click)
        return activate_cursor_row(session, state)
    end
    if rendered.summary_lines and rendered.summary_lines[click.line] then
        return open_summary_editor(session, state)
    end
    local footer_line = rendered.footer_line
    local spans = mouse.parse_footer_actions(rendered.lines[footer_line], SUBMIT_FOOTER_SPECS)
    local action = mouse.hit_test_footer_action(footer_line, spans, click.line, click.column)
    if action == "summary" then
        open_summary_editor(session, state)
    elseif action == "submit" then
        submit_review(session, state)
    elseif action == "close" then
        M.close(session)
    end
end

local function bind_modal_keys(session, state)
    local map = function(lhs, handler, desc)
        vim.keymap.set("n", lhs, handler, { buffer = state.buf, nowait = true, silent = true, desc = desc })
    end
    map("1", function() select_event(state, "COMMENT") end, "Select Comment review action")
    map("2", function() select_event(state, "APPROVE") end, "Select Approve review action")
    map("3", function() select_event(state, "REQUEST_CHANGES") end, "Select Request changes review action")
    map("e", function() open_summary_editor(session, state) end, "Edit review summary")
    map("<CR>", function() activate_cursor_row(session, state) end, "Open draft or submit review")
    map("<C-s>", function() submit_review(session, state) end, "Submit review")
    map("q", function() M.close(session) end, "Close submit modal")
    map("<Esc>", function() M.close(session) end, "Close submit modal")
    map("<LeftMouse>", function() handle_modal_click(session, state) end, "Click submit modal item or action")
end

local function open_modal(session, preview)
    close_active_submit(session)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    local state = {
        buf = buf,
        preview = preview,
        event = "COMMENT",
        body_lines = {},
        in_flight = false,
    }
    paint_modal(state)
    local width = math.min(88, math.max(58, vim.o.columns - 10))
    local height = math.min(26, math.max(10, #state.rendered.lines))
    state.win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(2, math.floor((vim.o.columns - width) / 2)),
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = " Submit Review ",
        title_pos = "center",
    })
    vim.api.nvim_set_option_value("wrap", true, { win = state.win, scope = "local" })
    session.submit = state
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            if session.submit == state then
                session.submit = nil
                close_confirm(state)
                close_editor(state)
            end
        end,
    })
    bind_modal_keys(session, state)
end

--- Opens the centered floating review submission modal for `session`.
function M.open(session)
    if not session or session.closing then
        return
    end
    local request_id = next_request_id(session)
    require("jpr.session").request(session, "submitPreview", nil, function(preview)
        if session.closing or session.submit_request_id ~= request_id then
            return
        end
        if session.tab ~= nil and not vim.api.nvim_tabpage_is_valid(session.tab) then
            return
        end
        open_modal(session, preview or {})
    end)
end

return M
