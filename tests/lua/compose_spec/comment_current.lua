-- Compose specs: session.comment_current anchor resolution across diff, split, and stream buffers.
return function(ctx)
    local session = ctx.session
    local main_window = ctx.main_window
    local stream_view = ctx.stream_view
    local compose = ctx.compose
    local helpers = ctx.helpers
    local log = ctx.log
    local review = ctx.review
    local find_compose_win = ctx.find_compose_win

    local function comment_and_submit(opts)
        local before = #helpers.read_requests(log, "comment")
        session.comment_current(opts)
        local active_win = find_compose_win()
        assert(active_win ~= nil and vim.api.nvim_win_is_valid(active_win), "comment_current opened compose window")
        vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(active_win), 0, -1, false, { "Anchor check" })
        helpers.press_key("<C-s>")
        assert(vim.wait(3000, function()
            return #helpers.read_requests(log, "comment") == before + 1
        end), "submitted comment RPC from comment_current")
        return helpers.read_requests(log, "comment")[before + 1].params.anchor
    end

    -- Unrelated scratch buffer reports error without opening compose.
    local win = main_window.find(review)
    vim.api.nvim_set_current_win(win)
    local unrelated_buf = vim.api.nvim_create_buf(false, true)
    local unrelated_win = vim.api.nvim_open_win(unrelated_buf, true, { relative = "editor", row = 1, col = 1, width = 40, height = 5 })
    ctx.captured.errors = {}
    session.comment_current()
    assert(#ctx.captured.errors == 1, "unrelated buffer notifies error")
    vim.api.nvim_win_close(unrelated_win, true)
    vim.api.nvim_buf_delete(unrelated_buf, { force = true })
    assert(find_compose_win() == nil, "unrelated buffer opens no compose window")

    -- Diff buffer: line, suggest, range, reversed range, file, and split base_buf.
    main_window.edit(review, win, "README.md", 1)
    assert(vim.wait(3000, function()
        return #helpers.read_requests(log, "fileDiff") >= 1
    end), "diff requested for README.md")

    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    assert(vim.deep_equal(comment_and_submit(), { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 }))

    session.comment_current({ suggest = true })
    assert(vim.wait(3000, function()
        return find_compose_win() ~= nil
    end), "comment_current({ suggest = true }) opens compose with suggestion fence")
    local suggest_from_cmd_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(find_compose_win()), 0, -1, false)
    assert(suggest_from_cmd_lines[1] == "```suggestion", vim.inspect(suggest_from_cmd_lines))
    compose.close(review)

    assert(vim.deep_equal(
        comment_and_submit({ line1 = 1, line2 = 3, range = 2 }),
        { file = "README.md", kind = "range", side = "RIGHT", start = 1, ["end"] = 3 }
    ))
    assert(vim.deep_equal(
        comment_and_submit({ line1 = 4, line2 = 2, range = 2 }),
        { file = "README.md", kind = "range", side = "RIGHT", start = 2, ["end"] = 4 }
    ))
    assert(vim.deep_equal(
        comment_and_submit({ file = true }),
        { file = "README.md", kind = "file", side = "RIGHT" }
    ))

    -- Switch to split view to comment on base_buf (LEFT side).
    session.toggle_view()
    local base_win
    assert(vim.wait(3000, function()
        for _, candidate_win in ipairs(vim.api.nvim_tabpage_list_wins(review.tab)) do
            if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(candidate_win)):find("jpr://base/7/README.md", 1, true) then
                base_win = candidate_win
                return true
            end
        end
        return false
    end), "split mode opens base_win")
    vim.api.nvim_set_current_win(base_win)
    vim.api.nvim_win_set_cursor(base_win, { 2, 0 })
    assert(vim.deep_equal(comment_and_submit(), { file = "README.md", kind = "line", side = "LEFT", start = 2, ["end"] = 2 }))

    -- Stream buffer: line, range, file = true, header error, mixed-side range error.
    session.toggle_view()
    stream_view.draw(review, {
        mode = "unified",
        rows = {
            { kind = "file", path = "README.md", additions = 1, deletions = 1, viewed = "UNVIEWED", folded = false },
            { kind = "hunk", path = "README.md", header = "@@ -1,3 +1,3 @@", target = 1 },
            {
                kind = "line",
                path = "README.md",
                left = { line = 1, text = "hello", change = "context", words = {} },
                right = { line = 1, text = "hello", change = "context", words = {} },
                target = 1,
            },
            { kind = "line", path = "README.md", left = { line = 2, text = "old", change = "removed", words = {} }, target = 2 },
            { kind = "line", path = "README.md", right = { line = 2, text = "new", change = "added", words = {} }, target = 2 },
            { kind = "line", path = "README.md", right = { line = 3, text = "tail", change = "added", words = {} }, target = 3 },
        },
    }, { focus = true })

    local stream_win = vim.fn.win_findbuf(review.stream.buffers.main)[1]
    vim.api.nvim_set_current_win(stream_win)
    vim.api.nvim_win_set_cursor(stream_win, { 4, 0 })
    assert(vim.deep_equal(comment_and_submit(), { file = "README.md", kind = "line", side = "LEFT", start = 2, ["end"] = 2 }))
    assert(vim.deep_equal(
        comment_and_submit({ line1 = 5, line2 = 6, range = 2 }),
        { file = "README.md", kind = "range", side = "RIGHT", start = 2, ["end"] = 3 }
    ))
    assert(vim.deep_equal(
        comment_and_submit({ file = true }),
        { file = "README.md", kind = "file", side = "RIGHT" }
    ))

    ctx.captured.errors = {}
    vim.api.nvim_win_set_cursor(stream_win, { 2, 0 })
    session.comment_current()
    assert(find_compose_win() == nil and #ctx.captured.errors == 1, "stream hunk header notifies error")

    ctx.captured.errors = {}
    session.comment_current({ line1 = 4, line2 = 5, range = 2 })
    assert(find_compose_win() == nil and #ctx.captured.errors == 1, "stream mixed-side range notifies error")
end
