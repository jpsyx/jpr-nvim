-- Pure header, badge, and text-formatting helpers for the PR sidebar panel.
local wrap_text = require("jpr.tui.render").wrap_text

local M = {}

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

--- Appends `text` wrapped to `width` (when wide enough) onto `content`.
function M.add_fitted_line(content, text, group, width)
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

return M
