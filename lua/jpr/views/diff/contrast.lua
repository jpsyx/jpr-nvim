-- Viewport-scoped decoration provider and removed-line syntax contrast builder
-- for unified file overlays and split `:diffthis` windows. Inactive outside
-- tracked jpr diff windows.
local highlights = require("jpr.highlights")
local stream_syntax = require("jpr.views.stream.syntax")

local M = {}

--- Maximum byte length of a diff line eligible for foreground contrast syntax
--- processing, keeping redraws and removed-block parsing fast on minified files.
M.MAX_LINE_BYTES = 1000

local MAX_REMOVED_SYNTAX_LINES = 500
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

local function is_lsp_namespace(namespace_name)
    return namespace_name:find("semantic_tokens", 1, true) ~= nil
        or vim.startswith(namespace_name, "nvim.lsp.")
        or vim.startswith(namespace_name, "vim.lsp.")
end

local function is_buffer_referenced_by_unified_window(buf)
    for win, entry in pairs(tracked_windows) do
        if entry.mode == "unified" and entry.buf == buf and vim.api.nvim_win_is_valid(win) then
            return true
        end
    end
    return false
end

local function prune_unreferenced_unified_buffer(buf)
    if buf == nil then
        return
    end
    if not vim.api.nvim_buf_is_valid(buf) or not is_buffer_referenced_by_unified_window(buf) then
        unified_lines_by_buf[buf] = nil
    end
end

