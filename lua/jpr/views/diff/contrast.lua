-- Viewport-scoped decoration provider applying OKLCH contrast-adjusted
-- foreground extmarks on visible diff lines in unified file overlays and split
-- `:diffthis` windows. Inactive outside tracked jpr diff windows.
local highlights = require("jpr.highlights")
local stream_syntax = require("jpr.views.stream.syntax")

local M = {}

M.MAX_LINE_BYTES = 1000

local NORMAL_PRIORITY = 45
local TREESITTER_PRIORITY = 115
local LSP_PRIORITY = 135
local IGNORED_CAPTURES = { spell = true, nospell = true, conceal = true }
local DIFF_HL_TO_KIND = {
    DiffAdd = "add",
    DiffChange = "add",
    DiffText = "add",
    DiffDelete = "delete",
}

local contrast_namespace = vim.api.nvim_create_namespace("jpr-diff-contrast")
local tracked_windows = {}
local unified_lines_by_buf = {}
local is_provider_installed = false

local function resolve_split_diff_kinds(win, topline, botline)
    local is_ok, kinds = pcall(vim.api.nvim_win_call, win, function()
        local found = {}
        for row = topline, botline do
            local hl_id = vim.fn.diff_hlID(row + 1, 1)
            if hl_id > 0 then
                local hl_name = vim.fn.synIDattr(hl_id, "name")
                local kind = DIFF_HL_TO_KIND[hl_name]
                if kind then
                    found[row] = kind
                end
            end
        end
        return found
    end)
    return is_ok and kinds or {}
end

local function resolve_diff_kinds(entry, win, buf, topline, botline)
    if entry.mode == "unified" then
        if entry.buf ~= buf then
            return {}
        end
        local added_lines = unified_lines_by_buf[buf]
        if not added_lines then
            return {}
        end
        local kinds = {}
        for row = topline, botline do
            local kind = added_lines[row]
            if kind then
                kinds[row] = kind
            end
        end
        return kinds
    end
    return resolve_split_diff_kinds(win, topline, botline)
end

local function filter_eligible_lines(buf, diff_kinds, topline, botline)
    local lines = vim.api.nvim_buf_get_lines(buf, topline, botline + 1, false)
    local eligible_kinds = {}
    local line_lengths = {}
    for row, kind in pairs(diff_kinds) do
        local line_text = lines[row - topline + 1]
        if line_text then
            local byte_length = #line_text
            if byte_length > 0 and byte_length <= M.MAX_LINE_BYTES then
                eligible_kinds[row] = kind
                line_lengths[row] = byte_length
            end
        end
    end
    return eligible_kinds, line_lengths
end

local function append_normal_fallback_marks(marks, eligible_kinds, line_lengths)
    for row, kind in pairs(eligible_kinds) do
        local derived_group = highlights.get_contrast_group("Normal", kind)
        if derived_group ~= "Normal" then
            marks[#marks + 1] = {
                row = row,
                col_start = 0,
                col_end = line_lengths[row],
                hl_group = derived_group,
                priority = NORMAL_PRIORITY,
            }
        end
    end
end

local function append_span_rows(marks, eligible_kinds, line_lengths, hl_group, priority, start_row, start_col, end_row, end_col)
    for row = start_row, end_row do
        local kind = eligible_kinds[row]
        if kind then
            local line_length = line_lengths[row]
            local col_start = row == start_row and math.max(0, math.min(start_col, line_length)) or 0
            local col_end = row == end_row and math.max(0, math.min(end_col, line_length)) or line_length
            if col_end > col_start then
                local derived_group = highlights.get_contrast_group(hl_group, kind)
                if derived_group ~= hl_group then
                    marks[#marks + 1] = {
                        row = row,
                        col_start = col_start,
                        col_end = col_end,
                        hl_group = derived_group,
                        priority = priority,
                    }
                end
            end
        end
    end
end

local function append_treesitter_marks(marks, buf, eligible_kinds, line_lengths, topline, botline)
    local active_highlighter = vim.treesitter.highlighter.active[buf]
    if not active_highlighter or not active_highlighter.tree then
        return
    end
    pcall(active_highlighter.tree.parse, active_highlighter.tree, { topline, botline + 1 })
    local capture_cache = {}
    active_highlighter.tree:for_each_tree(function(tree, language_tree)
        local language = language_tree:lang()
        local has_query, query = pcall(vim.treesitter.query.get, language, "highlights")
        if not has_query or not query then
            return
        end
        for capture_id, node in query:iter_captures(tree:root(), buf, topline, botline + 1) do
            local capture_name = query.captures[capture_id]
            if capture_name and not IGNORED_CAPTURES[capture_name] and capture_name:sub(1, 1) ~= "_" then
                local cache_key = language .. ":" .. capture_name
                local hl_group = capture_cache[cache_key]
                if hl_group == nil then
                    hl_group = stream_syntax.get_highlight_group_from_capture(capture_name, language) or false
                    capture_cache[cache_key] = hl_group
                end
                if hl_group then
                    local start_row, start_col, end_row, end_col = node:range()
                    local clamped_start = math.max(start_row, topline)
                    local clamped_end = math.min(end_row, botline)
                    local first_col = clamped_start == start_row and start_col or 0
                    local last_col = clamped_end == end_row and end_col or (line_lengths[clamped_end] or 0)
                    append_span_rows(
                        marks,
                        eligible_kinds,
                        line_lengths,
                        hl_group,
                        TREESITTER_PRIORITY,
                        clamped_start,
                        first_col,
                        clamped_end,
                        last_col
                    )
                end
            end
        end
    end)
