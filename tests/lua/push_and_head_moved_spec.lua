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
        "printf '%s\\n' \"$*\" > " .. vim.fn.shellescape(capture_file),
        "stty raw -echo 2>/dev/null || true",
        "exec cat >> " .. vim.fn.shellescape(capture_file),
    }
    vim.fn.writefile(lines, script_path)
    vim.uv.fs_chmod(script_path, 493)
end

local function setup_test_context()
    view_mode.path = vim.fn.tempname()
    local engine_log = vim.fn.tempname()
    local capture_file = vim.fn.tempname()
    local diff_override_file = vim.fn.tempname()
    local stream_override_file = vim.fn.tempname()
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
    vim.env.FAKE_ENGINE_DIFF_FILE = diff_override_file
    vim.env.FAKE_ENGINE_STREAM_FILE = stream_override_file
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
        diff_override_file = diff_override_file,
        stream_override_file = stream_override_file,
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

local function assert_push_command_updates_view_and_warns_on_sync_error(context)
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

local function assert_worktree_status_changed_redraws_panel_badge(context)
    local updated_view = vim.deepcopy(context.review.view)
    updated_view.worktreeStatus = { isDirty = true, ahead = 1, behind = 0 }
    session.on_notification(context.review, "event", {
        type = "worktreeStatusChanged",
        view = updated_view,
    })
    assert(context.review.view.worktreeStatus.isDirty == true, "worktreeStatusChanged updates session.view")
    local panel_lines = vim.api.nvim_buf_get_lines(context.review.panel.buf, 0, -1, false)
    assert(
        panel_lines[3] and panel_lines[3]:find("dirty \194\183 \226\134\1451 \226\134\1470", 1, true) ~= nil,
        "panel redraws dirty and ahead/behind badge: " .. vim.inspect(panel_lines)
    )
end

local function assert_head_moved_fast_forward_updates_view_and_sanitizes_shas(context)
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

local function assert_head_moved_diverged_and_failed_emit_sanitized_warnings(context)
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

local function assert_restore_conflict_resolve_myself_opens_safe_worktree_path(context)
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

local function assert_restore_conflict_ask_agent_dispatches_safe_paths(context)
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

    local expected_needle = "-- Resolve conflicts in README.md"
    assert(vim.wait(3000, function()
        return read_bytes(context.capture_file):find(expected_needle, 1, true) ~= nil
    end), "delivers conflict prompt to agent terminal: " .. vim.inspect(read_bytes(context.capture_file)))

    local confirm_request = helpers.read_requests(context.engine_log, "confirmSend")[1]
    assert(confirm_request.params.kind == "conflict", "confirmSend kind is conflict")
    assert(vim.deep_equal(confirm_request.params.threadIds, {}), "confirmSend threadIds is empty")
end

local function write_healed_engine_fixtures(context)
    local healed_diff = vim.json.encode({
        path = "README.md",
        binary = false,
        baseText = "hello\nhealed-base\n",
        added = { { line = 2, words = {} }, { line = 3, words = {} } },
        removed = { { above = 2, lines = { { text = "healed-base", words = {} } } } },
        threads = {},
    })
    local healed_stream = vim.json.encode({
        mode = "unified",
        rows = {
            { kind = "file", path = "README.md", additions = 2, deletions = 1, viewed = "UNVIEWED", folded = false },
            { kind = "hunk", path = "README.md", header = "@@ -1,2 +1,3 @@", target = 1 },
            {
                kind = "line",
                path = "README.md",
                left = nil,
                right = { line = 2, text = "healed-stream-line", change = "added", words = {} },
                target = 2,
            },
        },
    })
    vim.fn.writefile({ healed_diff }, context.diff_override_file)
    vim.fn.writefile({ healed_stream }, context.stream_override_file)
end

local function buffer_has_healed_diff_extmark(buf, diff_namespace)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if not vim.deep_equal(lines, { "hello", "healed line 2", "healed line 3" }) then
        return false
    end
    local marks = vim.api.nvim_buf_get_extmarks(buf, diff_namespace, 0, -1, { details = true })
    return vim.inspect(marks):find("healed%-base") ~= nil
end

local function emit_head_moved(review, head_sha, outcome, view, conflicted_paths)
    session.on_notification(review, "event", {
        type = "headMoved",
        previousSha = "abc123",
        headSha = head_sha,
        outcome = outcome,
        conflictedPaths = conflicted_paths or {},
        view = view,
    })
end

