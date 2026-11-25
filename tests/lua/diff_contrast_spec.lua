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
jpr.define_highlights()

-- Non-tracked window produces zero viewport contrast marks.
local plain_win = vim.api.nvim_get_current_win()
local plain_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(plain_buf, 0, -1, false, { "local untouched = 1" })
vim.api.nvim_win_set_buf(plain_win, plain_buf)
assert(#diff_contrast.collect_viewport_marks(plain_win, plain_buf, 0, 0) == 0, "untracked window emits no marks")

-- Unified file overlay: Normal (45), Treesitter (115), LSP (135), >1000-byte skip,
-- and contrast-adjusted syntax chunks on removed virtual lines.
local unified_buf = vim.api.nvim_create_buf(false, true)
local long_line = "local huge = '" .. ("x"):rep(1100) .. "'"
vim.api.nvim_buf_set_lines(unified_buf, 0, -1, false, {
    "local keep = 1",
    "local added = 42",
    long_line,
})
vim.bo[unified_buf].filetype = "lua"
vim.api.nvim_win_set_buf(plain_win, unified_buf)
vim.treesitter.start(unified_buf, "lua")

local fake_lsp_ns = vim.api.nvim_create_namespace("vim.lsp.semantic_tokens.test")
vim.api.nvim_buf_set_extmark(unified_buf, fake_lsp_ns, 1, 6, {
    end_col = 11,
    hl_group = "@lsp.type.variable",
    priority = 125,
})

diff_view.draw_overlay(unified_buf, {
    added = {
        { line = 2, words = { { start = 14, ["end"] = 16 } } },
        { line = 3, words = {} },
    },
    removed = {
        { above = 2, lines = { { text = "local old = 7", words = { { start = 12, ["end"] = 13 } } } } },
    },
}, plain_win)

local unified_marks = diff_contrast.collect_viewport_marks(plain_win, unified_buf, 0, 2)
local has_normal_45, has_ts_115, has_lsp_135 = false, false, false
for _, mark in ipairs(unified_marks) do
    assert(mark.row == 1, "only short added row 1 receives marks, got row " .. tostring(mark.row))
    assert(vim.startswith(mark.hl_group, "JprDiffAddFg_"), "added row uses JprDiffAddFg_* group: " .. tostring(mark.hl_group))
    if mark.priority == 45 and mark.col_start == 0 and mark.col_end == #"local added = 42" then
        has_normal_45 = true
    end
    if mark.priority == 115 and mark.col_start == 0 and mark.col_end == 5 then
        has_ts_115 = true
    end
    if mark.priority == 135 and mark.col_start == 6 and mark.col_end == 11 then
        has_lsp_135 = true
    end
end
assert(has_normal_45, "unified added line gets Normal fallback at priority 45")
assert(has_ts_115, "unified added line gets Treesitter contrast at priority 115")
assert(has_lsp_135, "unified added line gets LSP semantic-token contrast at priority 135")

-- Verify removed virtual line received contrast-adjusted syntax and word-diff chunks.
local diff_ns = vim.api.nvim_create_namespace("jpr-diff")
local found_removed_keyword, found_removed_word = false, false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(unified_buf, diff_ns, 0, -1, { details = true })) do
    local virt_lines = mark[4].virt_lines
    if virt_lines then
        for _, chunk in ipairs(virt_lines[1]) do
            local text, hl = chunk[1], chunk[2]
            if text == "local" and type(hl) == "table" and hl[1] == "JprDiffDelete" and vim.startswith(hl[2], "JprDiffDeleteFg_") then
                found_removed_keyword = true
            end
            if text == "7" and type(hl) == "table" and hl[1] == "JprDiffDeleteText" and vim.startswith(hl[2], "JprDiffDeleteFg_") then
                found_removed_word = true
            end
        end
    end
end
assert(found_removed_keyword, "removed virtual line highlights keyword with contrast-lifted JprDiffDeleteFg_*")
assert(found_removed_word, "removed virtual line highlights changed word with JprDiffDeleteText + contrast fg")

vim.cmd("redraw!")
diff_contrast.detach_window(plain_win)
diff_contrast.clear_buffer(unified_buf)
assert(#diff_contrast.collect_viewport_marks(plain_win, unified_buf, 0, 2) == 0, "detaching unified window stops marks")

-- Split :diffthis: both base_win (unfocused) and head_win (focused) compute
-- their own independent diff_hlID lines and contrast marks.
vim.cmd("tabnew")
local base_buf = vim.api.nvim_create_buf(false, true)
local head_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(base_buf, 0, -1, false, { "local same = 1", "local old_val = 1" })
vim.api.nvim_buf_set_lines(head_buf, 0, -1, false, { "local same = 1", "local new_val = 2" })
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

-- Keep head_win focused while inspecting unfocused base_win and focused head_win.
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
diff_contrast.detach_window(base_win)
diff_contrast.detach_window(head_win)
assert(#diff_contrast.collect_viewport_marks(base_win, base_buf, 0, 1) == 0, "detached base split stops marks")
assert(#diff_contrast.collect_viewport_marks(head_win, head_buf, 0, 1) == 0, "detached head split stops marks")

print("diff_contrast_spec: ok")
