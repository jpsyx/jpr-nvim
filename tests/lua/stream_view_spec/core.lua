return function(context)
    local helpers = context.helpers
    local log = context.log
    local worktree = context.worktree
    local create_file_row = context.create_file_row
    local create_hunk_row = context.create_hunk_row
    local create_added_row = context.create_added_row

    local jpr = require("jpr")
    local session = require("jpr.session")
    local stream_view = require("jpr.views.stream")
    local main_window = require("jpr.views.main_window")
    local view_mode = require("jpr.view_mode")

    session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
    local review = session.current()
    local function main_lines()
        local buf = review.stream and review.stream.buffers.main
        return (buf and vim.api.nvim_buf_is_valid(buf)) and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or {}
    end
    assert(vim.wait(3000, function()
        return #main_lines() == 5
    end), "the stream opens: " .. vim.inspect(main_lines()))
    assert(vim.deep_equal(main_lines(), {
        "▾   README.md  +2 -1",
        "@@ -1,2 +1,2 @@",
        "    1     1   hello",
        "    2       - old",
        "          2 + new",
    }), vim.inspect(main_lines()))
    local stream_win = vim.fn.win_findbuf(review.stream.buffers.main)[1]
    assert(stream_win and stream_win ~= review.panel.win, "it shows in the main window, beside the panel")

    -- ]h moves to the hunk, and <CR> opens the real file at that line.
    vim.api.nvim_set_current_win(stream_win)
    vim.api.nvim_win_set_cursor(stream_win, { 1, 0 })
    stream_view.jump(review, "hunks", 1)
    assert(vim.api.nvim_win_get_cursor(stream_win)[1] == 2, "]h")
    vim.api.nvim_win_set_cursor(stream_win, { 5, 0 })
    stream_view.open_target(review)
    assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/README.md"), "<CR> opens the file")
    assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "at its line")

    -- :Jpr stream brings it back; :Jpr toggle splits it into two aligned halves.
    session.stream_current()
    assert(vim.wait(3000, function()
        return vim.api.nvim_get_current_buf() == review.stream.buffers.main
    end), ":Jpr stream shows and focuses the stream")
    session.toggle_view()
    assert(vim.wait(3000, function()
        return review.stream.left_win ~= nil and vim.api.nvim_win_is_valid(review.stream.left_win)
    end), "the left half opens")
    local left_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(review.stream.left_win), 0, -1, false)
    assert(vim.deep_equal(left_lines, { "▾   README.md  +2 -1", "@@ -1,2 +1,2 @@", "    1   hello", "    2 - old" }), vim.inspect(left_lines))
    assert(vim.deep_equal(main_lines(), { "▾   README.md  +2 -1", "@@ -1,2 +1,2 @@", "    1   hello", "    2 + new" }), vim.inspect(main_lines()))
    assert(vim.wo[review.stream.left_win].scrollbind, "the halves scroll together")

    -- v marks the file viewed on the engine.
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(review.stream.buffers.main)[1])
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    stream_view.toggle_viewed(review)
    assert(vim.wait(3000, function()
        return review.view.viewedCount == 1
    end), "the engine's viewedChanged reaches the view")
    local sent = table.concat(vim.fn.readfile(log), "\n")
    assert(sent:find('"method":"setViewed"', 1, true) and sent:find('"viewed":true', 1, true), sent)
    assert(sent:find('"path":"README.md"', 1, true), sent)

    -- Toggling back and forth leaves no window, buffer or autocommand behind:
    -- the left half's buffer goes with its window.
    local function find_stream_buffers(number)
        return vim.tbl_filter(function(buf)
            return vim.api.nvim_buf_get_name(buf):find(("jpr://stream/%d"):format(number), 1, true) ~= nil
        end, vim.api.nvim_list_bufs())
    end
    local function wait_for_mode(target, mode)
        assert(vim.wait(3000, function()
            local state = target.stream
            local has_left = state and state.left_win ~= nil and vim.api.nvim_win_is_valid(state.left_win)
            local columns = state and state.layout and #state.layout.columns
            if mode == "split" then
                return has_left and columns == 2
            end
            return not has_left and columns == 1
        end), "the stream turns " .. mode)
    end
    for _, mode in ipairs({ "unified", "split", "unified" }) do
        session.toggle_view()
        wait_for_mode(review, mode)
        local expected = mode == "split" and 2 or 1
        assert(#find_stream_buffers(7) == expected, mode .. ": " .. vim.inspect(find_stream_buffers(7)))
        assert(#vim.api.nvim_tabpage_list_wins(review.tab) == expected + 1, mode .. ": the panel and the halves only")
    end
    local leave_autocmds = vim.api.nvim_get_autocmds({ event = "BufWinLeave", buffer = review.stream.buffers.main })
    assert(#leave_autocmds == 1, "one BufWinLeave: " .. #leave_autocmds)

    -- ]h skips the hunks of a viewed file's closed fold, and <CR> anywhere in
    -- that fold opens the file at its top rather than at the hidden line.
    vim.fn.writefile({ "1", "2", "3", "4", "5", "6" }, worktree .. "/b.md")
    local folded_stream = {
        mode = "unified",
        rows = {
            create_file_row("a.md", false), create_hunk_row("a.md", 1), create_added_row("a.md", 1, "a"),
            create_file_row("b.md", true), create_hunk_row("b.md", 1), create_added_row("b.md", 1, "b1"), create_hunk_row("b.md", 5), create_added_row("b.md", 5, "b5"),
            create_file_row("c.md", false), create_hunk_row("c.md", 1), create_added_row("c.md", 1, "c"),
        },
    }
    stream_view.draw(review, folded_stream, {})
    stream_win = vim.fn.win_findbuf(review.stream.buffers.main)[1]
    vim.api.nvim_set_current_win(stream_win)
    assert(vim.fn.foldclosed(5) == 5 and vim.fn.foldclosedend(5) == 8, "b.md's body is folded")
    vim.api.nvim_win_set_cursor(stream_win, { 2, 0 })
    stream_view.jump(review, "hunks", 1)
    assert(vim.api.nvim_win_get_cursor(stream_win)[1] == 10, "]h skips the folded hunks: " .. vim.api.nvim_win_get_cursor(stream_win)[1])
    stream_view.jump(review, "hunks", -1)
    assert(vim.api.nvim_win_get_cursor(stream_win)[1] == 2, "[h skips them too")
    vim.api.nvim_win_set_cursor(stream_win, { 7, 0 })
    stream_view.open_target(review)
    assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/b.md"), "<CR> on the fold opens b.md")
    assert(vim.api.nvim_win_get_cursor(0)[1] == 1, "at its top, not the hidden hunk's line")

    -- <CR> on a path the pull request named opens it only through
    -- main_window.edit: a symlink out of the worktree or `..` is refused.
    local errors = {}
    local report_error = jpr.error
    jpr.error = function(message)
        errors[#errors + 1] = message
    end
    local outside = vim.fn.tempname()
    vim.fn.writefile({ "secret" }, outside)
    vim.uv.fs_symlink(outside, worktree .. "/notes.md")
    stream_view.draw(review, {
        mode = "unified",
        rows = { create_file_row("notes.md", false), create_added_row("notes.md", 1, "x"), create_file_row("../escape.txt", false), create_added_row("../escape.txt", 1, "y") },
    }, {})
    stream_win = vim.fn.win_findbuf(review.stream.buffers.main)[1]
    vim.api.nvim_set_current_win(stream_win)
    for _, line in ipairs({ 1, 2, 3, 4 }) do
        errors = {}
        vim.api.nvim_win_set_cursor(stream_win, { line, 0 })
        local opened, open_err = pcall(stream_view.open_target, review)
        assert(opened, "line " .. line .. " threw: " .. tostring(open_err))
        assert(vim.api.nvim_get_current_buf() == review.stream.buffers.main, "line " .. line .. " opened a file")
        assert(#errors == 1 and errors[1]:find("not a plain file path inside the worktree", 1, true), vim.inspect(errors))
    end
    jpr.error = report_error

    -- A row's text with NUL, ESC or CR draws as ^@, ^[ and ^M, never raw.
    local drawn, draw_err = pcall(stream_view.draw, review, {
        mode = "unified",
        rows = { create_file_row("evil\27.md", false), create_hunk_row("evil\27.md", 1), create_added_row("evil\27.md", 1, "\27[2J\r\0x") },
    }, {})
    assert(drawn, "drawing hostile text threw: " .. tostring(draw_err))
    stream_win = vim.fn.win_findbuf(review.stream.buffers.main)[1]
    vim.cmd("redraw")
    local top_row, left_col = unpack(vim.fn.win_screenpos(stream_win))
    local function screen_row(row)
        local cells = {}
        for column = left_col, left_col + vim.api.nvim_win_get_width(stream_win) - 1 do
            cells[#cells + 1] = vim.fn.screenstring(top_row + row - 1, column)
        end
        return table.concat(cells)
    end
    for row = 1, 3 do
        assert(not screen_row(row):find("[%z\1-\31\127]"), ("row %d holds a raw control character"):format(row))
    end
    assert(vim.startswith(screen_row(1), "▾   evil^[.md"), screen_row(1))
    assert(vim.startswith(screen_row(3), "          1 + ^[[2J^M^@x"), screen_row(3))

    -- A stream buffer wiped from under the session is made again by :Jpr stream.
    vim.api.nvim_buf_delete(review.stream.buffers.main, { force = true })
    local refreshed, refresh_err = pcall(stream_view.refresh, review, true)
    assert(refreshed, "refresh threw: " .. tostring(refresh_err))
    session.stream_current()
    assert(vim.wait(3000, function()
        return #main_lines() == 5 and vim.api.nvim_get_current_buf() == review.stream.buffers.main
    end), "the stream comes back: " .. vim.inspect(main_lines()))

    local function cursor_line()
        return vim.api.nvim_win_get_cursor(0)[1]
    end
    local function draw_and_focus(stream)
        stream_view.draw(review, stream, {})
        stream_win = vim.fn.win_findbuf(review.stream.buffers.main)[1]
        vim.api.nvim_set_current_win(stream_win)
    end

    -- ]f and [f step between file headers.
    draw_and_focus(folded_stream)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local visited = {}
    for _, step in ipairs({ 1, 1, 1, -1 }) do
        stream_view.jump(review, "files", step)
        visited[#visited + 1] = cursor_line()
    end
    assert(vim.deep_equal(visited, { 4, 9, 9, 4 }), "]f ]f ]f [f: " .. vim.inspect(visited))

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
    jpr.error = function(message)
        errors[#errors + 1] = message
    end
    draw_and_focus({ mode = "unified", rows = { create_file_row("BROKEN.md", false), create_added_row("BROKEN.md", 1, "x"), create_file_row("c.md", false) } })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    stream_view.toggle_viewed(review)
    assert(vim.wait(3000, function()
        return #errors > 0
    end), "the refusal is reported")
    jpr.error = report_error
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
    for _, name in ipairs({ "wrap", "number", "signcolumn", "cursorline", "foldmethod", "scrollbind", "cursorbind" }) do
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

    -- An engine that stops mid-review closes the stream's left half and wipes its buffers, but the tab stays.
    session.start({ worktree = worktree, repo = "octo/widgets", number = 8 })
    local second = session.current()
    assert(vim.wait(3000, function()
        return second.stream ~= nil and second.stream.layout ~= nil
    end), "the second review's stream opens")
    session.toggle_view()
    wait_for_mode(second, "split")
    local left_win = second.stream.left_win
    jpr.error = function() end
    second.client:stop()
    assert(vim.wait(3000, function()
        return second.stream == nil
    end), "the session lets go of its stream")
    jpr.error = report_error
    assert(vim.api.nvim_tabpage_is_valid(second.tab), "the tab stays")
    assert(not vim.api.nvim_win_is_valid(left_win), "the left half closed")
    assert(#find_stream_buffers(8) == 0, "its buffers are wiped")
    vim.cmd.tabclose()
    session.toggle_view()
    assert(view_mode.get() == "unified", "toggled back")
end
