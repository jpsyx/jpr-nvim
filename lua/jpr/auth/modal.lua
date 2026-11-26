-- Centered floating GitHub authentication prompt modal supporting both Neovim
-- keyboard controls and `<LeftMouse>` button clicks.
local mouse = require("jpr.mouse")
local render = require("jpr.tui.render")
local window = require("jpr.tui.wizard.window")

local M = {}

local SELECTED_PREFIX = "▸ "
local UNSELECTED_PREFIX = "  "
local HELP_INDENT = "    "
local MODAL_TITLE = " GitHub Authentication Required "
local MODAL_FOOTER = "[j/k] move  [Enter/Click] select  [q/Esc] cancel"
local MODAL_FOOTER_SPECS = {
    { token = "[Enter/Click] select", action = "confirm" },
    { token = "[q/Esc] cancel", action = "cancel" },
}

local OPTIONS = {
    {
        id = "auth",
        label = "Authenticate with GitHub",
        badge = "[auth]",
        help = "Run `gh auth login` here and continue automatically once signed in.",
    },
    {
        id = "cancel",
        label = "Cancel",
        badge = "[cancel]",
        help = "Dismiss without authenticating.",
    },
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

--- Builds lines, highlights, cursor line, and row-to-option mapping for the
--- authentication prompt modal.
function M.create_layout(selected_index, detail_message, max_width)
    local width = math.max(1, tonumber(max_width) or 80)
    local layout = { lines = {}, highlights = {}, cursor_line = 1, item_for_line = {} }
    append_wrapped_lines(
        layout,
        "Jpr cannot work without an authenticated GitHub CLI (gh).",
        "",
        width,
        "JprTitle",
        nil
    )
    if type(detail_message) == "string" and vim.trim(detail_message) ~= "" then
        append_line(layout, "", nil)
        append_wrapped_lines(layout, detail_message, "", width, "JprError", nil)
    end
    append_line(layout, "", nil)
    local clamped = math.max(1, math.min(tonumber(selected_index) or 1, #OPTIONS))
    for option_index, option in ipairs(OPTIONS) do
        append_option_row(layout, option, option_index, option_index == clamped, width)
    end
    append_line(layout, "", nil)
    append_line(layout, MODAL_FOOTER, "JprMuted")
    return layout
end

local function paint_modal(state)
    if not state.is_open or not state.win or not vim.api.nvim_win_is_valid(state.win) then
        return
    end
    local width = window.get_modal_width()
    state.layout = M.create_layout(state.selected_index, state.detail_message, width)
    state.is_painting = true
    window.paint_menu_window(state.buf, state.win, state.layout, width)
    state.is_painting = false
end

local function activate_selected(state, callbacks)
    local option = OPTIONS[state.selected_index]
    if not option then
        return
    end
    M.close(state)
    if option.id == "auth" then
        callbacks.on_authenticate()
    else
        callbacks.on_cancel()
    end
end

local function handle_auth_click(state, callbacks, cancel)
    local click = mouse.get_click()
    if not click then
        return
    end
    if not mouse.is_click_in_window(click, state.win) then
        return cancel()
    end
    local clicked_index = state.layout and state.layout.item_for_line[click.line]
    if clicked_index ~= nil then
        state.selected_index = clicked_index
        return activate_selected(state, callbacks)
    end
    local action = mouse.hit_test_footer_line(state.layout and state.layout.lines, MODAL_FOOTER_SPECS, click)
    if action == "confirm" then
        activate_selected(state, callbacks)
    elseif action == "cancel" then
        cancel()
    end
end

local function bind_modal_keys(state, callbacks)
    local map = function(lhs, handler)
        vim.keymap.set("n", lhs, handler, { buffer = state.buf, nowait = true, silent = true })
    end
    local move_to = function(target_index)
        state.selected_index = ((target_index - 1) % #OPTIONS) + 1
        paint_modal(state)
    end
    local confirm = function()
        activate_selected(state, callbacks)
    end
    local cancel = function()
        M.close(state)
        callbacks.on_cancel()
    end
    for _, lhs in ipairs({ "j", "<Down>" }) do map(lhs, function() move_to(state.selected_index + 1) end) end
    for _, lhs in ipairs({ "k", "<Up>" }) do map(lhs, function() move_to(state.selected_index - 1) end) end
    for _, lhs in ipairs({ "gg", "<Home>" }) do map(lhs, function() move_to(1) end) end
    for _, lhs in ipairs({ "G", "<End>" }) do map(lhs, function() move_to(#OPTIONS) end) end
    for _, lhs in ipairs({ "<CR>", "l", "<Right>", "<Tab>" }) do map(lhs, confirm) end
    for _, lhs in ipairs({ "q", "<Esc>" }) do map(lhs, cancel) end
    map("<LeftMouse>", function() handle_auth_click(state, callbacks, cancel) end)
end

local function register_modal_autocmds(state, callbacks)
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = state.buf,
        callback = function()
            if state.is_painting or not state.is_open or not vim.api.nvim_win_is_valid(state.win) then
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
            if not state.is_open then
                return
            end
            state.is_open = false
            local buf = state.buf
            state.win, state.buf = nil, nil
            vim.schedule(function()
                window.close_handle(nil, buf)
                callbacks.on_cancel()
            end)
        end,
    })
end

--- Closes the active authentication prompt modal `state` if open.
function M.close(state)
    if not state then
        return
    end
    state.is_open = false
    local win, buf = state.win, state.buf
    state.win, state.buf = nil, nil
    window.close_handle(win, buf)
end

--- Opens the centered authentication prompt modal and returns its `state`.
function M.open(detail_message, callbacks)
    require("jpr").define_highlights()
    local width = window.get_modal_width()
    local layout = M.create_layout(1, detail_message, width)
    local state = {
        is_open = true,
        is_painting = true,
        selected_index = 1,
        detail_message = detail_message,
        layout = layout,
    }
    state.buf, state.win = window.create_menu_window(MODAL_TITLE, layout, width)
    state.is_painting = false
    bind_modal_keys(state, callbacks)
    register_modal_autocmds(state, callbacks)
    return state
end

return M
