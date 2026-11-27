return function(context)
    local helpers = context.helpers
    local log = context.log
    local worktree = context.worktree
    local create_file_row = context.create_file_row
    local create_hunk_row = context.create_hunk_row
    local create_added_row = context.create_added_row
    local review = context.review
    local folded_stream = context.folded_stream
    local find_stream_buffers = context.find_stream_buffers
    local wait_for_mode = context.wait_for_mode
    local report_error = context.report_error

    local jpr = require("jpr")
    local session = require("jpr.session")
    local stream_view = require("jpr.views.stream")
    local main_window = require("jpr.views.main_window")
    local view_mode = require("jpr.view_mode")
    local errors = {}
    local stream_win = vim.fn.win_findbuf(review.stream.buffers.main)[1]

    local function cursor_line()
        return vim.api.nvim_win_get_cursor(0)[1]
    end
    local function draw_and_focus(stream)
        stream_view.draw(review, stream, {})
        stream_win = vim.fn.win_findbuf(review.stream.buffers.main)[1]
        vim.api.nvim_set_current_win(stream_win)
    end

    -- A redraw keeps the cursor line and the top line.
    local long_rows = { create_file_row("long.md", false), create_hunk_row("long.md", 1) }
    for line = 1, 100 do
        long_rows[#long_rows + 1] = create_added_row("long.md", line, "line " .. line)
    end
    draw_and_focus({ mode = "unified", rows = long_rows })
    vim.fn.winrestview({ topline = 50, lnum = 60 })
    draw_and_focus({ mode = "unified", rows = long_rows })
    local kept_view = vim.fn.winsaveview()
    assert(kept_view.lnum == 60 and kept_view.topline == 50, "the view is kept: " .. vim.inspect(kept_view))

    -- A `v` that no redraw follows leaves nothing pending.
    draw_and_focus(folded_stream)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local streams_before_v = helpers.count_requests(log, '"method":"stream"')
    stream_view.toggle_viewed(review)
    assert(vim.wait(3000, function()
        return helpers.count_requests(log, '"method":"setViewed"', '"a.md"') == 1
    end), "v asks for a.md")
    vim.wait(300)
    assert(helpers.count_requests(log, '"method":"stream"') == streams_before_v, "no redraw was asked for")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    draw_and_focus(folded_stream)
    assert(cursor_line() == 2, "an unrelated draw moved the cursor to " .. cursor_line())

    -- A `v` the engine refuses leaves nothing pending either.
    errors = {}
    local jpr_notify = require("jpr.notify")
    jpr_notify.set_listener(function(kind, message)
        if kind == "error" then
            errors[#errors + 1] = message
        end
    end)
    draw_and_focus({ mode = "unified", rows = { create_file_row("BROKEN.md", false), create_added_row("BROKEN.md", 1, "x"), create_file_row("c.md", false) } })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    stream_view.toggle_viewed(review)
    assert(vim.wait(3000, function()
        return #errors > 0
    end), "the refusal is reported")
    jpr_notify.set_listener(nil)
    assert(errors[1]:find("GitHub refused BROKEN.md", 1, true), vim.inspect(errors))
    assert(review.stream.after_draw == nil, "nothing is pending after a refusal")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    draw_and_focus({ mode = "unified", rows = { create_file_row("BROKEN.md", false), create_added_row("BROKEN.md", 1, "x"), create_file_row("c.md", false) } })
    assert(cursor_line() == 2, "a draw after the refusal moved the cursor to " .. cursor_line())

    -- A view that changes while the request is in flight is fetched again by the next refresh.
    local function wait_for_answer(message)
        assert(vim.wait(3000, function()
            return review.stream.layout ~= nil
        end), message)
    end
    local streams_before_show = helpers.count_requests(log, '"method":"stream"')
    local view_before = review.view
    review.stream.layout = nil
    stream_view.show(review, {})
    review.view = vim.tbl_extend("force", view_before, { files = { vim.tbl_extend("force", view_before.files[1], { additions = 9 }) } })
    wait_for_answer("the stream is drawn")
    review.stream.layout = nil
    stream_view.refresh(review)
    assert(vim.wait(3000, function()
        return helpers.count_requests(log, '"method":"stream"') == streams_before_show + 2
    end), "the changed view is fetched")
    wait_for_answer("the changed view is drawn")
    review.view = view_before
    review.stream.layout = nil
    stream_view.refresh(review)
    wait_for_answer("the view is drawn again")

    -- A toggle while a request for the hidden stream is in flight fetches in the new mode.
    main_window.edit(review, vim.fn.win_findbuf(review.stream.buffers.main)[1], "README.md")
    assert(not stream_view.is_visible(review), "the stream is hidden")
    stream_view.show(review, {})
    session.toggle_view()
    wait_for_mode(review, "split")

    -- Split: a refused <CR> keeps the left half open.
    local split_left = review.stream.left_win
    errors = {}
    jpr.error = function(message)
        errors[#errors + 1] = message
    end
    draw_and_focus({ mode = "split", rows = { create_file_row("../escape.txt", false), create_added_row("../escape.txt", 1, "y") } })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    stream_view.open_target(review)
    jpr.error = report_error
    assert(#errors == 1, vim.inspect(errors))
    assert(review.stream.left_win == split_left and vim.api.nvim_win_is_valid(split_left), "the left half stays")

    -- A file opened from the stream gets its own window options back.
    vim.fn.writefile({ "fresh" }, worktree .. "/fresh.md")
    draw_and_focus({ mode = "split", rows = { create_file_row("fresh.md", false), create_added_row("fresh.md", 1, "fresh") } })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    stream_view.open_target(review)
    assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/fresh.md"), "fresh.md opens")
    local opened_win = vim.api.nvim_get_current_win()
    for _, name in ipairs({ "wrap", "number", "signcolumn", "cursorline", "foldmethod", "foldtext", "fillchars", "foldminlines", "scrollbind", "cursorbind" }) do
        local own = vim.api.nvim_get_option_value(name, { win = opened_win, scope = "global" })
        assert(vim.wo[opened_win][name] == own, name .. " is the stream's, not the window's own")
    end
    assert(not vim.wo[opened_win].scrollbind and not vim.wo[opened_win].cursorbind, "the file is not bound")
    assert(not vim.api.nvim_win_is_valid(split_left), "the left half went with the stream")

    -- Closing the left half with :q gets a new one on the next refresh.
    session.stream_current()
    assert(vim.wait(3000, function()
        local left = review.stream.left_win
        return vim.api.nvim_get_current_buf() == review.stream.buffers.main and left ~= nil and vim.api.nvim_win_is_valid(left)
    end), "the split stream is back")
    vim.api.nvim_set_current_win(review.stream.left_win)
    vim.cmd("quit")
    stream_view.refresh(review, true)
    assert(vim.wait(3000, function()
        local left = review.stream.left_win
        return left ~= nil and vim.api.nvim_win_is_valid(left)
    end), "a new left half opens")
    require("jpr.notify").clear()
    assert(#vim.api.nvim_tabpage_list_wins(review.tab) == 3, "the panel and the halves only")

    -- A window where the reviewer opened their own buffer is theirs.
    vim.fn.writefile({ "other" }, worktree .. "/OTHER.md")
    local function take_left_half(take)
        local taken = review.stream.left_win
        vim.api.nvim_set_current_win(taken)
        take()
        local their_buf = vim.api.nvim_win_get_buf(taken)
        stream_view.refresh(review, true)
        assert(vim.wait(3000, function()
            local left = review.stream.left_win
            return left ~= nil and left ~= taken and vim.api.nvim_win_is_valid(left)
        end), "a new left half opens")
        assert(vim.api.nvim_win_get_buf(taken) == their_buf, "their buffer is untouched")
        assert(vim.w[taken].jpr_side == nil, "their window is no longer a side window")
        return taken, their_buf
    end
    local saved_win = take_left_half(function()
        vim.cmd.edit(vim.fn.fnameescape(worktree .. "/OTHER.md"))
    end)
    local draft_win, draft_buf = take_left_half(function()
        vim.cmd("enew")
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "draft" })
    end)
    assert(vim.bo[draft_buf].modified and vim.api.nvim_buf_get_lines(draft_buf, 0, -1, false)[1] == "draft", "the draft is kept")
    session.toggle_view()
    wait_for_mode(review, "unified")
    assert(vim.api.nvim_win_is_valid(saved_win) and vim.api.nvim_win_is_valid(draft_win), "a toggle to unified keeps their windows")
    assert(vim.api.nvim_win_get_buf(draft_win) == draft_buf, "and their buffers")
    vim.api.nvim_win_close(saved_win, true)
    vim.api.nvim_win_close(draft_win, true)
    vim.api.nvim_buf_delete(draft_buf, { force = true })

    -- Closing the review wipes the stream, and a late answer is dropped without error.
    session.close_current()
    assert(review.stream == nil, "the session lets go of its stream")
    assert(#find_stream_buffers(7) == 0, "its buffers are wiped")
    local late, late_err = pcall(stream_view.draw, review, folded_stream, {})
    assert(late, "a late answer threw: " .. tostring(late_err))
    assert(review.stream == nil and #find_stream_buffers(7) == 0, "a late answer draws nothing")

    -- The first stream never opens over a file the reviewer opened before sync.
    session.start({ worktree = worktree, repo = "octo/widgets", number = 9 })
    local third = session.current()
    local third_main = main_window.find(third)
    main_window.edit(third, third_main, "README.md", 1)
    assert(vim.wait(3000, function()
        return third.stream ~= nil and third.stream.layout ~= nil
    end), "the stream is fetched")
    assert(vim.fn.resolve(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(third_main))) == vim.fn.resolve(worktree .. "/README.md"), "README.md stays")
    assert(not stream_view.is_visible(third), "the stream stays hidden")
    session.close_current()

    -- An engine that stops mid-review restarts once, keeps the stream open in
    -- read-only mode on a second crash, and wipes its buffers on :tabclose.
    session.start({ worktree = worktree, repo = "octo/widgets", number = 8 })
    local second = session.current()
    assert(vim.wait(3000, function()
        return second.stream ~= nil and second.stream.layout ~= nil
    end), "the second review's stream opens")
    session.toggle_view()
    wait_for_mode(second, "split")
    local left_win = second.stream.left_win
    local report_warn = jpr.warn
    jpr.error = function() end
    jpr.warn = function() end
    local first_client = second.client
    first_client:stop()
    assert(vim.wait(3000, function()
        return second.has_restarted == true and second.client ~= nil and second.client ~= first_client
    end), "first stop restarts the engine")
    second.client:stop()
    assert(vim.wait(3000, function()
        return second.is_read_only == true and second.client == nil
    end), "second stop switches the session to read-only")
    jpr.error = report_error
    jpr.warn = report_warn
    assert(vim.api.nvim_tabpage_is_valid(second.tab) and vim.api.nvim_win_is_valid(left_win), "read-only keeps the tab and split stream")
    vim.cmd.tabclose()
    assert(second.stream == nil, "closing the tab lets go of its stream")
    assert(not vim.api.nvim_win_is_valid(left_win), "the left half closed")
    assert(#find_stream_buffers(8) == 0, "its buffers are wiped")
    session.toggle_view()
    assert(view_mode.get() == "unified", "toggled back")
end
