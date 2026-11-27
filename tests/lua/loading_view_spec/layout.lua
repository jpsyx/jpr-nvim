return function(context)
    local loading = require("jpr.views.loading")
    local find_line = context.find_line
    local has_highlight = context.has_highlight

local function assert_stage_1_layout()
    local stage_one_layout = loading.create_layout_from_state({
        number = 42,
        stage = 1,
        detail = "Looking up pull request #42...",
        spinner_index = 0,
    })
    local header_line_index = assert(
        find_line(stage_one_layout.lines, "Pull Request #42"),
        "stage 1 header fallback: " .. vim.inspect(stage_one_layout.lines)
    )
    assert(has_highlight(stage_one_layout.highlights, header_line_index - 1, "JprTitle"), "header uses JprTitle")
    local stage_one_line_index, stage_one_line = assert(
        find_line(stage_one_layout.lines, "1/4  Checking out worktree..."),
        "stage 1 active label"
    )
    assert(not stage_one_line:find("✓", 1, true) and not stage_one_line:find("○", 1, true), "stage 1 uses spinner frame")
    assert(has_highlight(stage_one_layout.highlights, stage_one_line_index - 1, "JprTitle"), "active stage uses JprTitle")
    local detail_line_index = assert(find_line(stage_one_layout.lines, "Looking up pull request #42..."), "stage 1 shows detail")
    assert(has_highlight(stage_one_layout.highlights, detail_line_index - 1, "JprMuted"), "detail uses JprMuted")
    local stage_two_line_index = assert(find_line(stage_one_layout.lines, "○  2/4  Starting review engine"), "stage 2 pending")
    assert(has_highlight(stage_one_layout.highlights, stage_two_line_index - 1, "JprMuted"), "pending stage uses JprMuted")
    local footer_line_index = assert(find_line(stage_one_layout.lines, "Close this tab or run :Jpr close to cancel."), "footer hint")
    assert(has_highlight(stage_one_layout.highlights, footer_line_index - 1, "JprMuted"), "footer uses JprMuted")

    local next_spinner_layout = loading.create_layout_from_state({
        number = 42,
        stage = 1,
        detail = "Looking up pull request #42...",
        spinner_index = 1,
    })
    assert(
        next_spinner_layout.lines[stage_one_line_index] ~= stage_one_layout.lines[stage_one_line_index],
        "spinner_index advances spinner frame"
    )
end

local function assert_stage_2_layout()
    local stage_two_layout = loading.create_layout_from_state({
        number = 42,
        title = "Fix the widget",
        stage = 2,
        detail = "old detail should hide",
        spinner_index = 2,
    })
    assert(find_line(stage_two_layout.lines, "#42 Fix the widget"), "stage 2 header uses title")
    local completed_stage_one_index = assert(find_line(stage_two_layout.lines, "✓  1/4  Checking out worktree"), "stage 1 done with check")
    assert(has_highlight(stage_two_layout.highlights, completed_stage_one_index - 1, "JprViewed"), "check icon uses JprViewed")
    assert(has_highlight(stage_two_layout.highlights, completed_stage_one_index - 1, "JprMuted"), "completed label uses JprMuted")
    assert(find_line(stage_two_layout.lines, "old detail should hide") == nil, "checkout detail hidden after stage 1")
    assert(find_line(stage_two_layout.lines, "2/4  Starting review engine..."), "stage 2 active")
end

