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
local collapsed_payload = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
vim.env.FAKE_ENGINE_SET_VIEWED_FILE = set_viewed_payload
vim.env.FAKE_ENGINE_STREAM_FILE = stream_payload
vim.env.FAKE_ENGINE_SET_COLLAPSED_FILE = collapsed_payload
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
press("<CR>", 9)
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
press("o", 9)
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
for _, line in ipairs({ 9, 10 }) do
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

local function find_log_lines(needle)
    return vim.tbl_filter(function(line)
        return line:find(needle, 1, true) ~= nil
    end, vim.fn.readfile(log))
end
press("v", 9)
assert(vim.wait(3000, function()
    return review.view.viewedCount == 1
end), "the engine's viewedChanged reaches the view")
assert(#find_sent_requests('"viewed":true') == 1 and #find_sent_requests('"path":"README.md"') == 1, vim.inspect(vim.fn.readfile(log)))
press("v", 9)
assert(vim.wait(3000, function()
    return #find_sent_requests('"viewed":false') == 1
end), "v on a viewed file unmarks it")
press("v", 1)
press("v", 7)
vim.wait(200)
assert(#find_sent_requests("setViewed") == 2, "v on a header or Diff summary row sends nothing")

-- <CR> on the Diff summary row (line 6) opens the unified view scrolled to line 1.
press("<CR>", 7)
local summary_win = vim.api.nvim_get_current_win()
assert(summary_win ~= panel_win, "<CR> on line 6 focuses the main window beside the panel")
local summary_buf = vim.api.nvim_win_get_buf(summary_win)
assert(vim.api.nvim_buf_get_name(summary_buf) == "jpr://conversation/7", "<CR> on line 6 opens jpr://conversation/7")
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(summary_buf, 0, -1, false), "\n")
    return text:find("Fixes widget crash.", 1, true) ~= nil and vim.api.nvim_win_get_cursor(summary_win)[1] == 1
end), "summary row opens unified buffer at line 1")
require("jpr.views.conversation").close(review)

-- <CR> on the Conversation row (line 8) opens the unified view scrolled to the Conversation heading.
press("<CR>", 8)
local conversation_win = vim.api.nvim_get_current_win()
assert(conversation_win ~= panel_win, "<CR> on line 7 focuses the main window beside the panel")
local conversation_buf = vim.api.nvim_win_get_buf(conversation_win)
assert(vim.api.nvim_buf_get_name(conversation_buf) == "jpr://conversation/7", "<CR> on line 7 opens jpr://conversation/7")
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n")
    local start = review.conversation and review.conversation.layout and review.conversation.layout.conversation_start_line
    return text:find("Overall looks clean!", 1, true) ~= nil and start ~= nil and vim.api.nvim_win_get_cursor(conversation_win)[1] == start
end), "conversation buffer renders PR comments and scrolls to conversation start")
require("jpr.views.conversation").close(review)

-- `o` on the Conversation row also opens the PR conversation buffer identically to <CR>.
press("o", 8)
local conversation_win_from_o = vim.api.nvim_get_current_win()
assert(conversation_win_from_o ~= panel_win, "o on line 7 focuses the main window beside the panel")
local conversation_buf_from_o = vim.api.nvim_win_get_buf(conversation_win_from_o)
assert(vim.api.nvim_buf_get_name(conversation_buf_from_o) == "jpr://conversation/7", "o on line 7 opens jpr://conversation/7")
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
press("<CR>", 9)
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

-- Cursor clamps to column 0 and snaps off header lines onto Diff summary.
vim.api.nvim_set_current_win(panel_win)
vim.api.nvim_win_set_cursor(panel_win, { 1, 3 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = review.panel.buf })
local snapped_cursor = vim.api.nvim_win_get_cursor(panel_win)
assert(snapped_cursor[1] == 7 and snapped_cursor[2] == 0, "header snaps to Diff summary col 0: " .. vim.inspect(snapped_cursor))
local row_info = panel_view.get_row_under_cursor(review)
assert(row_info and row_info.line == 7 and row_info.row.kind == "summary", vim.inspect(row_info))

-- Horizontal keys (w, $, 0) are no-ops; j/k/gg/G move strictly across selectable_lines.
run_panel_key("w")
run_panel_key("$")
run_panel_key("0")
assert(vim.api.nvim_win_get_cursor(panel_win)[2] == 0, "horizontal keys stay at col 0")
assert(vim.wo[panel_win].sidescrolloff == 0, "sidescrolloff is 0 on panel window")

