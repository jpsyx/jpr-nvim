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
local delete_bg = vim.api.nvim_get_hl(0, { name = "JprDiffDelete", link = false }).bg
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
local has_unknown_treesitter_mark = false
local has_unknown_normal_fallback = false

for _, mark in ipairs(syntax_marks) do
    local row, col_start, details = mark[2], mark[3], mark[4]
    local highlight_group = details.hl_group
    if row == 2 and details.priority == 85 then
        has_context_fallback = true
    end
    if row == 2 and col_start == gutter_length and details.end_col == gutter_length + 5 and details.priority == 90 then
        if type(highlight_group) == "string" and vim.startswith(highlight_group, "@keyword") then
            has_context_keyword = true
        end
    end
    if row == 3 and details.priority == 85 and type(highlight_group) == "string" and vim.startswith(highlight_group, "JprDiffDeleteFg_") then
        has_removed_fallback = true
    end
    if row == 3 and col_start == gutter_length and details.end_col == gutter_length + 5 and details.priority == 90 then
        if type(highlight_group) == "string" and vim.startswith(highlight_group, "JprDiffDeleteFg_") then
            local fg = vim.api.nvim_get_hl(0, { name = highlight_group, link = false }).fg
            assert(contrast.contrast_ratio(fg, delete_bg) > contrast.contrast_ratio(raw_keyword_fg, delete_bg), "removed keyword contrast lifted")
            has_removed_keyword = true
        end
    end
    if row == 4 and details.priority == 85 and type(highlight_group) == "string" and vim.startswith(highlight_group, "JprDiffAddFg_") then
        has_added_fallback = true
    end
    if row == 4 and col_start == gutter_length and details.end_col == gutter_length + 5 and details.priority == 90 then
        if type(highlight_group) == "string" and vim.startswith(highlight_group, "JprDiffAddFg_") then
            local fg = vim.api.nvim_get_hl(0, { name = highlight_group, link = false }).fg
            assert(contrast.contrast_ratio(fg, add_bg) > contrast.contrast_ratio(raw_keyword_fg, add_bg), "added keyword contrast lifted")
            has_added_keyword = true
        end
    end
    if row == 4 and col_start == gutter_length + 15 and details.end_col == gutter_length + 17 and details.priority == 90 then
        if type(highlight_group) == "string" and vim.startswith(highlight_group, "JprDiffAddFg_") then
            has_added_number = true
        end
    end
    if row == 6 and col_start == gutter_length and details.end_col == gutter_length + 8 and details.priority == 90 then
        if type(highlight_group) == "string" and vim.startswith(highlight_group, "JprDiffAddFg_") then
            has_multiline_second_row = true
        end
    end
    if row == 9 and details.priority == 90 then
        has_unknown_treesitter_mark = true
    end
    if row == 9 and details.priority == 85 and type(highlight_group) == "string" and vim.startswith(highlight_group, "JprDiffAddFg_") then
        has_unknown_normal_fallback = true
    end
end

assert(has_context_keyword and not has_context_fallback, "context row keeps raw @keyword and no Normal fallback")
assert(has_removed_keyword and has_removed_fallback, "removed row receives contrast-lifted keyword and Normal fallback")
assert(has_added_keyword and has_added_fallback and has_added_number, "added row receives contrast-lifted keyword, number, and Normal fallback")
assert(has_multiline_second_row, "multi-line Lua string spans onto second row with contrast-lifted group")
assert(not has_unknown_treesitter_mark and has_unknown_normal_fallback, "unknown extension gets Normal fallback only, zero Treesitter marks")

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

-- code_rows carry left_line, right_line, and hunk_index.
assert(column.code_rows[1].left_line == 1 and column.code_rows[1].right_line == 1, "context row records left_line and right_line")
assert(column.code_rows[2].left_line == 2 and column.code_rows[2].right_line == nil, "removed row records left_line only")
assert(column.code_rows[3].left_line == nil and column.code_rows[3].right_line == 2, "added row records right_line only")
assert(column.code_rows[1].hunk_index == 1, "records 1-based hunk_index")

-- dedent_lines strips common leading whitespace across non-blank lines.
local dedented, stripped = syntax.dedent_lines({ "    key: value", "", "      nested: true" })
assert(stripped == 4, "strips minimum 4 spaces across non-blank lines, got " .. tostring(stripped))
assert(dedented[1] == "key: value" and dedented[2] == "" and dedented[3] == "  nested: true", "dedent preserves relative indent")

-- Full-file worktree context highlights mid-file hunks accurately (Lua multiline string opened before hunk).
local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree .. "/lua", "p")
vim.fn.writefile({
    "local header = [[",
    "  line two",
    "  local inside_string = 42",
    "  still inside",
    "]]",
    "local after = 99",
}, worktree .. "/lua/midfile.lua")

