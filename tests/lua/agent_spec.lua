local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local view_mode = require("jpr.view_mode")
local agent = require("jpr.agent")

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

local function create_fake_agent_script(script_path, metadata_log, capture_file)
    local lines = {
        "#!/bin/sh",
        "printf '%s\\n' \"$PWD|$JPR_SOCKET|$JPR_PR|$*\" >> " .. vim.fn.shellescape(metadata_log),
        "stty raw -echo 2>/dev/null || true",
        "exec cat > " .. vim.fn.shellescape(capture_file),
    }
    vim.fn.writefile(lines, script_path)
    vim.uv.fs_chmod(script_path, 493)
end

local function test_pure_helpers()
    local home_directory = vim.fn.tempname()
    local worktree = "/tmp/my_repo.work/pr-7"
    local session_id = "00000000-0000-4000-8000-000000000001"
    local slug = agent.build_claude_project_slug_from_worktree(worktree)
    assert(slug == "-tmp-my-repo-work-pr-7", "unexpected slug: " .. slug)
    assert(not agent.has_claude_transcript(worktree, session_id, home_directory), "transcript missing initially")

    local config = { agent = "claude", claude_cmd = "claude", codex_cmd = "codex" }
    local first_claude = agent.create_launch_argv_from_plan(config, worktree, { kind = "claude", sessionId = session_id, isResume = false }, home_directory)
    assert(vim.deep_equal(first_claude, { "claude", "--session-id", session_id }), "first claude argv")

    local resume_missing = agent.create_launch_argv_from_plan(config, worktree, { kind = "claude", sessionId = session_id, isResume = true }, home_directory)
    assert(vim.deep_equal(resume_missing, { "claude", "--session-id", session_id }), "claude fallback when transcript missing")

    local transcript_directory = home_directory .. "/.claude/projects/" .. slug
    vim.fn.mkdir(transcript_directory, "p")
    vim.fn.writefile({ "{}" }, transcript_directory .. "/" .. session_id .. ".jsonl")
    assert(agent.has_claude_transcript(worktree, session_id, home_directory), "transcript exists")

    local resume_present = agent.create_launch_argv_from_plan(config, worktree, { kind = "claude", sessionId = session_id, isResume = true }, home_directory)
    assert(vim.deep_equal(resume_present, { "claude", "--resume", session_id }), "claude resume argv")

    local fresh_codex = agent.create_launch_argv_from_plan(config, worktree, { kind = "codex", sessionId = session_id, isResume = false }, home_directory)
    assert(vim.deep_equal(fresh_codex, { "codex" }), "fresh codex argv")

    local resume_codex = agent.create_launch_argv_from_plan(config, worktree, { kind = "codex", sessionId = session_id, isResume = true }, home_directory)
    assert(vim.deep_equal(resume_codex, { "codex", "resume", session_id }), "resume codex argv")

    local dirty_prompt = "Line 1 \27[201~injected\27[31m text"
    local pasted = agent.build_bracketed_paste_from_prompt(dirty_prompt)
    assert(pasted == "\27[200~Line 1 [201~injected[31m text\27[201~", "bracketed paste strips ESC bytes")
    assert(agent.profile_to_submit_bytes({ submitKey = "tab" }) == "\t", "tab submit byte")
    assert(agent.profile_to_submit_bytes({ submitKey = "enter" }) == "\r", "enter submit byte")
    assert(agent.profile_to_submit_bytes(nil) == "\r", "default submit byte")
end

local function test_launch_argv_missing_session_id()
    local config = { agent = "claude", claude_cmd = "claude", codex_cmd = "codex" }
    local worktree = "/tmp/my_repo.work/pr-7"
    for _, missing_id in ipairs({ vim.NIL, "" }) do
        assert(
            vim.deep_equal(agent.create_launch_argv_from_plan(config, worktree, { kind = "claude", sessionId = missing_id, isResume = false }), { "claude" }),
            "claude ignores missing sessionId on launch"
        )
        assert(
            vim.deep_equal(agent.create_launch_argv_from_plan(config, worktree, { kind = "claude", sessionId = missing_id, isResume = true }), { "claude" }),
            "claude ignores missing sessionId on resume"
        )
        assert(
            vim.deep_equal(agent.create_launch_argv_from_plan(config, worktree, { kind = "codex", sessionId = missing_id, isResume = true }), { "codex" }),
            "codex ignores missing sessionId on resume"
        )
    end
