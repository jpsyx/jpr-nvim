-- Specs for the reusable centered floating confirmation modal (`jpr.views.confirm`).
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local confirm = require("jpr.views.confirm")

local function has_highlight(layout, line_number, expected_group)
    local line_index = line_number - 1
    for _, highlight in ipairs(layout.highlights) do
        if highlight.line == line_index and highlight.group == expected_group then
            return true
        end
    end
    return false
end

local function test_layout_renders_headline_items_selection_and_hover_help()
    local spec = {
        title = " Send to Coding Agent ",
        headline = "Send 3 local review threads to Claude?",
        items = {
            "src/auth.rs:L42",
            "src/session.rs:L108-115",
            "PR conversation",
        },
        confirm_label = "Send 3 Threads to Claude",
        confirm_badge = "[send]",
        confirm_help = "Auto-submit these threads to the Claude terminal.",
        cancel_label = "Cancel",
        cancel_help = "Dismiss without sending.",
    }

    local first_layout = confirm.create_layout(spec, 1, 70)
    local first_text = table.concat(first_layout.lines, "\n")
    assert(not first_text:find("\226\128\148", 1, true), "layout must contain no em dashes")
    assert(first_text:find("Send 3 local review threads to Claude?", 1, true) ~= nil, "headline present")
    assert(first_text:find("  • src/auth.rs:L42", 1, true) ~= nil, "first bullet item present")
    assert(first_text:find("  • PR conversation", 1, true) ~= nil, "last bullet item present")
    assert(first_text:find("▸ Send 3 Threads to Claude  [send]", 1, true) ~= nil, "confirm selected")
    assert(first_text:find("Auto-submit these threads to the Claude terminal.", 1, true) ~= nil, "confirm help shown")
    assert(first_text:find("  Cancel  [cancel]", 1, true) ~= nil, "cancel unselected")
    assert(first_text:find("Dismiss without sending.", 1, true) == nil, "cancel help hidden when unselected")
    assert(first_text:find("[j/k] move  [Enter/Click] select  [q/Esc] cancel", 1, true) ~= nil, "footer present")
    assert(has_highlight(first_layout, first_layout.cursor_line, "JprTitle"), "selected option highlighted")

    local second_layout = confirm.create_layout(spec, 2, 70)
    local second_text = table.concat(second_layout.lines, "\n")
    assert(second_text:find("  Send 3 Threads to Claude  [send]", 1, true) ~= nil, "confirm unselected")
    assert(second_text:find("Auto-submit these threads to the Claude terminal.", 1, true) == nil, "confirm help hidden")
    assert(second_text:find("▸ Cancel  [cancel]", 1, true) ~= nil, "cancel selected")
    assert(second_text:find("Dismiss without sending.", 1, true) ~= nil, "cancel help shown")
    assert(second_layout.item_for_line[second_layout.cursor_line] == 2, "cursor_line maps to option 2")
end

