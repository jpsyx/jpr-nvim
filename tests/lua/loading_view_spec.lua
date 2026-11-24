local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local loading = require("jpr.views.loading")
local session = require("jpr.session")
local stream_view = require("jpr.views.stream")
local diff_view = require("jpr.views.diff")
local events = require("jpr.session.events")
local fake_engine = root .. "/tests/lua/fixtures/fake_engine.sh"

local function find_line(lines, needle)
    for index, line in ipairs(lines) do
        if line:find(needle, 1, true) then
            return index, line
        end
    end
    return nil, nil
end

local function has_highlight(highlights, line_0based, group)
    for _, highlight in ipairs(highlights) do
        if highlight.line == line_0based and highlight.group == group then
            return true
        end
    end
    return false
end

local function assert_stage_1_and_2_layout()
    local stage1 = loading.create_layout_from_state({
        number = 42,
        stage = 1,
        detail = "Looking up pull request #42...",
        spinner_index = 0,
    })
    local header_idx = assert(find_line(stage1.lines, "Pull Request #42"), "stage 1 header fallback: " .. vim.inspect(stage1.lines))
    assert(has_highlight(stage1.highlights, header_idx - 1, "JprTitle"), "header uses JprTitle")
    local s1_idx, s1_line = assert(find_line(stage1.lines, "1/4  Checking out worktree..."), "stage 1 active label")
    assert(not s1_line:find("✓", 1, true) and not s1_line:find("○", 1, true), "stage 1 uses spinner frame")
    assert(has_highlight(stage1.highlights, s1_idx - 1, "JprTitle"), "active stage uses JprTitle")
    local detail_idx = assert(find_line(stage1.lines, "Looking up pull request #42..."), "stage 1 shows detail")
    assert(has_highlight(stage1.highlights, detail_idx - 1, "JprMuted"), "detail uses JprMuted")
    local s2_idx = assert(find_line(stage1.lines, "○  2/4  Starting review engine"), "stage 2 pending")
    assert(has_highlight(stage1.highlights, s2_idx - 1, "JprMuted"), "pending stage uses JprMuted")
    local footer_idx = assert(find_line(stage1.lines, "Close this tab or run :Jpr close to cancel."), "footer hint")
    assert(has_highlight(stage1.highlights, footer_idx - 1, "JprMuted"), "footer uses JprMuted")

    local stage1_next = loading.create_layout_from_state({
        number = 42,
        stage = 1,
        detail = "Looking up pull request #42...",
        spinner_index = 1,
    })
    assert(stage1_next.lines[s1_idx] ~= stage1.lines[s1_idx], "spinner_index advances spinner frame")

    local stage2 = loading.create_layout_from_state({
        number = 42,
        title = "Fix the widget",
        stage = 2,
        detail = "old detail should hide",
        spinner_index = 2,
    })
    assert(find_line(stage2.lines, "#42 Fix the widget"), "stage 2 header uses title")
    local done1_idx = assert(find_line(stage2.lines, "✓  1/4  Checking out worktree"), "stage 1 done with check")
    assert(has_highlight(stage2.highlights, done1_idx - 1, "JprViewed"), "check icon uses JprViewed")
    assert(has_highlight(stage2.highlights, done1_idx - 1, "JprMuted"), "completed label uses JprMuted")
    assert(find_line(stage2.lines, "old detail should hide") == nil, "checkout detail hidden after stage 1")
    assert(find_line(stage2.lines, "2/4  Starting review engine..."), "stage 2 active")
end

