local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local render = require("jpr.render.stream")
local stream_view = require("jpr.views.stream")
local syntax = require("jpr.views.stream.syntax")

jpr.define_highlights()

-- resolve_hl_group walks @capture.lang -> @a.b.c -> @a.b -> @a.
local function make_exists(known)
    return function(group_name)
        return known[group_name] == true
    end
end

assert(
    syntax.resolve_hl_group("keyword.function", "lua", make_exists({ ["@keyword.function.lua"] = true, ["@keyword"] = true }))
        == "@keyword.function.lua",
    "prefers language-qualified capture"
)
assert(
    syntax.resolve_hl_group("keyword.function", "lua", make_exists({ ["@keyword.function"] = true, ["@keyword"] = true }))
        == "@keyword.function",
    "falls back to unqualified full capture"
)
assert(
    syntax.resolve_hl_group("keyword.function.builtin", "lua", make_exists({ ["@keyword"] = true })) == "@keyword",
    "walks dot-separated prefixes to root capture"
)
assert(
    syntax.resolve_hl_group("nonexistent.capture", "lua", make_exists({ ["@keyword"] = true })) == nil,
    "returns nil when no prefix exists"
)
assert(
    syntax.resolve_hl_group("_internal", "lua", make_exists({ ["@_internal.lua"] = true, ["@_internal"] = true })) == nil,
    "ignores underscore-prefixed internal captures"
)

-- resolve_lang_from_path resolves known extensions and returns nil for unknown ones.
assert(syntax.resolve_lang_from_path("lua/jpr/init.lua") == "lua", "resolves lua files")
assert(syntax.resolve_lang_from_path("notes.unknownext") == nil, "returns nil for unknown extensions")

-- Stream buffer receives Treesitter syntax extmarks at exact post-gutter offsets
-- alongside JprDiffAdd line extmarks (priority 100) and word marks (priority 110).
local lua_stream = {
    mode = "unified",
    rows = {
        { kind = "file", path = "lua/demo.lua", additions = 3, deletions = 0, viewed = "UNVIEWED", folded = false },
        { kind = "hunk", path = "lua/demo.lua", header = "@@ -0,0 +1,3 @@", target = 1 },
        {
            kind = "line",
            path = "lua/demo.lua",
            right = {
                line = 1,
                text = "local answer = 42",
                change = "added",
                words = { { start = 15, ["end"] = 17 } },
            },
            target = 1,
        },
        {
            kind = "line",
            path = "lua/demo.lua",
            right = { line = 2, text = "local note = [[first", change = "added", words = {} },
            target = 2,
        },
        {
            kind = "line",
            path = "lua/demo.lua",
            right = { line = 3, text = "second]]", change = "added", words = {} },
            target = 3,
        },
        { kind = "file", path = "data.unknownext", additions = 1, deletions = 0, viewed = "UNVIEWED", folded = false },
        { kind = "hunk", path = "data.unknownext", header = "@@ -0,0 +1,1 @@", target = 1 },
        {
            kind = "line",
            path = "data.unknownext",
            right = { line = 1, text = "local ignored = true", change = "added", words = {} },
            target = 1,
        },
    },
}

local layout = render.create_layout_from_stream(lua_stream)
local column = layout.columns[1]
local buf = vim.api.nvim_create_buf(false, true)
stream_view.fill(buf, column)

local stream_namespace = vim.api.nvim_create_namespace("jpr-stream")
local syntax_namespace = vim.api.nvim_create_namespace("jpr-stream-syntax")
local gutter_len = column.code_rows[1].gutter_len
assert(gutter_len == 14, "unified gutter is 14 bytes: " .. tostring(gutter_len))

local stream_marks = vim.api.nvim_buf_get_extmarks(buf, stream_namespace, 0, -1, { details = true })
local has_line_priority, has_word_priority = false, false
for _, mark in ipairs(stream_marks) do
    local details = mark[4]
    if mark[2] == 2 and details.line_hl_group == "JprDiffAdd" and details.priority == 100 then
        has_line_priority = true
    end
    if mark[2] == 2 and details.hl_group == "JprDiffAddText" and details.priority == 110 then
        has_word_priority = true
    end
end
assert(has_line_priority, "JprDiffAdd line extmark has priority 100")
assert(has_word_priority, "JprDiffAddText word extmark has priority 110")

local syntax_marks = vim.api.nvim_buf_get_extmarks(buf, syntax_namespace, 0, -1, { details = true })
assert(#syntax_marks > 0, "Lua stream rows receive Treesitter syntax extmarks")

local has_local_keyword = false
local has_number_literal = false
local has_multiline_second_row = false
local has_unknown_ext_mark = false
for _, mark in ipairs(syntax_marks) do
    local row, col_start, details = mark[2], mark[3], mark[4]
    if row == 2 and col_start == gutter_len and details.end_col == gutter_len + 5 and details.priority == 90 then
        if type(details.hl_group) == "string" and vim.startswith(details.hl_group, "@keyword") then
            has_local_keyword = true
        end
    end
    if row == 2 and col_start == gutter_len + 15 and details.end_col == gutter_len + 17 then
        if type(details.hl_group) == "string" and vim.startswith(details.hl_group, "@number") then
            has_number_literal = true
        end
    end
    if row == 4 and col_start == gutter_len and details.end_col == gutter_len + 8 then
        if type(details.hl_group) == "string" and vim.startswith(details.hl_group, "@string") then
            has_multiline_second_row = true
        end
    end
    if row == 7 then
        has_unknown_ext_mark = true
    end
end
assert(has_local_keyword, "keyword 'local' highlighted at exact post-gutter bytes with priority 90")
assert(has_number_literal, "number '42' highlighted at exact post-gutter bytes")
assert(has_multiline_second_row, "multi-line Lua string spans onto second row after gutter")
assert(not has_unknown_ext_mark, "unknown extension produces no syntax extmarks")

-- Oversized files (> 5000 rows) are skipped gracefully without throwing or adding marks.
local huge_code_rows = {}
local huge_lines = {}
for index = 1, 5001 do
    huge_lines[index] = "          1 + local x = 1"
    huge_code_rows[index] = {
        line = index - 1,
        path = "lua/huge.lua",
        gutter_len = 14,
        text = "local x = 1",
    }
end
local huge_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(huge_buf, 0, -1, false, huge_lines)
syntax.apply(huge_buf, { code_rows = huge_code_rows })
assert(#vim.api.nvim_buf_get_extmarks(huge_buf, syntax_namespace, 0, -1, {}) == 0, "files over 5000 rows are skipped")

vim.api.nvim_buf_delete(buf, { force = true })
vim.api.nvim_buf_delete(huge_buf, { force = true })

print("stream_syntax_spec: ok")
