local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local view_mode = require("jpr.view_mode")
local render_submit = require("jpr.render.submit")
local submit_view = require("jpr.views.submit")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new", "line three", "line four", "line five" }, worktree .. "/README.md")

local function read_requests(method_name)
    if vim.fn.filereadable(log) == 0 then
        return {}
    end
    local matches = {}
    for _, line in ipairs(vim.fn.readfile(log)) do
        local ok, decoded = pcall(vim.json.decode, line)
        if ok and type(decoded) == "table" and decoded.method == method_name then
            matches[#matches + 1] = decoded
        end
    end
    return matches
end

local function press_key(lhs)
    local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    vim.api.nvim_feedkeys(keys, "xt", false)
end

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
    for _, hl in ipairs(highlights) do
        if hl.line == target_idx and hl.group == expected_group then
            return true
        end
    end
    return false
end

local function find_line_number(lines, needle)
    for idx, line in ipairs(lines) do
        if line:find(needle, 1, true) then
            return idx
        end
    end
    return nil
end

-- 1. Pure render.submit.build tests.
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
assert(find_line_number(built.lines, "Blocked: 2 comments pending please wait") == 1, "blockedReason rendered on line 1")
assert(has_highlight(built.highlights, built.lines[1], built.lines, "JprError"), "blockedReason uses JprError")

assert(find_line_number(built.lines, "  [x] 1. Comment") ~= nil, "COMMENT selected")
assert(find_line_number(built.lines, "  [ ] 2. Approve") ~= nil, "APPROVE unselected")
assert(find_line_number(built.lines, "  [ ] 3. Request changes") ~= nil, "REQUEST_CHANGES unselected")
assert(has_highlight(built.highlights, "  [x] 1. Comment", built.lines, "JprViewed"), "selected event uses JprViewed")

assert(find_line_number(built.lines, "Pending Drafts (3):") ~= nil, "draft count header rendered")
local line_draft_row = find_line_number(built.lines, "src/a.rs:12: first line second third")
assert(line_draft_row ~= nil and built.draft_anchors[line_draft_row] == preview_allowed.drafts[1].anchor, "line draft mapped")
local file_draft_row = find_line_number(built.lines, "docs/note line.md: file comment")
assert(file_draft_row ~= nil and built.draft_anchors[file_draft_row] == preview_allowed.drafts[2].anchor, "file draft mapped")
local pr_draft_row = find_line_number(built.lines, "PR: pr level")
assert(pr_draft_row ~= nil and built.draft_anchors[pr_draft_row] == preview_allowed.drafts[3].anchor, "pr draft mapped")
assert(find_line_number(built.lines, "  Looks solid") ~= nil, "body line 1 rendered")
assert(find_line_number(built.lines, "  Line break") ~= nil, "body line 2 sanitized")

-- Zero drafts and own PR restrictions.
local preview_own_empty = {
    draftCount = 0,
    drafts = {},
    canApproveOrRequestChanges = false,
    blockedReason = nil,
}
local built_own = render_submit.build(preview_own_empty, "COMMENT", {})
local own_joined = table.concat(built_own.lines, "\n")
assert(not own_joined:find("\226\128\148", 1, true), "zero-draft output contains no em dash")
assert(find_line_number(built_own.lines, "  (none - submits review summary only)") ~= nil, "zero drafts message")
assert(next(built_own.draft_anchors) == nil, "no draft anchors when draftCount == 0")
local approve_own_line = "  [ ] 2. Approve (unavailable on your own PR)"
local changes_own_line = "  [ ] 3. Request changes (unavailable on your own PR)"
assert(find_line_number(built_own.lines, approve_own_line) ~= nil, "approve unavailable note")
assert(find_line_number(built_own.lines, changes_own_line) ~= nil, "request changes unavailable note")
assert(has_highlight(built_own.highlights, approve_own_line, built_own.lines, "JprMuted"), "approve muted")
assert(has_highlight(built_own.highlights, changes_own_line, built_own.lines, "JprMuted"), "request changes muted")
assert(find_line_number(built_own.lines, "  (optional for Approve / Drafts; required for empty Comment)") ~= nil, "empty body hint")

-- 2. session.submit_current() without open session errors via jpr.error.
local errors, infos = {}, {}
local orig_error, orig_info = jpr.error, jpr.info
jpr.error = function(msg)
    errors[#errors + 1] = msg
end
jpr.info = function(msg)
    infos[#infos + 1] = msg
end

session.submit_current()
assert(#errors == 1 and errors[1]:find("no pull request", 1, true) ~= nil, vim.inspect(errors))
errors = {}

-- Start session with fake_engine.sh.
session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "session syncs")

-- 3. Opening :Jpr submit requests submitPreview and opens a centered rounded floating nofile/markdown window.
local previews_before = #read_requests("submitPreview")
session.submit_current()
assert(vim.wait(3000, function()
    return review.submit ~= nil and review.submit.win ~= nil and vim.api.nvim_win_is_valid(review.submit.win)
end), "submit modal opens")
assert(#read_requests("submitPreview") == previews_before + 1, "submitPreview RPC sent")

local modal_win = review.submit.win
local modal_buf = review.submit.buf
local modal_cfg = vim.api.nvim_win_get_config(modal_win)
assert(modal_cfg.relative == "editor", "submit modal is floating")
assert(modal_cfg.border ~= nil, "submit modal has rounded border")
assert(vim.bo[modal_buf].buftype == "nofile", "submit modal buftype is nofile")
assert(vim.bo[modal_buf].filetype == "markdown", "submit modal filetype is markdown")
assert(vim.bo[modal_buf].modifiable == false, "submit modal is read-only")

-- 4. Selecting 1/2/3 when allowed.
press_key("2")
assert(review.submit.event == "APPROVE", "2 selects APPROVE")
assert(find_line_number(vim.api.nvim_buf_get_lines(modal_buf, 0, -1, false), "  [x] 2. Approve") ~= nil)
press_key("3")
assert(review.submit.event == "REQUEST_CHANGES", "3 selects REQUEST_CHANGES")
assert(find_line_number(vim.api.nvim_buf_get_lines(modal_buf, 0, -1, false), "  [x] 3. Request changes") ~= nil)
press_key("1")
assert(review.submit.event == "COMMENT", "1 selects COMMENT")

-- 5. Pressing e opens summary editor, q/<Esc> cancels without overwriting, <C-s> saves (including empty clear).
press_key("e")
assert(review.submit.editor ~= nil and vim.api.nvim_win_is_valid(review.submit.editor.win), "summary editor opened")
local ed_buf = review.submit.editor.buf
assert(vim.bo[ed_buf].buftype == "nofile", "editor buftype is nofile")
assert(vim.bo[ed_buf].filetype == "markdown", "editor filetype is markdown")
vim.api.nvim_buf_set_lines(ed_buf, 0, -1, false, { "Looks solid", "Nice tests" })
press_key("<C-s>")
assert(review.submit.editor == nil, "<C-s> closes summary editor")
assert(vim.api.nvim_get_current_win() == modal_win, "focus returned to submit modal")
assert(vim.deep_equal(review.submit.body_lines, { "Looks solid", "Nice tests" }), "body_lines updated")
assert(find_line_number(vim.api.nvim_buf_get_lines(modal_buf, 0, -1, false), "  Looks solid") ~= nil)

-- Cancel via q and <Esc> preserves prior body_lines.
press_key("e")
vim.api.nvim_buf_set_lines(review.submit.editor.buf, 0, -1, false, { "Discarded text" })
press_key("q")
assert(review.submit.editor == nil and vim.api.nvim_get_current_win() == modal_win, "q closes editor and restores focus")
assert(vim.deep_equal(review.submit.body_lines, { "Looks solid", "Nice tests" }), "q does not overwrite body_lines")

press_key("e")
vim.api.nvim_buf_set_lines(review.submit.editor.buf, 0, -1, false, { "Also discarded" })
press_key("<Esc>")
assert(review.submit.editor == nil, "<Esc> closes editor")
assert(vim.deep_equal(review.submit.body_lines, { "Looks solid", "Nice tests" }), "<Esc> does not overwrite body_lines")

-- Clearing summary and saving with <C-s> updates body_lines to empty.
press_key("e")
vim.api.nvim_buf_set_lines(review.submit.editor.buf, 0, -1, false, { "" })
press_key("<C-s>")
assert(vim.deep_equal(review.submit.body_lines, { "" }), "empty cleared summary saved")
assert(find_line_number(vim.api.nvim_buf_get_lines(modal_buf, 0, -1, false), "  (optional for Approve / Drafts; required for empty Comment)") ~= nil)

-- 6. <CR> on a draft row jumps to file:line via main_window.edit and closes submit modal without calling submitReview.
local draft_row
for line_num, _ in pairs(review.submit.rendered.draft_anchors) do
    draft_row = line_num
    break
end
assert(draft_row ~= nil, "draft row found in modal")
local submits_before_jump = #read_requests("submitReview")
vim.api.nvim_win_set_cursor(modal_win, { draft_row, 0 })
press_key("<CR>")
assert(review.submit == nil, "<CR> on draft row closes submit modal")
assert(#read_requests("submitReview") == submits_before_jump, "<CR> on draft row does not call submitReview")
local main_win = main_window.find(review)
assert(vim.api.nvim_get_current_win() == main_win, "focus moved to main_window")
assert(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(main_win)):sub(-9) == "README.md", "opened draft file")
assert(vim.api.nvim_win_get_cursor(main_win)[1] == 2, "cursor placed at anchor line 2")

-- 7. Closing via q, <Esc>, M.close, and BufWipeout cleans up session.submit (including open summary editor).
session.submit_current()
assert(vim.wait(3000, function()
    return review.submit ~= nil
end), "reopened submit modal")
press_key("q")
assert(review.submit == nil, "q closes submit modal")

session.submit_current()
assert(vim.wait(3000, function()
    return review.submit ~= nil
end), "reopened submit modal for Esc")
press_key("<Esc>")
assert(review.submit == nil, "<Esc> closes submit modal")

session.submit_current()
assert(vim.wait(3000, function()
    return review.submit ~= nil
end), "reopened submit modal with sub-editor")
press_key("e")
local sub_editor_buf = review.submit.editor.buf
local parent_modal_buf = review.submit.buf
assert(vim.api.nvim_buf_is_valid(sub_editor_buf), "sub-editor valid")
submit_view.close(review)
assert(review.submit == nil, "M.close clears session.submit")
assert(not vim.api.nvim_buf_is_valid(parent_modal_buf), "M.close wipes modal buffer")
assert(not vim.api.nvim_buf_is_valid(sub_editor_buf), "M.close wipes open summary sub-editor")

session.submit_current()
assert(vim.wait(3000, function()
    return review.submit ~= nil
end), "reopened submit modal for BufWipeout")
press_key("e")
local wipe_sub_buf = review.submit.editor.buf
local wipe_modal_win = review.submit.win
vim.api.nvim_win_close(wipe_modal_win, true)
assert(review.submit == nil, "BufWipeout on modal clears session.submit")
assert(not vim.api.nvim_buf_is_valid(wipe_sub_buf), "BufWipeout on modal closes sub-editor")

-- 8. Custom preview scenarios: blockedReason, own PR restrictions, empty zero-draft COMMENT, PR-draft jump, submitReview error + retry.
local orig_request = review.client.request
local mock_preview
local mock_submit_error
local hold_preview_cb
local hold_submit_cb
local submit_calls = 0

review.client.request = function(client_self, method, params, cb)
    if method == "submitPreview" then
        if hold_preview_cb == true then
            hold_preview_cb = cb
            return
        end
        local result = vim.deepcopy(mock_preview)
        vim.schedule(function()
            cb(nil, result)
        end)
        return
    elseif method == "submitReview" then
        submit_calls = submit_calls + 1
        if hold_submit_cb == true then
            hold_submit_cb = cb
            return
        end
        if mock_submit_error then
            local err = mock_submit_error
            vim.schedule(function()
                cb(err, nil)
            end)
            return
        end
    end
    return orig_request(client_self, method, params, cb)
end

-- 8a. Stale submitPreview callback guard (superseded by newer request / close / session.closing).
hold_preview_cb = true
submit_view.open(review)
local stale_cb = hold_preview_cb
assert(type(stale_cb) == "function", "captured first submitPreview callback")
submit_view.close(review)
stale_cb(nil, preview_own_empty)
assert(review.submit == nil, "stale submitPreview callback after close does not open modal")
hold_preview_cb = nil

-- 8b. Blocked reason refuses <C-s> and non-draft <CR> with jpr.error(preview.blockedReason).
mock_preview = {
    draftCount = 1,
    drafts = {
        { threadId = "T1", messageId = "M1", anchor = { file = "README.md", kind = "line", start = 1, ["end"] = 1 }, snippet = "hi" },
    },
    canApproveOrRequestChanges = false,
    blockedReason = "1 comment is still sending",
}
session.submit_current()
assert(vim.wait(3000, function()
    return review.submit ~= nil
end), "blocked modal opens")

-- Own PR refuses 2 and 3 with jpr.info without changing selected event.
infos = {}
press_key("2")
assert(review.submit.event == "COMMENT", "2 ignored on own PR")
assert(#infos == 1 and infos[1]:find("own PR", 1, true) ~= nil, vim.inspect(infos))
infos = {}
press_key("3")
assert(review.submit.event == "COMMENT", "3 ignored on own PR")
assert(#infos == 1 and infos[1]:find("own PR", 1, true) ~= nil, vim.inspect(infos))

errors = {}
local calls_before_blocked = submit_calls
press_key("<C-s>")
assert(#errors == 1 and errors[1] == "1 comment is still sending", vim.inspect(errors))
assert(submit_calls == calls_before_blocked, "blocked <C-s> sends no RPC")

errors = {}
vim.api.nvim_win_set_cursor(review.submit.win, { 1, 0 })
press_key("<CR>")
assert(#errors == 1 and errors[1] == "1 comment is still sending", vim.inspect(errors))
assert(submit_calls == calls_before_blocked, "blocked non-draft <CR> sends no RPC")
submit_view.close(review)

-- 8c. Zero drafts + COMMENT + whitespace-only body refuses with jpr.error.
mock_preview = preview_own_empty
session.submit_current()
assert(vim.wait(3000, function()
    return review.submit ~= nil
end), "empty own-PR modal opens")
press_key("e")
vim.api.nvim_buf_set_lines(review.submit.editor.buf, 0, -1, false, { "   ", "\t" })
press_key("<C-s>")
errors = {}
local calls_before_empty = submit_calls
press_key("<C-s>")
assert(#errors == 1 and errors[1]:find("summary body", 1, true) ~= nil, vim.inspect(errors))
assert(submit_calls == calls_before_empty, "empty COMMENT review sends no RPC")
submit_view.close(review)

-- 8d. PR-level draft (<CR> when anchor.file == nil) calls conversation.show(session).
local conv_module = require("jpr.views.conversation")
local orig_conv_show = conv_module.show
local conv_shown = 0
conv_module.show = function(sess)
    if sess == review then
        conv_shown = conv_shown + 1
    end
end
mock_preview = {
    draftCount = 1,
    drafts = { { threadId = "T_PR", messageId = "M_PR", anchor = { kind = "pr", side = "RIGHT" }, snippet = "overall" } },
    canApproveOrRequestChanges = true,
    blockedReason = nil,
}
session.submit_current()
assert(vim.wait(3000, function()
    return review.submit ~= nil
end), "PR-draft modal opens")
local pr_row = next(review.submit.rendered.draft_anchors)
vim.api.nvim_win_set_cursor(review.submit.win, { pr_row, 0 })
press_key("<CR>")
conv_module.show = orig_conv_show
assert(review.submit == nil and conv_shown == 1, "PR-draft <CR> opens conversation")

-- 8e. submitReview failure keeps modal open + preserves summary text + allows retry; success closes cleanly.
mock_preview = {
    draftCount = 1,
    drafts = {
        { threadId = "T1", messageId = "M1", anchor = { file = "README.md", kind = "line", start = 2, ["end"] = 2 }, snippet = "nit" },
    },
    canApproveOrRequestChanges = true,
    blockedReason = nil,
}
session.submit_current()
assert(vim.wait(3000, function()
    return review.submit ~= nil
end), "modal opens for error+retry test")
press_key("2")
press_key("e")
vim.api.nvim_buf_set_lines(review.submit.editor.buf, 0, -1, false, { "Ship it!" })
press_key("<C-s>")

mock_submit_error = { code = -32000, message = "GitHub rejected submit" }
errors = {}
press_key("<C-s>")
assert(vim.wait(3000, function()
    return #errors == 1
end), "submitReview error reported")
assert(errors[1]:find("GitHub rejected submit", 1, true) ~= nil, vim.inspect(errors))
assert(review.submit ~= nil and vim.api.nvim_win_is_valid(review.submit.win), "modal stays open after submitReview error")
assert(review.submit.in_flight == false, "in_flight resets after error")
assert(vim.deep_equal(review.submit.body_lines, { "Ship it!" }), "summary body preserved after error")

-- Retry on the same modal succeeds with the real engine, sending APPROVE + "Ship it!".
mock_submit_error = nil
review.client.request = orig_request
local real_submits_before = #read_requests("submitReview")
press_key("<C-s>")
assert(vim.wait(3000, function()
    return review.submit == nil and #read_requests("submitReview") == real_submits_before + 1
end), "retry submitReview succeeds and closes modal")
local sent_submit = read_requests("submitReview")[real_submits_before + 1].params
assert(sent_submit.event == "APPROVE" and sent_submit.body == "Ship it!", vim.inspect(sent_submit))

-- 8f. in_flight guard ignores duplicate <C-s>, and non-draft <CR> submits when allowed.
review.client.request = function(client_self, method, params, cb)
    if method == "submitPreview" then
        vim.schedule(function()
            cb(nil, vim.deepcopy(mock_preview))
        end)
        return
    elseif method == "submitReview" then
        submit_calls = submit_calls + 1
        if hold_submit_cb == true then
            hold_submit_cb = cb
            return
        end
    end
    return orig_request(client_self, method, params, cb)
end
session.submit_current()
assert(vim.wait(3000, function()
    return review.submit ~= nil
end), "modal opens for in_flight guard test")
hold_submit_cb = true
local calls_before_inflight = submit_calls
vim.api.nvim_win_set_cursor(review.submit.win, { 1, 0 })
press_key("<CR>")
press_key("<C-s>")
assert(submit_calls == calls_before_inflight + 1, "in_flight guard suppresses duplicate submitReview")
assert(review.submit.in_flight == true, "in_flight is true while request is pending")
hold_submit_cb(nil, review.view)
assert(review.submit == nil, "completing pending submitReview closes modal")
hold_submit_cb = nil
review.client.request = orig_request

jpr.error = orig_error
jpr.info = orig_info
session.close_current()

print("submit_spec: ok")
