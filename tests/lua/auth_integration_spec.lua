local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local helpers = dofile(root .. "/tests/lua/support/helpers.lua")
local auth = require("jpr.auth")
local compose = require("jpr.comments.compose")
local events = require("jpr.session.events")
local jpr = require("jpr")
local session = require("jpr.session")

local notifications = {}
vim.notify = function(message, level)
    notifications[#notifications + 1] = { text = message, level = level }
end

local function with_auth_stub(behavior, callback)
    local original_prompt = auth.prompt_and_resume
    local prompt_calls = {}
    auth.prompt_and_resume = function(opts)
        prompt_calls[#prompt_calls + 1] = opts
        if behavior == "authenticate" then
            if type(opts.on_authenticated) == "function" then
                opts.on_authenticated()
            end
        elseif behavior == "cancel" then
            if type(opts.on_cancel) == "function" then
                opts.on_cancel("declined")
            end
        elseif type(behavior) == "function" then
            behavior(opts, prompt_calls)
        end
    end
    local is_ok, err = pcall(callback, prompt_calls)
    auth.prompt_and_resume = original_prompt
    auth.reset()
    if not is_ok then
        error(err, 0)
    end
end

-- 1. session.list_open_prs passes --repo, intercepts CLI exit code 3, and retries on auth.
do
    local calls = {}
    local original_system = vim.system
    local original_executable = vim.fn.executable
    vim.fn.executable = function() return 1 end
    vim.system = function(cmd, _opts, on_exit)
        calls[#calls + 1] = cmd
        local exit_result = #calls == 1
                and { code = 3, stdout = "", stderr = "gh auth login required" }
            or { code = 0, stdout = '[{"number":9,"title":"Hi","author":"a","headRef":"b","isDraft":false,"updatedAt":"2026-11-24T00:00:00Z"}]', stderr = "" }
        vim.schedule(function()
            on_exit(exit_result)
        end)
    end
    local got_prs = nil
    local reopened = false
    local is_ok, err = pcall(function()
        with_auth_stub("authenticate", function(prompt_calls)
            session.list_open_prs(function(prs)
                got_prs = prs
            end, function(err_msg)
                error("unexpected error: " .. tostring(err_msg))
            end, {
                repo = "octo/widgets",
                on_reopen = function() reopened = true end,
            })
            assert(vim.wait(2000, function() return got_prs ~= nil or reopened end), "list_open_prs resumed after auth")
            assert(#prompt_calls == 1, "prompted auth once")
            assert(vim.tbl_contains(calls[1], "--repo") and vim.tbl_contains(calls[1], "octo/widgets"), "passes --repo to prs")
            assert(reopened or (#calls == 2 and got_prs[1].number == 9), "either reopened wizard or retried list_open_prs")
        end)
    end)
    vim.system = original_system
    vim.fn.executable = original_executable
    if not is_ok then error(err, 0) end
end

-- 2. session.request replays exact RPC method/params after -32001 auth succeeds.
do
    local sent_count = 0
    local got_result = nil
    local fake_session = {
        tab = 1,
        number = 7,
        repo = "octo/widgets",
        client = {
            request = function(_, method, params, cb)
                sent_count = sent_count + 1
                assert(method == "comment" and params.body == "hello", "preserves method and params")
                if sent_count == 1 then
                    cb({ code = -32001, message = "gh auth login" }, nil)
                else
                    cb(nil, { ok = true })
                end
            end,
        },
    }
    with_auth_stub("authenticate", function(prompt_calls)
        session.request(fake_session, "comment", { body = "hello" }, function(result)
            got_result = result
        end)
        assert(#prompt_calls == 1, "prompted auth on -32001")
        assert(sent_count == 2 and got_result ~= nil and got_result.ok == true, "replayed RPC request cleanly")
    end)
end

-- 3. Simultaneous syncFailed(authRequired=true, isBackground=false) + sync RPC -32001 opens ONE auth modal and retries sync ONCE.
do
    local original_executable = vim.fn.executable
    local original_jobstart = vim.fn.jobstart
    local original_system = vim.system
    local sync_calls = 0
    vim.fn.executable = function() return 1 end
    vim.fn.jobstart = function(_cmd, opts)
        vim.defer_fn(function() opts.on_exit(91, 0, "exit") end, 10)
        return 91
    end
    vim.system = function(_cmd, _opts, on_exit)
        vim.defer_fn(function() on_exit({ code = 0, stdout = "ok", stderr = "" }) end, 10)
    end
    auth.reset()
    local fake_session
    fake_session = {
        tab = 77,
        number = 7,
        repo = "octo/widgets",
        view = { sync = { state = "never" } },
        client = {
            request = function(_, method, _params, cb)
                if method == "sync" then
                    sync_calls = sync_calls + 1
                    if sync_calls == 1 then
                        events.on_notification(fake_session, "event", {
                            type = "syncFailed",
                            message = "gh auth login",
                            authRequired = true,
                            isBackground = false,
                        }, function() end)
                        cb({ code = -32001, message = "gh auth login" }, nil)
                    else
                        cb(nil, { pr = { number = 7 }, sync = { state = "synced", at = 1 } })
                    end
                end
            end,
        },
    }
    local original_show = session.show
    session.show = function() end
    local is_ok, err = pcall(function()
        session.sync(fake_session)
        assert(auth.is_active(), "auth modal opened once for sync + syncFailed")
        helpers.press_key("<CR>")
        assert(vim.wait(2000, function() return sync_calls == 2 and not auth.is_active() end), "sync retried once: " .. tostring(sync_calls))
        vim.wait(50, function() return false end)
        assert(sync_calls == 2, "must not fire duplicate sync retries: " .. tostring(sync_calls))
    end)
    session.show = original_show
    auth.reset()
    vim.fn.executable = original_executable
    vim.fn.jobstart = original_jobstart
    vim.system = original_system
    if not is_ok then error(err, 0) end
end

-- 4. Background syncFailed stays suppressed after decline; foreground syncFailed (setViewed / push) clears suppression.
do
    local original_executable = vim.fn.executable
    vim.fn.executable = function() return 1 end
    auth.reset()
    local fake_session = { tab = 88, number = 7, repo = "octo/widgets", view = {} }
    local is_ok, err = pcall(function()
        events.on_notification(fake_session, "event", {
            type = "syncFailed",
            message = "gh auth login",
            authRequired = true,
            isBackground = true,
        }, function() end)
        assert(auth.is_active(), "first background syncFailed opens auth modal")
        helpers.press_key("q")
        assert(not auth.is_active(), "declining closes auth modal")

        events.on_notification(fake_session, "event", {
            type = "syncFailed",
            message = "gh auth login",
            authRequired = true,
            isBackground = true,
        }, function() end)
        assert(not auth.is_active(), "subsequent background syncFailed stays suppressed")

        events.on_notification(fake_session, "event", {
            type = "syncFailed",
            message = "gh auth login",
            authRequired = true,
            isBackground = false,
        }, function() end)
        assert(auth.is_active(), "foreground syncFailed clears suppression and opens auth modal")
    end)
    auth.reset()
    vim.fn.executable = original_executable
    if not is_ok then error(err, 0) end
end

-- 5. Cancelling auth after submitting compose comment reopens compose prefilled with unsent draft.
do
    local fake_session = {
        tab = vim.api.nvim_get_current_tabpage(),
        number = 7,
        repo = "octo/widgets",
        view = { pr = { number = 7 }, files = { { path = "src/a.rs", isLocalOnly = false } } },
        client = {
            request = function(_, _method, _params, cb)
                cb({ code = -32001, message = "gh auth login" }, nil)
            end,
        },
    }
    with_auth_stub("cancel", function()
        compose.open_new(fake_session, { file = "src/a.rs", kind = "line", side = "RIGHT", start = 1, ["end"] = 1 })
        assert(fake_session.compose ~= nil, "compose opened")
        vim.api.nvim_buf_set_lines(fake_session.compose.buf, 0, -1, false, { "Keep this carefully written draft" })
        helpers.press_key("<C-s>")
        assert(fake_session.compose ~= nil, "compose reopened on auth cancel")
        local recovered = table.concat(vim.api.nvim_buf_get_lines(fake_session.compose.buf, 0, -1, false), "\n")
        assert(recovered == "Keep this carefully written draft", "draft preserved: " .. recovered)
        compose.close(fake_session)
    end)
end

-- 6. Multi-repo same-PR-number safety: distinct buf_key on collision and repo-scoped open_tab_numbers.
do
    local original_by_tab = session.by_tab
    vim.cmd("tabnew")
    local tab1 = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    local tab2 = vim.api.nvim_get_current_tabpage()
    local s1 = { tab = tab1, number = 7, repo = "org-a/widgets" }
    local s2 = { tab = tab2, number = 7, repo = "org-b/widgets" }
    session.by_tab = { [tab1] = s1 }
    local key1 = session.buf_key(s1)
    assert(key1 == "7", "first PR #7 keeps canonical key '7': " .. tostring(key1))
    session.by_tab[tab2] = s2
    local key2 = session.buf_key(s2)
    assert(key2 ~= key1, "second PR #7 in another repo gets distinct buf_key: " .. tostring(key2))
    assert(session.open_tab_numbers("org-a/widgets")[7] == true, "open_tab_numbers matches org-a/widgets")
    assert(session.open_tab_numbers("org-c/widgets")[7] == nil, "open_tab_numbers does not match unrelated repo")
    session.by_tab = original_by_tab
    pcall(vim.cmd, "tabonly!")
end

print("auth_integration_spec: ok")
