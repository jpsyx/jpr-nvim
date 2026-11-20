local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local view_mode = require("jpr.view_mode")
local diff_view = require("jpr.views.diff")

view_mode.path = vim.fn.tempname()
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })
local request_log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = request_log
local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")
vim.fn.writefile({ "untouched" }, worktree .. "/OTHER.md")

--- How many requests the plugin sent that hold every one of `needles`.
local function count_requests(...)
    local needles, count = { ... }, 0
    for _, line in ipairs(vim.fn.filereadable(request_log) == 1 and vim.fn.readfile(request_log) or {}) do
        local has_all = true
        for _, needle in ipairs(needles) do
            has_all = has_all and line:find(needle, 1, true) ~= nil
        end
        count = count + (has_all and 1 or 0)
    end
    return count
end

-- name_to_relative_path resolves symlinks (a symlinked worktree too), `..`
-- and files that do not exist, so a path can be checked before it is opened.
local real_worktree = vim.fn.tempname()
vim.fn.mkdir(real_worktree .. "/docs", "p")
local linked_worktree = vim.fn.tempname()
vim.uv.fs_symlink(real_worktree, linked_worktree)
assert(diff_view.name_to_relative_path(linked_worktree, real_worktree .. "/docs") == "docs", "through a symlinked worktree")
assert(diff_view.name_to_relative_path(real_worktree, linked_worktree .. "/gone.md") == "gone.md", "a deleted file")
assert(diff_view.name_to_relative_path(real_worktree, "/etc/hosts") == nil, "a path outside")
assert(diff_view.name_to_relative_path(real_worktree, real_worktree .. "/docs/../../out.md") == nil, "`..` out of it")
assert(diff_view.name_to_relative_path(real_worktree, real_worktree .. "/no/../../out.md") == nil, "`..` after a missing directory")
assert(diff_view.name_to_relative_path(real_worktree, real_worktree .. "/no/../in.md") == "in.md", "`..` that stays inside")

session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "the review syncs")

-- A path from the pull request opens only when it is a plain path inside the
-- worktree: no symlink out, dangling or looping, no `..`, nothing absolute.
local errors = {}
local report_error = jpr.error
jpr.error = function(message)
    errors[#errors + 1] = message
end
local outside = vim.fn.tempname()
vim.fn.writefile({ "secret" }, outside)
vim.uv.fs_symlink(outside, worktree .. "/notes.md")
-- Dangling links to places that do not exist yet: a save would create them.
local not_yet = vim.fn.tempname()
vim.uv.fs_symlink(not_yet .. ".lua", worktree .. "/dangling.lua")
vim.uv.fs_symlink(not_yet, worktree .. "/dangling_dir")
vim.uv.fs_symlink(worktree .. "/loop.md", worktree .. "/loop.md")
local win = main_window.find(review)
-- By name: `:edit` reuses an empty unnamed buffer.
local start_name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
local refused = {
    "notes.md",
    "dangling.lua",
    "dangling_dir/new.txt",
    "loop.md",
    "../escape.txt",
    "no/../../escape.txt",
    "./README.md",
    outside,
}
for _, path in ipairs(refused) do
    errors = {}
    main_window.edit(review, win, path)
    assert(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == start_name, path .. " opened")
    assert(#errors == 1 and errors[1]:find("not a plain file path inside the worktree", 1, true), vim.inspect(errors))
end
assert(vim.fn.filereadable(not_yet .. ".lua") == 0 and vim.fn.isdirectory(not_yet) == 0, "nothing was created outside")
for _, path in ipairs({ "deleted.md", "gone/deeper/deleted.md" }) do
    main_window.edit(review, win, path)
    local deleted_name = vim.api.nvim_buf_get_name(0)
    assert(diff_view.name_to_relative_path(worktree, deleted_name) == path, "a deleted file opens: " .. deleted_name)
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "" }), "it is empty")
end
jpr.error = report_error

main_window.edit(review, win, "README.md", 1)
local buf = vim.api.nvim_win_get_buf(win)
local namespace = vim.api.nvim_create_namespace("jpr-diff")
local function count_overlay_marks(target)
    return #vim.api.nvim_buf_get_extmarks(target, namespace, 0, -1, {})
end

-- Unified: the added line is colored, and the removed line is drawn above it.
assert(vim.wait(3000, function()
    return count_overlay_marks(buf) > 0
end), "the overlay is drawn")
local has_added_line, removed_text = false, nil
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
    local details = mark[4]
    if mark[2] == 1 and details.line_hl_group == "JprDiffAdd" then
        has_added_line = true
    end
    if details.virt_lines then
        removed_text = details.virt_lines[1][1][1]
    end
