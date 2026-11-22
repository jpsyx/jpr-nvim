local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local view_mode = require("jpr.view_mode")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new", "tail" }, worktree .. "/README.md")

local errors, infos = {}, {}
local original_error, original_info = jpr.error, jpr.info
jpr.error = function(message)
    errors[#errors + 1] = message
end
jpr.info = function(message)
    infos[#infos + 1] = message
end

-- Calling popup_current without an active session notifies cleanly.
session.popup_current()
assert(#errors == 1 and errors[1]:find("no pull request", 1, true), vim.inspect(errors))
errors, infos = {}, {}

session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "the review syncs")

local context = {
    root = root,
    helpers = helpers,
    log = log,
    worktree = worktree,
    review = review,
    errors = errors,
    infos = infos,
    clear_messages = function()
        for idx = #errors, 1, -1 do errors[idx] = nil end
        for idx = #infos, 1, -1 do infos[idx] = nil end
    end,
}

dofile(root .. "/tests/lua/popup_spec/actions.lua")(context)
dofile(root .. "/tests/lua/popup_spec/lifecycle.lua")(context)

local function build_local_preview(overrides)
    local base = {
        threadId = "loc-1",
        origin = "local",
        kind = "local",
        anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 },
        displayLine = 2,
        state = "open",
        outdated = false,
        messageCount = 1,
        firstAuthor = "claude",
        snippet = "Check edge case",
        agent = { state = "unsent" },
        messages = {
            {
                id = "loc-m-1",
                author = "claude",
                body = "Check edge case",
                created = "2026-11-20T00:00:00Z",
                updated = "2026-11-20T00:00:00Z",
                viewerDidAuthor = false,
                reactions = {},
            },
        },
    }
    return vim.tbl_extend("force", base, overrides or {})
end

local function test_non_local_guards()
    local main_win = require("jpr.views.main_window").find(review)
    require("jpr.views.main_window").edit(review, main_win, "README.md", 1)
    local buf = vim.api.nvim_win_get_buf(main_win)
    local github_thread = {
        threadId = "T_GH_GUARD",
        origin = "github",
        kind = "published",
        displayLine = 2,
        state = "open",
        outdated = false,
        messageCount = 1,
        firstAuthor = "alice",
        snippet = "github body",
        messages = {
            { id = "M_GH", author = "alice", body = "github body", sync = "published", viewerDidAuthor = false, reactions = {} },
        },
    }
    require("jpr.views.threads").draw_on_buffer(review, buf, { github_thread })
    vim.api.nvim_set_current_win(main_win)
    vim.api.nvim_win_set_cursor(main_win, { 2, 0 })
    session.popup_current()
    local popup_win = helpers.find_floating_win()
    assert(popup_win ~= nil and vim.api.nvim_win_is_valid(popup_win), "github popup opens for guard checks")

    local sent_calls = {}
    local original_agent = package.loaded["jpr.agent"]
    package.loaded["jpr.agent"] = {
        send = function(target_session, thread_id)
            sent_calls[#sent_calls + 1] = { session = target_session, thread_id = thread_id }
        end,
    }
    context.clear_messages()
    helpers.press_key("p")
    assert(#infos == 1 and infos[1]:find("only local threads can be promoted", 1, true), vim.inspect(infos))
    assert(vim.api.nvim_win_is_valid(popup_win), "popup stays open on non-local promote")

    context.clear_messages()
    helpers.press_key("s")
    assert(#infos == 1 and infos[1]:find("only local threads can be sent", 1, true), vim.inspect(infos))
    assert(#sent_calls == 0, "non-local s does not call agent.send")
    assert(vim.api.nvim_win_is_valid(popup_win), "popup stays open on non-local send")
    package.loaded["jpr.agent"] = original_agent
    helpers.press_key("q")
end

local function test_local_promote_and_refresh()
    local popup_module = require("jpr.comments.popup")
    local local_thread = build_local_preview()
    popup_module.open(review, { local_thread })
    local popup_win = helpers.find_floating_win()
    assert(popup_win ~= nil and vim.api.nvim_win_is_valid(popup_win), "local popup opens")
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(popup_win), 0, -1, false), "\n")
    assert(text:find("[local · unsent]", 1, true) ~= nil, text)
    assert(text:find("[p]romote  [s]end", 1, true) ~= nil, text)

    local promotes_before = #helpers.read_requests(log, "promoteThread")
    helpers.press_key("p")
    assert(not vim.api.nvim_win_is_valid(popup_win), "p closes popup window")
    local promote_win = helpers.find_floating_win("Promote")
    assert(promote_win ~= nil and vim.api.nvim_win_is_valid(promote_win), "p opens promote compose")
    local promote_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(promote_win), 0, -1, false)
    assert(table.concat(promote_lines, "\n") == "Check edge case", vim.inspect(promote_lines))
    helpers.press_key("<C-s>")
    assert(vim.wait(3000, function()
        return #helpers.read_requests(log, "promoteThread") == promotes_before + 1
    end), "p -> <C-s> sends promoteThread")
    local sent_promote = helpers.read_requests(log, "promoteThread")[promotes_before + 1].params
    assert(sent_promote.threadId == "loc-1" and sent_promote.body == "Check edge case", vim.inspect(sent_promote))

    popup_module.open(review, { build_local_preview() })
    local refresh_win = helpers.find_floating_win()
    popup_module.refresh_from_thread(review, {
        id = "loc-1",
        origin = "local",
        kind = "local",
        state = "open",
        agent = { state = "sent", round = 1 },
        promotedTo = "PRRT_99",
        messages = build_local_preview().messages,
    })
    local refreshed = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(refresh_win), 0, -1, false), "\n")
    assert(refreshed:find("[local · sent #1] [promoted]", 1, true) ~= nil, refreshed)

    context.clear_messages()
    helpers.press_key("p")
    assert(#infos == 1 and infos[1]:find("already promoted", 1, true) ~= nil, vim.inspect(infos))
    assert(vim.api.nvim_win_is_valid(refresh_win), "already-promoted p keeps popup open")
    assert(helpers.find_floating_win("Promote") == nil, "already-promoted p does not open compose")
    popup_module.close(review)
end

local function test_local_send_and_react()
    local popup_module = require("jpr.comments.popup")
    local sent_calls = {}
    local original_agent = package.loaded["jpr.agent"]
    package.loaded["jpr.agent"] = {
        send = function(target_session, thread_id)
            sent_calls[#sent_calls + 1] = { session = target_session, thread_id = thread_id }
        end,
    }
    popup_module.open(review, { build_local_preview() })
    local send_win = helpers.find_floating_win()
    helpers.press_key("s")
    assert(not vim.api.nvim_win_is_valid(send_win), "s closes popup window")
    assert(#sent_calls == 1 and sent_calls[1].session == review and sent_calls[1].thread_id == "loc-1", vim.inspect(sent_calls))
    package.loaded["jpr.agent"] = original_agent

    popup_module.open(review, { build_local_preview() })
    local react_win = helpers.find_floating_win()
    context.clear_messages()
    local react_before = #helpers.read_requests(log, "toggleReaction")
    helpers.press_key("+")
    assert(#infos == 1 and infos[1]:find("reactions apply only to GitHub comments", 1, true) ~= nil, vim.inspect(infos))
    assert(#helpers.read_requests(log, "toggleReaction") == react_before, "+ on local thread sends no toggleReaction")
    assert(vim.api.nvim_win_is_valid(react_win), "+ on local thread keeps popup open")
    popup_module.close(review)
end

local function test_local_reply_and_delete()
    local popup_module = require("jpr.comments.popup")
    popup_module.open(review, { build_local_preview() })
    local reply_popup = helpers.find_floating_win()
    local replies_before = #helpers.read_requests(log, "reply")
    helpers.press_key("r")
    assert(not vim.api.nvim_win_is_valid(reply_popup), "r on local thread closes popup")
    local reply_win = helpers.find_floating_win("Local reply")
    assert(reply_win ~= nil and vim.api.nvim_win_is_valid(reply_win), "r on local thread opens [Local reply]")
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(reply_win), 0, -1, false, { "Local popup reply" })
    helpers.press_key("<C-s>")
    assert(vim.wait(3000, function()
        return #helpers.read_requests(log, "reply") == replies_before + 1
    end), "r on local thread submits reply")
    assert(helpers.read_requests(log, "reply")[replies_before + 1].params.threadId == "loc-1")

    popup_module.open(review, { build_local_preview() })
    local delete_win = helpers.find_floating_win()
    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function()
        return 1
    end
    local deletes_before = #helpers.read_requests(log, "deleteMessage")
    helpers.press_key("d")
    vim.fn.confirm = original_confirm
    assert(vim.wait(3000, function()
        return #helpers.read_requests(log, "deleteMessage") == deletes_before + 1
            and not vim.api.nvim_win_is_valid(delete_win)
    end), "d on local pre-pass finding deletes even when viewerDidAuthor == false")
    assert(helpers.read_requests(log, "deleteMessage")[deletes_before + 1].params.messageId == "loc-m-1")
end

test_non_local_guards()
test_local_promote_and_refresh()
test_local_send_and_react()
test_local_reply_and_delete()

jpr.error = original_error
jpr.info = original_info
session.close_current()

print("popup_spec: ok")
