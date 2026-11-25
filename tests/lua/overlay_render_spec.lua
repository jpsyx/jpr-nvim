local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local overlay = require("jpr.render.overlay")

assert(vim.deep_equal(overlay.text_to_lines("a\r\nb\n"), { "a", "b" }), "lines without endings")
assert(vim.deep_equal(overlay.text_to_lines("a\nb"), { "a", "b" }), "no final newline")
assert(vim.deep_equal(overlay.text_to_lines(nil), {}), "no base")
assert(vim.deep_equal(overlay.text_to_lines(""), {}), "an empty base")

local chunks = overlay.removed_line_to_chunks({ text = "let x = 1;", words = { { start = 8, ["end"] = 9 } } }, { width = 12, tabstop = 4 })
assert(vim.deep_equal(chunks, {
    { "let x = ", "JprDiffDelete" },
    { "1", "JprDiffDeleteText" },
    { ";", "JprDiffDelete" },
    { "  ", "JprDiffDelete" },
}), vim.inspect(chunks))
local tabbed = overlay.removed_line_to_chunks({ text = "\tx", words = {} }, { width = 0, tabstop = 4 })
assert(vim.deep_equal(tabbed, { { "    x", "JprDiffDelete" } }), vim.inspect(tabbed))
local empty = overlay.removed_line_to_chunks({ text = "", words = {} }, { width = 0, tabstop = 8 })
assert(vim.deep_equal(empty, { { "", "JprDiffDelete" } }), vim.inspect(empty))

