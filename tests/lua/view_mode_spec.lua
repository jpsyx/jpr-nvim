local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local view_mode = require("jpr.view_mode")

view_mode.path = vim.fn.tempname() .. "/jpr/view-mode"
assert(view_mode.get() == "unified", "unified by default")
jpr.setup({ view = "split" })
view_mode.reset()
assert(view_mode.get() == "split", "setup picks the starting mode")
assert(view_mode.toggle() == "unified", "toggle flips it")
assert(vim.fn.readfile(view_mode.path)[1] == "unified", "and remembers it")
view_mode.reset()
assert(view_mode.get() == "unified", "a remembered choice beats the setup default")
vim.fn.writefile({ "sideways" }, view_mode.path)
view_mode.reset()
assert(view_mode.get() == "split", "a file that names no mode is ignored")

print("view_mode_spec: ok")