local function assert_stage_3_and_4_layout()
    local stage3 = loading.create_layout_from_state({
        number = 42,
        title = "Fix the widget",
        stage = 3,
        spinner_index = 3,
    })
    assert(find_line(stage3.lines, "✓  2/4  Starting review engine"), "stage 2 completed")
    assert(find_line(stage3.lines, "3/4  Syncing with GitHub..."), "stage 3 active")

    local stage4 = loading.create_layout_from_state({
        number = 42,
        title = "Fix the widget",
        stage = 4,
        progress = { completed = 8, total = 20, path = "src/a.rs" },
        spinner_index = 4,
    })
    assert(find_line(stage4.lines, "✓  3/4  Syncing with GitHub"), "stage 3 completed")
    assert(find_line(stage4.lines, "4/4  Computing diffs..."), "stage 4 active")
    local bar_idx = assert(
        find_line(stage4.lines, "████████░░░░░░░░░░░░  8/20 files (40%)"),
        "stage 4 renders progress bar with file count and percent: " .. vim.inspect(stage4.lines)
    )
    assert(has_highlight(stage4.highlights, bar_idx - 1, "JprViewed"), "filled progress bar uses JprViewed")
    assert(has_highlight(stage4.highlights, bar_idx - 1, "JprMuted"), "unfilled progress bar uses JprMuted")
    assert(has_highlight(stage4.highlights, bar_idx - 1, "JprTitle"), "counter uses JprTitle")
    local path_idx = assert(find_line(stage4.lines, "src/a.rs"), "stage 4 renders current file path")
    assert(has_highlight(stage4.highlights, path_idx - 1, "JprMuted"), "current file path uses JprMuted")
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

