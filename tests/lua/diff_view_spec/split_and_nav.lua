return function(context)
    local root = context.root
    local jpr = require("jpr")
    local session = require("jpr.session")
    local main_window = require("jpr.views.main_window")
    local view_mode = require("jpr.view_mode")
    local diff_view = require("jpr.views.diff")
    local worktree = context.worktree
    local review = context.review
    local win = context.win
    local buf = context.buf
    local namespace = context.namespace
    local count_overlay_marks = context.count_overlay_marks
    local report_error = context.report_error

-- Split: a read-only base window opens on the left, both in diff mode.
main_window.edit(review, win, "README.md", 1)
assert(vim.wait(3000, function()
    return count_overlay_marks(buf) > 0
end), "the overlay is back")
vim.api.nvim_set_current_win(win)
vim.api.nvim_set_option_value("winhighlight", "Normal:NormalFloat", { win = win, scope = "local" })
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
local expected_diff_winhighlight = "DiffAdd:JprDiffAdd,DiffChange:JprDiffAdd,DiffDelete:JprDiffDelete,DiffText:JprDiffAddText"
assert(
    vim.wo[base].winhighlight:find(expected_diff_winhighlight, 1, true) ~= nil,
    "base window maps split diff highlights: " .. vim.wo[base].winhighlight
)
assert(
    vim.wo[win].winhighlight:find("Normal:NormalFloat", 1, true) ~= nil,
    "existing winhighlight is preserved: " .. vim.wo[win].winhighlight
)
assert(
    vim.wo[win].winhighlight:find(expected_diff_winhighlight, 1, true) ~= nil,
    "file window maps split diff highlights: " .. vim.wo[win].winhighlight
)
assert(count_overlay_marks(buf) == 0, "the unified overlay is gone")
assert(main_window.find(review) == win, "the base window is a side window")

-- Leaving the file closes its base window and turns diff mode off.
vim.cmd.edit(vim.fn.fnameescape(worktree .. "/OTHER.md"))
assert(vim.wait(3000, function()
    return not vim.api.nvim_win_is_valid(base)
end), "the base window closes")
assert(not vim.wo[win].diff, "diff mode is off")
assert(vim.wo[win].winhighlight == "Normal:NormalFloat", "original winhighlight is restored: " .. vim.wo[win].winhighlight)
vim.api.nvim_set_option_value("winhighlight", "", { win = win, scope = "local" })

-- An engine that stops mid-review restarts once and falls back to read-only on
-- a second crash while keeping the base window open; closing the tab cleans up.
main_window.edit(review, win, "README.md", 1)
assert(vim.wait(3000, function()
    return find_base_window(review.tab) ~= nil
end), "the base window opens again")
base = find_base_window(review.tab)
local group_name = ("jpr-diff-%d"):format(review.tab)
local report_warn = jpr.warn
jpr.error = function() end
jpr.warn = function() end
local first_client = review.client
first_client:stop()
assert(vim.wait(3000, function()
    return review.has_restarted == true and review.client ~= nil and review.client ~= first_client
end), "first stop restarts the engine")
review.client:stop()
assert(vim.wait(3000, function()
    return review.is_read_only == true and review.client == nil
end), "second stop switches the session to read-only")
jpr.error = report_error
jpr.warn = report_warn
assert(vim.api.nvim_tabpage_is_valid(review.tab) and vim.api.nvim_win_is_valid(base), "read-only keeps the tab and base window")
vim.cmd.tabclose()
assert(review.diff == nil, "closing the tab lets go of its diffs")
assert(not vim.api.nvim_win_is_valid(base), "the base window closed")
assert(not pcall(vim.api.nvim_get_autocmds, { group = group_name }), "the autocommands are gone")

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

