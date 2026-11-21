local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local view_mode = require("jpr.view_mode")
local mentions = require("jpr.comments.mentions")

view_mode.path = vim.fn.tempname()
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")

-- 1. Pure @mention helpers: find_start and create_items_from_candidates.
assert(mentions.find_start("hello @pa") == 6, "find_start returns 0-based @ offset")
assert(mentions.find_start("@pa") == 0, "find_start at column 0")
assert(mentions.find_start("hello ") == -1, "find_start returns -1 when not in mention")
assert(mentions.find_start("hello @pa world") == -1, "find_start returns -1 after space")

local mixed_candidates = {
    { login = "paula", isParticipant = false },
    { login = "pablo", isParticipant = true },
    { login = "Patrick", isParticipant = true },
    { login = "bob", isParticipant = false },
}
local matched = mentions.create_items_from_candidates(mixed_candidates, "@PA")
assert(vim.deep_equal(matched, {
    { word = "@pablo", abbr = "@pablo", menu = "[PR]", icase = 1 },
    { word = "@Patrick", abbr = "@Patrick", menu = "[PR]", icase = 1 },
    { word = "@paula", abbr = "@paula", menu = "[repo]", icase = 1 },
}), "create_items_from_candidates keeps participants first and matches case-insensitively: " .. vim.inspect(matched))

local single_matched = mentions.create_items_from_candidates({ { login = "pablo", isParticipant = true } }, "@pa")
assert(vim.deep_equal(single_matched, {
    { word = "@pablo", abbr = "@pablo", menu = "[PR]", icase = 1 },
}), "create_items_from_candidates matches exact expected item shape")

-- Start session with fake_engine.sh.
session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "session syncs")

-- 2. mentions.attach + mentions.omnifunc(1, "") and mentions.omnifunc(0, "@a").
local omnifunc_buf = vim.api.nvim_create_buf(false, true)
local omnifunc_win = vim.api.nvim_open_win(omnifunc_buf, true, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 40,
    height = 5,
})
vim.api.nvim_buf_set_lines(omnifunc_buf, 0, -1, false, { "hello @a" })
vim.api.nvim_win_set_cursor(omnifunc_win, { 1, 7 })
mentions.attach(review, omnifunc_buf)
assert(vim.bo[omnifunc_buf].omnifunc == "v:lua.require'jpr.comments.mentions'.omnifunc", "omnifunc wired")
assert(vim.wait(3000, function()
    local items = mentions.omnifunc(0, "@a")
    return #items == 1 and items[1].word == "@alice"
end), "mentions.omnifunc(0, '@a') returns synced candidates after attach")
vim.api.nvim_buf_set_lines(omnifunc_buf, 0, -1, false, { "hello @" })
local start_col
vim.keymap.set("i", "<F2>", function()
    start_col = mentions.omnifunc(1, "")
end, { buffer = omnifunc_buf })
helpers.press_key("A<F2><Esc>")
assert(start_col == 6, "mentions.omnifunc(1, '') returns @ column: " .. tostring(start_col))
vim.api.nvim_win_close(omnifunc_win, true)
vim.api.nvim_buf_delete(omnifunc_buf, { force = true })

-- 3. mentions.attach ignores stale/closing callbacks without erroring.
local pending_mentions_callback
local original_client_request = review.client.request
review.client.request = function(client_self, method, params, callback)
    if method == "mentions" then
        pending_mentions_callback = callback
        return
    end
    return original_client_request(client_self, method, params, callback)
end
local stale_omnifunc_buf = vim.api.nvim_create_buf(false, true)
mentions.attach(review, stale_omnifunc_buf)
vim.api.nvim_buf_delete(stale_omnifunc_buf, { force = true })
pending_mentions_callback(nil, { candidates = { { login = "ghost", isParticipant = false } } })
assert(#mentions.omnifunc(0, "@g") == 0, "wiped buffer mentions callback does not clobber active candidates")
review.client.request = original_client_request

session.close_current()
print("mentions_spec: ok")
