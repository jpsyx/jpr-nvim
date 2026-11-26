-- Specs for readiness-gated warm PTY delivery, bracketed paste sanitization,
-- and Claude Vim-mode VISUAL-only ESC handling.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")

local jpr = require("jpr")
local command = require("jpr.agent.command")
local delivery = require("jpr.agent.delivery")

local function test_pure_paste_submit_and_visual_detection()
    local dirty = "Line 1 \27[201~injected\27[31m text"
    assert(
        delivery.build_bracketed_paste_from_prompt(dirty) == "\27[200~Line 1 [201~injected[31m text\27[201~",
        "strips raw ESC bytes before wrapping bracketed paste"
    )
    assert(delivery.profile_to_submit_bytes({ submitKey = "tab" }) == "\t", "tab submit byte")
    assert(delivery.profile_to_submit_bytes({ submitKey = "enter" }) == "\r", "enter submit byte")
    assert(delivery.profile_to_submit_bytes(nil) == "\r", "default enter submit byte")

    assert(delivery.resolve_submit_delay_ms({}, { submitDelayMs = 200 }, "claude") == 350, "claude enforces >= 350ms settle")
    assert(delivery.resolve_submit_delay_ms({}, { submitDelayMs = 200 }, "codex") == 200, "codex keeps 200ms")
    assert(delivery.resolve_submit_delay_ms({ agent_submit_delay_ms = 25 }, { submitDelayMs = 200 }, "claude") == 25, "config override wins")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "prompt>", "", "-- VISUAL --", "" })
    assert(delivery.is_buffer_in_visual_mode(buf) == true, "detects -- VISUAL -- near bottom")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "prompt>", "-- VISUAL LINE --" })
    assert(delivery.is_buffer_in_visual_mode(buf) == true, "detects -- VISUAL LINE -- near bottom")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "prompt>", "-- NORMAL --" })
    assert(delivery.is_buffer_in_visual_mode(buf) == false, "NORMAL mode is not visual")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "prompt>", "-- INSERT --" })
    assert(delivery.is_buffer_in_visual_mode(buf) == false, "INSERT mode is not visual")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "-- VISUAL --",
        "line 1",
        "line 2",
        "line 3",
        "line 4",
        "line 5",
        "line 6",
        "-- NORMAL --",
    })
    assert(delivery.is_buffer_in_visual_mode(buf) == false, "ignores old -- VISUAL -- far above bottom")
    vim.api.nvim_buf_delete(buf, { force = true })
end

local function create_fake_agent_state(buf_lines, is_ready)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, buf_lines)
    local agent_state = {
        buf = buf,
        win = nil,
        job = 999,
        exited = false,
        kind = "claude",
        is_ready = is_ready,
        pending_dispatches = {},
    }
    local session = { closing = false, agent = agent_state }
    return session, agent_state
end

