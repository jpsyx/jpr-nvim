-- Pure: turns the engine's SessionView into panel lines, highlights and a
-- line-to-path map. No windows or buffers here.
local wrap_text = require("jpr.tui.render").wrap_text

local M = {}

local VIEWED_MARK = { VIEWED = "✓", DISMISSED = "●", UNVIEWED = " " }

--- How long ago `seconds` was, in the largest whole unit up to hours, for
--- example `2m ago`, for the panel's sync line.
function M.age(seconds)
    if seconds < 60 then
        return ("%ds ago"):format(seconds)
    end
    if seconds < 3600 then
        return ("%dm ago"):format(math.floor(seconds / 60))
    end
    return ("%dh ago"):format(math.floor(seconds / 3600))
end

--- `text` on one line: a buffer line cannot hold a newline, and gh's errors
--- and git's file names can.
function M.one_line(text)
    return vim.trim((tostring(text):gsub("%s*[\r\n]+%s*", " ")))
end

--- PR head/base plus the session checkout branch when it is a different name.
--- A reused checkout of `headRef` is the head line itself.
function M.build_branch_detail_lines(pr, local_context, checkout_branch)
    local lines = {}
    local head = type(pr) == "table" and type(pr.headRef) == "string" and pr.headRef or ""
    local base = type(pr) == "table" and type(pr.baseRef) == "string" and pr.baseRef or ""
    local local_branch = type(local_context) == "table" and type(local_context.branch) == "string" and local_context.branch or ""
    if head ~= "" and base ~= "" then
        lines[#lines + 1] = head .. " -> " .. base
    elseif head ~= "" then
        lines[#lines + 1] = head
    elseif base ~= "" then
        lines[#lines + 1] = base
    end
    local shown = head ~= "" and head or local_branch
    if type(checkout_branch) == "string" and checkout_branch ~= "" and checkout_branch ~= shown then
        lines[#lines + 1] = "checkout " .. checkout_branch
    end
    return lines
end

local function add_fitted_line(content, text, group, width)
    local clean = M.one_line(text)
    local lines = { clean }
    if type(width) == "number" and width >= 8 and vim.fn.strdisplaywidth(clean) > width then
        lines = wrap_text(clean, width)
    end
    for _, line in ipairs(lines) do
        content.add_line(line, group)
    end
end

--- The sync status line and its highlight group.
function M.sync_text(sync, now)
    if not sync or sync.state == "never" then
        return "not synced yet", "JprMuted"
    end
    if sync.state == "synced" then
        return "synced " .. M.age(math.max(0, now - sync.at)), "JprMuted"
    end
    return "sync failed: " .. M.one_line(sync.message or "unknown error"), "JprError"
end

--- Builds the read-only and git worktree status prefix for `view`, or nil when
--- writable and clean with zero ahead/behind commits.
function M.build_worktree_badge_from_view(view)
    local parts = {}
    if view.isReadOnly == true then
        parts[#parts + 1] = "[read-only]"
    end
    local status = type(view.worktreeStatus) == "table" and view.worktreeStatus or nil
    if status then
        local is_dirty = status.isDirty == true
        local ahead = type(status.ahead) == "number" and status.ahead or 0
        local behind = type(status.behind) == "number" and status.behind or 0
        if is_dirty then
            parts[#parts + 1] = "dirty"
        end
        if is_dirty or ahead > 0 or behind > 0 then
            parts[#parts + 1] = ("↑%d ↓%d"):format(ahead, behind)
        end
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, " · ")
end

--- The counts line: optional worktree/read-only badge, viewed files, threads,
--- drafts, local unsent threads, and viewed marks still waiting for GitHub.
function M.build_counts_text(view)
    local badge = M.build_worktree_badge_from_view(view)
    local prefix = badge and (badge .. " · ") or ""
    local text = prefix .. ("viewed %d/%d · threads %d"):format(view.viewedCount or 0, #(view.files or {}), view.threadCount or 0)
    if (view.draftCount or 0) > 0 then
        text = text .. (" · drafts %d"):format(view.draftCount)
    end
    local local_unsent_count = type(view.localUnsentCount) == "number" and view.localUnsentCount or 0
    if local_unsent_count > 0 then
        text = text .. (" · local unsent %d"):format(local_unsent_count)
    end
    if (view.queuedCount or 0) > 0 then
        text = text .. (" · %d waiting for GitHub"):format(view.queuedCount)
    end
    return text
end

--- Builds the per-file thread count badge (`[2]`, `[2 · 1L]`, or `[1L]`), or
--- nil when `file` has no threads.
function M.build_threads_badge_from_file(file)
    local total_threads = type(file.threads) == "number" and file.threads or 0
    local local_threads = type(file.localThreads) == "number" and file.localThreads or 0
    local github_threads = math.max(0, total_threads - local_threads)
    if total_threads <= 0 and local_threads <= 0 then
        return nil
    end
    if local_threads <= 0 then
        return ("[%d]"):format(total_threads)
    end
    if github_threads <= 0 then
        return ("[%dL]"):format(local_threads)
    end
    return ("[%d · %dL]"):format(github_threads, local_threads)
end

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

--- Adds one file's line to `content`: indent, viewed mark, modified mark, name,
--- counts, threads, and optional local-only badge, with their highlights.
local function add_file_line(content, file, name, indent, depth, parent_dir, is_unlinked_local)
    local mark = VIEWED_MARK[file.viewed] or " "
    local is_modified = file.isModified == true
    local modified_icon = "✎"
    local modified_prefix = is_modified and (modified_icon .. " ") or ""
    local plus = ("+%d"):format(file.additions)
    local stats = ("%s -%d"):format(plus, file.deletions)
    local threads_badge = M.build_threads_badge_from_file(file)
    local threads_suffix = threads_badge and (" " .. threads_badge) or ""
    local local_badge = (not is_unlinked_local and file.isLocalOnly == true) and "[local]" or nil
    local local_suffix = local_badge and (" " .. local_badge) or ""
    local shown_name = M.one_line(name)
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

local DIRECTORY_CHECK = "✓"

--- A changed file still needs review unless it is marked `VIEWED`.
--- `DISMISSED` stays visible: the diff moved after the last review.
local function file_needs_review(file)
    return type(file) == "table" and file.viewed ~= "VIEWED"
end

--- True when any changed file under the directory at `dir_index` still needs review.
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

--- True when `hide_viewed` should omit this tree row and, for a directory, its descendants.
local function row_is_hidden_as_viewed(row, index, tree, files)
    if row.file ~= nil then
        return not file_needs_review(files[row.file + 1])
    end
    return not directory_needs_review(tree, index, row.depth, files)
end

--- Counts changed files nested under the directory at `dir_index`, including
--- files inside child directories. `viewed_count` includes only `VIEWED`.
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

--- Directory label after the indent: fold indicator, optional check, name,
--- and a collapsed viewed/total suffix while any descendant file is unviewed.
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

--- Paints a directory line muted, with the check in `JprViewed` when every
--- nested file is viewed.
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
        build_directory_label(M.one_line(row.name), is_collapsed, viewed_count, total_count)
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

local function is_directory_collapsed(collapsed_dirs, parent_dir, segment, dir_path)
    if collapsed_dirs[dir_path] == true then
        return true
    end
    if segment:find("/", 1, true) == nil then
        return false
    end
    local current = parent_dir
    for part in segment:gmatch("[^/]+") do
        current = current and (current .. "/" .. part) or part
        if collapsed_dirs[current] == true then
            return true
        end
    end
    return false
end

local function render_tree_rows(content, view, collapsed_dirs, is_unlinked_local, hide_viewed)
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

local DEFAULT_PROGRESS_BAR_WIDTH = 16
local PROGRESS_FILLED_CELL = "█"
local PROGRESS_UNFILLED_CELL = "░"

--- Creates visual progress bar text and byte-range metadata for reviewed or
--- processed counts, used by the PR sidebar panel and the live loading view.
--- @param viewed_count integer|nil
--- @param total_count integer|nil
--- @param bar_width integer|nil
--- @param unit_label string|nil Optional unit noun placed after the ratio (for example `"files"`).
--- @return table { text: string, filled_bytes: integer, unfilled_bytes: integer, counter_start: integer, is_complete: boolean }
function M.create_progress_bar_from_counts(viewed_count, total_count, bar_width, unit_label)
    local width = math.max(1, math.floor(tonumber(bar_width) or DEFAULT_PROGRESS_BAR_WIDTH))
    local safe_total = math.max(0, math.floor(tonumber(total_count) or 0))
    local clamped_viewed = math.max(0, math.min(math.floor(tonumber(viewed_count) or 0), safe_total))
    local percent = safe_total > 0 and math.floor((clamped_viewed * 100) / safe_total + 0.5) or 0
    local filled_cells = 0
    if safe_total > 0 then
        if clamped_viewed == safe_total then
            filled_cells = width
        elseif clamped_viewed > 0 then
            filled_cells = math.max(0, math.min(width, math.floor((clamped_viewed * width) / safe_total + 0.5)))
        end
    end
    local filled = PROGRESS_FILLED_CELL:rep(filled_cells)
    local unfilled = PROGRESS_UNFILLED_CELL:rep(width - filled_cells)
    local has_unit_label = type(unit_label) == "string" and unit_label ~= ""
    local counter = has_unit_label
            and ("%d/%d %s (%d%%)"):format(clamped_viewed, safe_total, unit_label, percent)
        or ("%d/%d (%d%%)"):format(clamped_viewed, safe_total, percent)
    local text = filled .. unfilled .. "  " .. counter
    return {
        text = text,
        filled_bytes = #filled,
        unfilled_bytes = #unfilled,
        counter_start = #filled + #unfilled + 2,
        is_complete = safe_total > 0 and clamped_viewed == safe_total,
    }
end

--- Appends the filled, unfilled, and counter highlight spans for `progress_bar`
--- on 0-based `line` starting at `col_offset`. Shared by the panel and loading
--- renderers so both color progress bars identically.
function M.append_progress_bar_highlights(highlights, line, col_offset, progress_bar)
    if progress_bar.filled_bytes > 0 then
        highlights[#highlights + 1] = {
            line = line,
            col_start = col_offset,
            col_end = col_offset + progress_bar.filled_bytes,
            group = "JprViewed",
        }
    end
    if progress_bar.unfilled_bytes > 0 then
        highlights[#highlights + 1] = {
            line = line,
            col_start = col_offset + progress_bar.filled_bytes,
            col_end = col_offset + progress_bar.filled_bytes + progress_bar.unfilled_bytes,
            group = "JprMuted",
        }
    end
    highlights[#highlights + 1] = {
        line = line,
        col_start = col_offset + progress_bar.counter_start,
        col_end = col_offset + #progress_bar.text,
        group = progress_bar.is_complete and "JprViewed" or "JprTitle",
    }
end

local function every_file_is_viewed(files)
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

local function build_visible_counts_text(view, hide_viewed)
    local text = M.build_counts_text(view)
    if hide_viewed then
        return text .. " · unviewed only"
    end
    return text
end

local function add_progress_bar_line(content, view)
    local files = view.files or {}
    local progress_bar = M.create_progress_bar_from_counts(view.viewedCount or 0, #files)
    content.add_line(progress_bar.text)
    M.append_progress_bar_highlights(content.highlights, #content.lines - 1, 0, progress_bar)
end

--- The panel's contents for `view` at time `now` (Unix seconds): its lines,
--- their highlights, row metadata, selectable lines, and which file each line
--- shows, for the panel window to draw and navigate. `opts.hide_viewed`
--- omits `VIEWED` files and directories whose files are all `VIEWED`.
--- @return table { lines: string[], highlights: table[], paths: table<integer, string>, rows: table<integer, table>, selectable_lines: integer[], summary_line: integer, conversation_line: integer }
--- `line` is 0-based and columns are byte offsets; `paths` and `rows` are keyed by 1-based line number.
function M.build(view, now, opts)
    local collapsed_dirs = type(opts) == "table" and type(opts.collapsed_dirs) == "table" and opts.collapsed_dirs or {}
    local width = type(opts) == "table" and tonumber(opts.width) or nil
    local checkout_branch = type(opts) == "table" and opts.checkout_branch or nil
    local hide_viewed = type(opts) == "table" and opts.hide_viewed == true
    local content = { lines = {}, highlights = {}, paths = {}, rows = {}, selectable_lines = {} }
    function content.add_line(text, group)
        content.lines[#content.lines + 1] = text
        if group then
            content.highlights[#content.highlights + 1] = { line = #content.lines - 1, col_start = 0, col_end = #text, group = group }
        end
    end
    local pr = view.pr
    local local_ctx = type(view.localContext) == "table" and view.localContext or nil
    local is_unlinked_local = pr == nil and local_ctx ~= nil
    if pr then
        add_fitted_line(content, ("#%d %s"):format(pr.number, pr.title or ""), "JprTitle", width)
    elseif local_ctx then
        add_fitted_line(content, ("LOCAL %s vs %s"):format(local_ctx.branch or "", local_ctx.baseRef or ""), "JprTitle", width)
    else
        add_fitted_line(content, "Loading pull request…", "JprTitle", width)
    end
    for _, branch_line in ipairs(M.build_branch_detail_lines(pr, local_ctx, checkout_branch)) do
        add_fitted_line(content, branch_line, "JprMuted", width)
    end
    add_progress_bar_line(content, view)
    content.add_line(build_visible_counts_text(view, hide_viewed), "JprMuted")
    if is_unlinked_local then
        content.add_line("local only · :Jpr sync to link PR", "JprMuted")
    else
        content.add_line(M.sync_text(view.sync, now))
    end
    content.add_line("")
    content.add_line("  📄 Diff summary", "JprTitle")
    local summary_line = #content.lines
    content.rows[summary_line] = { kind = "summary" }
    content.selectable_lines[#content.selectable_lines + 1] = summary_line
    local conversation_count = view.conversationCount or 0
    local conversation_suffix = conversation_count > 0 and (" [%d]"):format(conversation_count) or ""
    local conversation_title = is_unlinked_local and "  💬 Local Notes" or "  💬 Conversation"
    content.add_line(conversation_title .. conversation_suffix, "JprTitle")
    local conversation_line = #content.lines
    content.rows[conversation_line] = { kind = "conversation" }
    content.selectable_lines[#content.selectable_lines + 1] = conversation_line
    render_tree_rows(content, view, collapsed_dirs, is_unlinked_local, hide_viewed)
    if hide_viewed and every_file_is_viewed(view.files) then
        content.add_line("  all files viewed", "JprMuted")
    end
    return {
        lines = content.lines,
        highlights = content.highlights,
        paths = content.paths,
        rows = content.rows,
        selectable_lines = content.selectable_lines,
        summary_line = summary_line,
        conversation_line = conversation_line,
    }
end

return M
