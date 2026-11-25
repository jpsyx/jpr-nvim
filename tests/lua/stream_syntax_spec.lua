local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local contrast = require("jpr.highlights.contrast")
local jpr = require("jpr")
local render = require("jpr.render.stream")
local stream_view = require("jpr.views.stream")
local syntax = require("jpr.views.stream.syntax")

vim.o.background = "dark"
vim.api.nvim_set_hl(0, "Normal", { bg = 0x282c34, fg = 0xabb2bf })
vim.api.nvim_set_hl(0, "@keyword", { fg = 0xc678dd })
vim.api.nvim_set_hl(0, "@string", { fg = 0x98c379 })
vim.api.nvim_set_hl(0, "@number", { fg = 0xd19a66 })
jpr.define_highlights()

-- get_highlight_group_from_capture walks @capture.language -> @a.b.c -> @a.b -> @a.
local function create_highlight_checker(known_groups)
    return function(group_name)
        return known_groups[group_name] == true
    end
end

assert(
    syntax.get_highlight_group_from_capture(
        "keyword.function",
        "lua",
        create_highlight_checker({ ["@keyword.function.lua"] = true, ["@keyword"] = true })
    ) == "@keyword.function.lua",
    "prefers language-qualified capture"
)
assert(
    syntax.get_highlight_group_from_capture(
        "keyword.function",
        "lua",
        create_highlight_checker({ ["@keyword.function"] = true, ["@keyword"] = true })
    ) == "@keyword.function",
    "falls back to unqualified full capture"
)
assert(
    syntax.get_highlight_group_from_capture(
        "keyword.function.builtin",
        "lua",
        create_highlight_checker({ ["@keyword"] = true })
    ) == "@keyword",
    "walks dot-separated prefixes to root capture"
)
assert(
    syntax.get_highlight_group_from_capture(
        "nonexistent.capture",
        "lua",
        create_highlight_checker({ ["@keyword"] = true })
    ) == nil,
    "returns nil when no prefix exists"
)
assert(
    syntax.get_highlight_group_from_capture(
        "_internal",
        "lua",
        create_highlight_checker({ ["@_internal.lua"] = true, ["@_internal"] = true })
    ) == nil,
    "ignores underscore-prefixed internal captures"
)

-- get_language_from_path returns known extensions and nil for unknown ones.
assert(syntax.get_language_from_path("lua/jpr/init.lua") == "lua", "detects lua files")
assert(syntax.get_language_from_path("notes.unknownext") == nil, "returns nil for unknown extensions")

