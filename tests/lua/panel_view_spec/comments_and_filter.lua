return function(context)
    local root = context.root
    local jpr = require("jpr")
    local session = require("jpr.session")
    local panel_view = require("jpr.views.panel")
    local review = context.review
    local log = context.log
    local press = context.press
    local panel_win = context.panel_win
    local tree_view = context.tree_view
    local stage_collapsed = context.stage_collapsed
    local set_viewed_payload = context.set_viewed_payload
    local find_sent_requests = context.find_sent_requests
    local find_log_lines = context.find_log_lines

-- gc and gf comment the sidebar file. gc on Diff summary posts a PR comment.
-- A directory has no comment. gp posts a PR comment from anywhere in the sidebar.
dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")
review.panel.collapsed_dirs = {}
panel_view.render(review, tree_view)
local panel_lines = vim.api.nvim_buf_get_lines(review.panel.buf, 0, -1, false)
assert(panel_lines[8]:find("Diff summary", 1, true) ~= nil, panel_lines[8])
assert(panel_lines[10]:find("src/", 1, true) ~= nil, panel_lines[10])
assert(panel_lines[11]:find("a.rs", 1, true) ~= nil, panel_lines[11])

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
press_panel("gc", 11)
submit_comment("file from gc")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "comment") == comments_before + 1
end), "sidebar gc file comment sent")
local gc_file = helpers.read_requests(log, "comment")[comments_before + 1].params
assert(vim.deep_equal(gc_file.anchor, { file = "src/a.rs", kind = "file", side = "RIGHT" }), vim.inspect(gc_file))

press_panel("gf", 11)
submit_comment("file from gf")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "comment") == comments_before + 2
end), "sidebar gf file comment sent")
local gf_file = helpers.read_requests(log, "comment")[comments_before + 2].params
assert(vim.deep_equal(gf_file.anchor, { file = "src/a.rs", kind = "file", side = "RIGHT" }), vim.inspect(gf_file))

press_panel("gc", 8)
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
press_panel("gc", 10)
assert(#comment_errors == 1, "gc on a directory reports an error: " .. vim.inspect(comment_errors))
assert(helpers.find_floating_win("GitHub") == nil, "gc on a directory opens no compose window")
jpr.error = report_error

press_panel("gp", 10)
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

-- u shows only files that still need review (replacing gu), clicking the header
-- filter pill toggles the same filter, and the choice survives closing the sidebar.
local filtered_view = vim.deepcopy(tree_view)
filtered_view.files[1].viewed = "VIEWED"
filtered_view.files[2].viewed = "DISMISSED"
filtered_view.files[3].viewed = "VIEWED"
filtered_view.viewedCount = 2
review.view = filtered_view
panel_view.render(review, filtered_view)
vim.api.nvim_set_current_win(review.panel.win)
local gu_map = vim.fn.maparg("gu", "n", false, true)
assert(type(gu_map) ~= "table" or gu_map.callback == nil, "gu is no longer mapped on the panel")
local u_map = vim.fn.maparg("u", "n", false, true)
assert(type(u_map) == "table" and type(u_map.callback) == "function", "u is mapped on the panel")
press("u", find_panel_line("file", "README.md"))
local filtered_text = table.concat(vim.api.nvim_buf_get_lines(review.panel.buf, 0, -1, false), "\n")
assert(filtered_text:find("filter: [u] unviewed only", 1, true) ~= nil, filtered_text)
assert(filtered_text:find("README.md", 1, true) == nil, filtered_text)
assert(filtered_text:find("b.rs", 1, true) == nil, filtered_text)
assert(filtered_text:find("a.rs", 1, true) ~= nil, filtered_text)
assert(filtered_text:find("src/", 1, true) ~= nil, filtered_text)
assert(vim.api.nvim_get_current_win() == review.panel.win, "u keeps the sidebar focused")
local cursor_after_filter = vim.api.nvim_win_get_cursor(review.panel.win)[1]
assert(review.panel.rows[cursor_after_filter] ~= nil, "cursor lands on a visible row after hiding the previous file")

press("u", cursor_after_filter)
local restored_text = table.concat(vim.api.nvim_buf_get_lines(review.panel.buf, 0, -1, false), "\n")
assert(restored_text:find("filter: [u] all files", 1, true) ~= nil, restored_text)
assert(restored_text:find("unviewed only", 1, true) == nil, restored_text)
assert(restored_text:find("README.md", 1, true) ~= nil, restored_text)
assert(restored_text:find("b.rs", 1, true) ~= nil, restored_text)

-- Clicking the header filter pill toggles the unviewed filter without losing focus.
assert(review.panel.filter_line ~= nil, "filter_line is recorded on the panel")
local original_filter_getmousepos = vim.fn.getmousepos
local is_filter_click_ok, filter_click_error = pcall(function()
    vim.fn.getmousepos = function()
        return { winid = review.panel.win, line = review.panel.filter_line, column = 10 }
    end
    vim.api.nvim_set_current_win(review.panel.win)
    helpers.press_key("<LeftMouse>")
    assert(review.panel_hide_viewed == true, "clicking filter pill enables unviewed filter")
    assert(vim.api.nvim_get_current_win() == review.panel.win, "clicking filter pill keeps sidebar focused")
    local clicked_text = table.concat(vim.api.nvim_buf_get_lines(review.panel.buf, 0, -1, false), "\n")
    assert(clicked_text:find("filter: [u] unviewed only", 1, true) ~= nil, clicked_text)
    helpers.press_key("<LeftMouse>")
    assert(review.panel_hide_viewed == false, "clicking filter pill again disables unviewed filter")
end)
vim.fn.getmousepos = original_filter_getmousepos
assert(is_filter_click_ok, tostring(filter_click_error))

press("u", find_panel_line("file", "README.md"))
assert(panel_view.toggle(review) == true, "sidebar closes while the agent window is open")
assert(review.panel_hide_viewed == true, "closing the sidebar keeps the unviewed filter")
assert(panel_view.toggle(review) == true, "sidebar reopens")
local reopened_text = table.concat(vim.api.nvim_buf_get_lines(review.panel.buf, 0, -1, false), "\n")
assert(reopened_text:find("filter: [u] unviewed only", 1, true) ~= nil, reopened_text)
assert(reopened_text:find("README.md", 1, true) == nil, reopened_text)
assert(reopened_text:find("a.rs", 1, true) ~= nil, reopened_text)


end
