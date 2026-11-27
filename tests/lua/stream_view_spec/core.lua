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
        require("jpr.notify").clear()
        local expected = mode == "split" and 2 or 1
        assert(#find_stream_buffers(7) == expected, mode .. ": " .. vim.inspect(find_stream_buffers(7)))
        assert(#vim.api.nvim_tabpage_list_wins(review.tab) == expected + 1, mode .. ": the panel and the halves only")
    end
    local leave_autocmds = vim.api.nvim_get_autocmds({ event = "BufWinLeave", buffer = review.stream.buffers.main })
    assert(#leave_autocmds == 1, "one BufWinLeave: " .. #leave_autocmds)

    -- ]h skips the hunks of a viewed file's closed fold, a collapsed viewed file
    -- renders as a single header line (no +-- banner) with zo still expanding it,
    -- and <CR> on that fold opens the file at its top rather than at the hidden line.
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
    assert(vim.fn.foldclosed(4) == 4 and vim.fn.foldclosedend(4) == 8, "b.md folds from its header line through its body")
    vim.cmd("redraw")
    local fold_top, fold_left = unpack(vim.fn.win_screenpos(stream_win))
    local function read_fold_row(row)
        local cells = {}
        for column = fold_left, fold_left + vim.api.nvim_win_get_width(stream_win) - 1 do
            cells[#cells + 1] = vim.fn.screenstring(fold_top + row - 1, column)
        end
        return table.concat(cells)
    end
    assert(vim.startswith(read_fold_row(4), "▸ ✓ b.md  +1 -0"), "collapsed file shows header only: " .. read_fold_row(4))
    assert(vim.startswith(read_fold_row(5), "▾   c.md  +1 -0"), "no extra +-- fold banner below collapsed file: " .. read_fold_row(5))
    vim.api.nvim_win_set_cursor(stream_win, { 2, 0 })
    stream_view.jump(review, "hunks", 1)
    assert(vim.api.nvim_win_get_cursor(stream_win)[1] == 10, "]h skips the folded hunks: " .. vim.api.nvim_win_get_cursor(stream_win)[1])
    stream_view.jump(review, "hunks", -1)
    assert(vim.api.nvim_win_get_cursor(stream_win)[1] == 2, "[h skips them too")
    vim.api.nvim_win_set_cursor(stream_win, { 4, 0 })
    vim.cmd("normal! zo")
    assert(vim.fn.foldclosed(4) == -1, "zo opens the collapsed file in place")
    vim.cmd("normal! zc")
    assert(vim.fn.foldclosed(4) == 4, "zc collapses the file again")
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

    -- A folded header with control bytes also renders sanitized via foldtext().
    stream_view.draw(review, {
        mode = "unified",
        rows = { create_file_row("evil\27.md", true), create_hunk_row("evil\27.md", 1), create_added_row("evil\27.md", 1, "x") },
    }, {})
    stream_win = vim.fn.win_findbuf(review.stream.buffers.main)[1]
    vim.cmd("redraw")
    assert(not screen_row(1):find("[%z\1-\31\127]"), "folded header has no raw control character")
    assert(vim.startswith(screen_row(1), "▸ ✓ evil^[.md"), "folded header sanitized: " .. screen_row(1))

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

    -- <2-LeftMouse> expands a closed fold in place, opens an expanded diff line, and passes through outside clicks.
    draw_and_focus(folded_stream)
    local mouse_mod = require("jpr.mouse")
    local original_getmousepos = vim.fn.getmousepos
    local original_passthrough = mouse_mod.passthrough
    local passthrough_keys = {}
    mouse_mod.passthrough = function(key) passthrough_keys[#passthrough_keys + 1] = key end
    local is_double_click_ok, double_click_error = pcall(function()
        local double_click_map = vim.fn.maparg("<2-LeftMouse>", "n", false, true)
        assert(type(double_click_map) == "table" and type(double_click_map.callback) == "function", "<2-LeftMouse> mapped on stream")

        -- Double-click on closed fold (line 4: b.md viewed/folded) expands fold without leaving stream.
        assert(vim.fn.foldclosed(4) == 4, "line 4 starts folded")
        vim.fn.getmousepos = function() return { winid = stream_win, line = 4, column = 3 } end
        double_click_map.callback()
        assert(vim.fn.foldclosed(4) == -1, "<2-LeftMouse> on closed fold opens it in place")
        assert(vim.api.nvim_get_current_buf() == review.stream.buffers.main, "<2-LeftMouse> on closed fold stays in stream")

        -- Double-click outside stream window passes through <2-LeftMouse>.
        vim.fn.getmousepos = function() return { winid = review.panel.win, line = 1, column = 1 } end
        double_click_map.callback()
        assert(#passthrough_keys == 1 and passthrough_keys[1] == "<2-LeftMouse>", "outside <2-LeftMouse> passes through")

        -- Double-click on an expanded diff line opens the real file at that line.
        vim.fn.writefile({ "line1", "line2" }, worktree .. "/a.md")
        draw_and_focus({
            mode = "unified",
            rows = { create_file_row("a.md", false), create_hunk_row("a.md", 1), create_added_row("a.md", 2, "line2") },
        })
        vim.fn.getmousepos = function() return { winid = stream_win, line = 3, column = 5 } end
        double_click_map.callback()
        assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/a.md"), "<2-LeftMouse> opens a.md")
        assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "<2-LeftMouse> jumps to line 2 in a.md")
    end)
    vim.fn.getmousepos = original_getmousepos
    mouse_mod.passthrough = original_passthrough
    assert(is_double_click_ok, tostring(double_click_error))
    draw_and_focus(folded_stream)


    context.review = review
    context.folded_stream = folded_stream
    context.find_stream_buffers = find_stream_buffers
    context.wait_for_mode = wait_for_mode
    context.report_error = report_error
end