-- collect_line_spans returns per-line Treesitter spans for reuse in removed virtual lines.
local collected = syntax.collect_line_spans({ "local x = 42" }, "lua")
assert(type(collected) == "table" and type(collected[1]) == "table" and #collected[1] > 0, "collects spans for line 1")
local has_collected_keyword, has_collected_number = false, false
for _, span in ipairs(collected[1]) do
    if span.col_start == 0 and span.col_end == 5 and vim.startswith(span.hl_group, "@keyword") then
        has_collected_keyword = true
    end
    if span.col_start == 10 and span.col_end == 12 and vim.startswith(span.hl_group, "@number") then
        has_collected_number = true
    end
end
assert(has_collected_keyword and has_collected_number, "collect_line_spans captures keyword and number spans")

-- Stream buffer receives contrast-adjusted syntax extmarks on added/removed rows
-- and raw syntax extmarks on context rows alongside JprDiff* line/word marks.
local lua_stream = {
    mode = "unified",
    rows = {
        { kind = "file", path = "lua/demo.lua", additions = 3, deletions = 1, viewed = "UNVIEWED", folded = false },
        { kind = "hunk", path = "lua/demo.lua", header = "@@ -1,2 +1,4 @@", target = 1 },
        {
            kind = "line",
            path = "lua/demo.lua",
            left = { line = 1, text = "local keep = 1", change = "context", words = {} },
            right = { line = 1, text = "local keep = 1", change = "context", words = {} },
            target = 1,
        },
        {
            kind = "line",
            path = "lua/demo.lua",
            left = { line = 2, text = "local gone = 7", change = "removed", words = {} },
            target = 2,
        },
        {
            kind = "line",
            path = "lua/demo.lua",
            right = {
                line = 2,
                text = "local answer = 42",
                change = "added",
                words = { { start = 15, ["end"] = 17 } },
            },
            target = 2,
        },
        {
            kind = "line",
            path = "lua/demo.lua",
            right = { line = 3, text = "local note = [[first", change = "added", words = {} },
            target = 3,
        },
        {
            kind = "line",
            path = "lua/demo.lua",
            right = { line = 4, text = "second]]", change = "added", words = {} },
            target = 4,
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
assert(column.code_rows[1].change == "context", "records context change on code_rows")
assert(column.code_rows[2].change == "removed", "records removed change on code_rows")
assert(column.code_rows[3].change == "added", "records added change on code_rows")

local buf = vim.api.nvim_create_buf(false, true)
stream_view.fill(buf, column)

local stream_namespace = vim.api.nvim_create_namespace("jpr-stream")
local syntax_namespace = vim.api.nvim_create_namespace("jpr-stream-syntax")
local gutter_length = column.code_rows[1].gutter_length
assert(gutter_length == 14, "unified gutter is 14 bytes: " .. tostring(gutter_length))

local stream_marks = vim.api.nvim_buf_get_extmarks(buf, stream_namespace, 0, -1, { details = true })
local has_line_priority, has_word_priority = false, false
for _, mark in ipairs(stream_marks) do
    local details = mark[4]
    if mark[2] == 4 and details.line_hl_group == "JprDiffAdd" and details.priority == 100 then
        has_line_priority = true
    end
    if mark[2] == 4 and details.hl_group == "JprDiffAddText" and details.priority == 110 then
        has_word_priority = true
    end
end
assert(has_line_priority, "JprDiffAdd line extmark has priority 100")
assert(has_word_priority, "JprDiffAddText word extmark has priority 110")

local add_bg = vim.api.nvim_get_hl(0, { name = "JprDiffAdd", link = false }).bg
local del_bg = vim.api.nvim_get_hl(0, { name = "JprDiffDelete", link = false }).bg
local raw_keyword_fg = vim.api.nvim_get_hl(0, { name = "@keyword", link = false }).fg
local syntax_marks = vim.api.nvim_buf_get_extmarks(buf, syntax_namespace, 0, -1, { details = true })
assert(#syntax_marks > 0, "Lua stream rows receive Treesitter syntax extmarks")

local has_context_keyword = false
local has_context_fallback = false
local has_removed_keyword = false
local has_removed_fallback = false
local has_added_keyword = false
local has_added_fallback = false
local has_added_number = false
local has_multiline_second_row = false
local has_unknown_ts_mark = false
local has_unknown_normal_fallback = false

for _, mark in ipairs(syntax_marks) do
    local row, col_start, details = mark[2], mark[3], mark[4]
    local hl_group = details.hl_group
    if row == 2 and details.priority == 85 then
        has_context_fallback = true
    end
    if row == 2 and col_start == gutter_length and details.end_col == gutter_length + 5 and details.priority == 90 then
        if type(hl_group) == "string" and vim.startswith(hl_group, "@keyword") then
            has_context_keyword = true
        end
    end
    if row == 3 and details.priority == 85 and type(hl_group) == "string" and vim.startswith(hl_group, "JprDiffDeleteFg_") then
        has_removed_fallback = true
    end
    if row == 3 and col_start == gutter_length and details.end_col == gutter_length + 5 and details.priority == 90 then
        if type(hl_group) == "string" and vim.startswith(hl_group, "JprDiffDeleteFg_") then
            local fg = vim.api.nvim_get_hl(0, { name = hl_group, link = false }).fg
            assert(contrast.contrast_ratio(fg, del_bg) > contrast.contrast_ratio(raw_keyword_fg, del_bg), "removed keyword contrast lifted")
            has_removed_keyword = true
        end
    end
    if row == 4 and details.priority == 85 and type(hl_group) == "string" and vim.startswith(hl_group, "JprDiffAddFg_") then
        has_added_fallback = true
    end
    if row == 4 and col_start == gutter_length and details.end_col == gutter_length + 5 and details.priority == 90 then
        if type(hl_group) == "string" and vim.startswith(hl_group, "JprDiffAddFg_") then
            local fg = vim.api.nvim_get_hl(0, { name = hl_group, link = false }).fg
            assert(contrast.contrast_ratio(fg, add_bg) > contrast.contrast_ratio(raw_keyword_fg, add_bg), "added keyword contrast lifted")
            has_added_keyword = true
        end
    end
    if row == 4 and col_start == gutter_length + 15 and details.end_col == gutter_length + 17 and details.priority == 90 then
        if type(hl_group) == "string" and vim.startswith(hl_group, "JprDiffAddFg_") then
            has_added_number = true
        end
    end
    if row == 6 and col_start == gutter_length and details.end_col == gutter_length + 8 and details.priority == 90 then
        if type(hl_group) == "string" and vim.startswith(hl_group, "JprDiffAddFg_") then
            has_multiline_second_row = true
        end
    end
    if row == 9 and details.priority == 90 then
        has_unknown_ts_mark = true
    end
    if row == 9 and details.priority == 85 and type(hl_group) == "string" and vim.startswith(hl_group, "JprDiffAddFg_") then
        has_unknown_normal_fallback = true
    end
end

assert(has_context_keyword and not has_context_fallback, "context row keeps raw @keyword and no Normal fallback")
assert(has_removed_keyword and has_removed_fallback, "removed row receives contrast-lifted keyword and Normal fallback")
assert(has_added_keyword and has_added_fallback and has_added_number, "added row receives contrast-lifted keyword, number, and Normal fallback")
assert(has_multiline_second_row, "multi-line Lua string spans onto second row with contrast-lifted group")
assert(not has_unknown_ts_mark and has_unknown_normal_fallback, "unknown extension gets Normal fallback only, zero Treesitter marks")

-- Oversized files (> 5000 rows) are skipped gracefully without throwing or adding marks.
local huge_code_rows = {}
local huge_lines = {}
for index = 1, 5001 do
    huge_lines[index] = "          1 + local x = 1"
    huge_code_rows[index] = {
        line = index - 1,
        path = "lua/huge.lua",
        gutter_length = 14,
        text = "local x = 1",
        change = "added",
    }
end
local huge_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(huge_buf, 0, -1, false, huge_lines)
syntax.apply(huge_buf, { code_rows = huge_code_rows })
assert(#vim.api.nvim_buf_get_extmarks(huge_buf, syntax_namespace, 0, -1, {}) == 0, "files over 5000 rows are skipped")

vim.api.nvim_buf_delete(buf, { force = true })
vim.api.nvim_buf_delete(huge_buf, { force = true })

print("stream_syntax_spec: ok")
