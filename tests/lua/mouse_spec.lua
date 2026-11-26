-- Pure unit tests and cursor/passthrough tests for `jpr.mouse`.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local mouse = require("jpr.mouse")

-- 1. is_click_in_window validates table shape, matching winid, and positive line.
assert(mouse.is_click_in_window({ winid = 42, line = 1, column = 3 }, 42) == true, "matching winid and line >= 1")
assert(mouse.is_click_in_window({ winid = 42, line = 5, column = 1 }, 99) == false, "mismatched winid rejected")
assert(mouse.is_click_in_window({ winid = 42, line = 0, column = 1 }, 42) == false, "zero line rejected")
assert(mouse.is_click_in_window({ winid = 0, line = 1, column = 1 }, 42) == false, "zero winid rejected")
assert(mouse.is_click_in_window(nil, 42) == false, "nil mouse rejected")
assert(mouse.is_click_in_window({ winid = 42, line = 1 }, nil) == false, "nil win rejected")

-- 2. parse_footer_actions locates exact 1-based inclusive column spans for tokens.
local popup_footer = "[r]eply  [e]dit  [d]elete  [R]esolve  [+]react  [X]retry  [q]uit"
local popup_specs = {
    { token = "[r]eply", action = "reply" },
    { token = "[e]dit", action = "edit" },
    { token = "[d]elete", action = "delete" },
    { token = "[R]esolve", action = "resolve" },
    { token = "[+]react", action = "react" },
    { token = "[X]retry", action = "retry" },
    { token = "[p]romote", action = "promote" },
    { token = "[q]uit", action = "close" },
}
local spans = mouse.parse_footer_actions(popup_footer, popup_specs)
assert(#spans == 7, "absent token [p]romote is skipped cleanly: got " .. tostring(#spans))
assert(spans[1].action == "reply" and spans[1].col_start == 1 and spans[1].col_end == 7, "reply span exact")
assert(spans[5].action == "react", "literal + in [+]react matched without regex issues")
assert(
    popup_footer:sub(spans[5].col_start, spans[5].col_end) == "[+]react",
    "react span slices exact token"
)
assert(
    popup_footer:sub(spans[7].col_start, spans[7].col_end) == "[q]uit",
    "quit span slices exact token"
)

-- Special characters like <CR> and <C-s> are matched literally.
local submit_footer = "[1/2/3] action  [e] summary  [<CR>] open draft / submit  [<C-s>] submit  [q] cancel"
local submit_spans = mouse.parse_footer_actions(submit_footer, {
    { token = "[e] summary", action = "summary" },
    { token = "[<C-s>] submit", action = "submit" },
    { token = "[q] cancel", action = "close" },
})
assert(#submit_spans == 3, "submit spans count")
assert(
    submit_footer:sub(submit_spans[2].col_start, submit_spans[2].col_end) == "[<C-s>] submit",
    "submit token with angle brackets and hyphen matched literally"
)

-- 3. hit_test_footer_action matches start, middle, end columns and rejects gaps/wrong lines.
assert(mouse.hit_test_footer_action(10, spans, 10, 1) == "reply", "start boundary hits")
assert(mouse.hit_test_footer_action(10, spans, 10, 4) == "reply", "middle column hits")
assert(mouse.hit_test_footer_action(10, spans, 10, 7) == "reply", "end boundary hits")
assert(mouse.hit_test_footer_action(10, spans, 10, 8) == nil, "gap between tokens misses")
assert(mouse.hit_test_footer_action(10, spans, 10, 9) == nil, "second gap column misses")
assert(mouse.hit_test_footer_action(10, spans, 10, 10) == "edit", "next token hits")
assert(mouse.hit_test_footer_action(10, spans, 9, 1) == nil, "wrong line misses")
assert(mouse.hit_test_footer_action(10, spans, 10, 0) == nil, "zero column misses")
assert(mouse.hit_test_footer_action(nil, spans, 10, 1) == nil, "nil footer_line misses")

-- 4. set_cursor_from_click clamps row/column safely inside a real buffer window.
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha", "beta gamma", "delta" })
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)
mouse.set_cursor_from_click(win, { winid = win, line = 2, column = 6 })
local cursor = vim.api.nvim_win_get_cursor(win)
assert(cursor[1] == 2 and cursor[2] == 5, "places cursor at clicked 1-based line and 0-based col")
mouse.set_cursor_from_click(win, { winid = win, line = 99, column = 99 })
local clamped = vim.api.nvim_win_get_cursor(win)
assert(clamped[1] == 3 and clamped[2] == 4, "clamps out-of-range line and column safely")
vim.api.nvim_buf_delete(buf, { force = true })

-- 5. passthrough forwards the native key with 'n' mode without remapping.
local fed = {}
local original_feedkeys = vim.api.nvim_feedkeys
vim.api.nvim_feedkeys = function(keys, mode, escape_ks)
    fed[#fed + 1] = { keys = keys, mode = mode, escape_ks = escape_ks }
end
local ok, err = pcall(function()
    mouse.passthrough()
    mouse.passthrough("<2-LeftMouse>")
end)
vim.api.nvim_feedkeys = original_feedkeys
assert(ok, tostring(err))
assert(#fed == 2, "passthrough invoked nvim_feedkeys twice")
assert(fed[1].keys == vim.keycode("<LeftMouse>") and fed[1].mode == "n" and fed[1].escape_ks == false, "default LeftMouse passthrough")
assert(fed[2].keys == vim.keycode("<2-LeftMouse>") and fed[2].mode == "n" and fed[2].escape_ks == false, "2-LeftMouse passthrough")

print("mouse_spec.lua: ok")
