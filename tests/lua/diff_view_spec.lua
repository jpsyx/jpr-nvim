local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local view_mode = require("jpr.view_mode")
local diff_view = require("jpr.views.diff")

view_mode.path = vim.fn.tempname()
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })
local request_log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = request_log
local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")
vim.fn.writefile({ "untouched" }, worktree .. "/OTHER.md")

--- How many requests the plugin sent that hold every one of `needles`.
local function count_requests(...)
    local needles, count = { ... }, 0
    for _, line in ipairs(vim.fn.filereadable(request_log) == 1 and vim.fn.readfile(request_log) or {}) do
        local has_all = true
        for _, needle in ipairs(needles) do
            has_all = has_all and line:find(needle, 1, true) ~= nil
        end
        count = count + (has_all and 1 or 0)
    end
    return count
end


local context = {
    root = root,
    worktree = worktree,
    count_requests = count_requests,
}

dofile(root .. "/tests/lua/diff_view_spec/unified.lua")(context)
dofile(root .. "/tests/lua/diff_view_spec/split_and_nav.lua")(context)

print("diff_view_spec: ok")
