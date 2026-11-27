local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local view_mode = require("jpr.view_mode")
local render_threads = require("jpr.render.threads")
local conversation = require("jpr.views.conversation")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")

local errors, infos = {}, {}
local original_error, original_info = jpr.error, jpr.info
jpr.error = function(message)
    errors[#errors + 1] = message
end
jpr.info = function(message)
    infos[#infos + 1] = message
end

local function find_tab_win_by_buf_name(tab, substring)
    for _, candidate_win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(candidate_win))
        if name:find(substring, 1, true) ~= nil then
            return candidate_win
        end
    end
    return nil
end


local context = {
    root = root,
    helpers = helpers,
    log = log,
    worktree = worktree,
    errors = errors,
    infos = infos,
    find_tab_win_by_buf_name = find_tab_win_by_buf_name,
}

dofile(root .. "/tests/lua/conversation_view_spec/render_and_compose.lua")(context)
dofile(root .. "/tests/lua/conversation_view_spec/actions.lua")(context)

jpr.error = original_error
jpr.info = original_info
session.close_current()

print("conversation_view_spec: ok")