end

local function setup_session_environment()
    view_mode.path = vim.fn.tempname()
    local engine_log = vim.fn.tempname()
    local metadata_log = vim.fn.tempname()
    local capture_file = vim.fn.tempname()
    local worktree = vim.fn.tempname()
    vim.fn.mkdir(worktree, "p")
    vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")
    local fake_agent = worktree .. "/fake-agent.sh"
    create_fake_agent_script(fake_agent, metadata_log, capture_file)

    vim.env.FAKE_ENGINE_LOG = engine_log
    jpr.setup({
        binary = root .. "/tests/lua/fixtures/fake_engine.sh",
        claude_cmd = fake_agent,
        codex_cmd = fake_agent,
        agent = "claude",
        agent_width = 50,
    })

    local errors = {}
    jpr.error = function(message)
        errors[#errors + 1] = message
    end
    jpr.info = function() end

    session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
    local review = session.current()
    assert(vim.wait(3000, function()
        return review.view.pr ~= nil
    end), "session syncs")

    return {
        review = review,
        worktree = worktree,
        engine_log = engine_log,
        metadata_log = metadata_log,
        capture_file = capture_file,
        errors = errors,
    }
end

local function test_agent_toggle_and_environment(context)
    local review = context.review
    local main_window_module = require("jpr.views.main_window")
    session.agent_current()
    assert(vim.wait(3000, function()
        return review.agent ~= nil and review.agent.win ~= nil and vim.api.nvim_win_is_valid(review.agent.win)
    end), ":Jpr agent opens right split")

    local agent_window = review.agent.win
    local agent_buffer = review.agent.buf
    local agent_job = review.agent.job
    assert(vim.w[agent_window].jpr_side == true, "agent window marked as jpr_side")
    assert(vim.wo[agent_window].winfixwidth == true, "agent window sets winfixwidth")
    assert(main_window_module.find(review) ~= agent_window, "main_window.find skips agent side window")
    assert(vim.api.nvim_win_get_position(agent_window)[2] > vim.api.nvim_win_get_position(review.panel.win)[2], "agent split is on the right")

    assert(vim.wait(3000, function()
        return vim.fn.filereadable(context.metadata_log) == 1 and #vim.fn.readfile(context.metadata_log) == 1
    end), "fake agent recorded launch metadata")
    local metadata_line = vim.fn.readfile(context.metadata_log)[1]
    local expected_cwd = vim.uv.fs_realpath(context.worktree) or context.worktree
    assert(metadata_line:find(expected_cwd .. "|/tmp/jpr-fake.sock|7|", 1, true) == 1, "agent env and cwd: " .. metadata_line)
    assert(metadata_line:find("--session-id 00000000-0000-4000-8000-000000000001", 1, true), "agent argv: " .. metadata_line)

    session.agent_current()
    assert(review.agent.win == nil and not vim.api.nvim_win_is_valid(agent_window), "second :Jpr agent hides window")
    assert(vim.api.nvim_buf_is_valid(agent_buffer) and not review.agent.exited, "terminal buffer and job stay alive when hidden")

    session.agent_current()
    assert(review.agent.win ~= nil and vim.api.nvim_win_is_valid(review.agent.win), "third :Jpr agent re-shows window")
    assert(review.agent.buf == agent_buffer and review.agent.job == agent_job, "reuses existing buffer and job")
    assert(#vim.fn.readfile(context.metadata_log) == 1, "does not spawn a second job")
end

local function test_send_and_prepass(context)
    local review = context.review
    session.agent_current()
    assert(review.agent.win == nil, "agent window starts hidden before :Jpr send")

    session.send_current()
    assert(vim.wait(3000, function()
        local requests = helpers.read_requests(context.engine_log, "confirmSend")
        return #requests == 1
    end), ":Jpr send confirms delivery")
    assert(review.agent.win ~= nil and vim.api.nvim_win_is_valid(review.agent.win), ":Jpr send auto-opens agent panel")

    local expected_send = "\27[200~Review local thread loc-1\27[201~\r"
    assert(vim.wait(3000, function()
        return read_bytes(context.capture_file):find(expected_send, 1, true) ~= nil
    end), "send prompt pasted with bracketed paste and submit CR")

    local first_confirm = helpers.read_requests(context.engine_log, "confirmSend")[1]
    assert(first_confirm.params.kind == "send", "confirmSend kind is send")
    assert(vim.deep_equal(first_confirm.params.threadIds, { "loc-1" }), "confirmSend includes loc-1")

    agent.send(review, "loc-1")
    assert(vim.wait(3000, function()
        return #helpers.read_requests(context.engine_log, "confirmSend") == 2
    end), "single-thread agent.send confirms")
    local prepare_requests = helpers.read_requests(context.engine_log, "prepareSend")
    assert(prepare_requests[2].params.threadId == "loc-1", "single-thread prepareSend passes threadId")

    session.prepass_current()
    assert(vim.wait(3000, function()
        return #helpers.read_requests(context.engine_log, "confirmSend") == 3
    end), ":Jpr prepass confirms")
    local expected_prepass = "\27[200~Run pre-pass review\27[201~\r"
    assert(vim.wait(3000, function()
        return read_bytes(context.capture_file):find(expected_prepass, 1, true) ~= nil
    end), "prepass prompt pasted with CR")
    local prepass_confirm = helpers.read_requests(context.engine_log, "confirmSend")[3]
    assert(prepass_confirm.params.kind == "prepass", "confirmSend kind is prepass")
    assert(vim.deep_equal(prepass_confirm.params.threadIds, {}), "prepass confirmSend threadIds is empty array")
end

local function test_codex_tab_and_exit_guards(context)
    local review = context.review
    local confirm_before = #helpers.read_requests(context.engine_log, "confirmSend")
    agent.deliver_dispatch(review, {
        round = 4,
        kind = "send",
        threadIds = { "loc-1" },
        prompt = "Tab dispatch",
        profile = { submitKey = "tab", submitDelayMs = 20 },
    })
    assert(vim.wait(3000, function()
        return #helpers.read_requests(context.engine_log, "confirmSend") == confirm_before + 1
    end), "tab dispatch confirms")
    assert(read_bytes(context.capture_file):find("\27[200~Tab dispatch\27[201~\t", 1, true) ~= nil, "tab submit byte captured")

    confirm_before = #helpers.read_requests(context.engine_log, "confirmSend")
    agent.deliver_dispatch(review, {
        round = 5,
        kind = "send",
        threadIds = { "loc-1" },
        prompt = "Aborted dispatch",
        profile = { submitKey = "enter", submitDelayMs = 150 },
    })
    vim.fn.jobstop(review.agent.job)
    assert(vim.wait(3000, function()
        return review.agent.exited == true
    end), "stopped job marks agent exited")
    vim.wait(250, function()
        return false
    end)
    assert(#helpers.read_requests(context.engine_log, "confirmSend") == confirm_before, "exited job skips confirmSend")

    local dead_buffer = review.agent.buf
    agent.ensure_open(review)
    assert(vim.wait(3000, function()
        return review.agent ~= nil and not review.agent.exited and review.agent.buf ~= dead_buffer
    end), "ensure_open replaces exited agent with fresh terminal")
    assert(not vim.api.nvim_buf_is_valid(dead_buffer), "stale exited buffer is deleted")
end

local function test_window_recovery_and_coalescing(context)
    local review = context.review
    local scratch_buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(review.agent.win, scratch_buffer)
    assert(vim.api.nvim_win_get_buf(review.agent.win) == scratch_buffer, "window switched away from agent buffer")
    local restored = false
    agent.ensure_open(review, function()
        restored = true
    end)
    assert(restored and vim.api.nvim_win_get_buf(review.agent.win) == review.agent.buf, "ensure_open restores agent buffer")
    vim.api.nvim_buf_delete(scratch_buffer, { force = true })

    agent.close(review)
    local launch_before = #helpers.read_requests(context.engine_log, "prepareAgentLaunch")
    local ready_states = {}
    agent.ensure_open(review, function(agent_state)
        ready_states[#ready_states + 1] = agent_state
    end)
    agent.ensure_open(review, function(agent_state)
        ready_states[#ready_states + 1] = agent_state
    end)
    assert(vim.wait(3000, function()
        return #ready_states == 2
    end), "coalesced ensure_open fires both callbacks")
    assert(ready_states[1] == ready_states[2] and ready_states[1] == review.agent, "both callbacks receive the single agent")
    assert(#helpers.read_requests(context.engine_log, "prepareAgentLaunch") == launch_before + 1, "only one prepareAgentLaunch sent")
end

local function test_guard_and_close(context)
    local review = context.review
    local confirm_before = #helpers.read_requests(context.engine_log, "confirmSend")
    local errors_before = #context.errors
    agent.deliver_dispatch(review, { round = 4, kind = "send", threadIds = { "loc-1" }, prompt = "" })
    assert(#context.errors == errors_before + 1, "empty prompt notifies error")
    assert(#helpers.read_requests(context.engine_log, "confirmSend") == confirm_before, "empty prompt never calls confirmSend")

    local agent_window = review.agent.win
    local agent_buffer = review.agent.buf
    local agent_job = review.agent.job
    agent.close(review)
    assert(review.agent == nil, "agent.close clears session.agent")
    assert(not vim.api.nvim_win_is_valid(agent_window), "agent.close closes window")
    assert(not vim.api.nvim_buf_is_valid(agent_buffer), "agent.close deletes buffer")
    assert(vim.fn.jobwait({ agent_job }, 3000)[1] ~= -1, "agent.close stops job")

    local original_command = jpr.config.claude_cmd
    jpr.config.claude_cmd = context.worktree .. "/missing-agent"
    errors_before = #context.errors
    local windows_before = #vim.api.nvim_tabpage_list_wins(review.tab)
    agent.ensure_open(review)
    assert(vim.wait(3000, function()
        return #context.errors > errors_before
    end), "missing agent binary notifies error")
    assert(review.agent == nil and #vim.api.nvim_tabpage_list_wins(review.tab) == windows_before, "failed spawn leaves no stray window")
    jpr.config.claude_cmd = original_command
end

local function test_last_window_toggle_and_session_close(context)
    local review = context.review
    session.agent_current()
    assert(vim.wait(3000, function()
        return review.agent ~= nil and review.agent.win ~= nil
    end), "reopens agent before last-window toggle and close_current")

    vim.api.nvim_set_current_win(review.agent.win)
    vim.cmd("only")
    local only_window = review.agent.win
    local errors_before = #context.errors
    agent.toggle(review)
    assert(review.agent.win == only_window and vim.api.nvim_win_is_valid(only_window), "toggle preserves last window")
    assert(#context.errors == errors_before + 1, "toggle notifies when last window cannot close")

    local second_buffer = review.agent.buf
    local second_job = review.agent.job
    session.close_current()
    assert(review.agent == nil, "session.close_current closes jpr.agent")
    assert(not vim.api.nvim_buf_is_valid(second_buffer), "session.close_current deletes agent buffer")
    assert(vim.fn.jobwait({ second_job }, 3000)[1] ~= -1, "session.close_current stops agent job")
end

test_pure_helpers()
test_launch_argv_missing_session_id()
local context = setup_session_environment()
test_agent_toggle_and_environment(context)
test_send_and_prepass(context)
test_codex_tab_and_exit_guards(context)
test_window_recovery_and_coalescing(context)
test_guard_and_close(context)
test_last_window_toggle_and_session_close(context)

print("agent_spec: ok")
