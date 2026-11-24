-- Text from GitHub (file names, titles, gh's errors) never runs as a command
-- and never breaks the panel.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local session = require("jpr.session")
local panel_view = require("jpr.views.panel")

jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

-- A worktree whose own path needs escaping for :tcd.
local worktree = vim.fn.tempname() .. " 100%#"
vim.fn.mkdir(worktree, "p")
local hostile = {
    "+lua\\ vim.g.pwned=true README",
    "README",
    "100%.md",
    "a#b.md",
    "with space.md",
    "~",
    "-",
}
for _, name in ipairs(hostile) do
    vim.fn.writefile({ name }, worktree .. "/" .. name)
end

session.start({ worktree = worktree, repo = "octo/widgets", number = 21 })
local review = assert(session.current(), "the session starts in a worktree whose path holds % and #")
assert(vim.fn.resolve(vim.fn.getcwd(-1, 0)) == vim.fn.resolve(worktree), ":tcd reaches the worktree: " .. vim.fn.getcwd(-1, 0))
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "the engine synced")

local files = {}
for _, name in ipairs(hostile) do
    files[#files + 1] = { path = name, additions = 1, deletions = 0, viewed = "UNVIEWED", threads = 0 }
end
session.show(review, { pr = { number = 21, title = "Hostile" }, files = files, viewedCount = 0, threadCount = 0 })

for index, name in ipairs(hostile) do
    vim.api.nvim_set_current_win(review.panel.win)
    vim.api.nvim_win_set_cursor(review.panel.win, { 6 + index, 0 })
    panel_view.open_file_under_cursor(review)
    local opened = vim.api.nvim_buf_get_name(0)
    assert(vim.g.pwned == nil, "opening " .. name .. " ran code")
    assert(vim.fn.resolve(opened) == vim.fn.resolve(worktree .. "/" .. name), ("%q opens itself, not %q"):format(name, opened))
    assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == name, "the file's own content is shown for " .. name)
end

-- A multi-line error or name is drawn on one line instead of raising.
local multi_line = "error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com\n"
session.on_notification(review, "event", { type = "syncFailed", message = multi_line })
local lines = vim.api.nvim_buf_get_lines(review.panel.buf, 0, -1, false)
assert(
    lines[4] == "sync failed: error connecting to api.github.com check your internet connection or https://githubstatus.com",
    vim.inspect(lines)
)

session.show(review, {
    pr = { number = 21, title = "Two\nlines" },
    files = { { path = "new\nline.md", additions = 1, deletions = 0, viewed = "UNVIEWED", threads = 0 } },
    viewedCount = 0,
    threadCount = 0,
})
lines = vim.api.nvim_buf_get_lines(review.panel.buf, 0, -1, false)
assert(lines[1] == "#21 Two lines" and lines[7] == "  new line.md  +1 -0", vim.inspect(lines))
assert(review.panel.paths[7] == "new\nline.md", "the real path is kept for opening")

session.close_current()
print("untrusted_text_spec: ok")