local function resolve_split_diff_kinds(win, topline, botline)
    local is_ok, kinds = pcall(vim.api.nvim_win_call, win, function()
        local found = {}
        for row = topline, botline do
            local highlight_id = vim.fn.diff_hlID(row + 1, 1)
            if highlight_id > 0 then
                local kind = DIFF_HL_TO_KIND[vim.fn.synIDattr(highlight_id, "name")]
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
        local added_lines = entry.buf == buf and unified_lines_by_buf[buf] or nil
        if not added_lines then
            return {}
        end
        local kinds = {}
        for row = topline, botline do
            if added_lines[row] then
                kinds[row] = added_lines[row]
            end
        end
        return kinds
    end
    return resolve_split_diff_kinds(win, topline, botline)
end

local function filter_eligible_lines(buf, diff_kinds, topline, botline)
    local lines = vim.api.nvim_buf_get_lines(buf, topline, botline + 1, false)
    local eligible_kinds, line_lengths = {}, {}
    for row, kind in pairs(diff_kinds) do
        local line_text = lines[row - topline + 1]
        if line_text and #line_text > 0 and #line_text <= M.MAX_LINE_BYTES then
            eligible_kinds[row] = kind
            line_lengths[row] = #line_text
        end
    end
    return eligible_kinds, line_lengths
end

local function append_normal_fallback_marks(viewport)
    for row, kind in pairs(viewport.eligible_kinds) do
        local derived_group = highlights.get_contrast_group("Normal", kind)
        if derived_group ~= "Normal" then
            viewport.marks[#viewport.marks + 1] = {
                row = row,
                col_start = 0,
                col_end = viewport.line_lengths[row],
                hl_group = derived_group,
                priority = NORMAL_PRIORITY,
            }
        end
    end
end

local function append_clamped_span(viewport, highlight_group, priority, start_row, start_col, end_row, end_col)
    local clamped_start = math.max(start_row, viewport.topline)
    local clamped_end = math.min(end_row, viewport.botline)
    local first_col = clamped_start == start_row and start_col or 0
    local last_col = clamped_end == end_row and end_col or (viewport.line_lengths[clamped_end] or 0)
    for row = clamped_start, clamped_end do
        local kind = viewport.eligible_kinds[row]
        if kind then
            local line_length = viewport.line_lengths[row]
            local col_start = row == clamped_start and math.max(0, math.min(first_col, line_length)) or 0
            local col_end = row == clamped_end and math.max(0, math.min(last_col, line_length)) or line_length
            if col_end > col_start then
                local derived_group = highlights.get_contrast_group(highlight_group, kind)
                if derived_group ~= highlight_group then
                    viewport.marks[#viewport.marks + 1] = {
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

local function collect_tree_captures(viewport, tree, language, capture_cache)
    local root = tree:root()
    local root_start_row, _, root_end_row = root:range()
    if root_start_row > viewport.botline or root_end_row < viewport.topline then
        return
    end
    local has_query, query = pcall(vim.treesitter.query.get, language, "highlights")
    if not has_query or not query then
        return
    end
    for capture_id, node, metadata in query:iter_captures(root, viewport.buf, viewport.topline, viewport.botline + 1) do
        local capture_name = query.captures[capture_id]
        if capture_name and not IGNORED_CAPTURES[capture_name] and capture_name:sub(1, 1) ~= "_" then
            local cache_key = language .. ":" .. capture_name
            local highlight_group = capture_cache[cache_key]
            if highlight_group == nil then
                highlight_group = stream_syntax.get_highlight_group_from_capture(capture_name, language) or false
                capture_cache[cache_key] = highlight_group
            end
            if highlight_group then
                local capture_meta = metadata and metadata[capture_id]
                local start_row, start_col, end_row, end_col
                if capture_meta and capture_meta.range then
                    local range = vim.treesitter.get_range(node, viewport.buf, capture_meta)
                    start_row, start_col, end_row, end_col = range[1], range[2], range[4], range[5]
                else
                    start_row, start_col, end_row, end_col = node:range()
                end
                append_clamped_span(viewport, highlight_group, TREESITTER_PRIORITY, start_row, start_col, end_row, end_col)
            end
        end
    end
end

local function append_treesitter_marks(viewport)
    local active_highlighter = vim.treesitter.highlighter.active[viewport.buf]
    if not active_highlighter or not active_highlighter.tree then
        return
    end
    local is_valid = active_highlighter.tree:is_valid(false, { viewport.topline, 0, viewport.botline + 1, 0 })
    if not active_highlighter.parsing and not is_valid then
        pcall(active_highlighter.tree.parse, active_highlighter.tree, { viewport.topline, viewport.botline + 1 })
    end
    local capture_cache = {}
    active_highlighter.tree:for_each_tree(function(tree, language_tree)
        if tree then
            collect_tree_captures(viewport, tree, language_tree:lang(), capture_cache)
        end
    end)
end

local function append_lsp_marks(viewport)
    for namespace_name, namespace_id in pairs(vim.api.nvim_get_namespaces()) do
        if namespace_id ~= contrast_namespace and is_lsp_namespace(namespace_name) then
            local extmarks = vim.api.nvim_buf_get_extmarks(
                viewport.buf,
                namespace_id,
                { viewport.topline, 0 },
                { viewport.botline, -1 },
                { details = true, overlap = true }
            )
            for _, extmark in ipairs(extmarks) do
                local details = extmark[4]
                local highlight_group = details and details.hl_group
                if type(highlight_group) == "string" and vim.startswith(highlight_group, "@lsp.") then
                    local start_row, start_col = extmark[2], extmark[3]
                    local end_row = details.end_row or start_row
                    local end_col = details.end_col or (viewport.line_lengths[end_row] or start_col)
                    append_clamped_span(viewport, highlight_group, LSP_PRIORITY, start_row, start_col, end_row, end_col)
                end
            end
        end
    end
end

local function map_block_spans_to_contrast(spans_by_line, line_index_map)
    local contrast_block = {}
    for parsed_index, spans in pairs(spans_by_line) do
        local mapped = {}
        for span_index, span in ipairs(spans) do
            mapped[span_index] = {
                col_start = span.col_start,
                col_end = span.col_end,
                hl_group = highlights.get_contrast_group(span.hl_group, "delete"),
            }
        end
        contrast_block[line_index_map[parsed_index]] = mapped
    end
    return contrast_block
end

--- Builds per-block, per-line contrast-adjusted Treesitter spans for removed
--- virtual lines in `diff`, skipping lines over `MAX_LINE_BYTES` and capping
--- total parsed lines across blocks.
function M.build_removed_syntax_by_block(buf, diff)
    local language = stream_syntax.get_language_from_filetype(vim.bo[buf].filetype)
    if not language then
        return nil
    end
    local syntax_by_block = {}
    local parsed_line_count = 0
    for block_index, block in ipairs(diff.removed or {}) do
        if parsed_line_count >= MAX_REMOVED_SYNTAX_LINES then
            break
        end
        local eligible_lines, line_index_map = {}, {}
        for line_index, removed in ipairs(block.lines) do
            if parsed_line_count < MAX_REMOVED_SYNTAX_LINES and #removed.text <= M.MAX_LINE_BYTES then
                eligible_lines[#eligible_lines + 1] = removed.text
                line_index_map[#eligible_lines] = line_index
                parsed_line_count = parsed_line_count + 1
            end
        end
        if #eligible_lines > 0 then
            local spans_by_line = stream_syntax.collect_line_spans(eligible_lines, language)
            syntax_by_block[block_index] = map_block_spans_to_contrast(spans_by_line, line_index_map)
        end
    end
    return syntax_by_block
end

--- Collects contrast-adjusted ephemeral extmark specs for visible diff rows in
--- `[topline, botline]` of tracked window `win`. Returns `{}` when `win` is not
--- tracked, bounds are invalid, or no eligible diff rows are in view.
function M.collect_viewport_marks(win, buf, topline, botline)
    local entry = tracked_windows[win]
    if not entry or not vim.api.nvim_buf_is_valid(buf) or topline < 0 or botline < topline then
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
    local viewport = {
        buf = buf,
        topline = topline,
        botline = botline,
        eligible_kinds = eligible_kinds,
        line_lengths = line_lengths,
        marks = {},
    }
    append_normal_fallback_marks(viewport)
    append_treesitter_marks(viewport)
    append_lsp_marks(viewport)
    return viewport.marks
end

local function install_cleanup_autocmds()
    local group = vim.api.nvim_create_augroup("jpr-diff-contrast", { clear = true })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        callback = function(event)
            unified_lines_by_buf[event.buf] = nil
            for win, entry in pairs(tracked_windows) do
                if entry.mode == "unified" and entry.buf == event.buf then
                    tracked_windows[win] = nil
                end
            end
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(event)
            local closed_win = tonumber(event.match)
            if closed_win then
                M.detach_window(closed_win)
            end
        end,
    })
end

local function ensure_provider()
    if is_provider_installed then
        return
    end
    is_provider_installed = true
    install_cleanup_autocmds()
    vim.api.nvim_set_decoration_provider(contrast_namespace, {
        on_start = function()
            for win, entry in pairs(tracked_windows) do
                if not vim.api.nvim_win_is_valid(win) then
                    tracked_windows[win] = nil
                    if entry.mode == "unified" then
                        prune_unreferenced_unified_buffer(entry.buf)
                    end
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

--- Stops tracking `win` in the viewport contrast provider and prunes its
--- unified buffer map when no other unified window displays that buffer.
function M.detach_window(win)
    local entry = tracked_windows[win]
    tracked_windows[win] = nil
    if entry and entry.mode == "unified" then
        prune_unreferenced_unified_buffer(entry.buf)
    end
end

--- Drops unified added-line tracking for `buf` once no valid unified diff
--- window still displays it.
function M.clear_buffer(buf)
    prune_unreferenced_unified_buffer(buf)
end

return M
