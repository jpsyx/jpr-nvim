local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local view_mode = require("jpr.view_mode")
local submit_view = require("jpr.views.submit")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new", "line three", "line four", "line five" }, worktree .. "/README.md")

local function find_submit_win()
    return helpers.find_floating_win("Submit Review")
end

local function find_summary_editor_win()
    return helpers.find_floating_win("Review Summary")
end

local function find_submit_confirm_win()
    return helpers.find_floating_win("Confirm GitHub Review Submission")
end

local function win_lines(win)
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

-- 1. session.submit_current() without open session errors via jpr.error.
local errors, infos = {}, {}
local original_error, original_info = jpr.error, jpr.info
jpr.error = function(message)
    errors[#errors + 1] = message
end
jpr.info = function(message)
    infos[#infos + 1] = message
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

-- 2. Opening :Jpr submit requests submitPreview and opens a centered rounded floating nofile/markdown window.
local previews_before = #helpers.read_requests(log, "submitPreview")
session.submit_current()
assert(vim.wait(3000, function()
    return find_submit_win() ~= nil
end), "submit modal opens")
assert(#helpers.read_requests(log, "submitPreview") == previews_before + 1, "submitPreview RPC sent")

local modal_win = find_submit_win()
local modal_buf = vim.api.nvim_win_get_buf(modal_win)
local modal_config = vim.api.nvim_win_get_config(modal_win)
assert(modal_config.relative == "editor", "submit modal is floating")
assert(
    vim.deep_equal(modal_config.border, { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }),
    "submit modal has rounded border: " .. vim.inspect(modal_config.border)
)
assert(vim.bo[modal_buf].buftype == "nofile", "submit modal buftype is nofile")
assert(vim.bo[modal_buf].filetype == "markdown", "submit modal filetype is markdown")
assert(vim.bo[modal_buf].modifiable == false, "submit modal is read-only")

-- 3. Selecting 1/2/3 updates the rendered radio selection when allowed.
helpers.press_key("2")
assert(helpers.find_line_number(win_lines(modal_win), "  [x] 2. Approve") ~= nil, "2 selects APPROVE")
helpers.press_key("3")
assert(helpers.find_line_number(win_lines(modal_win), "  [x] 3. Request changes") ~= nil, "3 selects REQUEST_CHANGES")
helpers.press_key("1")
assert(helpers.find_line_number(win_lines(modal_win), "  [x] 1. Comment") ~= nil, "1 selects COMMENT")

-- 4. Pressing e opens summary editor, q/<Esc> cancels without overwriting, <C-s> saves (including empty clear).
helpers.press_key("e")
local editor_win = find_summary_editor_win()
assert(editor_win ~= nil and vim.api.nvim_win_is_valid(editor_win), "summary editor opened")
local editor_buf = vim.api.nvim_win_get_buf(editor_win)
assert(vim.bo[editor_buf].buftype == "nofile", "editor buftype is nofile")
assert(vim.bo[editor_buf].filetype == "markdown", "editor filetype is markdown")
vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { "Looks solid", "Nice tests" })
helpers.press_key("<C-s>")
assert(not vim.api.nvim_win_is_valid(editor_win), "<C-s> closes summary editor")
assert(vim.api.nvim_get_current_win() == modal_win, "focus returned to submit modal")
assert(helpers.find_line_number(win_lines(modal_win), "  Looks solid") ~= nil, "summary line 1 rendered")
assert(helpers.find_line_number(win_lines(modal_win), "  Nice tests") ~= nil, "summary line 2 rendered")

-- Cancel via q and <Esc> preserves rendered summary lines.
helpers.press_key("e")
local cancel_q_win = find_summary_editor_win()
vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(cancel_q_win), 0, -1, false, { "Discarded text" })
helpers.press_key("q")
assert(not vim.api.nvim_win_is_valid(cancel_q_win) and vim.api.nvim_get_current_win() == modal_win, "q closes editor and restores focus")
assert(helpers.find_line_number(win_lines(modal_win), "  Looks solid") ~= nil, "q preserves prior summary")
assert(helpers.find_line_number(win_lines(modal_win), "Discarded text") == nil, "q discards unsaved text")

helpers.press_key("e")
local cancel_esc_win = find_summary_editor_win()
vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(cancel_esc_win), 0, -1, false, { "Also discarded" })
helpers.press_key("<Esc>")
assert(not vim.api.nvim_win_is_valid(cancel_esc_win), "<Esc> closes editor")
assert(helpers.find_line_number(win_lines(modal_win), "  Looks solid") ~= nil, "<Esc> preserves prior summary")

