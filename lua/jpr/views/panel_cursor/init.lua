-- Sidebar selection: hide the cursor block, brighten the current row, raise each
-- fragment's contrast against that row, and reveal clipped file or directory
-- names past the panel.
local fragments_mod = require("jpr.views.panel_cursor.fragments")
local overflow = require("jpr.views.panel_cursor.overflow")

local M = {}

local HIDDEN_CURSOR = "a:JprPanelHiddenCursor/JprPanelHiddenCursor"
local selection_namespace = vim.api.nvim_create_namespace("jpr-panel-selection")
local saved_guicursor = nil
local is_syncing = false

M.build_line_fragments = fragments_mod.build_line_fragments
M.adjust_fragment_foregrounds = fragments_mod.adjust_fragment_foregrounds
M.plan_overflow = fragments_mod.plan_overflow
M.build_tooltip_lines = fragments_mod.build_tooltip_lines

local function conceal_cursor()
    vim.api.nvim_set_hl(0, "JprPanelHiddenCursor", { blend = 100, nocombine = true })
    if saved_guicursor == nil then
        saved_guicursor = vim.api.nvim_get_option_value("guicursor", {})
    end
    vim.api.nvim_set_option_value("guicursor", HIDDEN_CURSOR, {})
end

local function restore_cursor()
    if saved_guicursor == nil then
        return
    end
    vim.api.nvim_set_option_value("guicursor", saved_guicursor, {})
    saved_guicursor = nil
end

local function is_focused_panel(panel)
    return type(panel) == "table"
        and type(panel.win) == "number"
        and type(panel.buf) == "number"
        and vim.api.nvim_win_is_valid(panel.win)
        and vim.api.nvim_buf_is_valid(panel.buf)
        and vim.api.nvim_get_current_win() == panel.win
end

local function selection_fragments(panel, line_number, background)
    local line_index = line_number - 1
    local text = vim.api.nvim_buf_get_lines(panel.buf, line_index, line_number, false)[1] or ""
    local fragments = fragments_mod.build_line_fragments(text, fragments_mod.spans_on_line(panel.highlights, line_index), "Normal")
    return text, fragments_mod.adjust_fragment_foregrounds(fragments, fragments_mod.foregrounds_for_fragments(fragments), background)
end

local function refresh_focused_panel(panel)
    conceal_cursor()
    local background = fragments_mod.apply_selection_background(panel.win)
    local line_number = vim.api.nvim_win_get_cursor(panel.win)[1]
    local text, fragments = selection_fragments(panel, line_number, background)
    vim.api.nvim_buf_clear_namespace(panel.buf, selection_namespace, 0, -1)
    fragments_mod.paint_fragments(panel.buf, selection_namespace, line_number - 1, fragments)
    overflow.show(panel, selection_namespace, line_number, text, fragments, background)
end

--- Hides the cursor, brightens the current row, and reveals a clipped name
--- while `panel.win` is the current window. An unfocused panel is cleared.
function M.sync(panel)
    if is_syncing then
        return
    end
    if not is_focused_panel(panel) then
        return M.clear(panel)
    end
    is_syncing = true
    local ok, err = pcall(refresh_focused_panel, panel)
    is_syncing = false
    if not ok then
        error(err, 0)
    end
end

--- Restores the cursor, the row colors, and closes any name overflow.
function M.clear(panel)
    restore_cursor()
    if type(panel) ~= "table" then
        return
    end
    if type(panel.win) == "number" and vim.api.nvim_win_is_valid(panel.win) then
        fragments_mod.set_managed_winhighlight(panel.win, { Cursor = false, CursorLine = false })
        overflow.close(panel.win)
    elseif type(panel.win) == "number" then
        overflow.close(panel.win)
    end
    if type(panel.buf) == "number" and vim.api.nvim_buf_is_valid(panel.buf) then
        vim.api.nvim_buf_clear_namespace(panel.buf, selection_namespace, 0, -1)
    end
end

return M