local function assert_self_healed_head_moved_redraws_unified_diff_and_stream(context)
    require("jpr.agent").close(context.review)
    session.stream_current()
    assert(vim.wait(3000, function()
        return require("jpr.views.stream").is_visible(context.review)
    end), "initial stream visible")
    local stream_win = vim.fn.win_findbuf(context.review.stream.buffers.main)[1]

    local file_win = vim.api.nvim_open_win(0, true, { split = "below", win = stream_win })
    vim.cmd.edit(vim.fn.fnameescape(context.worktree .. "/README.md"))
    local readme_buf = vim.api.nvim_win_get_buf(file_win)
    local diff_namespace = vim.api.nvim_create_namespace("jpr-diff")
    local def_view = vim.deepcopy(context.review.view)
    def_view.pr.headSha = "def456"
    emit_head_moved(context.review, "def456", "failed", def_view)
    assert(vim.wait(3000, function()
        local has_marks = #vim.api.nvim_buf_get_extmarks(readme_buf, diff_namespace, 0, -1, {}) > 0
        return has_marks and (context.review.stream.key or ""):find("def456", 1, true) ~= nil
    end), "Sync #1 failed headMoved draws pre-heal diff and stream at headSha=def456")

    vim.fn.writefile({ "hello", "healed line 2", "healed line 3" }, context.worktree .. "/README.md")
    write_healed_engine_fixtures(context)
    emit_head_moved(context.review, "def456", "fastForwarded", vim.deepcopy(def_view))
    assert(vim.wait(3000, function()
        return buffer_has_healed_diff_extmark(readme_buf, diff_namespace)
    end), "Sync #2 self-healed fastForwarded redraws unified diff overlay")
    assert(vim.wait(3000, function()
        local lines = vim.api.nvim_buf_get_lines(context.review.stream.buffers.main, 0, -1, false)
        return table.concat(lines, "\n"):find("healed-stream-line", 1, true) ~= nil
    end), "Sync #2 self-healed fastForwarded force-refreshes jpr://stream")
    vim.api.nvim_win_close(file_win, true)
end

local function assert_self_healed_head_moved_refreshes_split_base_buffer(context)
    vim.fn.delete(context.diff_override_file)
    vim.fn.delete(context.stream_override_file)
    session.toggle_view()
    local main_win = require("jpr.views.main_window").find(context.review)
    require("jpr.views.main_window").edit(context.review, main_win, "README.md")
    local split_view = vim.deepcopy(context.review.view)
    split_view.pr.headSha = "splitdef"
    emit_head_moved(context.review, "splitdef", "failed", split_view)
    assert(vim.wait(3000, function()
        local split_record = context.review.diff.splits[main_win]
        return split_record ~= nil and vim.api.nvim_buf_is_valid(split_record.base_buf)
    end), "Sync #1 failed headMoved opens initial split base buffer")

    write_healed_engine_fixtures(context)
    local original_select = vim.ui.select
    vim.ui.select = function(_, _, on_choice)
        on_choice(nil)
    end
    emit_head_moved(context.review, "splitdef", "restoreConflict", vim.deepcopy(split_view), { "README.md" })
    vim.ui.select = original_select
    assert(vim.wait(3000, function()
        local split_record = context.review.diff.splits[main_win]
        local is_valid = split_record and vim.api.nvim_buf_is_valid(split_record.base_buf)
        return is_valid and vim.deep_equal(vim.api.nvim_buf_get_lines(split_record.base_buf, 0, -1, false), { "hello", "healed-base" })
    end), "Sync #2 self-healed restoreConflict refreshes split base buffer")
    session.toggle_view()
    vim.fn.delete(context.diff_override_file)
    vim.fn.delete(context.stream_override_file)
end

local context = setup_test_context()
assert_push_command_updates_view_and_warns_on_sync_error(context)
assert_worktree_status_changed_redraws_panel_badge(context)
assert_head_moved_fast_forward_updates_view_and_sanitizes_shas(context)
assert_head_moved_diverged_and_failed_emit_sanitized_warnings(context)
assert_restore_conflict_resolve_myself_opens_safe_worktree_path(context)
assert_restore_conflict_ask_agent_dispatches_safe_paths(context)
assert_self_healed_head_moved_redraws_unified_diff_and_stream(context)
assert_self_healed_head_moved_refreshes_split_base_buffer(context)
session.close_current()
vim.env.FAKE_ENGINE_LOG = nil
vim.env.FAKE_ENGINE_DIFF_FILE = nil
vim.env.FAKE_ENGINE_STREAM_FILE = nil

print("push_and_head_moved_spec: ok")
