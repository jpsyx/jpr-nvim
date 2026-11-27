local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local helpers = dofile(root .. "/tests/lua/support/helpers.lua")
local jpr = require("jpr")
local view_mode = require("jpr.view_mode")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")

local context = {
    root = root,
    helpers = helpers,
    log = log,
    worktree = worktree,
    create_file_row = function(path, folded)
        return { kind = "file", path = path, additions = 1, deletions = 0, viewed = folded and "VIEWED" or "UNVIEWED", folded = folded }
    end,
    create_hunk_row = function(path, line)
        return { kind = "hunk", path = path, header = ("@@ -0,0 +%d,1 @@"):format(line), target = line }
    end,
    create_added_row = function(path, line, text)
        return { kind = "line", path = path, right = { line = line, text = text, change = "added", words = {} }, target = line }
    end,
}

dofile(root .. "/tests/lua/stream_view_spec/core.lua")(context)
dofile(root .. "/tests/lua/stream_view_spec/lifecycle.lua")(context)
dofile(root .. "/tests/lua/stream_view_spec/threads.lua")(context)

print("stream_view_spec: ok")
