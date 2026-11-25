-- Pure: turns the engine's FileDiffView into extmark specs for a unified
-- overlay, and a base text into buffer lines. No windows or buffers here.
local M = {}

--- `text` as buffer lines: split on newlines, without the empty line a final
--- newline leaves and without carriage returns, as a buffer read with
--- `fileformat=dos` shows none either.
function M.text_to_lines(text)
    if not text or text == "" then
        return {}
    end
    local lines = vim.split(text, "\n", { plain = true })
    if lines[#lines] == "" then
        lines[#lines] = nil
    end
    for index, line in ipairs(lines) do
        lines[index] = line:gsub("\r$", "")
    end
    return lines
end

--- The cells a tab-free `run` takes in a virtual line, where a control
--- character (a byte below 0x20, or DEL) is drawn as two cells (`^[`, `^@`).
local function get_width_from_run(run)
    -- `nvim_strwidth` counts a control character as one cell and stops at a
    -- NUL, so they are counted here and the rest is measured in one call.
    -- Control bytes never occur inside a multibyte UTF-8 sequence, so
    -- removing them leaves the rest intact.
    local printable, control_count = run:gsub("[%z\1-\31\127]", "")
    return vim.api.nvim_strwidth(printable) + 2 * control_count
end

--- `text` with tabs expanded to `tabstop` columns, starting at display
--- column `column`; returns the text and the column after it. Each NUL
--- becomes "\n", which a virtual line draws as `^@` (two cells, as counted);
--- a NUL itself would end the chunk there.
local function expand_tabs(text, tabstop, column)
    -- Plain Lua string functions only: a Vimscript call would turn text
    -- holding a NUL into a Blob and fail.
    local parts, position = {}, 1
    while true do
        local tab_position = text:find("\t", position, true)
        local run = text:sub(position, tab_position and tab_position - 1 or #text)
        parts[#parts + 1] = (run:gsub("%z", "\n"))
        column = column + get_width_from_run(run)
        if not tab_position then
            return table.concat(parts), column
        end
        local spaces = tabstop - (column % tabstop)
        parts[#parts + 1] = (" "):rep(spaces)
        column = column + spaces
        position = tab_position + 1
    end
end

local function collect_sorted_boundaries(text_length, words, syntax_spans)
    local seen = { [0] = true, [text_length] = true }
    local points = { 0, text_length }
    local function add_point(offset)
        local clamped = math.max(0, math.min(text_length, offset))
        if not seen[clamped] then
            seen[clamped] = true
            points[#points + 1] = clamped
        end
    end
    for _, word in ipairs(words or {}) do
        add_point(word.start)
        add_point(word["end"])
    end
    for _, span in ipairs(syntax_spans or {}) do
        add_point(span.col_start)
        add_point(span.col_end)
    end
    table.sort(points)
    return points
end

local function resolve_segment_highlight(seg_start, seg_end, words, syntax_spans, fg_group)
    local bg_group = "JprDiffDelete"
    for _, word in ipairs(words or {}) do
        if word.start <= seg_start and word["end"] >= seg_end then
            bg_group = "JprDiffDeleteText"
            break
        end
    end
    local resolved_fg = fg_group
    for _, span in ipairs(syntax_spans or {}) do
        if span.col_start <= seg_start and span.col_end >= seg_end then
            resolved_fg = span.hl_group
        end
    end
    return resolved_fg and { bg_group, resolved_fg } or bg_group
end

local function append_styled_removed_chunks(removed, opts, add_chunk)
    local boundaries = collect_sorted_boundaries(#removed.text, removed.words, opts.syntax_spans)
    for index = 1, #boundaries - 1 do
        local seg_start = boundaries[index]
        local seg_end = boundaries[index + 1]
        if seg_end > seg_start then
            local highlight = resolve_segment_highlight(seg_start, seg_end, removed.words, opts.syntax_spans, opts.fg_group)
            add_chunk(removed.text:sub(seg_start + 1, seg_end), highlight)
        end
    end
end

--- One removed line as virtual-text chunks: the line in the removed color,
--- its changed words in the stronger one, padded to `opts.width` so the color
--- spans the window. opts: { width, tabstop, fg_group?, syntax_spans? }.
function M.removed_line_to_chunks(removed, opts)
    local chunks, column = {}, 0
    local function add_chunk(text, group)
        if text ~= "" then
            local expanded
            expanded, column = expand_tabs(text, opts.tabstop, column)
            chunks[#chunks + 1] = { expanded, group }
        end
    end
    if opts.fg_group or (opts.syntax_spans and #opts.syntax_spans > 0) then
        append_styled_removed_chunks(removed, opts, add_chunk)
    else
        local position = 1
        for _, word in ipairs(removed.words or {}) do
            add_chunk(removed.text:sub(position, word.start), "JprDiffDelete")
            add_chunk(removed.text:sub(word.start + 1, word["end"]), "JprDiffDeleteText")
            position = word["end"] + 1
        end
        add_chunk(removed.text:sub(position), "JprDiffDelete")
    end
    if column < opts.width then
        chunks[#chunks + 1] = { (" "):rep(opts.width - column), "JprDiffDelete" }
    end
    if #chunks == 0 then
        chunks[1] = { "", "JprDiffDelete" }
    end
    return chunks
end

--- The extmarks that draw `diff` on a buffer of `line_count` lines, as
--- { line, col, opts } with 0-based lines and byte columns. opts: { width,
--- tabstop, removed_fg_group?, removed_syntax_by_block? } of the window, for
--- the removed lines. An added line past the end (the buffer was shortened
--- since its last save) is left out.
function M.create_extmarks_from_diff(diff, line_count, opts)
    local marks = {}
    for _, added in ipairs(diff.added or {}) do
        local line = added.line - 1
        if line < line_count then
            marks[#marks + 1] = { line = line, col = 0, opts = { line_hl_group = "JprDiffAdd" } }
            for _, word in ipairs(added.words or {}) do
                marks[#marks + 1] =
                    { line = line, col = word.start, opts = { end_col = word["end"], hl_group = "JprDiffAddText" } }
            end
        end
    end
    local syntax_by_block = opts.removed_syntax_by_block or {}
    for block_index, block in ipairs(diff.removed or {}) do
        local block_spans = syntax_by_block[block_index] or {}
        local virt_lines = {}
        for line_index, removed in ipairs(block.lines) do
            local line_opts = {
                width = opts.width,
                tabstop = opts.tabstop,
                fg_group = opts.removed_fg_group,
                syntax_spans = block_spans[line_index],
            }
            virt_lines[#virt_lines + 1] = M.removed_line_to_chunks(removed, line_opts)
        end
        local is_past_end = block.above > line_count
        marks[#marks + 1] = {
            line = is_past_end and math.max(line_count - 1, 0) or block.above - 1,
            col = 0,
            opts = { virt_lines = virt_lines, virt_lines_above = not is_past_end },
        }
    end
    return marks
end

return M
