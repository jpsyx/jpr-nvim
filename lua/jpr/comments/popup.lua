-- Floating thread inspector at the cursor: renders full messages and dispatches
-- reply (r), edit (e), delete (d), resolve (R), reaction (+), retry (X),
-- promote (p), and send (s).
local mouse = require("jpr.mouse")
local render = require("jpr.render.threads")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-popup")

local POPUP_FOOTER_SPECS = {
    { token = "[r]eply", action = "reply" },
    { token = "[e]dit", action = "edit" },
    { token = "[d]elete", action = "delete" },
    { token = "[R]esolve", action = "resolve" },
    { token = "[+]react", action = "react" },
    { token = "[X]retry", action = "retry" },
    { token = "[p]romote", action = "promote" },
    { token = "[s]end", action = "send" },
    { token = "[q]uit", action = "close" },
}

local function clamp_popup_height(line_count)
    return math.min(22, math.max(6, line_count))
end

--- Closes the active floating thread popup for `session`, if any.
function M.close(session)
    local popup = session and session.popup
    if not popup then
        return
    end
    session.popup = nil
    if vim.api.nvim_win_is_valid(popup.win) then
        pcall(vim.api.nvim_win_close, popup.win, true)
    end
    if vim.api.nvim_buf_is_valid(popup.buf) then
        pcall(vim.api.nvim_buf_delete, popup.buf, { force = true })
    end
end

local function current_entry(session)
    local popup = session.popup
    if not popup or not popup.win or not vim.api.nvim_win_is_valid(popup.win) then
        return nil
    end
    local cursor_line = vim.api.nvim_win_get_cursor(popup.win)[1]
    return render.find_message_at_line(popup.layout, cursor_line), popup
end

--- Prompts the user to pick a GitHub reaction and passes the chosen content to `on_select`.
function M.pick_reaction(on_select)
    vim.ui.select(render.REACTION_ORDER, {
        prompt = "Toggle reaction:",
        format_item = function(content)
            return ("%s  %s"):format(render.REACTION_EMOJI[content] or "", content)
        end,
    }, function(choice)
        if choice then
            on_select(choice)
        end
    end)
end

local function toggle_popup_reaction(session)
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local entry, popup = current_entry(session)
    if not entry then
        return
    end
    if render.is_local_thread(entry.thread) then
        return require("jpr").info("reactions apply only to GitHub comments")
    end
    M.pick_reaction(function(choice)
        if session.popup ~= popup then
            return
        end
        require("jpr.session").request(session, "toggleReaction", {
            messageId = entry.message_id,
            content = choice,
        }, function(result)
            if session.popup ~= popup then
                return
            end
            if result and result.thread then
                M.refresh_from_thread(session, result.thread)
            end
        end)
    end)
end

local function toggle_resolved(session)
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local entry, popup = current_entry(session)
    if not entry then
        return
    end
    local next_resolved = entry.thread.state ~= "resolved"
    require("jpr.session").request(session, "setResolved", {
        threadId = entry.thread_id,
        resolved = next_resolved,
    }, function(result)
        if session.popup ~= popup then
            return
        end
        if result and result.thread then
            M.refresh_from_thread(session, result.thread)
        end
    end)
end

local function delete_current_message(session)
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local entry, popup = current_entry(session)
    if not entry then
        return
    end
    if not render.is_local_thread(entry.thread) and not entry.message.viewerDidAuthor then
        return require("jpr").error("you can only delete your own comments")
    end
    if vim.fn.confirm("Delete this comment?", "&Yes\n&No", 2) ~= 1 or session.popup ~= popup then
        return
    end
    require("jpr.session").request(session, "deleteMessage", { messageId = entry.message_id }, function()
        if session.popup ~= popup then
            return
        end
        M.close(session)
    end)
end

local function retry_current_message(session)
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local entry, popup = current_entry(session)
    if not entry or entry.message.sync ~= "failed" then
        return require("jpr").info("this message is not in a failed state")
    end
    require("jpr.session").request(session, "retryMessage", { messageId = entry.message_id }, function()
        if session.popup ~= popup then
            return
        end
        M.close(session)
    end)
end

local function open_reply(session)
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local entry = current_entry(session)
    if entry then
        M.close(session)
        require("jpr.comments.compose").open_reply(session, entry.thread)
    end
end

local function open_edit(session)
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local entry = current_entry(session)
    if not entry then
        return
    end
    if not entry.message.viewerDidAuthor then
        return require("jpr").error("you can only edit your own comments")
    end
    M.close(session)
    require("jpr.comments.compose").open_edit(session, entry.message, entry.thread)
end

local function promote_current_thread(session)
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    if session.mode == "local" and not (session.view and session.view.pr) then
        return require("jpr").info("cannot promote to GitHub in local review mode; run :Jpr sync once a PR is open")
    end
    local entry = current_entry(session)
    if not entry then
        return
    end
    if not render.is_local_thread(entry.thread) then
        return require("jpr").info("only local threads can be promoted to GitHub")
    end
    if type(entry.thread.promotedTo) == "string" and entry.thread.promotedTo ~= "" then
        return require("jpr").info("local thread was already promoted to " .. entry.thread.promotedTo)
    end
    M.close(session)
    require("jpr.comments.compose").open_promote(session, entry.thread)
end

local function send_current_thread(session)
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local entry = current_entry(session)
    if not entry then
        return
    end
    if not render.is_local_thread(entry.thread) then
        return require("jpr").info("only local threads can be sent to the agent")
    end
    M.close(session)
    require("jpr.agent").send(session, entry.thread_id)
