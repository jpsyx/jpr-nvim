-- Pure: turns the engine's SessionView into panel lines, highlights and a
-- line-to-path map. No windows or buffers here.
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

--- Adds one file's line to `content`: indent, viewed mark, modified mark, name,
--- counts and threads, with their highlights.
local function add_file_line(content, file, name, indent)
    local mark = VIEWED_MARK[file.viewed] or " "
    local is_modified = file.isModified == true
    local modified_icon = "✎"
    local modified_prefix = is_modified and (modified_icon .. " ") or ""
    local plus = ("+%d"):format(file.additions)
    local stats = ("%s -%d"):format(plus, file.deletions)
    local threads_badge = M.build_threads_badge_from_file(file)
    local threads_suffix = threads_badge and (" " .. threads_badge) or ""
    local shown_name = M.one_line(name)
    content.add_line(("%s%s %s%s  %s%s"):format(indent, mark, modified_prefix, shown_name, stats, threads_suffix))
    local line = #content.lines - 1
    content.paths[#content.lines] = file.path
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
end

local DEFAULT_PROGRESS_BAR_WIDTH = 16
local PROGRESS_FILLED_CELL = "█"
local PROGRESS_UNFILLED_CELL = "░"

--- Builds the reviewed-files visual progress bar text and byte-range metadata.
--- @param viewed_count integer|nil
--- @param total_count integer|nil
--- @param bar_width integer|nil
--- @return table { text: string, filled_bytes: integer, unfilled_bytes: integer, counter_start: integer, is_complete: boolean }
function M.build_progress_bar_from_counts(viewed_count, total_count, bar_width)
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
    local counter = ("%d/%d (%d%%)"):format(clamped_viewed, safe_total, percent)
    local text = filled .. unfilled .. "  " .. counter
    return {
        text = text,
        filled_bytes = #filled,
        unfilled_bytes = #unfilled,
        counter_start = #filled + #unfilled + 2,
        is_complete = safe_total > 0 and clamped_viewed == safe_total,
    }
end

local function add_progress_bar_line(content, view)
    local files = view.files or {}
    local progress = M.build_progress_bar_from_counts(view.viewedCount or 0, #files)
    content.add_line(progress.text)
    local line = #content.lines - 1
    if progress.filled_bytes > 0 then
        content.highlights[#content.highlights + 1] = {
            line = line,
            col_start = 0,
            col_end = progress.filled_bytes,
            group = "JprViewed",
        }
    end
    if progress.unfilled_bytes > 0 then
        content.highlights[#content.highlights + 1] = {
            line = line,
            col_start = progress.filled_bytes,
            col_end = progress.filled_bytes + progress.unfilled_bytes,
            group = "JprMuted",
        }
    end
    content.highlights[#content.highlights + 1] = {
        line = line,
        col_start = progress.counter_start,
        col_end = #progress.text,
        group = progress.is_complete and "JprViewed" or "JprTitle",
    }
end

--- The panel's contents for `view` at time `now` (Unix seconds): its lines,
--- their highlights, and which file each line shows, for the panel window to
--- draw and to open files from.
--- @return table { lines: string[], highlights: { line, col_start, col_end, group }[], paths: table<integer, string>, conversation_line: integer }
--- `line` is 0-based and columns are byte offsets; `paths` is keyed by 1-based line number.
function M.build(view, now)
    local content = { lines = {}, highlights = {}, paths = {} }
    function content.add_line(text, group)
        content.lines[#content.lines + 1] = text
        if group then
            content.highlights[#content.highlights + 1] = { line = #content.lines - 1, col_start = 0, col_end = #text, group = group }
        end
    end
    local pr = view.pr
    content.add_line(pr and ("#%d %s"):format(pr.number, M.one_line(pr.title)) or "Loading pull request…", "JprTitle")
    add_progress_bar_line(content, view)
    content.add_line(M.build_counts_text(view), "JprMuted")
    content.add_line(M.sync_text(view.sync, now))
    content.add_line("")
    local conversation_count = view.conversationCount or 0
    local conversation_suffix = conversation_count > 0 and (" [%d]"):format(conversation_count) or ""
    content.add_line("  💬 Conversation" .. conversation_suffix, "JprTitle")
    local conversation_line = #content.lines
    local files = view.files or {}
    for _, row in ipairs(view.tree or M.create_flat_tree_from_files(files)) do
        local indent = ("  "):rep(row.depth)
        local file = row.file and files[row.file + 1]
        if file then
            add_file_line(content, file, row.name, indent)
        else
            content.add_line(indent .. M.one_line(row.name) .. "/", "JprMuted")
        end
    end
    return { lines = content.lines, highlights = content.highlights, paths = content.paths, conversation_line = conversation_line }
end

return M
