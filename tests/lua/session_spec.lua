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
assert(lines[6] == "  README.md  +2 -1 [1]", vim.inspect(lines))

vim.api.nvim_set_current_win(review.panel.win)
vim.api.nvim_win_set_cursor(review.panel.win, { 6, 0 })
panel_view.open_file_under_cursor(review)
assert(vim.api.nvim_get_current_win() ~= review.panel.win, "the file opens beside the panel")
assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/README.md"), "the worktree file opens")

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

local refreshed_conversation = false
local closed_views = {}
package.loaded["jpr.views.conversation"] = {
    refresh = function(target)
        if target == review then
            refreshed_conversation = true
        end
    end,
    close = function(target)
        if target == review then
            closed_views.conversation = true
        end
    end,
}
package.loaded["jpr.comments.popup"] = {
    close = function(target)
        if target == review then
            closed_views.popup = true
        end
    end,
}
package.loaded["jpr.comments.compose"] = {
    close = function(target)
        if target == review then
            closed_views.compose = true
        end
    end,
}
package.loaded["jpr.views.submit"] = {
    close = function(target)
        if target == review then
            closed_views.submit = true
        end
    end,
}
session.on_notification(review, "event", { type = "threadsChanged", view = review.view })
assert(refreshed_conversation, "threadsChanged refreshes loaded conversation view")

local tabs = #vim.api.nvim_list_tabpages()
session.close_current()
assert(session.current() == nil, "closing forgets the session")
assert(#vim.api.nvim_list_tabpages() == tabs - 1, "closing closes the tab")
assert(closed_views.conversation and closed_views.popup and closed_views.compose and closed_views.submit, "teardown closes loaded optional M3 views")
package.loaded["jpr.views.conversation"] = nil
package.loaded["jpr.comments.popup"] = nil
package.loaded["jpr.comments.compose"] = nil
package.loaded["jpr.views.submit"] = nil

print("session_spec: ok")
