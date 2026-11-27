local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local view_mode = require("jpr.view_mode")
local render_threads = require("jpr.render.threads")
local conversation = require("jpr.views.conversation")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")

local errors, infos = {}, {}
local original_error, original_info = jpr.error, jpr.info
jpr.error = function(message)
    errors[#errors + 1] = message
end
jpr.info = function(message)
    infos[#infos + 1] = message
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

-- 1. Without an active session, summary_current and conversation_current error cleanly.
session.summary_current()
assert(#errors == 1 and errors[1]:find("no pull request", 1, true), vim.inspect(errors))
errors = {}
session.conversation_current()
assert(#errors == 1 and errors[1]:find("no pull request", 1, true), vim.inspect(errors))
errors = {}

-- Start session and sync with fake_engine.sh.
session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "the review syncs")

-- 2. :Jpr conversation clears any diff split first and opens jpr://conversation/7 in main_window.
local win = main_window.find(review)
view_mode.set("split")
main_window.edit(review, win, "README.md", 1)
assert(vim.wait(3000, function()
    return find_tab_win_by_buf_name(review.tab, "jpr://base/7/README.md") ~= nil
end), "split diff opens base_win before conversation")
local base_win = find_tab_win_by_buf_name(review.tab, "jpr://base/7/README.md")

session.conversation_current()
assert(not vim.api.nvim_win_is_valid(base_win), "conversation closes diff base_win")

local conversation_buf = vim.api.nvim_win_get_buf(win)
assert(vim.api.nvim_buf_get_name(conversation_buf) == "jpr://conversation/7", vim.api.nvim_buf_get_name(conversation_buf))
assert(vim.bo[conversation_buf].buftype == "nofile", "conversation buftype is nofile")
assert(vim.bo[conversation_buf].filetype == "markdown", "conversation filetype is markdown")
assert(vim.bo[conversation_buf].modifiable == false, "conversation is read-only")

assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n")
    return text:find("Overall looks clean!", 1, true) ~= nil
end), "conversation loads PR comment")

local conversation_lines = vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false)
local conversation_text = table.concat(conversation_lines, "\n")
assert(conversation_text:find("#7 Fix the widget", 1, true) ~= nil, "summary title rendered: " .. conversation_text)
assert(conversation_text:find("@alice · fix/widget -> main", 1, true) ~= nil, "summary metadata rendered: " .. conversation_text)
assert(conversation_text:find("1 file changed · +2 -1 · 0/1 viewed", 1, true) ~= nil, "summary diffstat rendered: " .. conversation_text)
assert(conversation_text:find("Fixes widget crash.", 1, true) ~= nil, "PR body paragraph 1 rendered: " .. conversation_text)
assert(conversation_text:find("Includes regression test.", 1, true) ~= nil, "PR body paragraph 2 rendered: " .. conversation_text)
assert(conversation_text:find("\r", 1, true) == nil, "CRLF normalized out of PR body")
assert(conversation_text:find("@alice", 1, true) ~= nil, "author header rendered: " .. conversation_text)
assert(conversation_text:find("nit: rename this", 1, true) == nil, "code threads excluded: " .. conversation_text)

local conversation_start = review.conversation.layout.conversation_start_line
assert(type(conversation_start) == "number" and conversation_start > 1, "conversation_start_line is below summary: " .. tostring(conversation_start))
assert(conversation_lines[conversation_start]:find("Conversation (1 comments)", 1, true) ~= nil, tostring(conversation_lines[conversation_start]))
assert(vim.api.nvim_win_get_cursor(win)[1] == conversation_start, "conversation_current scrolls cursor to conversation_start_line")
local conv_topline = vim.api.nvim_win_call(win, function() return vim.fn.winsaveview().topline end)
assert(conv_topline <= conversation_start and conv_topline >= 1, "conversation_current sets valid topline")

-- 2b. :Jpr summary opens the same buffer scrolled to line 1; switching back jumps to conversation_start_line.
session.summary_current()
assert(vim.api.nvim_win_get_buf(win) == conversation_buf, "summary_current reuses the same buffer")
assert(vim.wait(3000, function()
    return vim.api.nvim_win_get_cursor(win)[1] == 1
end), "summary_current moves cursor to line 1")
local summary_topline = vim.api.nvim_win_call(win, function() return vim.fn.winsaveview().topline end)
assert(summary_topline == 1, "summary_current scrolls topline to 1: " .. tostring(summary_topline))

