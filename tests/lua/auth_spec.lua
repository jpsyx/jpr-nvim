local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local helpers = dofile(root .. "/tests/lua/support/helpers.lua")
local auth = require("jpr.auth")
local wizard = require("jpr.tui.wizard")

local notifications = {}
vim.notify = function(message, level)
    notifications[#notifications + 1] = { text = message, level = level }
end

local function clear_notifications()
    for index = #notifications, 1, -1 do
        notifications[index] = nil
    end
end

local function has_notification(needle, expected_level)
    for _, entry in ipairs(notifications) do
        local level_matches = expected_level == nil or entry.level == expected_level
        if level_matches and entry.text:find(needle, 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function with_stubs(stubs, callback)
    local original_executable = vim.fn.executable
    local original_jobstart = vim.fn.jobstart
    local original_jobstop = vim.fn.jobstop
    local original_system = vim.system
    local original_getmousepos = vim.fn.getmousepos
    if stubs.executable then vim.fn.executable = stubs.executable end
    if stubs.jobstart then vim.fn.jobstart = stubs.jobstart end
    if stubs.jobstop then vim.fn.jobstop = stubs.jobstop end
    if stubs.system then vim.system = stubs.system end
    if stubs.getmousepos then vim.fn.getmousepos = stubs.getmousepos end
    auth.reset()
    clear_notifications()
    local is_ok, err = pcall(callback)
    auth.reset()
    wizard.close()
    vim.fn.executable = original_executable
    vim.fn.jobstart = original_jobstart
    vim.fn.jobstop = original_jobstop
    vim.system = original_system
    vim.fn.getmousepos = original_getmousepos
    if not is_ok then
        error(err, 0)
    end
end

assert(auth.is_cli_auth_error({ code = 3 }) == true, "exit code 3 is cli auth error")
assert(auth.is_cli_auth_error({ code = 1 }) == false, "exit code 1 is not cli auth error")
assert(auth.is_rpc_auth_error({ code = -32001 }) == true, "-32001 is rpc auth error")
assert(auth.is_rpc_auth_error({ code = -32000 }) == false, "-32000 is not rpc auth error")

-- 1. Missing gh binary reports install error and never opens modal or terminal.
with_stubs({
    executable = function(cmd)
        return cmd == "gh" and 0 or 1
    end,
    jobstart = function()
        error("jobstart must not run when gh is missing")
    end,
}, function()
    local cancelled_reason = nil
    auth.prompt_and_resume({
        on_authenticated = function() error("must not resume") end,
        on_cancel = function(reason) cancelled_reason = reason end,
    })
    assert(cancelled_reason == "missing_gh", "reports missing_gh: " .. tostring(cancelled_reason))
    assert(not auth.is_active(), "modal does not open when gh is missing")
    assert(has_notification("gh (GitHub CLI)", vim.log.levels.ERROR), "notifies missing gh")
end)

-- 2. Keyboard confirmation launches floating gh auth login terminal, verifies status, and resumes.
with_stubs({
    executable = function() return 1 end,
    jobstart = function(cmd, opts)
        assert(vim.deep_equal(cmd, { "gh", "auth", "login" }), "runs gh auth login")
        assert(opts.term == true, "runs in terminal buffer")
        vim.defer_fn(function()
            opts.on_exit(42, 0, "exit")
        end, 10)
        return 42
    end,
    system = function(cmd, _opts, on_exit)
        assert(vim.deep_equal(cmd, { "gh", "auth", "status" }), "verifies with gh auth status")
        vim.defer_fn(function()
            on_exit({ code = 0, stdout = "Logged in", stderr = "" })
        end, 10)
    end,
}, function()
    local resumed = 0
    local keyed_resumed = 0
    auth.prompt_and_resume({
        key = "sync:1",
        on_authenticated = function() keyed_resumed = keyed_resumed + 1 end,
    })
    -- Duplicate key deduplicates; distinct key queues alongside.
    auth.prompt_and_resume({
        key = "sync:1",
        on_authenticated = function() keyed_resumed = keyed_resumed + 1 end,
    })
    auth.prompt_and_resume({
        on_authenticated = function() resumed = resumed + 1 end,
    })

    assert(auth.is_active(), "auth prompt modal is open")
    local text = helpers.current_text()
    assert(text:find("Authenticate with GitHub", 1, true) ~= nil, "shows Authenticate option: " .. text)
    assert(text:find("Cancel", 1, true) ~= nil, "shows Cancel option")

    helpers.press_key("<CR>")
    assert(
        vim.wait(2000, function()
            return resumed == 1 and keyed_resumed == 1 and not auth.is_active()
        end),
        ("resumed=%d keyed=%d active=%s"):format(resumed, keyed_resumed, tostring(auth.is_active()))
    )
end)

-- 3. Mouse click on Authenticate row launches gh auth login and resumes.
with_stubs({
    executable = function() return 1 end,
    jobstart = function(_cmd, opts)
        vim.defer_fn(function() opts.on_exit(55, 0, "exit") end, 10)
        return 55
    end,
    system = function(_cmd, _opts, on_exit)
        vim.defer_fn(function() on_exit({ code = 0, stdout = "", stderr = "" }) end, 10)
    end,
}, function()
    local resumed = false
    auth.prompt_and_resume({
        on_authenticated = function() resumed = true end,
    })
    local lines = helpers.current_lines()
    local auth_line = helpers.find_line_number(lines, "Authenticate with GitHub")
    assert(auth_line ~= nil, "found Authenticate line")
    local modal_win = helpers.current_float_win()
    vim.fn.getmousepos = function()
        return { winid = modal_win, line = auth_line, column = 4 }
    end
    helpers.press_key("<LeftMouse>")
    assert(vim.wait(2000, function() return resumed end), "mouse click triggered auth and resumed")
end)

-- 4. Incomplete login (gh auth status non-zero) reopens retry prompt keeping queue; Cancel drains on_cancel.
with_stubs({
    executable = function() return 1 end,
    jobstart = function(_cmd, opts)
        vim.defer_fn(function() opts.on_exit(77, 1, "exit") end, 10)
        return 77
    end,
    system = function(_cmd, _opts, on_exit)
        vim.defer_fn(function() on_exit({ code = 1, stdout = "", stderr = "not logged in" }) end, 10)
    end,
}, function()
    local cancelled_reason = nil
    auth.prompt_and_resume({
        on_authenticated = function() error("must not resume when status fails") end,
        on_cancel = function(reason) cancelled_reason = reason end,
    })
    helpers.press_key("<CR>")
    assert(
        vim.wait(2000, function()
            return helpers.find_floating_win("GitHub Authentication Required") ~= nil
                and helpers.current_text():find("did not complete", 1, true) ~= nil
        end),
        "reopens auth modal with retry detail after incomplete login"
    )
    helpers.press_key("q")
    assert(cancelled_reason == "incomplete", "cancelling retry prompt reports incomplete: " .. tostring(cancelled_reason))
end)

-- 5. Manual terminal window close stops login job, still verifies gh auth status, and resumes when logged in.
do
    local stopped_job_ids = {}
    with_stubs({
        executable = function() return 1 end,
        jobstart = function(_cmd, _opts)
            return 88
        end,
        jobstop = function(id)
            stopped_job_ids[#stopped_job_ids + 1] = id
        end,
        system = function(_cmd, _opts, on_exit)
            vim.defer_fn(function() on_exit({ code = 0, stdout = "Logged in", stderr = "" }) end, 10)
        end,
    }, function()
        local resumed = false
        auth.prompt_and_resume({
            on_authenticated = function() resumed = true end,
        })
        helpers.press_key("<CR>")
        local term_win = helpers.find_floating_win("GitHub CLI Login")
        assert(term_win ~= nil, "login terminal float opened")
        vim.api.nvim_win_close(term_win, true)
        assert(vim.wait(2000, function() return resumed end), "manual terminal close verified status and resumed")
        assert(
            #stopped_job_ids == 1 and stopped_job_ids[1] == 88,
            "manual close stops active login job 88: " .. vim.inspect(stopped_job_ids)
        )
    end)
end

-- 6. Declining suppresses background prompts until an explicit foreground call clears suppression.
with_stubs({
    executable = function() return 1 end,
}, function()
    local bg_cancelled = nil
    auth.prompt_and_resume({
        is_background = true,
        on_authenticated = function() end,
        on_cancel = function(reason) bg_cancelled = reason end,
    })
    assert(auth.is_active(), "first background auth prompt opens")
    helpers.press_key("q")
    assert(bg_cancelled == "declined", "first decline reports declined")

    local second_bg_cancelled = nil
    auth.prompt_and_resume({
        is_background = true,
        on_authenticated = function() end,
        on_cancel = function(reason) second_bg_cancelled = reason end,
    })
    assert(not auth.is_active(), "second background prompt is suppressed after decline")
    assert(second_bg_cancelled == "declined", "suppressed background prompt cancels immediately")

    auth.prompt_and_resume({
        is_background = false,
        on_authenticated = function() end,
    })
    assert(auth.is_active(), "explicit foreground call clears suppression and opens modal")
end)

-- 7. Clicking [q/Esc] cancel in auth modal footer or clicking outside cancels cleanly.
with_stubs({
    executable = function() return 1 end,
}, function()
    local cancelled = 0
    auth.prompt_and_resume({
        on_authenticated = function() end,
        on_cancel = function() cancelled = cancelled + 1 end,
    })
    local mwin = helpers.current_float_win()
    local mlines = helpers.current_lines()
    local cancel_col = mlines[#mlines]:find("[q/Esc] cancel", 1, true)
    assert(cancel_col ~= nil, "found [q/Esc] cancel in auth footer")
    vim.fn.getmousepos = function() return { winid = mwin, line = #mlines, column = cancel_col + 2 } end
    helpers.press_key("<LeftMouse>")
    assert(cancelled == 1 and not auth.is_active(), "footer [q/Esc] cancel click cancels auth modal")

    auth.prompt_and_resume({
        on_authenticated = function() end,
        on_cancel = function() cancelled = cancelled + 1 end,
    })
    vim.fn.getmousepos = function() return { winid = 999999, line = 1, column = 1 } end
    helpers.press_key("<LeftMouse>")
    assert(cancelled == 2 and not auth.is_active(), "outside click cancels auth modal")
end)

print("auth_spec: ok")
