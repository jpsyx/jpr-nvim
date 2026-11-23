-- Specs for :Jpr push, worktreeStatusChanged, headMoved notifications, and
-- restoreConflict resolution ("Resolve myself" and "Ask agent to resolve").
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local view_mode = require("jpr.view_mode")

local function read_bytes(path)
    local file_descriptor = vim.uv.fs_open(path, "r", 438)
    if not file_descriptor then
        return ""
    end
    local stat = vim.uv.fs_fstat(file_descriptor)
    local data = stat and stat.size > 0 and vim.uv.fs_read(file_descriptor, stat.size, 0) or ""
    vim.uv.fs_close(file_descriptor)
    return data or ""
end

local function create_fake_agent_script(script_path, capture_file)
    local lines = {
        "#!/bin/sh",
        "stty raw -echo 2>/dev/null || true",
        "exec cat > " .. vim.fn.shellescape(capture_file),
    }
    vim.fn.writefile(lines, script_path)
    vim.uv.fs_chmod(script_path, 493)
end

local function setup_test_context()
    view_mode.path = vim.fn.tempname()
    local engine_log = vim.fn.tempname()
    local capture_file = vim.fn.tempname()
    local worktree = vim.fn.tempname()
    vim.fn.mkdir(worktree, "p")
    vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")
    local fake_agent = worktree .. "/fake-agent.sh"
    create_fake_agent_script(fake_agent, capture_file)

    local notifications = {}
    vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
    end

    vim.env.FAKE_ENGINE_LOG = engine_log
    jpr.setup({
        binary = root .. "/tests/lua/fixtures/fake_engine.sh",
        claude_cmd = fake_agent,
        codex_cmd = fake_agent,
        agent = "claude",
    })

    session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
    local review = session.current()
    assert(vim.wait(3000, function()
        return review.view.pr ~= nil
    end), "session syncs")

    return {
        review = review,
        worktree = worktree,
        engine_log = engine_log,
        capture_file = capture_file,
        notifications = notifications,
    }
end

local function find_notification(notifications, text, expected_level)
    for _, entry in ipairs(notifications) do
        local does_match_level = expected_level == nil or entry.level == expected_level
        if does_match_level and entry.message:find(text, 1, true) then
            return entry
        end
    end
    return nil
end

local function clear_list(items)
    for index = #items, 1, -1 do
        items[index] = nil
    end
end

