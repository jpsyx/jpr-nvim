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

local context = {
    root = root,
    review = review,
    worktree = worktree,
    log = log,
    press = press,
    PANEL_OPTIONS = PANEL_OPTIONS,
    globals_before = globals_before,
    set_viewed_payload = set_viewed_payload,
    stream_payload = stream_payload,
    collapsed_payload = collapsed_payload,
    find_sent_requests = find_sent_requests,
    find_log_lines = find_log_lines,
}

dofile(root .. "/tests/lua/panel_view_spec/basics.lua")(context)
dofile(root .. "/tests/lua/panel_view_spec/navigation_and_mouse.lua")(context)
dofile(root .. "/tests/lua/panel_view_spec/comments_and_filter.lua")(context)

os.remove(stream_payload)
os.remove(set_viewed_payload)
os.remove(collapsed_payload)
vim.env.FAKE_ENGINE_STREAM_FILE = nil
vim.env.FAKE_ENGINE_SET_VIEWED_FILE = nil
vim.env.FAKE_ENGINE_SET_COLLAPSED_FILE = nil

session.close_current()
print("panel_view_spec: ok")