end

local POPUP_FOOTER_HANDLERS = {
    reply = open_reply,
    edit = open_edit,
    delete = delete_current_message,
    resolve = toggle_resolved,
    react = toggle_popup_reaction,
    retry = retry_current_message,
    promote = promote_current_thread,
    send = send_current_thread,
    close = function(session) M.close(session) end,
}

local function handle_popup_click(session)
    local popup = session and session.popup
    local click = mouse.get_click()
    if not popup or not click then
        return
    end
    if not mouse.is_click_in_window(click, popup.win) then
        return M.close(session)
    end
    local lines = popup.layout and popup.layout.lines or {}
    if click.line == #lines then
        local action = mouse.hit_test_footer_line(lines, POPUP_FOOTER_SPECS, click)
        local handler = action and POPUP_FOOTER_HANDLERS[action]
        if handler then
            handler(session)
        end
        return
    end
    mouse.set_cursor_from_click(popup.win, click)
end

local function bind_popup_keys(session, buf)
    local map = function(lhs, handler, desc)
        vim.keymap.set("n", lhs, handler, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
    map("q", function() M.close(session) end, "Close thread popup")
    map("<Esc>", function() M.close(session) end, "Close thread popup")
    map("R", function() toggle_resolved(session) end, "Resolve or unresolve thread")
    map("+", function() toggle_popup_reaction(session) end, "Toggle reaction on message")
    map("d", function() delete_current_message(session) end, "Delete own message")
    map("X", function() retry_current_message(session) end, "Retry failed message")
    map("r", function() open_reply(session) end, "Reply to thread")
    map("e", function() open_edit(session) end, "Edit own message")
    map("p", function() promote_current_thread(session) end, "Promote local thread to GitHub")
    map("s", function() send_current_thread(session) end, "Send local thread to agent")
    map("<LeftMouse>", function() handle_popup_click(session) end, "Select message or click popup footer action")
end

local function paint_popup(popup, threads)
    local layout = render.create_popup_layout_from_threads(threads)
    popup.threads, popup.layout = threads, layout
    vim.bo[popup.buf].modifiable = true
    vim.api.nvim_buf_set_lines(popup.buf, 0, -1, false, layout.lines)
    vim.bo[popup.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(popup.buf, namespace, 0, -1)
    for _, highlight in ipairs(layout.highlights) do
        vim.api.nvim_buf_set_extmark(popup.buf, namespace, highlight.line, highlight.col_start, {
            end_col = highlight.col_end,
            hl_group = highlight.group,
            strict = false,
        })
    end
end

local function merge_updated_thread(item, updated_thread)
    local updated_messages = updated_thread.messages or {}
    local is_outdated = item.outdated
    if updated_thread.outdated ~= nil then
        is_outdated = updated_thread.outdated
    end
    local merged = vim.tbl_extend("force", item, {
        origin = updated_thread.origin or item.origin,
        kind = updated_thread.kind or item.kind,
        state = updated_thread.state,
        outdated = is_outdated,
        messages = updated_messages,
        messageCount = #updated_messages,
    })
    merged.agent = updated_thread.agent
    merged.promotedTo = updated_thread.promotedTo
    return merged
end

--- Updates the open popup in place when `updated_thread` changes, clamping the
--- window height and cursor position if the rendered line count shrinks.
function M.refresh_from_thread(session, updated_thread)
    local popup = session and session.popup
    if
        not popup
        or not updated_thread
        or not popup.buf
        or not vim.api.nvim_buf_is_valid(popup.buf)
        or not popup.win
        or not vim.api.nvim_win_is_valid(popup.win)
    then
        return
    end
    local target_id = type(updated_thread.id) == "string" and updated_thread.id or updated_thread.threadId
    local updated_list, was_matched = {}, false
    for _, item in ipairs(popup.threads or {}) do
        if item.threadId == target_id then
            was_matched = true
            updated_list[#updated_list + 1] = merge_updated_thread(item, updated_thread)
        else
            updated_list[#updated_list + 1] = item
        end
    end
    if not was_matched then
        return
    end
    local saved_cursor = vim.api.nvim_win_get_cursor(popup.win)
    paint_popup(popup, updated_list)
    if vim.api.nvim_win_is_valid(popup.win) then
        pcall(vim.api.nvim_win_set_height, popup.win, clamp_popup_height(#popup.layout.lines))
        local clamped_line = math.max(1, math.min(saved_cursor[1], #popup.layout.lines))
        pcall(vim.api.nvim_win_set_cursor, popup.win, { clamped_line, saved_cursor[2] })
    end
end

--- Opens the floating thread popup displaying `threads` at the cursor.
function M.open(session, threads)
    if not threads or #threads == 0 then
        return require("jpr").info("no review thread on this line")
    end
    M.close(session)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    local popup = { buf = buf, threads = threads }
    paint_popup(popup, threads)
    local width = math.min(84, math.max(52, vim.o.columns - 12))
    popup.win = vim.api.nvim_open_win(buf, true, {
        relative = "cursor",
        row = 1,
        col = 0,
        width = width,
        height = clamp_popup_height(#popup.layout.lines),
        style = "minimal",
        border = "rounded",
        title = " Review Thread ",
        title_pos = "center",
    })
    vim.api.nvim_set_option_value("wrap", true, { win = popup.win, scope = "local" })
    session.popup = popup
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            if session.popup == popup then
                session.popup = nil
            end
        end,
    })
    bind_popup_keys(session, buf)
end

return M
