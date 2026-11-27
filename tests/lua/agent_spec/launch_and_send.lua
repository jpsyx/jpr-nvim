return function(context)
    local helpers = context.helpers
    local read_bytes = context.read_bytes
    local session = require("jpr.session")
    local agent = require("jpr.agent")

local function test_launch_argv_slug_and_paste_helpers_build_expected_payloads()
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
    assert(vim.deep_equal(agent.parse_command_argv("cl --model opus", "claude"), { "cl", "--model", "opus" }), "re-exports parse_command_argv")
    assert(agent.is_claude_vim_mode_enabled(home_directory, "") == false, "re-exports is_claude_vim_mode_enabled")
end

local function test_launch_argv_omits_session_flags_when_session_id_is_missing()
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


local function test_cold_start_send_cancels_cleanly_or_passes_prompt_via_cli_argv(context)
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

local function test_agent_toggle_keeps_job_alive_and_delivers_warm_send_and_prepass(context)
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


    test_launch_argv_slug_and_paste_helpers_build_expected_payloads()
    test_launch_argv_omits_session_flags_when_session_id_is_missing()
    test_cold_start_send_cancels_cleanly_or_passes_prompt_via_cli_argv(context)
    test_agent_toggle_keeps_job_alive_and_delivers_warm_send_and_prepass(context)
end
