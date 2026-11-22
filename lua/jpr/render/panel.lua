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

--- The counts line: viewed files, threads, drafts, local unsent threads, and
--- viewed marks still waiting for GitHub.
function M.build_counts_text(view)
    local text = ("viewed %d/%d · threads %d"):format(view.viewedCount or 0, #(view.files or {}), view.threadCount or 0)
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

--- Tree rows for `files` when a view carries no tree: every file at the top
--- level, under its full path.
function M.create_flat_tree_from_files(files)
    local rows = {}
    for index, file in ipairs(files) do
        rows[index] = { depth = 0, name = file.path, file = index - 1 }
    end
    return rows
end

--- Adds one file's line to `content`: indent, viewed mark, name, counts and
--- threads, with their highlights.
local function add_file_line(content, file, name, indent)
    local mark = VIEWED_MARK[file.viewed] or " "
    local plus = ("+%d"):format(file.additions)
    local stats = ("%s -%d"):format(plus, file.deletions)
    local threads = file.threads > 0 and (" [%d]"):format(file.threads) or ""
    local shown_name = M.one_line(name)
    content.add_line(("%s%s %s  %s%s"):format(indent, mark, shown_name, stats, threads))
    local line = #content.lines - 1
    content.paths[#content.lines] = file.path
    local mark_group = (file.viewed == "VIEWED" and "JprViewed") or (file.viewed == "DISMISSED" and "JprDismissed") or nil
    if mark_group then
        content.highlights[#content.highlights + 1] = { line = line, col_start = #indent, col_end = #indent + #mark, group = mark_group }
    end
    local stats_start = #indent + #mark + 1 + #shown_name + 2
    content.highlights[#content.highlights + 1] = { line = line, col_start = stats_start, col_end = stats_start + #plus, group = "JprAdded" }
    content.highlights[#content.highlights + 1] =
        { line = line, col_start = stats_start + #plus + 1, col_end = stats_start + #stats, group = "JprRemoved" }
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
