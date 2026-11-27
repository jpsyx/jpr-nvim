-- Sidebar cursor row: brighter background, per-fragment OKLab contrast, and
-- full file/dir names that spill past the panel instead of wrapping.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local contrast = require("jpr.highlights.contrast")
local panel_cursor = require("jpr.views.panel_cursor")

local function angular_diff_deg(hue_a, hue_b)
    local delta = math.abs(hue_a - hue_b) % (2 * math.pi)
    if delta > math.pi then
        delta = 2 * math.pi - delta
    end
    return math.deg(delta)
end

-- Brighten the row background by 10% of the remaining OKLab lightness toward white.
local cursorline_bg = 0x2c323c
local before_l, before_c, before_h = contrast.rgb_to_oklch(cursorline_bg)
local bright_bg = contrast.brighten_background(cursorline_bg, 0.10)
local after_l, after_c, after_h = contrast.rgb_to_oklch(bright_bg)
assert(type(bright_bg) == "number", "brighten_background returns an rgb integer")
assert(math.abs(after_l - (before_l + 0.10 * (1 - before_l))) < 0.02, "background lightness moves 10% toward white")
assert(after_l > before_l, "brightened background is lighter")
assert(after_c < 0.02 or angular_diff_deg(before_h, after_h) < 8, "background hue stays locked")
assert(contrast.brighten_background(cursorline_bg, 0) == cursorline_bg, "zero brighten returns the original color")

-- Each fragment's contrast against the highlighted background rises by 10%.
local samples = {
    { name = "added", rgb = 0x98c379 },
    { name = "removed", rgb = 0xe06c75 },
    { name = "muted", rgb = 0x5c6370 },
    { name = "filename", rgb = 0xabb2bf },
}
local adjusted_by_name = {}
for _, sample in ipairs(samples) do
    local adjusted = contrast.increase_contrast(sample.rgb, bright_bg, 0.10)
    adjusted_by_name[sample.name] = adjusted
    local before_ratio = contrast.contrast_ratio(sample.rgb, bright_bg)
    local after_ratio = contrast.contrast_ratio(adjusted, bright_bg)
    local target_ratio = math.min(21, before_ratio * 1.10)
    assert(after_ratio + 1e-3 >= before_ratio, sample.name .. " contrast does not drop")
    local lightness = select(1, contrast.rgb_to_oklch(adjusted))
    local reached_target = after_ratio + 0.08 >= target_ratio
    local at_extreme = lightness <= 0.02 or lightness >= 0.98
    assert(reached_target or at_extreme, ("%s contrast %.3f -> %.3f, target %.3f"):format(sample.name, before_ratio, after_ratio, target_ratio))
    local _, chroma, hue = contrast.rgb_to_oklch(adjusted)
    local _, _, source_hue = contrast.rgb_to_oklch(sample.rgb)
    if chroma > 0.02 and select(2, contrast.rgb_to_oklch(sample.rgb)) > 0.02 then
        assert(angular_diff_deg(source_hue, hue) < 8, sample.name .. " keeps its OKLab hue")
    end
end
assert(adjusted_by_name.added ~= adjusted_by_name.removed, "added and removed shift differently")
assert(adjusted_by_name.removed ~= adjusted_by_name.muted, "removed and muted shift differently")
assert(adjusted_by_name.muted ~= adjusted_by_name.filename, "muted and filename shift differently")
assert(contrast.increase_contrast(0x98c379, bright_bg, 0) == 0x98c379, "zero contrast boost returns the original color")

local other_bg = 0xd0d4dc
assert(
    contrast.increase_contrast(0x98c379, bright_bg, 0.10) ~= contrast.increase_contrast(0x98c379, other_bg, 0.10),
    "the same green is adjusted against the background it sits on"
)