-- Pressing comment actions on a Diff summary line safely no-ops without errors.
local errors_before_summary_keys = #errors
helpers.press_key("e")
helpers.press_key("d")
helpers.press_key("r")
helpers.press_key("p")
helpers.press_key("s")
helpers.press_key("+")
assert(#errors == errors_before_summary_keys, "message actions on summary line do not error: " .. vim.inspect(errors))

-- Cached read-only mode still switches scroll target cleanly between conversation and summary.
review.is_read_only = true
session.conversation_current()
assert(vim.api.nvim_win_get_cursor(win)[1] == conversation_start, "read-only cached conversation_current jumps to conversation_start_line")
session.summary_current()
assert(vim.api.nvim_win_get_cursor(win)[1] == 1, "read-only cached summary_current jumps to line 1")
review.is_read_only = false

-- Background refresh preserves cursor position instead of resetting to line 1 or conversation_start_line.
vim.api.nvim_win_set_cursor(win, { 3, 0 })
conversation.refresh(review)
assert(vim.wait(3000, function()
    return vim.api.nvim_win_get_cursor(win)[1] == 3
end), "refresh preserves cursor line")

-- Blank PR body falls back to `(no PR description)`, and unlinked local mode shows local summary.
local saved_pr = review.view.pr
review.view.pr = vim.tbl_extend("force", vim.deepcopy(saved_pr), { body = "   \r\n  " })
conversation.refresh(review)
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n")
    return text:find("(no PR description)", 1, true) ~= nil
end), "blank PR body renders fallback hint")

review.mode = "local"
review.branch = "feat/local-x"
review.view.pr = nil
review.view.localContext = { branch = "feat/local-x", baseRef = "main" }
conversation.refresh(review)
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n")
    return text:find("LOCAL feat/local-x vs main", 1, true) ~= nil
        and text:find("run :Jpr sync once a PR is open", 1, true) ~= nil
        and text:find("Local Notes", 1, true) ~= nil
end), "unlinked local mode renders local diff summary and Local Notes")

review.mode = "pr"
review.branch = nil
review.view.pr = saved_pr
review.view.localContext = nil
conversation.refresh(review)
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n")
    return text:find("Fixes widget crash.", 1, true) ~= nil
end), "restored PR summary")

-- Opening conversation while split stream is active also closes stream's left window.
require("jpr.views.stream").show(review, { focus = true })
assert(vim.wait(3000, function()
    return find_tab_win_by_buf_name(review.tab, "jpr://stream/7/base") ~= nil
end), "split stream opens left_win")
local stream_left_win = find_tab_win_by_buf_name(review.tab, "jpr://stream/7/base")
session.conversation_current()
assert(not vim.api.nvim_win_is_valid(stream_left_win), "conversation closes stream left_win")
assert(vim.api.nvim_win_get_buf(main_window.find(review)) == conversation_buf, "reuses jpr://conversation/7")

-- 3. Pressing c opens real compose with PR Conversation title and <C-s> sends comment with PR anchor.
local comments_before = #helpers.read_requests(log, "comment")
vim.api.nvim_set_current_win(main_window.find(review))
helpers.press_key("c")
local pr_compose_win = helpers.find_floating_win("GitHub")
assert(pr_compose_win ~= nil and vim.api.nvim_win_is_valid(pr_compose_win), "real compose opens on c")
assert(helpers.win_title(pr_compose_win):find("PR Conversation", 1, true) ~= nil, helpers.win_title(pr_compose_win))
vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(pr_compose_win), 0, -1, false, { "Ship it!" })
helpers.press_key("<C-s>")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "comment") == comments_before + 1
end), "PR comment RPC sent")
local sent_pr_comment = helpers.read_requests(log, "comment")[comments_before + 1].params
assert(vim.deep_equal(sent_pr_comment.anchor, { kind = "pr", side = "RIGHT" }) and sent_pr_comment.body == "Ship it!", vim.inspect(sent_pr_comment))

