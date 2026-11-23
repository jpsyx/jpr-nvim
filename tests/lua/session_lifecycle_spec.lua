local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local session = require("jpr.session")
local fake_engine = root .. "/tests/lua/fixtures/fake_engine.sh"
local crashing_engine = root .. "/tests/lua/fixtures/crashing_engine.sh"

local messages = {}
local notifications = {}
vim.notify = function(message, level)
    messages[#messages + 1] = message
    notifications[#notifications + 1] = { message = message, level = level }
end
local function clear_notifications()
    messages = {}
    notifications = {}
end
local function wait_for_message(text)
    return vim.wait(3000, function()
        for _, message in ipairs(messages) do
            if message:find(text, 1, true) then
                return true
            end
        end
        return false
    end)
end
local function find_notification(text, expected_level)
    for _, entry in ipairs(notifications) do
        local does_match_level = expected_level == nil or entry.level == expected_level
        if does_match_level and entry.message:find(text, 1, true) then
            return entry
        end
    end
    return nil
end

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
local function start_pr(number)
    session.start({ worktree = worktree, repo = "octo/widgets", number = number })
    return vim.api.nvim_get_current_tabpage()
end
local function sessions_for(number)
    return #vim.tbl_filter(function(existing)
        return existing.number == number
    end, vim.tbl_values(session.by_tab))
end

-- An engine that dies at startup forgets its session, so :Jpr open starts over.
local function wait_for_exit(dead)
    return vim.wait(3000, function()
        return dead.client == nil
    end)
end
local function tab_count()
    return #vim.api.nvim_list_tabpages()
end
local function wait_for_sync(live)
    return vim.wait(3000, function()
        return live.view.pr ~= nil
    end)
end

jpr.setup({ binary = crashing_engine })
local tabs_before = tab_count()
local crashed_tab = start_pr(7)
local crashed = session.by_tab[crashed_tab]
assert(wait_for_exit(crashed) and session.by_tab[crashed_tab] == nil, "a crashed engine unregisters its session")
assert(#messages == 1 and messages[1]:find("gh: not logged in", 1, true), "one error, with the engine's stderr: " .. vim.inspect(messages))
assert(vim.fn.bufnr("jpr://panel/7") == -1, "the dead session's panel buffer is gone")
assert(not vim.api.nvim_tabpage_is_valid(crashed_tab) and tab_count() == tabs_before, "a failed start leaves no stray tab")
clear_notifications()
session.sync_current()
assert(#messages == 1 and not messages[1]:find("reopen", 1, true), ":Jpr sync does not send the user to a reopen that does nothing")
clear_notifications()
session.open(7)
assert(wait_for_message("gh: not logged in"), ":Jpr open checks the PR out again instead of refocusing the dead tab")

-- Once the engine works again, the same pull request starts and syncs.
jpr.setup({ binary = fake_engine })
local restarted = session.by_tab[start_pr(7)]
assert(restarted and restarted.client and restarted.panel, "the restarted session is whole")
assert(vim.wait(3000, function()
    return restarted.view.pr ~= nil
end), "the restarted session syncs")

-- A panel that cannot be built leaves no half-built session behind.
vim.api.nvim_buf_set_name(vim.api.nvim_create_buf(false, true), "jpr://panel/11")
clear_notifications()
tabs_before = tab_count()
local buffers_before = #vim.api.nvim_list_bufs()
start_pr(11)
assert(sessions_for(11) == 0, "a failed panel registers nothing")
assert(wait_for_message("E95"), "the panel failure is reported")
assert(tab_count() == tabs_before and #vim.api.nvim_list_bufs() == buffers_before, "a failed panel leaves no stray tab or buffer")

-- An engine that cannot be spawned forgets its session.
jpr.setup({ binary = worktree .. "/missing-engine" })
tabs_before = tab_count()
start_pr(8)
assert(sessions_for(8) == 0, "a failed spawn registers nothing")
assert(tab_count() == tabs_before, "a failed spawn leaves no stray tab")

-- A protocol mismatch stops the engine and forgets its session.
vim.env.FAKE_ENGINE_PROTOCOL = "99"
jpr.setup({ binary = fake_engine })
clear_notifications()
tabs_before = tab_count()
local mismatched_tab = start_pr(9)
local mismatched = session.by_tab[mismatched_tab]
assert(wait_for_message("protocol mismatch"), "the mismatch is reported")
assert(session.by_tab[mismatched_tab] == nil, "a protocol mismatch unregisters its session")
assert(wait_for_exit(mismatched) and #messages == 1, "the mismatch is the only error: " .. vim.inspect(messages))
assert(tab_count() == tabs_before, "a protocol mismatch leaves no stray tab")
vim.env.FAKE_ENGINE_PROTOCOL = nil

-- A binary/plugin version mismatch or empty version stops the engine and forgets its session.
local function test_version_mismatch()
    vim.env.FAKE_ENGINE_VERSION = "0.1.0\27[31m\7"
    jpr.setup({ binary = fake_engine })
    clear_notifications()
    local count_before = tab_count()
    local version_tab = start_pr(14)
    local version_mismatched = session.by_tab[version_tab]
    assert(wait_for_message("version mismatch"), "version mismatch is reported: " .. vim.inspect(messages))
    assert(session.by_tab[version_tab] == nil, "a version mismatch unregisters its session")
    assert(wait_for_exit(version_mismatched) and #notifications == 1, "version mismatch is the only notification")
    local error_entry = notifications[1]
    assert(error_entry.level == vim.log.levels.ERROR, "version mismatch notifies ERROR")
    assert(error_entry.message:find("%c") == nil, "version mismatch sanitizes control bytes: " .. error_entry.message)
    assert(error_entry.message:find("0.5.0", 1, true) ~= nil, "names plugin version 0.5.0: " .. error_entry.message)
    assert(error_entry.message:find("0.1.0", 1, true) ~= nil, "names binary version 0.1.0: " .. error_entry.message)
    assert(error_entry.message:find("./install.sh", 1, true) ~= nil, "names ./install.sh: " .. error_entry.message)
    assert(tab_count() == count_before, "a version mismatch leaves no stray tab")

    vim.env.FAKE_ENGINE_VERSION = ""
    clear_notifications()
    local empty_tab = start_pr(15)
    local empty_version = session.by_tab[empty_tab]
    assert(wait_for_exit(empty_version) and session.by_tab[empty_tab] == nil, "empty version unregisters session")
    assert(#notifications == 1 and notifications[1].level == vim.log.levels.ERROR, "empty version notifies ERROR")
    assert(tab_count() == count_before, "empty version leaves no stray tab")
    vim.env.FAKE_ENGINE_VERSION = nil
end
test_version_mismatch()

-- :tabclose stops the engine and forgets the session.
local closed_tab = start_pr(10)
local closed = session.by_tab[closed_tab]
assert(vim.wait(3000, function()
    return closed.view.pr ~= nil
end), "the engine synced")
local job = closed.client.job
vim.cmd("tabclose")
assert(session.by_tab[closed_tab] == nil, ":tabclose unregisters the session")
assert(vim.fn.jobwait({ job }, 3000)[1] ~= -1, ":tabclose stops the engine")
start_pr(10)
assert(sessions_for(10) == 1, "reopening runs one engine for the pull request, not two")

-- Mid-review crash restarts once; a second crash switches the session to read-only.
local function test_first_crash_auto_restart(log_path)
    vim.env.FAKE_ENGINE_STDERR = "engine panic: boom"
    local died_tab = start_pr(12)
    local died = session.by_tab[died_tab]
    assert(wait_for_sync(died), "the engine synced")
    clear_notifications()
    local first_client = died.client
    died.view.sync = { state = "never" }
    vim.fn.jobstop(first_client.job)
    assert(vim.wait(3000, function()
        return died.has_restarted == true
            and died.client ~= nil
            and died.client ~= first_client
            and died.view.sync ~= nil
            and died.view.sync.state == "synced"
    end), "first mid-review crash restarts engine and re-syncs")
    assert(vim.api.nvim_tabpage_is_valid(died_tab), "review tab remains valid across restart")
    assert(vim.fn.bufnr("jpr://panel/12") ~= -1, "panel buffer remains valid across restart")
    assert(find_notification("restarting", vim.log.levels.WARN) ~= nil, "warns about restarting: " .. vim.inspect(notifications))
    assert(vim.fn.filereadable(log_path) == 1, "crash log created at " .. log_path)
    local log_stat = vim.uv.fs_stat(log_path)
    assert(log_stat and bit.band(log_stat.mode, tonumber("777", 8)) == tonumber("600", 8), "crash log is mode 0600")
    local log_text = table.concat(vim.fn.readfile(log_path), "\n")
    assert(log_text:find("code", 1, true) ~= nil and log_text:find("engine panic: boom", 1, true) ~= nil, "crash log records code and stderr: " .. log_text)
    return died_tab, died
end

local function test_second_crash_read_only(died_tab, died)
    local compose = require("jpr.comments.compose")
    compose.open_new(died, { kind = "pr", side = "RIGHT" })
    local compose_buf = died.compose.buf
    vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { "precious draft" })
    clear_notifications()
    vim.fn.jobstop(died.client.job)
    assert(vim.wait(3000, function()
        return died.is_read_only == true and died.client == nil
    end), "second crash transitions session to read-only")
    assert(vim.api.nvim_tabpage_is_valid(died_tab), "review tab stays open in read-only mode")
    local panel_buf = vim.fn.bufnr("jpr://panel/12")
    assert(panel_buf ~= -1, "panel buffer stays open in read-only mode")
    local panel_lines = vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)
    assert(panel_lines[2] and panel_lines[2]:find("[read-only]", 1, true) ~= nil, "panel renders [read-only]: " .. vim.inspect(panel_lines))
    require("jpr.views.panel").render(died, { pr = died.view.pr, files = died.view.files })
    panel_lines = vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)
    assert(panel_lines[2] and panel_lines[2]:find("[read-only]", 1, true) ~= nil, "panel re-render keeps [read-only] badge")
    assert(find_notification("engine-pr-12.log", vim.log.levels.ERROR) ~= nil, "error names engine-pr-12.log: " .. vim.inspect(notifications))
    return compose_buf
end

local function test_read_only_view_guards(died_tab, died, compose_buf)
    local compose = require("jpr.comments.compose")
    vim.api.nvim_set_current_win(died.compose.win)
    clear_notifications()
    local submit_keys = vim.api.nvim_replace_termcodes("<C-s>", true, false, true)
    vim.api.nvim_feedkeys(submit_keys, "xt", false)
    assert(find_notification("read-only mode", vim.log.levels.ERROR) ~= nil, "submitting compose in read-only reports error")
    assert(vim.api.nvim_buf_is_valid(compose_buf) and vim.api.nvim_buf_get_lines(compose_buf, 0, 1, false)[1] == "precious draft", "compose draft preserved")
    compose.close(died)

    clear_notifications()
    compose.open_new(died, { kind = "pr", side = "RIGHT" })
    assert(died.compose == nil and find_notification("read-only mode", vim.log.levels.ERROR) ~= nil, "open_new blocked in read-only")

    vim.api.nvim_set_current_tabpage(died_tab)
    local main_win = require("jpr.views.main_window").find(died)
    local buf_before = vim.api.nvim_win_get_buf(main_win)
    clear_notifications()
    require("jpr.views.conversation").show(died)
    assert(vim.api.nvim_win_get_buf(main_win) == buf_before and died.conversation == nil, "uncached conversation leaves main window untouched")
    assert(find_notification("read-only mode", vim.log.levels.ERROR) ~= nil, "uncached conversation reports read-only mode")

    clear_notifications()
    require("jpr.views.stream").refresh(died, true)
    assert(#notifications == 0, "stream.refresh is quiet in read-only mode")

    session.sync_current()
    assert(find_notification(":Jpr close", vim.log.levels.ERROR) ~= nil, "sync_current names :Jpr close in read-only mode")
    clear_notifications()
    session.push_current()
    assert(find_notification("read-only mode", vim.log.levels.ERROR) ~= nil, "push_current reports read-only mode")
end

local function build_sample_popup_threads()
    return {
        {
            threadId = "T1",
            origin = "github",
            state = "open",
            outdated = false,
            messages = {
                {
                    id = "M1",
                    author = "reviewer",
                    body = "check this",
                    created = "2026-11-20T00:00:00Z",
                    sync = "published",
                    viewerDidAuthor = true,
                    reactions = {},
                },
            },
        },
    }
end

local function assert_keys_blocked_in_read_only(keys, extra_check)
    local original_confirm, original_select = vim.fn.confirm, vim.ui.select
    local prompt_calls = 0
    vim.fn.confirm = function()
        prompt_calls = prompt_calls + 1
        return 1
    end
    vim.ui.select = function(_, _, on_choice)
        prompt_calls = prompt_calls + 1
        on_choice("THUMBS_UP")
    end
    for _, key in ipairs(keys) do
        clear_notifications()
        vim.api.nvim_feedkeys(key, "xt", false)
        assert(prompt_calls == 0, ("key %s must not open confirm/select in read-only mode"):format(key))
        assert(find_notification("read-only mode", vim.log.levels.ERROR) ~= nil, ("key %s must report read-only mode"):format(key))
        if extra_check then
            extra_check(key)
        end
    end
    vim.fn.confirm, vim.ui.select = original_confirm, original_select
end

local function test_read_only_popup_and_conversation(live)
    local popup = require("jpr.comments.popup")
    popup.open(live, build_sample_popup_threads())
    local popup_win = live.popup and live.popup.win
    assert(popup_win and vim.api.nvim_win_is_valid(popup_win), "popup opens in read-only mode")
    vim.api.nvim_set_current_win(popup_win)
    vim.api.nvim_win_set_cursor(popup_win, { live.popup.layout.message_ranges[1].first, 0 })
    assert_keys_blocked_in_read_only({ "r", "e", "d", "+", "R", "X", "p", "s" }, function(key)
        assert(live.popup ~= nil and vim.api.nvim_win_is_valid(popup_win), ("popup key %s must not close popup"):format(key))
    end)
    vim.api.nvim_feedkeys("q", "xt", false)
    assert(live.popup == nil, "q still closes popup in read-only mode")

    local conversation = require("jpr.views.conversation")
    conversation.show(live)
    local first_range = live.conversation.layout.message_ranges[1]
    first_range.message.viewerDidAuthor = true
    vim.api.nvim_win_set_cursor(0, { first_range.first, 0 })
    assert_keys_blocked_in_read_only({ "c", "r", "e", "d", "p", "s", "+", "X" })
end

local function test_failed_restart_handshake()
    local restart_log_path = vim.fn.stdpath("state") .. "/jpr/engine-pr-16.log"
    vim.fn.delete(restart_log_path)
    local live = session.by_tab[start_pr(16)]
    assert(vim.wait(3000, function()
        return live.view.pr ~= nil and live.stream ~= nil and live.stream.layout ~= nil
    end), "PR 16 synced and drew initial stream")
    require("jpr.views.conversation").show(live)
    assert(vim.wait(3000, function()
        return live.conversation ~= nil and live.conversation.layout ~= nil
    end), "PR 16 cached conversation before crash")
    clear_notifications()
    vim.env.FAKE_ENGINE_VERSION = "0.1.0"
    vim.fn.jobstop(live.client.job)
    assert(vim.wait(3000, function()
        return live.is_read_only == true and live.client == nil
    end), "failed restart handshake transitions to read-only")
    vim.env.FAKE_ENGINE_VERSION = nil
    local error_notifications = vim.tbl_filter(function(entry)
        return entry.level == vim.log.levels.ERROR
    end, notifications)
    assert(#error_notifications == 1, "failed restart handshake emits single ERROR: " .. vim.inspect(notifications))
    assert(error_notifications[1].message:find("version mismatch", 1, true) ~= nil, "combined ERROR includes handshake reason")
    assert(error_notifications[1].message:find("engine-pr-16.log", 1, true) ~= nil, "combined ERROR includes log path")
    test_read_only_popup_and_conversation(live)
    session.close_current()
    vim.fn.delete(restart_log_path)
end

local crash_log_path = vim.fn.stdpath("state") .. "/jpr/engine-pr-12.log"
vim.fn.delete(crash_log_path)
local died_tab, died = test_first_crash_auto_restart(crash_log_path)
local preserved_compose_buf = test_second_crash_read_only(died_tab, died)
test_read_only_view_guards(died_tab, died, preserved_compose_buf)
vim.env.FAKE_ENGINE_STDERR = nil
vim.fn.delete(crash_log_path)
test_failed_restart_handshake()

-- :Jpr close on the only tab still frees the pull request for :Jpr open.
local only = session.by_tab[start_pr(13)]
assert(wait_for_sync(only), "the engine synced")
vim.cmd("tabonly")
session.close_current()
assert(session.current() == nil and vim.fn.bufnr("jpr://panel/13") == -1, ":Jpr close forgets the session and its panel")
local reopened = session.by_tab[start_pr(13)]
assert(reopened and reopened.client and reopened.panel, ":Jpr open after :Jpr close on the only tab starts whole")
assert(wait_for_sync(reopened), "the reopened session syncs")

print("session_lifecycle_spec: ok")
