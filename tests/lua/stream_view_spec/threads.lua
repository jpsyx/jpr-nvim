return function(context)
    local helpers = context.helpers
    local worktree = context.worktree
    local create_file_row = context.create_file_row
    local create_hunk_row = context.create_hunk_row
    local create_added_row = context.create_added_row

    local session = require("jpr.session")
    local stream_view = require("jpr.views.stream")

    local stream_namespace = vim.api.nvim_create_namespace("jpr-stream")
    local function get_eol_marks(buf)
        local marks = vim.api.nvim_buf_get_extmarks(buf, stream_namespace, 0, -1, { details = true })
        return vim.tbl_filter(function(mark)
            return mark[4] and mark[4].virt_text_pos == "eol"
        end, marks)
    end

    -- Stream buffers bind comment/thread keys and support ]t/[t, threads_at_cursor, and anchor_at_range.
    session.start({ worktree = worktree, repo = "octo/widgets", number = 10 })
    local threaded_session = session.current()
    assert(vim.wait(3000, function()
        return threaded_session.stream ~= nil and threaded_session.stream.layout ~= nil
    end), "threaded stream opens")

    local main_buf = threaded_session.stream.buffers.main
    for _, lhs in ipairs({ "]t", "[t", "gc", "gC", "gf", "gt" }) do
        assert(helpers.has_buf_map(main_buf, "n", lhs), "expected buffer key " .. lhs .. " on stream buffer")
    end

    local file_thread = {
        threadId = "T_FILE",
        anchor = { file = "a.md", kind = "file", side = "RIGHT" },
        displayLine = 0,
        kind = "draft",
        state = "open",
        firstAuthor = "bob",
        snippet = "file comment",
        messages = { { id = "M1", author = "bob", body = "file comment", sync = "draft" } },
    }
    local folded_thread = {
        threadId = "T_FOLDED",
        anchor = { file = "b.md", kind = "line", side = "RIGHT", start = 1, ["end"] = 1 },
        displayLine = 1,
        kind = "published",
        state = "open",
        firstAuthor = "eve",
        snippet = "hidden in fold",
        messages = { { id = "M2", author = "eve", body = "hidden in fold", sync = "published" } },
    }
    local c_thread = {
        threadId = "T_C",
        anchor = { file = "c.md", kind = "line", side = "RIGHT", start = 1, ["end"] = 1 },
        displayLine = 1,
        kind = "published",
        state = "open",
        firstAuthor = "alice",
        snippet = "visible thread",
        messages = { { id = "M3", author = "alice", body = "visible thread", sync = "published" } },
    }
    local unified_threaded_stream = {
        mode = "unified",
        rows = {
            create_file_row("a.md", false),
            { kind = "thread", path = "a.md", thread = file_thread, target = 1 },
            create_hunk_row("a.md", 1),
            { kind = "line", path = "a.md", left = { line = 1, text = "keep", change = "context", words = {} }, right = { line = 1, text = "keep", change = "context", words = {} }, target = 1 },
            { kind = "line", path = "a.md", left = { line = 2, text = "old", change = "removed", words = {} }, target = 2 },
            { kind = "line", path = "a.md", right = { line = 2, text = "new", change = "added", words = {} }, target = 2 },
            create_file_row("b.md", true),
            create_hunk_row("b.md", 1),
            { kind = "line", path = "b.md", right = { line = 1, text = "b1", change = "added", words = {} }, target = 1, threads = { folded_thread } },
            create_file_row("c.md", false),
            create_hunk_row("c.md", 1),
            { kind = "line", path = "c.md", right = { line = 1, text = "c1", change = "added", words = {} }, target = 1, threads = { c_thread } },
        },
    }

    stream_view.draw(threaded_session, unified_threaded_stream, {})
    local threaded_win = vim.fn.win_findbuf(threaded_session.stream.buffers.main)[1]
    vim.api.nvim_set_current_win(threaded_win)
    assert(#get_eol_marks(main_buf) == 2, "compact stream draws EOL extmarks on threaded lines")

    -- ]t and [t skip threads inside folded viewed files (b.md).
    vim.api.nvim_win_set_cursor(threaded_win, { 1, 0 })
    stream_view.jump(threaded_session, "threads", 1)
    assert(vim.api.nvim_win_get_cursor(threaded_win)[1] == 2, "]t lands on file thread row 2")
    stream_view.jump(threaded_session, "threads", 1)
    assert(vim.api.nvim_win_get_cursor(threaded_win)[1] == 12, "]t skips folded b.md thread and lands on line 12: " .. vim.api.nvim_win_get_cursor(threaded_win)[1])
    stream_view.jump(threaded_session, "threads", -1)
    assert(vim.api.nvim_win_get_cursor(threaded_win)[1] == 2, "[t skips folded b.md thread back to line 2")

    -- threads_at_cursor finds threads on thread row and on line row.
    vim.api.nvim_win_set_cursor(threaded_win, { 2, 0 })
    local at_thread_row = stream_view.threads_at_cursor(threaded_session)
    assert(#at_thread_row == 1 and at_thread_row[1].threadId == "T_FILE", vim.inspect(at_thread_row))
    vim.api.nvim_win_set_cursor(threaded_win, { 12, 0 })
    local at_line_row = stream_view.threads_at_cursor(threaded_session)
    assert(#at_line_row == 1 and at_line_row[1].threadId == "T_C", vim.inspect(at_line_row))
    vim.api.nvim_win_set_cursor(threaded_win, { 4, 0 })
    assert(#stream_view.threads_at_cursor(threaded_session) == 0, "no threads on line 4")

    -- anchor_at_range in unified mode: thread row, context line, removed line, valid ranges, and invalid ranges.
    assert(vim.deep_equal(stream_view.anchor_at_range(threaded_session, threaded_win, 2, 2), { file = "a.md", kind = "file", side = "RIGHT" }))
    assert(vim.deep_equal(stream_view.anchor_at_range(threaded_session, threaded_win, 4, 4), { file = "a.md", kind = "line", side = "RIGHT", start = 1, ["end"] = 1 }))
    assert(vim.deep_equal(stream_view.anchor_at_range(threaded_session, threaded_win, 5, 5), { file = "a.md", kind = "line", side = "LEFT", start = 2, ["end"] = 2 }))
    assert(vim.deep_equal(stream_view.anchor_at_range(threaded_session, threaded_win, 4, 5), { file = "a.md", kind = "range", side = "LEFT", start = 1, ["end"] = 2 }))
    assert(vim.deep_equal(stream_view.anchor_at_range(threaded_session, threaded_win, 5, 4), { file = "a.md", kind = "range", side = "LEFT", start = 1, ["end"] = 2 }))
    assert(stream_view.anchor_at_range(threaded_session, threaded_win, 4, 6) == nil, "mixed context+removed+added unified range is rejected")
    assert(stream_view.anchor_at_range(threaded_session, threaded_win, 5, 6) == nil, "mixed removed+added unified range is rejected")
    assert(stream_view.anchor_at_range(threaded_session, threaded_win, 1, 2) == nil, "range crossing file header and thread row is rejected")
    assert(stream_view.anchor_at_range(threaded_session, threaded_win, 3, 4) == nil, "range crossing hunk row is rejected")
    assert(stream_view.anchor_at_range(threaded_session, threaded_win, 2, 4) == nil, "range crossing thread and hunk rows is rejected")
    assert(stream_view.anchor_at_range(threaded_session, threaded_win, 6, 12) == nil, "cross-file range is rejected")

    -- Valid RIGHT unified range (with reversed line1 > line2), note row rejection, and adjacent cross-file rejection.
    stream_view.draw(threaded_session, {
        mode = "unified",
        rows = {
            create_file_row("a.md", false),
            create_hunk_row("a.md", 1),
            create_added_row("a.md", 1, "one"),
            create_added_row("a.md", 2, "two"),
            { kind = "note", path = "a.md", text = "summary note" },
            create_added_row("b.md", 1, "other file"),
        },
    }, {})
    assert(vim.deep_equal(stream_view.anchor_at_range(threaded_session, threaded_win, 3, 4), { file = "a.md", kind = "range", side = "RIGHT", start = 1, ["end"] = 2 }))
    assert(vim.deep_equal(stream_view.anchor_at_range(threaded_session, threaded_win, 4, 3), { file = "a.md", kind = "range", side = "RIGHT", start = 1, ["end"] = 2 }))
    assert(stream_view.anchor_at_range(threaded_session, threaded_win, 5, 5) == nil, "note row has no anchor")
    assert(stream_view.anchor_at_range(threaded_session, threaded_win, 4, 5) == nil, "range crossing note row is rejected")
    assert(stream_view.anchor_at_range(threaded_session, threaded_win, 4, 6) == nil, "cross-file range is rejected")

    stream_view.draw(threaded_session, {
        mode = "unified",
        rows = { create_added_row("a.md", 1, "a1"), create_added_row("b.md", 1, "b1") },
    }, {})
    assert(stream_view.anchor_at_range(threaded_session, threaded_win, 1, 2) == nil, "adjacent cross-file line rows are rejected")

    -- anchor_at_range and threads_at_cursor in split mode: left_win yields LEFT, main win yields RIGHT.
    local left_split_thread = {
        threadId = "T_SPLIT_LEFT",
        anchor = { file = "a.md", kind = "line", side = "LEFT", start = 2, ["end"] = 2 },
        displayLine = 2,
        kind = "published",
        state = "open",
        firstAuthor = "carol",
        snippet = "left side comment",
        messages = { { id = "M4", author = "carol", body = "left side comment", sync = "published" } },
    }
    local split_threaded_stream = {
        mode = "split",
        rows = {
            create_file_row("a.md", false),
            create_hunk_row("a.md", 1),
            { kind = "line", path = "a.md", left = { line = 1, text = "keep", change = "context", words = {} }, right = { line = 1, text = "keep", change = "context", words = {} }, target = 1 },
            { kind = "line", path = "a.md", left = { line = 2, text = "old", change = "removed", words = {} }, right = { line = 2, text = "new", change = "added", words = {} }, target = 2, threads = { left_split_thread, c_thread } },
            { kind = "line", path = "a.md", right = { line = 3, text = "extra", change = "added", words = {} }, target = 3 },
        },
    }
    stream_view.draw(threaded_session, split_threaded_stream, {})
    local split_left_win = threaded_session.stream.left_win
    local split_main_win = vim.fn.win_findbuf(threaded_session.stream.buffers.main)[1]
    assert(split_left_win and vim.api.nvim_win_is_valid(split_left_win), "split left_win opened")
    for _, lhs in ipairs({ "]t", "[t", "gc", "gC", "gf", "gt" }) do
        assert(helpers.has_buf_map(threaded_session.stream.buffers.left, "n", lhs), "expected buffer key " .. lhs .. " on split left stream buffer")
    end
    assert(#get_eol_marks(threaded_session.stream.buffers.left) == 1, "split left buffer gets LEFT eol mark")
    assert(#get_eol_marks(threaded_session.stream.buffers.main) == 1, "split main buffer gets RIGHT eol mark")

    local left_win_threads = stream_view.threads_at_cursor(threaded_session, 4, split_left_win)
    assert(#left_win_threads == 1 and left_win_threads[1].threadId == "T_SPLIT_LEFT", vim.inspect(left_win_threads))
    local main_win_threads = stream_view.threads_at_cursor(threaded_session, 4, split_main_win)
    assert(#main_win_threads == 1 and main_win_threads[1].threadId == "T_C", vim.inspect(main_win_threads))
    vim.api.nvim_set_current_win(split_left_win)
    vim.api.nvim_win_set_cursor(split_left_win, { 4, 0 })
    local cursor_left_threads = stream_view.threads_at_cursor(threaded_session)
    assert(#cursor_left_threads == 1 and cursor_left_threads[1].threadId == "T_SPLIT_LEFT", vim.inspect(cursor_left_threads))
    vim.api.nvim_set_current_win(split_main_win)
    vim.api.nvim_win_set_cursor(split_main_win, { 4, 0 })
    local cursor_main_threads = stream_view.threads_at_cursor(threaded_session)
    assert(#cursor_main_threads == 1 and cursor_main_threads[1].threadId == "T_C", vim.inspect(cursor_main_threads))

    assert(vim.deep_equal(stream_view.anchor_at_range(threaded_session, split_left_win, 3, 3), { file = "a.md", kind = "line", side = "LEFT", start = 1, ["end"] = 1 }))
    assert(vim.deep_equal(stream_view.anchor_at_range(threaded_session, split_left_win, 3, 4), { file = "a.md", kind = "range", side = "LEFT", start = 1, ["end"] = 2 }))
    assert(vim.deep_equal(stream_view.anchor_at_range(threaded_session, split_left_win, 4, 3), { file = "a.md", kind = "range", side = "LEFT", start = 1, ["end"] = 2 }))
    local filler_anchor = stream_view.anchor_at_range(threaded_session, split_left_win, 5, 5)
    assert(filler_anchor == nil, "filler line in left_win has no LEFT anchor: " .. vim.inspect(filler_anchor))
    assert(stream_view.anchor_at_range(threaded_session, split_left_win, 4, 5) == nil, "split left range crossing filler line is rejected")
    assert(stream_view.anchor_at_range(threaded_session, split_left_win, 3, 5) == nil, "split left range ending on filler line is rejected")
    assert(vim.deep_equal(stream_view.anchor_at_range(threaded_session, split_main_win, 3, 3), { file = "a.md", kind = "line", side = "RIGHT", start = 1, ["end"] = 1 }))
    assert(vim.deep_equal(stream_view.anchor_at_range(threaded_session, split_main_win, 4, 5), { file = "a.md", kind = "range", side = "RIGHT", start = 2, ["end"] = 3 }))
    assert(vim.deep_equal(stream_view.anchor_at_range(threaded_session, split_main_win, 5, 4), { file = "a.md", kind = "range", side = "RIGHT", start = 2, ["end"] = 3 }))

    vim.api.nvim_set_current_win(split_main_win)
    vim.api.nvim_win_set_cursor(split_main_win, { 1, 0 })
    session.jump_thread_current(1)
    assert(vim.api.nvim_win_get_cursor(split_main_win)[1] == 4, "session.jump_thread_current jumps to thread in stream")

    threaded_session.threads_expanded = true
    stream_view.draw(threaded_session, split_threaded_stream, {})
    assert(#get_eol_marks(threaded_session.stream.buffers.main) == 0, "expanded stream clears EOL extmarks")
    local split_left_lines = vim.api.nvim_buf_get_lines(threaded_session.stream.buffers.left, 0, -1, false)
    local split_main_lines = vim.api.nvim_buf_get_lines(threaded_session.stream.buffers.main, 0, -1, false)
    assert(#split_left_lines == #split_main_lines, "expanded split buffers have identical line counts")
    assert(split_main_lines[5]:find("  │ @alice", 1, true), vim.inspect(split_main_lines))

    -- File thread rows remain visible to threads_at_cursor in both split windows.
    threaded_session.threads_expanded = false
    stream_view.draw(threaded_session, {
        mode = "split",
        rows = {
            create_file_row("a.md", false),
            { kind = "thread", path = "a.md", thread = file_thread, target = 1 },
            create_hunk_row("a.md", 1),
            { kind = "line", path = "a.md", left = { line = 1, text = "old", change = "removed", words = {} }, target = 1 },
        },
    }, {})
    assert(stream_view.threads_at_cursor(threaded_session, 2, split_left_win)[1].threadId == "T_FILE", "file thread returned in split left_win")
    assert(stream_view.threads_at_cursor(threaded_session, 2, split_main_win)[1].threadId == "T_FILE", "file thread returned in split main win")
    assert(stream_view.anchor_at_range(threaded_session, split_main_win, 4, 4) == nil, "right filler line has no RIGHT anchor")

    session.close_current()
end
