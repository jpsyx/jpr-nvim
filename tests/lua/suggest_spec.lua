local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local view_mode = require("jpr.view_mode")
local stream_view = require("jpr.views.stream")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")
vim.fn.writefile({ "other" }, worktree .. "/OTHER.md")

local outside_file = vim.fn.tempname()
vim.fn.writefile({ "outside" }, outside_file)

local function read_bytes(path)
    local handle = assert(io.open(path, "rb"))
    local content = handle:read("*a")
    handle:close()
    return content
end

local function write_bytes(path, content)
    local handle = assert(io.open(path, "wb"))
    handle:write(content)
    handle:close()
end

local function find_tab_win_by_buf_name(tab, substring)
    for _, candidate_win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(candidate_win))
        if name:find(substring, 1, true) ~= nil then
            return candidate_win
        end
    end
    return nil
end

local errors = {}
local original_error, original_info = jpr.error, jpr.info
jpr.error = function(message)
    errors[#errors + 1] = message
end
jpr.info = function() end

-- 1. Without an active session, suggest_current errors cleanly.
session.suggest_current()
assert(#errors == 1 and errors[1]:find("no pull request", 1, true), vim.inspect(errors))
errors = {}

-- Start session and sync with fake_engine.sh.
session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "the review syncs")

local original_request = review.client.request

-- 2. :Jpr suggest refuses non-changed and non-worktree buffers.
local main_win = main_window.find(review)
vim.api.nvim_set_current_win(main_win)
vim.cmd.edit(vim.fn.fnameescape(worktree .. "/OTHER.md"))
errors = {}
session.suggest_current()
assert(#errors == 1, "suggest refuses unchanged file in worktree")

vim.cmd.edit(vim.fn.fnameescape(outside_file))
errors = {}
session.suggest_current()
assert(#errors == 1, "suggest refuses file outside worktree")

-- 3. :Jpr suggest on unsaved buffer edit (modified = true):
--    sends suggestFromEdit, replaces buffer with revertedText, clears modified when matching disk,
--    and does NOT rewrite disk.
main_window.edit(review, main_win, "README.md", 1)
local readme_buf = vim.api.nvim_win_get_buf(main_win)
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "fileDiff") >= 1
end), "diff applied on README.md")

vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "hello", "better" })
vim.bo[readme_buf].modified = true
vim.api.nvim_win_set_cursor(main_win, { 2, 0 })

local writefile_calls = 0
local original_writefile = vim.fn.writefile
vim.fn.writefile = function(...)
    writefile_calls = writefile_calls + 1
    return original_writefile(...)
end

local suggest_before = #helpers.read_requests(log, "suggestFromEdit")
session.suggest_current()
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "suggestFromEdit") == suggest_before + 1
        and vim.bo[readme_buf].modified == false
end), "unsaved single-hunk suggest reverts buffer and clears modified")
vim.fn.writefile = original_writefile

local sent_suggest = helpers.read_requests(log, "suggestFromEdit")[suggest_before + 1].params
assert(sent_suggest.path == "README.md", vim.inspect(sent_suggest))
assert(sent_suggest.editedText == "hello\nbetter\n", vim.inspect(sent_suggest))
assert(sent_suggest.cursorLine == 2, vim.inspect(sent_suggest))
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(readme_buf, 0, -1, false), { "hello", "new" }))
assert(writefile_calls == 0, "did not unnecessarily rewrite disk when buffer already had modified=true")

-- 4. :Jpr suggest on saved buffer edit (modified = false): writes revertedText back to disk and keeps modified = false.
vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "hello", "saved_edit" })
vim.cmd("silent write")
assert(vim.bo[readme_buf].modified == false, "saved edit has modified = false")
assert(read_bytes(worktree .. "/README.md") == "hello\nsaved_edit\n")
vim.api.nvim_win_set_cursor(main_win, { 2, 0 })

