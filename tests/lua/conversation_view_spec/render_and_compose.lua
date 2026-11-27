return function(context)
    local helpers = context.helpers
    local log = context.log
    local worktree = context.worktree
    local errors = context.errors
    local find_tab_win_by_buf_name = context.find_tab_win_by_buf_name
    local session = require("jpr.session")
    local main_window = require("jpr.views.main_window")
    local view_mode = require("jpr.view_mode")
    local conversation = require("jpr.views.conversation")

-- 1. Without an active session, summary_current and conversation_current error cleanly.
session.summary_current()
assert(#errors == 1 and errors[1]:find("no pull request", 1, true), vim.inspect(errors))
while #errors > 0 do table.remove(errors) end
session.conversation_current()
assert(#errors == 1 and errors[1]:find("no pull request", 1, true), vim.inspect(errors))
while #errors > 0 do table.remove(errors) end

-- Start session and sync with fake_engine.sh.
session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "the review syncs")

-- 2. :Jpr conversation clears any diff split first and opens jpr://conversation/7 in main_window.
local win = main_window.find(review)
view_mode.set("split")
main_window.edit(review, win, "README.md", 1)
assert(vim.wait(3000, function()
    return find_tab_win_by_buf_name(review.tab, "jpr://base/7/README.md") ~= nil
end), "split diff opens base_win before conversation")
local base_win = find_tab_win_by_buf_name(review.tab, "jpr://base/7/README.md")

session.conversation_current()
assert(not vim.api.nvim_win_is_valid(base_win), "conversation closes diff base_win")

local conversation_buf = vim.api.nvim_win_get_buf(win)
assert(vim.api.nvim_buf_get_name(conversation_buf) == "jpr://conversation/7", vim.api.nvim_buf_get_name(conversation_buf))
assert(vim.bo[conversation_buf].buftype == "nofile", "conversation buftype is nofile")
assert(vim.bo[conversation_buf].filetype == "markdown", "conversation filetype is markdown")
assert(vim.bo[conversation_buf].modifiable == false, "conversation is read-only")

assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n")
    return text:find("Overall looks clean!", 1, true) ~= nil
end), "conversation loads PR comment")

local conversation_lines = vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false)
local conversation_text = table.concat(conversation_lines, "\n")
assert(conversation_text:find("#7 Fix the widget", 1, true) ~= nil, "summary title rendered: " .. conversation_text)
assert(conversation_text:find("@alice · fix/widget -> main", 1, true) ~= nil, "summary metadata rendered: " .. conversation_text)
assert(conversation_text:find("1 file changed · +2 -1 · 0/1 viewed", 1, true) ~= nil, "summary diffstat rendered: " .. conversation_text)
assert(conversation_text:find("Fixes widget crash.", 1, true) ~= nil, "PR body paragraph 1 rendered: " .. conversation_text)
assert(conversation_text:find("Includes regression test.", 1, true) ~= nil, "PR body paragraph 2 rendered: " .. conversation_text)
assert(conversation_text:find("\r", 1, true) == nil, "CRLF normalized out of PR body")
assert(conversation_text:find("@alice", 1, true) ~= nil, "author header rendered: " .. conversation_text)
assert(conversation_text:find("nit: rename this", 1, true) == nil, "code threads excluded: " .. conversation_text)
assert(conversation_text:find("|", 1, true) ~= nil, "conversation comments are boxed: " .. conversation_text)
assert(conversation_text:find("_", 1, true) ~= nil, "comment boxes use underscore rules: " .. conversation_text)
local comment_box_line = nil
for _, line in ipairs(conversation_lines) do
    if line:find("Overall looks clean!", 1, true) then
        comment_box_line = line
    end
end
assert(comment_box_line ~= nil and comment_box_line:find("|", 1, true) ~= nil, "comment body sits inside a box: " .. tostring(comment_box_line))

local conversation_start = review.conversation.layout.conversation_start_line
assert(type(conversation_start) == "number" and conversation_start > 1, "conversation_start_line is below summary: " .. tostring(conversation_start))
assert(conversation_lines[conversation_start]:find("Conversation (1 comments)", 1, true) ~= nil, tostring(conversation_lines[conversation_start]))
assert(vim.api.nvim_win_get_cursor(win)[1] == conversation_start, "conversation_current scrolls cursor to conversation_start_line")
local conv_topline = vim.api.nvim_win_call(win, function() return vim.fn.winsaveview().topline end)
assert(conv_topline <= conversation_start and conv_topline >= 1, "conversation_current sets valid topline")

-- 2b. :Jpr summary opens the same buffer scrolled to line 1; switching back jumps to conversation_start_line.
session.summary_current()
assert(vim.api.nvim_win_get_buf(win) == conversation_buf, "summary_current reuses the same buffer")
assert(vim.wait(3000, function()
    return vim.api.nvim_win_get_cursor(win)[1] == 1
end), "summary_current moves cursor to line 1")
local summary_topline = vim.api.nvim_win_call(win, function() return vim.fn.winsaveview().topline end)
assert(summary_topline == 1, "summary_current scrolls topline to 1: " .. tostring(summary_topline))

