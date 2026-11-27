return function(context)
    local session = require("jpr.session")
    local panel_view = require("jpr.views.panel")
    local stream_view = require("jpr.views.stream")
    local review = context.review
    local worktree = context.worktree
    local press = context.press
    local panel_win = context.panel_win
    local stream_win = context.stream_win
    local set_viewed_payload = context.set_viewed_payload
    local stream_payload = context.stream_payload
    local collapsed_payload = context.collapsed_payload
    local find_sent_requests = context.find_sent_requests
    local find_log_lines = context.find_log_lines

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
assert(snapped_cursor[1] == 8 and snapped_cursor[2] == 0, "header snaps to Diff summary col 0: " .. vim.inspect(snapped_cursor))
local row_info = panel_view.get_row_under_cursor(review)
assert(row_info and row_info.line == 8 and row_info.row.kind == "summary", vim.inspect(row_info))

-- Horizontal keys (w, $, 0) are no-ops; j/k/gg/G move strictly across selectable_lines.
run_panel_key("w")
run_panel_key("$")
run_panel_key("0")
assert(vim.api.nvim_win_get_cursor(panel_win)[2] == 0, "horizontal keys stay at col 0")
assert(vim.wo[panel_win].sidescrolloff == 0, "sidescrolloff is 0 on panel window")

run_panel_key("j")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 9, "j moves to Conversation")
run_panel_key("j")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 10, "j moves to src/ dir")
run_panel_key("G")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 13, "G jumps to last selectable item")
run_panel_key("k")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 12, "k moves up to src/b.rs")
run_panel_key("gg")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 8, "gg jumps to Diff summary")

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
assert(vim.api.nvim_buf_get_lines(review.panel.buf, 9, 10, false)[1]:find("▸ src/", 1, true) ~= nil, "collapsed src/ renders from the view")
tree_view.collapsedDirs = nil
panel_view.render(review, tree_view)
assert(review.panel.collapsed_dirs["src"] == nil, "render without collapsedDirs expands src/")
review.panel.collapsed_dirs["src"] = true
panel_view.render(review, tree_view)
assert(review.panel.collapsed_dirs["src"] == nil, "a local collapsed_dirs assignment does not survive render")

-- h on child file jumps to parent_dir; h on expanded dir collapses it without opening stream.
vim.api.nvim_win_set_cursor(panel_win, { 12, 0 })
local collapse_requests_before_file_h = #find_log_lines('"method":"setCollapsed"')
run_panel_key("h")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 10, "h on child file jumps to parent src/ dir")
assert(#find_log_lines('"method":"setCollapsed"') == collapse_requests_before_file_h, "h on a file sends no setCollapsed")
local stream_requests_before_collapse = #find_log_lines('"method":"stream"')
local was_stream_opened = review.stream_opened
review.stream_opened = false
stage_collapsed({ "src" })
run_panel_key("h")
wait_src_collapsed("h on expanded dir collapses it", true)
assert(
    #find_log_lines('"method":"stream"') == stream_requests_before_collapse,
    "setCollapsed must not trigger a stream request"
)
review.stream_opened = was_stream_opened
assert(vim.api.nvim_buf_get_lines(review.panel.buf, 9, 10, false)[1] == "▸ src/ (0/2)", "collapsed src/ shows viewed files out of all descendant files")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 10, "cursor stays on collapsed dir")
local collapse_request = find_log_lines('"method":"setCollapsed"')[#find_log_lines('"method":"setCollapsed"')]
assert(collapse_request:find('"path":"src"', 1, true) and collapse_request:find('"collapsed":true', 1, true), collapse_request)

-- o expands a collapsed dir, does nothing on an already-expanded dir.
stage_collapsed({})
run_panel_key("o")
wait_src_collapsed("o expands collapsed dir", false)
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 10, "cursor stays on expanded dir after o")
local requests_before_noop_o = #find_log_lines('"method":"setCollapsed"')
run_panel_key("o")
assert(#find_log_lines('"method":"setCollapsed"') == requests_before_noop_o, "o on already-expanded dir does nothing")
assert(review.panel.collapsed_dirs["src"] == nil, "o on already-expanded dir stays expanded")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 10, "o on already-expanded dir does not move cursor")

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
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 10, "l expanding dir keeps cursor on dir")
local requests_before_step_l = #find_log_lines('"method":"setCollapsed"')
run_panel_key("l")
assert(#find_log_lines('"method":"setCollapsed"') == requests_before_step_l, "l on an expanded dir sends no setCollapsed")
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 11, "l on expanded dir steps into first child")
local main_buf_before_l = vim.api.nvim_win_get_buf(stream_win)
run_panel_key("l")
assert(vim.api.nvim_get_current_win() == panel_win, "l on file stays in panel window")
assert(vim.api.nvim_win_get_buf(stream_win) == main_buf_before_l, "l on file does not open it in main window")
run_panel_key("<Right>")
assert(vim.api.nvim_get_current_win() == panel_win, "<Right> on file stays in panel window")
assert(vim.api.nvim_win_get_buf(stream_win) == main_buf_before_l, "<Right> on file does not open it in main window")
vim.api.nvim_win_set_cursor(panel_win, { 8, 0 })
run_panel_key("l")
assert(vim.api.nvim_get_current_win() == panel_win, "l on Diff summary row stays in panel window")
vim.api.nvim_win_set_cursor(panel_win, { 9, 0 })
run_panel_key("l")
assert(vim.api.nvim_get_current_win() == panel_win, "l on Conversation row stays in panel window")