-- Clearing summary and saving with <C-s> restores empty placeholder line.
helpers.press_key("e")
vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(find_summary_editor_win()), 0, -1, false, { "" })
helpers.press_key("<C-s>")
assert(helpers.find_line_number(win_lines(modal_win), "  (optional for Approve / Drafts; required for empty Comment)") ~= nil)

-- 5. <CR> on a draft row jumps to file:line via main_window.edit and closes submit modal without calling submitReview.
local draft_row = helpers.find_line_number(win_lines(modal_win), "README.md:2:")
assert(draft_row ~= nil, "draft row rendered in modal")
local submits_before_jump = #helpers.read_requests(log, "submitReview")
vim.api.nvim_win_set_cursor(modal_win, { draft_row, 0 })
helpers.press_key("<CR>")
assert(not vim.api.nvim_win_is_valid(modal_win), "<CR> on draft row closes submit modal")
assert(#helpers.read_requests(log, "submitReview") == submits_before_jump, "<CR> on draft row does not call submitReview")
local main_win = main_window.find(review)
assert(vim.api.nvim_get_current_win() == main_win, "focus moved to main_window")
assert(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(main_win)):sub(-9) == "README.md", "opened draft file")
assert(vim.api.nvim_win_get_cursor(main_win)[1] == 2, "cursor placed at anchor line 2")

-- 6. Closing via q, <Esc>, M.close, and BufWipeout closes modal and any open summary sub-editor.
session.submit_current()
assert(vim.wait(3000, function() return find_submit_win() ~= nil end), "reopened submit modal")
local q_modal_win = find_submit_win()
helpers.press_key("q")
assert(not vim.api.nvim_win_is_valid(q_modal_win), "q closes submit modal")

session.submit_current()
assert(vim.wait(3000, function() return find_submit_win() ~= nil end), "reopened submit modal for Esc")
local esc_modal_win = find_submit_win()
helpers.press_key("<Esc>")
assert(not vim.api.nvim_win_is_valid(esc_modal_win), "<Esc> closes submit modal")

session.submit_current()
assert(vim.wait(3000, function() return find_submit_win() ~= nil end), "reopened submit modal with sub-editor")
local parent_modal_win = find_submit_win()
local parent_modal_buf = vim.api.nvim_win_get_buf(parent_modal_win)
helpers.press_key("e")
local sub_editor_buf = vim.api.nvim_win_get_buf(find_summary_editor_win())
submit_view.close(review)
assert(not vim.api.nvim_win_is_valid(parent_modal_win), "M.close closes modal window")
assert(not vim.api.nvim_buf_is_valid(parent_modal_buf), "M.close wipes modal buffer")
assert(not vim.api.nvim_buf_is_valid(sub_editor_buf), "M.close wipes open summary sub-editor")

session.submit_current()
assert(vim.wait(3000, function() return find_submit_win() ~= nil end), "reopened submit modal for BufWipeout")
local wipe_modal_win = find_submit_win()
helpers.press_key("e")
local wipe_sub_buf = vim.api.nvim_win_get_buf(find_summary_editor_win())
vim.api.nvim_win_close(wipe_modal_win, true)
assert(not vim.api.nvim_buf_is_valid(wipe_sub_buf), "BufWipeout on modal closes sub-editor")

-- 7. Custom preview scenarios: blockedReason, own PR restrictions, empty zero-draft COMMENT, PR-draft jump, submitReview error + retry.
local preview_own_empty = {
    draftCount = 0,
    drafts = {},
    canApproveOrRequestChanges = false,
    blockedReason = nil,
}
local original_request = review.client.request
local mock_preview
local mock_submit_error
local hold_preview_callback
local hold_submit_callback
local submit_calls = 0