run_panel_key("j")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 8, "j moves to Conversation")
run_panel_key("j")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 9, "j moves to src/ dir")
run_panel_key("G")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 12, "G jumps to last selectable item")
run_panel_key("k")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 11, "k moves up to src/b.rs")
run_panel_key("gg")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 7, "gg jumps to Diff summary")

local function stage_collapsed(paths, base)
    local next_view = vim.deepcopy(base or tree_view)
    next_view.collapsedDirs = paths
    vim.fn.writefile({ vim.json.encode(next_view) }, collapsed_payload)
end

local function wait_src_collapsed(label, is_collapsed)
    assert(vim.wait(3000, function()
        return (review.panel.collapsed_dirs["src"] == true) == is_collapsed
    end), label)
end

-- A snapshot collapsedDirs list collapses the directory before any keypress.
tree_view.collapsedDirs = { "src" }
panel_view.render(review, tree_view)
assert(review.panel.collapsed_dirs["src"] == true, "view.collapsedDirs collapses src/ before a keypress")
assert(vim.api.nvim_buf_get_lines(review.panel.buf, 8, 9, false)[1]:find("▸ src/", 1, true) ~= nil, "collapsed src/ renders from the view")
tree_view.collapsedDirs = nil
panel_view.render(review, tree_view)
assert(review.panel.collapsed_dirs["src"] == nil, "render without collapsedDirs expands src/")
review.panel.collapsed_dirs["src"] = true
panel_view.render(review, tree_view)
assert(review.panel.collapsed_dirs["src"] == nil, "a local collapsed_dirs assignment does not survive render")

-- h on child file jumps to parent_dir; h on expanded dir collapses it.
vim.api.nvim_win_set_cursor(panel_win, { 11, 0 })
local collapse_requests_before_file_h = #find_log_lines('"method":"setCollapsed"')
run_panel_key("h")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 9, "h on child file jumps to parent src/ dir")
assert(#find_log_lines('"method":"setCollapsed"') == collapse_requests_before_file_h, "h on a file sends no setCollapsed")
stage_collapsed({ "src" })
run_panel_key("h")
wait_src_collapsed("h on expanded dir collapses it", true)
assert(vim.api.nvim_buf_get_lines(review.panel.buf, 8, 9, false)[1] == "▸ src/ (0/2)", "collapsed src/ shows viewed files out of all descendant files")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 9, "cursor stays on collapsed dir")
local collapse_request = find_log_lines('"method":"setCollapsed"')[#find_log_lines('"method":"setCollapsed"')]
assert(collapse_request:find('"path":"src"', 1, true) and collapse_request:find('"collapsed":true', 1, true), collapse_request)

-- o expands a collapsed dir, does nothing on an already-expanded dir.
stage_collapsed({})
run_panel_key("o")
wait_src_collapsed("o expands collapsed dir", false)
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 9, "cursor stays on expanded dir after o")
local requests_before_noop_o = #find_log_lines('"method":"setCollapsed"')
run_panel_key("o")
assert(#find_log_lines('"method":"setCollapsed"') == requests_before_noop_o, "o on already-expanded dir does nothing")
assert(review.panel.collapsed_dirs["src"] == nil, "o on already-expanded dir stays expanded")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 9, "o on already-expanded dir does not move cursor")

-- <CR> toggles directories.
stage_collapsed({ "src" })
run_panel_key("<CR>")
wait_src_collapsed("<CR> collapses expanded dir", true)
stage_collapsed({})
run_panel_key("<CR>")
wait_src_collapsed("<CR> expands collapsed dir", false)

