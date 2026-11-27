local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local session = require("jpr.session")
local panel_view = require("jpr.views.panel")
local fixture = root .. "/tests/lua/fixtures/fake_engine.sh"

jpr.setup({ binary = fixture })
assert(vim.deep_equal(session.checkout_args(7), { fixture, "checkout", "--pr", "7" }), "checkout args")
jpr.setup({ binary = fixture, worktree_cmd = "wt pr {n}" })
assert(
    vim.deep_equal(session.checkout_args(7), { fixture, "checkout", "--pr", "7", "--worktree-cmd", "wt pr {n}" }),
    "checkout args with a worktree command"
)
assert(
    vim.deep_equal(
        session.checkout_args(7, "octo/gadgets"),
        { fixture, "checkout", "--pr", "7", "--repo", "octo/gadgets", "--worktree-cmd", "wt pr {n}" }
    ),
    "checkout args with the repository a URL named"
)

-- Only a moved head or base commit redraws every diff.
local pr = { headSha = "head1", baseSha = "base1" }
assert(not session.have_commits_changed({ pr = pr }, { pr = vim.deepcopy(pr) }), "the same commits")
assert(session.have_commits_changed({ pr = pr }, { pr = { headSha = "head2", baseSha = "base1" } }), "a moved head")
assert(session.have_commits_changed({ pr = pr }, { pr = { headSha = "head1", baseSha = "base2" } }), "a moved base")
assert(not session.have_commits_changed({}, { pr = pr }), "the first view with a pull request")
assert(not session.have_commits_changed(nil, { pr = pr }), "no previous view")
assert(not session.have_commits_changed({ pr = pr }, {}), "a view without a pull request")

local info = session.parse_checkout('Checking out...\n{"worktree":"/tmp/w","repo":"octo/widgets","number":7,"title":"T"}\n')
assert(info.worktree == "/tmp/w" and info.repo == "octo/widgets" and info.number == 7, vim.inspect(info))
local missing, err = session.parse_checkout("")
assert(missing == nil and err:find("printed nothing", 1, true), "empty checkout output")
local bad, bad_err = session.parse_checkout("{}")
assert(bad == nil and bad_err:find("unexpected", 1, true), "checkout output without a worktree")

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello" }, worktree .. "/README.md")

session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(review and review.number == 7, "the tab has a session")
assert(vim.fn.resolve(vim.fn.getcwd(-1, 0)) == vim.fn.resolve(worktree), "the tab's directory is the worktree")

assert(vim.wait(3000, function()
    return vim.api.nvim_buf_get_lines(review.panel.buf, 0, 1, false)[1] == "#7 Fix the widget"
end), "the panel shows the synced pull request")
local lines = vim.api.nvim_buf_get_lines(review.panel.buf, 0, -1, false)
assert(lines[9] == "  README.md  +2 -1 [1]", vim.inspect(lines))

assert(jpr.defaults.agent == "claude", "default agent")
assert(jpr.defaults.claude_cmd == "claude", "default claude_cmd")
assert(jpr.defaults.claude_model == nil, "default claude_model omits --model")
assert(jpr.defaults.claude_effort == nil, "default claude_effort omits --effort")
assert(jpr.defaults.codex_cmd == "codex", "default codex_cmd")
assert(jpr.defaults.agent_direction == "vertical", "default agent_direction")
assert(jpr.defaults.agent_width == nil, "default agent_width is proportional nil")
assert(jpr.defaults.agent_load_toggleterm == true, "default agent_load_toggleterm")

jpr.define_highlights()
assert(vim.fn.hlexists("JprThreadLocal") == 1, "JprThreadLocal highlight group exists")

local completed = jpr.complete("", "Jpr ")
for _, subcommand in ipairs({ "agent", "send", "prepass" }) do
    assert(vim.tbl_contains(completed, subcommand), ":Jpr completion includes " .. subcommand)
end

vim.api.nvim_set_current_win(review.panel.win)
vim.api.nvim_win_set_cursor(review.panel.win, { 9, 0 })
panel_view.open_file_under_cursor(review)
assert(vim.api.nvim_get_current_win() ~= review.panel.win, "the file opens beside the panel")
assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/README.md"), "the worktree file opens")