review.client.request = function(client_self, method, params, callback)
    if method == "submitPreview" then
        if hold_preview_callback == true then
            hold_preview_callback = callback
            return
        end
        local preview_copy = vim.deepcopy(mock_preview)
        vim.schedule(function()
            callback(nil, preview_copy)
        end)
        return
    elseif method == "submitReview" then
        submit_calls = submit_calls + 1
        if hold_submit_callback == true then
            hold_submit_callback = callback
            return
        end
        if mock_submit_error then
            local err = mock_submit_error
            vim.schedule(function()
                callback(err, nil)
            end)
            return
        end
    end
    return original_request(client_self, method, params, callback)
end

-- 7a. Stale submitPreview callback guard after close.
hold_preview_callback = true
submit_view.open(review)
local stale_callback = hold_preview_callback
assert(type(stale_callback) == "function", "captured first submitPreview callback")
submit_view.close(review)
stale_callback(nil, preview_own_empty)
assert(find_submit_win() == nil, "stale submitPreview callback after close does not open modal")
hold_preview_callback = nil

-- 7b. Blocked reason refuses <C-s> and non-draft <CR> with jpr.error(preview.blockedReason).
mock_preview = {
    draftCount = 1,
    drafts = {
        { threadId = "T1", messageId = "M1", anchor = { file = "README.md", kind = "line", start = 1, ["end"] = 1 }, snippet = "hi" },
    },
    canApproveOrRequestChanges = false,
    blockedReason = "1 comment is still sending",
}
session.submit_current()
assert(vim.wait(3000, function() return find_submit_win() ~= nil end), "blocked modal opens")
local blocked_win = find_submit_win()

