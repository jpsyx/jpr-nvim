return function(context)
    local jpr = require("jpr")
    local session = require("jpr.session")
    local panel_view = require("jpr.views.panel")
    local stream_view = require("jpr.views.stream")
    local review = context.review
    local worktree = context.worktree
    local log = context.log
    local press = context.press
    local PANEL_OPTIONS = context.PANEL_OPTIONS
    local globals_before = context.globals_before
    local find_sent_requests = context.find_sent_requests

-- The panel's look is local to its window: the global values are untouched.
local panel_win = review.panel.win
assert(not vim.wo[panel_win].wrap and vim.wo[panel_win].cursorline and vim.wo[panel_win].winfixwidth, "the panel's look")
vim.api.nvim_set_current_win(panel_win)
local panel_guicursor = vim.api.nvim_get_option_value("guicursor", {})
assert(panel_guicursor:find("JprPanelHiddenCursor", 1, true), "sidebar focus hides the cursor block: " .. panel_guicursor)
local panel_winhighlight = vim.api.nvim_get_option_value("winhighlight", { win = panel_win, scope = "local" })
assert(panel_winhighlight:find("CursorLine:JprPanelCursorLine", 1, true), "sidebar row uses the bright cursorline: " .. panel_winhighlight)
for _, name in ipairs(PANEL_OPTIONS) do
    local global = vim.api.nvim_get_option_value(name, { win = panel_win, scope = "global" })
    assert(global == globals_before[name], ("the panel set the global %s to %s"):format(name, vim.inspect(global)))
end

-- A main window split from the panel, and the file opened in it, do not get
-- the panel's look.
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(review.tab)) do
    if win ~= panel_win then
        vim.api.nvim_win_close(win, true)
    end
end
press("<CR>", 10)
local file_win = vim.api.nvim_get_current_win()
assert(file_win ~= panel_win, "the file opens beside the panel")
assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/README.md"), "<CR> opens README.md")
local file_guicursor = vim.api.nvim_get_option_value("guicursor", {})
assert(not file_guicursor:find("JprPanelHiddenCursor", 1, true), "leaving the sidebar restores the cursor: " .. file_guicursor)
for _, name in ipairs(PANEL_OPTIONS) do
    assert(vim.wo[file_win][name] == globals_before[name], ("the file has the panel's %s"):format(name))
end

-- `o` is mapped on the panel buffer and opens the file under the cursor just like <CR>.
vim.api.nvim_set_current_win(panel_win)
local o_keymap = vim.fn.maparg("o", "n", false, true)
assert(
    type(o_keymap) == "table" and type(o_keymap.callback) == "function",
    "o keymap is registered on the panel buffer"
)
assert(
    o_keymap.desc == "Open the conversation or file under the cursor",
    "o keymap has expected desc: " .. tostring(o_keymap.desc)
)
vim.api.nvim_win_close(file_win, true)
press("o", 10)
file_win = vim.api.nvim_get_current_win()
assert(file_win ~= panel_win, "o opens the file beside the panel")
assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/README.md"), "o opens README.md")

