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

--- One removed line as virtual-text chunks: the line in the removed color,
--- its changed words in the stronger one, padded to `opts.width` so the color
--- spans the window. opts: { width, tabstop }.
function M.removed_line_to_chunks(removed, opts)
    local chunks, column, position = {}, 0, 1
    local function add_chunk(text, group)
        if text ~= "" then
            local expanded
            expanded, column = expand_tabs(text, opts.tabstop, column)
            chunks[#chunks + 1] = { expanded, group }
        end
    end
    for _, word in ipairs(removed.words or {}) do
        add_chunk(removed.text:sub(position, word.start), "JprDiffDelete")
        add_chunk(removed.text:sub(word.start + 1, word["end"]), "JprDiffDeleteText")
        position = word["end"] + 1
    end
    add_chunk(removed.text:sub(position), "JprDiffDelete")
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
--- tabstop } of the window, for the removed lines. An added line past the
--- end (the buffer was shortened since its last save) is left out.
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
    for _, block in ipairs(diff.removed or {}) do
        local virt_lines = {}
        for _, removed in ipairs(block.lines) do
            virt_lines[#virt_lines + 1] = M.removed_line_to_chunks(removed, opts)
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
