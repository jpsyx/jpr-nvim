local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local session = require("jpr.session")
local panel_view = require("jpr.views.panel")
local fixture = root .. "/tests/lua/fixtures/fake_engine.sh"

jpr.setup({ binary = fixture })
assert(vim.deep_equal(session.checkout_args(7), { fixture, "checkout", "--pr", "7" }), "checkout args")
jpr.setup({ binary = fixture, worktree_cmd = "wt pr {n}" })
assert(
    vim.deep_equal(session.checkout_args(7), { fixture, "checkout", "--pr", "7", "--worktree-cmd", "wt pr {n}" }),
    "checkout args with a worktree command"
)

local info = session.parse_checkout('Checking out...\n{"worktree":"/tmp/w","repo":"octo/widgets","number":7,"title":"T"}\n')
assert(info.worktree == "/tmp/w" and info.repo == "octo/widgets" and info.number == 7, vim.inspect(info))
local missing, err = session.parse_checkout("")
assert(missing == nil and err:find("printed nothing", 1, true), "empty checkout output")
local bad, bad_err = session.parse_checkout("{}")
assert(bad == nil and bad_err:find("unexpected", 1, true), "checkout output without a worktree")

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello" }, worktree .. "/README.md")

session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local s = session.current()
assert(s and s.number == 7, "the tab has a session")
assert(vim.fn.resolve(vim.fn.getcwd(-1, 0)) == vim.fn.resolve(worktree), "the tab's directory is the worktree")

assert(vim.wait(3000, function()
    return vim.api.nvim_buf_get_lines(s.panel.buf, 0, 1, false)[1] == "#7 Fix the widget"
end), "the panel shows the synced pull request")
local lines = vim.api.nvim_buf_get_lines(s.panel.buf, 0, -1, false)
assert(lines[5] == "✓ README.md  +2 -1 [1]", vim.inspect(lines))

vim.api.nvim_set_current_win(s.panel.win)
vim.api.nvim_win_set_cursor(s.panel.win, { 5, 0 })
panel_view.open_file_under_cursor(s)
assert(vim.api.nvim_get_current_win() ~= s.panel.win, "the file opens beside the panel")
assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/README.md"), "the worktree file opens")

local tabs = #vim.api.nvim_list_tabpages()
session.close_current()
assert(session.current() == nil, "closing forgets the session")
assert(#vim.api.nvim_list_tabpages() == tabs - 1, "closing closes the tab")

print("session_spec: ok")