end
assert(has_added_line, "line 2 is an added line")
assert(removed_text == "old", "the removed line sits above it: " .. vim.inspect(removed_text))

-- Two windows on one file: moving one away keeps the other's overlay.
vim.api.nvim_set_current_win(win)
vim.cmd("vsplit")
local twin = vim.api.nvim_get_current_win()
diff_view.reconcile(review)
assert(review.diff.applied[twin] ~= nil, "the second window is drawn too")
vim.cmd.edit(vim.fn.fnameescape(worktree .. "/OTHER.md"))
assert(vim.wait(3000, function()
    return review.diff.applied[twin] == nil
end), "the window that moved on is cleared")
vim.wait(100)
assert(count_overlay_marks(buf) > 0, "the other window keeps its overlay")
vim.api.nvim_win_close(twin, true)

-- A save asks for the diff again and redraws it.
vim.api.nvim_set_current_win(win)
local diffs_before_save = count_requests('"method":"fileDiff"', "README.md")
vim.cmd("silent write")
assert(vim.wait(3000, function()
    return count_requests('"method":"fileDiff"', "README.md") > diffs_before_save
end), "the save asks again")
assert(vim.wait(3000, function()
    return count_overlay_marks(buf) > 0
end), "and redraws")

-- A window closed while another tab was current is never reconciled; a save
-- from that tab drops it instead of failing on the closed window.
vim.cmd("vsplit")
local closed_win = vim.api.nvim_get_current_win()
diff_view.reconcile(review)
assert(review.diff.applied[closed_win] ~= nil, "the window is drawn")
vim.cmd("tabnew")
vim.api.nvim_win_close(closed_win, true)
vim.cmd.edit(vim.fn.fnameescape(worktree .. "/README.md"))
local saved, save_err = pcall(vim.cmd, "silent write")
assert(saved, "the save fails: " .. tostring(save_err))
assert(review.diff.applied[closed_win] == nil, "the closed window is dropped")
vim.cmd.tabclose()
vim.api.nvim_set_current_tabpage(review.tab)
vim.api.nvim_set_current_win(win)

-- A viewedChanged event redraws from its view.
session.request(review, "setViewed", { path = "README.md", viewed = true }, function() end)
assert(vim.wait(3000, function()
    return review.view.files[1].viewed == "VIEWED"
end), "the viewedChanged view is shown")

-- A failed or empty fileDiff leaves the window undrawn, and is not asked for
-- again on every BufEnter: only a toggle (or moved commits) asks again.
jpr.error = function(message)
    errors[#errors + 1] = message
end
vim.fn.writefile({ "x" }, worktree .. "/BROKEN.md")
vim.fn.writefile({ "x" }, worktree .. "/NULL.md")
local files = vim.deepcopy(review.view.files)
for _, path in ipairs({ "BROKEN.md", "NULL.md" }) do
    files[#files + 1] = { path = path, additions = 1, deletions = 0, viewed = "UNVIEWED", threads = 0 }
end
session.show(review, vim.tbl_extend("force", review.view, { files = files }))
local function count_broken_requests()
    return count_requests('"method":"fileDiff"', "BROKEN.md")
end
main_window.edit(review, win, "BROKEN.md")
assert(vim.wait(3000, function()
    return errors[#errors]:find("BROKEN.md is not at the base", 1, true) ~= nil
end), vim.inspect(errors))
assert(review.diff.applied[win] == nil, "the failed diff is not kept as drawn")
main_window.edit(review, win, "OTHER.md")
main_window.edit(review, win, "BROKEN.md")
diff_view.reconcile(review)
vim.wait(200)
assert(count_broken_requests() == 1, "asked once: " .. count_broken_requests())
session.toggle_view()
assert(vim.wait(3000, function()
    return count_broken_requests() == 2
end), "a toggle asks again: " .. count_broken_requests())
session.toggle_view()
assert(vim.wait(3000, function()
    return count_broken_requests() == 3 and review.diff.applied[win] == nil
end), "and toggling back too")
main_window.edit(review, win, "NULL.md")
assert(vim.wait(3000, function()
    return errors[#errors]:find("no diff for NULL.md", 1, true) ~= nil
end), vim.inspect(errors))
assert(review.diff.applied[win] == nil, "an empty answer is not kept as drawn")
jpr.error = report_error

-- Split: a read-only base window opens on the left, both in diff mode.
main_window.edit(review, win, "README.md", 1)
assert(vim.wait(3000, function()
    return count_overlay_marks(buf) > 0
end), "the overlay is back")
vim.api.nvim_set_current_win(win)
session.toggle_view()
assert(view_mode.get() == "split", "the view is split now")
local function find_base_window(tab)
    for _, other in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(other)):find("jpr://base/7/README.md", 1, true) then
            return other
        end
    end
end
assert(vim.wait(3000, function()
    return find_base_window(review.tab) ~= nil
end), "a base window opens")
local base = find_base_window(review.tab)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(base), 0, -1, false), { "hello", "old" }), "it shows the base")
assert(vim.wo[base].diff and vim.wo[win].diff, "both windows are in diff mode")
assert(count_overlay_marks(buf) == 0, "the unified overlay is gone")
assert(main_window.find(review) == win, "the base window is a side window")

