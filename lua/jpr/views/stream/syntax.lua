-- Per-file Treesitter syntax highlighting for rendered stream buffers, with
-- contrast-adjusted foreground groups on added and removed diff rows.
local highlights = require("jpr.highlights")

local M = {}

local syntax_namespace = vim.api.nvim_create_namespace("jpr-stream-syntax")
local MAX_FILE_ROWS = 5000
local NORMAL_FALLBACK_PRIORITY = 85
local SYNTAX_PRIORITY = 90
local IGNORED_CAPTURES = { spell = true, nospell = true, conceal = true }
local CHANGE_TO_CONTRAST_KIND = { added = "add", removed = "delete" }

local function default_highlight_exists(group_name)
    return vim.fn.hlexists(group_name) == 1
end

--- Looks up the most specific existing highlight group for a Treesitter
--- `capture_name` and optional `language`, checking `@<capture>.<language>`
--- first and walking dot-separated prefixes (`@a.b.c` -> `@a.b` -> `@a`).
--- Used when painting stream syntax extmarks across colorschemes.
function M.get_highlight_group_from_capture(capture_name, language, has_highlight_group)
    if type(capture_name) ~= "string" or capture_name == "" or capture_name:sub(1, 1) == "_" then
        return nil
    end
    local check_exists = has_highlight_group or default_highlight_exists
    if type(language) == "string" and language ~= "" then
        local language_group = ("@%s.%s"):format(capture_name, language)
        if check_exists(language_group) then
            return language_group
        end
    end
    local prefix = capture_name
    while prefix and prefix ~= "" do
        local group_name = "@" .. prefix
        if check_exists(group_name) then
            return group_name
        end
        prefix = prefix:match("^(.+)%.[^.]+$")
    end
    return nil
end

--- Resolves the Treesitter language name for a Neovim `filetype`, or nil when
--- `filetype` is empty. Used by stream and file-diff syntax helpers.
function M.get_language_from_filetype(filetype)
    if type(filetype) ~= "string" or filetype == "" then
        return nil
    end
    local has_language, language = pcall(vim.treesitter.language.get_lang, filetype)
    if has_language and type(language) == "string" and language ~= "" then
        return language
    end
    return filetype
end

