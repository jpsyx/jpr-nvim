-- Floating extension and tooltip window management for clipped sidebar panel rows.
local contrast = require("jpr.highlights.contrast")
local fragments_mod = require("jpr.views.panel_cursor.fragments")

local M = {}

local CONTRAST_BOOST = 0.10
local TOOLTIP_MAX_WIDTH = 56
local overflow_by_win = {}

--- Closes any active overflow float attached to `panel_win`.
function M.close(panel_win)
    local state = overflow_by_win[panel_win]
    overflow_by_win[panel_win] = nil
    if not state then
        return
    end
    if state.win and vim.api.nvim_win_is_valid(state.win) then
        pcall(vim.api.nvim_win_close, state.win, true)
    end
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
    end
end

local function cursor_screen_position(win)
    local position = vim.api.nvim_win_get_position(win)
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
    local top_line = vim.api.nvim_win_call(win, function()
        return vim.fn.line("w0")
    end)
    return position[1] + cursor_line - top_line, position[2]
end

local function style_float(float_win, normal_group)
    vim.api.nvim_set_option_value("wrap", false, { win = float_win, scope = "local" })
    vim.api.nvim_set_option_value("cursorline", false, { win = float_win, scope = "local" })
    vim.api.nvim_set_option_value("winhighlight", "Normal:" .. normal_group .. ",NormalFloat:" .. normal_group, {
        win = float_win,
        scope = "local",
    })
end

local function reuse_float(state, lines, config, normal_group)
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    vim.bo[state.buf].modifiable = false
    if not pcall(vim.api.nvim_win_set_config, state.win, config) then
        return false
    end
    style_float(state.win, normal_group)
    return true
end

local function can_reuse_float(state)
    return state and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_buf_is_valid(state.buf)
end

local function ensure_float(panel_win, lines, config, normal_group)
    local state = overflow_by_win[panel_win]
    if can_reuse_float(state) and reuse_float(state, lines, config, normal_group) then
        return state
    end
    M.close(panel_win)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    local ok, float_win = pcall(vim.api.nvim_open_win, buf, false, config)
    if not ok then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        return nil
    end
    style_float(float_win, normal_group)
    state = { win = float_win, buf = buf }
    overflow_by_win[panel_win] = state
    return state
end

local function float_config(row, col, width, height, zindex)
    return {
        relative = "editor",
        row = math.max(0, row),
        col = math.max(0, col),
        width = math.max(1, width),
        height = math.max(1, height),
        style = "minimal",
        border = "none",
        focusable = false,
        mouse = false,
        noautocmd = true,
        zindex = zindex,
    }
end

local function widest_line(lines)
    local width = 1
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    return width
end

local function show_extension(panel, selection_namespace, text, fragments, screen_row, screen_col)
    local width = vim.fn.strdisplaywidth(text)
    local config = float_config(screen_row, screen_col, width, 1, 40)
    local state = ensure_float(panel.win, { text }, config, "JprPanelCursorLine")
    if not state then
        return false
    end
    vim.api.nvim_buf_clear_namespace(state.buf, selection_namespace, 0, -1)
    fragments_mod.paint_fragments(state.buf, selection_namespace, 0, fragments)
    return true
end

local function tooltip_lines_for(text, screen_col, window_width)
    local columns = vim.o.columns
    local anchor = screen_col + window_width
    local available = math.max(8, columns - math.min(anchor, columns - 1))
    local limit = math.min(TOOLTIP_MAX_WIDTH, available)
    local lines = fragments_mod.build_tooltip_lines(text, limit)
    local max_height = math.max(1, vim.o.lines - 1)
    if #lines > max_height then
        lines = fragments_mod.build_tooltip_lines(text, math.max(limit, math.ceil(#text / max_height) + 2))
    end
    return lines, math.min(anchor, math.max(0, columns - widest_line(lines)))
end

local function apply_tooltip_highlight(background)
    local normal_fg = fragments_mod.get_highlight_foreground("Normal")
    local foreground = type(normal_fg) == "number" and contrast.increase_contrast(normal_fg, background, CONTRAST_BOOST) or nil
    local spec = { bg = background, ctermbg = fragments_mod.cterm_color(background) }
    if type(foreground) == "number" then
        spec.fg = foreground
        spec.ctermfg = fragments_mod.cterm_color(foreground)
    end
    vim.api.nvim_set_hl(0, "JprPanelTooltip", spec)
end

local function show_tooltip(panel, text, screen_row, screen_col, window_width, background)
    local lines, anchor_col = tooltip_lines_for(text, screen_col, window_width)
    if #lines == 0 then
        M.close(panel.win)
        return
    end
    apply_tooltip_highlight(background)
    local width = widest_line(lines)
    local row = screen_row
    if row + #lines > vim.o.lines then
        row = math.max(0, vim.o.lines - #lines)
    end
    ensure_float(panel.win, lines, float_config(row, anchor_col, width, #lines, 45), "JprPanelTooltip")
end

--- Reveals a clipped panel row via inline extension or tooltip, or closes any stale overflow.
function M.show(panel, selection_namespace, line_number, text, fragments, background)
    local row = panel.rows and panel.rows[line_number] or nil
    local screen_row, screen_col = cursor_screen_position(panel.win)
    local window_width = vim.api.nvim_win_get_width(panel.win)
    local plan = fragments_mod.plan_overflow(row, vim.fn.strdisplaywidth(text), window_width, screen_col, vim.o.columns)
    if not plan then
        M.close(panel.win)
        return
    end
    if plan.kind == "extend" and show_extension(panel, selection_namespace, text, fragments, screen_row, screen_col) then
        return
    end
    local label = plan.text or (row and row.path) or ""
    show_tooltip(panel, label, screen_row, screen_col, window_width, background)
end

return M
