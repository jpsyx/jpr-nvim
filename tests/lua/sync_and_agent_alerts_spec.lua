-- Spec for sync delta auto-refresh, blue sync summary toasts, and blue local
-- agent reply / pre-pass notifications.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local events = require("jpr.session.events")
local notify = require("jpr.notify")

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(label or "assert_eq", vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

local function reset()
    notify.clear()
    notify.set_listener(nil)
end

-- 1. Pure formatting for SyncDelta
local fake_session = { number = 42, mode = "pr" }
assert_eq(events.build_sync_delta_message(fake_session, nil), nil, "nil delta -> nil")
assert_eq(
    events.build_sync_delta_message(fake_session, {
        filesChanged = 0,
        newComments = 0,
        updatedComments = 0,
        resolvedThreads = 0,
        reopenedThreads = 0,
        headMoved = false,
    }),
    nil,
    "empty delta -> nil"
)
assert_eq(
    events.build_sync_delta_message(fake_session, {
        filesChanged = 3,
        newComments = 2,
        updatedComments = 0,
        resolvedThreads = 0,
        reopenedThreads = 0,
        headMoved = false,
    }),
    "PR #42 updated: 3 files changed, 2 new comments",
    "pluralized delta message"
)
assert_eq(
    events.build_sync_delta_message(fake_session, {
        filesChanged = 1,
        newComments = 1,
        updatedComments = 1,
        resolvedThreads = 1,
        reopenedThreads = 1,
        headMoved = false,
    }),
    "PR #42 updated: 1 file changed, 1 new comment, 1 comment edited, 1 thread resolved, 1 thread reopened",
    "singular delta message"
)

-- 2. Pure formatting for AgentReplied
assert_eq(
    events.build_agent_reply_message({ author = "claude", file = "src/a.rs", line = 42 }),
    "claude replied on src/a.rs:42",
    "line-anchored agent reply"
)
assert_eq(
    events.build_agent_reply_message({ author = "agent", file = "src/a.rs" }),
    "agent replied on src/a.rs",
    "file-anchored agent reply"
)
assert_eq(
    events.build_agent_reply_message({ author = "claude" }),
    "claude replied on PR conversation",
    "pr-level agent reply"
)

-- 3. synced event with delta auto-refreshes diff, threads, stream, conversation, and emits a blue toast
reset()
local recorded = {}
notify.set_listener(function(kind, message)
    recorded[#recorded + 1] = { kind = kind, message = message }
end)
local calls = {
    show = 0,
    redraw_all = 0,
    redraw_threads = 0,
    stream_force = 0,
    conversation_refresh = 0,
    popup_refresh = 0,
}
local orig_diff = package.loaded["jpr.views.diff"]
local orig_stream = package.loaded["jpr.views.stream"]
local orig_conv = package.loaded["jpr.views.conversation"]
local orig_popup = package.loaded["jpr.comments.popup"]
local orig_panel = package.loaded["jpr.views.panel"]

package.loaded["jpr.views.diff"] = {
    redraw_all = function() calls.redraw_all = calls.redraw_all + 1 end,
    redraw_threads = function() calls.redraw_threads = calls.redraw_threads + 1 end,
}
package.loaded["jpr.views.stream"] = {
    refresh = function(_, force)
        if force then
            calls.stream_force = calls.stream_force + 1
        end
    end,
}
package.loaded["jpr.views.conversation"] = {
    refresh = function() calls.conversation_refresh = calls.conversation_refresh + 1 end,
}
package.loaded["jpr.comments.popup"] = {
    refresh_open = function() calls.popup_refresh = calls.popup_refresh + 1 end,
}
package.loaded["jpr.views.panel"] = {
    render = function() end,
}

local ok_events, events_err = pcall(function()
    local test_session = { number = 7, mode = "pr", view = {} }
    local show_session = function(s, view)
        s.view = view
        calls.show = calls.show + 1
    end

    -- Empty/nil delta emits no toast
    events.on_notification(test_session, "event", {
        type = "synced",
        isBackground = true,
        view = { pr = { number = 7 } },
    }, show_session)
    assert_eq(calls.show, 1, "show_session called")
    assert_eq(#recorded, 0, "no toast when delta is nil")

    -- Delta with files + comments triggers full refresh + blue info toast
    events.on_notification(test_session, "event", {
        type = "synced",
        isBackground = true,
        delta = {
            filesChanged = 3,
            newComments = 2,
            updatedComments = 0,
            resolvedThreads = 0,
            reopenedThreads = 0,
            headMoved = false,
        },
        view = { pr = { number = 7 } },
    }, show_session)
    assert_eq(calls.redraw_all, 1, "diff.redraw_all called on file changes")
    assert_eq(calls.redraw_threads, 1, "diff.redraw_threads called on new comments")
    assert_eq(calls.stream_force, 1, "stream.refresh forced on delta")
    assert_eq(calls.conversation_refresh, 1, "conversation refreshed on comment delta")
    assert_eq(calls.popup_refresh, 1, "open popup refreshed on comment delta")
    assert_eq(#recorded, 1, "one blue sync toast emitted")
    assert_eq(recorded[1].kind, "info", "blue info kind for sync delta")
    assert_eq(recorded[1].message, "PR #7 updated: 3 files changed, 2 new comments", "sync delta summary")

    -- 4. agentReplied emits blue info toast and refreshes popup
    recorded = {}
    calls.popup_refresh = 0
    events.on_notification(test_session, "event", {
        type = "agentReplied",
        threadId = "loc-1",
        author = "claude",
        file = "src/a.rs",
        line = 42,
        view = { pr = { number = 7 } },
    }, show_session)
    assert_eq(#recorded, 1, "one blue agent reply toast emitted")
    assert_eq(recorded[1].kind, "info", "blue info kind for agent reply")
    assert_eq(recorded[1].message, "claude replied on src/a.rs:42", "agent reply message")
    assert_eq(calls.popup_refresh, 1, "open popup refreshed on agent reply")

    -- 5. agentPrepassWritten emits blue info toast
    recorded = {}
    events.on_notification(test_session, "event", {
        type = "agentPrepassWritten",
        count = 3,
        view = { pr = { number = 7 } },
    }, show_session)
    assert_eq(#recorded, 1, "one blue prepass toast emitted")
    assert_eq(recorded[1].kind, "info", "blue info kind for prepass")
    assert_eq(recorded[1].message, "Agent added 3 pre-pass findings", "prepass message")
end)

package.loaded["jpr.views.diff"] = orig_diff
package.loaded["jpr.views.stream"] = orig_stream
package.loaded["jpr.views.conversation"] = orig_conv
package.loaded["jpr.comments.popup"] = orig_popup
package.loaded["jpr.views.panel"] = orig_panel
reset()
assert(ok_events, events_err)
print("sync_and_agent_alerts_spec: ok")