-- A tree row whose path is a symlink out of the worktree, or climbs out of
-- it with `..`, opens nothing and does not throw.
local errors = {}
local report_error = jpr.error
jpr.error = function(message)
    errors[#errors + 1] = message
end
local outside = vim.fn.tempname()
vim.fn.writefile({ "secret" }, outside)
vim.uv.fs_symlink(outside, worktree .. "/notes.md")
vim.fn.writefile({ "outside" }, worktree .. "/../x")
local function create_hostile_file(path)
    return { path = path, additions = 1, deletions = 0, viewed = "UNVIEWED", threads = 0 }
end
panel_view.render(review, {
    pr = review.view.pr,
    files = { create_hostile_file("notes.md"), create_hostile_file("../x") },
    tree = { { depth = 0, name = "notes.md", file = 0 }, { depth = 0, name = "../x", file = 1 } },
})
local buf_before = vim.api.nvim_win_get_buf(file_win)
for _, line in ipairs({ 10, 11 }) do
    errors = {}
    local pressed, press_err = pcall(press, "<CR>", line)
    assert(pressed, "line " .. line .. " threw: " .. tostring(press_err))
    assert(vim.api.nvim_win_get_buf(file_win) == buf_before, "line " .. line .. " opened a file")
    assert(vim.api.nvim_get_current_win() == panel_win, "line " .. line .. " left the panel")
    assert(#errors == 1 and errors[1]:find("not a plain file path inside the worktree", 1, true), vim.inspect(errors))
end
jpr.error = report_error
panel_view.render(review, review.view)

-- v marks the file under the cursor viewed, and unviewed again.

press("v", 10)
assert(vim.wait(3000, function()
    return review.view.viewedCount == 1
end), "the engine's viewedChanged reaches the view")
assert(#find_sent_requests('"viewed":true') == 1 and #find_sent_requests('"path":"README.md"') == 1, vim.inspect(vim.fn.readfile(log)))
press("v", 10)
assert(vim.wait(3000, function()
    return #find_sent_requests('"viewed":false') == 1
end), "v on a viewed file unmarks it")
press("v", 1)
press("v", 8)
vim.wait(200)
assert(#find_sent_requests("setViewed") == 2, "v on a header or Diff summary row sends nothing")

-- <CR> on the Diff summary row (line 8) opens the unified view scrolled to line 1.
press("<CR>", 8)
local summary_win = vim.api.nvim_get_current_win()
assert(summary_win ~= panel_win, "<CR> on Diff summary focuses the main window beside the panel")
local summary_buf = vim.api.nvim_win_get_buf(summary_win)
assert(vim.api.nvim_buf_get_name(summary_buf) == "jpr://conversation/7", "<CR> on Diff summary opens jpr://conversation/7")
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(summary_buf, 0, -1, false), "\n")
    return text:find("Fixes widget crash.", 1, true) ~= nil and vim.api.nvim_win_get_cursor(summary_win)[1] == 1
end), "summary row opens unified buffer at line 1")
require("jpr.views.conversation").close(review)

-- <CR> on the Conversation row (line 9) opens the unified view scrolled to the Conversation heading.
press("<CR>", 9)
local conversation_win = vim.api.nvim_get_current_win()
assert(conversation_win ~= panel_win, "<CR> on Conversation focuses the main window beside the panel")
local conversation_buf = vim.api.nvim_win_get_buf(conversation_win)
assert(vim.api.nvim_buf_get_name(conversation_buf) == "jpr://conversation/7", "<CR> on Conversation opens jpr://conversation/7")
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n")
    local start = review.conversation and review.conversation.layout and review.conversation.layout.conversation_start_line
    return text:find("Overall looks clean!", 1, true) ~= nil and start ~= nil and vim.api.nvim_win_get_cursor(conversation_win)[1] == start
end), "conversation buffer renders PR comments and scrolls to conversation start")
require("jpr.views.conversation").close(review)

-- `o` on the Conversation row also opens the PR conversation buffer identically to <CR>.
press("o", 9)
local conversation_win_from_o = vim.api.nvim_get_current_win()
assert(conversation_win_from_o ~= panel_win, "o on Conversation focuses the main window beside the panel")
local conversation_buf_from_o = vim.api.nvim_win_get_buf(conversation_win_from_o)
assert(vim.api.nvim_buf_get_name(conversation_buf_from_o) == "jpr://conversation/7", "o on Conversation opens jpr://conversation/7")
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf_from_o, 0, -1, false), "\n")
    return text:find("Overall looks clean!", 1, true) ~= nil
end), "o opens conversation buffer with PR comments")
require("jpr.views.conversation").close(review)

-- With the stream split, <CR> opens the file in the main window, not in the
-- stream's left half, and adds no window.
session.toggle_view()
session.stream_current()
assert(vim.wait(3000, function()
    local state = review.stream
    local left = state and state.left_win
    return left ~= nil and vim.api.nvim_win_is_valid(left) and #state.layout.columns == 2 and stream_view.is_visible(review)
end), "the stream is split")
local left_win = review.stream.left_win
local stream_win = vim.fn.win_findbuf(review.stream.buffers.main)[1]
require("jpr.notify").clear()
assert(#vim.api.nvim_tabpage_list_wins(review.tab) == 3, "the panel and the halves")
press("<CR>", 10)
assert(vim.api.nvim_get_current_win() == stream_win, "README.md opens in the main window")
assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/README.md"), "<CR> opens README.md")
assert(not vim.api.nvim_win_is_valid(left_win) or vim.api.nvim_win_get_buf(left_win) ~= vim.api.nvim_get_current_buf(), "not in the left half")
vim.wait(300)
assert(#vim.api.nvim_tabpage_list_wins(review.tab) <= 3, "no window was added: " .. #vim.api.nvim_tabpage_list_wins(review.tab))


    context.panel_win = panel_win
    context.stream_win = stream_win
end