-- l / <Right> expands a collapsed dir and steps into first child on an expanded dir,
-- but never opens a file, Diff summary, or Conversation row (avoiding accidental opens).
stage_collapsed({ "src" })
run_panel_key("h")
wait_src_collapsed("re-collapsed src/", true)
stage_collapsed({})
run_panel_key("l")
wait_src_collapsed("l expands collapsed dir", false)
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 9, "l expanding dir keeps cursor on dir")
local requests_before_step_l = #find_log_lines('"method":"setCollapsed"')
run_panel_key("l")
assert(#find_log_lines('"method":"setCollapsed"') == requests_before_step_l, "l on an expanded dir sends no setCollapsed")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 10, "l on expanded dir steps into first child")
local main_buf_before_l = vim.api.nvim_win_get_buf(stream_win)
run_panel_key("l")
assert(vim.api.nvim_get_current_win() == panel_win, "l on file stays in panel window")
assert(vim.api.nvim_win_get_buf(stream_win) == main_buf_before_l, "l on file does not open it in main window")
run_panel_key("<Right>")
assert(vim.api.nvim_get_current_win() == panel_win, "<Right> on file stays in panel window")
assert(vim.api.nvim_win_get_buf(stream_win) == main_buf_before_l, "<Right> on file does not open it in main window")
vim.api.nvim_win_set_cursor(panel_win, { 7, 0 })
run_panel_key("l")
assert(vim.api.nvim_get_current_win() == panel_win, "l on Diff summary row stays in panel window")
vim.api.nvim_win_set_cursor(panel_win, { 8, 0 })
run_panel_key("l")
assert(vim.api.nvim_get_current_win() == panel_win, "l on Conversation row stays in panel window")

-- Cursor stays on the same file path (and on Diff summary) across M.render redraws.
vim.api.nvim_set_current_win(panel_win)
vim.api.nvim_win_set_cursor(panel_win, { 7, 0 })
panel_view.render(review, tree_view)
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 7, "cursor stays on Diff summary across redraw")
vim.api.nvim_win_set_cursor(panel_win, { 11, 0 })
panel_view.render(review, tree_view)
local preserved = vim.api.nvim_win_get_cursor(panel_win)
assert(preserved[1] == 11 and preserved[2] == 0, "cursor stays on src/b.rs across redraw: " .. vim.inspect(preserved))

-- Pressing `v` on an expanded or collapsed directory sends a single batched
-- setViewed request with all descendant paths, and advances the main window
-- when it was showing a file just marked viewed.
local all_src_viewed = vim.deepcopy(tree_view)
all_src_viewed.files[2].viewed = "VIEWED"
all_src_viewed.files[3].viewed = "VIEWED"
all_src_viewed.viewedCount = 2
vim.fn.writefile({ vim.json.encode(all_src_viewed) }, set_viewed_payload)

-- Open src/a.rs in main window (hiding stream), then press v on src/ dir in panel.
press("<CR>", 10)
assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/src/a.rs"), "opened src/a.rs in main window")
local main_win_for_dir = vim.api.nvim_get_current_win()
local before_dir_requests = #find_sent_requests('"paths":')
press("v", 9)
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
stage_collapsed({ "src" }, all_src_viewed)
run_panel_key("h")
wait_src_collapsed("collapsed src/", true)
vim.fn.writefile({ vim.json.encode(tree_view) }, set_viewed_payload)
press("v", 9)
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
press("v", 9)
assert(vim.wait(3000, function()
    return vim.api.nvim_win_call(live_stream_win, function() return vim.fn.foldclosed(1) == 1 end)
end), "visible full diff view repaints to collapse newly viewed directory files")
vim.fn.writefile({ vim.json.encode(tree_view) }, set_viewed_payload)
vim.fn.writefile({ vim.json.encode(expanded_dir_stream) }, stream_payload)
press("v", 9)
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
    local collapsed_for_mouse = vim.deepcopy(tree_view)
    collapsed_for_mouse.collapsedDirs = { "src" }
    require("jpr.session").show(review, collapsed_for_mouse)
    assert(review.panel.collapsed_dirs["src"] == true, "src/ starts collapsed for the click test")
    vim.fn.getmousepos = function() return { winid = panel_win, line = 9, column = 3 } end
    stage_collapsed({})
    left_mouse_map.callback()
    wait_src_collapsed("single-click on collapsed dir expands it", false)
    stage_collapsed({ "src" })
    left_mouse_map.callback()
    wait_src_collapsed("single-click on expanded dir collapses it", true)
    stage_collapsed({})
    left_mouse_map.callback()
    wait_src_collapsed("single-click re-expands src/ so src/a.rs is visible", false)

    -- Single-click on a file row opens that file in the main window.
    vim.fn.getmousepos = function() return { winid = panel_win, line = 10, column = 5 } end
    left_mouse_map.callback()
    assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/src/a.rs"), "single-click opens src/a.rs")

    -- Single-click on the Diff summary row opens unified view at line 1.
    vim.api.nvim_set_current_win(panel_win)
    local summary_line = review.panel.summary_line
    assert(summary_line ~= nil, "summary_line is set")
    vim.fn.getmousepos = function() return { winid = panel_win, line = summary_line, column = 4 } end
    left_mouse_map.callback()
    assert(vim.wait(3000, function()
        return review.conversation ~= nil
            and review.conversation.buf ~= nil
            and vim.api.nvim_buf_is_valid(review.conversation.buf)
            and vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1] == 1
    end), "single-click on Diff summary opens unified view at line 1")

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
    vim.api.nvim_win_set_cursor(panel_win, { 10, 0 })
    vim.fn.getmousepos = function() return { winid = panel_win, line = 1, column = 2 } end
    left_mouse_map.callback()
    assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 10, "click on non-selectable header preserves selection")

    -- Single-click outside panel_win forwards natively via passthrough.
    vim.fn.getmousepos = function() return { winid = live_stream_win, line = 2, column = 1 } end
    left_mouse_map.callback()
    assert(#passthrough_calls == 1 and passthrough_calls[1] == "<LeftMouse>", "outside click passes through <LeftMouse>")
end)
vim.fn.getmousepos = original_getmousepos
mouse_mod.passthrough = original_passthrough
assert(is_mouse_ok, tostring(mouse_error))

