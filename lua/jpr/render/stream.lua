-- Pure: turns the engine's StreamView into the lines and highlights of one
-- column (unified) or two aligned columns (split), plus what each line
-- leads to. No windows or buffers here.
local one_line = require("jpr.render.panel").one_line
local threads_render = require("jpr.render.threads")

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
    return { lines = {}, line_groups = {}, highlights = {}, eol_marks = {}, code_rows = {} }
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

local function record_code_row(column, path, gutter_length, text)
    column.code_rows[#column.code_rows + 1] = {
        line = #column.lines - 1,
        path = path,
        gutter_length = gutter_length,
        text = text,
    }
end

--- A unified row: both line numbers, the sign, and the text.
local function add_unified_row(column, row)
    local cell = row.right or row.left
    local gutter = ("%5s %5s %s "):format(row.left and row.left.line or "", row.right and row.right.line or "", SIGN[cell.change])
    add_line(column, gutter .. cell.text, LINE_GROUP[cell.change])
    add_words(column, cell, #gutter)
    record_code_row(column, row.path, #gutter, cell.text)
end

--- One side of a split row, or a filler line when that side has none.
local function add_split_cell(column, cell, path)
    if not cell then
        return add_line(column, "", "JprDiffFiller")
    end
    local gutter = ("%5d %s "):format(cell.line, SIGN[cell.change])
    add_line(column, gutter .. cell.text, LINE_GROUP[cell.change])
    add_words(column, cell, #gutter)
    record_code_row(column, path, #gutter, cell.text)
end

local function add_line_to_all_columns(columns, text, group)
    for _, column in ipairs(columns) do
        add_line(column, text, group)
    end
end

local function append_virt_line_to_column(column, virt_line)
    if not virt_line then
        return add_line(column, "", "JprDiffFiller")
    end
    local chunk = virt_line[1]
    local group = chunk[2] ~= "Normal" and chunk[2] or nil
    add_line(column, chunk[1], group)
end

local function append_expanded_threads(columns, threads)
    if #columns == 1 then
        for _, virt_line in ipairs(threads_render.create_expanded_virt_lines_from_threads(threads, false)) do
            append_virt_line_to_column(columns[1], virt_line)
        end
        return
    end
    local left_threads, right_threads = threads_render.partition_threads_by_side(threads)
    local left_virt_lines = threads_render.create_expanded_virt_lines_from_threads(left_threads, false)
    local right_virt_lines = threads_render.create_expanded_virt_lines_from_threads(right_threads, false)
    local max_virt_lines = math.max(#left_virt_lines, #right_virt_lines)
    for index = 1, max_virt_lines do
        append_virt_line_to_column(columns[1], left_virt_lines[index])
        append_virt_line_to_column(columns[2], right_virt_lines[index])
    end
end

local function add_thread_row(layout, row, line, is_expanded)
    local sign, group = threads_render.pick_sign({ row.thread })
    local local_badge = threads_render.build_local_badge_from_thread(row.thread)
    local local_tag = local_badge ~= "" and (" " .. local_badge) or ""
    local badge = ("  %s @%s: %s%s"):format(sign, one_line(row.thread.firstAuthor or ""), one_line(row.thread.snippet or ""), local_tag)
    add_line_to_all_columns(layout.columns, badge, group)
    layout.threads_by_line[line] = { row.thread }
    layout.thread_lines[#layout.thread_lines + 1] = line
    layout.anchors[line] = { file = row.path, kind = "file", side = "RIGHT" }
    if is_expanded then
        append_expanded_threads(layout.columns, { row.thread })
    end
end

local function append_eol_mark(column, line, threads)
    if #threads == 0 then
        return
    end
    column.eol_marks[#column.eol_marks + 1] = {
        line = line - 1,
        chunks = threads_render.create_eol_chunks_from_threads(threads),
    }
end

local function add_line_threads(layout, row, line, is_expanded)
    layout.anchors[line] = {
        file = row.path,
        side = (row.left and not row.right) and "LEFT" or "RIGHT",
        left_line = row.left and row.left.line or nil,
        right_line = row.right and row.right.line or nil,
    }
    local row_threads = row.threads or {}
    if #row_threads == 0 then
        return
    end
    layout.threads_by_line[line] = row_threads
    layout.thread_lines[#layout.thread_lines + 1] = line
    if is_expanded then
        return append_expanded_threads(layout.columns, row_threads)
    end
    if #layout.columns == 1 then
        return append_eol_mark(layout.columns[1], line, row_threads)
    end
    local left_threads, right_threads = threads_render.partition_threads_by_side(row_threads)
    append_eol_mark(layout.columns[1], line, left_threads)
    append_eol_mark(layout.columns[2], line, right_threads)
end

--- Folds lines `first_line` to `last_line` when a folded file's body has any.
local function close_fold(layout, first_line, last_line)
    if first_line and first_line <= last_line then
        layout.folds[#layout.folds + 1] = { first = first_line, last = last_line }
    end
end

--- Adds a hunk, note, thread or line row as line `line`.
local function add_body_row(layout, row, line, is_expanded)
    if row.kind == "hunk" then
        add_line_to_all_columns(layout.columns, row.header, "JprHunk")
        layout.hunks[#layout.hunks + 1] = line
    elseif row.kind == "note" then
        add_line_to_all_columns(layout.columns, "  " .. one_line(row.text), "JprMuted")
    elseif row.kind == "thread" then
        add_thread_row(layout, row, line, is_expanded)
    else
        if #layout.columns == 2 then
            add_split_cell(layout.columns[1], row.left, row.path)
            add_split_cell(layout.columns[2], row.right, row.path)
        else
            add_unified_row(layout.columns[1], row)
        end
        add_line_threads(layout, row, line, is_expanded)
    end
    if row.target then
        layout.targets[line] = { path = row.path, line = row.target }
    end
end

--- The lines of `stream` and where each leads:
--- { mode, columns, targets, files, hunks, folds, threads_by_line, thread_lines, anchors }.
--- `columns` holds one column when unified and two (left, right) when split;
--- a column is { lines, line_groups, highlights, eol_marks, code_rows } with `line_groups`
--- keyed by 1-based line and `highlights[].line` / `eol_marks[].line` / `code_rows[].line` 0-based.
--- `opts.expanded` renders full indented thread messages across columns.
function M.create_layout_from_stream(stream, opts)
    local is_split = stream.mode == "split"
    local is_expanded = opts and opts.expanded == true
    local layout = {
        mode = stream.mode,
        columns = is_split and { create_column(), create_column() } or { create_column() },
        targets = {},
        files = {},
        hunks = {},
        folds = {},
        threads_by_line = {},
        thread_lines = {},
        anchors = {},
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
            add_body_row(layout, row, line, is_expanded)
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

--- What the stream is drawn from, as one string: the commits, session counts,
--- and each file's counts, viewed state, and thread count. A view with the
--- same key draws the same stream, so it need not be fetched again.
function M.build_key_from_view(view)
    local local_unsent_count = type(view.localUnsentCount) == "number" and view.localUnsentCount or 0
    local parts = {
        view.pr and view.pr.headSha or "",
        view.pr and view.pr.baseSha or "",
        tostring(view.threadCount or 0),
        tostring(view.draftCount or 0),
        tostring(local_unsent_count),
        tostring(view.queuedCount or 0),
    }
    for _, file in ipairs(view.files or {}) do
        parts[#parts + 1] = table.concat(
            { file.path, file.additions, file.deletions, file.viewed, file.threads or 0 },
            "\0"
        )
    end
    return table.concat(parts, "\n")
end

return M
