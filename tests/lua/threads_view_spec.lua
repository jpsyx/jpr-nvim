-- Entry point for threads view specs (split into threads_view_spec/*.lua).
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local view_mode = require("jpr.view_mode")
local threads_view = require("jpr.views.threads")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new", "tail" }, worktree .. "/README.md")

local thread_namespace = vim.api.nvim_create_namespace("jpr-threads")
local function get_thread_marks(buf)
    return vim.api.nvim_buf_get_extmarks(buf, thread_namespace, 0, -1, { details = true })
end

local function find_base_window(tab)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
        if name:find("jpr://base/7/README.md", 1, true) then
            return win
        end
    end
    return nil
end

local function create_split_thread_fixtures()
    local left_thread = {
        threadId = "T_LEFT",
        anchor = { file = "README.md", kind = "line", side = "LEFT", start = 1, ["end"] = 1 },
        displayLine = 2,
        kind = "draft",
        state = "open",
        outdated = false,
        messageCount = 1,
        firstAuthor = "bob",
        snippet = "old base line comment",
        messages = {
            { id = "M_L", author = "bob", body = "old base line comment", sync = "draft" },
        },
    }
    local right_thread = {
        threadId = "T_RIGHT",
        anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 },
        displayLine = 2,
        kind = "published",
        state = "open",
        outdated = false,
        messageCount = 1,
        firstAuthor = "alice",
        snippet = "new head line comment",
        messages = {
            { id = "M_R", author = "alice", body = "new head line comment", sync = "published" },
        },
    }
    return left_thread, right_thread
end

local function create_mock_state(review)
    local left_thread, right_thread = create_split_thread_fixtures()
    local original_request = review.client.request
    local state = {
        left_thread = left_thread,
        right_thread = right_thread,
        threads = { left_thread, right_thread },
        file_diff_calls = 0,
        original_request = original_request,
    }
    function state.install_file_diff_mock()
        review.client.request = function(client_self, method, params, callback)
            if method == "fileDiff" then
                state.file_diff_calls = state.file_diff_calls + 1
                local response_threads = vim.deepcopy(state.threads)
                vim.schedule(function()
                    callback(nil, {
                        path = "README.md",
                        binary = false,
                        baseText = "hello\nold\n",
                        added = {},
                        removed = {},
                        threads = response_threads,
                    })
                end)
                return
            end
            return original_request(client_self, method, params, callback)
        end
    end
    return state
end

session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "the review syncs")

local diff_view = require("jpr.views.diff")
local win = main_window.find(review)
main_window.edit(review, win, "README.md", 1)
vim.api.nvim_set_option_value("signcolumn", "no", { win = win, scope = "local" })
local buf = vim.api.nvim_win_get_buf(win)
local mock_state = create_mock_state(review)

local context = {
    jpr = jpr,
    session = session,
    diff_view = diff_view,
    view_mode = view_mode,
    threads_view = threads_view,
    helpers = helpers,
    log = log,
    review = review,
    win = win,
    buf = buf,
    get_thread_marks = get_thread_marks,
    find_base_window = find_base_window,
    mock_state = mock_state,
}

dofile(root .. "/tests/lua/threads_view_spec/diff_and_split.lua")(context)
dofile(root .. "/tests/lua/threads_view_spec/live_anchors.lua")(context)

review.client.request = mock_state.original_request

session.close_current()
assert(#get_thread_marks(buf) == 0, "closing session clears jpr-threads extmarks")
assert(#threads_view.threads_at_cursor(review, buf, 2) == 0, "closing session clears file buffer threads")

print("threads_view_spec: ok")