-- 3b. Pressing c, flipping destination to [Local -> agent] with <C-g>, and saving with <C-s> sends origin = "local".
review.compose_destination = nil
vim.api.nvim_set_current_win(main_window.find(review))
helpers.press_key("c")
local pr_toggle_win = helpers.find_floating_win("PR Conversation")
assert(pr_toggle_win ~= nil and vim.api.nvim_win_is_valid(pr_toggle_win), "compose opens on c for toggle")
helpers.press_key("<C-g>")
assert(helpers.win_title(pr_toggle_win):find("[Local → agent] PR Conversation", 1, true) ~= nil, helpers.win_title(pr_toggle_win))
vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(pr_toggle_win), 0, -1, false, { "Local PR thought" })
helpers.press_key("<C-s>")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "comment") == comments_before + 2
end), "local PR comment RPC sent")
local sent_local_pr_comment = helpers.read_requests(log, "comment")[comments_before + 2].params
assert(
    vim.deep_equal(sent_local_pr_comment.anchor, { kind = "pr", side = "RIGHT" })
        and sent_local_pr_comment.body == "Local PR thought"
        and sent_local_pr_comment.origin == "local",
    vim.inspect(sent_local_pr_comment)
)
review.compose_destination = nil

-- 4. Multi-message PR threads: reactions, author checks on e/d, failed X, refresh visibility, q, close.
local pr_threads_fixture = {
    {
        id = "T_CODE",
        origin = "github",
        anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 },
        state = "open",
        outdated = false,
        messages = {
            {
                id = "M_CODE",
                author = "bob",
                body = "should not appear in conversation",
                created = "2026-11-20T00:00:00Z",
                updated = "2026-11-20T00:00:00Z",
                sync = "published",
                viewerDidAuthor = false,
                reactions = {},
            },
        },
    },
    {
        id = "T_PR_1",
        origin = "github",
        anchor = { kind = "pr", side = "RIGHT" },
        state = "open",
        outdated = false,
        messages = {
            {
                id = "M_PR_OTHER",
                author = "alice",
                body = "Thanks for the fix",
                created = "2026-11-20T00:00:00Z",
                updated = "2026-11-20T00:00:00Z",
                sync = "published",
                viewerDidAuthor = false,
                reactions = {
                    { content = "THUMBS_UP", count = 2, viewerHasReacted = true },
                },
            },
        },
    },
    {
        id = "T_PR_2",
        origin = "github",
        anchor = { kind = "pr", side = "RIGHT" },
        state = "open",
        outdated = false,
        messages = {
            {
                id = "M_PR_OWN",
                author = "pablo",
                body = "Offline follow-up",
                created = "2026-11-20T01:00:00Z",
                updated = "2026-11-20T01:00:00Z",
                sync = "failed",
                syncError = "rate limited",
                recoverableBody = "Recovered body",
                viewerDidAuthor = true,
                reactions = {},
            },
        },
    },
    {
        id = "T_PR_LOCAL",
        origin = "local",
        anchor = { kind = "pr", side = "RIGHT" },
        state = "open",
        outdated = false,
        agent = { state = "unsent" },
        messages = {
            {
                id = "M_PR_LOCAL",
                author = "claude",
                body = "Local PR note",
                created = "2026-11-20T02:00:00Z",
                updated = "2026-11-20T02:00:00Z",
                viewerDidAuthor = false,
                reactions = {},
            },
        },
    },
}

local original_request = review.client.request
local threads_calls = 0
local pending_threads_callbacks = {}
local hold_threads = false
review.client.request = function(client_self, method, params, callback)
    if method == "threads" then
        threads_calls = threads_calls + 1
        if hold_threads then
            pending_threads_callbacks[#pending_threads_callbacks + 1] = callback
            return
        end
        local copy = vim.deepcopy(pr_threads_fixture)
        vim.schedule(function()
            callback(nil, { threads = copy })
        end)
        return
    end
    return original_request(client_self, method, params, callback)
end

conversation.refresh(review)
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n")
    return text:find("Offline follow-up", 1, true) ~= nil
end), "refresh redraws visible conversation")

