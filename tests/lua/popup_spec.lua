local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local view_mode = require("jpr.view_mode")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new", "tail" }, worktree .. "/README.md")

local errors, infos = {}, {}
local original_error, original_info = jpr.error, jpr.info
jpr.error = function(message)
    errors[#errors + 1] = message
end
jpr.info = function(message)
    infos[#infos + 1] = message
end

-- Calling popup_current without an active session notifies cleanly.
session.popup_current()
assert(#errors == 1 and errors[1]:find("no pull request", 1, true), vim.inspect(errors))
errors, infos = {}, {}

session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "the review syncs")

local context = {
    root = root,
    helpers = helpers,
    log = log,
    worktree = worktree,
    review = review,
    errors = errors,
    infos = infos,
    clear_messages = function()
        for idx = #errors, 1, -1 do errors[idx] = nil end
        for idx = #infos, 1, -1 do infos[idx] = nil end
    end,
}

dofile(root .. "/tests/lua/popup_spec/actions.lua")(context)
dofile(root .. "/tests/lua/popup_spec/lifecycle.lua")(context)

jpr.error = original_error
jpr.info = original_info
session.close_current()

print("popup_spec: ok")
