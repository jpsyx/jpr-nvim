local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local session = require("jpr.session")
local fake_engine = root .. "/tests/lua/fixtures/fake_engine.sh"
local crashing_engine = root .. "/tests/lua/fixtures/crashing_engine.sh"

local messages = {}
vim.notify = function(message)
    messages[#messages + 1] = message
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

jpr.setup({ binary = crashing_engine })
local crashed_tab = start_pr(7)
local crashed = session.by_tab[crashed_tab]
assert(wait_for_exit(crashed) and session.by_tab[crashed_tab] == nil, "a crashed engine unregisters its session")
assert(#messages == 1 and messages[1]:find("gh: not logged in", 1, true), "one error, with the engine's stderr: " .. vim.inspect(messages))
assert(vim.fn.bufnr("jpr://panel/7") == -1, "the dead session's panel buffer is gone")
messages = {}
session.sync_current()
assert(#messages == 1 and not messages[1]:find("reopen", 1, true), ":Jpr sync does not send the user to a reopen that does nothing")
messages = {}
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
messages = {}
local blocked_tab = start_pr(11)
assert(session.by_tab[blocked_tab] == nil and sessions_for(11) == 0, "a failed panel registers nothing")
assert(wait_for_message("E95"), "the panel failure is reported")

-- An engine that cannot be spawned forgets its session.
jpr.setup({ binary = worktree .. "/missing-engine" })
local unstarted_tab = start_pr(8)
assert(session.by_tab[unstarted_tab] == nil, "a failed spawn unregisters its session")

-- A protocol mismatch stops the engine and forgets its session.
vim.env.FAKE_ENGINE_PROTOCOL = "2"
jpr.setup({ binary = fake_engine })
messages = {}
local mismatched_tab = start_pr(9)
local mismatched = session.by_tab[mismatched_tab]
assert(wait_for_message("protocol mismatch"), "the mismatch is reported")
assert(session.by_tab[mismatched_tab] == nil, "a protocol mismatch unregisters its session")
assert(wait_for_exit(mismatched) and #messages == 1, "the mismatch is the only error: " .. vim.inspect(messages))
vim.env.FAKE_ENGINE_PROTOCOL = nil

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

print("session_lifecycle_spec: ok")
