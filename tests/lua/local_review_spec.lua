local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")

local function eq(actual, expected, label)
    assert(
        vim.deep_equal(actual, expected),
        ("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual))
    )
end

local function ne(actual, unexpected, label)
    assert(
        not vim.deep_equal(actual, unexpected),
        ("%s: expected value different from %s"):format(label, vim.inspect(unexpected))
    )
end

local helpers = { eq = eq, ne = ne }
local jpr = require("jpr")
local binary = require("jpr.binary")
local panel_render = require("jpr.render.panel")
local statusline = require("jpr.render.statusline")
local stream_render = require("jpr.render.stream")
local session = require("jpr.session")
local crash = require("jpr.session.crash")
local compose = require("jpr.comments.compose")
local commands_schema = require("jpr.commands.schema")

local notifications = {}
require("jpr.notify").set_listener(function(_, message, level)
    notifications[#notifications + 1] = { text = "jpr: " .. message, level = level }
end)

local function clear_notifications()
    for index = #notifications, 1, -1 do
        notifications[index] = nil
    end
end

local function has_notification(substring)
    for _, entry in ipairs(notifications) do
        if entry.text:find(substring, 1, true) ~= nil then
            return true
        end
    end
    return false
end

-- 1. Schema has 19 commands with `local` right after `open`, discriminant-first steps, and ref validation.
local ids = commands_schema.list_command_ids()
helpers.eq(#ids, 19, "expected 19 :Jpr subcommands")
helpers.eq(ids[1], "open", "first subcommand is open")
helpers.eq(ids[2], "local", "second subcommand is local")
local local_spec = commands_schema.find_command_spec("local")
helpers.eq(local_spec.label, "Review Current Worktree", "local label")
helpers.eq(local_spec.steps[1].id, "base_mode", "discriminant-first base_mode step")
helpers.eq(local_spec.steps[2].id, "base", "conditional base step")
helpers.eq(local_spec.steps[2].when({ base_mode = "auto" }), false, "auto hides base step")
helpers.eq(local_spec.steps[2].when({ base_mode = "custom" }), true, "custom shows base step")
local is_valid_bad_dash = local_spec.steps[2].validate("-bad")
helpers.eq(is_valid_bad_dash, false, "leading dash rejected")
local is_valid_ws = local_spec.steps[2].validate("a b")
helpers.eq(is_valid_ws, false, "whitespace rejected")
local is_valid_head = local_spec.steps[2].validate("HEAD")
helpers.eq(is_valid_head, true, "HEAD accepted")

-- 2. Direct `:Jpr local`, `:Jpr self` alias, and explicit base ref dispatch (without adding `self` to palette).
helpers.eq(commands_schema.find_command_spec("self"), nil, "self alias is not in command palette schema")
local captured_base_args = {}
local original_open_local = session.open_local
session.open_local = function(base_ref)
    captured_base_args[#captured_base_args + 1] = base_ref or "<nil>"
end
jpr.command({ "local" })
jpr.command({ "local", "HEAD" })
jpr.command({ "self" })
jpr.command({ "self", "HEAD" })
clear_notifications()
jpr.command({ "self", "HEAD", "extra" })
session.open_local = original_open_local
helpers.eq(captured_base_args, { "<nil>", "HEAD", "<nil>", "HEAD" }, "direct :Jpr local and :Jpr self dispatch")
helpers.eq(has_notification("too many arguments"), true, "extra arg on :Jpr self errors")

-- 3. `binary.create_agent_env_from_session` omits JPR_PR when nil and sets string when numeric.
local local_env = binary.create_agent_env_from_session("jpr-review", "/tmp/local.sock", nil, "/usr/bin")
helpers.eq(local_env.JPR_PR, nil, "JPR_PR omitted in local mode")
helpers.eq(local_env.JPR_SOCKET, "/tmp/local.sock", "JPR_SOCKET preserved")
local pr_env = binary.create_agent_env_from_session("jpr-review", "/tmp/pr.sock", 7, "/usr/bin")
helpers.eq(pr_env.JPR_PR, "7", "JPR_PR set for numeric PR")

-- 4. Panel, statusline, and stream key in local mode vs linked PR mode.
local local_view = {
    localContext = { branch = "feat/x", baseRef = "develop", baseSha = "base111" },
    files = {
        { path = "src/a.rs", additions = 3, deletions = 1, viewed = "VIEWED", threads = 1, localThreads = 1, isLocalOnly = true },
        { path = "src/b.rs", additions = 2, deletions = 0, viewed = "UNVIEWED", threads = 0, localThreads = 0, isLocalOnly = true },
    },
    viewedCount = 1,
    threadCount = 1,
    localUnsentCount = 2,
    queuedCount = 0,
    sync = { state = "never" },
    worktreeStatus = { isDirty = true, ahead = 1, behind = 0 },
}
local built_local = panel_render.build(local_view, 1000)
helpers.eq(built_local.lines[1], "LOCAL feat/x vs develop", "local panel header")
helpers.eq(built_local.lines[4], "local only · :Jpr sync to link PR", "local panel sync hint")
helpers.eq(built_local.lines[6], "  📄 Diff summary", "local diff summary row label")
helpers.eq(built_local.lines[7], "  💬 Local Notes", "local notes row label")
for _, line in ipairs(built_local.lines) do
    helpers.eq(line:find("[local]", 1, true), nil, "suppresses redundant [local] badge in unlinked local mode")
end

local local_session = {
    mode = "local",
    tab = vim.api.nvim_get_current_tabpage(),
    worktree = "/tmp/wt-local",
    branch = "feat/x",
    base_ref = "develop",
    view = local_view,
}
helpers.eq(
    statusline.build_statusline_from_session(local_session),
    "LOCAL feat/x · dirty ↑1 · 1/2 viewed · 2 local",
    "local statusline formatting"
)
helpers.eq(session.buf_key(local_session), "local-" .. tostring(local_session.tab), "local buf_key")

local key_v1 = stream_render.build_key_from_view(local_view)
local local_view_moved = vim.deepcopy(local_view)
local_view_moved.localContext.baseSha = "base222"
helpers.ne(stream_render.build_key_from_view(local_view_moved), key_v1, "stream key changes when baseSha moves")

local linked_view = {
    pr = { number = 7, owner = "octo", repo = "widgets", title = "Ship it", headSha = "h1", baseSha = "b1" },
    files = {
        { path = "src/a.rs", additions = 3, deletions = 1, viewed = "VIEWED", threads = 0, localThreads = 0, isLocalOnly = false },
        { path = "src/c.rs", additions = 1, deletions = 0, viewed = "UNVIEWED", threads = 0, localThreads = 0, isLocalOnly = true },
    },
    viewedCount = 1,
    threadCount = 0,
    localUnsentCount = 0,
    queuedCount = 0,
    sync = { state = "synced", at = 995 },
}
local built_linked = panel_render.build(linked_view, 1000)
helpers.eq(built_linked.lines[1], "#7 Ship it", "linked PR panel header")
helpers.eq(built_linked.lines[6], "  📄 Diff summary", "linked PR diff summary row")
helpers.eq(built_linked.lines[7], "  💬 Conversation", "linked PR conversation row")
helpers.ne(stream_render.build_key_from_view(linked_view), key_v1, "stream key changes on PR upgrade")

-- 5. Mid-session upgrade in `session.show` updates session metadata and notifies user.
clear_notifications()
local upgrade_session = {
    mode = "local",
    tab = vim.api.nvim_get_current_tabpage(),
    worktree = "/tmp/wt-local",
    branch = "feat/x",
    base_ref = "develop",
    view = local_view,
    is_read_only = true, -- skip stream/diff RPC calls in pure unit test
}
session.show(upgrade_session, vim.deepcopy(linked_view))
helpers.eq(upgrade_session.mode, "pr", "mode upgraded to pr")
helpers.eq(upgrade_session.number, 7, "number populated on upgrade")
helpers.eq(upgrade_session.repo, "octo/widgets", "repo populated on upgrade")
helpers.eq(has_notification("Linked to PR #7"), true, "upgrade notification emitted")
helpers.eq(
    statusline.build_statusline_from_session(upgrade_session),
    "PR #7 · [read-only] · 1/2 viewed",
    "statusline switches to PR #7 after upgrade"
)

-- 6. Compose locks destination to local in unlinked local session.
local compose_session = {
    mode = "local",
    tab = vim.api.nvim_get_current_tabpage(),
    branch = "feat/x",
    view = local_view,
}
compose.open_new(compose_session, { kind = "line", file = "src/a.rs", start = 1, ["end"] = 1, side = "RIGHT" })
helpers.eq(compose_session.compose.origin, "local", "compose locked to local origin")
local win_cfg = vim.api.nvim_win_get_config(compose_session.compose.win)
local footer_text = type(win_cfg.footer) == "table" and win_cfg.footer[1][1] or tostring(win_cfg.footer or "")
helpers.eq(footer_text, " <C-s> save · local review (no linked PR) · q cancel ", "local compose footer")
compose.close(compose_session)

-- 7. Crash log path & session label handle nil PR number cleanly.
local local_log = crash.build_log_path_from_number(nil, "feat/x")
helpers.eq(local_log:find("engine-local-feat-x.log", 1, true) ~= nil, true, "local crash log filename")
helpers.eq(crash.build_session_label(local_session), "local review (feat/x)", "local session label")

-- 8. Tab reuse and mismatch notice in `handle_local_probe_result` (Decision C1).
clear_notifications()
local tab = vim.api.nvim_get_current_tabpage()
session.by_tab[tab] = local_session
session.handle_local_probe_result({ mode = "local", worktree = "/tmp/wt-local", branch = "feat/x", baseRef = "HEAD", baseSha = "abc" })
helpers.eq(has_notification("run :Jpr close to switch"), true, "mismatch notice emitted on baseRef mismatch")
session.by_tab[tab] = nil

print("local_review_spec: ok")