local midfile_lua_stream = {
    mode = "unified",
    rows = {
        { kind = "file", path = "lua/midfile.lua", additions = 1, deletions = 0, viewed = "UNVIEWED", folded = false },
        { kind = "hunk", path = "lua/midfile.lua", header = "@@ -3,4 +3,4 @@", target = 3 },
        { kind = "line", path = "lua/midfile.lua", left = { line = 3, text = "  local inside_string = 42", change = "context", words = {} }, right = { line = 3, text = "  local inside_string = 42", change = "context", words = {} }, target = 3 },
        { kind = "line", path = "lua/midfile.lua", right = { line = 4, text = "  still inside", change = "added", words = {} }, target = 4 },
        { kind = "line", path = "lua/midfile.lua", left = { line = 5, text = "]]", change = "context", words = {} }, right = { line = 5, text = "]]", change = "context", words = {} }, target = 5 },
        { kind = "line", path = "lua/midfile.lua", left = { line = 6, text = "local after = 99", change = "context", words = {} }, right = { line = 6, text = "local after = 99", change = "context", words = {} }, target = 6 },
    },
}
local midfile_col = render.create_layout_from_stream(midfile_lua_stream).columns[1]
local midfile_buf = vim.api.nvim_create_buf(false, true)
stream_view.fill(midfile_buf, midfile_col, { worktree = worktree })
local midfile_marks = vim.api.nvim_buf_get_extmarks(midfile_buf, syntax_namespace, { 2, 0 }, { 2, -1 }, { details = true })
local has_string_on_line3 = false
local has_keyword_on_line3 = false
for _, mark in ipairs(midfile_marks) do
    local group = mark[4].hl_group
    if type(group) == "string" and vim.startswith(group, "@string") then
        has_string_on_line3 = true
    end
    if type(group) == "string" and vim.startswith(group, "@keyword") then
        has_keyword_on_line3 = true
    end
end
assert(has_string_on_line3 and not has_keyword_on_line3, "mid-file hunk uses full worktree file context so line inside [[...]] is @string, not @keyword")
vim.api.nvim_buf_delete(midfile_buf, { force = true })

-- Mid-file YAML hunk with dedent preserves highlighting both with worktree and on fallback (removed/deleted).
local has_yaml_query, yaml_query = pcall(vim.treesitter.query.get, "yaml", "highlights")
local has_yaml_parser = pcall(vim.treesitter.get_string_parser, "a: 1\n", "yaml")
if has_yaml_query and yaml_query and has_yaml_parser then
    vim.api.nvim_set_hl(0, "@property", { fg = 0xe06c75 })
    vim.fn.writefile({
        "root:",
        "  section:",
        "    items:",
        "      - item1",
        "      - item2",
        "    next_key: value",
        "    other_key: 42",
    }, worktree .. "/config.yaml")

    local yaml_stream = {
        mode = "unified",
        rows = {
            { kind = "file", path = "config.yaml", additions = 2, deletions = 1, viewed = "UNVIEWED", folded = false },
            { kind = "hunk", path = "config.yaml", header = "@@ -4,4 +4,4 @@", target = 4 },
            { kind = "line", path = "config.yaml", left = { line = 4, text = "      - item1", change = "context", words = {} }, right = { line = 4, text = "      - item1", change = "context", words = {} }, target = 4 },
            { kind = "line", path = "config.yaml", left = { line = 5, text = "      - old_item", change = "removed", words = {} }, target = 5 },
            { kind = "line", path = "config.yaml", right = { line = 5, text = "      - item2", change = "added", words = {} }, target = 5 },
            { kind = "line", path = "config.yaml", left = { line = 6, text = "    next_key: value", change = "context", words = {} }, right = { line = 6, text = "    next_key: value", change = "context", words = {} }, target = 6 },
            { kind = "line", path = "config.yaml", right = { line = 7, text = "    other_key: 42", change = "added", words = {} }, target = 7 },
        },
    }
    local yaml_col = render.create_layout_from_stream(yaml_stream).columns[1]

    -- With worktree (full file context).
    local yaml_buf = vim.api.nvim_create_buf(false, true)
    stream_view.fill(yaml_buf, yaml_col, { worktree = worktree })
    local dedented_key_marks = vim.api.nvim_buf_get_extmarks(yaml_buf, syntax_namespace, { 5, 0 }, { 5, -1 }, { details = true })
    assert(#dedented_key_marks > 0, "mid-file YAML dedented key line receives syntax marks with worktree")
    local dedented_added_marks = vim.api.nvim_buf_get_extmarks(yaml_buf, syntax_namespace, { 6, 0 }, { 6, -1 }, { details = true })
    local has_added_syntax = false
    for _, mark in ipairs(dedented_added_marks) do
        if mark[4].priority == 90 then
            has_added_syntax = true
        end
    end
    assert(has_added_syntax, "mid-file YAML added line after dedent receives priority-90 syntax marks")
    vim.api.nvim_buf_delete(yaml_buf, { force = true })

    -- Without worktree (fallback dedent + per-line recovery).
    local yaml_fallback_buf = vim.api.nvim_create_buf(false, true)
    stream_view.fill(yaml_fallback_buf, yaml_col)
    local fallback_marks = vim.api.nvim_buf_get_extmarks(yaml_fallback_buf, syntax_namespace, { 5, 0 }, { 5, -1 }, { details = true })
    assert(#fallback_marks > 0, "mid-file YAML dedented line still receives syntax marks on fallback without worktree")
    vim.api.nvim_buf_delete(yaml_fallback_buf, { force = true })
end

vim.fn.delete(worktree, "rf")

print("stream_syntax_spec: ok")
