local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")

-- Zero-cost check: statusline() returns "" when jpr.session has never been loaded,
-- and does NOT eagerly require jpr.session.
package.loaded["jpr.session"] = nil
assert(jpr.statusline() == "", "statusline() is empty before any session module is loaded")
assert(package.loaded["jpr.session"] == nil, "statusline() must not load jpr.session when absent")

local statusline = require("jpr.render.statusline")

assert(statusline.build_statusline_from_session(nil) == "", "nil session returns empty string")
assert(statusline.build_statusline_from_session({}) == "", "session without number returns empty string")

-- Loading states before first sync (view.pr == nil).
assert(
    statusline.build_statusline_from_session({ number = 7, view = {} }) == "PR #7 · Loading…",
    "loading state before initial sync"
)
assert(
    statusline.build_statusline_from_session({ number = 7, is_read_only = true, view = {} })
        == "PR #7 · [read-only] · Loading…",
    "read-only loading state before initial sync"
)

-- Dirty and ahead (with behind == 0 omitted), drafts, and local unsent count.
local dirty_ahead_line = statusline.build_statusline_from_session({
    number = 7,
    view = {
        pr = { number = 7, title = "Fix widget", author = "alice" },
        files = { {}, {}, {} },
        viewedCount = 1,
        draftCount = 2,
        localUnsentCount = 1,
        worktreeStatus = { isDirty = true, ahead = 2, behind = 0 },
        sync = { state = "synced", at = 100 },
    },
})
assert(
    dirty_ahead_line == "PR #7 · dirty ↑2 · 1/3 viewed · 2 drafts · 1 local",
    "dirty ahead statusline: " .. tostring(dirty_ahead_line)
)

-- Behind > 0 renders ↓N, clean omits "dirty", zero drafts/local omitted.
local behind_line = statusline.build_statusline_from_session({
    number = 12,
    view = {
        pr = { number = 12, title = "Refactor", author = "bob" },
        files = { {}, {} },
        viewedCount = 2,
        draftCount = 0,
        localUnsentCount = 0,
        worktreeStatus = { isDirty = false, ahead = 0, behind = 1 },
        sync = { state = "synced", at = 100 },
    },
})
assert(behind_line == "PR #12 · ↓1 · 2/2 viewed", "behind statusline: " .. tostring(behind_line))

-- Both ahead and behind with dirty.
local dirty_diverged_line = statusline.build_statusline_from_session({
    number = 12,
    view = {
        pr = { number = 12, title = "Refactor", author = "bob" },
        files = { {} },
        viewedCount = 0,
        worktreeStatus = { isDirty = true, ahead = 3, behind = 1 },
        sync = { state = "synced", at = 100 },
    },
})
assert(
    dirty_diverged_line == "PR #12 · dirty ↑3 ↓1 · 0/1 viewed",
    "dirty diverged statusline: " .. tostring(dirty_diverged_line)
)

-- Read-only (via session.is_read_only or view.isReadOnly) and failed sync ("sync!").
local read_only_failed_line = statusline.build_statusline_from_session({
    number = 9,
    is_read_only = true,
    view = {
        pr = { number = 9, title = "Crash test", author = "carol" },
        files = { {}, {} },
        viewedCount = 1,
        sync = { state = "failed", at = 105, message = "gh timed out" },
    },
})
assert(
    read_only_failed_line == "PR #9 · [read-only] · 1/2 viewed · sync!",
    "read-only failed sync statusline: " .. tostring(read_only_failed_line)
)

local view_read_only_line = statusline.build_statusline_from_session({
    number = 9,
    view = {
        isReadOnly = true,
        pr = { number = 9, title = "Crash test", author = "carol" },
        files = { {} },
        viewedCount = 0,
        sync = { state = "synced", at = 105 },
    },
})
assert(
    view_read_only_line == "PR #9 · [read-only] · 0/1 viewed",
    "view.isReadOnly statusline: " .. tostring(view_read_only_line)
)

-- Hostile PR title/author strings are never included in statusline output (e.g. %{} statusline eval injection).
local hostile_title = "%{system('touch /tmp/pwned')} EVIL_TITLE"
local hostile_author = "%!evil_expr() EVIL_AUTHOR"
local safe_line = statusline.build_statusline_from_session({
    number = 42,
    view = {
        pr = { number = 42, title = hostile_title, author = hostile_author },
        files = { {} },
        viewedCount = 1,
        sync = { state = "synced", at = 100 },
    },
})
assert(safe_line == "PR #42 · 1/1 viewed", "safe statusline: " .. tostring(safe_line))
assert(not safe_line:find("EVIL_TITLE", 1, true), "title never appears in statusline")
assert(not safe_line:find("EVIL_AUTHOR", 1, true), "author never appears in statusline")
assert(not safe_line:find("%", 1, true), "no statusline format directives leaked")

-- require("jpr").statusline() delegates to the active session when jpr.session is loaded.
local current_session = nil
package.loaded["jpr.session"] = {
    current = function()
        return current_session
    end,
}
assert(jpr.statusline() == "", "statusline() is empty when current() returns nil")
current_session = {
    number = 7,
    view = {
        pr = { number = 7, title = "Widget", author = "alice" },
        files = { {}, {} },
        viewedCount = 1,
        sync = { state = "synced", at = 100 },
    },
}
assert(jpr.statusline() == "PR #7 · 1/2 viewed", "statusline() formats current session")
package.loaded["jpr.session"] = nil

print("statusline_spec: ok")
