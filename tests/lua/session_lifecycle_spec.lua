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
        local matches_level = expected_level == nil or entry.level == expected_level
        if matches_level and entry.message:find(text, 1, true) then
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

-- A binary/plugin version mismatch stops the engine and forgets its session.
local function test_version_mismatch()
    vim.env.FAKE_ENGINE_VERSION = "0.1.0"
    jpr.setup({ binary = fake_engine })
    clear_notifications()
    local count_before = tab_count()
    local version_tab = start_pr(14)
    local version_mismatched = session.by_tab[version_tab]
    assert(wait_for_message("version mismatch"), "version mismatch is reported: " .. vim.inspect(messages))
    assert(session.by_tab[version_tab] == nil, "a version mismatch unregisters its session")
    assert(wait_for_exit(version_mismatched) and #notifications == 1, "version mismatch is the only notification")
    local err_entry = notifications[1]
    assert(err_entry.level == vim.log.levels.ERROR, "version mismatch notifies ERROR")
    assert(err_entry.message:find("0.5.0", 1, true) ~= nil, "names plugin version 0.5.0: " .. err_entry.message)
    assert(err_entry.message:find("0.1.0", 1, true) ~= nil, "names binary version 0.1.0: " .. err_entry.message)
    assert(err_entry.message:find("./install.sh", 1, true) ~= nil, "names ./install.sh: " .. err_entry.message)
    assert(tab_count() == count_before, "a version mismatch leaves no stray tab")
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
    local log_text = table.concat(vim.fn.readfile(log_path), "\n")
    assert(log_text:find("code", 1, true) ~= nil and log_text:find("engine panic: boom", 1, true) ~= nil, "crash log records code and stderr: " .. log_text)
    return died_tab, died
end

local function test_second_crash_read_only(died_tab, died, log_path)
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
    vim.api.nvim_set_current_tabpage(died_tab)
    clear_notifications()
    session.sync_current()
    assert(find_notification("read-only mode", vim.log.levels.ERROR) ~= nil, "sync_current reports read-only mode")
    clear_notifications()
    session.push_current()
    assert(find_notification("read-only mode", vim.log.levels.ERROR) ~= nil, "push_current reports read-only mode")
end

local crash_log_path = vim.fn.stdpath("state") .. "/jpr/engine-pr-12.log"
vim.fn.delete(crash_log_path)
local died_tab, died = test_first_crash_auto_restart(crash_log_path)
test_second_crash_read_only(died_tab, died, crash_log_path)
vim.env.FAKE_ENGINE_STDERR = nil
vim.fn.delete(crash_log_path)

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
