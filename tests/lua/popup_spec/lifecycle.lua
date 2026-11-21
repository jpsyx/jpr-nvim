return function(context)
    local helpers = context.helpers
    local review = context.review

    local stream_view = require("jpr.views.stream")
    local popup_module = require("jpr.comments.popup")

    local function win_lines(win)
        return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    end

    -- 1. Popup works from a stream buffer (views.stream.threads_at_cursor).
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
    helpers.press_key("gt")
    local stream_popup_win = helpers.find_floating_win()
    assert(stream_popup_win ~= nil and vim.api.nvim_win_is_valid(stream_popup_win), "gt opens popup from stream buffer")
    local stream_popup_text = table.concat(win_lines(stream_popup_win), "\n")
    assert(stream_popup_text:find("stream comment body", 1, true) ~= nil, stream_popup_text)
    helpers.press_key("q")
    assert(not vim.api.nvim_win_is_valid(stream_popup_win), "q closes stream popup")

    -- 2. Direct window close wipes popup buffer cleanly via BufWipeout.
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
    popup_module.open(review, vim.deepcopy(stale_test_threads))
    local direct_win = helpers.find_floating_win()
    assert(direct_win ~= nil and vim.api.nvim_win_is_valid(direct_win), "popup opens for direct close test")
    local direct_buf = vim.api.nvim_win_get_buf(direct_win)
    vim.api.nvim_win_close(direct_win, true)
    assert(not vim.api.nvim_win_is_valid(direct_win), "direct close invalidates window")
    assert(not vim.api.nvim_buf_is_valid(direct_buf), "direct close wipes buffer")

    -- 3. refresh_from_thread clears Outdated badge when outdated becomes false and ignores unrelated thread IDs.
    popup_module.open(review, vim.deepcopy(stale_test_threads))
    local refresh_win = helpers.find_floating_win()
    local refresh_buf = vim.api.nvim_win_get_buf(refresh_win)
    assert(table.concat(win_lines(refresh_win), "\n"):find("Outdated", 1, true) ~= nil, "initial popup shows Outdated")
    local tick_before_unrelated = vim.api.nvim_buf_get_changedtick(refresh_buf)
    vim.api.nvim_win_set_cursor(refresh_win, { 2, 1 })
    popup_module.refresh_from_thread(review, {
        id = "T_UNRELATED",
        state = "resolved",
        outdated = false,
        messages = {},
    })
    assert(
        vim.api.nvim_buf_get_changedtick(refresh_buf) == tick_before_unrelated,
        "unrelated thread does not touch popup buffer"
    )
    assert(
        vim.deep_equal(vim.api.nvim_win_get_cursor(refresh_win), { 2, 1 }),
        "unrelated thread does not disturb cursor"
    )

    popup_module.refresh_from_thread(review, {
        id = "T_STALE",
        state = "open",
        outdated = false,
        messages = vim.deepcopy(stale_test_threads[1].messages),
    })
    assert(
        table.concat(win_lines(refresh_win), "\n"):find("Outdated", 1, true) == nil,
        "Outdated tag removed when outdated becomes false: " .. table.concat(win_lines(refresh_win), "\n")
    )
    popup_module.close(review)

    -- 4. Async stale-popup guard across vim.ui.select, toggleReaction, setResolved, and deleteMessage.
    local original_request = review.client.request
    local original_select = vim.ui.select
    local original_confirm = vim.fn.confirm
    local pending_callbacks = {}
    local sent_methods = {}
    review.client.request = function(_, method, _, callback)
        sent_methods[#sent_methods + 1] = method
        pending_callbacks[method] = callback
    end

    -- 4a. vim.ui.select completes after popup closed and reopened.
    popup_module.open(review, vim.deepcopy(stale_test_threads))
    local captured_select_callback
    vim.ui.select = function(_, _, on_choice)
        captured_select_callback = on_choice
    end
    helpers.press_key("+")
    vim.ui.select = original_select
    assert(captured_select_callback ~= nil, "vim.ui.select callback captured")
    popup_module.close(review)
    popup_module.open(review, vim.deepcopy(stale_test_threads))
    local reopened_select_win = helpers.find_floating_win()
    local select_calls_before = #sent_methods
    captured_select_callback("THUMBS_UP")
    assert(#sent_methods == select_calls_before, "stale vim.ui.select callback does not send toggleReaction")
    assert(vim.api.nvim_win_is_valid(reopened_select_win), "new popup stays open after stale vim.ui.select")
    popup_module.close(review)

    -- 4b. toggleReaction RPC completes after popup closed and reopened.
    popup_module.open(review, vim.deepcopy(stale_test_threads))
    vim.ui.select = function(_, _, on_choice)
        on_choice("THUMBS_UP")
    end
    pending_callbacks.toggleReaction = nil
    helpers.press_key("+")
    vim.ui.select = original_select
    assert(pending_callbacks.toggleReaction ~= nil, "toggleReaction RPC in flight")
    popup_module.close(review)
    popup_module.open(review, vim.deepcopy(stale_test_threads))
    local reopened_react_win = helpers.find_floating_win()
    local reopened_react_buf = vim.api.nvim_win_get_buf(reopened_react_win)
    local tick_react_reopen = vim.api.nvim_buf_get_changedtick(reopened_react_buf)
    pending_callbacks.toggleReaction(nil, {
        thread = {
            id = "T_STALE",
            state = "resolved",
            outdated = false,
            messages = vim.deepcopy(stale_test_threads[1].messages),
        },
    })
    assert(vim.api.nvim_win_is_valid(reopened_react_win), "new popup stays active after stale toggleReaction")
    assert(
        vim.api.nvim_buf_get_changedtick(reopened_react_buf) == tick_react_reopen,
        "stale toggleReaction does not refresh newly opened popup"
    )
    popup_module.close(review)

    -- 4c. setResolved RPC completes after popup closed and reopened.
    popup_module.open(review, vim.deepcopy(stale_test_threads))
    pending_callbacks.setResolved = nil
    helpers.press_key("R")
    assert(pending_callbacks.setResolved ~= nil, "setResolved RPC in flight")
    popup_module.close(review)
    popup_module.open(review, vim.deepcopy(stale_test_threads))
    local reopened_resolve_win = helpers.find_floating_win()
    local reopened_resolve_buf = vim.api.nvim_win_get_buf(reopened_resolve_win)
    local tick_resolve_reopen = vim.api.nvim_buf_get_changedtick(reopened_resolve_buf)
    pending_callbacks.setResolved(nil, {
        thread = {
            id = "T_STALE",
            state = "resolved",
            outdated = false,
            messages = vim.deepcopy(stale_test_threads[1].messages),
        },
    })
    assert(vim.api.nvim_win_is_valid(reopened_resolve_win), "new popup stays active after stale setResolved")
    assert(
        vim.api.nvim_buf_get_changedtick(reopened_resolve_buf) == tick_resolve_reopen,
        "stale setResolved does not refresh newly opened popup"
    )
    popup_module.close(review)

    -- 4d. deleteMessage RPC completes after popup closed and reopened.
    popup_module.open(review, vim.deepcopy(stale_test_threads))
    vim.fn.confirm = function()
        return 1
    end
    pending_callbacks.deleteMessage = nil
    helpers.press_key("d")
    vim.fn.confirm = original_confirm
    assert(pending_callbacks.deleteMessage ~= nil, "deleteMessage RPC in flight")
    popup_module.close(review)
    popup_module.open(review, vim.deepcopy(stale_test_threads))
    local reopened_delete_win = helpers.find_floating_win()
    pending_callbacks.deleteMessage(nil, {})
    assert(vim.api.nvim_win_is_valid(reopened_delete_win), "stale deleteMessage does not close newly opened popup")
    popup_module.close(review)

    review.client.request = original_request
end
