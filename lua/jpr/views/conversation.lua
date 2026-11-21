-- PR conversation view (`:Jpr conversation`): lists top-level PR issue
-- comments (`anchor.kind == "pr"`) in the main window beside the panel.
local diff_view = require("jpr.views.diff")
local main_window = require("jpr.views.main_window")
local render = require("jpr.render.threads")
local stream_view = require("jpr.views.stream")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-conversation")

local function filter_pr_threads(threads)
    return vim.tbl_filter(function(thread)
        return thread.anchor ~= nil and thread.anchor.kind == "pr"
    end, threads or {})
end

local function count_messages(threads)
    local num_messages = 0
    for _, thread in ipairs(threads) do
        num_messages = num_messages + #(thread.messages or {})
    end
    return num_messages
end

local function create_layout_from_threads(session, threads)
    local pr_threads = filter_pr_threads(threads)
    local layout = render.create_message_layout()
    layout.add(("#%d PR Conversation (%d comments)"):format(session.number, count_messages(pr_threads)), "JprTitle")
    layout.add("")
    if #pr_threads == 0 then
        layout.add("  (no PR conversation comments yet; press c to post one)", "JprMuted")
        layout.add("")
    else
        for _, thread in ipairs(pr_threads) do
            for _, message in ipairs(thread.messages or {}) do
                render.append_formatted_message(layout, thread, message)
                layout.add("")
            end
        end
    end
    layout.add("[c]omment  [e]dit  [d]elete  [+]react  [X]retry  [q]uit", "JprMuted")
    return layout
end

local function paint_buffer(buf, layout)
    local cursors = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        cursors[win] = vim.api.nvim_win_get_cursor(win)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, layout.lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    for _, highlight in ipairs(layout.highlights) do
        vim.api.nvim_buf_set_extmark(buf, namespace, highlight.line, highlight.col_start, {
            end_col = highlight.col_end,
            hl_group = highlight.group,
            strict = false,
        })
    end
    for win, cursor in pairs(cursors) do
        local clamped_line = math.max(1, math.min(cursor[1], #layout.lines))
        pcall(vim.api.nvim_win_set_cursor, win, { clamped_line, cursor[2] })
    end
end

local function is_visible(session)
    local state = session and session.conversation
    return state ~= nil
        and state.buf ~= nil
        and vim.api.nvim_buf_is_valid(state.buf)
        and #vim.fn.win_findbuf(state.buf) > 0
end

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
    return render.find_message_at_line(state.layout, cursor_line), state
end

local function open_edit_comment(session)
    local entry = current_entry(session)
    if not entry then
        return
    end
    if not entry.message.viewerDidAuthor then
        return require("jpr").error("you can only edit your own comments")
    end
    require("jpr.comments.compose").open_edit(session, entry.message)
end

local function delete_comment(session)
    local entry, state = current_entry(session)
    if not entry then
        return
    end
    if not entry.message.viewerDidAuthor then
        return require("jpr").error("you can only delete your own comments")
    end
    if vim.fn.confirm("Delete this comment?", "&Yes\n&No", 2) ~= 1 or session.closing or session.conversation ~= state then
        return
    end
    require("jpr.session").request(session, "deleteMessage", { messageId = entry.message_id }, function() end)
end

local function react_to_comment(session)
    local entry, state = current_entry(session)
    if not entry then
        return
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
    local entry = current_entry(session)
    if not entry or entry.message.sync ~= "failed" then
        return require("jpr").info("this message is not in a failed state")
    end
    require("jpr.session").request(session, "retryMessage", { messageId = entry.message_id }, function() end)
end

local function bind_keys(session, buf)
    local map = function(lhs, handler, desc)
        vim.keymap.set("n", lhs, handler, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
    map("c", function()
        require("jpr.comments.compose").open_new(session, { kind = "pr", side = "RIGHT" })
    end, "Add PR conversation comment")
    map("e", function() open_edit_comment(session) end, "Edit own PR comment")
    map("d", function() delete_comment(session) end, "Delete own PR comment")
    map("+", function() react_to_comment(session) end, "Toggle reaction on PR comment")
    map("X", function() retry_comment(session) end, "Retry failed PR comment")
    map("q", function() M.close(session) end, "Close PR conversation")
end

local function get_or_create_state(session)
    local existing = session.conversation
    if existing and existing.buf and vim.api.nvim_buf_is_valid(existing.buf) then
        return existing
    end
    local buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, ("jpr://conversation/%d"):format(session.number))
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading PR conversation..." })
    vim.bo[buf].modifiable = false
    local state = { buf = buf, request_id = 0 }
    session.conversation = state
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            if session.conversation == state then
                session.conversation = nil
            end
        end,
    })
    bind_keys(session, buf)
    return state
end

local function fetch_and_draw(session, state)
    state.request_id = (state.request_id or 0) + 1
    local request_id = state.request_id
    local buf = state.buf
    require("jpr.session").request(session, "threads", nil, function(result)
        if session.closing or session.conversation ~= state or state.request_id ~= request_id then
            return
        end
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        local layout = create_layout_from_threads(session, (result and result.threads) or {})
        state.layout = layout
        paint_buffer(buf, layout)
    end)
end

--- Opens or focuses the PR conversation buffer (`jpr://conversation/<number>`)
--- in `session`'s main window beside the panel.
function M.show(session)
    if not session or session.closing then
        return
    end
    local state = get_or_create_state(session)
    local main_win = main_window.find(session)
    diff_view.clear(session, main_win)
    stream_view.close_left_window(session)
    vim.api.nvim_win_set_buf(main_win, state.buf)
    vim.api.nvim_set_option_value("wrap", true, { win = main_win, scope = "local" })
    vim.api.nvim_set_option_value("scrollbind", false, { win = main_win, scope = "local" })
    vim.api.nvim_set_option_value("cursorbind", false, { win = main_win, scope = "local" })
    vim.api.nvim_set_current_win(main_win)
    fetch_and_draw(session, state)
end

--- Updates the PR conversation buffer when it is currently visible.
function M.refresh(session)
    if not session or session.closing or not is_visible(session) then
        return
    end
    fetch_and_draw(session, session.conversation)
end

--- Closes and wipes `session`'s PR conversation buffer, if open.
function M.close(session)
    local state = session and session.conversation
    if not state then
        return
    end
    session.conversation = nil
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        main_window.release_windows(state.buf)
        pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
    end
end

return M
