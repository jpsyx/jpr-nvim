local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local loading = require("jpr.views.loading")
local session = require("jpr.session")
local stream_view = require("jpr.views.stream")
local diff_view = require("jpr.views.diff")
local events = require("jpr.session.events")
local fake_engine = root .. "/tests/lua/fixtures/fake_engine.sh"

local function find_line(lines, needle)
    for index, line in ipairs(lines) do
        if line:find(needle, 1, true) then
            return index, line
        end
    end
    return nil, nil
end

local function has_highlight(highlights, line_0based, group)
    for _, highlight in ipairs(highlights) do
        if highlight.line == line_0based and highlight.group == group then
            return true
        end
    end
    return false
end


local context = {
    fake_engine = fake_engine,
    find_line = find_line,
    has_highlight = has_highlight,
}

dofile(root .. "/tests/lua/loading_view_spec/layout.lua")(context)
dofile(root .. "/tests/lua/loading_view_spec/checkout.lua")(context)

print("loading_view_spec: ok")
