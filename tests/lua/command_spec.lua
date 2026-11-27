local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path


dofile(root .. "/tests/lua/command_spec/surface.lua")(root)
dofile(root .. "/tests/lua/command_spec/dispatch.lua")()

print("command_spec: ok")
