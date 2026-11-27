return function(context)
    local helpers = context.helpers
    local read_bytes = context.read_bytes
    local jpr = require("jpr")
    local session = require("jpr.session")
    local agent = require("jpr.agent")

local function test_agent_sends_tab_submit_skips_confirm_on_exit_and_replaces_dead_buffer(context)
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

local function test_agent_recovers_window_coalesces_launch_and_handles_tab_and_errors(context)
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
    -- Overlapping deliver_dispatch during an in-flight prepareAgentLaunch must NOT drop the prompt.
    local confirm_before_overlap = #helpers.read_requests(context.engine_log, "confirmSend")
    agent.ensure_open(review)
    agent.deliver_dispatch(review, {
        round = 6,
        kind = "send",
        threadIds = { "loc-1" },
        prompt = "Overlapped dispatch prompt",
        profile = { kind = "claude", submitKey = "enter", submitDelayMs = 20 },
    })
    assert(vim.wait(3000, function()
        return #helpers.read_requests(context.engine_log, "confirmSend") == confirm_before_overlap + 1
    end), "overlapped deliver_dispatch confirms after PTY delivery")
    assert(vim.wait(3000, function()
        return read_bytes(context.capture_file):find("\27[200~Overlapped dispatch prompt\27[201~\r", 1, true) ~= nil
    end), "overlapped deliver_dispatch wrote prompt over PTY instead of dropping it")
    vim.cmd("stopinsert")
    agent.close(review)

    -- End-to-end cold-start with leading '-', newline, $HOME, and quotes delivers verbatim via CLI argv.
    local tricky_prompt = "- fix item\nCheck $HOME and 'single' \"double\""
    local metadata_count_before = #vim.fn.readfile(context.metadata_log)
    local confirm_before_tricky = #helpers.read_requests(context.engine_log, "confirmSend")
    agent.deliver_dispatch(review, {
        round = 7,
        kind = "send",
        threadIds = { "loc-1" },
        prompt = tricky_prompt,
        profile = { kind = "claude", submitKey = "enter", submitDelayMs = 20 },
    })
    assert(vim.wait(3000, function()
        return #helpers.read_requests(context.engine_log, "confirmSend") == confirm_before_tricky + 1
    end), "tricky cold-start confirms")
    assert(vim.wait(3000, function()
        return #vim.fn.readfile(context.metadata_log) > metadata_count_before
    end), "tricky cold-start logged argv")
    local tricky_log = table.concat(vim.fn.readfile(context.metadata_log), "\n")
    assert(tricky_log:find("-- - fix item\nCheck $HOME and 'single' \"double\"", 1, true) ~= nil, "literal tricky prompt delivered without shell expansion: " .. tricky_log)
    agent.close(review)

    -- Dedicated agent tab: :Jpr agent and ga inside the agent tab close the tab and return to review.tab.
    local saved_direction = jpr.config.agent_direction
    jpr.config.agent_direction = "tab"
    session.agent_current()
    assert(vim.wait(3000, function()
        return review.agent ~= nil and review.agent.win ~= nil and vim.api.nvim_win_get_tabpage(review.agent.win) ~= review.tab
    end), "dedicated agent tab opened")
    vim.cmd("stopinsert")
    assert(vim.api.nvim_get_current_tabpage() ~= review.tab, "cursor is in dedicated agent tab")
    session.agent_current()
    assert(vim.api.nvim_get_current_tabpage() == review.tab, ":Jpr agent from dedicated tab returns to review.tab")
    assert(agent.has_live_agent(review), "agent stays alive after :Jpr agent hides dedicated tab")
    session.agent_current()
    vim.cmd("stopinsert")
    assert(vim.api.nvim_get_current_tabpage() ~= review.tab, ":Jpr agent re-enters dedicated tab")
    helpers.press_key("ga")
    assert(vim.api.nvim_get_current_tabpage() == review.tab, "ga inside dedicated agent tab hides and returns to review.tab")
    assert(agent.has_live_agent(review), "agent stays alive after ga hides dedicated tab")
    agent.close(review)
    jpr.config.agent_direction = saved_direction

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

local function test_agent_toggle_preserves_last_window_and_session_close_stops_job(context)
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


    test_agent_sends_tab_submit_skips_confirm_on_exit_and_replaces_dead_buffer(context)
    test_agent_recovers_window_coalesces_launch_and_handles_tab_and_errors(context)
    test_agent_toggle_preserves_last_window_and_session_close_stops_job(context)
end
