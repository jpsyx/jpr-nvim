-- Sections 1-7: unified thread signs, navigation, expand, split routing, and cleanup.
local function test_unified_signs_and_navigation(context)
    local buf, win = context.buf, context.win
    assert(vim.wait(3000, function()
        return #context.get_thread_marks(buf) > 0
    end), "thread extmark is drawn on README.md")

    local marks = context.get_thread_marks(buf)
    assert(#marks == 1, "expected 1 compact thread mark, got " .. #marks)
    assert(marks[1][2] == 1, "thread mark is on 0-based row 1 (displayLine 2): " .. marks[1][2])
    assert(marks[1][4].sign_text == "💬", "expected published sign: " .. vim.inspect(marks[1][4]))
    assert(marks[1][4].sign_hl_group == "JprThreadPublished", vim.inspect(marks[1][4]))
    assert(marks[1][4].virt_text_pos == "eol", vim.inspect(marks[1][4]))
    assert(marks[1][4].virt_lines == nil, "threads start collapsed without virt_lines")
    assert(marks[1][4].virt_text[1][1]:find("@alice: nit: rename this", 1, true), vim.inspect(marks[1][4]))
    assert(vim.wo[win].signcolumn == "yes", "signcolumn is enabled on diff window with threads")

    for _, lhs in ipairs({ "]t", "[t", "gc", "gC", "gf", "gt" }) do
        assert(context.helpers.has_buf_map(buf, "n", lhs), "expected buffer key " .. lhs .. " on diff buffer")
    end

    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    context.session.jump_thread_current(1)
    assert(vim.api.nvim_win_get_cursor(win)[1] == 2, "jump_thread_current(1) moves to line 2")

    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    context.session.jump_thread_current(-1)
    assert(vim.api.nvim_win_get_cursor(win)[1] == 2, "jump_thread_current(-1) moves to line 2")

    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    context.helpers.press_key("]t")
    assert(vim.api.nvim_win_get_cursor(win)[1] == 2, "]t keymap moves to line 2")

    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    context.helpers.press_key("[t")
    assert(vim.api.nvim_win_get_cursor(win)[1] == 2, "[t keymap moves to line 2")
end

local function test_unified_expand_and_collapse(context)
    local buf = context.buf
    context.session.expand_current()
    assert(vim.wait(3000, function()
        local current_marks = context.get_thread_marks(buf)
        return #current_marks == 2 and (current_marks[1][4].virt_lines ~= nil or current_marks[2][4].virt_lines ~= nil)
    end), "expanded thread draws virt_lines: " .. vim.inspect(context.get_thread_marks(buf)))

    local expanded_marks = context.get_thread_marks(buf)
    local virt_mark, sign_mark
    for _, mark in ipairs(expanded_marks) do
        if mark[4].virt_lines then
            virt_mark = mark
        else
            sign_mark = mark
        end
    end
    assert(virt_mark and sign_mark, vim.inspect(expanded_marks))
    assert(sign_mark[4].virt_text == nil, "expanded mode hides compact EOL virt_text")
    local expanded_text = virt_mark[4].virt_lines[1][1][1] .. "\n" .. virt_mark[4].virt_lines[2][1][1]
    assert(expanded_text:find("@alice", 1, true) and expanded_text:find("nit: rename this", 1, true), expanded_text)

    context.session.expand_current()
    assert(vim.wait(3000, function()
        local current_marks = context.get_thread_marks(buf)
        return #current_marks == 1 and current_marks[1][4].virt_text ~= nil and current_marks[1][4].virt_lines == nil
    end), "collapsing restores compact EOL virt_text")
end

local function open_split_base_window(context)
    context.session.toggle_view()
    assert(context.view_mode.get() == "split", "toggled to split")
    assert(vim.wait(3000, function()
        return context.find_base_window(context.review.tab) ~= nil
    end), "base window opens in split mode")

    local base_win = context.find_base_window(context.review.tab)
    local base_buf = vim.api.nvim_win_get_buf(base_win)
    local initial_base_signcolumn = vim.api.nvim_get_option_value("signcolumn", { win = base_win, scope = "local" })
    assert(vim.b[base_buf].jpr_base_path == "README.md", "base buffer records jpr_base_path")
    for _, lhs in ipairs({ "]t", "[t", "gc", "gC", "gf", "gt" }) do
        assert(context.helpers.has_buf_map(base_buf, "n", lhs), "expected buffer key " .. lhs .. " on base buffer")
    end
    assert(#context.get_thread_marks(context.buf) == 1 and context.get_thread_marks(context.buf)[1][2] == 1, "RIGHT thread stays on file buffer")
    assert(#context.get_thread_marks(base_buf) == 0, "no LEFT threads on base buffer for RIGHT-only fixture")
    return base_win, base_buf, initial_base_signcolumn
end

local function test_split_threads_changed_routing(context, base_win, base_buf)
    context.mock_state.install_file_diff_mock()

    vim.api.nvim_set_current_win(base_win)
    vim.api.nvim_win_set_cursor(base_win, { 2, 0 })

    local calls_before = context.mock_state.file_diff_calls
    context.session.on_notification(context.review, "event", { type = "threadsChanged", view = context.review.view })
    assert(vim.wait(3000, function()
        return context.mock_state.file_diff_calls > calls_before and #context.get_thread_marks(base_buf) == 1
    end), "threadsChanged redraws split diff and places LEFT thread on base buffer")

    assert(context.find_base_window(context.review.tab) == base_win, "threadsChanged preserves split base_win handle")
    assert(vim.api.nvim_get_current_win() == base_win, "threadsChanged preserves focus on base_win")
    assert(vim.api.nvim_win_get_cursor(base_win)[1] == 2, "threadsChanged preserves cursor on base_win")

    local base_marks = context.get_thread_marks(base_buf)
    local file_marks = context.get_thread_marks(context.buf)
    assert(#base_marks == 1 and base_marks[1][2] == 0, "LEFT thread drawn on base line 1 (row 0): " .. vim.inspect(base_marks))
    assert(vim.trim(base_marks[1][4].sign_text) == "✎", "LEFT draft thread has draft sign: " .. vim.inspect(base_marks[1][4].sign_text))
    assert(vim.wo[base_win].signcolumn == "yes", "base window enables signcolumn when LEFT threads exist")
    assert(#file_marks == 1 and file_marks[1][2] == 1, "RIGHT thread drawn on head line 2 (row 1)")
    assert(vim.wo[context.win].signcolumn == "yes", "file window enables signcolumn when RIGHT threads exist")
end

local function test_split_expand_and_navigation(context, base_win, base_buf)
    context.session.expand_current()
    assert(context.find_base_window(context.review.tab) == base_win, "expand preserves split base_win handle")
    assert(vim.api.nvim_get_current_win() == base_win, "expand preserves focus on base_win")
    assert(vim.api.nvim_win_get_cursor(base_win)[1] == 2, "expand preserves cursor on base_win")
    assert(vim.wait(3000, function()
        local current_marks = context.get_thread_marks(base_buf)
        return #current_marks == 2 and (current_marks[1][4].virt_lines ~= nil or current_marks[2][4].virt_lines ~= nil)
    end), "expand draws virt_lines on split base_buf")
    context.session.expand_current()
    assert(vim.wait(3000, function()
        local current_marks = context.get_thread_marks(base_buf)
        return #current_marks == 1 and current_marks[1][4].virt_text ~= nil and current_marks[1][4].virt_lines == nil
    end), "second expand_current collapses virt_lines in split mode")
    assert(vim.api.nvim_get_current_win() == base_win, "collapse preserves focus on base_win")
    assert(vim.api.nvim_win_get_cursor(base_win)[1] == 2, "collapse preserves cursor on base_win")

    assert(#context.threads_view.threads_at_cursor(context.review, base_buf, 1) == 1, "threads_at_cursor finds LEFT thread on base line 1")
    assert(context.threads_view.threads_at_cursor(context.review, base_buf, 1)[1].threadId == "T_LEFT")
    assert(#context.threads_view.threads_at_cursor(context.review, context.buf, 2) == 1, "threads_at_cursor finds RIGHT thread on head line 2")
    assert(context.threads_view.threads_at_cursor(context.review, context.buf, 2)[1].threadId == "T_RIGHT")

    vim.api.nvim_win_set_cursor(base_win, { 2, 0 })
    context.session.jump_thread_current(-1)
    assert(vim.api.nvim_win_get_cursor(base_win)[1] == 1, "[t in base window jumps to LEFT thread on line 1")
end

local function test_empty_threads_restores_signcolumn(context, base_win, base_buf, initial_base_signcolumn)
    context.mock_state.threads = {}
    local calls_before = context.mock_state.file_diff_calls
    context.session.on_notification(context.review, "event", { type = "threadsChanged", view = context.review.view })
    assert(vim.wait(3000, function()
        return context.mock_state.file_diff_calls > calls_before
            and #context.get_thread_marks(context.buf) == 0
            and #context.get_thread_marks(base_buf) == 0
    end), "threadsChanged clears thread marks when diff.threads is empty")
    assert(
        vim.api.nvim_get_option_value("signcolumn", { win = context.win, scope = "local" }) == "no",
        "file window restores signcolumn when threads become empty"
    )
    assert(
        vim.api.nvim_get_option_value("signcolumn", { win = base_win, scope = "local" }) == initial_base_signcolumn,
        "base window restores signcolumn when threads become empty"
    )
end

local function test_manual_base_close_and_clear_cleanup(context, base_win, base_buf)
    context.mock_state.threads = { context.mock_state.left_thread, context.mock_state.right_thread }
    local calls_before = context.mock_state.file_diff_calls
    context.session.on_notification(context.review, "event", { type = "threadsChanged", view = context.review.view })
    assert(vim.wait(3000, function()
        return context.mock_state.file_diff_calls > calls_before and #context.get_thread_marks(base_buf) == 1
    end), "threads restored before manual base_win close")
    assert(vim.api.nvim_get_option_value("signcolumn", { win = context.win, scope = "local" }) == "yes")

    vim.api.nvim_win_close(base_win, true)
    assert(not vim.api.nvim_buf_is_valid(base_buf), "base_buf is wiped when base_win closes")
    context.diff_view.clear(context.review, context.win)
    assert(
        vim.api.nvim_get_option_value("signcolumn", { win = context.win, scope = "local" }) == "no",
        "M.clear restores file window signcolumn"
    )
    assert(#context.threads_view.threads_at_cursor(context.review, context.buf, 2) == 0, "M.clear clears file buffer threads")
    assert(#context.threads_view.threads_at_cursor(context.review, base_buf, 1) == 0, "M.clear clears wiped base buffer threads")

    context.diff_view.reconcile(context.review)
    assert(vim.wait(3000, function()
        return context.find_base_window(context.review.tab) ~= nil
    end), "reconcile re-opens split base window")
    local reopened_base_win = context.find_base_window(context.review.tab)
    local reopened_base_buf = vim.api.nvim_win_get_buf(reopened_base_win)
    assert(vim.wait(3000, function()
        return #context.get_thread_marks(reopened_base_buf) == 1
    end), "reopened base buffer draws thread")
    vim.api.nvim_win_close(reopened_base_win, true)
end

return function(context)
    test_unified_signs_and_navigation(context)
    test_unified_expand_and_collapse(context)
    local base_win, base_buf, initial_base_signcolumn = open_split_base_window(context)
    test_split_threads_changed_routing(context, base_win, base_buf)
    test_split_expand_and_navigation(context, base_win, base_buf)
    test_empty_threads_restores_signcolumn(context, base_win, base_buf, initial_base_signcolumn)
    test_manual_base_close_and_clear_cleanup(context, base_win, base_buf)
end
