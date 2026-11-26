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
local set_viewed_payload = vim.fn.tempname()
local stream_payload = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
vim.env.FAKE_ENGINE_SET_VIEWED_FILE = set_viewed_payload
vim.env.FAKE_ENGINE_STREAM_FILE = stream_payload
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

-- Menu-style vertical-only navigation, cursor clamping, collapsible directories, and cursor preservation.
local function run_panel_key(lhs)
    vim.api.nvim_set_current_win(panel_win)
    local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    vim.api.nvim_feedkeys(keys, "xt", false)
end

local tree_view = {
    pr = review.view.pr,
    files = {
        { path = "README.md", additions = 2, deletions = 1, viewed = "UNVIEWED", threads = 1 },
        { path = "src/a.rs", additions = 3, deletions = 0, viewed = "UNVIEWED", threads = 0 },
        { path = "src/b.rs", additions = 1, deletions = 0, viewed = "UNVIEWED", threads = 0 },
    },
    tree = {
        { depth = 0, name = "src" },
        { depth = 1, name = "a.rs", file = 1 },
        { depth = 1, name = "b.rs", file = 2 },
        { depth = 0, name = "README.md", file = 0 },
    },
    viewedCount = 0,
    threadCount = 1,
    draftCount = 0,
    conversationCount = 1,
    sync = { state = "synced", at = 1 },
}
vim.fn.mkdir(worktree .. "/src", "p")
vim.fn.writefile({ "fn a() {}" }, worktree .. "/src/a.rs")
vim.fn.writefile({ "fn b() {}" }, worktree .. "/src/b.rs")
review.view = tree_view
panel_view.render(review, tree_view)

-- Cursor clamps to column 0 and snaps off header lines onto Conversation.
vim.api.nvim_set_current_win(panel_win)
vim.api.nvim_win_set_cursor(panel_win, { 1, 3 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = review.panel.buf })
local snapped_cursor = vim.api.nvim_win_get_cursor(panel_win)
assert(snapped_cursor[1] == 6 and snapped_cursor[2] == 0, "header snaps to Conversation col 0: " .. vim.inspect(snapped_cursor))
local row_info = panel_view.get_row_under_cursor(review)
assert(row_info and row_info.line == 6 and row_info.row.kind == "conversation", vim.inspect(row_info))

-- Horizontal keys (w, $, 0) are no-ops; j/k/gg/G move strictly across selectable_lines.
run_panel_key("w")
run_panel_key("$")
run_panel_key("0")
assert(vim.api.nvim_win_get_cursor(panel_win)[2] == 0, "horizontal keys stay at col 0")
assert(vim.wo[panel_win].sidescrolloff == 0, "sidescrolloff is 0 on panel window")

run_panel_key("j")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 7, "j moves to src/ dir")
run_panel_key("G")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 10, "G jumps to last selectable item")
run_panel_key("k")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 9, "k moves up to src/b.rs")
run_panel_key("gg")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 6, "gg jumps to Conversation")

-- h on child file jumps to parent_dir; h on expanded dir collapses it.
vim.api.nvim_win_set_cursor(panel_win, { 9, 0 })
run_panel_key("h")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 7, "h on child file jumps to parent src/ dir")
run_panel_key("h")
assert(review.panel.collapsed_dirs["src"] == true, "h on expanded dir collapses it")
assert(vim.api.nvim_buf_get_lines(review.panel.buf, 6, 7, false)[1] == "▸ src/ (2)", "collapsed src/ renders count")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 7, "cursor stays on collapsed dir")

-- o expands a collapsed dir, does nothing on an already-expanded dir.
run_panel_key("o")
assert(review.panel.collapsed_dirs["src"] == nil, "o expands collapsed dir")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 7, "cursor stays on expanded dir after o")
run_panel_key("o")
assert(review.panel.collapsed_dirs["src"] == nil, "o on already-expanded dir does nothing")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 7, "o on already-expanded dir does not move cursor")

-- <CR> toggles directories.
run_panel_key("<CR>")
assert(review.panel.collapsed_dirs["src"] == true, "<CR> collapses expanded dir")
run_panel_key("<CR>")
assert(review.panel.collapsed_dirs["src"] == nil, "<CR> expands collapsed dir")