local function assert_stage_3_and_4_layout()
    local stage_three_layout = loading.create_layout_from_state({
        number = 42,
        title = "Fix the widget",
        stage = 3,
        spinner_index = 3,
    })
    assert(find_line(stage_three_layout.lines, "✓  2/4  Starting review engine"), "stage 2 completed")
    assert(find_line(stage_three_layout.lines, "3/4  Syncing with GitHub..."), "stage 3 active")

    local stage_four_layout = loading.create_layout_from_state({
        number = 42,
        title = "Fix the widget",
        stage = 4,
        progress = { completed = 8, total = 20, path = "src/a.rs" },
        spinner_index = 4,
    })
    assert(find_line(stage_four_layout.lines, "✓  3/4  Syncing with GitHub"), "stage 3 completed")
    assert(find_line(stage_four_layout.lines, "4/4  Computing diffs..."), "stage 4 active")
    local bar_line_index = assert(
        find_line(stage_four_layout.lines, "████████░░░░░░░░░░░░  8/20 files (40%)"),
        "stage 4 renders progress bar with file count and percent: " .. vim.inspect(stage_four_layout.lines)
    )
    assert(has_highlight(stage_four_layout.highlights, bar_line_index - 1, "JprViewed"), "filled progress bar uses JprViewed")
    assert(has_highlight(stage_four_layout.highlights, bar_line_index - 1, "JprMuted"), "unfilled progress bar uses JprMuted")
    assert(has_highlight(stage_four_layout.highlights, bar_line_index - 1, "JprTitle"), "counter uses JprTitle")
    local path_line_index = assert(find_line(stage_four_layout.lines, "src/a.rs"), "stage 4 renders current file path")
    assert(has_highlight(stage_four_layout.highlights, path_line_index - 1, "JprMuted"), "current file path uses JprMuted")
end

local function assert_loading_buffer_and_timer_lifecycle()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    local test_session = { number = 55, tab = tab }
    loading.open(test_session, { number = 55, stage = 1, detail = "Starting..." })
    local buf = test_session.loading and test_session.loading.buf
    local timer = test_session.loading and test_session.loading.timer
    assert(buf and vim.api.nvim_buf_is_valid(buf), "loading buffer created")
    assert(vim.api.nvim_buf_get_name(buf) == "jpr://loading/55", "loading buffer name")
    assert(vim.bo[buf].filetype == "jpr-loading", "loading buffer filetype")
    assert(vim.bo[buf].bufhidden == "wipe", "loading buffer bufhidden")
    assert(vim.bo[buf].modifiable == false, "loading buffer is non-modifiable")
    assert(loading.is_loading_buffer(test_session, buf), "is_loading_buffer true for loading buf")
    local other_buf = vim.api.nvim_create_buf(false, true)
    assert(not loading.is_loading_buffer(test_session, other_buf), "is_loading_buffer false for other buf")
    vim.api.nvim_buf_delete(other_buf, { force = true })

    local win = vim.api.nvim_get_current_win()
    assert(vim.api.nvim_get_option_value("number", { win = win, scope = "local" }) == false, "number off")
    assert(vim.api.nvim_get_option_value("relativenumber", { win = win, scope = "local" }) == false, "relativenumber off")
    assert(vim.api.nvim_get_option_value("signcolumn", { win = win, scope = "local" }) == "no", "signcolumn no")
    assert(vim.api.nvim_get_option_value("cursorline", { win = win, scope = "local" }) == false, "cursorline off")
    assert(vim.api.nvim_get_option_value("wrap", { win = win, scope = "local" }) == false, "wrap off")

    loading.update(test_session, { stage = 2, title = "Updated PR" })
    local updated_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert(find_line(updated_lines, "#55 Updated PR"), "update re-renders title")
    assert(find_line(updated_lines, "2/4  Starting review engine..."), "update re-renders stage")

    loading.close(test_session)
    assert(test_session.loading == nil, "close clears session.loading")
    assert(not vim.api.nvim_buf_is_valid(buf), "close wipes loading buffer")
    assert(not loading.is_loading_buffer(test_session, buf), "is_loading_buffer false after close")
    assert(timer == nil or timer:is_closing(), "close stops and closes timer")
    if #vim.api.nvim_list_tabpages() > 1 then
        vim.cmd("tabclose")
    end
end


    assert_stage_1_layout()
    assert_stage_2_layout()
    assert_stage_3_and_4_layout()
    assert_loading_buffer_and_timer_lifecycle()
end