-- gc and gf comment the sidebar file. gc on Diff summary posts a PR comment.
-- A directory has no comment. gp posts a PR comment from anywhere in the sidebar.
dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")
review.panel.collapsed_dirs = {}
panel_view.render(review, tree_view)
local panel_lines = vim.api.nvim_buf_get_lines(review.panel.buf, 0, -1, false)
assert(panel_lines[7]:find("Diff summary", 1, true) ~= nil, panel_lines[7])
assert(panel_lines[9]:find("src/", 1, true) ~= nil, panel_lines[9])
assert(panel_lines[10]:find("a.rs", 1, true) ~= nil, panel_lines[10])

local function press_panel(lhs, line)
    review.panel.collapsed_dirs = {}
    panel_view.render(review, tree_view)
    vim.api.nvim_set_current_win(review.panel.win)
    vim.api.nvim_win_set_cursor(review.panel.win, { line, 0 })
    helpers.press_key(lhs)
end

local function submit_comment(body)
    local compose_win = helpers.find_floating_win("GitHub")
    assert(compose_win ~= nil, "compose window opened")
    vim.api.nvim_set_current_win(compose_win)
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(compose_win), 0, -1, false, { body })
    helpers.press_key("<C-s>")
    return compose_win
end

local comments_before = #helpers.read_requests(log, "comment")
press_panel("gc", 10)
submit_comment("file from gc")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "comment") == comments_before + 1
end), "sidebar gc file comment sent")
local gc_file = helpers.read_requests(log, "comment")[comments_before + 1].params
assert(vim.deep_equal(gc_file.anchor, { file = "src/a.rs", kind = "file", side = "RIGHT" }), vim.inspect(gc_file))

press_panel("gf", 10)
submit_comment("file from gf")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "comment") == comments_before + 2
end), "sidebar gf file comment sent")
local gf_file = helpers.read_requests(log, "comment")[comments_before + 2].params
assert(vim.deep_equal(gf_file.anchor, { file = "src/a.rs", kind = "file", side = "RIGHT" }), vim.inspect(gf_file))

press_panel("gc", 7)
submit_comment("pr from summary")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "comment") == comments_before + 3
end), "sidebar gc on Diff summary sent a PR comment")
local summary_comment = helpers.read_requests(log, "comment")[comments_before + 3].params
assert(vim.deep_equal(summary_comment.anchor, { kind = "pr", side = "RIGHT" }), vim.inspect(summary_comment))

local comment_errors = {}
local report_error = jpr.error
jpr.error = function(message)
    comment_errors[#comment_errors + 1] = message
end
press_panel("gc", 9)
assert(#comment_errors == 1, "gc on a directory reports an error: " .. vim.inspect(comment_errors))
assert(helpers.find_floating_win("GitHub") == nil, "gc on a directory opens no compose window")
jpr.error = report_error

press_panel("gp", 9)
submit_comment("pr from gp")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "comment") == comments_before + 4
end), "gp sends a PR comment from a directory row")
local gp_comment = helpers.read_requests(log, "comment")[comments_before + 4].params
assert(vim.deep_equal(gp_comment.anchor, { kind = "pr", side = "RIGHT" }), vim.inspect(gp_comment))

local lines_before_bad_collapse = vim.api.nvim_buf_get_lines(review.panel.buf, 0, -1, false)
local applied_bad_collapse = false
session.request(review, "setCollapsed", { path = "../x", collapsed = true }, function()
    applied_bad_collapse = true
end)
assert(vim.wait(3000, function()
    return #find_log_lines('"path":"../x"') >= 1
end), "unsafe setCollapsed is sent")
assert(applied_bad_collapse == false, "a failed setCollapsed does not apply")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(review.panel.buf, 0, -1, false), lines_before_bad_collapse), "a failed setCollapsed leaves the panel lines")

