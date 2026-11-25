-- Pure O(1) statusline formatter for an open pull-request review tab.
-- Reads in-memory session fields only: never spawns processes or makes RPC calls.
local M = {}

local function build_head_segment_from_status(status)
    if type(status) ~= "table" then
        return nil
    end
    local parts = {}
    if status.isDirty == true then
        parts[#parts + 1] = "dirty"
    end
    local ahead = type(status.ahead) == "number" and status.ahead or 0
    local behind = type(status.behind) == "number" and status.behind or 0
    if ahead > 0 then
        parts[#parts + 1] = ("↑%d"):format(ahead)
    end
    if behind > 0 then
        parts[#parts + 1] = ("↓%d"):format(behind)
    end
    return #parts > 0 and table.concat(parts, " ") or nil
end

--- Builds a concise statusline summary for `session`, or `""` when `session` is nil.
function M.build_statusline_from_session(session)
    if type(session) ~= "table" then
        return ""
    end
    local view = type(session.view) == "table" and session.view or {}
    local is_local = type(session.number) ~= "number"
    local local_ctx = type(view.localContext) == "table" and view.localContext or nil
    if is_local and session.mode ~= "local" and local_ctx == nil then
        return ""
    end
    local branch = (local_ctx and local_ctx.branch) or session.branch or "local"
    local prefix = is_local and ("LOCAL " .. tostring(branch)) or ("PR #" .. tostring(session.number))
    local segments = { prefix }
    if session.is_read_only == true or view.isReadOnly == true then
        segments[#segments + 1] = "[read-only]"
    end
    if type(view.pr) ~= "table" and local_ctx == nil then
        segments[#segments + 1] = "Loading…"
        return table.concat(segments, " · ")
    end
    local head_segment = build_head_segment_from_status(view.worktreeStatus)
    if head_segment then
        segments[#segments + 1] = head_segment
    end
    local files = type(view.files) == "table" and view.files or {}
    local viewed_count = type(view.viewedCount) == "number" and view.viewedCount or 0
    segments[#segments + 1] = ("%d/%d viewed"):format(viewed_count, #files)
    local draft_count = type(view.draftCount) == "number" and view.draftCount or 0
    if draft_count > 0 then
        segments[#segments + 1] = ("%d drafts"):format(draft_count)
    end
    local local_unsent_count = type(view.localUnsentCount) == "number" and view.localUnsentCount or 0
    if local_unsent_count > 0 then
        segments[#segments + 1] = ("%d local"):format(local_unsent_count)
    end
    if type(view.sync) == "table" and view.sync.state == "failed" then
        segments[#segments + 1] = "sync!"
    end
    return table.concat(segments, " · ")
end

return M
