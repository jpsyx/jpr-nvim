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

-- 1. Without an active session, conversation_current errors cleanly.
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

local conversation_text = table.concat(vim.api.nvim_buf_get_lines(conversation_buf, 0, -1, false), "\n")
assert(conversation_text:find("@alice", 1, true) ~= nil, "author header rendered: " .. conversation_text)
assert(conversation_text:find("nit: rename this", 1, true) == nil, "code threads excluded: " .. conversation_text)

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

local conversation_win = main_window.find(review)
vim.api.nvim_set_current_win(conversation_win)
local other_message_line = helpers.find_line_number(rendered_lines, "Thanks for the fix")
local own_message_line = helpers.find_line_number(rendered_lines, "Offline follow-up")
assert(other_message_line ~= nil and own_message_line ~= nil, rendered_text)

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

-- Reopen, then q closes cleanly and wipes buffer; M.close also wipes buffer.
session.conversation_current()
local reopened_buf = vim.api.nvim_win_get_buf(main_window.find(review))
assert(vim.api.nvim_buf_is_valid(reopened_buf), "conversation reopened")
vim.api.nvim_set_current_win(main_window.find(review))
helpers.press_key("q")
assert(not vim.api.nvim_buf_is_valid(reopened_buf), "q wipes conversation buffer")
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