-- l / <Right> expands a collapsed dir and steps into first child on an expanded dir,
-- but never opens a file or Conversation row (avoiding accidental opens).
run_panel_key("h")
assert(review.panel.collapsed_dirs["src"] == true, "re-collapsed src/")
run_panel_key("l")
assert(review.panel.collapsed_dirs["src"] == nil, "l expands collapsed dir")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 7, "l expanding dir keeps cursor on dir")
run_panel_key("l")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 8, "l on expanded dir steps into first child")
local main_buf_before_l = vim.api.nvim_win_get_buf(stream_win)
run_panel_key("l")
assert(vim.api.nvim_get_current_win() == panel_win, "l on file stays in panel window")
assert(vim.api.nvim_win_get_buf(stream_win) == main_buf_before_l, "l on file does not open it in main window")
run_panel_key("<Right>")
assert(vim.api.nvim_get_current_win() == panel_win, "<Right> on file stays in panel window")
assert(vim.api.nvim_win_get_buf(stream_win) == main_buf_before_l, "<Right> on file does not open it in main window")
vim.api.nvim_win_set_cursor(panel_win, { 6, 0 })
run_panel_key("l")
assert(vim.api.nvim_get_current_win() == panel_win, "l on Conversation row stays in panel window")

-- Cursor stays on the same file path across M.render redraws.
vim.api.nvim_set_current_win(panel_win)
vim.api.nvim_win_set_cursor(panel_win, { 9, 0 })
panel_view.render(review, tree_view)
local preserved = vim.api.nvim_win_get_cursor(panel_win)
assert(preserved[1] == 9 and preserved[2] == 0, "cursor stays on src/b.rs across redraw: " .. vim.inspect(preserved))

-- Pressing `v` on an expanded or collapsed directory sends a single batched
-- setViewed request with all descendant paths, and advances the main window
-- when it was showing a file just marked viewed.
local all_src_viewed = vim.deepcopy(tree_view)
all_src_viewed.files[2].viewed = "VIEWED"
all_src_viewed.files[3].viewed = "VIEWED"
all_src_viewed.viewedCount = 2
vim.fn.writefile({ vim.json.encode(all_src_viewed) }, set_viewed_payload)

-- Open src/a.rs in main window (hiding stream), then press v on src/ dir in panel.
press("<CR>", 8)
assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/src/a.rs"), "opened src/a.rs in main window")
local main_win_for_dir = vim.api.nvim_get_current_win()
local before_dir_requests = #find_sent_requests('"paths":')
press("v", 7)
assert(vim.wait(3000, function()
    return #find_sent_requests('"paths":') == before_dir_requests + 1
end), "v on expanded src/ dir sends batched setViewed paths")
local dir_req = find_sent_requests('"paths":')[before_dir_requests + 1]
assert(
    dir_req:find('"src/a.rs"', 1, true) ~= nil
        and dir_req:find('"src/b.rs"', 1, true) ~= nil
        and dir_req:find('"viewed":true', 1, true) ~= nil,
    "batched dir request includes all descendants with viewed=true: " .. tostring(dir_req)
)
assert(vim.wait(3000, function()
    return vim.fn.resolve(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(main_win_for_dir)))
        == vim.fn.resolve(worktree .. "/README.md")
end), "main window advances to next unviewed file README.md after src/ is marked viewed")
assert(vim.api.nvim_get_current_win() == panel_win, "sidebar keeps cursor focus when advancing main window")

-- Collapsing src/ and pressing v when all descendants are VIEWED unmarks all descendants.
run_panel_key("h")
assert(review.panel.collapsed_dirs["src"] == true, "collapsed src/")
vim.fn.writefile({ vim.json.encode(tree_view) }, set_viewed_payload)
press("v", 7)
assert(vim.wait(3000, function()
    return #find_sent_requests('"paths":') == before_dir_requests + 2 and review.view.viewedCount == 0
end), "v on collapsed src/ dir sends batched unmark request")
local unmark_req = find_sent_requests('"paths":')[before_dir_requests + 2]
assert(
    unmark_req:find('"src/a.rs"', 1, true) ~= nil
        and unmark_req:find('"src/b.rs"', 1, true) ~= nil
        and unmark_req:find('"viewed":false', 1, true) ~= nil,
    "collapsed dir unmark includes all descendants with viewed=false: " .. tostring(unmark_req)
)
-- Live full-diff repaint: with the full diff stream visible beside the panel,
-- marking a directory viewed collapses its files and unmarking expands them.
session.toggle_view()
session.stream_current()
assert(vim.wait(3000, function()
    return stream_view.is_visible(review)
end), "full diff stream is visible beside the panel")
local live_stream_win = vim.fn.win_findbuf(review.stream.buffers.main)[1]
local folded_dir_stream = {
    mode = "unified",
    rows = {
        { kind = "file", path = "src/a.rs", additions = 3, deletions = 0, viewed = "VIEWED", folded = true },
        { kind = "hunk", path = "src/a.rs", header = "@@ -0,0 +1,1 @@", target = 1 },
        { kind = "line", path = "src/a.rs", right = { line = 1, text = "fn a() {}", change = "added", words = {} }, target = 1 },
    },
}
local expanded_dir_stream = {
    mode = "unified",
    rows = {
        { kind = "file", path = "src/a.rs", additions = 3, deletions = 0, viewed = "UNVIEWED", folded = false },
        { kind = "hunk", path = "src/a.rs", header = "@@ -0,0 +1,1 @@", target = 1 },
        { kind = "line", path = "src/a.rs", right = { line = 1, text = "fn a() {}", change = "added", words = {} }, target = 1 },
    },
}
vim.fn.writefile({ vim.json.encode(all_src_viewed) }, set_viewed_payload)
vim.fn.writefile({ vim.json.encode(folded_dir_stream) }, stream_payload)
press("v", 7)
assert(vim.wait(3000, function()
    return vim.api.nvim_win_call(live_stream_win, function() return vim.fn.foldclosed(1) == 1 end)
end), "visible full diff view repaints to collapse newly viewed directory files")
vim.fn.writefile({ vim.json.encode(tree_view) }, set_viewed_payload)
vim.fn.writefile({ vim.json.encode(expanded_dir_stream) }, stream_payload)
press("v", 7)
assert(vim.wait(3000, function()
    return vim.api.nvim_win_call(live_stream_win, function() return vim.fn.foldclosed(1) == -1 end)
end), "visible full diff view repaints to expand newly unviewed directory files")

