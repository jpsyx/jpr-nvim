-- Comment mutation actions, mouse footer dispatch, and keymaps for the PR
-- conversation buffer.
local mouse = require("jpr.mouse")
local render = require("jpr.render.threads")

local M = {}

local CONVERSATION_FOOTER_SPECS = {
    { token = "[c]omment", action = "comment" },
    { token = "[r]eply", action = "reply" },
    { token = "[e]dit", action = "edit" },
    { token = "[d]elete", action = "delete" },
    { token = "[p]romote", action = "promote" },
    { token = "[s]end", action = "send" },
    { token = "[+]react", action = "react" },
    { token = "[X]retry", action = "retry" },
    { token = "[q]uit", action = "close" },
}

local function current_entry(session)
    local state = session and session.conversation
    if not state or not state.layout or not state.buf then
        return nil
    end
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) ~= state.buf then
        return nil
    end
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
    if cursor_line < (state.layout.conversation_start_line or 1) then
        return nil
    end
    return render.find_message_at_line(state.layout, cursor_line), state
end

local function open_edit_comment(session)
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
    require("jpr.comments.compose").open_edit(session, entry.message, entry.thread)
end

local function reply_to_comment(session)
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local entry = current_entry(session)
    if not entry then
        return
    end
    if not render.is_local_thread(entry.thread) then
        return require("jpr").info("only local threads support replies here; press c to comment")
    end
    require("jpr.comments.compose").open_reply(session, entry.thread)
end

local function promote_comment_thread(session)
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
    require("jpr.comments.compose").open_promote(session, entry.thread)
end

local function send_comment_thread(session)
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
    require("jpr.agent").send(session, entry.thread_id)
end

local function delete_comment(session)
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local entry, state = current_entry(session)
    if not entry then
        return
    end
    if not render.is_local_thread(entry.thread) and not entry.message.viewerDidAuthor then
        return require("jpr").error("you can only delete your own comments")
    end
    if vim.fn.confirm("Delete this comment?", "&Yes\n&No", 2) ~= 1 or session.closing or session.conversation ~= state then
        return
    end
    require("jpr.session").request(session, "deleteMessage", { messageId = entry.message_id }, function() end)
end

local function react_to_comment(session)
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local entry, state = current_entry(session)
    if not entry then
        return
    end
    if render.is_local_thread(entry.thread) then
        return require("jpr").info("reactions apply only to GitHub comments")
    end
    require("jpr.comments.popup").pick_reaction(function(choice)
        if session.closing or session.conversation ~= state then
            return
        end
        require("jpr.session").request(session, "toggleReaction", {
            messageId = entry.message_id,
            content = choice,
        }, function() end)
    end)
end

local function retry_comment(session)
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local entry = current_entry(session)
    if not entry or entry.message.sync ~= "failed" then
        return require("jpr").info("this message is not in a failed state")
    end
    require("jpr.session").request(session, "retryMessage", { messageId = entry.message_id }, function() end)
end

local function build_footer_handlers(conversation_mod)
    return {
        comment = function(session)
            require("jpr.comments.compose").open_new(session, { kind = "pr", side = "RIGHT" })
        end,
        reply = reply_to_comment,
        edit = open_edit_comment,
        delete = delete_comment,
        promote = promote_comment_thread,
        send = send_comment_thread,
        react = react_to_comment,
        retry = retry_comment,
        close = function(session)
            conversation_mod.close(session)
        end,
    }
end

local function handle_conversation_click(conversation_mod, session)
    local state = session and session.conversation
    local click = mouse.get_click()
    if not state or not click then
        return
    end
    local is_in_conversation = click.winid ~= nil
        and vim.api.nvim_win_is_valid(click.winid)
        and vim.api.nvim_win_get_buf(click.winid) == state.buf
        and type(click.line) == "number"
        and click.line >= 1
    if not is_in_conversation then
        return mouse.passthrough("<LeftMouse>")
    end
    local lines = state.layout and state.layout.lines or {}
    if click.line == #lines then
        local action = mouse.hit_test_footer_line(lines, CONVERSATION_FOOTER_SPECS, click)
        local handler = action and build_footer_handlers(conversation_mod)[action]
        if handler then
            handler(session)
        end
        return
    end
    mouse.set_cursor_from_click(click.winid, click)
end

--- Binds comment, mouse, and session keymaps onto the conversation buffer `buf`.
function M.bind_keys(conversation_mod, session, buf)
    local map = function(lhs, handler, desc)
        vim.keymap.set("n", lhs, handler, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
    map("c", function()
        require("jpr.comments.compose").open_new(session, { kind = "pr", side = "RIGHT" })
    end, "Add PR conversation comment")
    map("r", function() reply_to_comment(session) end, "Reply to local PR thread")
    map("e", function() open_edit_comment(session) end, "Edit own PR comment")
    map("d", function() delete_comment(session) end, "Delete PR comment")
    map("p", function() promote_comment_thread(session) end, "Promote local PR thread to GitHub")
    map("s", function() send_comment_thread(session) end, "Send local PR thread to agent")
    map("+", function() react_to_comment(session) end, "Toggle reaction on PR comment")
    map("X", function() retry_comment(session) end, "Retry failed PR comment")
    map("q", function() conversation_mod.close(session) end, "Close PR conversation")
    map("?", function() require("jpr.views.cheatsheet").open() end, "Show Jpr keyboard shortcuts")
    map("<LeftMouse>", function() handle_conversation_click(conversation_mod, session) end, "Select comment or click conversation footer action")
    local jpr = require("jpr")
    jpr.bind_session_keys(buf)
    local full_diff_key = jpr.config.keys and jpr.config.keys.full_diff
    if type(full_diff_key) == "string" and full_diff_key ~= "" then
        vim.keymap.set("n", full_diff_key, "<Plug>(jpr-full-diff)", { buffer = buf, remap = true, silent = true, nowait = true, desc = "Switch to the full branch diff view" })
    end
end

return M
