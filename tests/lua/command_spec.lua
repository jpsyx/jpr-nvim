local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")

assert(jpr.parse_pr_arg("123") == 123, "a bare number")
assert(jpr.parse_pr_arg("#45") == 45, "a hash number")
assert(jpr.parse_pr_arg("https://github.com/octo/widgets/pull/678") == 678, "a pull request URL")
assert(jpr.parse_pr_arg("https://github.com/octo/widgets/pull/678/files") == 678, "a files URL")
assert(jpr.parse_pr_arg("abc") == nil, "not a number")
assert(jpr.parse_pr_arg(nil) == nil, "missing")

assert(vim.deep_equal(jpr.complete("", "Jpr "), { "open", "sync", "close" }), "all subcommands")
assert(vim.deep_equal(jpr.complete("s", "Jpr s"), { "sync" }), "filtered subcommands")
assert(vim.deep_equal(jpr.complete("", "Jpr open "), {}), "nothing after the subcommand")

jpr.setup({ worktree_cmd = "wt pr {n}" })
assert(jpr.config.worktree_cmd == "wt pr {n}", "setup takes options")
assert(jpr.config.binary == "jpr-review", "setup keeps the defaults")

dofile(root .. "/plugin/jpr.lua")
assert(vim.api.nvim_get_commands({})["Jpr"] ~= nil, ":Jpr exists")

local messages = {}
vim.notify = function(msg, level)
    messages[#messages + 1] = { msg = msg, level = level }
end
jpr.command({ "frobnicate" })
assert(messages[1].level == vim.log.levels.ERROR, "an unknown subcommand is an error")
assert(messages[1].msg:find("unknown subcommand", 1, true), messages[1].msg)
jpr.command({ "open", "abc" })
assert(messages[2].msg:find("usage", 1, true), "open without a number shows the usage")

print("command_spec: ok")
