return function(context)
    local helpers = context.helpers
    local log = context.log
    local review = context.review
    local errors = context.errors
    local infos = context.infos
    local find_submit_win = context.find_submit_win
    local find_summary_editor_win = context.find_summary_editor_win
    local find_submit_confirm_win = context.find_submit_confirm_win
    local win_lines = context.win_lines
    local session = require("jpr.session")
    local main_window = require("jpr.views.main_window")
    local submit_view = require("jpr.views.submit")

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
while #infos > 0 do table.remove(infos) end
helpers.press_key("2")
assert(helpers.find_line_number(win_lines(blocked_win), "  [x] 1. Comment") ~= nil, "2 ignored on own PR")
assert(#infos == 1 and infos[1]:find("own PR", 1, true) ~= nil, vim.inspect(infos))
while #infos > 0 do table.remove(infos) end
helpers.press_key("3")
assert(helpers.find_line_number(win_lines(blocked_win), "  [x] 1. Comment") ~= nil, "3 ignored on own PR")
assert(#infos == 1 and infos[1]:find("own PR", 1, true) ~= nil, vim.inspect(infos))

while #errors > 0 do table.remove(errors) end
local calls_before_blocked = submit_calls
helpers.press_key("<C-s>")
assert(#errors == 1 and errors[1] == "1 comment is still sending", vim.inspect(errors))
assert(submit_calls == calls_before_blocked, "blocked <C-s> sends no RPC")

while #errors > 0 do table.remove(errors) end
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
while #errors > 0 do table.remove(errors) end
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
while #errors > 0 do table.remove(errors) end
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
    while #infos > 0 do table.remove(infos) end
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


end
