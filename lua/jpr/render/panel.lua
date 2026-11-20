-- Pure: turns the engine's SessionView into panel lines, highlights and a
-- line-to-path map. No windows or buffers here.
local M = {}

local VIEWED_MARK = { VIEWED = "✓", DISMISSED = "●", UNVIEWED = " " }

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

--- @return table { lines: string[], highlights: { line, col_start, col_end, group }[], paths: table<integer, string> }
--- `line` is 0-based and columns are byte offsets; `paths` is keyed by 1-based line number.
function M.build(view, now)
    local lines, highlights, paths = {}, {}, {}
    local function add(text, group)
        lines[#lines + 1] = text
        if group then
            highlights[#highlights + 1] = { line = #lines - 1, col_start = 0, col_end = #text, group = group }
        end
    end

    local pr = view.pr
    add(pr and ("#%d %s"):format(pr.number, M.one_line(pr.title)) or "Loading pull request…", "JprTitle")
    local files = view.files or {}
    add(("viewed %d/%d · threads %d"):format(view.viewedCount or 0, #files, view.threadCount or 0), "JprMuted")
    add(M.sync_text(view.sync, now))
    add("")

    for _, file in ipairs(files) do
        local mark = VIEWED_MARK[file.viewed] or " "
        local plus = ("+%d"):format(file.additions)
        local stats = ("%s -%d"):format(plus, file.deletions)
        local threads = file.threads > 0 and (" [%d]"):format(file.threads) or ""
        local shown_path = M.one_line(file.path)
        add(("%s %s  %s%s"):format(mark, shown_path, stats, threads))
        local line = #lines - 1
        paths[#lines] = file.path
        if file.viewed == "VIEWED" then
            highlights[#highlights + 1] = { line = line, col_start = 0, col_end = #mark, group = "JprViewed" }
        elseif file.viewed == "DISMISSED" then
            highlights[#highlights + 1] = { line = line, col_start = 0, col_end = #mark, group = "JprDismissed" }
        end
        local stats_start = #mark + 1 + #shown_path + 2
        highlights[#highlights + 1] = { line = line, col_start = stats_start, col_end = stats_start + #plus, group = "JprAdded" }
        highlights[#highlights + 1] =
            { line = line, col_start = stats_start + #plus + 1, col_end = stats_start + #stats, group = "JprRemoved" }
    end

    return { lines = lines, highlights = highlights, paths = paths }
end

return M