local readme_buffer = vim.api.nvim_get_current_buf()
local diff_namespace = vim.api.nvim_create_namespace("jpr-diff")
assert(vim.wait(3000, function()
    return #vim.api.nvim_buf_get_extmarks(readme_buffer, diff_namespace, 0, -1, {}) > 0
end), "initial diff overlay draws on README.md")
assert(#vim.api.nvim_buf_get_extmarks(readme_buffer, diff_namespace, { 1, 0 }, { 1, -1 }, {}) == 0, "line 2 is not in buffer yet")

vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")
local files_changed_view = vim.deepcopy(review.view)
files_changed_view.localUnsentCount = 1
session.on_notification(review, "event", {
    type = "filesChanged",
    paths = { "README.md" },
    view = files_changed_view,
})
assert(
    vim.deep_equal(vim.api.nvim_buf_get_lines(readme_buffer, 0, -1, false), { "hello", "new" }),
    "filesChanged reloads README.md via checktime"
)
assert(review.view.localUnsentCount == 1, "filesChanged updates session.view")
assert(vim.wait(3000, function()
    return #vim.api.nvim_buf_get_extmarks(readme_buffer, diff_namespace, { 1, 0 }, { 1, -1 }, {}) > 0
end), "filesChanged refreshes the diff overlay")

local agent_round_view = vim.deepcopy(review.view)
agent_round_view.localUnsentCount = 0
session.on_notification(review, "event", {
    type = "agentRound",
    round = { round = 1, kind = "send", threadIds = { "loc-1" }, prompt = "hi", sentAt = 1 },
    view = agent_round_view,
})
assert(review.view.localUnsentCount == 0, "agentRound updates session.view")

-- :Jpr open refocuses the tab only for the same repository.
local review_tab = vim.api.nvim_get_current_tabpage()
jpr.setup({ binary = worktree .. "/missing-engine" })
local notified = {}
vim.notify = function(message)
    notified[#notified + 1] = message
end
vim.cmd("tabfirst")
local first_tab = vim.api.nvim_get_current_tabpage()
session.open(7, "octo/gadgets")
assert(vim.api.nvim_get_current_tabpage() == first_tab, "another repository's PR 7 does not refocus octo/widgets#7")
assert(#notified == 1, "it goes on to check the PR out instead: " .. vim.inspect(notified))
session.open(7, "Octo/Widgets")
assert(vim.api.nvim_get_current_tabpage() == review_tab, "the same repository, in any case, refocuses")
vim.cmd("tabfirst")
session.open(7)
assert(vim.api.nvim_get_current_tabpage() == review_tab, "a bare number refocuses")
jpr.setup({ binary = fixture })

local helpers = dofile(root .. "/tests/lua/support/helpers.lua")
local conversation = require("jpr.views.conversation")
local popup = require("jpr.comments.popup")
local compose = require("jpr.comments.compose")
local submit = require("jpr.views.submit")

conversation.show(review)
local main_win = require("jpr.views.main_window").find(review)
local conversation_buf = vim.api.nvim_win_get_buf(main_win)
assert(vim.api.nvim_buf_get_name(conversation_buf) == "jpr://conversation/7", "conversation buffer opens in main window")
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n")
    return text:find("Overall looks clean!", 1, true) ~= nil
end), "conversation buffer renders initial PR comment")

local tick_before_notify = vim.api.nvim_buf_get_changedtick(conversation_buf)
session.on_notification(review, "event", { type = "threadsChanged", view = review.view })
assert(vim.wait(3000, function()
    return vim.api.nvim_buf_get_changedtick(conversation_buf) > tick_before_notify
end), "threadsChanged refreshes the visible conversation buffer")

popup.open(review, {
    {
        threadId = "T1",
        displayLine = 2,
        kind = "published",
        state = "open",
        messages = { { id = "M1", author = "alice", body = "hi", sync = "published" } },
    },
})
local popup_win = assert(helpers.find_floating_win("Review Thread"), "popup window opens")

compose.open_new(review, { kind = "pr", side = "RIGHT" })
local compose_win = assert(helpers.find_floating_win("PR Conversation"), "compose window opens")

submit.open(review)
assert(vim.wait(3000, function()
    return helpers.find_floating_win("Submit Review") ~= nil
end), "submit modal window opens")
local submit_win = helpers.find_floating_win("Submit Review")

local tabs = #vim.api.nvim_list_tabpages()
session.close_current()
assert(session.current() == nil, "closing forgets the session")
assert(#vim.api.nvim_list_tabpages() == tabs - 1, "closing closes the tab")
assert(not vim.api.nvim_buf_is_valid(conversation_buf), "closing wipes the conversation buffer")
assert(not vim.api.nvim_win_is_valid(popup_win), "closing closes the thread popup window")
assert(not vim.api.nvim_win_is_valid(compose_win), "closing closes the comment compose window")
assert(not vim.api.nvim_win_is_valid(submit_win), "closing closes the review submit modal")

print("session_spec: ok")
