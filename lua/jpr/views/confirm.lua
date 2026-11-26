-- Reusable centered floating confirmation modal supporting Neovim keyboard
-- controls and `<LeftMouse>` selection.
local mouse = require("jpr.mouse")
local render = require("jpr.tui.render")
local window = require("jpr.tui.wizard.window")

local M = {}

local SELECTED_PREFIX = "▸ "
local UNSELECTED_PREFIX = "  "
local HELP_INDENT = "    "
local ITEM_PREFIX = "  • "
local MODAL_FOOTER = "[j/k] move  [Enter/Click] select  [q/Esc] cancel"
local MODAL_FOOTER_SPECS = {
    { token = "[Enter/Click] select", action = "confirm" },
    { token = "[q/Esc] cancel", action = "cancel" },
}

local function append_highlight(highlights, line_index, col_start, col_end, group)
    if group and col_end > col_start then
        highlights[#highlights + 1] = {
            line = line_index,
            col_start = col_start,
            col_end = col_end,
            group = group,
        }
    end
end

local function append_line(layout, text, group)
    layout.lines[#layout.lines + 1] = text
    local row_number = #layout.lines
    if group then
        append_highlight(layout.highlights, row_number - 1, 0, #text, group)
    end
    return row_number
end

local function append_wrapped_lines(layout, text, indent, max_width, group, item_index)
    if type(text) ~= "string" or vim.trim(text) == "" then
        return
    end
    local available = math.max(1, max_width - vim.fn.strdisplaywidth(indent))
    for _, wrapped_line in ipairs(render.wrap_text(text, available)) do
        local row_number = append_line(layout, indent .. wrapped_line, group)
        if item_index ~= nil then
            layout.item_for_line[row_number] = item_index
        end
    end
end

local function build_options_from_spec(spec)
    return {
        {
            id = "confirm",
            label = tostring(spec.confirm_label or "Confirm"),
            badge = tostring(spec.confirm_badge or "[confirm]"),
            help = spec.confirm_help,
        },
        {
            id = "cancel",
            label = tostring(spec.cancel_label or "Cancel"),
            badge = "[cancel]",
            help = spec.cancel_help or "Dismiss without sending.",
        },
    }
end

local function append_option_row(layout, option, option_index, is_selected, max_width)
    local prefix = is_selected and SELECTED_PREFIX or UNSELECTED_PREFIX
    local row_text = prefix .. option.label .. "  " .. option.badge
    local row_number = append_line(layout, row_text, nil)
    local line_index = row_number - 1
    layout.item_for_line[row_number] = option_index
    if is_selected then
        layout.cursor_line = row_number
        append_highlight(layout.highlights, line_index, 0, #prefix + #option.label, "JprTitle")
    end
    local badge_start = #prefix + #option.label + 2
    append_highlight(layout.highlights, line_index, badge_start, badge_start + #option.badge, "JprMuted")
    if is_selected then
        append_wrapped_lines(layout, option.help, HELP_INDENT, max_width, "JprMuted", option_index)
    end
end

--- Builds lines, highlights, cursor line, and row-to-option mapping for a
--- confirmation modal described by `spec`.
function M.create_layout(spec, selected_index, max_width)
    local width = math.max(1, tonumber(max_width) or 80)
    local layout = { lines = {}, highlights = {}, cursor_line = 1, item_for_line = {} }
    append_wrapped_lines(layout, tostring(spec.headline or ""), "", width, "JprTitle", nil)
    local items = type(spec.items) == "table" and spec.items or {}
    if #items > 0 then
        append_line(layout, "", nil)
        for _, item in ipairs(items) do
            append_wrapped_lines(layout, tostring(item), ITEM_PREFIX, width, "JprMuted", nil)
        end
    end
    append_line(layout, "", nil)
    local options = build_options_from_spec(spec)
    local clamped = math.max(1, math.min(tonumber(selected_index) or 1, #options))
    for option_index, option in ipairs(options) do
        append_option_row(layout, option, option_index, option_index == clamped, width)
    end
    append_line(layout, "", nil)
    append_line(layout, MODAL_FOOTER, "JprMuted")
    return layout
end

local function paint_modal(state)
    if not M.is_open(state) then
        return
    end
    local width = window.get_modal_width()
    state.layout = M.create_layout(state.spec, state.selected_index, width)
    state.is_painting = true
    window.paint_menu_window(state.buf, state.win, state.layout, width)
    state.is_painting = false
end

local function settle(state, action)
    if state.is_settled then
        return
    end
    state.is_settled = true
    M.close(state)
    if action == "confirm" then
        if type(state.spec.on_confirm) == "function" then
            state.spec.on_confirm()
        end
    elseif type(state.spec.on_cancel) == "function" then
        state.spec.on_cancel()
    end
end

local function activate_selected(state)
    if state.selected_index == 1 then
        settle(state, "confirm")
    else
        settle(state, "cancel")
    end
end

local function bind_modal_keys(state)
    local map = function(lhs, handler)
        vim.keymap.set("n", lhs, handler, { buffer = state.buf, nowait = true, silent = true })
    end
    local move_to = function(target_index)
        state.selected_index = ((target_index - 1) % 2) + 1
        paint_modal(state)
    end
    local handle_click = function()
        local click = mouse.get_click()
        if not click then
            return
        end
        if not mouse.is_click_in_window(click, state.win) then
            return settle(state, "cancel")
        end
        local clicked_index = state.layout and state.layout.item_for_line[click.line]
        if clicked_index ~= nil then
            state.selected_index = clicked_index
            return activate_selected(state)
        end
        local lines = state.layout and state.layout.lines or {}
        local footer_line = #lines
        local spans = mouse.parse_footer_actions(lines[footer_line], MODAL_FOOTER_SPECS)
        local action = mouse.hit_test_footer_action(footer_line, spans, click.line, click.column)
        if action == "confirm" then
            activate_selected(state)
        elseif action == "cancel" then
            settle(state, "cancel")
        end
    end
    for _, lhs in ipairs({ "j", "<Down>" }) do map(lhs, function() move_to(state.selected_index + 1) end) end
    for _, lhs in ipairs({ "k", "<Up>" }) do map(lhs, function() move_to(state.selected_index - 1) end) end
    for _, lhs in ipairs({ "gg", "<Home>" }) do map(lhs, function() move_to(1) end) end
    for _, lhs in ipairs({ "G", "<End>" }) do map(lhs, function() move_to(2) end) end
    for _, lhs in ipairs({ "<CR>", "l", "<Right>", "<Tab>" }) do map(lhs, function() activate_selected(state) end) end
    for _, lhs in ipairs({ "q", "<Esc>" }) do map(lhs, function() settle(state, "cancel") end) end
    map("<LeftMouse>", handle_click)
end

local function register_modal_autocmds(state)
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = state.buf,
        callback = function()
            if state.is_painting or not M.is_open(state) then
                return
            end
            local row = vim.api.nvim_win_get_cursor(state.win)[1]
            local hovered = state.layout and state.layout.item_for_line[row]
            if hovered ~= nil and hovered ~= state.selected_index then
                state.selected_index = hovered
                paint_modal(state)
            end
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(state.win),
        once = true,
        callback = function()
            if state.is_settled then
                return
            end
            state.win = nil
            vim.schedule(function()
                settle(state, "cancel")
            end)
        end,
    })
end

--- Whether confirmation modal `state` currently has a valid open window and buffer.
function M.is_open(state)
    return state ~= nil
        and state.is_open == true
        and state.win ~= nil
        and state.buf ~= nil
        and vim.api.nvim_win_is_valid(state.win)
        and vim.api.nvim_buf_is_valid(state.buf)
end

--- Programmatically closes confirmation modal `state` without firing `on_cancel`.
function M.close(state)
    if not state then
        return
    end
    state.is_settled = true
    state.is_open = false
    local win, buf = state.win, state.buf
    state.win, state.buf = nil, nil
    window.close_handle(win, buf)
end

--- Opens a centered floating confirmation modal from `spec` and returns its `state`.
function M.open(spec)
    require("jpr").define_highlights()
    local modal_spec = type(spec) == "table" and spec or {}
    local width = window.get_modal_width()
    local layout = M.create_layout(modal_spec, 1, width)
    local title = tostring(modal_spec.title or " Confirm ")
    local state = {
        is_open = true,
        is_settled = false,
        is_painting = true,
        selected_index = 1,
        spec = modal_spec,
        layout = layout,
    }
    state.buf, state.win = window.create_menu_window(title, layout, width)
    state.is_painting = false
    bind_modal_keys(state)
    register_modal_autocmds(state)
    return state
end

return M
