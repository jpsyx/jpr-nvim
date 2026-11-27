local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local view_mode = require("jpr.view_mode")
local submit_view = require("jpr.views.submit")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new", "line three", "line four", "line five" }, worktree .. "/README.md")

local function find_submit_win()
    return helpers.find_floating_win("Submit Review")
end

local function find_summary_editor_win()
    return helpers.find_floating_win("Review Summary")
end

local function find_submit_confirm_win()
    return helpers.find_floating_win("Confirm GitHub Review Submission")
end

local function win_lines(win)
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

-- 1. session.submit_current() without open session errors via jpr.error.
local errors, infos = {}, {}
require("jpr.notify").set_listener(function(kind, message)
    if kind == "error" then
        errors[#errors + 1] = message
    elseif kind == "info" or kind == "success" then
        infos[#infos + 1] = message
    end
end)


local context = {
    helpers = helpers,
    log = log,
    worktree = worktree,
    errors = errors,
    infos = infos,
    find_submit_win = find_submit_win,
    find_summary_editor_win = find_summary_editor_win,
    find_submit_confirm_win = find_submit_confirm_win,
    win_lines = win_lines,
}

dofile(root .. "/tests/lua/submit_view_spec/modal_and_editor.lua")(context)
dofile(root .. "/tests/lua/submit_view_spec/scenarios_and_mouse.lua")(context)

require("jpr.notify").set_listener(nil)
session.close_current()

print("submit_view_spec: ok")
