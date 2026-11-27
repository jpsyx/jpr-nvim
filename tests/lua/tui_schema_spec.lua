local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path


local valid_commands = dofile(root .. "/tests/lua/tui_schema_spec/validation.lua")()
dofile(root .. "/tests/lua/tui_schema_spec/resolution.lua")(valid_commands)

print("tui_schema_spec: ok")
