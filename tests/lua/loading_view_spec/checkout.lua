return function(context)
    local jpr = require("jpr")
    local loading = require("jpr.views.loading")
    local session = require("jpr.session")
    local stream_view = require("jpr.views.stream")
    local diff_view = require("jpr.views.diff")
    local events = require("jpr.session.events")
    local fake_engine = context.fake_engine
    local find_line = context.find_line

local function stub_system_and_notify()
    local original_system = vim.system
    local jpr_notify = require("jpr.notify")
    local calls, notifications = {}, {}
    jpr_notify.set_listener(function(_, message, level)
        notifications[#notifications + 1] = { message = "jpr: " .. message, level = level }
    end)
    vim.system = function(cmd, opts, on_exit)
        local entry = { cmd = cmd, opts = opts, on_exit = on_exit }
        calls[#calls + 1] = entry
        return {
            kill = function() end,
        }
    end
    local function restore()
        vim.system = original_system
        jpr_notify.set_listener(nil)
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
    local notify = require("jpr.notify")
    notify.clear()
    local echoed = {}
    local original_echo = vim.api.nvim_echo
    vim.api.nvim_echo = function(chunks)
        echoed[#echoed + 1] = chunks
    end

    events.on_notification(review, "streamProgress", { completed = 8, total = 20, path = "src/a.rs" }, session.show)
    assert(#echoed == 0, "streamProgress uses top-right progress toast instead of nvim_echo")
    local progress_toasts = notify.get_toasts()
    assert(#progress_toasts == 1, "streamProgress opens a progress toast when loading view is closed")
    local toast_text = table.concat(vim.api.nvim_buf_get_lines(progress_toasts[1].buf, 0, -1, false), "\n")
    assert(toast_text:find("8/20 (40%)", 1, true) ~= nil, "toast shows count and percent: " .. toast_text)
    assert(toast_text:find("src/a.rs", 1, true) ~= nil, "toast shows file path: " .. toast_text)
    events.on_notification(review, "streamProgress", { completed = 20, total = 20, path = "src/z.rs" }, session.show)
    assert(#notify.get_toasts() == 0, "streamProgress toast closes on completion")

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
    assert(vim.wait(3000, function()
        return review.diff and review.diff.applied[main_win] ~= nil
    end), "diff.apply completes without nvim_echo")
    assert(#echoed == 0, "diff.apply uses progress toast rather than nvim_echo")
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

local function assert_spawn_failure_cleans_up_loading_tab_and_allows_retry()
    jpr.setup({ binary = fake_engine })
    local original_system = vim.system
    local jpr_notify = require("jpr.notify")
    local notifications, spawn_attempts = {}, 0
    jpr_notify.set_listener(function(_, message, level)
        notifications[#notifications + 1] = { message = "jpr: " .. message, level = level }
    end)
    vim.system = function()
        spawn_attempts = spawn_attempts + 1
        if spawn_attempts == 1 then
            error("ENOENT: failed to spawn")
        end
        return { kill = function() end }
    end

    local tabs_before = #vim.api.nvim_list_tabpages()
    local is_ok = pcall(session.open, 88)
    assert(is_ok, "vim.system throw must be caught by session.open")
    assert(#vim.api.nvim_list_tabpages() == tabs_before, "spawn failure closes loading tab")
    assert(vim.fn.bufnr("jpr://loading/88") == -1, "spawn failure wipes loading buffer")
    assert(#notifications == 1 and notifications[1].level == vim.log.levels.ERROR, "spawn failure notifies ERROR")
    assert(notifications[1].message:find("ENOENT: failed to spawn", 1, true) ~= nil, "reports spawn error: " .. notifications[1].message)

    session.open(88)
    assert(spawn_attempts == 2, "pending state cleared so retry launches a new checkout")
    session.close_current()
    vim.system = original_system
    require("jpr.notify").set_listener(nil)
end

local function assert_manual_tabclose_kills_pending_checkout_process()
    jpr.setup({ binary = fake_engine })
    local original_system, original_notify = vim.system, vim.notify
    local killed_signals, spawn_count = {}, 0
    vim.notify = function() end
    vim.system = function()
        spawn_count = spawn_count + 1
        return {
            kill = function(_, signal)
                killed_signals[#killed_signals + 1] = signal
            end,
        }
    end

    session.open(89)
    assert(spawn_count == 1, "initial checkout spawned")
    vim.cmd("tabclose")
    assert(#killed_signals == 1, "manual :tabclose immediately kills in-flight checkout subprocess")
    assert(vim.fn.bufnr("jpr://loading/89") == -1, "manual :tabclose wipes loading buffer")

    session.open(89)
    assert(spawn_count == 2, "manual :tabclose cleared pending state so reopen launches checkout")
    session.close_current()
    vim.system = original_system
    require("jpr.notify").set_listener(nil)
end

local function assert_tcd_failure_cleans_up_loading_tab()
    jpr.setup({ binary = fake_engine })
    local calls, notifications, restore = stub_system_and_notify()
    local tabs_before = #vim.api.nvim_list_tabpages()
    session.open(90)
    local missing_worktree_json = vim.json.encode({
        worktree = vim.fn.tempname() .. "/missing-worktree-dir",
        repo = "octo/widgets",
        number = 90,
        title = "Broken worktree",
    })
    calls[1].on_exit({ code = 0, stdout = missing_worktree_json .. "\n", stderr = "" })
    assert(vim.wait(1000, function()
        return #notifications >= 1
    end), "tcd failure notifies error")
    assert(notifications[1].level == vim.log.levels.ERROR, "tcd failure level is ERROR")
    assert(#vim.api.nvim_list_tabpages() == tabs_before, "tcd failure closes loading tab")
    assert(vim.fn.bufnr("jpr://loading/90") == -1, "tcd failure wipes loading buffer")
    assert(next(session.by_tab) == nil, "tcd failure does not leave a registered session")
    restore()
end

local function assert_user_file_in_pending_tab_is_preserved()
    jpr.setup({ binary = fake_engine })
    local calls, _, restore = stub_system_and_notify()
    local worktree = vim.fn.tempname()
    vim.fn.mkdir(worktree, "p")
    vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")
    vim.fn.writefile({ "keep my notes" }, worktree .. "/notes.txt")

    session.open(91)
    local pr_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd.edit(vim.fn.fnameescape(worktree .. "/notes.txt"))
    local user_buf = vim.api.nvim_get_current_buf()
    local checkout_json = vim.json.encode({
        worktree = worktree,
        repo = "octo/widgets",
        number = 91,
        title = "User file test",
    })
    calls[1].on_exit({ code = 0, stdout = checkout_json .. "\n", stderr = "" })
    assert(vim.wait(3000, function()
        local active = session.by_tab[pr_tab]
        return active ~= nil and active.stream ~= nil and active.stream.layout ~= nil
    end), "session started and synced after user opened file in pending tab")

    local main_win = require("jpr.views.main_window").find(session.by_tab[pr_tab])
    assert(vim.api.nvim_win_get_buf(main_win) == user_buf, "user-opened file in pending tab is preserved across stage 2 and stream")
    assert(vim.fn.bufnr("jpr://loading/91") == -1, "loading buffer was not reopened over user file")
    restore()
    session.close_current()
end


    assert_end_to_end_open_flow()
    assert_spawn_failure_cleans_up_loading_tab_and_allows_retry()
    assert_manual_tabclose_kills_pending_checkout_process()
    assert_tcd_failure_cleans_up_loading_tab()
    assert_user_file_in_pending_tab_is_preserved()
end