--- Looks up the Treesitter language name for a repository file `path`, or nil
--- when Neovim does not recognize the filetype. Used to pick a parser per file
--- section in the diff stream.
function M.get_language_from_path(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local has_filetype, filetype = pcall(vim.filetype.match, { filename = path })
    if not has_filetype then
        return nil
    end
    return M.get_language_from_filetype(filetype)
end

local function group_code_rows_by_path(code_rows)
    local groups = {}
    local current_group = nil
    for _, entry in ipairs(code_rows) do
        if not current_group or current_group.path ~= entry.path then
            current_group = { path = entry.path, rows = {} }
            groups[#groups + 1] = current_group
        end
        current_group.rows[#current_group.rows + 1] = entry
    end
    return groups
end

local function parse_source_root(lines, language)
    local source = table.concat(lines, "\n")
    local has_parser, parser = pcall(vim.treesitter.get_string_parser, source, language)
    if not has_parser or not parser then
        return nil, nil
    end
    local has_parsed, trees = pcall(parser.parse, parser)
    local root = has_parsed and trees and trees[1] and trees[1]:root()
    if not root then
        return nil, nil
    end
    return root, source
end

local function append_capture_spans(spans_by_line, lines, highlight_group, start_row, start_col, end_row, end_col)
    for row_index = start_row, end_row do
        local line_text = lines[row_index + 1]
        if line_text then
            local line_length = #line_text
            local col_start = row_index == start_row and math.max(0, math.min(start_col, line_length)) or 0
            local col_end = row_index == end_row and math.max(0, math.min(end_col, line_length)) or line_length
            if col_end > col_start then
                local line_spans = spans_by_line[row_index + 1]
                if not line_spans then
                    line_spans = {}
                    spans_by_line[row_index + 1] = line_spans
                end
                line_spans[#line_spans + 1] = {
                    col_start = col_start,
                    col_end = col_end,
                    hl_group = highlight_group,
                }
            end
        end
    end
end

--- Parses `lines` with Treesitter `language` and returns a 1-based line map of
--- `{ col_start, col_end, hl_group }` syntax spans, or an empty table when no
--- parser or highlights query is available.
function M.collect_line_spans(lines, language)
    if type(lines) ~= "table" or #lines == 0 or type(language) ~= "string" or language == "" then
        return {}
    end
    local has_query, query = pcall(vim.treesitter.query.get, language, "highlights")
    if not has_query or not query then
        return {}
    end
    local root, source = parse_source_root(lines, language)
    if not root then
        return {}
    end
    local spans_by_line = {}
    local highlight_groups_by_capture = {}
    for capture_id, node, metadata in query:iter_captures(root, source, 0, -1) do
        local capture_name = query.captures[capture_id]
        if capture_name and not IGNORED_CAPTURES[capture_name] and capture_name:sub(1, 1) ~= "_" then
            local highlight_group = highlight_groups_by_capture[capture_name]
            if highlight_group == nil then
                highlight_group = M.get_highlight_group_from_capture(capture_name, language) or false
                highlight_groups_by_capture[capture_name] = highlight_group
            end
            if highlight_group then
                local capture_meta = metadata and metadata[capture_id]
                local start_row, start_col, end_row, end_col
                if capture_meta and capture_meta.range then
                    local range = vim.treesitter.get_range(node, source, capture_meta)
                    start_row, start_col, end_row, end_col = range[1], range[2], range[4], range[5]
                else
                    start_row, start_col, end_row, end_col = node:range()
                end
                append_capture_spans(spans_by_line, lines, highlight_group, start_row, start_col, end_row, end_col)
            end
        end
    end
    return spans_by_line
end

local function apply_normal_fallbacks(buf, rows)
    for _, entry in ipairs(rows) do
        local contrast_kind = CHANGE_TO_CONTRAST_KIND[entry.change]
        if contrast_kind then
            local normal_group = highlights.get_contrast_group("Normal", contrast_kind)
            local total_length = entry.gutter_length + #entry.text
            if normal_group ~= "Normal" and total_length > 0 then
                vim.api.nvim_buf_set_extmark(buf, syntax_namespace, entry.line, 0, {
                    end_col = total_length,
                    hl_group = normal_group,
                    priority = NORMAL_FALLBACK_PRIORITY,
                    strict = false,
                })
            end
        end
    end
end

local function apply_spans_to_rows(buf, rows, spans_by_line)
    for row_index, spans in pairs(spans_by_line) do
        local entry = rows[row_index]
        if entry then
            local contrast_kind = CHANGE_TO_CONTRAST_KIND[entry.change]
            for _, span in ipairs(spans) do
                local effective_group = contrast_kind and highlights.get_contrast_group(span.hl_group, contrast_kind)
                    or span.hl_group
                vim.api.nvim_buf_set_extmark(buf, syntax_namespace, entry.line, entry.gutter_length + span.col_start, {
                    end_col = entry.gutter_length + span.col_end,
                    hl_group = effective_group,
                    priority = SYNTAX_PRIORITY,
                    strict = false,
                })
            end
        end
    end
end

local function highlight_file_group(buf, file_group)
    if #file_group.rows == 0 or #file_group.rows > MAX_FILE_ROWS then
        return
    end
    apply_normal_fallbacks(buf, file_group.rows)
    local language = M.get_language_from_path(file_group.path)
    if not language then
        return
    end
    local source_lines = {}
    for index, entry in ipairs(file_group.rows) do
        source_lines[index] = entry.text
    end
    local spans_by_line = M.collect_line_spans(source_lines, language)
    apply_spans_to_rows(buf, file_group.rows, spans_by_line)
end

--- Applies per-file Treesitter syntax extmarks and diff-row contrast fallbacks
--- onto `buf` for all code rows in `column`, clearing previous syntax extmarks
--- first. Called by `jpr.views.stream` whenever a stream buffer is filled.
function M.apply(buf, column)
    vim.api.nvim_buf_clear_namespace(buf, syntax_namespace, 0, -1)
    local code_rows = column and column.code_rows or {}
    for _, file_group in ipairs(group_code_rows_by_path(code_rows)) do
        highlight_file_group(buf, file_group)
    end
end

return M
