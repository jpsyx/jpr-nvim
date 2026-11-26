local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local helpers = dofile(root .. "/tests/lua/support/helpers.lua")
local render_submit = require("jpr.render.submit")

local function has_highlight(highlights, line_text, lines, expected_group)
    local target_idx
    for idx, text in ipairs(lines) do
        if text == line_text then
            target_idx = idx - 1
            break
        end
    end
    if not target_idx then
        return false
    end
    for _, highlight in ipairs(highlights) do
        if highlight.line == target_idx and highlight.group == expected_group then
            return true
        end
    end
    return false
end

-- 1. Draft list, blocked reason, selected action, and sanitized multi-line summary.
local preview_allowed = {
    draftCount = 3,
    drafts = {
        {
            threadId = "T1",
            messageId = "M1",
            anchor = { file = "src/a.rs", kind = "line", side = "RIGHT", start = 10, ["end"] = 12 },
            snippet = "first line\nsecond\r\nthird",
        },
        {
            threadId = "T2",
            messageId = "M2",
            anchor = { file = "docs/note\nline.md", kind = "file", side = "RIGHT" },
            snippet = "file comment",
        },
        {
            threadId = "T3",
            messageId = "M3",
            anchor = { kind = "pr", side = "RIGHT" },
            snippet = "pr level",
        },
    },
    canApproveOrRequestChanges = true,
    blockedReason = "2 comments pending\nplease wait",
}

local built = render_submit.build(preview_allowed, "COMMENT", { "Looks solid\r", "Line\nbreak" })
local joined = table.concat(built.lines, "\n")
assert(not joined:find("\226\128\148", 1, true), "render output contains no em dash")
assert(helpers.find_line_number(built.lines, "Blocked: 2 comments pending please wait") == 1, "blockedReason rendered on line 1")
assert(has_highlight(built.highlights, built.lines[1], built.lines, "JprError"), "blockedReason uses JprError")

assert(helpers.find_line_number(built.lines, "  [x] 1. Comment") ~= nil, "COMMENT selected")
assert(helpers.find_line_number(built.lines, "  [ ] 2. Approve") ~= nil, "APPROVE unselected")
assert(helpers.find_line_number(built.lines, "  [ ] 3. Request changes") ~= nil, "REQUEST_CHANGES unselected")
assert(has_highlight(built.highlights, "  [x] 1. Comment", built.lines, "JprViewed"), "selected event uses JprViewed")

assert(helpers.find_line_number(built.lines, "Pending Drafts (3):") ~= nil, "draft count header rendered")
local line_draft_row = helpers.find_line_number(built.lines, "src/a.rs:12: first line second third")
assert(line_draft_row ~= nil and built.draft_anchors[line_draft_row] == preview_allowed.drafts[1].anchor, "line draft mapped")
local file_draft_row = helpers.find_line_number(built.lines, "docs/note line.md: file comment")
assert(file_draft_row ~= nil and built.draft_anchors[file_draft_row] == preview_allowed.drafts[2].anchor, "file draft mapped")
local pr_draft_row = helpers.find_line_number(built.lines, "PR: pr level")
assert(pr_draft_row ~= nil and built.draft_anchors[pr_draft_row] == preview_allowed.drafts[3].anchor, "pr draft mapped")
assert(helpers.find_line_number(built.lines, "  Looks solid") ~= nil, "body line 1 rendered")
assert(helpers.find_line_number(built.lines, "  Line break") ~= nil, "body line 2 sanitized")
local comment_row = helpers.find_line_number(built.lines, "  [x] 1. Comment")
local approve_row = helpers.find_line_number(built.lines, "  [ ] 2. Approve")
local request_row = helpers.find_line_number(built.lines, "  [ ] 3. Request changes")
assert(type(built.event_lines) == "table", "event_lines map returned")
assert(built.event_lines[comment_row] == "COMMENT", "comment event line mapped")
assert(built.event_lines[approve_row] == "APPROVE", "approve event line mapped")
assert(built.event_lines[request_row] == "REQUEST_CHANGES", "request changes event line mapped")
local summary_header_row = helpers.find_line_number(built.lines, "Summary Body (press e to edit):")
local summary_line_row = helpers.find_line_number(built.lines, "  Looks solid")
assert(type(built.summary_lines) == "table" and built.summary_lines[summary_header_row] == true, "summary header mapped")
assert(built.summary_lines[summary_line_row] == true, "summary body line mapped")
assert(built.footer_line == #built.lines, "footer_line points to last line")

-- 2. Zero drafts and own PR restrictions.
local preview_own_empty = {
    draftCount = 0,
    drafts = {},
    canApproveOrRequestChanges = false,
    blockedReason = nil,
}
local built_own = render_submit.build(preview_own_empty, "COMMENT", {})
local own_joined = table.concat(built_own.lines, "\n")
assert(not own_joined:find("\226\128\148", 1, true), "zero-draft output contains no em dash")
assert(helpers.find_line_number(built_own.lines, "  (none - submits review summary only)") ~= nil, "zero drafts message")
assert(next(built_own.draft_anchors) == nil, "no draft anchors when draftCount == 0")
local approve_own_line = "  [ ] 2. Approve (unavailable on your own PR)"
local changes_own_line = "  [ ] 3. Request changes (unavailable on your own PR)"
assert(helpers.find_line_number(built_own.lines, approve_own_line) ~= nil, "approve unavailable note")
assert(helpers.find_line_number(built_own.lines, changes_own_line) ~= nil, "request changes unavailable note")
assert(has_highlight(built_own.highlights, approve_own_line, built_own.lines, "JprMuted"), "approve muted")
assert(has_highlight(built_own.highlights, changes_own_line, built_own.lines, "JprMuted"), "request changes muted")
assert(helpers.find_line_number(built_own.lines, "  (optional for Approve / Drafts; required for empty Comment)") ~= nil, "empty body hint")

print("submit_render_spec: ok")
