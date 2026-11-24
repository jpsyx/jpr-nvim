-- Per-file Treesitter syntax highlighting for rendered stream buffers.
local M = {}

local syntax_namespace = vim.api.nvim_create_namespace("jpr-stream-syntax")
local MAX_FILE_ROWS = 5000
local SYNTAX_PRIORITY = 90
local IGNORED_CAPTURES = { spell = true, nospell = true, conceal = true }

local function default_highlight_exists(group_name)
    return vim.fn.hlexists(group_name) == 1
end

--- Resolves a Treesitter `capture_name` for `lang` to the most specific
--- existing highlight group, checking `@<capture>.<lang>` first and then
--- walking dot-separated prefixes (`@a.b.c` -> `@a.b` -> `@a`).
function M.resolve_hl_group(capture_name, lang, exists_fn)
    if type(capture_name) ~= "string" or capture_name == "" or capture_name:sub(1, 1) == "_" then
        return nil
    end
    local check_exists = exists_fn or default_highlight_exists
    if type(lang) == "string" and lang ~= "" then
        local language_group = ("@%s.%s"):format(capture_name, lang)
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

--- Resolves a Treesitter language name from a repository file `path`, or nil
--- when Neovim does not recognize the filetype.
function M.resolve_lang_from_path(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local has_filetype, filetype = pcall(vim.filetype.match, { filename = path })
    if not has_filetype or type(filetype) ~= "string" or filetype == "" then
        return nil
    end
    local has_lang, language = pcall(vim.treesitter.language.get_lang, filetype)
    if has_lang and type(language) == "string" and language ~= "" then
        return language
    end
    return filetype
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

local function apply_capture_to_rows(buf, rows, highlight_group, start_row, start_col, end_row, end_col)
    for row_index = start_row, end_row do
        local entry = rows[row_index + 1]
        if entry then
            local line_length = #entry.text
            local col_start = row_index == start_row and math.max(0, math.min(start_col, line_length)) or 0
            local col_end = row_index == end_row and math.max(0, math.min(end_col, line_length)) or line_length
            if col_end > col_start then
                vim.api.nvim_buf_set_extmark(buf, syntax_namespace, entry.line, entry.gutter_len + col_start, {
                    end_col = entry.gutter_len + col_end,
                    hl_group = highlight_group,
                    priority = SYNTAX_PRIORITY,
                    strict = false,
                })
            end
        end
    end
end

local function parse_file_root(rows, lang)
    local source_lines = {}
    for index, entry in ipairs(rows) do
        source_lines[index] = entry.text
    end
    local source = table.concat(source_lines, "\n")
    local has_parser, parser = pcall(vim.treesitter.get_string_parser, source, lang)
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

local function highlight_file_group(buf, file_group)
    if #file_group.rows == 0 or #file_group.rows > MAX_FILE_ROWS then
        return
    end
    local lang = M.resolve_lang_from_path(file_group.path)
    if not lang then
        return
    end
    local has_query, query = pcall(vim.treesitter.query.get, lang, "highlights")
    if not has_query or not query then
        return
    end
    local root, source = parse_file_root(file_group.rows, lang)
    if not root then
        return
    end
    local resolved_groups_by_capture = {}
    for capture_id, node in query:iter_captures(root, source, 0, -1) do
        local capture_name = query.captures[capture_id]
        if capture_name and not IGNORED_CAPTURES[capture_name] and capture_name:sub(1, 1) ~= "_" then
            local resolved_group = resolved_groups_by_capture[capture_name]
            if resolved_group == nil then
                resolved_group = M.resolve_hl_group(capture_name, lang) or false
                resolved_groups_by_capture[capture_name] = resolved_group
            end
            if resolved_group then
                local start_row, start_col, end_row, end_col = node:range()
                apply_capture_to_rows(buf, file_group.rows, resolved_group, start_row, start_col, end_row, end_col)
            end
        end
    end
end

--- Applies per-file Treesitter syntax extmarks onto `buf` for all code rows in
--- `column`, clearing any previous syntax extmarks first.
function M.apply(buf, column)
    vim.api.nvim_buf_clear_namespace(buf, syntax_namespace, 0, -1)
    local code_rows = column and column.code_rows or {}
    for _, file_group in ipairs(group_code_rows_by_path(code_rows)) do
        highlight_file_group(buf, file_group)
    end
end

return M