-- Unhighlighted gaps keep the default group, and a later span wins overlaps.
local line = "ab+cd-ef"
local fragments = panel_cursor.build_line_fragments(line, {
    { col_start = 2, col_end = 3, group = "JprAdded" },
    { col_start = 5, col_end = 6, group = "JprRemoved" },
    { col_start = 2, col_end = 3, group = "JprOverlap" },
}, "Normal")
local function fragment_text(group)
    local parts = {}
    for _, fragment in ipairs(fragments) do
        if fragment.group == group then
            parts[#parts + 1] = line:sub(fragment.col_start + 1, fragment.col_end)
        end
    end
    return table.concat(parts)
end
assert(fragment_text("Normal") == "abcdef", "gaps stay in the default group")
assert(fragment_text("JprRemoved") == "-", "removed span is its own fragment")
assert(fragment_text("JprAdded") == "", "an earlier span does not keep an overlapped cell")
assert(fragment_text("JprOverlap") == "+", "the later span wins the overlapped cell")

local colored = panel_cursor.adjust_fragment_foregrounds(fragments, {
    Normal = 0xabb2bf,
    JprRemoved = 0xe06c75,
    JprOverlap = 0x98c379,
}, bright_bg)
local fg_by_group = {}
for _, fragment in ipairs(colored) do
    if fragment.group ~= "Normal" or fragment.fg ~= nil then
        fg_by_group[fragment.group] = fragment.fg
    end
end
assert(fg_by_group.JprOverlap ~= fg_by_group.JprRemoved, "fragment foregrounds stay distinct")
assert(
    contrast.contrast_ratio(fg_by_group.JprOverlap, bright_bg) > contrast.contrast_ratio(0x98c379, bright_bg),
    "added fragment contrast rises against the highlighted background"
)

-- Long file and directory names spill past the sidebar; other rows never do.
assert(panel_cursor.plan_overflow({ kind = "file", path = "src/a.rs" }, 20, 40, 0, 120) == nil, "a fitting file stays inside the sidebar")
assert(panel_cursor.plan_overflow({ kind = "summary" }, 80, 40, 0, 120) == nil, "non file/dir rows do not overflow")
local extend = panel_cursor.plan_overflow({ kind = "file", path = "src/long.rs" }, 80, 40, 0, 120)
assert(extend and extend.kind == "extend" and extend.width == 80, "a line that fits on screen extends past the sidebar")
local dir_extend = panel_cursor.plan_overflow({ kind = "dir", path = "docs/guides" }, 70, 30, 10, 100)
assert(dir_extend and dir_extend.kind == "extend", "a long directory extends the same way")
local tooltip = panel_cursor.plan_overflow({ kind = "dir", path = "docs/very/long" }, 200, 40, 0, 100)
assert(tooltip and tooltip.kind == "tooltip" and tooltip.text == "docs/very/long", "a line wider than the screen becomes a path tooltip")

local tooltip_lines = panel_cursor.build_tooltip_lines("docs/very/long/path", 10)
assert(#tooltip_lines > 1, "a tooltip wraps the path inside its own width")
local rebuilt = {}
for _, tooltip_line in ipairs(tooltip_lines) do
    rebuilt[#rebuilt + 1] = tooltip_line:sub(2, -2)
end
assert(table.concat(rebuilt) == "docs/very/long/path", "tooltip wrapping keeps the full path")
assert(tooltip_lines[1]:sub(1, 1) == " " and tooltip_lines[1]:sub(-1) == " ", "tooltip lines keep a one-cell padding")

-- Focused panel: hidden cursor, brighter row, boosted fragments, overflow float.
vim.api.nvim_set_hl(0, "Normal", { fg = 0xabb2bf, bg = 0x282c34 })
vim.api.nvim_set_hl(0, "CursorLine", { bg = cursorline_bg })
vim.api.nvim_set_hl(0, "JprAdded", { fg = 0x98c379 })
vim.api.nvim_set_hl(0, "JprRemoved", { fg = 0xe06c75 })

local extend_name = ("n"):rep(50)
local extend_line = "  " .. extend_name .. "  +4 -1"
local short_line = "  short.rs  +1 -0"
local tooltip_name = ("m"):rep(90)
local tooltip_line = "  " .. tooltip_name .. "  +2 -2"
local tooltip_path = "src/" .. tooltip_name .. ".rs"
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { extend_line, short_line, tooltip_line })
vim.cmd("topleft vsplit")
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)
vim.api.nvim_win_set_width(win, 24)
vim.api.nvim_set_option_value("wrap", false, { win = win, scope = "local" })
vim.api.nvim_set_option_value("cursorline", true, { win = win, scope = "local" })

local function spans_for(text, line_index)
    local plus_at = text:find("%+%d+", 1)
    local minus_at = text:find("%-%d+", 1)
    local plus_text = text:match("%+%d+")
    local minus_text = text:match("%-%d+")
    return {
        { line = line_index, col_start = plus_at - 1, col_end = plus_at - 1 + #plus_text, group = "JprAdded" },
        { line = line_index, col_start = minus_at - 1, col_end = minus_at - 1 + #minus_text, group = "JprRemoved" },
    }
end

local panel = {
    win = win,
    buf = buf,
    rows = {
        [1] = { kind = "file", path = "src/" .. extend_name .. ".rs" },
        [2] = { kind = "file", path = "short.rs" },
        [3] = { kind = "file", path = tooltip_path },
    },
    highlights = {},
}
for _, span in ipairs(spans_for(extend_line, 0)) do
    panel.highlights[#panel.highlights + 1] = span
end
for _, span in ipairs(spans_for(short_line, 1)) do
    panel.highlights[#panel.highlights + 1] = span
end
for _, span in ipairs(spans_for(tooltip_line, 2)) do
    panel.highlights[#panel.highlights + 1] = span
end

local guicursor_before = vim.api.nvim_get_option_value("guicursor", {})
vim.api.nvim_win_set_cursor(win, { 1, 0 })
panel_cursor.sync(panel)

local hidden_guicursor = vim.api.nvim_get_option_value("guicursor", {})
assert(hidden_guicursor:find("JprPanelHiddenCursor", 1, true), "focused panel hides the cursor block: " .. hidden_guicursor)
local winhighlight = vim.api.nvim_get_option_value("winhighlight", { win = win, scope = "local" })
assert(winhighlight:find("CursorLine:JprPanelCursorLine", 1, true), "row uses the brightened cursorline: " .. winhighlight)
local cursorline_hl = vim.api.nvim_get_hl(0, { name = "JprPanelCursorLine", link = false })
assert(cursorline_hl.bg == bright_bg, ("cursorline bg #%06x, expected #%06x"):format(cursorline_hl.bg or 0, bright_bg))

local selection_namespace = vim.api.nvim_create_namespace("jpr-panel-selection")
local selection_marks = vim.api.nvim_buf_get_extmarks(buf, selection_namespace, 0, -1, { details = true })
local plus_column = extend_line:find("%+%d+", 1) - 1
local boosted_added = false
for _, mark in ipairs(selection_marks) do
    local details = mark[4]
    local start_column = mark[3]
    if details and details.hl_group and start_column <= plus_column and (details.end_col or 0) > plus_column then
        local hl = vim.api.nvim_get_hl(0, { name = details.hl_group, link = false })
        assert(type(hl.fg) == "number", "added span has a numeric foreground")
        assert(
            contrast.contrast_ratio(hl.fg, bright_bg) > contrast.contrast_ratio(0x98c379, bright_bg),
            "the selected row boosts the added-count foreground"
        )
        boosted_added = true
    end
end
assert(boosted_added, "the selected row covers the added count")

local function overflow_windows()
    local found = {}
    for _, candidate in ipairs(vim.api.nvim_list_wins()) do
        local config = vim.api.nvim_win_get_config(candidate)
        if config.relative ~= "" and candidate ~= win then
            found[#found + 1] = candidate
        end
    end
    return found
end

local extend_windows = overflow_windows()
assert(#extend_windows == 1, "one overflow window extends the long file row")
local extend_config = vim.api.nvim_win_get_config(extend_windows[1])
assert(extend_config.focusable == false, "the extension does not take focus")
assert(extend_config.width == vim.fn.strdisplaywidth(extend_line), "the extension is as wide as the full line")
assert(extend_config.border == "none" or extend_config.border == nil, "the extension has no block border")
local extend_text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(extend_windows[1]), 0, -1, false)[1]
assert(extend_text == extend_line, "the extension shows the full line: " .. tostring(extend_text))
assert(vim.api.nvim_get_current_win() == win, "opening the extension leaves the sidebar focused")

vim.api.nvim_win_set_cursor(win, { 2, 0 })
panel_cursor.sync(panel)
assert(#overflow_windows() == 0, "a short row closes the overflow window")
local short_marks = vim.api.nvim_buf_get_extmarks(buf, selection_namespace, { 0, 0 }, { 0, -1 }, { details = true })
assert(#short_marks == 0, "leaving the long row clears its contrast marks")

vim.api.nvim_win_set_cursor(win, { 3, 0 })
panel_cursor.sync(panel)
local tooltip_windows = overflow_windows()
assert(#tooltip_windows == 1, "a line wider than the screen opens one tooltip")
local tooltip_config = vim.api.nvim_win_get_config(tooltip_windows[1])
assert(tooltip_config.border == "none" or tooltip_config.border == nil, "the tooltip has no type-hint border")
assert(tooltip_config.title == nil or tooltip_config.title == "", "the tooltip has no title")
assert(tooltip_config.width < vim.o.columns, "the tooltip stays narrower than the screen")
local tooltip_parts = {}
for _, tooltip_row in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(tooltip_windows[1]), 0, -1, false)) do
    tooltip_parts[#tooltip_parts + 1] = tooltip_row:match("^%s*(.-)%s*$")
end
assert(table.concat(tooltip_parts) == tooltip_path, "the tooltip shows the full path")

panel_cursor.clear(panel)
assert(#overflow_windows() == 0, "clearing the panel closes the tooltip")
assert(vim.api.nvim_get_option_value("guicursor", {}) == guicursor_before, "leaving the panel restores the cursor")
local cleared_highlight = vim.api.nvim_get_option_value("winhighlight", { win = win, scope = "local" })
assert(not cleared_highlight:find("JprPanelCursorLine", 1, true), "leaving the panel restores the row background")
assert(#vim.api.nvim_buf_get_extmarks(buf, selection_namespace, 0, -1, {}) == 0, "leaving the panel restores fragment colors")
