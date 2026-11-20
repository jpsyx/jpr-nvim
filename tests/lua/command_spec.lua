local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")

assert(jpr.parse_pr_arg("123") == 123, "a bare number")
assert(jpr.parse_pr_arg("#45") == 45, "a hash number")
assert(jpr.parse_pr_arg("https://github.com/octo/widgets/pull/678") == 678, "a pull request URL")
assert(jpr.parse_pr_arg("https://github.com/octo/widgets/pull/678/files") == 678, "a files URL")
assert(select(2, jpr.parse_pr_arg("123")) == nil, "a bare number names no repository")
local url_number, url_repo = jpr.parse_pr_arg("https://github.com/octo/gadgets/pull/12/files")
assert(url_number == 12 and url_repo == "octo/gadgets", "a URL names its repository: " .. tostring(url_repo))
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
vim.notify = function(message, level)
    messages[#messages + 1] = { text = message, level = level }
end
jpr.command({ "frobnicate" })
assert(messages[1].level == vim.log.levels.ERROR, "an unknown subcommand is an error")
assert(messages[1].text:find("unknown subcommand", 1, true), messages[1].text)
jpr.command({ "open", "abc" })
assert(messages[2].text:find("usage", 1, true), "open without a number shows the usage")

local opened = {}
package.loaded["jpr.session"] = {
    open = function(number, repo)
        opened = { number = number, repo = repo }
    end,
}
jpr.command({ "open", "https://github.com/octo/gadgets/pull/12" })
assert(opened.number == 12 and opened.repo == "octo/gadgets", ":Jpr open passes the URL's repository on: " .. vim.inspect(opened))
package.loaded["jpr.session"] = nil

print("command_spec: ok")
