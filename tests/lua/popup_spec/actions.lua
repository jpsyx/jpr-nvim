return function(context)
    local helpers = context.helpers
    local log = context.log
    local review = context.review
    local errors = context.errors
    local infos = context.infos

    local session = require("jpr.session")
    local main_window = require("jpr.views.main_window")
    local threads_view = require("jpr.views.threads")
    local render_threads = require("jpr.render.threads")
    local popup_module = require("jpr.comments.popup")

    local function win_lines(win)
        return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    end

    local win = main_window.find(review)
    main_window.edit(review, win, "README.md", 1)
    local buf = vim.api.nvim_win_get_buf(win)
    assert(vim.wait(3000, function()
        return #threads_view.threads_at_cursor(review, buf, 2) > 0
    end), "diff buffer loads thread on line 2")

    -- 1. Calling popup_current on a line with no threads does not open a window and notifies via jpr.info.
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    context.clear_messages()
    session.popup_current()
    assert(helpers.find_floating_win() == nil, "no popup opens on a threadless line")
    assert(#infos == 1 and infos[1]:find("no review thread", 1, true), vim.inspect(infos))

    -- 2. Pressing gt on line 2 opens a floating window with messages, footer, and expected buffer options.
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    helpers.press_key("gt")
    local popup_win = helpers.find_floating_win()
    assert(popup_win ~= nil and vim.api.nvim_win_is_valid(popup_win), "gt opens floating popup")
    local popup_buf = vim.api.nvim_win_get_buf(popup_win)
    local window_config = vim.api.nvim_win_get_config(popup_win)
    assert(window_config.relative ~= "", "popup window must be floating: " .. vim.inspect(window_config))
    assert(vim.bo[popup_buf].buftype == "nofile", "popup buftype is nofile")
    assert(vim.bo[popup_buf].bufhidden == "wipe", "popup bufhidden is wipe")
    assert(vim.bo[popup_buf].filetype == "markdown", "popup filetype is markdown")
    local initial_text = table.concat(win_lines(popup_win), "\n")
    assert(initial_text:find("Thread (Open)", 1, true) ~= nil, initial_text)
    assert(initial_text:find("@alice", 1, true) ~= nil, initial_text)
    assert(initial_text:find("nit: rename this", 1, true) ~= nil, initial_text)
    assert(initial_text:find("[r]eply  [e]dit  [d]elete  [R]esolve  [+]react  [X]retry  [q]uit", 1, true) ~= nil, initial_text)

    -- 3. Pressing R resolves and auto-closes popup; pressing R on a resolved thread unresolves and keeps popup open.
    local resolve_before = helpers.count_requests(log, '"method":"setResolved"')
    helpers.press_key("R")
    assert(vim.wait(3000, function()
        return helpers.count_requests(log, '"method":"setResolved"', '"resolved":true') == resolve_before + 1
            and not vim.api.nvim_win_is_valid(popup_win)
    end), "R sends setResolved(true) and auto-closes popup")

    popup_module.open(review, {
        {
            threadId = "T1",
            displayLine = 2,
            kind = "published",
            state = "resolved",
            outdated = false,
            messageCount = 1,
            firstAuthor = "alice",
            snippet = "nit: rename this",
            messages = {
                {
                    id = "M1",
                    author = "alice",
                    body = "nit: rename this",
                    created = "2026-11-20T00:00:00Z",
                    updated = "2026-11-20T00:00:00Z",
                    sync = "published",
                    viewerDidAuthor = false,
                    reactions = {},
                },
            },
        },
    })
    popup_win = helpers.find_floating_win()
    popup_buf = vim.api.nvim_win_get_buf(popup_win)
    assert(table.concat(win_lines(popup_win), "\n"):find("Thread (Resolved)", 1, true) ~= nil, "resolved popup opens")

    helpers.press_key("R")
    assert(vim.wait(3000, function()
        return helpers.count_requests(log, '"method":"setResolved"', '"resolved":false') >= 1
            and vim.api.nvim_win_is_valid(popup_win)
            and table.concat(win_lines(popup_win), "\n"):find("Thread (Open)", 1, true) ~= nil
    end), "R on resolved thread sends setResolved(false), keeps popup open, and refreshes")

    -- 4. Pressing + opens vim.ui.select with REACTION_ORDER and sends toggleReaction, refreshing reaction pill.
    local original_select = vim.ui.select
    local select_items, select_opts
    vim.ui.select = function(items, opts, on_choice)
        select_items = items
        select_opts = opts
        on_choice("THUMBS_UP")
    end
    local react_before = helpers.count_requests(log, '"method":"toggleReaction"')
    helpers.press_key("+")
    vim.ui.select = original_select
    assert(vim.deep_equal(select_items, render_threads.REACTION_ORDER), "select uses REACTION_ORDER")
    assert(select_opts and select_opts.format_item("THUMBS_UP"):find("THUMBS_UP", 1, true) ~= nil, "format_item includes name")
    assert(vim.wait(3000, function()
        return helpers.count_requests(log, '"method":"toggleReaction"', '"messageId":"M1"', '"content":"THUMBS_UP"') == react_before + 1
            and table.concat(win_lines(popup_win), "\n"):find(render_threads.REACTION_EMOJI.THUMBS_UP .. " 1*", 1, true) ~= nil
    end), "toggleReaction refreshes reaction pill")

    -- 5. Pressing d or e on a viewerDidAuthor == false message reports jpr.error without RPC or closing popup.
    context.clear_messages()
    local delete_before = helpers.count_requests(log, '"method":"deleteMessage"')
    helpers.press_key("d")
    assert(#errors == 1 and errors[1]:find("own comments", 1, true), vim.inspect(errors))
    assert(vim.api.nvim_win_is_valid(popup_win), "popup stays open on forbidden delete")
    assert(helpers.count_requests(log, '"method":"deleteMessage"') == delete_before, "no deleteMessage RPC on forbidden delete")

    context.clear_messages()
    helpers.press_key("e")
    assert(#errors == 1 and errors[1]:find("own comments", 1, true), vim.inspect(errors))
    assert(vim.api.nvim_win_is_valid(popup_win), "popup stays open on forbidden edit")

    -- 6. Pressing X on a non-failed message notifies jpr.info without calling retryMessage.
    context.clear_messages()
    local retry_before = helpers.count_requests(log, '"method":"retryMessage"')
    helpers.press_key("X")
    assert(#infos == 1 and infos[1]:find("not in a failed state", 1, true), vim.inspect(infos))
    assert(helpers.count_requests(log, '"method":"retryMessage"') == retry_before, "no retryMessage RPC for non-failed message")
    assert(vim.api.nvim_win_is_valid(popup_win), "popup stays open on non-failed X")

    -- 7. Pressing q and <Esc> close the floating window and wipe its buffer.
    helpers.press_key("q")
    assert(not vim.api.nvim_win_is_valid(popup_win), "q closes floating window")
    assert(not vim.api.nvim_buf_is_valid(popup_buf), "q wipes popup buffer")

    session.popup_current()
    local second_popup_win = helpers.find_floating_win()
    assert(second_popup_win ~= nil and vim.api.nvim_win_is_valid(second_popup_win), "popup reopens")
    helpers.press_key("<Esc>")
    assert(not vim.api.nvim_win_is_valid(second_popup_win), "<Esc> closes floating window")

    -- 8. Multi-thread popup + cursor targeting + height/cursor clamping on shrink.
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
            snippet = "first message",
            messages = {
                {
                    id = "M_1A",
                    author = "alice",
                    body = "first message",
                    created = "2026-11-20T00:00:00Z",
                    updated = "2026-11-20T00:00:00Z",
                    sync = "published",
                    viewerDidAuthor = false,
                    reactions = {},
                },
                {
                    id = "M_1B",
                    author = "pablo",
                    body = "second message",
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

    local original_request = review.client.request
    review.client.request = function(client_self, method, params, callback)
        if method == "fileDiff" then
            local response_threads = vim.deepcopy(multi_threads)
            vim.schedule(function()
                callback(nil, {
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
        return original_request(client_self, method, params, callback)
    end

    threads_view.draw_on_buffer(review, buf, multi_threads)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    session.popup_current()
    local multi_win = helpers.find_floating_win()
    assert(multi_win ~= nil and vim.api.nvim_win_is_valid(multi_win), "multi-thread popup opens")

    local line_1b = helpers.find_line_number(win_lines(multi_win), "second message")
    vim.api.nvim_win_set_cursor(multi_win, { line_1b, 0 })
    vim.ui.select = function(_, _, on_choice)
        on_choice("HEART")
    end
    local react_1b_before = helpers.count_requests(log, '"method":"toggleReaction"', '"messageId":"M_1B"')
    helpers.press_key("+")
    vim.ui.select = original_select
    assert(vim.wait(3000, function()
        return helpers.count_requests(log, '"method":"toggleReaction"', '"messageId":"M_1B"', '"content":"HEART"') == react_1b_before + 1
    end), "+ targets M_1B under popup cursor")

    local lines_before_shrink = #win_lines(multi_win)
    vim.api.nvim_win_set_cursor(multi_win, { lines_before_shrink, 0 })
    popup_module.refresh_from_thread(review, {
        id = "T_TWO",
        state = "open",
        messages = {
            {
                id = "M_2A",
                author = "pablo",
                body = "short failed body",
                created = "2026-11-20T00:02:00Z",
                updated = "2026-11-20T00:02:00Z",
                sync = "failed",
                viewerDidAuthor = true,
                reactions = {},
            },
        },
    })
    assert(vim.api.nvim_win_is_valid(multi_win), "popup window stays valid after shrink")
    local lines_after_shrink = #win_lines(multi_win)
    assert(lines_after_shrink < lines_before_shrink, "popup line count shrank")
    assert(vim.api.nvim_win_get_height(multi_win) == math.min(22, math.max(6, lines_after_shrink)), "popup height clamped on shrink")
    assert(vim.api.nvim_win_get_cursor(multi_win)[1] <= lines_after_shrink, "popup cursor clamped on shrink")

    local line_2a = helpers.find_line_number(win_lines(multi_win), "short failed body")
    vim.api.nvim_win_set_cursor(multi_win, { line_2a, 0 })
    local resolve_t2_before = helpers.count_requests(log, '"method":"setResolved"', '"threadId":"T_TWO"')
    helpers.press_key("R")
    assert(vim.wait(3000, function()
        return helpers.count_requests(log, '"method":"setResolved"', '"threadId":"T_TWO"', '"resolved":true') == resolve_t2_before + 1
            and not vim.api.nvim_win_is_valid(multi_win)
    end), "R targets T_TWO under popup cursor and closes popup")

    -- 9. Pressing X on a sync == "failed" message sends retryMessage and closes popup.
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    session.popup_current()
    multi_win = helpers.find_floating_win()
    local failed_line = helpers.find_line_number(win_lines(multi_win), "line 1")
    vim.api.nvim_win_set_cursor(multi_win, { failed_line, 0 })
    local retry_m2a_before = helpers.count_requests(log, '"method":"retryMessage"', '"messageId":"M_2A"')
    helpers.press_key("X")
    assert(vim.wait(3000, function()
        return helpers.count_requests(log, '"method":"retryMessage"', '"messageId":"M_2A"') == retry_m2a_before + 1
            and not vim.api.nvim_win_is_valid(multi_win)
    end), "X on failed message sends retryMessage and closes popup")

    -- 10. Pressing d on viewerDidAuthor == true: cancel keeps open, confirm sends deleteMessage and closes.
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    session.popup_current()
    local delete_popup_win = helpers.find_floating_win()
    vim.api.nvim_win_set_cursor(delete_popup_win, { helpers.find_line_number(win_lines(delete_popup_win), "second message"), 0 })
    local original_confirm = vim.fn.confirm
    local confirm_prompt
    vim.fn.confirm = function(prompt)
        confirm_prompt = prompt
        return 2
    end
    local deletes_before_confirm = helpers.count_requests(log, '"method":"deleteMessage"')
    helpers.press_key("d")
    assert(confirm_prompt and confirm_prompt:find("Delete", 1, true) ~= nil, "confirm prompt shown")
    assert(helpers.count_requests(log, '"method":"deleteMessage"') == deletes_before_confirm, "cancelled confirm does not send deleteMessage")
    assert(vim.api.nvim_win_is_valid(delete_popup_win), "cancelled confirm keeps popup open")

    vim.fn.confirm = function()
        return 1
    end
    helpers.press_key("d")
    vim.fn.confirm = original_confirm
    assert(vim.wait(3000, function()
        return helpers.count_requests(log, '"method":"deleteMessage"', '"messageId":"M_1B"') == 1
            and not vim.api.nvim_win_is_valid(delete_popup_win)
    end), "confirmed d sends deleteMessage for M_1B and closes popup")

    -- 11. Pressing r and e (on viewerDidAuthor == true) close popup and open real compose windows that submit reply / editMessage.
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    session.popup_current()
    local reply_popup_win = helpers.find_floating_win()
    vim.api.nvim_win_set_cursor(reply_popup_win, { helpers.find_line_number(win_lines(reply_popup_win), "first message"), 0 })
    local replies_before = #helpers.read_requests(log, "reply")
    helpers.press_key("r")
    assert(not vim.api.nvim_win_is_valid(reply_popup_win), "r closes popup window")
    local compose_reply_win = helpers.find_floating_win("GitHub")
    assert(compose_reply_win ~= nil and helpers.win_title(compose_reply_win):find("Reply", 1, true) ~= nil, "r opens Reply compose")
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(compose_reply_win), 0, -1, false, { "Reply from popup" })
    helpers.press_key("<C-s>")
    assert(vim.wait(3000, function()
        return #helpers.read_requests(log, "reply") == replies_before + 1
    end), "reply submitted from popup compose")
    assert(helpers.read_requests(log, "reply")[replies_before + 1].params.threadId == "T_ONE")

    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    session.popup_current()
    local edit_popup_win = helpers.find_floating_win()
    vim.api.nvim_win_set_cursor(edit_popup_win, { helpers.find_line_number(win_lines(edit_popup_win), "second message"), 0 })
    local edits_before = #helpers.read_requests(log, "editMessage")
    helpers.press_key("e")
    assert(not vim.api.nvim_win_is_valid(edit_popup_win), "e closes popup window")
    local compose_edit_win = helpers.find_floating_win("GitHub")
    assert(compose_edit_win ~= nil and helpers.win_title(compose_edit_win):find("[Edit GitHub comment]", 1, true) ~= nil, "e opens Edit compose")
    assert(table.concat(win_lines(compose_edit_win), "\n") == "second message", "edit compose pre-filled with message body")
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(compose_edit_win), 0, -1, false, { "Edited from popup" })
    helpers.press_key("<C-s>")
    assert(vim.wait(3000, function()
        return #helpers.read_requests(log, "editMessage") == edits_before + 1
    end), "editMessage submitted from popup compose")
    assert(helpers.read_requests(log, "editMessage")[edits_before + 1].params.messageId == "M_1B")

    -- 12. Mouse clicks in thread popup: select message, click footer actions preserving target, click outside closes.
    local original_getmousepos = vim.fn.getmousepos
    local is_popup_mouse_ok, popup_mouse_error = pcall(function()
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { 3, 0 })
        session.popup_current()
        local popup_win = helpers.find_floating_win()
        assert(popup_win ~= nil and vim.api.nvim_win_is_valid(popup_win), "popup opens for mouse test")
        local popup_lines = win_lines(popup_win)
        local line_t2 = helpers.find_line_number(popup_lines, "line 1")
        assert(line_t2 ~= nil, "found T_TWO message line")

        -- Clicking message line selects that message.
        vim.fn.getmousepos = function() return { winid = popup_win, line = line_t2, column = 4 } end
        helpers.press_key("<LeftMouse>")
        assert(vim.api.nvim_win_get_cursor(popup_win)[1] == line_t2, "clicking message line moves cursor to T_TWO")

        -- Clicking [R]esolve in footer resolves T_TWO (preserving previously selected message).
        local footer_line = #popup_lines
        local resolve_col = popup_lines[footer_line]:find("[R]esolve", 1, true)
        assert(resolve_col ~= nil, "found [R]esolve token in popup footer")
        local resolve_before = helpers.count_requests(log, '"method":"setResolved"', '"threadId":"T_TWO"')
        vim.fn.getmousepos = function() return { winid = popup_win, line = footer_line, column = resolve_col + 2 } end
        helpers.press_key("<LeftMouse>")
        assert(vim.wait(3000, function()
            return helpers.count_requests(log, '"method":"setResolved"', '"threadId":"T_TWO"') == resolve_before + 1
        end), "clicking [R]esolve in popup footer targets previously selected T_TWO")

        -- Clicking [q]uit in footer closes popup.
        popup_lines = win_lines(popup_win)
        local quit_col = popup_lines[#popup_lines]:find("[q]uit", 1, true)
        vim.fn.getmousepos = function() return { winid = popup_win, line = #popup_lines, column = quit_col + 1 } end
        helpers.press_key("<LeftMouse>")
        assert(not vim.api.nvim_win_is_valid(popup_win), "clicking [q]uit in popup footer closes popup")

        -- Clicking outside popup closes it.
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { 3, 0 })
        session.popup_current()
        local outside_popup_win = helpers.find_floating_win()
        vim.fn.getmousepos = function() return { winid = win, line = 1, column = 1 } end
        helpers.press_key("<LeftMouse>")
        assert(not vim.api.nvim_win_is_valid(outside_popup_win), "clicking outside popup closes it")
    end)
    vim.fn.getmousepos = original_getmousepos
    assert(is_popup_mouse_ok, tostring(popup_mouse_error))

    review.client.request = original_request
end
