-- Compose specs: open_new, empty/valid submit, cancel/confirm/wipe, and suggestion fences.
return function(ctx)
    local compose = ctx.compose
    local helpers = ctx.helpers
    local log = ctx.log
    local review = ctx.review
    local line_anchor = ctx.line_anchor
    local find_compose_win = ctx.find_compose_win

    -- 1. compose.open_new (code anchor and PR anchor): floating window options, title, omnifunc, keymaps.
    compose.open_new(review, line_anchor, { suggest = false })
    local compose_win = find_compose_win()
    assert(compose_win ~= nil and vim.api.nvim_win_is_valid(compose_win), "compose window opened")
    local compose_buf = vim.api.nvim_win_get_buf(compose_win)
    local code_window_config = vim.api.nvim_win_get_config(compose_win)
    assert(code_window_config.relative == "editor", "compose window is floating over editor")
    assert(
        vim.deep_equal(code_window_config.border, { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }),
        "compose window has rounded border: " .. vim.inspect(code_window_config.border)
    )
    assert(helpers.win_title(compose_win):find("[GitHub draft]", 1, true) ~= nil, helpers.win_title(compose_win))
    assert(vim.bo[compose_buf].buftype == "nofile", "compose buftype is nofile")
    assert(vim.bo[compose_buf].filetype == "markdown", "compose filetype is markdown")
    assert(vim.bo[compose_buf].omnifunc == "v:lua.require'jpr.comments.mentions'.omnifunc", "compose sets omnifunc")

    -- 2. Empty / whitespace <C-s> calls jpr.error without sending comment or closing; valid text sends comment + closes.
    ctx.captured.errors = {}
    local comments_before = #helpers.read_requests(log, "comment")
    vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { "   ", "\t" })
    helpers.press_key("<C-s>")
    assert(#ctx.captured.errors == 1 and ctx.captured.errors[1]:find("empty", 1, true) ~= nil, vim.inspect(ctx.captured.errors))
    assert(vim.api.nvim_win_is_valid(compose_win), "empty submit keeps compose window open")
    assert(#helpers.read_requests(log, "comment") == comments_before, "empty submit sends no RPC")

    vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { "Looks good", "Second line" })
    helpers.press_key("<C-s>")
    assert(not vim.api.nvim_win_is_valid(compose_win), "<C-s> closes compose window")
    assert(vim.wait(3000, function()
        return #helpers.read_requests(log, "comment") == comments_before + 1
    end), "comment RPC sent")
    local sent_comment = helpers.read_requests(log, "comment")[comments_before + 1].params
    assert(vim.deep_equal(sent_comment.anchor, line_anchor), vim.inspect(sent_comment))
    assert(sent_comment.body == "Looks good\nSecond line", vim.inspect(sent_comment))
    assert(sent_comment.origin == "github", vim.inspect(sent_comment))

    -- PR conversation anchor title uses [GitHub comment] PR Conversation.
    local pr_anchor = { kind = "pr", side = "RIGHT" }
    compose.open_new(review, pr_anchor, { suggest = false })
    local pr_compose_win = find_compose_win()
    assert(pr_compose_win ~= nil, "PR compose window opened")
    assert(helpers.win_title(pr_compose_win):find("[GitHub comment] PR Conversation", 1, true) ~= nil, helpers.win_title(pr_compose_win))

    -- 3. q / <Esc> unmodified closes without confirm; modified invokes confirm; BufWipeout cleans up.
    local original_confirm = vim.fn.confirm
    local confirm_called = 0
    vim.fn.confirm = function()
        confirm_called = confirm_called + 1
        return 2
    end
    helpers.press_key("q")
    assert(confirm_called == 0, "unmodified q does not call confirm")
    assert(not vim.api.nvim_win_is_valid(pr_compose_win), "unmodified q closes compose window")

    compose.open_new(review, line_anchor, { suggest = false })
    local esc_compose_win = find_compose_win()
    helpers.press_key("<Esc>")
    assert(confirm_called == 0, "unmodified <Esc> does not call confirm")
    assert(not vim.api.nvim_win_is_valid(esc_compose_win), "unmodified <Esc> closes compose window")

    compose.open_new(review, line_anchor, { suggest = false })
    local modified_win = find_compose_win()
    local modified_buf = vim.api.nvim_win_get_buf(modified_win)
    vim.api.nvim_buf_set_lines(modified_buf, 0, -1, false, { "unsaved edit" })
    helpers.press_key("q")
    assert(confirm_called == 1, "modified q calls confirm")
    assert(vim.api.nvim_win_is_valid(modified_win), "cancel keeps compose window open")

    vim.fn.confirm = function()
        confirm_called = confirm_called + 1
        return 1
    end
    helpers.press_key("q")
    assert(confirm_called == 2 and not vim.api.nvim_win_is_valid(modified_win), "discard confirm closes compose window")
    vim.fn.confirm = original_confirm

    compose.open_new(review, line_anchor, { suggest = false })
    local wipe_win = find_compose_win()
    local wipe_buf = vim.api.nvim_win_get_buf(wipe_win)
    vim.api.nvim_win_close(wipe_win, true)
    assert(not vim.api.nvim_win_is_valid(wipe_win), "direct close closes compose window")
    assert(not vim.api.nvim_buf_is_valid(wipe_buf), "closed compose buffer wiped")

    -- 4. open_new(..., { suggest = true }) pre-populates suggestion fence from anchoredLines; <C-g>s inserts fence in insert mode.
    compose.open_new(review, line_anchor, { suggest = true })
    assert(vim.wait(3000, function()
        return find_compose_win() ~= nil
    end), "suggest compose opens after anchoredLines")
    local suggest_win = find_compose_win()
    local suggest_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(suggest_win), 0, -1, false)
    assert(table.concat(suggest_lines, "\n") == "```suggestion\nnew\n```", vim.inspect(suggest_lines))
    compose.close(review)

    compose.open_new(review, line_anchor, { suggest = false })
    local fence_win = find_compose_win()
    local fence_buf = vim.api.nvim_win_get_buf(fence_win)
    vim.api.nvim_buf_set_lines(fence_buf, 0, -1, false, { "Try this:" })
    vim.api.nvim_win_set_cursor(fence_win, { 1, 9 })
    local anchored_before = #helpers.read_requests(log, "anchoredLines")
    helpers.press_key("A<C-g>s<Esc>")
    assert(vim.wait(3000, function()
        return #helpers.read_requests(log, "anchoredLines") == anchored_before + 1
            and #vim.api.nvim_buf_get_lines(fence_buf, 0, -1, false) >= 4
    end), "<C-g>s inserts suggestion fence at cursor")
    local inserted = table.concat(vim.api.nvim_buf_get_lines(fence_buf, 0, -1, false), "\n")
    assert(inserted == "Try this:\n```suggestion\nnew\n```", inserted)
    compose.close(review)

    -- 4b. Stale anchoredLines callback after compose closes does not reopen compose.
    local pending_anchored_callback
    review.client.request = function(client_self, method, params, callback)
        if method == "anchoredLines" then
            pending_anchored_callback = callback
            return
        end
        return ctx.original_client_request(client_self, method, params, callback)
    end
    compose.open_new(review, line_anchor, { suggest = true })
    assert(pending_anchored_callback ~= nil, "anchoredLines callback captured")
    compose.close(review)
    pending_anchored_callback(nil, { text = "stale" })
    assert(find_compose_win() == nil, "stale anchoredLines does not open compose window after close")
    review.client.request = ctx.original_client_request
end