local function test_open_confirm_cancel_close_and_winclosed()
    local confirms, cancels = 0, 0
    local state = confirm.open({
        title = " Send to Coding Agent ",
        headline = "Send 2 local review threads to Claude?",
        confirm_label = "Send 2 Threads to Claude",
        confirm_badge = "[send]",
        confirm_help = "Dispatch threads.",
        on_confirm = function()
            confirms = confirms + 1
        end,
        on_cancel = function()
            cancels = cancels + 1
        end,
    })
    assert(confirm.is_open(state) == true, "modal is open")
    local float_win = helpers.find_floating_win("Send to Coding Agent")
    assert(float_win ~= nil and float_win == state.win, "rounded floating modal opened")
    local win_cfg = vim.api.nvim_win_get_config(float_win)
    assert(vim.deep_equal(win_cfg.border, { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }), "rounded border")

    helpers.press_key("<CR>")
    assert(confirms == 1 and cancels == 0, "CR on option 1 invokes on_confirm once")
    assert(confirm.is_open(state) == false, "modal closed after confirm")

    -- Move down to Cancel and press <CR>.
    confirms, cancels = 0, 0
    local cancel_enter_state = confirm.open({
        title = " Send to Coding Agent ",
        headline = "Send 1 thread?",
        confirm_label = "Send",
        on_confirm = function() confirms = confirms + 1 end,
        on_cancel = function() cancels = cancels + 1 end,
    })
    helpers.press_key("j")
    helpers.press_key("<CR>")
    assert(confirms == 0 and cancels == 1, "j + CR invokes on_cancel once")
    assert(confirm.is_open(cancel_enter_state) == false, "modal closed after cancel")

    -- Cancel via q and <Esc>.
    for _, key in ipairs({ "q", "<Esc>" }) do
        confirms, cancels = 0, 0
        local key_state = confirm.open({
            title = " Confirm Action ",
            headline = "Proceed?",
            confirm_label = "Yes",
            on_confirm = function() confirms = confirms + 1 end,
            on_cancel = function() cancels = cancels + 1 end,
        })
        helpers.press_key(key)
        assert(confirms == 0 and cancels == 1, key .. " invokes on_cancel once")
        assert(confirm.is_open(key_state) == false, key .. " closes modal")
    end

    -- External WinClosed fires on_cancel exactly once.
    confirms, cancels = 0, 0
    local winclosed_state = confirm.open({
        title = " External Close ",
        headline = "Proceed?",
        confirm_label = "Yes",
        on_confirm = function() confirms = confirms + 1 end,
        on_cancel = function() cancels = cancels + 1 end,
    })
    vim.api.nvim_win_close(winclosed_state.win, true)
    assert(vim.wait(1000, function() return cancels == 1 end), "external WinClosed fires on_cancel once")
    assert(confirms == 0 and cancels == 1, "WinClosed does not invoke on_confirm")

    -- Programmatic confirm.close(state) never triggers on_cancel.
    confirms, cancels = 0, 0
    local programmatic_state = confirm.open({
        title = " Programmatic Close ",
        headline = "Proceed?",
        confirm_label = "Yes",
        on_confirm = function() confirms = confirms + 1 end,
        on_cancel = function() cancels = cancels + 1 end,
    })
    confirm.close(programmatic_state)
    vim.wait(50, function() return false end)
    assert(confirm.is_open(programmatic_state) == false, "confirm.close closes modal")
    assert(confirms == 0 and cancels == 0, "confirm.close never invokes on_cancel")

    -- Mouse clicks: footer [q/Esc] cancel and outside click both invoke on_cancel once.
    local original_getmousepos = vim.fn.getmousepos
    local is_mouse_ok, mouse_error = pcall(function()
        confirms, cancels = 0, 0
        local footer_state = confirm.open({
            title = " Footer Cancel ",
            headline = "Proceed?",
            confirm_label = "Yes",
            on_confirm = function() confirms = confirms + 1 end,
            on_cancel = function() cancels = cancels + 1 end,
        })
        local footer_lines = helpers.current_lines()
        local cancel_col = footer_lines[#footer_lines]:find("[q/Esc] cancel", 1, true)
        assert(cancel_col ~= nil, "found [q/Esc] cancel in confirm footer")
        vim.fn.getmousepos = function() return { winid = footer_state.win, line = #footer_lines, column = cancel_col + 2 } end
        helpers.press_key("<LeftMouse>")
        assert(confirms == 0 and cancels == 1 and confirm.is_open(footer_state) == false, "footer cancel click cancels modal")

        confirms, cancels = 0, 0
        local outside_state = confirm.open({
            title = " Outside Cancel ",
            headline = "Proceed?",
            confirm_label = "Yes",
            on_confirm = function() confirms = confirms + 1 end,
            on_cancel = function() cancels = cancels + 1 end,
        })
        vim.fn.getmousepos = function() return { winid = 999999, line = 1, column = 1 } end
        helpers.press_key("<LeftMouse>")
        assert(confirms == 0 and cancels == 1 and confirm.is_open(outside_state) == false, "outside click cancels confirm modal")
    end)
    vim.fn.getmousepos = original_getmousepos
    assert(is_mouse_ok, tostring(mouse_error))
end

test_layout_renders_headline_items_selection_and_hover_help()
test_open_confirm_cancel_close_and_winclosed()

print("confirm_view_spec: ok")