local function test_readiness_gating_and_fallback_timer()
    local writes = {}
    local submitted = {}
    local original_chansend = vim.fn.chansend
    local original_vim_mode = command.is_claude_vim_mode_enabled

    vim.fn.chansend = function(job, bytes)
        writes[#writes + 1] = { job = job, bytes = bytes }
        return #bytes
    end
    command.is_claude_vim_mode_enabled = function()
        return false
    end

    jpr.setup({ agent_submit_delay_ms = 20, agent_ready_settle_ms = 10 })

    -- 1. Queues while not ready, flushes once \27[?2004h arrives on on_stdout.
    local session, agent_state = create_fake_agent_state({ "> " }, false)
    local dispatch = {
        round = 1,
        kind = "send",
        threadIds = { "loc-1" },
        prompt = "Hello agent",
        profile = { submitKey = "enter", submitDelayMs = 20 },
    }
    delivery.enqueue_pty_dispatch(session, agent_state, dispatch, function(done_dispatch)
        submitted[#submitted + 1] = done_dispatch
    end)
    assert(#writes == 0, "does not write before PTY is ready")

    delivery.on_stdout(agent_state, { "booting...", "\27[?2004h> " })
    assert(vim.wait(1000, function() return #submitted == 1 end), "flushes after bracketed paste mode enabled")
    assert(#writes == 2, "wrote paste and submit as two separate writes: " .. vim.inspect(writes))
    assert(writes[1].bytes == "\27[200~Hello agent\27[201~", "first write is bracketed paste")
    assert(writes[2].bytes == "\r", "second write is CR")
    vim.api.nvim_buf_delete(agent_state.buf, { force = true })

    -- 2. Fallback readiness timer flushes even when \27[?2004h never arrives.
    writes, submitted = {}, {}
    local fallback_session, fallback_state = create_fake_agent_state({ "" }, false)
    delivery.start_ready_fallback_timer(fallback_session, fallback_state, 40)
    delivery.enqueue_pty_dispatch(fallback_session, fallback_state, dispatch, function(done_dispatch)
        submitted[#submitted + 1] = done_dispatch
    end)
    assert(#writes == 0, "queued before fallback timer fires")
    assert(vim.wait(1000, function() return #submitted == 1 end), "fallback timer flushes queued dispatch")
    assert(#writes == 2 and writes[2].bytes == "\r", "fallback flushed paste and CR")
    vim.api.nvim_buf_delete(fallback_state.buf, { force = true })

    vim.fn.chansend = original_chansend
    command.is_claude_vim_mode_enabled = original_vim_mode
end

local function test_vim_mode_normal_vs_visual_and_exit_guard()
    local writes = {}
    local submitted = {}
    local original_chansend = vim.fn.chansend
    local original_vim_mode = command.is_claude_vim_mode_enabled

    vim.fn.chansend = function(job, bytes)
        writes[#writes + 1] = { job = job, bytes = bytes }
        return #bytes
    end
    command.is_claude_vim_mode_enabled = function()
        return true
    end
    jpr.setup({ agent_submit_delay_ms = 20 })

    -- 1. Vim mode in NORMAL: NEVER sends ESC, only paste + CR.
    local normal_session, normal_state = create_fake_agent_state({ "prompt>", "-- NORMAL --" }, true)
    local dispatch = {
        round = 2,
        kind = "send",
        threadIds = { "loc-1" },
        prompt = "Normal mode send",
        profile = { submitKey = "enter", submitDelayMs = 20 },
    }
    delivery.enqueue_pty_dispatch(normal_session, normal_state, dispatch, function(done_dispatch)
        submitted[#submitted + 1] = done_dispatch
    end)
    assert(vim.wait(1000, function() return #submitted == 1 end), "normal mode submits")
    assert(#writes == 2, "normal mode writes only paste + CR (no ESC): " .. vim.inspect(writes))
    assert(writes[1].bytes == "\27[200~Normal mode send\27[201~", "normal paste")
    assert(writes[2].bytes == "\r", "normal CR")
    vim.api.nvim_buf_delete(normal_state.buf, { force = true })

    -- 2. Vim mode in VISUAL: sends ESC first, then paste, then CR.
    writes, submitted = {}, {}
    local visual_session, visual_state = create_fake_agent_state({ "prompt>", "-- VISUAL --" }, true)
    delivery.enqueue_pty_dispatch(visual_session, visual_state, dispatch, function(done_dispatch)
        submitted[#submitted + 1] = done_dispatch
    end)
    assert(vim.wait(1000, function() return #submitted == 1 end), "visual mode submits")
    assert(#writes == 3, "visual mode writes ESC, paste, CR: " .. vim.inspect(writes))
    assert(writes[1].bytes == "\27", "first write exits VISUAL mode")
    assert(writes[2].bytes == "\27[200~Normal mode send\27[201~", "second write is paste")
    assert(writes[3].bytes == "\r", "third write is CR")
    vim.api.nvim_buf_delete(visual_state.buf, { force = true })

    -- 3. Exit guard during settle delay skips submit and callback.
    writes, submitted = {}, {}
    jpr.setup({ agent_submit_delay_ms = 80 })
    local exit_session, exit_state = create_fake_agent_state({ "-- NORMAL --" }, true)
    delivery.enqueue_pty_dispatch(exit_session, exit_state, dispatch, function(done_dispatch)
        submitted[#submitted + 1] = done_dispatch
    end)
    assert(#writes == 1, "paste written before exit")
    exit_state.exited = true
    vim.wait(140, function() return false end)
    assert(#writes == 1 and #submitted == 0, "exited agent skips CR and on_submitted")
    vim.api.nvim_buf_delete(exit_state.buf, { force = true })

    vim.fn.chansend = original_chansend
    command.is_claude_vim_mode_enabled = original_vim_mode
end

test_pure_paste_submit_and_visual_detection()
test_readiness_gating_and_fallback_timer()
test_vim_mode_normal_vs_visual_and_exit_guard()

print("agent_delivery_spec: ok")
