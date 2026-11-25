-- Entry point for native LSP file operation specs (split into lsp_files_spec/*.lua).
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local lsp_files = require("jpr.lsp_files")

assert(jpr.defaults.lsp_file_ops_timeout_ms == 30000, "default lsp_file_ops_timeout_ms is 30000")
assert(jpr.defaults.lsp_attach_timeout_ms == 3000, "default lsp_attach_timeout_ms is 3000")

local orig_get_clients = vim.lsp.get_clients
local orig_ui_select = vim.ui.select
local orig_notify = vim.notify

local context = {
    lsp_files = lsp_files,
    create_temp_worktree = function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        return vim.uv.fs_realpath(dir) or dir
    end,
    write_lines = function(path, lines)
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        vim.fn.writefile(lines, path)
    end,
    open_buffer = function(path)
        local buf = vim.fn.bufadd(path)
        vim.fn.bufload(buf)
        vim.bo[buf].modified = false
        return buf
    end,
    list_dir_entries = function(dir)
        local entries = {}
        local handle = vim.uv.fs_scandir(dir)
        if not handle then
            return entries
        end
        while true do
            local name = vim.uv.fs_scandir_next(handle)
            if not name then
                break
            end
            entries[name] = true
        end
        return entries
    end,
    restore_stubs = function()
        vim.lsp.get_clients = orig_get_clients
        vim.ui.select = orig_ui_select
        vim.notify = orig_notify
    end,
}

dofile(root .. "/tests/lua/lsp_files_spec/rename_ops.lua")(context)
dofile(root .. "/tests/lua/lsp_files_spec/create_and_edge_cases.lua")(context)

print("lsp_files_spec: ok")