-- A NUL byte becomes "\n", which a virtual line draws as `^@` in two cells
-- (a NUL would cut the chunk short); a tab after it lands on the next stop.
local with_nul = overlay.removed_line_to_chunks({ text = "a\0\tz", words = {} }, { width = 6, tabstop = 4 })
assert(vim.deep_equal(with_nul, { { "a\n z", "JprDiffDelete" }, { " ", "JprDiffDelete" } }), vim.inspect(with_nul))
local nul_marks = overlay.create_extmarks_from_diff({ removed = { { above = 1, lines = { { text = "x\0y", words = {} } } } } }, 1, { width = 0, tabstop = 8 })
assert(nul_marks[1].opts.virt_lines[1][1][1] == "x\ny", vim.inspect(nul_marks))
local escaped = overlay.removed_line_to_chunks({ text = "\27\tx", words = {} }, { width = 6, tabstop = 4 })
assert(vim.deep_equal(escaped, { { "\27  x", "JprDiffDelete" }, { " ", "JprDiffDelete" } }), vim.inspect(escaped))
local wide = overlay.removed_line_to_chunks({ text = "日\tx", words = {} }, { width = 0, tabstop = 4 })
assert(vim.deep_equal(wide, { { "日  x", "JprDiffDelete" } }), vim.inspect(wide))
local after_word = overlay.removed_line_to_chunks({ text = "ab\tc", words = { { start = 0, ["end"] = 2 } } }, { width = 0, tabstop = 4 })
assert(vim.deep_equal(after_word, { { "ab", "JprDiffDeleteText" }, { "  c", "JprDiffDelete" } }), vim.inspect(after_word))
local long_text = ("x\t"):rep(100000)
local long_line = overlay.removed_line_to_chunks({ text = long_text, words = {} }, { width = 0, tabstop = 8 })
assert(#long_line == 1 and #long_line[1][1] == 800000, "a 200k-character line expands")

local diff = {
    added = { { line = 2, words = { { start = 0, ["end"] = 3 } } } },
    removed = {
        { above = 2, lines = { { text = "old", words = {} } } },
        { above = 4, lines = { { text = "tail", words = {} } } },
    },
}
local marks = overlay.create_extmarks_from_diff(diff, 3, { width = 0, tabstop = 8 })
assert(vim.deep_equal(marks[1], { line = 1, col = 0, opts = { line_hl_group = "JprDiffAdd" } }), vim.inspect(marks[1]))
assert(vim.deep_equal(marks[2], { line = 1, col = 0, opts = { end_col = 3, hl_group = "JprDiffAddText" } }), vim.inspect(marks[2]))
assert(marks[3].line == 1 and marks[3].opts.virt_lines_above == true, "a block sits above its line")
assert(marks[3].opts.virt_lines[1][1][1] == "old", vim.inspect(marks[3]))
assert(marks[4].line == 2 and marks[4].opts.virt_lines_above == false, "a block past the end sits below the last line")

-- A buffer edited since its last save can be shorter than the diff: an added
-- line past its end is dropped, not piled onto the last line.
local past_end = { added = { { line = 1, words = {} }, { line = 3, words = { { start = 0, ["end"] = 1 } } } } }
local shortened = overlay.create_extmarks_from_diff(past_end, 2, { width = 0, tabstop = 8 })
assert(vim.deep_equal(shortened, { { line = 0, col = 0, opts = { line_hl_group = "JprDiffAdd" } } }), vim.inspect(shortened))

-- Optional fg_group and syntax_spans split chunks across both word-diff and
-- syntax boundaries using { bg_group, fg_group } highlight arrays.
local syntax_chunks = overlay.removed_line_to_chunks(
    { text = "let x = 1;", words = { { start = 8, ["end"] = 9 } } },
    {
        width = 12,
        tabstop = 4,
        fg_group = "JprDiffDeleteFg_Normal",
        syntax_spans = {
            { col_start = 0, col_end = 3, hl_group = "JprDiffDeleteFg_Keyword" },
        },
    }
)
assert(vim.deep_equal(syntax_chunks, {
    { "let", { "JprDiffDelete", "JprDiffDeleteFg_Keyword" } },
    { " x = ", { "JprDiffDelete", "JprDiffDeleteFg_Normal" } },
    { "1", { "JprDiffDeleteText", "JprDiffDeleteFg_Normal" } },
    { ";", { "JprDiffDelete", "JprDiffDeleteFg_Normal" } },
    { "  ", "JprDiffDelete" },
}), vim.inspect(syntax_chunks))

-- Overlapping syntax span and word-diff span keeps both word bg and syntax fg.
local overlap_chunks = overlay.removed_line_to_chunks(
    { text = "let x = 1;", words = { { start = 8, ["end"] = 9 } } },
    {
        width = 0,
        tabstop = 4,
        fg_group = "JprDiffDeleteFg_Normal",
        syntax_spans = {
            { col_start = 6, col_end = 10, hl_group = "JprDiffDeleteFg_Number" },
        },
    }
)
assert(vim.deep_equal(overlap_chunks, {
    { "let x ", { "JprDiffDelete", "JprDiffDeleteFg_Normal" } },
    { "= ", { "JprDiffDelete", "JprDiffDeleteFg_Number" } },
    { "1", { "JprDiffDeleteText", "JprDiffDeleteFg_Number" } },
    { ";", { "JprDiffDelete", "JprDiffDeleteFg_Number" } },
}), vim.inspect(overlap_chunks))

-- create_extmarks_from_diff forwards per-block syntax spans and removed_fg_group.
local styled_marks = overlay.create_extmarks_from_diff(
    { removed = { { above = 1, lines = { { text = "local x = 1", words = {} } } } } },
    1,
    {
        width = 0,
        tabstop = 4,
        removed_fg_group = "JprDiffDeleteFg_Normal",
        removed_syntax_by_block = {
            [1] = {
                [1] = { { col_start = 0, col_end = 5, hl_group = "JprDiffDeleteFg_Keyword" } },
            },
        },
    }
)
assert(vim.deep_equal(styled_marks[1].opts.virt_lines[1], {
    { "local", { "JprDiffDelete", "JprDiffDeleteFg_Keyword" } },
    { " x = 1", { "JprDiffDelete", "JprDiffDeleteFg_Normal" } },
}), vim.inspect(styled_marks[1].opts.virt_lines[1]))

-- Nested syntax spans preserve later-span precedence inside the inner span and
-- restore the outer span afterward without quadratic blowup.
local nested_chunks = overlay.removed_line_to_chunks(
    { text = "foo(bar, 1)", words = { { start = 4, ["end"] = 7 } } },
    {
        width = 0,
        tabstop = 4,
        fg_group = "JprDiffDeleteFg_Normal",
        syntax_spans = {
            { col_start = 0, col_end = 11, hl_group = "JprDiffDeleteFg_Outer" },
            { col_start = 4, col_end = 7, hl_group = "JprDiffDeleteFg_Inner" },
        },
    }
)
assert(vim.deep_equal(nested_chunks, {
    { "foo(", { "JprDiffDelete", "JprDiffDeleteFg_Outer" } },
    { "bar", { "JprDiffDeleteText", "JprDiffDeleteFg_Inner" } },
    { ", 1)", { "JprDiffDelete", "JprDiffDeleteFg_Outer" } },
}), vim.inspect(nested_chunks))

print("overlay_render_spec: ok")