local rendered_lines = vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false)
local rendered_text = table.concat(rendered_lines, "\n")
assert(rendered_text:find("should not appear in conversation", 1, true) == nil, rendered_text)
assert(rendered_text:find(render_threads.REACTION_EMOJI.THUMBS_UP .. " 2*", 1, true) ~= nil, "reactions rendered: " .. rendered_text)
assert(rendered_text:find("[failed]", 1, true) ~= nil, "failed badge rendered: " .. rendered_text)
assert(rendered_text:find("rate limited", 1, true) ~= nil, "syncError rendered: " .. rendered_text)
assert(rendered_text:find("[local · unsent]", 1, true) ~= nil, "local badge rendered: " .. rendered_text)
assert(rendered_text:find("[p]romote", 1, true) ~= nil, "local conversation footer includes [p]romote: " .. rendered_text)

local conversation_win = main_window.find(review)
vim.api.nvim_set_current_win(conversation_win)
local other_message_line = helpers.find_line_number(rendered_lines, "Thanks for the fix")
local own_message_line = helpers.find_line_number(rendered_lines, "Offline follow-up")
local local_message_line = helpers.find_line_number(rendered_lines, "Local PR note")
assert(other_message_line ~= nil and own_message_line ~= nil and local_message_line ~= nil, rendered_text)

-- On non-own message: e and d error, X informs, + sends toggleReaction.
vim.api.nvim_win_set_cursor(conversation_win, { other_message_line, 0 })
errors = {}
helpers.press_key("e")
assert(#errors == 1 and errors[1]:find("own comments", 1, true), vim.inspect(errors))

errors = {}
local delete_before = #helpers.read_requests(log, "deleteMessage")
helpers.press_key("d")
assert(#errors == 1 and errors[1]:find("own comments", 1, true), vim.inspect(errors))
assert(#helpers.read_requests(log, "deleteMessage") == delete_before, "forbidden d sends no RPC")

infos = {}
local retry_before = #helpers.read_requests(log, "retryMessage")
helpers.press_key("X")
assert(#infos == 1 and infos[1]:find("not in a failed state", 1, true), vim.inspect(infos))
assert(#helpers.read_requests(log, "retryMessage") == retry_before, "non-failed X sends no RPC")

-- On non-local GitHub thread: r, p, and s inform without opening compose or sending to agent.
infos = {}
helpers.press_key("r")
assert(#infos == 1 and infos[1]:find("only local threads support replies", 1, true), vim.inspect(infos))
assert(helpers.find_floating_win("Reply") == nil, "r on non-local thread does not open reply compose")

infos = {}
helpers.press_key("p")
assert(#infos == 1 and infos[1]:find("only local threads can be promoted", 1, true), vim.inspect(infos))
assert(helpers.find_floating_win("Promote") == nil, "p on non-local thread does not open promote compose")

local sent_agent_threads = {}
local original_agent_module = package.loaded["jpr.agent"]
package.loaded["jpr.agent"] = {
    send = function(target_session, thread_id)
        sent_agent_threads[#sent_agent_threads + 1] = { session = target_session, thread_id = thread_id }
    end,
}
infos = {}
helpers.press_key("s")
assert(#infos == 1 and infos[1]:find("only local threads can be sent", 1, true), vim.inspect(infos))
assert(#sent_agent_threads == 0, "s on non-local thread does not call agent.send")

local original_select = vim.ui.select
vim.ui.select = function(items, _, on_choice)
    assert(vim.deep_equal(items, render_threads.REACTION_ORDER), "reaction picker uses REACTION_ORDER")
    on_choice("ROCKET")
end
local react_before = #helpers.read_requests(log, "toggleReaction")
helpers.press_key("+")
vim.ui.select = original_select
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "toggleReaction") == react_before + 1
end), "+ sends toggleReaction")
local sent_react = helpers.read_requests(log, "toggleReaction")[react_before + 1].params
assert(sent_react.messageId == "M_PR_OTHER" and sent_react.content == "ROCKET", vim.inspect(sent_react))

-- On own failed message: e opens real compose pre-filled with recoverableBody and <C-s> sends editMessage.
vim.api.nvim_win_set_cursor(conversation_win, { own_message_line, 0 })
local edit_before = #helpers.read_requests(log, "editMessage")
helpers.press_key("e")
local edit_win = helpers.find_floating_win("GitHub")
assert(edit_win ~= nil and vim.api.nvim_win_is_valid(edit_win), "e opens real compose window")
local edit_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(edit_win), 0, -1, false)
assert(table.concat(edit_lines, "\n") == "Recovered body", vim.inspect(edit_lines))
helpers.press_key("<C-s>")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "editMessage") == edit_before + 1
end), "e -> <C-s> sends editMessage")
local sent_edit = helpers.read_requests(log, "editMessage")[edit_before + 1].params
assert(sent_edit.messageId == "M_PR_OWN" and sent_edit.body == "Recovered body", vim.inspect(sent_edit))

-- Restore focus to conversation window for d and X checks.
vim.api.nvim_set_current_win(conversation_win)
vim.api.nvim_win_set_cursor(conversation_win, { own_message_line, 0 })
local original_confirm = vim.fn.confirm
vim.fn.confirm = function()
    return 2
end
helpers.press_key("d")
assert(#helpers.read_requests(log, "deleteMessage") == delete_before, "cancelled confirm sends no deleteMessage")

vim.fn.confirm = function()
    return 1
end
helpers.press_key("d")
vim.fn.confirm = original_confirm
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "deleteMessage") == delete_before + 1
end), "confirmed d sends deleteMessage")
assert(helpers.read_requests(log, "deleteMessage")[delete_before + 1].params.messageId == "M_PR_OWN")

helpers.press_key("X")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "retryMessage") == retry_before + 1
end), "X on failed message sends retryMessage")
assert(helpers.read_requests(log, "retryMessage")[retry_before + 1].params.messageId == "M_PR_OWN")

