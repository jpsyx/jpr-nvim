-- Spec for the jpr-owned top-right color-coded floating toast stack and live progress spinners.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local highlights = require("jpr.highlights")
local notify = require("jpr.notify")

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(label or "assert_eq", vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

local function reset()
    notify.clear()
    notify.set_listener(nil)
    highlights.define_highlights()
end

-- 1. Semantic highlight links for error (red), success (green), info (blue), warn (amber), progress (blue)
reset()
local expected_links = {
    JprNotifyErrorBorder = "DiagnosticError",
    JprNotifyErrorTitle = "DiagnosticError",
    JprNotifySuccessBorder = "DiagnosticOk",
    JprNotifySuccessTitle = "DiagnosticOk",
    JprNotifyInfoBorder = "DiagnosticInfo",
    JprNotifyInfoTitle = "DiagnosticInfo",
    JprNotifyWarnBorder = "DiagnosticWarn",
    JprNotifyWarnTitle = "DiagnosticWarn",
    JprNotifyProgressBorder = "DiagnosticInfo",
    JprNotifyProgressTitle = "DiagnosticInfo",
}
for group_name, expected_link in pairs(expected_links) do
    local hl = vim.api.nvim_get_hl(0, { name = group_name, link = true })
    assert_eq(hl.link, expected_link, "highlight link for " .. group_name)
end

-- 2. Top-right non-focusable floating window placement and zero vim.notify leakage
reset()
local vim_notify_called = false
local original_vim_notify = vim.notify
vim.notify = function()
    vim_notify_called = true
end
local ok_test, test_err = pcall(function()
    jpr.error("something broke")
    local toasts = notify.get_toasts()
    assert_eq(#toasts, 1, "one error toast visible")
    assert_eq(vim_notify_called, false, "jpr.notify must not call vim.notify")
    local toast = toasts[1]
    assert_eq(toast.kind, "error", "toast kind")
    assert(vim.api.nvim_win_is_valid(toast.win), "toast window must be valid")
    local win_cfg = vim.api.nvim_win_get_config(toast.win)
    assert_eq(win_cfg.anchor, "NE", "top-right anchor")
    assert_eq(win_cfg.focusable, false, "non-focusable")
    local winhl = vim.api.nvim_get_option_value("winhighlight", { win = toast.win })
    assert(winhl:find("FloatBorder:JprNotifyErrorBorder", 1, true) ~= nil, "red error border: " .. winhl)
    assert(winhl:find("FloatTitle:JprNotifyErrorTitle", 1, true) ~= nil, "red error title: " .. winhl)
end)
vim.notify = original_vim_notify
assert(ok_test, test_err)

-- 3. Color coding for success (green), info (blue), warn (amber)
reset()
jpr.success("review submitted")
jpr.info("3 files changed")
jpr.warn("ahead of target")
local color_toasts = notify.get_toasts()
assert_eq(#color_toasts, 3, "three stacked toasts")
assert(vim.api.nvim_get_option_value("winhighlight", { win = color_toasts[1].win }):find("JprNotifySuccessBorder", 1, true) ~= nil, "green success border")
assert(vim.api.nvim_get_option_value("winhighlight", { win = color_toasts[2].win }):find("JprNotifyInfoBorder", 1, true) ~= nil, "blue info border")
assert(vim.api.nvim_get_option_value("winhighlight", { win = color_toasts[3].win }):find("JprNotifyWarnBorder", 1, true) ~= nil, "amber warn border")

-- 4. Stacking downward without overlap + reflow + max cap eviction
reset()
local id1 = notify.info("first", { timeout_ms = 60000 })
notify.info("second", { timeout_ms = 60000 })
notify.info("third", { timeout_ms = 60000 })
local stacked = notify.get_toasts()
assert_eq(#stacked, 3, "3 stacked toasts")
local row1 = vim.api.nvim_win_get_config(stacked[1].win).row
local row2 = vim.api.nvim_win_get_config(stacked[2].win).row
local row3 = vim.api.nvim_win_get_config(stacked[3].win).row
assert(row2 > row1, "second toast stacked below first")
assert(row3 > row2, "third toast stacked below second")

notify.dismiss(id1)
local after_dismiss = notify.get_toasts()
assert_eq(#after_dismiss, 2, "2 toasts remain after dismiss")
assert_eq(vim.api.nvim_win_get_config(after_dismiss[1].win).row, row1, "remaining toasts reflow upward")

-- Max 6 visible toasts cap evicts oldest non-progress toast
reset()
for index = 1, 8 do
    notify.info("msg " .. index, { timeout_ms = 60000 })
end
assert_eq(#notify.get_toasts(), 6, "capped at 6 visible toasts")

-- 5. Immediate progress lifecycle: update in place, transition to green/red
reset()
local handle = notify.progress("Submitting review to GitHub...")
local prog_toasts = notify.get_toasts()
assert_eq(#prog_toasts, 1, "immediate progress toast opens")
local prog_win = prog_toasts[1].win
handle:update("Still submitting...")
assert_eq(#notify.get_toasts(), 1, "update reuses same toast")
assert_eq(notify.get_toasts()[1].win, prog_win, "same window reused")
local lines = vim.api.nvim_buf_get_lines(notify.get_toasts()[1].buf, 0, -1, false)
assert(table.concat(lines, "\n"):find("Still submitting...", 1, true) ~= nil, "updated text shown")

handle:succeed("Review submitted")
assert_eq(notify.get_toasts()[1].kind, "success", "transitioned to success")
assert(vim.api.nvim_get_option_value("winhighlight", { win = notify.get_toasts()[1].win }):find("JprNotifySuccessBorder", 1, true) ~= nil, "green border after succeed")

local fail_handle = notify.progress("Pushing...")
fail_handle:fail("push failed: rejected")
local latest = notify.get_toasts()[#notify.get_toasts()]
assert_eq(latest.kind, "error", "transitioned to error")
assert(vim.api.nvim_get_option_value("winhighlight", { win = latest.win }):find("JprNotifyErrorBorder", 1, true) ~= nil, "red border after fail")

-- 6. Delayed progress (delay_ms = 150) cancelled before threshold never flickers
reset()
local fast_handle = notify.progress("Fast local op...", { delay_ms = 150 })
assert_eq(#notify.get_toasts(), 0, "delayed progress not visible immediately")
fast_handle:cancel()
vim.wait(200, function() return false end)
assert_eq(#notify.get_toasts(), 0, "cancelled delayed progress never opened")

-- Delayed progress that stays in flight opens after delay_ms
local slow_handle = notify.progress("Slow op...", { delay_ms = 40 })
assert_eq(#notify.get_toasts(), 0, "not visible before delay")
local did_appear = vim.wait(300, function()
    return #notify.get_toasts() == 1
end, 10)
assert(did_appear, "delayed progress appeared once delay elapsed")
slow_handle:cancel()
assert_eq(#notify.get_toasts(), 0, "cancelled visible progress closed")

-- 7. Clean teardown while spinners are active
reset()
notify.progress("Spinning 1...")
notify.progress("Spinning 2...")
assert_eq(#notify.get_toasts(), 2, "two spinners active")
notify.clear()
assert_eq(#notify.get_toasts(), 0, "all toasts cleared cleanly")
