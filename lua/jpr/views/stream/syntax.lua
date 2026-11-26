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

--- Strips the minimum common leading whitespace across all non-blank lines in
--- `lines`, returning `(dedented_lines, stripped_bytes)`.
function M.dedent_lines(lines)
    local min_indent = nil
    for _, line_text in ipairs(lines) do
        if line_text:match("%S") ~= nil then
            local indent = #(line_text:match("^[ \t]*") or "")
            min_indent = min_indent and math.min(min_indent, indent) or indent
        end
    end
    if not min_indent or min_indent == 0 then
        return lines, 0
    end
    local dedented = {}
    for index, line_text in ipairs(lines) do
        dedented[index] = #line_text >= min_indent and line_text:sub(min_indent + 1) or ""
    end
    return dedented, min_indent
end

local function apply_row_spans(buf, entry, spans, col_offset)
    if not spans or #spans == 0 then
        return
    end
    local contrast_kind = CHANGE_TO_CONTRAST_KIND[entry.change]
    local offset = col_offset or 0
    local line_length = #entry.text
    for _, span in ipairs(spans) do
        local col_start = math.max(0, math.min(span.col_start + offset, line_length))
        local col_end = math.max(col_start, math.min(span.col_end + offset, line_length))
        if col_end > col_start then
            local effective_group = contrast_kind and highlights.get_contrast_group(span.hl_group, contrast_kind)
                or span.hl_group
            vim.api.nvim_buf_set_extmark(buf, syntax_namespace, entry.line, entry.gutter_length + col_start, {
                end_col = entry.gutter_length + col_end,
                hl_group = effective_group,
                priority = SYNTAX_PRIORITY,
                strict = false,
            })
        end
    end
end

local function read_worktree_file_lines(worktree, path)
    if type(worktree) ~= "string" or worktree == "" or type(path) ~= "string" or path == "" then
        return nil
    end
    local full_path = worktree .. "/" .. path
    if require("jpr.views.diff").name_to_relative_path(worktree, full_path) ~= path then
        return nil
    end
    local is_ok, file_lines = pcall(vim.fn.readfile, full_path)
    if not is_ok or type(file_lines) ~= "table" or #file_lines == 0 or #file_lines > MAX_FILE_ROWS then
        return nil
    end
    return file_lines
end

local function get_full_file_context(worktree, path, language, file_cache)
    local cached = file_cache[path]
    if cached ~= nil then
        return cached or nil
    end
    local file_lines = read_worktree_file_lines(worktree, path)
    if not file_lines then
        file_cache[path] = false
        return nil
    end
    local context = { lines = file_lines, spans = M.collect_line_spans(file_lines, language) }
    file_cache[path] = context
    return context
end

local function group_fallback_rows(rows)
    local groups = {}
    local current = nil
    for _, entry in ipairs(rows) do
        local is_removed = entry.change == "removed"
        local group_key = tostring(entry.hunk_index or 0) .. ":" .. tostring(is_removed)
        if not current or current.key ~= group_key then
            current = { key = group_key, rows = {} }
            groups[#groups + 1] = current
        end
        current.rows[#current.rows + 1] = entry
    end
    return groups
end

local function highlight_fallback_subgroup(buf, rows, language)
    local source_lines = {}
    for index, entry in ipairs(rows) do
        source_lines[index] = entry.text
    end
    local dedented, stripped_bytes = M.dedent_lines(source_lines)
    local spans_by_line = M.collect_line_spans(dedented, language)
    for row_index, entry in ipairs(rows) do
        local spans = spans_by_line[row_index]
        if spans and #spans > 0 then
            apply_row_spans(buf, entry, spans, stripped_bytes)
        elseif entry.text:match("%S") ~= nil then
            local single_dedented, single_stripped_bytes = M.dedent_lines({ entry.text })
            local recovered = M.collect_line_spans(single_dedented, language)
            apply_row_spans(buf, entry, recovered[1], single_stripped_bytes)
        end
    end
end

local function highlight_file_group(buf, file_group, worktree, file_cache)
    if #file_group.rows == 0 or #file_group.rows > MAX_FILE_ROWS then
        return
    end
    apply_normal_fallbacks(buf, file_group.rows)
    local language = M.get_language_from_path(file_group.path)
    if not language then
        return
    end
    local full_file = get_full_file_context(worktree, file_group.path, language, file_cache)
    local fallback_rows = {}
    for _, entry in ipairs(file_group.rows) do
        local right_line = entry.right_line
        if full_file and type(right_line) == "number" and full_file.lines[right_line] == entry.text then
            apply_row_spans(buf, entry, full_file.spans[right_line], 0)
        else
            fallback_rows[#fallback_rows + 1] = entry
        end
    end
    for _, subgroup in ipairs(group_fallback_rows(fallback_rows)) do
        highlight_fallback_subgroup(buf, subgroup.rows, language)
    end
end

--- Applies per-file Treesitter syntax extmarks and diff-row contrast fallbacks
--- onto `buf` for all code rows in `column`, clearing previous syntax extmarks
--- first. Optional `opts.worktree` enables full-file parsing so mid-file hunks
--- retain accurate language context.
function M.apply(buf, column, opts)
    vim.api.nvim_buf_clear_namespace(buf, syntax_namespace, 0, -1)
    local code_rows = column and column.code_rows or {}
    local worktree = type(opts) == "table" and opts.worktree or nil
    local file_cache = {}
    for _, file_group in ipairs(group_code_rows_by_path(code_rows)) do
        highlight_file_group(buf, file_group, worktree, file_cache)
    end
end

return M