-- 4b. Local PR thread actions: r (reply), p (promote), s (send), + guard, d even when not viewerDidAuthor.
vim.api.nvim_set_current_win(conversation_win)
vim.api.nvim_win_set_cursor(conversation_win, { local_message_line, 0 })

local replies_before = #helpers.read_requests(log, "reply")
helpers.press_key("r")
local local_reply_win = helpers.find_floating_win("Local reply")
assert(local_reply_win ~= nil and vim.api.nvim_win_is_valid(local_reply_win), "r opens [Local reply] compose")
vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(local_reply_win), 0, -1, false, { "Follow up locally" })
helpers.press_key("<C-s>")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "reply") == replies_before + 1
end), "r -> <C-s> sends reply for local PR thread")
assert(helpers.read_requests(log, "reply")[replies_before + 1].params.threadId == "T_PR_LOCAL")

vim.api.nvim_set_current_win(conversation_win)
vim.api.nvim_win_set_cursor(conversation_win, { local_message_line, 0 })
local promotes_before = #helpers.read_requests(log, "promoteThread")
helpers.press_key("p")
local promote_win = helpers.find_floating_win("Promote")
assert(promote_win ~= nil and vim.api.nvim_win_is_valid(promote_win), "p opens [Promote -> GitHub] compose")
assert(helpers.win_title(promote_win):find("[Promote → GitHub] PR Conversation", 1, true) ~= nil, helpers.win_title(promote_win))
assert(table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(promote_win), 0, -1, false), "\n") == "Local PR note")
helpers.press_key("<C-s>")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "promoteThread") == promotes_before + 1
end), "p -> <C-s> sends promoteThread")
local sent_promote = helpers.read_requests(log, "promoteThread")[promotes_before + 1].params
assert(sent_promote.threadId == "T_PR_LOCAL" and sent_promote.body == "Local PR note", vim.inspect(sent_promote))

vim.api.nvim_set_current_win(conversation_win)
vim.api.nvim_win_set_cursor(conversation_win, { local_message_line, 0 })
helpers.press_key("s")
assert(#sent_agent_threads == 1 and sent_agent_threads[1].session == review and sent_agent_threads[1].thread_id == "T_PR_LOCAL",
    "s delegates single local thread to jpr.agent.send")
package.loaded["jpr.agent"] = original_agent_module