local expanded_view = vim.deepcopy(tree_view)
expanded_view.collapsedDirs = nil
stage_collapsed({ "src" })
require("jpr.session").show(review, (function()
    local collapsed_view = vim.deepcopy(tree_view)
    collapsed_view.collapsedDirs = { "src" }
    return collapsed_view
end)())
assert(review.panel.collapsed_dirs["src"] == true, "show collapses src from the view")
require("jpr.session").show(review, expanded_view)
assert(review.panel.collapsed_dirs["src"] == nil, "a synced view drops a collapsed parent")

-- Marking a file or directory viewed must not reopen a closed editor.
-- The agent split is a side window, so the tab can be sidebar + agent only.
local layout = require("jpr.views.layout")
local main_window = require("jpr.views.main_window")
vim.api.nvim_set_current_win(panel_win)
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(review.tab)) do
    if win ~= panel_win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
    end
end
local agent_buf = vim.api.nvim_create_buf(false, true)
vim.bo[agent_buf].bufhidden = "hide"
local agent_win = require("jpr.agent.window").open_for_direction(review, agent_buf, "vertical", "claude", jpr.config)
review.agent = { buf = agent_buf, win = agent_win, job = 999, exited = false, kind = "claude" }
layout.reconcile(review, { force = true })
panel_view.render(review, tree_view)

local function count_editor_windows()
    local count = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(review.tab)) do
        if not main_window.is_side(review, win) then
            count = count + 1
        end
    end
    return count
end

local function find_panel_line(kind, path)
    for line, row in pairs(review.panel.rows) do
        if row.kind == kind and row.path == path then
            return line
        end
    end
    return nil
end

assert(layout.classify_tab_windows(review).has_editor == false, "editor starts closed beside the agent")
assert(count_editor_windows() == 0, "no editor window before marking viewed")

local function mark_paths_viewed(paths, viewed_count)
    local updated = vim.deepcopy(tree_view)
    local marked = {}
    for _, path in ipairs(paths) do
        marked[path] = true
    end
    for _, file in ipairs(updated.files) do
        if marked[file.path] then
            file.viewed = "VIEWED"
        end
    end
    updated.viewedCount = viewed_count
    vim.fn.writefile({ vim.json.encode(updated) }, set_viewed_payload)
    return updated
end

local readme_line = find_panel_line("file", "README.md")
local src_line = find_panel_line("dir", "src")
assert(readme_line ~= nil and src_line ~= nil, "README.md and src/ rows are selectable")

mark_paths_viewed({ "README.md" }, 4242)
local before_file_marks = #find_sent_requests('"path":"README.md"')
press("v", readme_line)
assert(vim.wait(3000, function()
    return review.view.viewedCount == 4242 and #find_sent_requests('"path":"README.md"') == before_file_marks + 1
end), "v on a file still sends setViewed while the editor is closed")
vim.wait(50, function()
    return false
end)
assert(count_editor_windows() == 0, "marking a file viewed leaves the editor closed")
assert(vim.api.nvim_get_current_win() == panel_win, "marking a file viewed keeps the sidebar focused")

panel_view.render(review, tree_view)
src_line = find_panel_line("dir", "src")
mark_paths_viewed({ "src/a.rs", "src/b.rs" }, 4243)
local before_dir_marks = #find_sent_requests('"paths":')
press("v", src_line)
assert(vim.wait(3000, function()
    return review.view.viewedCount == 4243 and #find_sent_requests('"paths":') == before_dir_marks + 1
end), "v on a directory still sends setViewed while the editor is closed")
vim.wait(50, function()
    return false
end)
assert(count_editor_windows() == 0, "marking a directory viewed leaves the editor closed")
assert(vim.api.nvim_get_current_win() == panel_win, "marking a directory viewed keeps the sidebar focused")

os.remove(stream_payload)
os.remove(set_viewed_payload)
os.remove(collapsed_payload)
vim.env.FAKE_ENGINE_STREAM_FILE = nil
vim.env.FAKE_ENGINE_SET_VIEWED_FILE = nil
vim.env.FAKE_ENGINE_SET_COLLAPSED_FILE = nil

session.close_current()
print("panel_view_spec: ok")
