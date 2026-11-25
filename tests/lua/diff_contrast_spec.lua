local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local diff_view = require("jpr.views.diff")
local diff_contrast = require("jpr.views.diff.contrast")

vim.o.background = "dark"
vim.api.nvim_set_hl(0, "Normal", { bg = 0x282c34, fg = 0xabb2bf })
vim.api.nvim_set_hl(0, "@keyword", { fg = 0xc678dd })
vim.api.nvim_set_hl(0, "@number", { fg = 0xd19a66 })
vim.api.nvim_set_hl(0, "@string", { fg = 0x98c379 })
vim.api.nvim_set_hl(0, "@lsp.type.variable", { fg = 0xe06c75 })
vim.api.nvim_set_hl(0, "@lsp.type.comment", { fg = 0x5c6370 })
jpr.define_highlights()

-- Non-tracked window produces zero viewport contrast marks and negative bounds are safe.
local plain_win = vim.api.nvim_get_current_win()
local plain_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(plain_buf, 0, -1, false, { "local untouched = 1" })
vim.api.nvim_win_set_buf(plain_win, plain_buf)
assert(#diff_contrast.collect_viewport_marks(plain_win, plain_buf, 0, 0) == 0, "untracked window emits no marks")
assert(#diff_contrast.collect_viewport_marks(plain_win, plain_buf, -1, 0) == 0, "negative topline returns empty")

-- Unified file overlay: Normal (45), Treesitter (115), single-line and multi-line
-- LSP (135), >1000-byte skip on added and removed lines, and removed virtual lines.
local unified_buf = vim.api.nvim_create_buf(false, true)
local long_added_line = "local huge = '" .. ("x"):rep(1100) .. "'"
local long_removed_line = "local old_huge = '" .. ("y"):rep(1100) .. "'"
vim.api.nvim_buf_set_lines(unified_buf, 0, -1, false, {
    "local keep = 1",
    "local added = 42",
    "local middle_comment",
    long_added_line,
})
vim.bo[unified_buf].filetype = "lua"
vim.api.nvim_win_set_buf(plain_win, unified_buf)
vim.treesitter.start(unified_buf, "lua")

local fake_lsp_namespace = vim.api.nvim_create_namespace("vim.lsp.semantic_tokens.test")
vim.api.nvim_buf_set_extmark(unified_buf, fake_lsp_namespace, 1, 6, {
    end_col = 11,
    hl_group = "@lsp.type.variable",
    priority = 125,
})
-- Multi-line LSP token starting on row 0 (col 10) and ending on row 3 (col 5),
-- overlapping visible row 2 (full 20 bytes) when viewport is restricted to [2, 2].
vim.api.nvim_buf_set_extmark(unified_buf, fake_lsp_namespace, 0, 10, {
    end_row = 3,
    end_col = 5,
    hl_group = "@lsp.type.comment",
    priority = 125,
})

diff_view.draw_overlay(unified_buf, {
    added = {
        { line = 2, words = { { start = 14, ["end"] = 16 } } },
        { line = 3, words = {} },
        { line = 4, words = {} },
    },
    removed = {
        {
            above = 2,
            lines = {
                { text = "local old = 7", words = { { start = 12, ["end"] = 13 } } },
                { text = long_removed_line, words = {} },
            },
        },
    },
}, plain_win)

local unified_marks = diff_contrast.collect_viewport_marks(plain_win, unified_buf, 0, 3)
local has_normal_45, has_treesitter_115, has_lsp_135 = false, false, false
for _, mark in ipairs(unified_marks) do
    assert(mark.row == 1 or mark.row == 2, "only short added rows 1 and 2 receive marks, got row " .. tostring(mark.row))
    assert(vim.startswith(mark.hl_group, "JprDiffAddFg_"), "added row uses JprDiffAddFg_* group: " .. tostring(mark.hl_group))
    if mark.row == 1 and mark.priority == 45 and mark.col_start == 0 and mark.col_end == #"local added = 42" then
        has_normal_45 = true
    end
    if mark.row == 1 and mark.priority == 115 and mark.col_start == 0 and mark.col_end == 5 then
        has_treesitter_115 = true
    end
    if mark.row == 1 and mark.priority == 135 and mark.col_start == 6 and mark.col_end == 11 then
        has_lsp_135 = true
    end
end
assert(has_normal_45, "unified added line gets Normal fallback at priority 45")
assert(has_treesitter_115, "unified added line gets Treesitter contrast at priority 115")
assert(has_lsp_135, "unified added line gets LSP semantic-token contrast at priority 135")

-- Multi-line LSP token overlapping viewport [2, 2] spans full row 2 without truncation.
local middle_viewport_marks = diff_contrast.collect_viewport_marks(plain_win, unified_buf, 2, 2)
local has_multiline_lsp = false
for _, mark in ipairs(middle_viewport_marks) do
    if mark.row == 2 and mark.priority == 135 and mark.col_start == 0 and mark.col_end == #"local middle_comment" then
        has_multiline_lsp = true
    end
end
assert(has_multiline_lsp, "multi-line LSP token spanning topline..botline covers full visible row 2")

-- Verify short removed virtual line has syntax contrast and oversized removed line skips syntax parsing.
local diff_namespace = vim.api.nvim_create_namespace("jpr-diff")
local found_removed_keyword, found_removed_word, found_oversized_single_chunk = false, false, false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(unified_buf, diff_namespace, 0, -1, { details = true })) do
    local virt_lines = mark[4].virt_lines
    if virt_lines then
        for _, chunk in ipairs(virt_lines[1]) do
            local text, chunk_hl = chunk[1], chunk[2]
            if text == "local" and type(chunk_hl) == "table" and chunk_hl[1] == "JprDiffDelete" and vim.startswith(chunk_hl[2], "JprDiffDeleteFg_") then
                found_removed_keyword = true
            end
            if text == "7" and type(chunk_hl) == "table" and chunk_hl[1] == "JprDiffDeleteText" and vim.startswith(chunk_hl[2], "JprDiffDeleteFg_") then
                found_removed_word = true
            end
        end
        local oversized_chunks = virt_lines[2]
        if
            oversized_chunks
            and #oversized_chunks == 1
            and oversized_chunks[1][1] == long_removed_line
            and type(oversized_chunks[1][2]) == "table"
            and oversized_chunks[1][2][1] == "JprDiffDelete"
            and vim.startswith(oversized_chunks[1][2][2], "JprDiffDeleteFg_")
        then
            found_oversized_single_chunk = true
        end
    end
end
assert(found_removed_keyword, "removed virtual line highlights keyword with contrast-lifted JprDiffDeleteFg_*")
assert(found_removed_word, "removed virtual line highlights changed word with JprDiffDeleteText + contrast fg")
assert(found_oversized_single_chunk, "oversized removed line (>1000 bytes) skips syntax splitting while keeping Normal contrast")

-- Unknown filetype removed virtual line receives Normal-lifted contrast without error.
local unknown_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(unknown_buf, 0, -1, false, { "after" })
vim.bo[unknown_buf].filetype = ""
vim.api.nvim_win_set_buf(plain_win, unknown_buf)
diff_view.draw_overlay(unknown_buf, {
    added = {},
    removed = { { above = 1, lines = { { text = "before", words = {} } } } },
}, plain_win)
local unknown_marks = vim.api.nvim_buf_get_extmarks(unknown_buf, diff_namespace, 0, -1, { details = true })
local unknown_chunk = unknown_marks[1][4].virt_lines[1][1]
assert(
    unknown_chunk[1] == "before"
        and type(unknown_chunk[2]) == "table"
        and unknown_chunk[2][1] == "JprDiffDelete"
        and vim.startswith(unknown_chunk[2][2], "JprDiffDeleteFg_"),
    "unknown filetype removed line still gets Normal-lifted contrast"
)

-- Twin unified windows sharing one buffer: clearing one keeps the other active,
-- and diff_view.clear detaches the last window cleanly.
vim.api.nvim_win_set_buf(plain_win, unified_buf)
diff_contrast.attach_unified(plain_win, unified_buf, { [1] = "add" })
vim.cmd("vsplit")
local twin_win = vim.api.nvim_get_current_win()
diff_contrast.attach_unified(twin_win, unified_buf, { [1] = "add" })
diff_contrast.detach_window(twin_win)
diff_contrast.clear_buffer(unified_buf)
assert(#diff_contrast.collect_viewport_marks(plain_win, unified_buf, 0, 2) > 0, "other unified window retains buffer lines")
vim.api.nvim_win_close(twin_win, true)

local mock_session = {
    diff = {
        applied = { [plain_win] = { buf = unified_buf, mode = "unified" } },
        splits = {},
        saved_signcolumn = {},
    },
}
diff_view.clear(mock_session, plain_win)
assert(#diff_contrast.collect_viewport_marks(plain_win, unified_buf, 0, 2) == 0, "diff_view.clear detaches unified window")

-- BufWipeout automatically clears tracked unified buffer state.
local wipe_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(wipe_buf, 0, -1, false, { "local temp = 1" })
vim.api.nvim_win_set_buf(plain_win, wipe_buf)
diff_contrast.attach_unified(plain_win, wipe_buf, { [0] = "add" })
assert(#diff_contrast.collect_viewport_marks(plain_win, wipe_buf, 0, 0) > 0, "attached before wipeout")
vim.api.nvim_win_set_buf(plain_win, plain_buf)
vim.api.nvim_buf_delete(wipe_buf, { force = true })
assert(#diff_contrast.collect_viewport_marks(plain_win, wipe_buf, 0, 0) == 0, "BufWipeout clears tracked unified buffer")

-- Split :diffthis: both base_win (unfocused) and head_win (focused) compute
-- their own independent diff_hlID lines and contrast marks, and diff_view.clear cleans up both.
vim.cmd("tabnew")
local base_buf = vim.api.nvim_create_buf(false, true)
local head_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(base_buf, 0, -1, false, { "local same = 1", "local old_value = 1" })
vim.api.nvim_buf_set_lines(head_buf, 0, -1, false, { "local same = 1", "local new_value = 2" })
vim.bo[base_buf].filetype = "lua"
vim.bo[head_buf].filetype = "lua"

local base_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(base_win, base_buf)
vim.treesitter.start(base_buf, "lua")
vim.cmd("diffthis")

vim.cmd("vsplit")
local head_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(head_win, head_buf)
vim.treesitter.start(head_buf, "lua")
vim.cmd("diffthis")

diff_contrast.attach_split(base_win)
diff_contrast.attach_split(head_win)

vim.api.nvim_set_current_win(head_win)
local base_marks = diff_contrast.collect_viewport_marks(base_win, base_buf, 0, 1)
local head_marks = diff_contrast.collect_viewport_marks(head_win, head_buf, 0, 1)
assert(#base_marks > 0, "unfocused base split window emits contrast marks on changed line")
assert(#head_marks > 0, "focused head split window emits contrast marks on changed line")
for _, mark in ipairs(base_marks) do
    assert(mark.row == 1, "base split skips equal row 0")
end
for _, mark in ipairs(head_marks) do
    assert(mark.row == 1, "head split skips equal row 0")
end

vim.cmd("redraw!")
local split_session = {
    diff = {
        applied = { [head_win] = { buf = head_buf, mode = "split" } },
        splits = { [head_win] = { base_win = base_win, base_buf = base_buf, saved_winhighlight = "" } },
        saved_signcolumn = {},
    },
}
diff_view.clear(split_session, head_win)
assert(#diff_contrast.collect_viewport_marks(base_win, base_buf, 0, 1) == 0, "diff_view.clear detaches base split")
assert(#diff_contrast.collect_viewport_marks(head_win, head_buf, 0, 1) == 0, "diff_view.clear detaches head split")

-- Clean up scratch tab and buffers.
vim.cmd("tabclose")
for _, scratch_buf in ipairs({ unified_buf, unknown_buf, base_buf, head_buf }) do
    if vim.api.nvim_buf_is_valid(scratch_buf) then
        pcall(vim.api.nvim_buf_delete, scratch_buf, { force = true })
    end
end

print("diff_contrast_spec: ok")
