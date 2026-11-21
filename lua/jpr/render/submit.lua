-- Pure: formats the :Jpr submit modal from SubmitPreview, chosen event, and
-- summary body. No windows or buffers here.
local one_line = require("jpr.render.panel").one_line

local M = {}

local EVENTS = {
    { id = "COMMENT", key = "1", label = "Comment" },
    { id = "APPROVE", key = "2", label = "Approve" },
    { id = "REQUEST_CHANGES", key = "3", label = "Request changes" },
}

local function sanitize_body_line(line)
    return (tostring(line):gsub("\r$", ""):gsub("[\r\n]+", " "))
end

local function append_events(add, preview, selected_event)
    add("Review Action (press 1/2/3):", "JprTitle")
    for _, option in ipairs(EVENTS) do
        local is_restricted = option.id ~= "COMMENT" and not preview.canApproveOrRequestChanges
        local is_selected = selected_event == option.id
        local mark = is_selected and "[x]" or "[ ]"
        local note = is_restricted and " (unavailable on your own PR)" or ""
        local group = is_restricted and "JprMuted" or (is_selected and "JprViewed" or nil)
        add(("  %s %s. %s%s"):format(mark, option.key, option.label, note), group)
    end
end

local function append_drafts(layout, add, preview)
    add(("Pending Drafts (%d):"):format(preview.draftCount or 0), "JprTitle")
    if (preview.draftCount or 0) == 0 then
        add("  (none - submits review summary only)", "JprMuted")
        return
    end
    for _, draft in ipairs(preview.drafts or {}) do
        local anchor = draft.anchor or {}
        local location = anchor.file or "PR"
        local line_number = anchor["end"] or anchor.start
        if anchor.file and line_number then
            location = ("%s:%d"):format(location, line_number)
        end
        add(("  • %s: %s"):format(one_line(location), one_line(draft.snippet or "")), "JprThreadDraft")
        layout.draft_anchors[#layout.lines] = draft.anchor
    end
end

local function append_body(add, body_lines)
    add("Summary Body (press e to edit):", "JprTitle")
    local has_body = body_lines and #body_lines > 0 and vim.trim(table.concat(body_lines, "\n")) ~= ""
    if not has_body then
        add("  (optional for Approve / Drafts; required for empty Comment)", "JprMuted")
        return
    end
    for _, line in ipairs(body_lines) do
        add("  " .. sanitize_body_line(line))
    end
end

--- Builds the `:Jpr submit` modal lines, highlights, and cursor-line to draft
--- anchor map from `preview`, `selected_event`, and `body_lines`.
--- @return table { lines: string[], highlights: { line, col_start, col_end, group }[], draft_anchors: table<integer, table> }
function M.build(preview, selected_event, body_lines)
    local layout = { lines = {}, highlights = {}, draft_anchors = {} }
    local add = function(text, group)
        layout.lines[#layout.lines + 1] = text
        if group then
            layout.highlights[#layout.highlights + 1] = {
                line = #layout.lines - 1,
                col_start = 0,
                col_end = #text,
                group = group,
            }
        end
    end
    local current_preview = preview or {}
    if current_preview.blockedReason and current_preview.blockedReason ~= "" then
        add("Blocked: " .. one_line(current_preview.blockedReason), "JprError")
        add("")
    end
    append_events(add, current_preview, selected_event)
    add("")
    append_drafts(layout, add, current_preview)
    add("")
    append_body(add, body_lines)
    add("")
    add("[1/2/3] action  [e] summary  [<CR>] open draft / submit  [<C-s>] submit  [q] cancel", "JprMuted")
    return layout
end

return M
