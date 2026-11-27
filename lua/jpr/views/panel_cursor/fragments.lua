-- Pure fragment splitting, contrast boosting, overflow planning, and highlight
-- helpers for the sidebar panel cursor selection.
local contrast = require("jpr.highlights.contrast")

local M = {}

local BACKGROUND_BRIGHTEN = 0.10
local CONTRAST_BOOST = 0.10
local SELECTION_PRIORITY = 5000

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

--- Returns the highlight spans on 0-based `line_index`.
function M.spans_on_line(highlights, line_index)
    local spans = {}
    for _, highlight in ipairs(highlights or {}) do
        if highlight.line == line_index then
            spans[#spans + 1] = highlight
        end
    end
    return spans
end

--- Looks up the numeric RGB foreground color of highlight `group`, or nil.
function M.get_highlight_foreground(group)
    if type(group) ~= "string" or group == "" then
        return nil
    end
    local ok, highlight = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    if ok and type(highlight.fg) == "number" then
        return highlight.fg
    end
    return nil
end

--- Collects resolved numeric foregrounds keyed by group for `fragments`.
function M.foregrounds_for_fragments(fragments)
    local fg_by_group = {}
    for _, fragment in ipairs(fragments) do
        if fg_by_group[fragment.group] == nil then
            fg_by_group[fragment.group] = M.get_highlight_foreground(fragment.group) or false
        end
    end
    return fg_by_group
end

--- Returns the numeric RGB background of `CursorLine`, falling back to `Normal`.
function M.get_cursorline_bg()
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

--- Converts a 24-bit RGB integer to its nearest 256-color cterm index.
function M.cterm_color(rgb)
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

--- Updates `Cursor` and `CursorLine` entries in `win`'s local `winhighlight`.
function M.set_managed_winhighlight(win, updates)
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

local function foreground_group(rgb)
    local name = ("JprPanelSelFg_%06x"):format(rgb)
    vim.api.nvim_set_hl(0, name, { fg = rgb, ctermfg = M.cterm_color(rgb) })
    return name
end

--- Paints contrast-adjusted `fragments` onto `buf` at 0-based `line_index`.
function M.paint_fragments(buf, selection_namespace, line_index, fragments)
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

--- Brightens the cursorline background for `win` and returns the brightened RGB value.
function M.apply_selection_background(win)
    local bright = contrast.brighten_background(M.get_cursorline_bg(), BACKGROUND_BRIGHTEN)
    vim.api.nvim_set_hl(0, "JprPanelCursorLine", { bg = bright, ctermbg = M.cterm_color(bright) })
    M.set_managed_winhighlight(win, { CursorLine = "JprPanelCursorLine", Cursor = "JprPanelHiddenCursor" })
    return bright
end

return M
