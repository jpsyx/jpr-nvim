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
        "printf '\\033[?2004h'",
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
    assert(type(agent.parse_command_argv) == "function", "exports parse_command_argv")
    assert(type(agent.is_claude_vim_mode_enabled) == "function", "exports is_claude_vim_mode_enabled")
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
        agent_load_toggleterm = false,
        agent_submit_delay_ms = 20,
        agent_ready_settle_ms = 10,
        agent_ready_timeout_ms = 200,
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

local function test_cold_start_confirm_cancel_and_cli_prompt(context)
    local review = context.review
    local origin_win = vim.api.nvim_get_current_win()

    -- 1. Canceling confirmation leaves review.agent nil and sends zero confirmSend RPCs.
    session.send_current()
    assert(vim.wait(3000, function()
        return helpers.find_floating_win("Send to Coding Agent") ~= nil
    end), "send opens confirmation modal")
    local modal_text = helpers.current_text()
    assert(modal_text:find("Send 1 local review thread to Claude?", 1, true) ~= nil, "modal shows exact count: " .. modal_text)
    helpers.press_key("q")
    assert(helpers.find_floating_win("Send to Coding Agent") == nil, "q closes confirmation modal")
    assert(review.agent == nil, "canceled send never spawns agent")
    assert(#helpers.read_requests(context.engine_log, "confirmSend") == 0, "canceled send never calls confirmSend")

    -- 2. Confirming cold-start send passes -- <prompt> in CLI argv, preserves focus, sets bufhidden=hide, and confirms.
    vim.api.nvim_set_current_win(origin_win)
    session.send_current()
    assert(vim.wait(3000, function()
        return helpers.find_floating_win("Send to Coding Agent") ~= nil
    end), "second send opens confirmation modal")
    helpers.press_key("<CR>")

    assert(vim.wait(3000, function()
        return #helpers.read_requests(context.engine_log, "confirmSend") == 1
    end), "confirmed cold-start send confirms round")
    assert(review.agent ~= nil and review.agent.win ~= nil and vim.api.nvim_win_is_valid(review.agent.win), "agent split opened")
    assert(vim.api.nvim_get_current_win() == origin_win, "cold-start send preserves focus in review buffer")
    assert(vim.bo[review.agent.buf].bufhidden == "hide", "agent terminal sets bufhidden = hide")

    assert(vim.wait(3000, function()
        return vim.fn.filereadable(context.metadata_log) == 1 and #vim.fn.readfile(context.metadata_log) == 1
    end), "fake agent recorded cold-start launch metadata")
    local metadata_line = vim.fn.readfile(context.metadata_log)[1]
    local expected_cwd = vim.uv.fs_realpath(context.worktree) or context.worktree
    assert(metadata_line:find(expected_cwd .. "|/tmp/jpr-fake.sock|7|", 1, true) == 1, "agent env and cwd: " .. metadata_line)
    assert(metadata_line:find("--session-id 00000000-0000-4000-8000-000000000001 -- Review local thread loc-1", 1, true) ~= nil, "cold-start passed -- prompt: " .. metadata_line)

    local first_confirm = helpers.read_requests(context.engine_log, "confirmSend")[1]
    assert(first_confirm.params.kind == "send", "confirmSend kind is send")
    assert(vim.deep_equal(first_confirm.params.threadIds, { "loc-1" }), "confirmSend includes loc-1")
end

local function test_agent_toggle_winclose_and_warm_send_prepass(context)
    local review = context.review
    local main_window_module = require("jpr.views.main_window")
    local agent_window = review.agent.win
    local agent_buffer = review.agent.buf
    local agent_job = review.agent.job

    assert(vim.w[agent_window].jpr_side == true, "agent window marked as jpr_side")
    assert(vim.wo[agent_window].winfixwidth == true, "agent window sets winfixwidth")
    assert(main_window_module.find(review) ~= agent_window, "main_window.find skips agent side window")
    assert(vim.api.nvim_win_get_position(agent_window)[2] > vim.api.nvim_win_get_position(review.panel.win)[2], "agent split is on the right")

    -- Closing the window directly (:q / nvim_win_close) keeps the job alive.
    vim.api.nvim_win_close(agent_window, true)
    assert(vim.wait(1000, function() return review.agent.win == nil end), "WinClosed hides without killing job")
    assert(vim.api.nvim_buf_is_valid(agent_buffer) and agent.has_live_agent(review), "buffer and job stay alive after window close")

    -- Toggle reopens the exact same buffer and job without spawning a second process.
    session.agent_current()
    vim.cmd("stopinsert")
    assert(review.agent.win ~= nil and vim.api.nvim_win_is_valid(review.agent.win), "toggle re-shows window")
    assert(review.agent.buf == agent_buffer and review.agent.job == agent_job, "reuses existing buffer and job")
    assert(#vim.fn.readfile(context.metadata_log) == 1, "does not spawn a second job")

    -- Second :Jpr agent hides again.
    session.agent_current()
    assert(review.agent.win == nil, "toggle hides window")

    -- Warm single-thread send confirms, reveals split without stealing focus, and delivers via PTY bracketed paste + CR.
    local origin_win = review.panel.win
    vim.api.nvim_set_current_win(origin_win)
    agent.send(review, "loc-1")
    assert(vim.wait(3000, function()
        return helpers.find_floating_win("Send to Coding Agent") ~= nil
    end), "single-thread send opens confirmation modal")
    helpers.press_key("<CR>")
    assert(vim.wait(3000, function()
        return #helpers.read_requests(context.engine_log, "confirmSend") == 2
    end), "warm single-thread agent.send confirms")
    assert(review.agent.win ~= nil and vim.api.nvim_win_is_valid(review.agent.win), "warm send auto-reveals agent panel")
    assert(vim.api.nvim_get_current_win() == origin_win, "warm send preserves focus in review buffer")
    local prepare_requests = helpers.read_requests(context.engine_log, "prepareSend")
    assert(prepare_requests[3].params.threadId == "loc-1", "single-thread prepareSend passes threadId")
    assert(vim.wait(3000, function()
        return read_bytes(context.capture_file):find("\27[200~Review local thread loc-1\27[201~\r", 1, true) ~= nil
    end), "warm send prompt pasted with bracketed paste and submit CR")

    -- Prepass delivers via PTY on warm agent without confirmation dialog.
    session.prepass_current()
    assert(vim.wait(3000, function()
        return #helpers.read_requests(context.engine_log, "confirmSend") == 3
    end), ":Jpr prepass confirms")
    assert(vim.wait(3000, function()
        return read_bytes(context.capture_file):find("\27[200~Run pre-pass review\27[201~\r", 1, true) ~= nil
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
    assert(vim.wait(3000, function()
        return read_bytes(context.capture_file):find("\27[200~Tab dispatch\27[201~\t", 1, true) ~= nil
    end), "tab submit byte captured")

    confirm_before = #helpers.read_requests(context.engine_log, "confirmSend")
    jpr.config.agent_submit_delay_ms = 150
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
    jpr.config.agent_submit_delay_ms = 20

    local dead_buffer = review.agent.buf
    agent.ensure_open(review)
    assert(vim.wait(3000, function()
        return review.agent ~= nil and not review.agent.exited and review.agent.buf ~= dead_buffer
    end), "ensure_open replaces exited agent with fresh terminal")
    vim.cmd("stopinsert")
    assert(not vim.api.nvim_buf_is_valid(dead_buffer), "stale exited buffer is deleted")
end

local function test_window_recovery_coalescing_and_close(context)
    local review = context.review
    local scratch_buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(review.agent.win, scratch_buffer)
    assert(vim.api.nvim_win_get_buf(review.agent.win) == scratch_buffer, "window switched away from agent buffer")
    local restored = false
    agent.ensure_open(review, function()
        restored = true
    end)
    vim.cmd("stopinsert")
    assert(restored and vim.api.nvim_win_get_buf(review.agent.win) == review.agent.buf, "ensure_open restores agent buffer")
    vim.api.nvim_buf_delete(scratch_buffer, { force = true })

    -- Open a send confirmation modal and verify agent.close closes it cleanly.
    session.send_current()
    assert(vim.wait(3000, function()
        return helpers.find_floating_win("Send to Coding Agent") ~= nil
    end), "confirmation modal opened before agent.close")

    local agent_window = review.agent.win
    local agent_buffer = review.agent.buf
    local agent_job = review.agent.job
    agent.close(review)
    assert(helpers.find_floating_win("Send to Coding Agent") == nil, "agent.close closes open confirmation modal")
    assert(review.agent == nil, "agent.close clears session.agent")
    assert(not vim.api.nvim_win_is_valid(agent_window), "agent.close closes window")
    assert(not vim.api.nvim_buf_is_valid(agent_buffer), "agent.close deletes buffer")
    assert(vim.fn.jobwait({ agent_job }, 3000)[1] ~= -1, "agent.close stops job")

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
    vim.cmd("stopinsert")
    assert(ready_states[1] == ready_states[2] and ready_states[1] == review.agent, "both callbacks receive the single agent")
    assert(#helpers.read_requests(context.engine_log, "prepareAgentLaunch") == launch_before + 1, "only one prepareAgentLaunch sent")

    local confirm_before = #helpers.read_requests(context.engine_log, "confirmSend")
    local errors_before = #context.errors
    agent.deliver_dispatch(review, { round = 4, kind = "send", threadIds = { "loc-1" }, prompt = "" })
    assert(#context.errors == errors_before + 1, "empty prompt notifies error")
    assert(#helpers.read_requests(context.engine_log, "confirmSend") == confirm_before, "empty prompt never calls confirmSend")

    agent.close(review)
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
    vim.cmd("stopinsert")

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
test_cold_start_confirm_cancel_and_cli_prompt(context)
test_agent_toggle_winclose_and_warm_send_prepass(context)
test_codex_tab_and_exit_guards(context)
test_window_recovery_coalescing_and_close(context)
test_last_window_toggle_and_session_close(context)

print("agent_spec: ok")
