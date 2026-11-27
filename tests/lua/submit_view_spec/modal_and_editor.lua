return function(context)
    local helpers = context.helpers
    local log = context.log
    local worktree = context.worktree
    local errors = context.errors
    local find_submit_win = context.find_submit_win
    local find_summary_editor_win = context.find_summary_editor_win
    local win_lines = context.win_lines
    local session = require("jpr.session")
    local main_window = require("jpr.views.main_window")
    local submit_view = require("jpr.views.submit")

session.submit_current()
assert(#errors == 1 and errors[1]:find("no pull request", 1, true) ~= nil, vim.inspect(errors))
while #errors > 0 do table.remove(errors) end

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


    context.review = review
end
