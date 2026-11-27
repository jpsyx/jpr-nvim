-- Comment mutation actions, mouse footer dispatch, and keymaps for the floating
-- review thread popup.
local mouse = require("jpr.mouse")
local render = require("jpr.render.threads")

local M = {}

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

local function current_entry(session)
    local popup = session.popup
    if not popup or not popup.win or not vim.api.nvim_win_is_valid(popup.win) then
        return nil
    end
    local cursor_line = vim.api.nvim_win_get_cursor(popup.win)[1]
    return render.find_message_at_line(popup.layout, cursor_line), popup
end

local function toggle_popup_reaction(popup_mod, session)
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
    popup_mod.pick_reaction(function(choice)
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
                popup_mod.refresh_from_thread(session, result.thread)
            end
        end)
    end)
end

local function toggle_resolved(popup_mod, session)
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
        if next_resolved then
            return popup_mod.close(session)
        end
        if result and result.thread then
            popup_mod.refresh_from_thread(session, result.thread)
        end
    end)
end

local function delete_current_message(popup_mod, session)
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
        popup_mod.close(session)
    end)
end

local function retry_current_message(popup_mod, session)
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
        popup_mod.close(session)
    end)
end

local function open_reply(popup_mod, session)
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local entry = current_entry(session)
    if entry then
        popup_mod.close(session)
        require("jpr.comments.compose").open_reply(session, entry.thread)
    end
end

local function open_edit(popup_mod, session)
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
    popup_mod.close(session)
    require("jpr.comments.compose").open_edit(session, entry.message, entry.thread)
end

local function promote_current_thread(popup_mod, session)
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
    popup_mod.close(session)
    require("jpr.comments.compose").open_promote(session, entry.thread)
end

local function send_current_thread(popup_mod, session)
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
    popup_mod.close(session)
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
    close = function(popup_mod, session)
        popup_mod.close(session)
    end,
}

local function handle_popup_click(popup_mod, session)
    local popup = session and session.popup
    local click = mouse.get_click()
    if not popup or not click then
        return
    end
    if not mouse.is_click_in_window(click, popup.win) then
        return popup_mod.close(session)
    end
    local lines = popup.layout and popup.layout.lines or {}
    if click.line == #lines then
        local action = mouse.hit_test_footer_line(lines, POPUP_FOOTER_SPECS, click)
        local handler = action and POPUP_FOOTER_HANDLERS[action]
        if handler then
            handler(popup_mod, session)
        end
        return
    end
    mouse.set_cursor_from_click(popup.win, click)
end

--- Binds thread-action and mouse keymaps onto the popup buffer `buf`.
function M.bind_popup_keys(popup_mod, session, buf)
    local map = function(lhs, handler, desc)
        vim.keymap.set("n", lhs, handler, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
    map("q", function() popup_mod.close(session) end, "Close thread popup")
    map("<Esc>", function() popup_mod.close(session) end, "Close thread popup")
    map("R", function() toggle_resolved(popup_mod, session) end, "Resolve or unresolve thread")
    map("+", function() toggle_popup_reaction(popup_mod, session) end, "Toggle reaction on message")
    map("d", function() delete_current_message(popup_mod, session) end, "Delete own message")
    map("X", function() retry_current_message(popup_mod, session) end, "Retry failed message")
    map("r", function() open_reply(popup_mod, session) end, "Reply to thread")
    map("e", function() open_edit(popup_mod, session) end, "Edit own message")
    map("p", function() promote_current_thread(popup_mod, session) end, "Promote local thread to GitHub")
    map("s", function() send_current_thread(popup_mod, session) end, "Send local thread to agent")
    map("<LeftMouse>", function() handle_popup_click(popup_mod, session) end, "Select message or click popup footer action")
end

return M
