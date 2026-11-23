-- lazy.nvim runs this automatically on plugin install, `:Lazy update`, and `:Lazy build jpr-nvim`.
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local lua_search_prefix = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;"
if not package.path:find(lua_search_prefix, 1, true) then
    package.path = lua_search_prefix .. package.path
end

require("jpr.build").build_release_binary(plugin_root)