local function stub_system_and_notify()
    local original_system, original_notify = vim.system, vim.notify
    local calls, notifications = {}, {}
    vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
    end
    vim.system = function(cmd, opts, on_exit)
        local entry = { cmd = cmd, opts = opts, on_exit = on_exit }
        calls[#calls + 1] = entry
        return {
            kill = function() end,
        }
    end
    local function restore()
        vim.system = original_system
        vim.notify = original_notify
    end
    return calls, notifications, restore
end

local function assert_checkout_stderr_dedup_and_failure(calls, notifications)
    local initial_tab = vim.api.nvim_get_current_tabpage()
    local tabs_before = #vim.api.nvim_list_tabpages()
    session.open(77)
    assert(#calls == 1, "first open invokes vim.system once")
    assert(#vim.api.nvim_list_tabpages() == tabs_before + 1, "open immediately creates a new tab")
    local loading_tab = vim.api.nvim_get_current_tabpage()
    local loading_buf = vim.api.nvim_get_current_buf()
    assert(vim.bo[loading_buf].filetype == "jpr-loading", "loading tab shows loading buffer")
    local initial_lines = vim.api.nvim_buf_get_lines(loading_buf, 0, -1, false)
    assert(find_line(initial_lines, "Looking up pull request #77..."), "initial stage 1 detail")

    assert(type(calls[1].opts.stderr) == "function", "passes stderr streaming callback")
    calls[1].opts.stderr(nil, "Fetching branch pr-77...\n")
    assert(vim.wait(1000, function()
        local lines = vim.api.nvim_buf_get_lines(loading_buf, 0, -1, false)
        return find_line(lines, "Fetching branch pr-77...") ~= nil
    end), "stderr updates stage 1 detail live")

    vim.api.nvim_set_current_tabpage(initial_tab)
    session.open(77)
    assert(#calls == 1, "duplicate :Jpr open focuses pending tab instead of launching second checkout")
    assert(vim.api.nvim_get_current_tabpage() == loading_tab, "duplicate :Jpr open switches to loading tab")

    calls[1].on_exit({ code = 1, stdout = "", stderr = nil })
    assert(vim.wait(1000, function()
        return #notifications == 1
    end), "checkout failure notifies error")
    assert(notifications[1].level == vim.log.levels.ERROR, "failure level is ERROR")
    assert(notifications[1].message:find("Fetching branch pr-77...", 1, true) ~= nil, "uses buffered stderr chunks: " .. notifications[1].message)
    assert(not vim.api.nvim_tabpage_is_valid(loading_tab), "checkout failure closes loading tab")
    assert(#vim.api.nvim_list_tabpages() == tabs_before, "tab count restored after checkout failure")
end

local function assert_stream_progress_user_file_and_diff_echo(review, worktree)
    local echoed = {}
    local original_echo = vim.api.nvim_echo
    vim.api.nvim_echo = function(chunks)
        echoed[#echoed + 1] = chunks
    end

    events.on_notification(review, "streamProgress", { completed = 8, total = 20, path = "src/a.rs" }, session.show)
    assert(#echoed == 1, "streamProgress echoes when loading view is closed")
    assert(echoed[1][1][1]:find("8/20 (40%)", 1, true) ~= nil, "echo shows count and percent: " .. vim.inspect(echoed))
    assert(echoed[1][1][1]:find("src/a.rs", 1, true) ~= nil, "echo shows file path: " .. vim.inspect(echoed))
    assert(echoed[1][1][2] == "JprMuted", "echo uses JprMuted highlight")

    local main_win = require("jpr.views.main_window").find(review)
    vim.api.nvim_set_current_win(main_win)
    loading.open(review, { number = 7, title = "Fix the widget", stage = 3 })
    events.on_notification(review, "streamProgress", { completed = 8, total = 20, path = "src/a.rs" }, session.show)
    local progress_lines = vim.api.nvim_buf_get_lines(review.loading.buf, 0, -1, false)
    assert(find_line(progress_lines, "████████░░░░░░░░░░░░  8/20 files (40%)"), "streamProgress updates loading bar")
    assert(find_line(progress_lines, "src/a.rs"), "streamProgress updates loading path")

    vim.cmd.edit(vim.fn.fnameescape(worktree .. "/README.md"))
    local user_buf = vim.api.nvim_win_get_buf(main_win)
    stream_view.draw(review, { mode = "unified", rows = {} }, { only_if_free = true })
    assert(vim.api.nvim_win_get_buf(main_win) == user_buf, "only_if_free does not replace user-opened file")

    echoed = {}
    diff_view.clear(review, main_win)
    diff_view.apply(review, main_win)
    assert(
        #echoed >= 1 and echoed[1][1][1]:find("Loading diff for README.md", 1, true) ~= nil,
        "diff.apply echoes loading status: " .. vim.inspect(echoed)
    )
    assert(vim.wait(3000, function()
        return #echoed >= 2 and echoed[#echoed][1][1] == ""
    end), "diff.apply clears echo once fileDiff arrives: " .. vim.inspect(echoed))
    vim.api.nvim_echo = original_echo
end

local function assert_end_to_end_open_flow()
    jpr.setup({ binary = fake_engine })
    local calls, notifications, restore = stub_system_and_notify()
    assert_checkout_stderr_dedup_and_failure(calls, notifications)

    local worktree = vim.fn.tempname()
    vim.fn.mkdir(worktree, "p")
    vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")

    session.open(7)
    assert(#calls == 2, "second open starts checkout")
    local pr_tab = vim.api.nvim_get_current_tabpage()
    local checkout_json = vim.json.encode({
        worktree = worktree,
        repo = "octo/widgets",
        number = 7,
        title = "Fix the widget",
    })
    calls[2].on_exit({ code = 0, stdout = checkout_json .. "\n", stderr = "" })
    assert(vim.wait(3000, function()
        local active = session.by_tab[pr_tab]
        return active ~= nil and active.stream ~= nil and active.stream.layout ~= nil
    end), "checkout success starts engine, syncs, and renders stream")

    local review = session.by_tab[pr_tab]
    assert(review.loading == nil, "stream.draw closes loading state")
    assert(vim.fn.bufnr("jpr://loading/7") == -1, "loading buffer is wiped after stream.draw")

    assert_stream_progress_user_file_and_diff_echo(review, worktree)
    restore()
    session.close_current()
end

assert_stage_1_and_2_layout()
assert_stage_3_and_4_layout()
assert_loading_buffer_and_timer_lifecycle()
assert_end_to_end_open_flow()

print("loading_view_spec: ok")