-- Pressing comment actions on a Diff summary line safely no-ops without errors.
local errors_before_summary_keys = #errors
helpers.press_key("e")
helpers.press_key("d")
helpers.press_key("r")
helpers.press_key("p")
helpers.press_key("s")
helpers.press_key("+")
assert(#errors == errors_before_summary_keys, "message actions on summary line do not error: " .. vim.inspect(errors))

-- Cached read-only mode still switches scroll target cleanly between conversation and summary.
review.is_read_only = true
session.conversation_current()
assert(vim.api.nvim_win_get_cursor(win)[1] == conversation_start, "read-only cached conversation_current jumps to conversation_start_line")
session.summary_current()
assert(vim.api.nvim_win_get_cursor(win)[1] == 1, "read-only cached summary_current jumps to line 1")
review.is_read_only = false

-- Background refresh preserves cursor position instead of resetting to line 1 or conversation_start_line.
vim.api.nvim_win_set_cursor(win, { 3, 0 })
conversation.refresh(review)
assert(vim.wait(3000, function()
    return vim.api.nvim_win_get_cursor(win)[1] == 3
end), "refresh preserves cursor line")

-- Blank PR body falls back to `(no PR description)`, and unlinked local mode shows local summary.
local saved_pr = review.view.pr
review.view.pr = vim.tbl_extend("force", vim.deepcopy(saved_pr), { body = "   \r\n  " })
conversation.refresh(review)
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n")
    return text:find("(no PR description)", 1, true) ~= nil
end), "blank PR body renders fallback hint")

review.mode = "local"
review.branch = "feat/local-x"
review.view.pr = nil
review.view.localContext = { branch = "feat/local-x", baseRef = "main" }
conversation.refresh(review)
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n")
    return text:find("LOCAL feat/local-x vs main", 1, true) ~= nil
        and text:find("run :Jpr sync once a PR is open", 1, true) ~= nil
        and text:find("Local Notes", 1, true) ~= nil
end), "unlinked local mode renders local diff summary and Local Notes")

review.mode = "pr"
review.branch = nil
review.view.pr = saved_pr
review.view.localContext = nil
conversation.refresh(review)
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n")
    return text:find("Fixes widget crash.", 1, true) ~= nil
end), "restored PR summary")

-- Opening conversation while split stream is active also closes stream's left window.
require("jpr.views.stream").show(review, { focus = true })
assert(vim.wait(3000, function()
    return find_tab_win_by_buf_name(review.tab, "jpr://stream/7/base") ~= nil
end), "split stream opens left_win")
local stream_left_win = find_tab_win_by_buf_name(review.tab, "jpr://stream/7/base")
session.conversation_current()
assert(not vim.api.nvim_win_is_valid(stream_left_win), "conversation closes stream left_win")
assert(vim.api.nvim_win_get_buf(main_window.find(review)) == conversation_buf, "reuses jpr://conversation/7")

-- 3. Pressing c opens real compose with PR Conversation title and <C-s> sends comment with PR anchor.
local comments_before = #helpers.read_requests(log, "comment")
vim.api.nvim_set_current_win(main_window.find(review))
helpers.press_key("c")
local pr_compose_win = helpers.find_floating_win("GitHub")
assert(pr_compose_win ~= nil and vim.api.nvim_win_is_valid(pr_compose_win), "real compose opens on c")
assert(helpers.win_title(pr_compose_win):find("PR Conversation", 1, true) ~= nil, helpers.win_title(pr_compose_win))
vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(pr_compose_win), 0, -1, false, { "Ship it!" })
helpers.press_key("<C-s>")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "comment") == comments_before + 1
end), "PR comment RPC sent")
local sent_pr_comment = helpers.read_requests(log, "comment")[comments_before + 1].params
assert(vim.deep_equal(sent_pr_comment.anchor, { kind = "pr", side = "RIGHT" }) and sent_pr_comment.body == "Ship it!", vim.inspect(sent_pr_comment))

-- gc in the diff summary / conversation buffer is the same standalone PR comment.
vim.api.nvim_set_current_win(main_window.find(review))
helpers.press_key("gc")
local gc_compose_win = helpers.find_floating_win("PR Conversation")
assert(gc_compose_win ~= nil and vim.api.nvim_win_is_valid(gc_compose_win), "gc opens a PR comment from the conversation buffer")
vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(gc_compose_win), 0, -1, false, { "From gc" })
helpers.press_key("<C-s>")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "comment") == comments_before + 2
end), "gc PR comment RPC sent")
local sent_gc_comment = helpers.read_requests(log, "comment")[comments_before + 2].params
assert(vim.deep_equal(sent_gc_comment.anchor, { kind = "pr", side = "RIGHT" }) and sent_gc_comment.body == "From gc", vim.inspect(sent_gc_comment))

-- 3b. Pressing c, flipping destination to [Local -> agent] with <C-g>, and saving with <C-s> sends origin = "local".
review.compose_destination = nil
vim.api.nvim_set_current_win(main_window.find(review))
helpers.press_key("c")
local pr_toggle_win = helpers.find_floating_win("PR Conversation")
assert(pr_toggle_win ~= nil and vim.api.nvim_win_is_valid(pr_toggle_win), "compose opens on c for toggle")
helpers.press_key("<C-g>")
assert(helpers.win_title(pr_toggle_win):find("[Local → agent] PR Conversation", 1, true) ~= nil, helpers.win_title(pr_toggle_win))
vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(pr_toggle_win), 0, -1, false, { "Local PR thought" })
helpers.press_key("<C-s>")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "comment") == comments_before + 3
end), "local PR comment RPC sent")
local sent_local_pr_comment = helpers.read_requests(log, "comment")[comments_before + 3].params
assert(
    vim.deep_equal(sent_local_pr_comment.anchor, { kind = "pr", side = "RIGHT" })
        and sent_local_pr_comment.body == "Local PR thought"
        and sent_local_pr_comment.origin == "local",
    vim.inspect(sent_local_pr_comment)
)
review.compose_destination = nil


    context.review = review
    context.conversation_buf = conversation_buf
end
