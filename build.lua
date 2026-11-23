-- lazy.nvim runs this automatically on plugin install, `:Lazy update`, and `:Lazy build jpr-nvim`.
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h")
local lua_search_prefix = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;"
if not vim.startswith(package.path, lua_search_prefix) then
    package.path = lua_search_prefix .. package.path
end

package.loaded["jpr.build"] = nil
package.loaded["jpr.binary"] = nil

require("jpr.build").build_release_binary(plugin_root)
