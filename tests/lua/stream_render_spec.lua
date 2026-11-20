local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local stream = require("jpr.render.stream")

local function create_cell(line, text, change, words)
    return { line = line, text = text, change = change, words = words or {} }
end
local x_word = { { start = 4, ["end"] = 5 } }
local rows = {
    { kind = "file", path = "a.rs", additions = 1, deletions = 1, viewed = "UNVIEWED", folded = false },
    { kind = "hunk", path = "a.rs", header = "@@ -1,2 +1,2 @@", target = 1 },
    { kind = "line", path = "a.rs", left = create_cell(1, "keep", "context"), right = create_cell(1, "keep", "context"), target = 1 },
    { kind = "line", path = "a.rs", left = create_cell(2, "x = 1", "removed", x_word), target = 2 },
    { kind = "line", path = "a.rs", right = create_cell(2, "x = 2", "added", x_word), target = 2 },
    { kind = "file", path = "b.rs", additions = 1, deletions = 0, viewed = "VIEWED", folded = true },
    { kind = "hunk", path = "b.rs", header = "@@ -0,0 +1,1 @@", target = 1 },
    { kind = "line", path = "b.rs", right = create_cell(1, "new", "added"), target = 1 },
    { kind = "file", path = "c.png", additions = 0, deletions = 0, viewed = "DISMISSED", folded = false },
    { kind = "note", path = "c.png", text = "binary file" },
}

local unified = stream.create_layout_from_stream({ mode = "unified", rows = rows })
local column = unified.columns[1]
assert(#unified.columns == 1, "one column")
assert(vim.deep_equal(column.lines, {
    "▾   a.rs  +1 -1",
    "@@ -1,2 +1,2 @@",
    "    1     1   keep",
    "    2       - x = 1",
    "          2 + x = 2",
    "▸ ✓ b.rs  +1 -0",
    "@@ -0,0 +1,1 @@",
    "          1 + new",
    "▾ ● c.png  +0 -0",
    "  binary file",
}), vim.inspect(column.lines))
assert(column.line_groups[1] == "JprFileHeader" and column.line_groups[2] == "JprHunk", "headers")
assert(column.line_groups[3] == nil, "context is not colored")
assert(column.line_groups[4] == "JprDiffDelete" and column.line_groups[5] == "JprDiffAdd", "changes")
assert(column.line_groups[10] == "JprMuted", "notes are muted")
assert(vim.deep_equal(column.highlights, {
    { line = 3, col_start = 18, col_end = 19, group = "JprDiffDeleteText" },
    { line = 4, col_start = 18, col_end = 19, group = "JprDiffAddText" },
}), vim.inspect(column.highlights))
assert(vim.deep_equal(unified.targets[4], { path = "a.rs", line = 2 }), "a removed line leads to its place")
assert(vim.deep_equal(unified.targets[6], { path = "b.rs", line = 1 }), "a header leads to the top")
assert(unified.targets[10] == nil, "a note leads nowhere")
assert(vim.deep_equal(unified.hunks, { 2, 7 }), vim.inspect(unified.hunks))
assert(vim.deep_equal(unified.folds, { { first = 7, last = 8 } }), "a viewed file's body is folded")
assert(#unified.files == 3 and unified.files[2].line == 6 and unified.files[2].viewed == "VIEWED", vim.inspect(unified.files))

local split = stream.create_layout_from_stream({
    mode = "split",
    rows = {
        rows[1],
        rows[2],
        rows[3],
        { kind = "line", path = "a.rs", left = create_cell(2, "x = 1", "removed", x_word), right = create_cell(2, "x = 2", "added", x_word), target = 2 },
        { kind = "line", path = "a.rs", right = create_cell(3, "y", "added"), target = 3 },
    },
})
assert(#split.columns == 2, "two columns")
assert(vim.deep_equal(split.columns[1].lines, { "▾   a.rs  +1 -1", "@@ -1,2 +1,2 @@", "    1   keep", "    2 - x = 1", "" }), vim.inspect(split.columns[1].lines))
assert(vim.deep_equal(split.columns[2].lines, { "▾   a.rs  +1 -1", "@@ -1,2 +1,2 @@", "    1   keep", "    2 + x = 2", "    3 + y" }), vim.inspect(split.columns[2].lines))
assert(split.columns[1].line_groups[5] == "JprDiffFiller", "filler keeps the columns aligned")
assert(split.columns[2].highlights[1].col_start == 12, "the split gutter is 8 bytes")

assert(stream.find_file_at_line(unified, 5).path == "a.rs" and stream.find_file_at_line(unified, 6).path == "b.rs", "find_file_at_line")
assert(stream.find_next_unviewed_file(unified, 1).path == "c.png", "a viewed file is skipped and a dismissed one is not")
assert(stream.find_next_unviewed_file(unified, 9) == nil, "nothing after the last file")
assert(stream.find_adjacent_line({ 2, 7 }, 2, 1) == 7 and stream.find_adjacent_line({ 2, 7 }, 7, 1) == nil, "next")
assert(stream.find_adjacent_line({ 2, 7 }, 7, -1) == 2 and stream.find_adjacent_line({ 2, 7 }, 2, -1) == nil, "previous")

local view = { pr = { headSha = "h", baseSha = "b" }, files = { { path = "a.rs", additions = 1, deletions = 1, viewed = "UNVIEWED" } } }
local key = stream.build_key_from_view(view)
assert(stream.build_key_from_view(view) == key, "the same view, the same key")
view.files[1].viewed = "VIEWED"
assert(stream.build_key_from_view(view) ~= key, "a viewed change changes the key")

print("stream_render_spec: ok")