-- Own PR refuses 2 and 3 with jpr.info while keeping [x] 1. Comment selected.
infos = {}
helpers.press_key("2")
assert(helpers.find_line_number(win_lines(blocked_win), "  [x] 1. Comment") ~= nil, "2 ignored on own PR")
assert(#infos == 1 and infos[1]:find("own PR", 1, true) ~= nil, vim.inspect(infos))
infos = {}
helpers.press_key("3")
assert(helpers.find_line_number(win_lines(blocked_win), "  [x] 1. Comment") ~= nil, "3 ignored on own PR")
assert(#infos == 1 and infos[1]:find("own PR", 1, true) ~= nil, vim.inspect(infos))

errors = {}
local calls_before_blocked = submit_calls
helpers.press_key("<C-s>")
assert(#errors == 1 and errors[1] == "1 comment is still sending", vim.inspect(errors))
assert(submit_calls == calls_before_blocked, "blocked <C-s> sends no RPC")

errors = {}
vim.api.nvim_win_set_cursor(blocked_win, { 1, 0 })
helpers.press_key("<CR>")
assert(#errors == 1 and errors[1] == "1 comment is still sending", vim.inspect(errors))
assert(submit_calls == calls_before_blocked, "blocked non-draft <CR> sends no RPC")
submit_view.close(review)

-- 7c. Zero drafts + COMMENT + whitespace-only body refuses with jpr.error.
mock_preview = preview_own_empty
session.submit_current()
assert(vim.wait(3000, function() return find_submit_win() ~= nil end), "empty own-PR modal opens")
helpers.press_key("e")
vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(find_summary_editor_win()), 0, -1, false, { "   ", "\t" })
helpers.press_key("<C-s>")
errors = {}
local calls_before_empty = submit_calls
helpers.press_key("<C-s>")
assert(#errors == 1 and errors[1]:find("summary body", 1, true) ~= nil, vim.inspect(errors))
assert(submit_calls == calls_before_empty, "empty COMMENT review sends no RPC")
submit_view.close(review)

-- 7d. PR-level draft (<CR> when anchor.file == nil) opens jpr://conversation/7 in main_window.
mock_preview = {
    draftCount = 1,
    drafts = { { threadId = "T_PR", messageId = "M_PR", anchor = { kind = "pr", side = "RIGHT" }, snippet = "overall" } },
    canApproveOrRequestChanges = true,
    blockedReason = nil,
}
session.submit_current()
assert(vim.wait(3000, function() return find_submit_win() ~= nil end), "PR-draft modal opens")
local pr_modal_win = find_submit_win()
local pr_row = helpers.find_line_number(win_lines(pr_modal_win), "PR: overall")
vim.api.nvim_win_set_cursor(pr_modal_win, { pr_row, 0 })
helpers.press_key("<CR>")
assert(not vim.api.nvim_win_is_valid(pr_modal_win), "PR-draft <CR> closes modal")
local conversation_buf = vim.api.nvim_win_get_buf(main_window.find(review))
assert(vim.api.nvim_buf_get_name(conversation_buf) == "jpr://conversation/7", vim.api.nvim_buf_get_name(conversation_buf))

-- 7e. submitReview failure keeps modal open + preserves summary text + allows retry; success closes cleanly.
mock_preview = {
    draftCount = 1,
    drafts = {
        { threadId = "T1", messageId = "M1", anchor = { file = "README.md", kind = "line", start = 2, ["end"] = 2 }, snippet = "nit" },
    },
    canApproveOrRequestChanges = true,
    blockedReason = nil,
}
session.submit_current()
assert(vim.wait(3000, function() return find_submit_win() ~= nil end), "modal opens for error+retry test")
local retry_modal_win = find_submit_win()
helpers.press_key("2")
helpers.press_key("e")
vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(find_summary_editor_win()), 0, -1, false, { "Ship it!" })
helpers.press_key("<C-s>")

mock_submit_error = { code = -32000, message = "GitHub rejected submit" }
errors = {}
helpers.press_key("<C-s>")
local confirm_win = find_submit_confirm_win()
assert(confirm_win ~= nil and vim.api.nvim_win_is_valid(confirm_win), "<C-s> opens GitHub submit confirmation modal")
local confirm_text = table.concat(win_lines(confirm_win), "\n")
assert(
    confirm_text:find("Submit Approve review with 1 draft comment and a summary to GitHub?", 1, true) ~= nil,
    "confirmation names exact action, draft count, and summary: " .. confirm_text
)
assert(submit_calls == calls_before_empty, "opening confirmation sends no submitReview RPC yet")

-- Canceling confirmation via q returns focus to Submit Review with state preserved.
helpers.press_key("q")
assert(find_submit_confirm_win() == nil, "q closes submit confirmation modal")
assert(vim.api.nvim_get_current_win() == retry_modal_win, "canceling confirmation restores focus to Submit Review")
assert(helpers.find_line_number(win_lines(retry_modal_win), "  Ship it!") ~= nil, "summary preserved after cancel")
assert(submit_calls == calls_before_empty, "canceled confirmation sends no submitReview RPC")

-- Confirming via <C-s> then <CR> triggers submitReview; failure keeps Submit Review open for retry.
helpers.press_key("<C-s>")
assert(find_submit_confirm_win() ~= nil, "reopened submit confirmation modal")
helpers.press_key("<CR>")
assert(vim.wait(3000, function() return #errors == 1 end), "submitReview error reported")
assert(errors[1]:find("GitHub rejected submit", 1, true) ~= nil, vim.inspect(errors))
assert(vim.api.nvim_win_is_valid(retry_modal_win), "modal stays open after submitReview error")
assert(helpers.find_line_number(win_lines(retry_modal_win), "  Ship it!") ~= nil, "summary body preserved after error")

mock_submit_error = nil
review.client.request = original_request
local real_submits_before = #helpers.read_requests(log, "submitReview")
helpers.press_key("<C-s>")
assert(find_submit_confirm_win() ~= nil, "retry opens submit confirmation modal")
helpers.press_key("<CR>")
assert(vim.wait(3000, function()
    return not vim.api.nvim_win_is_valid(retry_modal_win) and #helpers.read_requests(log, "submitReview") == real_submits_before + 1
end), "retry submitReview succeeds and closes modal")
local sent_submit = helpers.read_requests(log, "submitReview")[real_submits_before + 1].params
assert(sent_submit.event == "APPROVE" and sent_submit.body == "Ship it!", vim.inspect(sent_submit))

-- 7f. Closing Submit Review while confirmation is open closes both modals without calling submitReview.
session.submit_current()
assert(vim.wait(3000, function() return find_submit_win() ~= nil end), "modal opens for close-with-confirm test")
local close_confirm_modal_win = find_submit_win()
local submits_before_close = #helpers.read_requests(log, "submitReview")
helpers.press_key("<C-s>")
assert(find_submit_confirm_win() ~= nil, "confirmation open before M.close")
-- Attempting to mutate action (2=APPROVE) or open summary editor (e) while confirmation is open is blocked.
vim.api.nvim_set_current_win(close_confirm_modal_win)
helpers.press_key("2")
helpers.press_key("e")
assert(review.submit.event == "COMMENT", "cannot mutate review event while confirmation is open")
assert(review.submit.editor == nil, "cannot open summary editor while confirmation is open")
submit_view.close(review)
assert(not vim.api.nvim_win_is_valid(close_confirm_modal_win), "M.close closes Submit Review")
assert(find_submit_confirm_win() == nil, "M.close also closes open confirmation modal")
assert(#helpers.read_requests(log, "submitReview") == submits_before_close, "M.close never triggers submitReview")

-- 7g. In-flight guard ignores duplicate <C-s> and editor `e` while pending, and closes on completion.
review.client.request = function(client_self, method, params, callback)
    if method == "submitPreview" then
        vim.schedule(function()
            callback(nil, vim.deepcopy(mock_preview))
        end)
        return
    elseif method == "submitReview" then
        submit_calls = submit_calls + 1
        if hold_submit_callback == true then
            hold_submit_callback = callback
            return
        end
    end
    return original_request(client_self, method, params, callback)
end
session.submit_current()
assert(vim.wait(3000, function() return find_submit_win() ~= nil end), "modal opens for in-flight guard test")
local inflight_modal_win = find_submit_win()
hold_submit_callback = true
local calls_before_inflight = submit_calls
vim.api.nvim_win_set_cursor(inflight_modal_win, { 1, 0 })
helpers.press_key("<CR>")
assert(find_submit_confirm_win() ~= nil, "non-draft <CR> opens confirmation modal")
helpers.press_key("<CR>")
helpers.press_key("<C-s>")
helpers.press_key("e")
assert(submit_calls == calls_before_inflight + 1, "in-flight guard suppresses duplicate submitReview")
assert(find_summary_editor_win() == nil, "in-flight guard suppresses summary editor while submitting")
hold_submit_callback(nil, review.view)
assert(not vim.api.nvim_win_is_valid(inflight_modal_win), "completing pending submitReview closes modal")
hold_submit_callback = nil
review.client.request = original_request

-- 8. Mouse click support in Submit Review modal (events, restricted events, summary, drafts, footer, outside close).
local original_getmousepos = vim.fn.getmousepos
local is_submit_mouse_ok, submit_mouse_error = pcall(function()
    session.submit_current()
    assert(vim.wait(3000, function() return find_submit_win() ~= nil end), "modal opens for mouse test")
    local submit_modal_win = find_submit_win()
    local lines = win_lines(submit_modal_win)

    -- Click Approve row selects APPROVE.
    local approve_line = helpers.find_line_number(lines, "  [ ] 2. Approve")
    assert(approve_line ~= nil, "found Approve line")
    vim.fn.getmousepos = function() return { winid = submit_modal_win, line = approve_line, column = 5 } end
    helpers.press_key("<LeftMouse>")
    assert(helpers.find_line_number(win_lines(submit_modal_win), "  [x] 2. Approve") ~= nil, "clicking Approve selects APPROVE")

    -- Click Summary Body opens summary editor; cancel editor to return to modal.
    local summary_line = helpers.find_line_number(win_lines(submit_modal_win), "Summary Body")
    assert(summary_line ~= nil, "found Summary Body line")
    vim.fn.getmousepos = function() return { winid = submit_modal_win, line = summary_line, column = 4 } end
    helpers.press_key("<LeftMouse>")
    assert(find_summary_editor_win() ~= nil, "clicking Summary Body opens summary editor")
    helpers.press_key("q")
    assert(find_summary_editor_win() == nil and vim.api.nvim_get_current_win() == submit_modal_win, "editor closed back to modal")

    -- Click [<C-s>] submit in footer opens confirmation modal; cancel confirmation.
    lines = win_lines(submit_modal_win)
    local submit_col = lines[#lines]:find("[<C-s>] submit", 1, true)
    assert(submit_col ~= nil, "found [<C-s>] submit footer token")
    vim.fn.getmousepos = function() return { winid = submit_modal_win, line = #lines, column = submit_col + 2 } end
    helpers.press_key("<LeftMouse>")
    assert(find_submit_confirm_win() ~= nil, "clicking [<C-s>] submit opens confirmation dialog")
    helpers.press_key("q")
    assert(find_submit_confirm_win() == nil and vim.api.nvim_get_current_win() == submit_modal_win, "confirm closed back to modal")

    -- Click pending draft row jumps to file:line and closes modal.
    local draft_line = helpers.find_line_number(win_lines(submit_modal_win), "README.md:2:")
    assert(draft_line ~= nil, "found draft row")
    vim.fn.getmousepos = function() return { winid = submit_modal_win, line = draft_line, column = 6 } end
    helpers.press_key("<LeftMouse>")
    assert(not vim.api.nvim_win_is_valid(submit_modal_win), "clicking draft row closes submit modal")
    assert(vim.api.nvim_buf_get_name(0):sub(-9) == "README.md", "clicking draft row opens draft file")

    -- Clicking restricted Approve on own PR keeps COMMENT selected and notifies.
    review.client.request = function(client_self, method, params, callback)
        if method == "submitPreview" then
            vim.schedule(function()
                callback(nil, { draftCount = 0, drafts = {}, canApproveOrRequestChanges = false })
            end)
            return
        end
        return original_request(client_self, method, params, callback)
    end
    infos = {}
    session.submit_current()
    assert(vim.wait(3000, function() return find_submit_win() ~= nil end), "own-PR modal opens")
    local own_win = find_submit_win()
    local own_approve_line = helpers.find_line_number(win_lines(own_win), "2. Approve")
    vim.fn.getmousepos = function() return { winid = own_win, line = own_approve_line, column = 5 } end
    helpers.press_key("<LeftMouse>")
    assert(helpers.find_line_number(win_lines(own_win), "  [x] 1. Comment") ~= nil, "own-PR click keeps COMMENT selected")
    assert(#infos >= 1 and infos[#infos]:find("own PR", 1, true) ~= nil, "own-PR click emits info notice")

    -- Clicking [q] cancel in footer closes modal.
    local own_lines = win_lines(own_win)
    local cancel_col = own_lines[#own_lines]:find("[q] cancel", 1, true)
    vim.fn.getmousepos = function() return { winid = own_win, line = #own_lines, column = cancel_col + 1 } end
    helpers.press_key("<LeftMouse>")
    assert(not vim.api.nvim_win_is_valid(own_win), "clicking [q] cancel closes modal")

    -- Clicking outside modal closes it.
    session.submit_current()
    assert(vim.wait(3000, function() return find_submit_win() ~= nil end), "modal opens for outside-click close")
    local outside_modal_win = find_submit_win()
    vim.fn.getmousepos = function() return { winid = 999999, line = 1, column = 1 } end
    helpers.press_key("<LeftMouse>")
    assert(not vim.api.nvim_win_is_valid(outside_modal_win), "clicking outside submit modal closes it")
end)
vim.fn.getmousepos = original_getmousepos
review.client.request = original_request
assert(is_submit_mouse_ok, tostring(submit_mouse_error))

jpr.error = original_error
jpr.info = original_info
session.close_current()

print("submit_view_spec: ok")
