-- Pure tree building, directory filtering, viewed-state helpers, and tree row
-- rendering for the PR sidebar panel.
local header = require("jpr.render.panel.header")

local M = {}

local VIEWED_MARK = { VIEWED = "✓", DISMISSED = "●", UNVIEWED = " " }
local DIRECTORY_CHECK = "✓"

--- Tree rows for `files` when a view carries no tree: every file at the top
--- level, under its full path.
function M.create_flat_tree_from_files(files)
    local rows = {}
    for index, file in ipairs(files) do
        rows[index] = { depth = 0, name = file.path, file = index - 1 }
    end
    return rows
end

--- Collects all descendant changed file paths under `dir_path` together with
--- the target viewed flag (`true` if any descendant is not `VIEWED`, `false` if
--- all descendants are already `VIEWED`), or `nil` when zero files match.
function M.collect_directory_toggle_from_files(files, dir_path)
    if type(dir_path) ~= "string" then
        return nil
    end
    local normalized = dir_path:gsub("/+$", "")
    if normalized == "" then
        return nil
    end
    local prefix = normalized .. "/"
    local paths = {}
    local has_unviewed = false
    for _, file in ipairs(files or {}) do
        if type(file) == "table" and type(file.path) == "string" and vim.startswith(file.path, prefix) then
            paths[#paths + 1] = file.path
            if file.viewed ~= "VIEWED" then
                has_unviewed = true
            end
        end
    end
    if #paths == 0 then
        return nil
    end
    return { paths = paths, viewed = has_unviewed }
end

local function list_ordered_files_from_view(view)
    local files = type(view) == "table" and view.files or {}
    local tree = type(view) == "table" and view.tree or nil
    if type(tree) ~= "table" or #tree == 0 then
        return files
    end
    local ordered = {}
    for _, row in ipairs(tree) do
        local file = row.file ~= nil and files[row.file + 1] or nil
        if file then
            ordered[#ordered + 1] = file
        end
    end
    return #ordered > 0 and ordered or files
end

--- Finds the next unviewed file path after `current_path` in tree display
--- order, wrapping around to earlier files when none follow, or `nil` when
--- every file is `VIEWED`.
function M.find_next_unviewed_path(view, current_path)
    local ordered = list_ordered_files_from_view(view)
    local total = #ordered
    if total == 0 then
        return nil
    end
    local start_index = 0
    for index, file in ipairs(ordered) do
        if file.path == current_path then
            start_index = index
            break
        end
    end
    for offset = 1, total do
        local candidate = ordered[((start_index + offset - 1) % total) + 1]
        if candidate.path ~= current_path and candidate.viewed ~= "VIEWED" then
            return candidate.path
        end
    end
    return nil
end

--- A changed file still needs review unless it is marked `VIEWED`.
--- `DISMISSED` stays visible: the diff moved after the last review.
local function file_needs_review(file)
    return type(file) == "table" and file.viewed ~= "VIEWED"
end

--- Returns true when `files` is non-empty and every entry is marked `VIEWED`.
function M.every_file_is_viewed(files)
    if type(files) ~= "table" or #files == 0 then
        return false
    end
    for _, file in ipairs(files) do
        if file_needs_review(file) then
            return false
        end
    end
    return true
end

local function directory_needs_review(tree, dir_index, dir_depth, files)
    for index = dir_index + 1, #tree do
        local descendant = tree[index]
        if descendant.depth <= dir_depth then
            break
        end
        local file = descendant.file ~= nil and files[descendant.file + 1] or nil
        if file_needs_review(file) then
            return true
        end
    end
    return false
end

local function row_is_hidden_as_viewed(row, index, tree, files)
    if row.file ~= nil then
        return not file_needs_review(files[row.file + 1])
    end
    return not directory_needs_review(tree, index, row.depth, files)
end

local function count_descendant_viewed_files(tree, dir_index, dir_depth, files)
    local viewed_count = 0
    local total_count = 0
    for index = dir_index + 1, #tree do
        local descendant = tree[index]
        if descendant.depth <= dir_depth then
            break
        end
        local file = descendant.file ~= nil and files[descendant.file + 1] or nil
        if file then
            total_count = total_count + 1
            if file.viewed == "VIEWED" then
                viewed_count = viewed_count + 1
            end
        end
    end
    return viewed_count, total_count
end

local function build_directory_label(name, is_collapsed, viewed_count, total_count)
    local indicator = is_collapsed and "▸ " or "▾ "
    local is_complete = total_count > 0 and viewed_count == total_count
    local mark = is_complete and (DIRECTORY_CHECK .. " ") or ""
    local suffix = ""
    if is_collapsed and not is_complete then
        suffix = (" (%d/%d)"):format(viewed_count, total_count)
    end
    return indicator .. mark .. name .. "/" .. suffix, is_complete, #indicator
end

local function add_muted_span(content, line, col_start, col_end)
    if col_end > col_start then
        content.highlights[#content.highlights + 1] = {
            line = line,
            col_start = col_start,
            col_end = col_end,
            group = "JprMuted",
        }
    end
end

local function add_directory_highlights(content, line, indent_bytes, text_bytes, is_complete, indicator_bytes)
    if not is_complete then
        add_muted_span(content, line, 0, text_bytes)
        return
    end
    local mark_start = indent_bytes + indicator_bytes
    local mark_end = mark_start + #DIRECTORY_CHECK
    add_muted_span(content, line, 0, mark_start)
    content.highlights[#content.highlights + 1] = {
        line = line,
        col_start = mark_start,
        col_end = mark_end,
        group = "JprViewed",
    }
    add_muted_span(content, line, mark_end, text_bytes)
end

local function add_directory_line(content, row, dir_path, parent_dir, is_collapsed, viewed_count, total_count)
    local indent = ("  "):rep(row.depth)
    local label, is_complete, indicator_bytes =
        build_directory_label(header.one_line(row.name), is_collapsed, viewed_count, total_count)
    local text = indent .. label
    content.add_line(text)
    local line_1based = #content.lines
    add_directory_highlights(content, line_1based - 1, #indent, #text, is_complete, indicator_bytes)
    content.rows[line_1based] = {
        kind = "dir",
        path = dir_path,
        depth = row.depth,
        parent_dir = parent_dir,
        is_collapsed = is_collapsed,
    }
    content.selectable_lines[#content.selectable_lines + 1] = line_1based
end

local function add_file_line(content, file, name, indent, depth, parent_dir, is_unlinked_local)
    local mark = VIEWED_MARK[file.viewed] or " "
    local is_modified = file.isModified == true
    local modified_icon = "✎"
    local modified_prefix = is_modified and (modified_icon .. " ") or ""
    local plus = ("+%d"):format(file.additions)
    local stats = ("%s -%d"):format(plus, file.deletions)
    local threads_badge = header.build_threads_badge_from_file(file)
    local threads_suffix = threads_badge and (" " .. threads_badge) or ""
    local local_badge = (not is_unlinked_local and file.isLocalOnly == true) and "[local]" or nil
    local local_suffix = local_badge and (" " .. local_badge) or ""
    local shown_name = header.one_line(name)
    content.add_line(("%s%s %s%s  %s%s%s"):format(indent, mark, modified_prefix, shown_name, stats, threads_suffix, local_suffix))
    local line_1based = #content.lines
    local line = line_1based - 1
    content.paths[line_1based] = file.path
    content.rows[line_1based] = { kind = "file", path = file.path, depth = depth, parent_dir = parent_dir }
    content.selectable_lines[#content.selectable_lines + 1] = line_1based
    local mark_group = (file.viewed == "VIEWED" and "JprViewed") or (file.viewed == "DISMISSED" and "JprDismissed") or nil
    if mark_group then
        content.highlights[#content.highlights + 1] = { line = line, col_start = #indent, col_end = #indent + #mark, group = mark_group }
    end
    if is_modified then
        local modified_start = #indent + #mark + 1
        content.highlights[#content.highlights + 1] =
            { line = line, col_start = modified_start, col_end = modified_start + #modified_icon, group = "JprModified" }
    end
    local stats_start = #indent + #mark + 1 + #modified_prefix + #shown_name + 2
    content.highlights[#content.highlights + 1] = { line = line, col_start = stats_start, col_end = stats_start + #plus, group = "JprAdded" }
    content.highlights[#content.highlights + 1] =
        { line = line, col_start = stats_start + #plus + 1, col_end = stats_start + #stats, group = "JprRemoved" }
    if local_badge then
        local local_start = stats_start + #stats + #threads_suffix + 1
        content.highlights[#content.highlights + 1] =
            { line = line, col_start = local_start, col_end = local_start + #local_badge, group = "JprThreadLocal" }
    end
end

local function is_directory_collapsed(collapsed_dirs, parent_dir, segment, dir_path)
    if collapsed_dirs[dir_path] == true then
        return true
    end
    if segment:find("/", 1, true) == nil then
        return false
    end
    local current_path = parent_dir
    for part in segment:gmatch("[^/]+") do
        current_path = current_path and (current_path .. "/" .. part) or part
        if collapsed_dirs[current_path] == true then
            return true
        end
    end
    return false
end

--- Appends all visible directory and file rows from `view` onto `content`.
function M.render_tree_rows(content, view, collapsed_dirs, is_unlinked_local, hide_viewed)
    local files = view.files or {}
    local tree = view.tree or M.create_flat_tree_from_files(files)
    local dir_stack = {}
    local skip_depth = nil
    for index, row in ipairs(tree) do
        if skip_depth ~= nil then
            if row.depth > skip_depth then
                goto continue
            end
            skip_depth = nil
        end
        while #dir_stack > 0 and dir_stack[#dir_stack].depth >= row.depth do
            dir_stack[#dir_stack] = nil
        end
        if hide_viewed and row_is_hidden_as_viewed(row, index, tree, files) then
            if row.file == nil then
                skip_depth = row.depth
            end
            goto continue
        end
        local parent_dir = #dir_stack > 0 and dir_stack[#dir_stack].path or nil
        local file = row.file and files[row.file + 1]
        if file then
            add_file_line(content, file, row.name, ("  "):rep(row.depth), row.depth, parent_dir, is_unlinked_local)
        else
            local segment = tostring(row.name):gsub("/+$", "")
            local dir_path = parent_dir and (parent_dir .. "/" .. segment) or segment
            local is_collapsed = is_directory_collapsed(collapsed_dirs, parent_dir, segment, dir_path)
            local viewed_count, total_count = count_descendant_viewed_files(tree, index, row.depth, files)
            add_directory_line(content, row, dir_path, parent_dir, is_collapsed, viewed_count, total_count)
            if is_collapsed then
                skip_depth = row.depth
            else
                dir_stack[#dir_stack + 1] = { depth = row.depth, path = dir_path }
            end
        end
        ::continue::
    end
end

return M