local function test_push_command(context)
    clear_list(context.notifications)
    context.review.view.viewedCount = 99
    jpr.command({ "push" })
    assert(vim.wait(3000, function()
        return find_notification(context.notifications, "pushed abc1234", vim.log.levels.INFO) ~= nil
    end), ":Jpr push notifies pushed abc1234: " .. vim.inspect(context.notifications))
    assert(#helpers.read_requests(context.engine_log, "push") == 1, "push RPC sent once")
    assert(context.review.view.viewedCount == 0, "push updates session.view from result.view")

    vim.env.FAKE_ENGINE_PUSH_SYNC_ERROR = "offline"
    session.start({ worktree = context.worktree, repo = "octo/widgets", number = 8 })
    local offline_session = session.current()
    assert(vim.wait(3000, function()
        return offline_session.view.pr ~= nil
    end), "offline test session syncs")
    clear_list(context.notifications)
    session.push_current()
    assert(vim.wait(3000, function()
        return find_notification(context.notifications, "offline", vim.log.levels.WARN) ~= nil
    end), "push syncError emits WARN: " .. vim.inspect(context.notifications))
    assert(find_notification(context.notifications, "pushed abc1234", vim.log.levels.INFO) ~= nil, "push still emits INFO")
    session.close_current()
    vim.env.FAKE_ENGINE_PUSH_SYNC_ERROR = nil
    vim.api.nvim_set_current_tabpage(context.review.tab)
end

local function test_worktree_status_changed(context)
    local updated_view = vim.deepcopy(context.review.view)
    updated_view.worktreeStatus = { isDirty = true, ahead = 1, behind = 0 }
    session.on_notification(context.review, "event", {
        type = "worktreeStatusChanged",
        view = updated_view,
    })
    assert(context.review.view.worktreeStatus.isDirty == true, "worktreeStatusChanged updates session.view")
    local panel_lines = vim.api.nvim_buf_get_lines(context.review.panel.buf, 0, -1, false)
    assert(
        panel_lines[2] and panel_lines[2]:find("dirty \194\183 \226\134\1451 \226\134\1470", 1, true) ~= nil,
        "panel redraws dirty and ahead/behind badge: " .. vim.inspect(panel_lines)
    )
end

local function test_head_moved_fast_forward(context)
    clear_list(context.notifications)
    local target_view = vim.deepcopy(context.review.view)
    target_view.pr.headSha = "head222"
    session.on_notification(context.review, "event", {
        type = "headMoved",
        previousSha = "head111",
        headSha = "head222",
        outcome = "alreadyAtTarget",
        conflictedPaths = {},
        view = target_view,
    })
    assert(context.review.view.pr.headSha == "head222", "alreadyAtTarget updates session.view")
    assert(#context.notifications == 0, "alreadyAtTarget stays quiet: " .. vim.inspect(context.notifications))

    local fast_forward_view = vim.deepcopy(context.review.view)
    fast_forward_view.pr.headSha = "ff98765"
    session.on_notification(context.review, "event", {
        type = "headMoved",
        previousSha = "aa11223\27[31m",
        headSha = "ff98765\n\7",
        outcome = "fastForwarded",
        conflictedPaths = {},
        view = fast_forward_view,
    })
    assert(context.review.view.pr.headSha == "ff98765", "fastForwarded updates session.view")
    local info_entry = find_notification(context.notifications, "ff98765", vim.log.levels.INFO)
    assert(info_entry ~= nil and info_entry.message:find("%c") == nil, "fastForwarded emits sanitized INFO")

    clear_list(context.notifications)
    session.on_notification(context.review, "event", {
        type = "headMoved",
        previousSha = "\27",
        headSha = "\n",
        outcome = "fastForwarded",
        conflictedPaths = {},
        view = fast_forward_view,
    })
    local empty_sha_entry = find_notification(context.notifications, "fast-forwarded", vim.log.levels.INFO)
    assert(empty_sha_entry ~= nil and empty_sha_entry.message:find("()", 1, true) == nil, "no empty () on blank SHAs")
end

local function test_head_moved_warnings(context)
    local current_view = vim.deepcopy(context.review.view)
    for _, outcome in ipairs({ "diverged", "failed" }) do
        clear_list(context.notifications)
        session.on_notification(context.review, "event", {
            type = "headMoved",
            previousSha = "ff98765",
            headSha = "bad9999\27[2J",
            outcome = outcome,
            message = outcome .. " detail\27[31m\nwith\0controls",
            conflictedPaths = {},
            view = current_view,
        })
        local warn_entry = find_notification(context.notifications, outcome .. " detail[31m withcontrols", vim.log.levels.WARN)
        assert(warn_entry ~= nil, outcome .. " emits sanitized WARN: " .. vim.inspect(context.notifications))
        assert(warn_entry.message:find("%c") == nil, outcome .. " strips control characters")
    end
end

local function test_restore_conflict_resolve_myself(context)
    vim.fn.mkdir(context.worktree .. "/.git", "p")
    vim.fn.writefile({ "[core]" }, context.worktree .. "/.git/config")
    local original_select = vim.ui.select
    local captured_items, captured_prompt
    vim.ui.select = function(items, opts, on_choice)
        captured_items = items
        captured_prompt = opts and opts.prompt or ""
        on_choice("Resolve myself")
    end

    local conflict_view = vim.deepcopy(context.review.view)
    session.on_notification(context.review, "event", {
        type = "headMoved",
        previousSha = "head1",
        headSha = "head2",
        outcome = "restoreConflict",
        conflictedPaths = { ".git", ".git/config", "sub/.git/hooks", "../outside.txt", "/etc/passwd", "bad\nname.md", "README.md" },
        view = conflict_view,
    })
    vim.ui.select = original_select

    assert(vim.deep_equal(captured_items, { "Resolve myself", "Ask agent to resolve" }), "conflict prompt choices")
    assert(captured_prompt:find("1 file", 1, true) ~= nil, "only safe non-.git relative paths counted: " .. tostring(captured_prompt))
    local main_win = require("jpr.views.main_window").find(context.review)
    local opened_name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(main_win))
    assert(
        vim.fn.resolve(opened_name) == vim.fn.resolve(context.worktree .. "/README.md"),
        "Resolve myself opens safe conflictedPaths[1] in main window: " .. opened_name
    )
end

local function test_restore_conflict_ask_agent(context)
    clear_list(context.notifications)
    require("jpr.agent").resolve_conflicts(context.review, { ".git", ".git/config", "../outside.txt" })
    assert(#helpers.read_requests(context.engine_log, "prepareConflictResolution") == 0, "unsafe .git paths rejected in agent.resolve_conflicts")
    assert(find_notification(context.notifications, "no conflicted files", vim.log.levels.ERROR) ~= nil, "notifies error when all paths unsafe")

    local original_select = vim.ui.select
    vim.ui.select = function(_, _, on_choice)
        on_choice("Ask agent to resolve")
    end

    local conflict_view = vim.deepcopy(context.review.view)
    session.on_notification(context.review, "event", {
        type = "headMoved",
        previousSha = "head2",
        headSha = "head3",
        outcome = "restoreConflict",
        conflictedPaths = { ".git/config", "../outside.txt", "README.md" },
        view = conflict_view,
    })
    vim.ui.select = original_select

    assert(vim.wait(3000, function()
        return #helpers.read_requests(context.engine_log, "confirmSend") == 1
    end), "Ask agent confirms conflict round")

    local prepare_requests = helpers.read_requests(context.engine_log, "prepareConflictResolution")
    assert(#prepare_requests == 1, "prepareConflictResolution called once")
    assert(vim.deep_equal(prepare_requests[1].params.paths, { "README.md" }), "passes validated conflictedPaths")
    assert(prepare_requests[1].params.agent == "claude", "passes configured agent")

    local expected_paste = "\27[200~Resolve conflicts in README.md\27[201~\r"
    assert(vim.wait(3000, function()
        return read_bytes(context.capture_file):find(expected_paste, 1, true) ~= nil
    end), "delivers conflict prompt to agent terminal")

    local confirm_request = helpers.read_requests(context.engine_log, "confirmSend")[1]
    assert(confirm_request.params.kind == "conflict", "confirmSend kind is conflict")
    assert(vim.deep_equal(confirm_request.params.threadIds, {}), "confirmSend threadIds is empty")
end

local context = setup_test_context()
test_push_command(context)
test_worktree_status_changed(context)
test_head_moved_fast_forward(context)
test_head_moved_warnings(context)
test_restore_conflict_resolve_myself(context)
test_restore_conflict_ask_agent(context)
session.close_current()
vim.env.FAKE_ENGINE_LOG = nil

print("push_and_head_moved_spec: ok")
