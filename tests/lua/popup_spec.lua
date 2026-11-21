local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local view_mode = require("jpr.view_mode")
local threads_view = require("jpr.views.threads")
local stream_view = require("jpr.views.stream")
local render_threads = require("jpr.render.threads")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new", "tail" }, worktree .. "/README.md")

local function count_requests(...)
    local needles, count = { ... }, 0
    if vim.fn.filereadable(log) == 0 then
        return 0
    end
    for _, line in ipairs(vim.fn.readfile(log)) do
        local has_all = true
        for _, needle in ipairs(needles) do
            has_all = has_all and line:find(needle, 1, true) ~= nil
        end
        count = count + (has_all and 1 or 0)
    end
    return count
end

local function popup_lines(review)
    return vim.api.nvim_buf_get_lines(review.popup.buf, 0, -1, false)
end

local function press_key(lhs)
    local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    vim.api.nvim_feedkeys(keys, "xt", false)
end

-- 0. Calling popup_current without an active session notifies cleanly.
local errors, infos = {}, {}
local orig_error, orig_info = jpr.error, jpr.info
jpr.error = function(msg)
    errors[#errors + 1] = msg
end
jpr.info = function(msg)
    infos[#infos + 1] = msg
end

session.popup_current()
assert(#errors == 1 and errors[1]:find("no pull request", 1, true), vim.inspect(errors))
errors, infos = {}, {}

-- Start session and open README.md in diff window.
session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "the review syncs")

local win = main_window.find(review)
main_window.edit(review, win, "README.md", 1)
local buf = vim.api.nvim_win_get_buf(win)
assert(vim.wait(3000, function()
    return #(review.buf_threads and review.buf_threads[buf] or {}) > 0
end), "diff buffer loads thread on line 2")

-- 1. Calling popup_current on a line with no threads does not open a window and notifies via jpr.info.
vim.api.nvim_set_current_win(win)
vim.api.nvim_win_set_cursor(win, { 1, 0 })
infos = {}
session.popup_current()
assert(review.popup == nil, "no popup opens on a threadless line")
assert(#infos == 1 and infos[1]:find("no review thread", 1, true), vim.inspect(infos))

-- 2. Pressing gt on line 2 opens a floating window with messages, footer, and expected buffer options.
vim.api.nvim_win_set_cursor(win, { 2, 0 })
press_key("gt")
assert(review.popup ~= nil and vim.api.nvim_win_is_valid(review.popup.win), "gt opens floating popup")
local win_cfg = vim.api.nvim_win_get_config(review.popup.win)
assert(win_cfg.relative ~= "", "popup window must be floating: " .. vim.inspect(win_cfg))
assert(vim.bo[review.popup.buf].buftype == "nofile", "popup buftype is nofile")
assert(vim.bo[review.popup.buf].bufhidden == "wipe", "popup bufhidden is wipe")
assert(vim.bo[review.popup.buf].filetype == "markdown", "popup filetype is markdown")
local initial_text = table.concat(popup_lines(review), "\n")
assert(initial_text:find("Thread (Open)", 1, true) ~= nil, initial_text)
assert(initial_text:find("@alice", 1, true) ~= nil, initial_text)
assert(initial_text:find("nit: rename this", 1, true) ~= nil, initial_text)
assert(initial_text:find("[r]eply  [e]dit  [d]elete  [R]esolve  [+]react  [X]retry  [q]uit", 1, true) ~= nil, initial_text)

-- 3. Pressing R resolves then unresolves via fake_engine.sh and refreshes popup.
local resolve_before = count_requests('"method":"setResolved"')
press_key("R")
assert(vim.wait(3000, function()
    return count_requests('"method":"setResolved"', '"resolved":true') == resolve_before + 1
        and table.concat(popup_lines(review), "\n"):find("Thread (Resolved)", 1, true) ~= nil
end), "R sends setResolved(true) and refreshes popup: " .. table.concat(popup_lines(review), "\n"))

press_key("R")
assert(vim.wait(3000, function()
    return count_requests('"method":"setResolved"', '"resolved":false') >= 1
        and table.concat(popup_lines(review), "\n"):find("Thread (Open)", 1, true) ~= nil
end), "second R sends setResolved(false) and refreshes popup")

-- 4. Pressing + opens vim.ui.select with REACTION_ORDER and sends toggleReaction, refreshing reaction pill.
local orig_select = vim.ui.select
local select_items, select_opts
vim.ui.select = function(items, opts, on_choice)
    select_items = items
    select_opts = opts
    on_choice("THUMBS_UP")
end
local react_before = count_requests('"method":"toggleReaction"')
press_key("+")
vim.ui.select = orig_select
assert(vim.deep_equal(select_items, render_threads.REACTION_ORDER), "select uses REACTION_ORDER: " .. vim.inspect(select_items))
assert(select_opts and select_opts.format_item("THUMBS_UP"):find("THUMBS_UP", 1, true) ~= nil, "format_item includes name")
assert(vim.wait(3000, function()
    return count_requests('"method":"toggleReaction"', '"messageId":"M1"', '"content":"THUMBS_UP"') == react_before + 1
        and table.concat(popup_lines(review), "\n"):find(render_threads.REACTION_EMOJI.THUMBS_UP .. " 1*", 1, true) ~= nil
end), "toggleReaction refreshes reaction pill: " .. table.concat(popup_lines(review), "\n"))

-- 5. Pressing d or e on a viewerDidAuthor == false message reports jpr.error without RPC or closing popup.
errors = {}
local delete_before = count_requests('"method":"deleteMessage"')
press_key("d")
assert(#errors == 1 and errors[1]:find("own comments", 1, true), vim.inspect(errors))
assert(review.popup ~= nil and vim.api.nvim_win_is_valid(review.popup.win), "popup stays open on forbidden delete")
assert(count_requests('"method":"deleteMessage"') == delete_before, "no deleteMessage RPC on forbidden delete")

errors = {}
press_key("e")
assert(#errors == 1 and errors[1]:find("own comments", 1, true), vim.inspect(errors))
assert(review.popup ~= nil and vim.api.nvim_win_is_valid(review.popup.win), "popup stays open on forbidden edit")

-- 6. Pressing X on a non-failed message notifies jpr.info without calling retryMessage.
infos = {}
local retry_before = count_requests('"method":"retryMessage"')
press_key("X")
assert(#infos == 1 and infos[1]:find("not in a failed state", 1, true), vim.inspect(infos))
assert(count_requests('"method":"retryMessage"') == retry_before, "no retryMessage RPC for non-failed message")
assert(review.popup ~= nil and vim.api.nvim_win_is_valid(review.popup.win), "popup stays open on non-failed X")

-- 7. Pressing q and <Esc> close the floating window cleanly.
local first_popup_win = review.popup.win
local first_popup_buf = review.popup.buf
press_key("q")
assert(review.popup == nil, "q clears session.popup")
assert(not vim.api.nvim_win_is_valid(first_popup_win), "q closes floating window")
assert(not vim.api.nvim_buf_is_valid(first_popup_buf), "q wipes popup buffer")

session.popup_current()
assert(review.popup ~= nil and vim.api.nvim_win_is_valid(review.popup.win), "popup reopens")
local second_popup_win = review.popup.win
press_key("<Esc>")
assert(review.popup == nil, "<Esc> clears session.popup")
assert(not vim.api.nvim_win_is_valid(second_popup_win), "<Esc> closes floating window")

-- 8. Multi-thread popup + cursor targeting (find_message_at_line) + height/cursor clamping on shrink.
local long_body = table.concat({
    "line 1", "line 2", "line 3", "line 4", "line 5", "line 6",
    "line 7", "line 8", "line 9", "line 10", "line 11", "line 12",
}, "\n")
local multi_threads = {
    {
        threadId = "T_ONE",
        displayLine = 3,
        kind = "published",
        state = "open",
        outdated = false,
        messageCount = 2,
        firstAuthor = "alice",
        snippet = "first msg",
        messages = {
            {
                id = "M_1A",
                author = "alice",
                body = "first msg",
                created = "2026-11-20T00:00:00Z",
                updated = "2026-11-20T00:00:00Z",
                sync = "published",
                viewerDidAuthor = false,
                reactions = {},
            },
            {
                id = "M_1B",
                author = "pablo",
                body = "second msg",
                created = "2026-11-20T00:01:00Z",
                updated = "2026-11-20T00:01:00Z",
                sync = "published",
                viewerDidAuthor = true,
                reactions = {},
            },
        },
    },
    {
        threadId = "T_TWO",
        displayLine = 3,
        kind = "failed",
        state = "open",
        outdated = false,
        messageCount = 1,
        firstAuthor = "pablo",
        snippet = "line 1",
        messages = {
            {
                id = "M_2A",
                author = "pablo",
                body = long_body,
                created = "2026-11-20T00:02:00Z",
                updated = "2026-11-20T00:02:00Z",
                sync = "failed",
                syncError = "network glitch",
                viewerDidAuthor = true,
                reactions = {},
            },
        },
    },
}

local orig_request = review.client.request
review.client.request = function(client_self, method, params, cb)
    if method == "fileDiff" then
        local response_threads = vim.deepcopy(multi_threads)
        vim.schedule(function()
            cb(nil, {
                path = "README.md",
                binary = false,
                baseText = "hello\nold\n",
                added = {},
                removed = {},
                threads = response_threads,
            })
        end)
        return
    end
    return orig_request(client_self, method, params, cb)
end

threads_view.draw_on_buffer(review, buf, multi_threads)
vim.api.nvim_set_current_win(win)
vim.api.nvim_win_set_cursor(win, { 3, 0 })
session.popup_current()
assert(review.popup ~= nil and vim.api.nvim_win_is_valid(review.popup.win), "multi-thread popup opens")

-- Target M_1B with + and verify toggleReaction uses messageId = M_1B.
local range_1b = review.popup.layout.message_ranges[2]
vim.api.nvim_win_set_cursor(review.popup.win, { range_1b.first, 0 })
vim.ui.select = function(_, _, on_choice)
    on_choice("HEART")
end
local react_1b_before = count_requests('"method":"toggleReaction"', '"messageId":"M_1B"')
press_key("+")
vim.ui.select = orig_select
assert(vim.wait(3000, function()
    return count_requests('"method":"toggleReaction"', '"messageId":"M_1B"', '"content":"HEART"') == react_1b_before + 1
end), "+ targets M_1B under popup cursor")

-- Target T_TWO / M_2A with R and verify setResolved uses threadId = T_TWO.
local range_2a = review.popup.layout.message_ranges[3]
vim.api.nvim_win_set_cursor(review.popup.win, { range_2a.first + 1, 0 })
local resolve_t2_before = count_requests('"method":"setResolved"', '"threadId":"T_TWO"')
press_key("R")
assert(vim.wait(3000, function()
    return count_requests('"method":"setResolved"', '"threadId":"T_TWO"', '"resolved":true') == resolve_t2_before + 1
end), "R targets T_TWO under popup cursor")

-- Verify refresh_from_thread clamps height and cursor when line count shrinks.
local popup_mod = require("jpr.comments.popup")
local lines_before_shrink = #popup_lines(review)
vim.api.nvim_win_set_cursor(review.popup.win, { lines_before_shrink, 0 })
popup_mod.refresh_from_thread(review, {
    id = "T_TWO",
    state = "open",
    messages = {
        {
            id = "M_2A",
            author = "pablo",
            body = "short",
            created = "2026-11-20T00:02:00Z",
            updated = "2026-11-20T00:02:00Z",
            sync = "failed",
            viewerDidAuthor = true,
            reactions = {},
        },
    },
})
assert(vim.api.nvim_win_is_valid(review.popup.win), "popup.win stays valid after shrink")
local lines_after_shrink = #popup_lines(review)
assert(lines_after_shrink < lines_before_shrink, "popup line count shrank")
assert(vim.api.nvim_win_get_height(review.popup.win) == math.min(22, math.max(6, lines_after_shrink)),
    "popup height clamped on shrink")
assert(vim.api.nvim_win_get_cursor(review.popup.win)[1] <= lines_after_shrink, "popup cursor clamped on shrink")

-- 9. Pressing X on a sync == "failed" message sends retryMessage and closes popup.
local failed_range = review.popup.layout.message_ranges[3]
vim.api.nvim_win_set_cursor(review.popup.win, { failed_range.first, 0 })
local retry_m2a_before = count_requests('"method":"retryMessage"', '"messageId":"M_2A"')
press_key("X")
assert(vim.wait(3000, function()
    return count_requests('"method":"retryMessage"', '"messageId":"M_2A"') == retry_m2a_before + 1
        and review.popup == nil
end), "X on failed message sends retryMessage and closes popup")

-- 10. Pressing d on viewerDidAuthor == true: cancel keeps open, confirm sends deleteMessage and closes.
vim.api.nvim_set_current_win(win)
vim.api.nvim_win_set_cursor(win, { 3, 0 })
session.popup_current()
local own_range = review.popup.layout.message_ranges[2]
vim.api.nvim_win_set_cursor(review.popup.win, { own_range.first, 0 })
local orig_confirm = vim.fn.confirm
local confirm_prompt
vim.fn.confirm = function(prompt)
    confirm_prompt = prompt
    return 2
end
local del_before = count_requests('"method":"deleteMessage"')
press_key("d")
assert(confirm_prompt and confirm_prompt:find("Delete", 1, true) ~= nil, "confirm prompt shown")
assert(count_requests('"method":"deleteMessage"') == del_before, "cancelled confirm does not send deleteMessage")
assert(review.popup ~= nil and vim.api.nvim_win_is_valid(review.popup.win), "cancelled confirm keeps popup open")

vim.fn.confirm = function()
    return 1
end
press_key("d")
vim.fn.confirm = orig_confirm
assert(vim.wait(3000, function()
    return count_requests('"method":"deleteMessage"', '"messageId":"M_1B"') == 1
        and review.popup == nil
end), "confirmed d sends deleteMessage for M_1B and closes popup")

-- 11. Pressing r and e (on viewerDidAuthor == true) close popup and open compose.
local orig_compose = package.loaded["jpr.comments.compose"]
local compose_calls = {}
package.loaded["jpr.comments.compose"] = {
    open_reply = function(sess, thread)
        compose_calls[#compose_calls + 1] = { action = "reply", sess = sess, thread_id = thread.threadId }
    end,
    open_edit = function(sess, message)
        compose_calls[#compose_calls + 1] = { action = "edit", sess = sess, message_id = message.id }
    end,
}
vim.api.nvim_set_current_win(win)
vim.api.nvim_win_set_cursor(win, { 3, 0 })
session.popup_current()
vim.api.nvim_win_set_cursor(review.popup.win, { review.popup.layout.message_ranges[1].first, 0 })
press_key("r")
assert(review.popup == nil, "r closes popup")
assert(#compose_calls == 1 and compose_calls[1].action == "reply" and compose_calls[1].thread_id == "T_ONE",
    vim.inspect(compose_calls))

session.popup_current()
vim.api.nvim_win_set_cursor(review.popup.win, { review.popup.layout.message_ranges[2].first, 0 })
press_key("e")
assert(review.popup == nil, "e closes popup for own comment")
assert(#compose_calls == 2 and compose_calls[2].action == "edit" and compose_calls[2].message_id == "M_1B",
    vim.inspect(compose_calls))
package.loaded["jpr.comments.compose"] = orig_compose
review.client.request = orig_request

-- 12. Popup works from a stream buffer (views.stream.threads_at_cursor).
local stream_thread = {
    threadId = "T_STREAM",
    anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 },
    displayLine = 2,
    kind = "published",
    state = "open",
    firstAuthor = "carol",
    snippet = "stream comment body",
    messages = {
        {
            id = "M_STR",
            author = "carol",
            body = "stream comment body",
            created = "2026-11-20T03:00:00Z",
            updated = "2026-11-20T03:00:00Z",
            sync = "published",
            viewerDidAuthor = false,
            reactions = {},
        },
    },
}
stream_view.draw(review, {
    mode = "unified",
    rows = {
        { kind = "file", path = "README.md", additions = 1, deletions = 0, viewed = "UNVIEWED", folded = false },
        { kind = "hunk", path = "README.md", header = "@@ -1,1 +1,1 @@", target = 1 },
        { kind = "line", path = "README.md", right = { line = 2, text = "new", change = "added", words = {} }, target = 2, threads = { stream_thread } },
    },
}, { focus = true })
local stream_win = vim.fn.win_findbuf(review.stream.buffers.main)[1]
vim.api.nvim_set_current_win(stream_win)
vim.api.nvim_win_set_cursor(stream_win, { 3, 0 })
press_key("gt")
assert(review.popup ~= nil and vim.api.nvim_win_is_valid(review.popup.win), "gt opens popup from stream buffer")
local stream_popup_text = table.concat(popup_lines(review), "\n")
assert(stream_popup_text:find("stream comment body", 1, true) ~= nil, stream_popup_text)
press_key("q")
assert(review.popup == nil, "q closes stream popup")

-- 13. Direct window close clears session.popup via BufWipeout.
local popup_mod = require("jpr.comments.popup")
local stale_test_threads = {
    {
        threadId = "T_STALE",
        displayLine = 2,
        kind = "published",
        state = "open",
        outdated = true,
        messageCount = 1,
        firstAuthor = "pablo",
        snippet = "hello",
        messages = {
            {
                id = "M_STALE",
                author = "pablo",
                body = "hello",
                created = "2026-11-20T00:00:00Z",
                updated = "2026-11-20T00:00:00Z",
                sync = "published",
                viewerDidAuthor = true,
                reactions = {},
            },
        },
    },
}
popup_mod.open(review, vim.deepcopy(stale_test_threads))
assert(review.popup ~= nil and vim.api.nvim_win_is_valid(review.popup.win), "popup opens for direct close test")
local direct_win, direct_buf = review.popup.win, review.popup.buf
vim.api.nvim_win_close(direct_win, true)
assert(review.popup == nil, "direct nvim_win_close clears session.popup via BufWipeout")
assert(not vim.api.nvim_win_is_valid(direct_win), "direct close invalidates window")
assert(not vim.api.nvim_buf_is_valid(direct_buf), "direct close wipes buffer")

-- 14. refresh_from_thread clears outdated = true -> false and ignores unrelated thread IDs.
popup_mod.open(review, vim.deepcopy(stale_test_threads))
assert(table.concat(popup_lines(review), "\n"):find("Outdated", 1, true) ~= nil, "initial popup shows Outdated")
local tick_before_unrelated = vim.api.nvim_buf_get_changedtick(review.popup.buf)
vim.api.nvim_win_set_cursor(review.popup.win, { 2, 1 })
popup_mod.refresh_from_thread(review, {
    id = "T_UNRELATED",
    state = "resolved",
    outdated = false,
    messages = {},
})
assert(
    vim.api.nvim_buf_get_changedtick(review.popup.buf) == tick_before_unrelated,
    "unrelated thread does not touch popup buffer"
)
assert(
    vim.deep_equal(vim.api.nvim_win_get_cursor(review.popup.win), { 2, 1 }),
    "unrelated thread does not disturb cursor"
)

popup_mod.refresh_from_thread(review, {
    id = "T_STALE",
    state = "open",
    outdated = false,
    messages = vim.deepcopy(stale_test_threads[1].messages),
})
assert(review.popup.threads[1].outdated == false, "outdated = false clears true on refresh")
assert(
    table.concat(popup_lines(review), "\n"):find("Outdated", 1, true) == nil,
    "Outdated tag removed when outdated becomes false: " .. table.concat(popup_lines(review), "\n")
)
popup_mod.close(review)

-- 15. Async stale-popup guard across vim.ui.select, toggleReaction, setResolved, and deleteMessage.
local pending_callbacks = {}
local sent_methods = {}
review.client.request = function(_, method, params, cb)
    sent_methods[#sent_methods + 1] = method
    pending_callbacks[method] = cb
end

-- 15a. vim.ui.select completes after popup closed and reopened.
popup_mod.open(review, vim.deepcopy(stale_test_threads))
local captured_select_cb
vim.ui.select = function(_, _, on_choice)
    captured_select_cb = on_choice
end
press_key("+")
vim.ui.select = orig_select
assert(captured_select_cb ~= nil, "vim.ui.select callback captured")
popup_mod.close(review)
popup_mod.open(review, vim.deepcopy(stale_test_threads))
local popup_after_select_reopen = review.popup
local select_calls_before = #sent_methods
captured_select_cb("THUMBS_UP")
assert(#sent_methods == select_calls_before, "stale vim.ui.select callback does not send toggleReaction")
assert(review.popup == popup_after_select_reopen, "new popup stays intact after stale vim.ui.select")
popup_mod.close(review)

-- 15b. toggleReaction RPC completes after popup closed and reopened.
popup_mod.open(review, vim.deepcopy(stale_test_threads))
vim.ui.select = function(_, _, on_choice)
    on_choice("THUMBS_UP")
end
pending_callbacks.toggleReaction = nil
press_key("+")
vim.ui.select = orig_select
assert(pending_callbacks.toggleReaction ~= nil, "toggleReaction RPC in flight")
popup_mod.close(review)
popup_mod.open(review, vim.deepcopy(stale_test_threads))
local popup_after_react_reopen = review.popup
local tick_react_reopen = vim.api.nvim_buf_get_changedtick(popup_after_react_reopen.buf)
pending_callbacks.toggleReaction(nil, {
    thread = {
        id = "T_STALE",
        state = "resolved",
        outdated = false,
        messages = vim.deepcopy(stale_test_threads[1].messages),
    },
})
assert(review.popup == popup_after_react_reopen, "new popup stays active after stale toggleReaction")
assert(
    vim.api.nvim_buf_get_changedtick(popup_after_react_reopen.buf) == tick_react_reopen,
    "stale toggleReaction does not refresh newly opened popup"
)
popup_mod.close(review)

-- 15c. setResolved RPC completes after popup closed and reopened.
popup_mod.open(review, vim.deepcopy(stale_test_threads))
pending_callbacks.setResolved = nil
press_key("R")
assert(pending_callbacks.setResolved ~= nil, "setResolved RPC in flight")
popup_mod.close(review)
popup_mod.open(review, vim.deepcopy(stale_test_threads))
local popup_after_resolve_reopen = review.popup
local tick_resolve_reopen = vim.api.nvim_buf_get_changedtick(popup_after_resolve_reopen.buf)
pending_callbacks.setResolved(nil, {
    thread = {
        id = "T_STALE",
        state = "resolved",
        outdated = false,
        messages = vim.deepcopy(stale_test_threads[1].messages),
    },
})
assert(review.popup == popup_after_resolve_reopen, "new popup stays active after stale setResolved")
assert(
    vim.api.nvim_buf_get_changedtick(popup_after_resolve_reopen.buf) == tick_resolve_reopen,
    "stale setResolved does not refresh newly opened popup"
)
popup_mod.close(review)

-- 15d. deleteMessage RPC completes after popup closed and reopened.
popup_mod.open(review, vim.deepcopy(stale_test_threads))
vim.fn.confirm = function()
    return 1
end
pending_callbacks.deleteMessage = nil
press_key("d")
vim.fn.confirm = orig_confirm
assert(pending_callbacks.deleteMessage ~= nil, "deleteMessage RPC in flight")
popup_mod.close(review)
popup_mod.open(review, vim.deepcopy(stale_test_threads))
local popup_after_delete_reopen = review.popup
pending_callbacks.deleteMessage(nil, {})
assert(
    review.popup == popup_after_delete_reopen and vim.api.nvim_win_is_valid(popup_after_delete_reopen.win),
    "stale deleteMessage does not close newly opened popup"
)
popup_mod.close(review)
review.client.request = orig_request

jpr.error = orig_error
jpr.info = orig_info
session.close_current()

print("popup_spec: ok")
