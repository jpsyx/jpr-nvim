-- Spec for centralized RPC in-progress toast indicators, submit modal inline
-- submitting state, and stream progress toast updates.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local notify = require("jpr.notify")
local progress = require("jpr.session.progress")
local render_submit = require("jpr.render.submit")
local session_mod = require("jpr.session")
local submit_view = require("jpr.views.submit")
local events = require("jpr.session.events")

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(label or "assert_eq", vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

local function reset()
    notify.clear()
    notify.set_listener(nil)
end

-- 1. Method progress specs: immediate (delay_ms = 0) for GitHub ops, 150ms for fast/local ops
local submit_spec = progress.get_spec_from_request("submitReview", { event = "APPROVE" })
assert_eq(submit_spec.delay_ms, 0, "submitReview is immediate")
assert(submit_spec.label:find("Submitting", 1, true) ~= nil, "submitReview label")

local sync_spec = progress.get_spec_from_request("sync", nil)
assert_eq(sync_spec.delay_ms, 0, "sync is immediate")

local push_spec = progress.get_spec_from_request("push", nil)
assert_eq(push_spec.delay_ms, 0, "push is immediate")

local gh_comment_spec = progress.get_spec_from_request("comment", { origin = "github" })
assert_eq(gh_comment_spec.delay_ms, 0, "github comment is immediate")

local local_comment_spec = progress.get_spec_from_request("comment", { origin = "local" })
assert_eq(local_comment_spec.delay_ms, 150, "local comment is delayed")

local diff_spec = progress.get_spec_from_request("fileDiff", { path = "src/a.rs" })
assert_eq(diff_spec.delay_ms, 150, "fileDiff is delayed")

local viewed_spec = progress.get_spec_from_request("setViewed", { path = "src/a.rs", viewed = true })
assert_eq(viewed_spec.delay_ms, 150, "setViewed is delayed")

-- 2. session.request tracks progress, transitions to error without duplicate toast, and cancels on teardown
reset()
local recorded = {}
notify.set_listener(function(kind, message)
    recorded[#recorded + 1] = { kind = kind, message = message }
end)
local pending_cb = nil
local fake_session = {
    tab = vim.api.nvim_get_current_tabpage(),
    number = 7,
    closing = false,
    client = {
        request = function(_, _method, _params, cb)
            pending_cb = cb
        end,
    },
}

session_mod.request(fake_session, "submitReview", { event = "COMMENT", body = "ok" }, function() end, nil, {
    success_message = "Review submitted",
})
assert_eq(#notify.get_toasts(), 1, "immediate progress toast shown for submitReview")
assert_eq(notify.get_toasts()[1].kind, "progress", "toast kind is progress")

pending_cb({ code = -32000, message = "cannot approve own PR" }, nil)
assert_eq(#recorded, 1, "only one error notification emitted on failure")
assert_eq(recorded[1].kind, "error", "error kind emitted")
assert(recorded[1].message:find("cannot approve own PR", 1, true) ~= nil, "error detail preserved")
assert_eq(#notify.get_toasts(), 1, "single toast transitioned in place")
assert_eq(notify.get_toasts()[1].kind, "error", "toast transitioned to red error")

-- Success transition
reset()
recorded = {}
notify.set_listener(function(kind, message)
    recorded[#recorded + 1] = { kind = kind, message = message }
end)
session_mod.request(fake_session, "submitReview", { event = "COMMENT", body = "ok" }, function() end, nil, {
    success_message = "Review submitted",
})
assert_eq(notify.get_toasts()[1].kind, "progress", "progress active")
pending_cb(nil, {})
assert_eq(#recorded, 1, "one success notification emitted")
assert_eq(recorded[1].kind, "success", "green success kind")
assert_eq(notify.get_toasts()[1].kind, "success", "toast transitioned to green success")

-- Teardown cancels active progress toasts cleanly
reset()
session_mod.request(fake_session, "push", nil, function() end)
assert_eq(#notify.get_toasts(), 1, "push progress visible")
progress.cancel_all(fake_session)
assert_eq(#notify.get_toasts(), 0, "cancel_all closes active progress toasts")

-- 3. Submit Review modal inline submitting banner
local preview = { draftCount = 1, drafts = {}, canApproveOrRequestChanges = true }
local normal_layout = render_submit.build(preview, "COMMENT", {})
local submitting_layout = render_submit.build(preview, "COMMENT", {}, { is_submitting = true })
local normal_text = table.concat(normal_layout.lines, "\n")
local submitting_text = table.concat(submitting_layout.lines, "\n")
assert(normal_text:find("Submitting review to GitHub", 1, true) == nil, "idle submit modal has no submitting banner")
assert(submitting_text:find("Submitting review to GitHub", 1, true) ~= nil, "in-flight submit modal shows submitting banner")

-- 4. streamProgress outside loading updates progress toast instead of nvim_echo
reset()
local echo_called = false
local orig_echo = vim.api.nvim_echo
vim.api.nvim_echo = function()
    echo_called = true
end
local ok_stream, stream_err = pcall(function()
    local stream_session = { tab = vim.api.nvim_get_current_tabpage(), loading = nil }
    events.on_notification(stream_session, "streamProgress", { completed = 1, total = 4, path = "src/a.rs" }, function() end)
    assert_eq(echo_called, false, "streamProgress should not call nvim_echo")
    assert_eq(#notify.get_toasts(), 1, "streamProgress opens/updates a progress toast")
    local lines = vim.api.nvim_buf_get_lines(notify.get_toasts()[1].buf, 0, -1, false)
    assert(table.concat(lines, "\n"):find("1/4", 1, true) ~= nil, "stream progress count shown")
    events.on_notification(stream_session, "streamProgress", { completed = 4, total = 4, path = "src/d.rs" }, function() end)
    assert_eq(#notify.get_toasts(), 0, "streamProgress closes when completed == total")
end)
vim.api.nvim_echo = orig_echo
assert(ok_stream, stream_err)

reset()
print("progress_and_submit_spec: ok")
