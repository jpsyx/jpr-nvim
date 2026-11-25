-- Entry point for compose specs (split into compose_spec/*.lua).
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local stream_view = require("jpr.views.stream")
local view_mode = require("jpr.view_mode")
local compose = require("jpr.comments.compose")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new", "tail", "end" }, worktree .. "/README.md")

local captured = { errors = {}, infos = {} }
local original_error, original_info = jpr.error, jpr.info
jpr.error = function(message)
    captured.errors[#captured.errors + 1] = message
end
jpr.info = function(message)
    captured.infos[#captured.infos + 1] = message
end

session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "session syncs")

local context = {
    jpr = jpr,
    session = session,
    main_window = main_window,
    stream_view = stream_view,
    compose = compose,
    helpers = helpers,
    log = log,
    review = review,
    captured = captured,
    original_client_request = review.client.request,
    line_anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 },
    find_compose_win = function()
        return helpers.find_floating_win("GitHub")
    end,
}

dofile(root .. "/tests/lua/compose_spec/basic_and_suggestions.lua")(context)
dofile(root .. "/tests/lua/compose_spec/reply_edit_and_origins.lua")(context)
dofile(root .. "/tests/lua/compose_spec/comment_current.lua")(context)

jpr.error = original_error
jpr.info = original_info
session.close_current()

print("compose_spec: ok")
