-- Pure: turns the engine's StreamView into the lines and highlights of one
-- column (unified) or two aligned columns (split), plus what each line
-- leads to. No windows or buffers here.
local one_line = require("jpr.render.panel").one_line

local M = {}

local VIEWED_MARK = { VIEWED = "✓", DISMISSED = "●", UNVIEWED = " " }
local SIGN = { added = "+", removed = "-", context = " " }
local LINE_GROUP = { added = "JprDiffAdd", removed = "JprDiffDelete" }
local WORD_GROUP = { added = "JprDiffAddText", removed = "JprDiffDeleteText" }

--- A file row's header line, such as `▾ ✓ src/a.rs  +12 -3`; `▸` marks a
--- folded file.
function M.build_file_header(row)
    return ("%s %s %s  +%d -%d"):format(
        row.folded and "▸" or "▾",
        VIEWED_MARK[row.viewed] or " ",
        one_line(row.path),
        row.additions,
        row.deletions
    )
end

local function create_column()
    return { lines = {}, line_groups = {}, highlights = {} }
end

--- Appends `text` to `column`, colored whole by `group` when given.
local function add_line(column, text, group)
    column.lines[#column.lines + 1] = text
    if group then
        column.line_groups[#column.lines] = group
    end
end

--- Highlights `cell`'s changed words on `column`'s last line, after a gutter
--- of `gutter` bytes.
local function add_words(column, cell, gutter)
    for _, word in ipairs(cell.words or {}) do
        column.highlights[#column.highlights + 1] = {
            line = #column.lines - 1,
            col_start = gutter + word.start,
            col_end = gutter + word["end"],
            group = WORD_GROUP[cell.change],
        }
    end
end

--- A unified row: both line numbers, the sign, and the text.
local function add_unified_row(column, row)
    local cell = row.right or row.left
    local gutter = ("%5s %5s %s "):format(row.left and row.left.line or "", row.right and row.right.line or "", SIGN[cell.change])
    add_line(column, gutter .. cell.text, LINE_GROUP[cell.change])
    add_words(column, cell, #gutter)
end

--- One side of a split row, or a filler line when that side has none.
local function add_split_cell(column, cell)
    if not cell then
        return add_line(column, "", "JprDiffFiller")
    end
    local gutter = ("%5d %s "):format(cell.line, SIGN[cell.change])
    add_line(column, gutter .. cell.text, LINE_GROUP[cell.change])
    add_words(column, cell, #gutter)
end

local function add_line_to_all_columns(columns, text, group)
    for _, column in ipairs(columns) do
        add_line(column, text, group)
    end
end

--- Folds lines `first_line` to `last_line` when a folded file's body has any.
local function close_fold(layout, first_line, last_line)
    if first_line and first_line <= last_line then
        layout.folds[#layout.folds + 1] = { first = first_line, last = last_line }
    end
end

--- Adds a hunk, note or line row as line `line`.
local function add_body_row(layout, row, line)
    if row.kind == "hunk" then
        add_line_to_all_columns(layout.columns, row.header, "JprHunk")
        layout.hunks[#layout.hunks + 1] = line
    elseif row.kind == "note" then
        add_line_to_all_columns(layout.columns, "  " .. one_line(row.text), "JprMuted")
    elseif #layout.columns == 2 then
        add_split_cell(layout.columns[1], row.left)
        add_split_cell(layout.columns[2], row.right)
    else
        add_unified_row(layout.columns[1], row)
    end
    if row.target then
        layout.targets[line] = { path = row.path, line = row.target }
    end
end

--- The lines of `stream` and where each leads:
--- { mode, columns, targets, files, hunks, folds }. `columns` holds one
--- column when unified and two (left, right) when split; a column is
--- { lines, line_groups, highlights } with `line_groups` keyed by 1-based
--- line and `highlights[].line` 0-based. `targets[line]` is the { path, line }
--- the line opens, `files` the { line, path, viewed } of each header,
--- `hunks` the hunk header lines, and `folds` the { first, last } bodies of
--- viewed files.
function M.create_layout_from_stream(stream)
    local is_split = stream.mode == "split"
    local layout = {
        mode = stream.mode,
        columns = is_split and { create_column(), create_column() } or { create_column() },
        targets = {},
        files = {},
        hunks = {},
        folds = {},
    }
    local fold_start
    for _, row in ipairs(stream.rows or {}) do
        local line = #layout.columns[1].lines + 1
        if row.kind == "file" then
            close_fold(layout, fold_start, line - 1)
            fold_start = row.folded and line + 1 or nil
            add_line_to_all_columns(layout.columns, M.build_file_header(row), "JprFileHeader")
            layout.files[#layout.files + 1] = { line = line, path = row.path, viewed = row.viewed }
            layout.targets[line] = { path = row.path, line = 1 }
        else
            add_body_row(layout, row, line)
        end
    end
    close_fold(layout, fold_start, #layout.columns[1].lines)
    return layout
end

--- The file whose section holds `line`, as an entry of `layout.files`.
function M.find_file_at_line(layout, line)
    local found
    for _, file in ipairs(layout.files) do
        if file.line > line then
            break
        end
        found = file
    end
    return found
end

--- The first file after `line` that is not viewed, for moving on once a
--- file is marked viewed.
function M.find_next_unviewed_file(layout, line)
    for _, file in ipairs(layout.files) do
        if file.line > line and file.viewed ~= "VIEWED" then
            return file
        end
    end
    return nil
end

--- The nearest of the sorted `lines` after `line` when `step` is 1, or
--- before it when `step` is -1.
function M.find_adjacent_line(lines, line, step)
    local found
    for _, candidate in ipairs(lines) do
        if step > 0 and candidate > line then
            return candidate
        end
        if step < 0 and candidate < line then
            found = candidate
        end
    end
    return found
end

--- What the stream is drawn from, as one string: the commits and each
--- file's counts and viewed state. A view with the same key draws the same
--- stream, so it need not be fetched again.
function M.build_key_from_view(view)
    local parts = { view.pr and view.pr.headSha or "", view.pr and view.pr.baseSha or "" }
    for _, file in ipairs(view.files or {}) do
        parts[#parts + 1] = table.concat({ file.path, file.additions, file.deletions, file.viewed }, "\0")
    end
    return table.concat(parts, "\n")
end

return M