-- Mouse click support in the sidebar panel.
local mouse_mod = require("jpr.mouse")
local original_getmousepos = vim.fn.getmousepos
local original_passthrough = mouse_mod.passthrough
local passthrough_calls = {}
mouse_mod.passthrough = function(key)
    passthrough_calls[#passthrough_calls + 1] = key or "<LeftMouse>"
end
local is_mouse_ok, mouse_error = pcall(function()
    vim.api.nvim_set_current_win(panel_win)
    local left_mouse_map = vim.fn.maparg("<LeftMouse>", "n", false, true)
    assert(type(left_mouse_map) == "table" and type(left_mouse_map.callback) == "function", "<LeftMouse> mapped on panel")

    -- Single-click on collapsed src/ directory expands it, then clicking again collapses and re-expands it.
    assert(review.panel.collapsed_dirs["src"] == true, "src/ starts collapsed from prior test")
    vim.fn.getmousepos = function() return { winid = panel_win, line = 7, column = 3 } end
    left_mouse_map.callback()
    assert(review.panel.collapsed_dirs["src"] == nil, "single-click on collapsed dir expands it")
    left_mouse_map.callback()
    assert(review.panel.collapsed_dirs["src"] == true, "single-click on expanded dir collapses it")
    left_mouse_map.callback()
    assert(review.panel.collapsed_dirs["src"] == nil, "single-click re-expands src/ so src/a.rs is visible")

    -- Single-click on a file row opens that file in the main window.
    vim.fn.getmousepos = function() return { winid = panel_win, line = 8, column = 5 } end
    left_mouse_map.callback()
    assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/src/a.rs"), "single-click opens src/a.rs")

    -- Single-click on the Conversation row opens PR conversation.
    vim.api.nvim_set_current_win(panel_win)
    local conversation_line = review.panel.conversation_line
    assert(conversation_line ~= nil, "conversation_line is set")
    vim.fn.getmousepos = function() return { winid = panel_win, line = conversation_line, column = 4 } end
    left_mouse_map.callback()
    assert(vim.wait(3000, function()
        return review.conversation ~= nil and review.conversation.buf ~= nil and vim.api.nvim_buf_is_valid(review.conversation.buf)
    end), "single-click on Conversation opens PR conversation")

    -- Single-click on a non-selectable header line keeps selection unchanged.
    vim.api.nvim_set_current_win(panel_win)
    vim.api.nvim_win_set_cursor(panel_win, { 8, 0 })
    vim.fn.getmousepos = function() return { winid = panel_win, line = 1, column = 2 } end
    left_mouse_map.callback()
    assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 8, "click on non-selectable header preserves selection")

    -- Single-click outside panel_win forwards natively via passthrough.
    vim.fn.getmousepos = function() return { winid = live_stream_win, line = 2, column = 1 } end
    left_mouse_map.callback()
    assert(#passthrough_calls == 1 and passthrough_calls[1] == "<LeftMouse>", "outside click passes through <LeftMouse>")
end)
vim.fn.getmousepos = original_getmousepos
mouse_mod.passthrough = original_passthrough
assert(is_mouse_ok, tostring(mouse_error))

os.remove(stream_payload)
os.remove(set_viewed_payload)
vim.env.FAKE_ENGINE_STREAM_FILE = nil
vim.env.FAKE_ENGINE_SET_VIEWED_FILE = nil

session.close_current()
print("panel_view_spec: ok")