-- Cursor stays on the same file path (and on Diff summary) across M.render redraws.
vim.api.nvim_set_current_win(panel_win)
vim.api.nvim_win_set_cursor(panel_win, { 8, 0 })
panel_view.render(review, tree_view)
assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 8, "cursor stays on Diff summary across redraw")
vim.api.nvim_win_set_cursor(panel_win, { 12, 0 })
panel_view.render(review, tree_view)
local preserved = vim.api.nvim_win_get_cursor(panel_win)
assert(preserved[1] == 12 and preserved[2] == 0, "cursor stays on src/b.rs across redraw: " .. vim.inspect(preserved))

-- Pressing `v` on an expanded or collapsed directory sends a single batched
-- setViewed request with all descendant paths, and advances the main window
-- when it was showing a file just marked viewed.
local all_src_viewed = vim.deepcopy(tree_view)
all_src_viewed.files[2].viewed = "VIEWED"
all_src_viewed.files[3].viewed = "VIEWED"
all_src_viewed.viewedCount = 2
vim.fn.writefile({ vim.json.encode(all_src_viewed) }, set_viewed_payload)

-- Open src/a.rs in main window (hiding stream), then press v on src/ dir in panel.
press("<CR>", 11)
assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/src/a.rs"), "opened src/a.rs in main window")
local main_win_for_dir = vim.api.nvim_get_current_win()
local before_dir_requests = #find_sent_requests('"paths":')
press("v", 10)
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
press("v", 10)
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
press("v", 10)
assert(vim.wait(3000, function()
    return vim.api.nvim_win_call(live_stream_win, function() return vim.fn.foldclosed(1) == 1 end)
end), "visible full diff view repaints to collapse newly viewed directory files")
vim.fn.writefile({ vim.json.encode(tree_view) }, set_viewed_payload)
vim.fn.writefile({ vim.json.encode(expanded_dir_stream) }, stream_payload)
press("v", 10)
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
    vim.fn.getmousepos = function() return { winid = panel_win, line = 10, column = 3 } end
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
    vim.fn.getmousepos = function() return { winid = panel_win, line = 11, column = 5 } end
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
    vim.api.nvim_win_set_cursor(panel_win, { 11, 0 })
    vim.fn.getmousepos = function() return { winid = panel_win, line = 1, column = 2 } end
    left_mouse_map.callback()
    assert(vim.api.nvim_win_get_cursor(panel_win)[1] == 11, "click on non-selectable header preserves selection")

    -- Single-click outside panel_win forwards natively via passthrough.
    vim.fn.getmousepos = function() return { winid = live_stream_win, line = 2, column = 1 } end
    left_mouse_map.callback()
    assert(#passthrough_calls == 1 and passthrough_calls[1] == "<LeftMouse>", "outside click passes through <LeftMouse>")
end)
vim.fn.getmousepos = original_getmousepos
mouse_mod.passthrough = original_passthrough
assert(is_mouse_ok, tostring(mouse_error))


    context.tree_view = tree_view
    context.stage_collapsed = stage_collapsed
end