infos = {}
local react_local_before = #helpers.read_requests(log, "toggleReaction")
helpers.press_key("+")
assert(#infos == 1 and infos[1]:find("reactions apply only to GitHub comments", 1, true), vim.inspect(infos))
assert(#helpers.read_requests(log, "toggleReaction") == react_local_before, "+ on local thread sends no toggleReaction")

local delete_local_before = #helpers.read_requests(log, "deleteMessage")
vim.fn.confirm = function()
    return 1
end
helpers.press_key("d")
vim.fn.confirm = original_confirm
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "deleteMessage") == delete_local_before + 1
end), "d deletes local thread message even when not viewerDidAuthor")
assert(helpers.read_requests(log, "deleteMessage")[delete_local_before + 1].params.messageId == "M_PR_LOCAL")

-- Verify JprThreadLocal highlight is placed on the [local * unsent] badge line and p guards already-promoted threads.
local badge_line = helpers.find_line_number(rendered_lines, "[local · unsent]")
assert(badge_line ~= nil, "local badge line present")
local extmarks = vim.api.nvim_buf_get_extmarks(conversation_buf, -1, { badge_line - 1, 0 }, { badge_line - 1, -1 }, { details = true })
local has_local_highlight = false
for _, mark in ipairs(extmarks) do
    if mark[4] and mark[4].hl_group == "JprThreadLocal" then
        has_local_highlight = true
    end
end
assert(has_local_highlight, "local badge uses JprThreadLocal highlight")

pr_threads_fixture[4].promotedTo = "PRRT_77"
conversation.refresh(review)
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n")
    return text:find("[promoted]", 1, true) ~= nil
end), "promoted badge rendered")
local promoted_line = helpers.find_line_number(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "Local PR note")
vim.api.nvim_win_set_cursor(conversation_win, { promoted_line, 0 })
infos = {}
helpers.press_key("p")
assert(#infos == 1 and infos[1]:find("already promoted", 1, true) ~= nil, vim.inspect(infos))
assert(helpers.find_floating_win("Promote") == nil, "p on already-promoted local thread does not open compose")
pr_threads_fixture[4].promotedTo = nil

-- Stale threads request_id guard.
hold_threads = true
conversation.refresh(review)
conversation.refresh(review)
assert(#pending_threads_callbacks == 2, "two in-flight threads requests captured")
hold_threads = false
pending_threads_callbacks[1](nil, {
    threads = {
        {
            id = "T_STALE",
            anchor = { kind = "pr", side = "RIGHT" },
            state = "open",
            messages = { { id = "M_STALE", author = "ghost", body = "STALE_TEXT", created = "2026-11-20T00:00:00Z", updated = "2026-11-20T00:00:00Z" } },
        },
    },
})
assert(not table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n"):find("STALE_TEXT", 1, true),
    "stale request_id response is dropped")
pending_threads_callbacks[2](nil, { threads = pr_threads_fixture })

-- M.refresh does NOT fetch or redraw when conversation buffer is hidden.
view_mode.set("unified")
main_window.edit(review, conversation_win, "README.md", 1)
local calls_while_hidden = threads_calls
conversation.refresh(review)
assert(threads_calls == calls_while_hidden, "refresh does nothing while conversation is hidden")

-- Mouse clicks (message select, footer actions, outside passthrough) in dedicated module.
dofile(root .. "/tests/lua/conversation_view_spec/mouse.lua")({
    helpers = helpers,
    main_window = main_window,
    review = review,
    session = session,
})

session.conversation_current()
local quit_buf = vim.api.nvim_win_get_buf(main_window.find(review))
assert(vim.api.nvim_buf_is_valid(quit_buf), "conversation reopened for q")
vim.api.nvim_set_current_win(main_window.find(review))
helpers.press_key("q")
assert(not vim.api.nvim_buf_is_valid(quit_buf), "q wipes conversation buffer")
assert(vim.api.nvim_win_is_valid(review.panel.win), "panel stays open after q")

session.conversation_current()
local close_buf = vim.api.nvim_win_get_buf(main_window.find(review))
conversation.close(review)
assert(not vim.api.nvim_buf_is_valid(close_buf), "close wipes conversation buffer")

review.client.request = original_request
jpr.error = original_error
jpr.info = original_info
session.close_current()

print("conversation_view_spec: ok")