-- Leaving the file closes its base window and turns diff mode off.
vim.cmd.edit(vim.fn.fnameescape(worktree .. "/OTHER.md"))
assert(vim.wait(3000, function()
    return not vim.api.nvim_win_is_valid(base)
end), "the base window closes")
assert(not vim.wo[win].diff, "diff mode is off")

-- An engine that stops mid-review keeps the tab, but its base windows close,
-- diff mode goes off and the autocommands are gone.
main_window.edit(review, win, "README.md", 1)
assert(vim.wait(3000, function()
    return find_base_window(review.tab) ~= nil
end), "the base window opens again")
base = find_base_window(review.tab)
local group_name = ("jpr-diff-%d"):format(review.tab)
jpr.error = function() end
review.client:stop()
assert(vim.wait(3000, function()
    return review.diff == nil
end), "the session lets go of its diffs")
jpr.error = report_error
assert(vim.api.nvim_tabpage_is_valid(review.tab), "the tab stays")
assert(not vim.api.nvim_win_is_valid(base) and not vim.wo[win].diff, "the base window closed")
assert(not pcall(vim.api.nvim_get_autocmds, { group = group_name }), "the autocommands are gone")
vim.cmd.tabclose()

session.toggle_view()
assert(view_mode.get() == "unified", "toggled back")

-- Closing a review clears its overlays.
session.start({ worktree = worktree, repo = "octo/widgets", number = 8 })
local second = session.current()
assert(vim.wait(3000, function()
    return second.view.pr ~= nil
end), "the second review syncs")
main_window.edit(second, main_window.find(second), "README.md", 1)
assert(vim.wait(3000, function()
    return count_overlay_marks(buf) > 0
end), "its overlay is drawn")
session.close_current()
assert(count_overlay_marks(buf) == 0, "closing clears the overlay")

-- Lines removed above the first line (a deleted header, or all of a deleted
-- file) are scrolled into view, and a hostile removed line reaches the screen
-- only as printable cells: Neovim draws an escape as `^[`, a CR as `^M`.
vim.cmd("tabnew")
local scratch_win = vim.api.nvim_get_current_win()
local scratch = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "first", "second", "third" })
local hostile = "\27]52;c;cHduZWQ=\7\27[2J\r\0" .. ("x"):rep(100000)
diff_view.draw_overlay(scratch, {
    added = { { line = 1, words = {} }, { line = 9, words = {} } },
    removed = { { above = 1, lines = { { text = hostile, words = {} }, { text = "gone", words = {} } } } },
}, scratch_win)
assert(vim.fn.winsaveview().topfill == 2, "the removed header shows: topfill " .. vim.fn.winsaveview().topfill)
vim.cmd("redraw")
-- Rows counted from the window's top, below any tabline.
local top_row = vim.fn.win_screenpos(scratch_win)[1]
local function screen_row(row)
    local cells = {}
    for column = 1, vim.o.columns do
        cells[#cells + 1] = vim.fn.screenstring(top_row + row - 1, column)
    end
    return table.concat(cells)
end
for row = 1, 3 do
    assert(not screen_row(row):find("[%z\1-\31\127]"), ("row %d holds a raw control character"):format(row))
end
assert(vim.startswith(screen_row(1), "^[]52;c;cHduZWQ=^G^[[2J^M^@xxx"), screen_row(1))
assert(vim.startswith(screen_row(2), "gone"), screen_row(2))
assert(vim.startswith(screen_row(3), "first"), screen_row(3))

-- An added line past the end of a buffer shortened since its last save is
-- dropped rather than piled onto the last line.
local added_lines = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(scratch, namespace, 0, -1, { details = true })) do
    if mark[4].line_hl_group == "JprDiffAdd" then
        added_lines[#added_lines + 1] = mark[2]
    end
end
assert(vim.deep_equal(added_lines, { 0 }), "only line 1 is added: " .. vim.inspect(added_lines))

print("diff_view_spec: ok")