session.suggest_current()
assert(vim.wait(3000, function()
    return read_bytes(worktree .. "/README.md") == "hello\nnew\n"
end), "saved edit writes revertedText back to disk")
assert(vim.bo[readme_buf].modified == false, "saved edit keeps modified = false")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(readme_buf, 0, -1, false), { "hello", "new" }))

-- 5. Two unsaved edits: reverting hunk 1 preserves hunk 2 and keeps modified = true.
write_bytes(worktree .. "/README.md", "line1\nline2\nline3\n")
vim.cmd("silent edit!")
vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "edit1", "line2", "edit3" })
vim.bo[readme_buf].modified = true
vim.api.nvim_win_set_cursor(main_win, { 1, 0 })

review.client.request = function(client_self, method, params, callback)
    if method == "suggestFromEdit" then
        vim.schedule(function()
            callback(nil, {
                suggested = {
                    anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 1, ["end"] = 1 },
                    suggestionBody = "```suggestion\nedit1\n```",
                    revertedText = "line1\nline2\nedit3\n",
                },
            })
        end)
        return
    end
    return original_request(client_self, method, params, callback)
end

session.suggest_current()
assert(vim.wait(3000, function()
    local lines = vim.api.nvim_buf_get_lines(readme_buf, 0, -1, false)
    return lines[1] == "line1"
end), "hunk 1 reverted")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(readme_buf, 0, -1, false), { "line1", "line2", "edit3" }),
    "hunk 2 preserved")
assert(vim.bo[readme_buf].modified == true, "remaining unsaved hunk keeps modified = true")
assert(read_bytes(worktree .. "/README.md") == "line1\nline2\nline3\n", "disk untouched for unsaved multi-hunk")

-- 6. Trailing newline preservation: file WITHOUT trailing newline (saved and unsaved).
write_bytes(worktree .. "/README.md", "alpha\nbeta")
vim.cmd("silent edit!")
assert(vim.bo[readme_buf].eol == false, "loaded noeol file has eol = false")
vim.bo[readme_buf].fixeol = false
vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "alpha", "gamma" })
vim.cmd("silent write")
assert(read_bytes(worktree .. "/README.md") == "alpha\ngamma", "disk written without trailing newline")
vim.api.nvim_win_set_cursor(main_win, { 2, 0 })

local seen_edited_noeol
review.client.request = function(client_self, method, params, callback)
    if method == "suggestFromEdit" then
        seen_edited_noeol = params.editedText
        vim.schedule(function()
            callback(nil, {
                suggested = {
                    anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 },
                    suggestionBody = "```suggestion\ngamma\n```",
                    revertedText = "alpha\nbeta",
                },
            })
        end)
        return
    end
    return original_request(client_self, method, params, callback)
end

session.suggest_current()
assert(vim.wait(3000, function()
    return read_bytes(worktree .. "/README.md") == "alpha\nbeta"
end), "reverted noeol file written without trailing newline")
assert(seen_edited_noeol == "alpha\ngamma", "editedText respected eol=false: " .. vim.inspect(seen_edited_noeol))
assert(vim.bo[readme_buf].eol == false, "buffer keeps eol = false")
assert(vim.bo[readme_buf].modified == false, "noeol saved revert keeps modified = false")

vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "alpha", "unsaved" })
vim.bo[readme_buf].modified = true
session.suggest_current()
assert(vim.wait(3000, function()
    return vim.bo[readme_buf].modified == false
end), "unsaved noeol revert matching disk clears modified")
assert(read_bytes(worktree .. "/README.md") == "alpha\nbeta")