-- gF returns to the full branch diff view from a changed file or unchanged worktree file,
-- and gv toggles viewed in single-file editor view (advancing to the next unviewed file
-- when marking viewed, or returning to full diff when all files are viewed, and staying
-- in place when unmarking).
dofile(root .. "/plugin/jpr.lua")
local nav_set_viewed_file = vim.fn.tempname()
vim.env.FAKE_ENGINE_SET_VIEWED_FILE = nav_set_viewed_file
vim.fn.writefile({ "second file" }, worktree .. "/OTHER.md")
vim.fn.writefile({ "helper" }, worktree .. "/helper.txt")
session.start({ worktree = worktree, repo = "octo/widgets", number = 9 })
local nav_review = session.current()
assert(vim.wait(3000, function()
    return nav_review.stream ~= nil and nav_review.stream.layout ~= nil
end), "nav review syncs and opens stream")

local two_file_view = {
    pr = nav_review.view.pr,
    files = {
        { path = "README.md", additions = 2, deletions = 1, viewed = "UNVIEWED", threads = 0 },
        { path = "OTHER.md", additions = 1, deletions = 0, viewed = "UNVIEWED", threads = 0 },
    },
    tree = {
        { depth = 0, name = "OTHER.md", file = 1 },
        { depth = 0, name = "README.md", file = 0 },
    },
    viewedCount = 0,
    threadCount = 0,
    draftCount = 0,
    conversationCount = 0,
    sync = { state = "synced", at = 1 },
}
nav_review.view = two_file_view
local nav_main = main_window.find(nav_review)
main_window.edit(nav_review, nav_main, "OTHER.md", 1)
assert(vim.wait(3000, function()
    local maps = vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(nav_main), "n")
    for _, mapping in ipairs(maps) do
        if mapping.lhs == "gv" then
            return true
        end
    end
    return false
end), "gv and gF are bound on changed file buffers")

-- Marking OTHER.md viewed via gv advances the main window to README.md.
local other_viewed = vim.deepcopy(two_file_view)
other_viewed.files[2].viewed = "VIEWED"
other_viewed.viewedCount = 1
vim.fn.writefile({ vim.json.encode(other_viewed) }, nav_set_viewed_file)
vim.api.nvim_set_current_win(nav_main)
jpr.action("toggle_viewed")
assert(vim.wait(3000, function()
    return vim.fn.resolve(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(nav_main)))
        == vim.fn.resolve(worktree .. "/README.md")
end), "gv on OTHER.md advances to next unviewed file README.md")

-- Unmarking a viewed file stays in that file buffer.
main_window.edit(nav_review, nav_main, "OTHER.md", 1)
vim.fn.writefile({ vim.json.encode(two_file_view) }, nav_set_viewed_file)
jpr.action("toggle_viewed")
assert(vim.wait(3000, function()
    return nav_review.view.viewedCount == 0
end), "gv on viewed OTHER.md unmarks it")
assert(
    vim.fn.resolve(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(nav_main)))
        == vim.fn.resolve(worktree .. "/OTHER.md"),
    "unmarking OTHER.md keeps focus on OTHER.md"
)

-- Opening an unchanged worktree file in the review tab still gets tab-aware gF.
vim.cmd.edit(vim.fn.fnameescape(worktree .. "/helper.txt"))
diff_view.reconcile(nav_review)
local helper_has_gf = false
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(nav_main), "n")) do
    if mapping.lhs == "gF" then
        helper_has_gf = true
    end
end
assert(helper_has_gf, "unchanged worktree file in review tab gets tab-aware gF")

-- gF (full_diff action) returns to and focuses the full branch diff view.
jpr.action("full_diff")
assert(vim.wait(3000, function()
    return require("jpr.views.stream").is_visible(nav_review)
        and vim.api.nvim_get_current_buf() == nav_review.stream.buffers.main
end), "gF returns to and focuses the full branch diff stream")

os.remove(nav_set_viewed_file)
vim.env.FAKE_ENGINE_SET_VIEWED_FILE = nil
session.close_current()

end
