-- Sidebar selection: hide the cursor block, brighten the current row, raise each
-- fragment's contrast against that row, and reveal clipped file or directory
-- names past the panel.
local contrast = require("jpr.highlights.contrast")

local M = {}

local BACKGROUND_BRIGHTEN = 0.10
local CONTRAST_BOOST = 0.10
local SELECTION_PRIORITY = 5000
local TOOLTIP_MAX_WIDTH = 56
local HIDDEN_CURSOR = "a:JprPanelHiddenCursor/JprPanelHiddenCursor"
local selection_namespace = vim.api.nvim_create_namespace("jpr-panel-selection")
local overflow_by_win = {}
local saved_guicursor = nil
local is_syncing = false

--- Splits `line_text` into byte-range fragments. `spans` use the panel's
--- exclusive byte columns. A later span wins when ranges overlap. Gaps use
--- `default_group`.
function M.build_line_fragments(line_text, spans, default_group)
    local text = tostring(line_text or "")
    local fallback = type(default_group) == "string" and default_group or "Normal"
    local owners = {}
    for index = 1, #text do
        owners[index] = fallback
    end
    for _, span in ipairs(spans or {}) do
        local group = type(span.group) == "string" and span.group or fallback
        local first = math.max(1, math.floor(tonumber(span.col_start) or 0) + 1)
        local last = math.min(#text, math.floor(tonumber(span.col_end) or 0))
        for index = first, last do
            owners[index] = group
        end
    end
    local fragments = {}
    local index = 1
    while index <= #text do
        local group = owners[index]
        local next_index = index + 1
        while next_index <= #text and owners[next_index] == group do
            next_index = next_index + 1
        end
        fragments[#fragments + 1] = {
            group = group,
            col_start = index - 1,
            col_end = next_index - 1,
            text = text:sub(index, next_index - 1),
        }
        index = next_index
    end
    return fragments
end

--- Returns adjusted copies of `fragments`, raising each known foreground's
--- contrast by 10% against `background_rgb`. Fragments without a numeric
--- foreground keep their group and gain no `fg`.
function M.adjust_fragment_foregrounds(fragments, fg_by_group, background_rgb)
    local adjusted = {}
    for _, fragment in ipairs(fragments or {}) do
        local next_fragment = {
            group = fragment.group,
            col_start = fragment.col_start,
            col_end = fragment.col_end,
            text = fragment.text,
        }
        local foreground = type(fg_by_group) == "table" and fg_by_group[fragment.group] or nil
        if type(foreground) == "number" and type(background_rgb) == "number" then
            next_fragment.fg = contrast.increase_contrast(foreground, background_rgb, CONTRAST_BOOST)
        end
        adjusted[#adjusted + 1] = next_fragment
    end
    return adjusted
end

--- Decides how a clipped file or directory name is revealed. A line that fits
--- in the sidebar returns nil. One that fits on the screen extends. Otherwise
--- the full path is shown in a tooltip.
function M.plan_overflow(row, display_width, window_width, screen_col, screen_columns)
    if type(row) ~= "table" or (row.kind ~= "file" and row.kind ~= "dir") then
        return nil
    end
    local line_width = tonumber(display_width) or 0
    local panel_width = tonumber(window_width) or 0
    if line_width <= panel_width then
        return nil
    end
    local origin = math.max(0, tonumber(screen_col) or 0)
    local columns = math.max(0, tonumber(screen_columns) or 0)
    local available = columns - origin
    if available > 0 and line_width <= available then
        return { kind = "extend", width = line_width }
    end
    local label = type(row.path) == "string" and row.path or ""
    if label == "" then
        return nil
    end
    return { kind = "tooltip", text = label }
end

--- Pads and wraps `text` into tooltip rows of at most `max_width` cells.
function M.build_tooltip_lines(text, max_width)
    local clean = tostring(text or "")
    if clean == "" then
        return {}
    end
    local inner_width = math.max(1, (tonumber(max_width) or 1) - 2)
    local wrapped = require("jpr.tui.render").wrap_text(clean, inner_width)
    local lines = {}
    for _, wrapped_line in ipairs(wrapped) do
        lines[#lines + 1] = " " .. wrapped_line .. " "
    end
    return lines
end

local function spans_on_line(highlights, line_index)
    local spans = {}
    for _, highlight in ipairs(highlights or {}) do
        if highlight.line == line_index then
            spans[#spans + 1] = highlight
        end
    end
    return spans
end

local function resolve_fg(group)
    if type(group) ~= "string" or group == "" then
        return nil
    end
    local ok, highlight = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    if ok and type(highlight.fg) == "number" then
        return highlight.fg
    end
    return nil
end

local function foregrounds_for_fragments(fragments)
    local fg_by_group = {}
    for _, fragment in ipairs(fragments) do
        if fg_by_group[fragment.group] == nil then
            fg_by_group[fragment.group] = resolve_fg(fragment.group) or false
        end
    end
    return fg_by_group
end

local function resolve_cursorline_bg()
    local cursorline = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
    if type(cursorline.bg) == "number" then
        return cursorline.bg
    end
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    if type(normal.bg) == "number" then
        return normal.bg
    end
    return vim.o.background == "light" and 0xf0f0f0 or 0x1e1e1e
end

local function cterm_color(rgb)
    return require("jpr.highlights").rgb_to_cterm256(rgb)
end

local function parse_winhighlight(value)
    local entries = {}
    for item in tostring(value or ""):gmatch("[^,]+") do
        local key, group = item:match("^%s*([^:%s]+)%s*:%s*(%S+)%s*$")
        if key and group then
            entries[#entries + 1] = { key = key, group = group }
        end
    end
    return entries
end

local function write_winhighlight(win, entries)
    local parts = {}
    for _, entry in ipairs(entries) do
        parts[#parts + 1] = entry.key .. ":" .. entry.group
    end
    vim.api.nvim_set_option_value("winhighlight", table.concat(parts, ","), { win = win, scope = "local" })
end

local function set_managed_winhighlight(win, updates)
    local entries = {}
    for _, entry in ipairs(parse_winhighlight(vim.api.nvim_get_option_value("winhighlight", { win = win, scope = "local" }))) do
        if updates[entry.key] == nil then
            entries[#entries + 1] = entry
        end
    end
    for _, key in ipairs({ "Cursor", "CursorLine" }) do
        if updates[key] then
            entries[#entries + 1] = { key = key, group = updates[key] }
        end
    end
    write_winhighlight(win, entries)
end

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

local function foreground_group(rgb)
    local name = ("JprPanelSelFg_%06x"):format(rgb)
    vim.api.nvim_set_hl(0, name, { fg = rgb, ctermfg = cterm_color(rgb) })
    return name
end

local function paint_fragments(buf, line_index, fragments)
    for _, fragment in ipairs(fragments) do
        if type(fragment.fg) == "number" and fragment.col_end > fragment.col_start then
            vim.api.nvim_buf_set_extmark(buf, selection_namespace, line_index, fragment.col_start, {
                end_col = fragment.col_end,
                hl_group = foreground_group(fragment.fg),
                priority = SELECTION_PRIORITY,
            })
        end
    end
end

local function apply_selection_background(win)
    local bright = contrast.brighten_background(resolve_cursorline_bg(), BACKGROUND_BRIGHTEN)
    vim.api.nvim_set_hl(0, "JprPanelCursorLine", { bg = bright, ctermbg = cterm_color(bright) })
    set_managed_winhighlight(win, { CursorLine = "JprPanelCursorLine", Cursor = "JprPanelHiddenCursor" })
    return bright
end

local function close_overflow(panel_win)
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
    close_overflow(panel_win)
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

local function show_extension(panel, text, fragments, screen_row, screen_col)
    local width = vim.fn.strdisplaywidth(text)
    local config = float_config(screen_row, screen_col, width, 1, 40)
    local state = ensure_float(panel.win, { text }, config, "JprPanelCursorLine")
    if not state then
        return false
    end
    vim.api.nvim_buf_clear_namespace(state.buf, selection_namespace, 0, -1)
    paint_fragments(state.buf, 0, fragments)
    return true
end

local function tooltip_lines_for(text, screen_col, window_width)
    local columns = vim.o.columns
    local anchor = screen_col + window_width
    local available = math.max(8, columns - math.min(anchor, columns - 1))
    local limit = math.min(TOOLTIP_MAX_WIDTH, available)
    local lines = M.build_tooltip_lines(text, limit)
    local max_height = math.max(1, vim.o.lines - 1)
    if #lines > max_height then
        lines = M.build_tooltip_lines(text, math.max(limit, math.ceil(#text / max_height) + 2))
    end
    return lines, math.min(anchor, math.max(0, columns - widest_line(lines)))
end

local function apply_tooltip_highlight(background)
    local normal_fg = resolve_fg("Normal")
    local foreground = type(normal_fg) == "number" and contrast.increase_contrast(normal_fg, background, CONTRAST_BOOST) or nil
    local spec = { bg = background, ctermbg = cterm_color(background) }
    if type(foreground) == "number" then
        spec.fg = foreground
        spec.ctermfg = cterm_color(foreground)
    end
    vim.api.nvim_set_hl(0, "JprPanelTooltip", spec)
end

local function show_tooltip(panel, text, screen_row, screen_col, window_width, background)
    local lines, anchor_col = tooltip_lines_for(text, screen_col, window_width)
    if #lines == 0 then
        close_overflow(panel.win)
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

local function show_overflow(panel, line_number, text, fragments, background)
    local row = panel.rows and panel.rows[line_number] or nil
    local screen_row, screen_col = cursor_screen_position(panel.win)
    local plan = M.plan_overflow(row, vim.fn.strdisplaywidth(text), vim.api.nvim_win_get_width(panel.win), screen_col, vim.o.columns)
    if not plan then
        close_overflow(panel.win)
        return
    end
    local window_width = vim.api.nvim_win_get_width(panel.win)
    if plan.kind == "extend" and show_extension(panel, text, fragments, screen_row, screen_col) then
        return
    end
    local label = plan.text or (row and row.path) or ""
    show_tooltip(panel, label, screen_row, screen_col, window_width, background)
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
    local fragments = M.build_line_fragments(text, spans_on_line(panel.highlights, line_index), "Normal")
    return text, M.adjust_fragment_foregrounds(fragments, foregrounds_for_fragments(fragments), background)
end

local function refresh_focused_panel(panel)
    conceal_cursor()
    local background = apply_selection_background(panel.win)
    local line_number = vim.api.nvim_win_get_cursor(panel.win)[1]
    local text, fragments = selection_fragments(panel, line_number, background)
    vim.api.nvim_buf_clear_namespace(panel.buf, selection_namespace, 0, -1)
    paint_fragments(panel.buf, line_number - 1, fragments)
    show_overflow(panel, line_number, text, fragments, background)
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
        set_managed_winhighlight(panel.win, { Cursor = false, CursorLine = false })
        close_overflow(panel.win)
    elseif type(panel.win) == "number" then
        close_overflow(panel.win)
    end
    if type(panel.buf) == "number" and vim.api.nvim_buf_is_valid(panel.buf) then
        vim.api.nvim_buf_clear_namespace(panel.buf, selection_namespace, 0, -1)
    end
end

return M
