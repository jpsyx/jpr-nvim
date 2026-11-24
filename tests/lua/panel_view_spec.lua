-- The panel window: its look stays its own, `<CR>` opens files only through
-- main_window, and `v` toggles viewed.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local session = require("jpr.session")
local panel_view = require("jpr.views.panel")
local stream_view = require("jpr.views.stream")
local view_mode = require("jpr.view_mode")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })
local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")

local PANEL_OPTIONS = { "number", "relativenumber", "signcolumn", "winfixwidth", "cursorline", "wrap" }
local globals_before = {}
for _, name in ipairs(PANEL_OPTIONS) do
    globals_before[name] = vim.api.nvim_get_option_value(name, { scope = "global" })
end

session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.stream ~= nil and review.stream.layout ~= nil and stream_view.is_visible(review)
end), "the review syncs and its stream opens")

--- Runs the panel's own mapping for `lhs`, with the cursor on `line`.
local function press(lhs, line)
    vim.api.nvim_set_current_win(review.panel.win)
    vim.api.nvim_win_set_cursor(review.panel.win, { line, 0 })
    vim.fn.maparg(lhs, "n", false, true).callback()
end

-- The panel's look is local to its window: the global values are untouched.
local panel_win = review.panel.win
assert(not vim.wo[panel_win].wrap and vim.wo[panel_win].cursorline and vim.wo[panel_win].winfixwidth, "the panel's look")
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
press("<CR>", 7)
local file_win = vim.api.nvim_get_current_win()
assert(file_win ~= panel_win, "the file opens beside the panel")
assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/README.md"), "<CR> opens README.md")
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
press("o", 7)
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
for _, line in ipairs({ 7, 8 }) do
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
local function find_sent_requests(needle)
    return vim.tbl_filter(function(line)
        return line:find('"method":"setViewed"', 1, true) ~= nil and line:find(needle, 1, true) ~= nil
    end, vim.fn.readfile(log))
end
press("v", 7)
assert(vim.wait(3000, function()
    return review.view.viewedCount == 1
end), "the engine's viewedChanged reaches the view")
assert(#find_sent_requests('"viewed":true') == 1 and #find_sent_requests('"path":"README.md"') == 1, vim.inspect(vim.fn.readfile(log)))
press("v", 7)
assert(vim.wait(3000, function()
    return #find_sent_requests('"viewed":false') == 1
end), "v on a viewed file unmarks it")
press("v", 1)
vim.wait(200)
assert(#find_sent_requests("setViewed") == 2, "v on a line with no file sends nothing")

-- <CR> on the Conversation row opens the PR conversation buffer in the main window instead of a file.
press("<CR>", 6)
local conversation_win = vim.api.nvim_get_current_win()
assert(conversation_win ~= panel_win, "<CR> on line 6 focuses the main window beside the panel")
local conversation_buf = vim.api.nvim_win_get_buf(conversation_win)
assert(vim.api.nvim_buf_get_name(conversation_buf) == "jpr://conversation/7", "<CR> on line 6 opens jpr://conversation/7")
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n")
    return text:find("Overall looks clean!", 1, true) ~= nil
end), "conversation buffer renders PR comments")
require("jpr.views.conversation").close(review)

-- `o` on the Conversation row also opens the PR conversation buffer identically to <CR>.
press("o", 6)
local conversation_win_from_o = vim.api.nvim_get_current_win()
assert(conversation_win_from_o ~= panel_win, "o on line 6 focuses the main window beside the panel")
local conversation_buf_from_o = vim.api.nvim_win_get_buf(conversation_win_from_o)
assert(vim.api.nvim_buf_get_name(conversation_buf_from_o) == "jpr://conversation/7", "o on line 6 opens jpr://conversation/7")
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
assert(#vim.api.nvim_tabpage_list_wins(review.tab) == 3, "the panel and the halves")
press("<CR>", 7)
assert(vim.api.nvim_get_current_win() == stream_win, "README.md opens in the main window")
assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/README.md"), "<CR> opens README.md")
assert(not vim.api.nvim_win_is_valid(left_win) or vim.api.nvim_win_get_buf(left_win) ~= vim.api.nvim_get_current_buf(), "not in the left half")
vim.wait(300)
assert(#vim.api.nvim_tabpage_list_wins(review.tab) <= 3, "no window was added: " .. #vim.api.nvim_tabpage_list_wins(review.tab))

session.close_current()
print("panel_view_spec: ok")
