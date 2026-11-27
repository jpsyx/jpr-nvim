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

end