end

local function append_lsp_marks(marks, buf, eligible_kinds, line_lengths, topline, botline)
    for ns_name, ns_id in pairs(vim.api.nvim_get_namespaces()) do
        if ns_id ~= contrast_namespace and not vim.startswith(ns_name, "jpr") then
            local extmarks = vim.api.nvim_buf_get_extmarks(
                buf,
                ns_id,
                { topline, 0 },
                { botline, -1 },
                { details = true }
            )
            for _, extmark in ipairs(extmarks) do
                local details = extmark[4]
                local hl_group = details and details.hl_group
                if type(hl_group) == "string" and vim.startswith(hl_group, "@lsp.") then
                    local start_row, start_col = extmark[2], extmark[3]
                    local end_row = details.end_row or start_row
                    local end_col = details.end_col or (line_lengths[end_row] or start_col)
                    append_span_rows(
                        marks,
                        eligible_kinds,
                        line_lengths,
                        hl_group,
                        LSP_PRIORITY,
                        math.max(start_row, topline),
                        start_col,
                        math.min(end_row, botline),
                        end_col
                    )
                end
            end
        end
    end
end

--- Collects contrast-adjusted ephemeral extmark specs for visible diff rows in
--- `[topline, botline]` of tracked window `win`. Returns `{}` when `win` is not
--- tracked or has no eligible diff rows in view.
function M.collect_viewport_marks(win, buf, topline, botline)
    local entry = tracked_windows[win]
    if not entry or not vim.api.nvim_buf_is_valid(buf) or botline < topline then
        return {}
    end
    local diff_kinds = resolve_diff_kinds(entry, win, buf, topline, botline)
    if next(diff_kinds) == nil then
        return {}
    end
    local eligible_kinds, line_lengths = filter_eligible_lines(buf, diff_kinds, topline, botline)
    if next(eligible_kinds) == nil then
        return {}
    end
    local marks = {}
    append_normal_fallback_marks(marks, eligible_kinds, line_lengths)
    append_treesitter_marks(marks, buf, eligible_kinds, line_lengths, topline, botline)
    append_lsp_marks(marks, buf, eligible_kinds, line_lengths, topline, botline)
    return marks
end

local function ensure_provider()
    if is_provider_installed then
        return
    end
    is_provider_installed = true
    vim.api.nvim_set_decoration_provider(contrast_namespace, {
        on_start = function()
            for win in pairs(tracked_windows) do
                if not vim.api.nvim_win_is_valid(win) then
                    tracked_windows[win] = nil
                end
            end
            return next(tracked_windows) ~= nil
        end,
        on_win = function(_, win, buf, topline, botline)
            if not tracked_windows[win] then
                return false
            end
            for _, mark in ipairs(M.collect_viewport_marks(win, buf, topline, botline)) do
                pcall(vim.api.nvim_buf_set_extmark, buf, contrast_namespace, mark.row, mark.col_start, {
                    end_col = mark.col_end,
                    hl_group = mark.hl_group,
                    priority = mark.priority,
                    ephemeral = true,
                    strict = false,
                })
            end
            return false
        end,
    })
end

--- Tracks `win` displaying unified file overlay `buf` with `added_lines`
--- (`{ [row0] = "add" }`).
function M.attach_unified(win, buf, added_lines)
    ensure_provider()
    tracked_windows[win] = { mode = "unified", buf = buf }
    unified_lines_by_buf[buf] = added_lines
end

--- Tracks `win` displaying a `:diffthis` split diff side.
function M.attach_split(win)
    ensure_provider()
    tracked_windows[win] = { mode = "split" }
end

--- Stops tracking `win` in the viewport contrast provider.
function M.detach_window(win)
    tracked_windows[win] = nil
end

--- Drops unified added-line tracking for `buf` once no diff window displays it.
function M.clear_buffer(buf)
    unified_lines_by_buf[buf] = nil
end

return M