-- 7. Split mode suggest redraws threads without tearing down the split.
review.client.request = original_request
write_bytes(worktree .. "/README.md", "hello\nnew\n")
vim.cmd("silent edit!")
view_mode.set("split")
require("jpr.views.diff").redraw_all(review)
assert(vim.wait(3000, function()
    return find_tab_win_by_buf_name(review.tab, "jpr://base/7/README.md") ~= nil
end), "split diff active for suggest")
local split_base_win = find_tab_win_by_buf_name(review.tab, "jpr://base/7/README.md")
vim.api.nvim_set_current_win(main_win)
vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "hello", "better" })
vim.bo[readme_buf].modified = true
vim.api.nvim_win_set_cursor(main_win, { 2, 0 })
local file_diffs_before_split_suggest = #helpers.read_requests(log, "fileDiff")
session.suggest_current()
assert(vim.wait(3000, function()
    return vim.bo[readme_buf].modified == false and #helpers.read_requests(log, "fileDiff") > file_diffs_before_split_suggest
end), "split mode suggest reverts buffer and redraws threads")
assert(vim.api.nvim_win_is_valid(split_base_win), "split base_win stays open")
view_mode.set("unified")

-- 8. Stale changedtick guard: editing buffer while suggestFromEdit is in flight drops callback.
local pending_suggest_callback
review.client.request = function(client_self, method, params, callback)
    if method == "suggestFromEdit" then
        pending_suggest_callback = callback
        return
    end
    return original_request(client_self, method, params, callback)
end
vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "alpha", "first_edit" })
session.suggest_current()
assert(pending_suggest_callback ~= nil, "captured in-flight suggestFromEdit")
vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "alpha", "newer_edit" })
pending_suggest_callback(nil, {
    suggested = {
        anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 },
        suggestionBody = "```suggestion\nfirst_edit\n```",
        revertedText = "alpha\nbeta",
    },
})
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(readme_buf, 0, -1, false), { "alpha", "newer_edit" }),
    "stale changedtick callback does not overwrite newer buffer edits")

review.client.request = original_request

-- 9. Visible stream window: :Jpr suggest on a saved edit refreshes the visible stream buffer with reverted disk content.
view_mode.set("unified")
vim.bo[readme_buf].modified = false
write_bytes(worktree .. "/README.md", "hello\nsaved_edit\n")
review.client.request = function(client_self, method, params, callback)
    if method == "stream" then
        local disk_lines = vim.split(read_bytes(worktree .. "/README.md"):gsub("\n$", ""), "\n", { plain = true })
        local second_line = disk_lines[2] or ""
        vim.schedule(function()
            callback(nil, {
                mode = "unified",
                rows = {
                    { kind = "file", path = "README.md", additions = 1, deletions = 0, viewed = "UNVIEWED", folded = false },
                    { kind = "hunk", path = "README.md", header = "@@ -1,2 +1,2 @@", target = 1 },
                    {
                        kind = "line",
                        path = "README.md",
                        left = nil,
                        right = { line = 2, text = second_line, change = "added", words = {} },
                        target = 2,
                    },
                },
            })
        end)
        return
    end
    return original_request(client_self, method, params, callback)
end

stream_view.show(review, { focus = true })
local stream_win
assert(vim.wait(3000, function()
    stream_win = find_tab_win_by_buf_name(review.tab, "jpr://stream/7")
    if not stream_win then
        return false
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(stream_win), 0, -1, false), "\n")
    return text:find("saved_edit", 1, true) ~= nil
end), "stream initially shows saved_edit from disk")

vim.cmd("vsplit " .. vim.fn.fnameescape(worktree .. "/README.md"))
local edit_win = vim.api.nvim_get_current_win()
local edit_buf = vim.api.nvim_win_get_buf(edit_win)
vim.cmd("silent edit!")
assert(vim.bo[edit_buf].modified == false, "saved edit buffer starts unmodified")
vim.api.nvim_win_set_cursor(edit_win, { 2, 0 })

session.suggest_current()
assert(vim.wait(3000, function()
    if read_bytes(worktree .. "/README.md") ~= "hello\nnew\n" then
        return false
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(stream_win), 0, -1, false), "\n")
    return text:find("new", 1, true) ~= nil and text:find("saved_edit", 1, true) == nil
end), "suggest refreshes visible stream buffer with reverted disk content")

review.client.request = original_request
jpr.error = original_error
jpr.info = original_info
session.close_current()

print("suggest_spec: ok")
