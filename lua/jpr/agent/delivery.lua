-- Readiness-gated warm PTY delivery, bracketed paste sanitization, and
-- Claude Vim-mode VISUAL-only ESC guard before submitting prompts.
local command = require("jpr.agent.command")
local terminal = require("jpr.agent.terminal")

local M = {}

local BRACKETED_PASTE_ENABLE_SEQ = "\27[?2004h"
local VISUAL_EXIT_DELAY_MS = 50
local DEFAULT_READY_SETTLE_MS = 150
local DEFAULT_CLAUDE_SUBMIT_DELAY_MS = 350
local DEFAULT_SUBMIT_DELAY_MS = 200
local STATUS_LOOKBACK_NON_EMPTY_LINES = 6

local function jpr()
    return require("jpr")
end

--- Strips raw ESC bytes from `prompt` and wraps it in bracketed-paste escapes.
function M.build_bracketed_paste_from_prompt(prompt)
    local sanitized = tostring(prompt or ""):gsub("\27", "")
    return "\27[200~" .. sanitized .. "\27[201~"
end

--- Converts a delivery `profile` into the trailing submit byte sequence.
function M.profile_to_submit_bytes(profile)
    if type(profile) == "table" and profile.submitKey == "tab" then
        return "\t"
    end
    return "\r"
end

--- Computes the paste-to-submit settle delay in milliseconds from `config`,
--- `profile`, and agent `kind`.
function M.resolve_submit_delay_ms(config, profile, kind)
    local active_config = type(config) == "table" and config or jpr().config
    if type(active_config.agent_submit_delay_ms) == "number" and active_config.agent_submit_delay_ms >= 0 then
        return active_config.agent_submit_delay_ms
    end
    local profile_delay = (type(profile) == "table" and type(profile.submitDelayMs) == "number")
        and profile.submitDelayMs
        or DEFAULT_SUBMIT_DELAY_MS
    if kind == "claude" then
        return math.max(profile_delay, DEFAULT_CLAUDE_SUBMIT_DELAY_MS)
    end
    return profile_delay
end

--- Whether the bottom status lines of terminal buffer `buf` currently display
--- Claude Code's Vim `-- VISUAL` indicator (`-- VISUAL --` / `-- VISUAL LINE --`).
function M.is_buffer_in_visual_mode(buf)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    local total_lines = vim.api.nvim_buf_line_count(buf)
    if total_lines == 0 then
        return false
    end
    local start_row = math.max(0, total_lines - 30)
    local lines = vim.api.nvim_buf_get_lines(buf, start_row, total_lines, false)
    local seen_non_empty = 0
    for index = #lines, 1, -1 do
        local trimmed = vim.trim(lines[index] or "")
        if trimmed ~= "" then
            seen_non_empty = seen_non_empty + 1
            if trimmed:find("-- VISUAL", 1, true) ~= nil then
                return true
            end
            if seen_non_empty >= STATUS_LOOKBACK_NON_EMPTY_LINES then
                break
            end
        end
    end
    return false
end

local function is_active_target(session, agent_state)
    return session ~= nil
        and not session.closing
        and session.agent == agent_state
        and terminal.has_live_agent(session)
end

local function send_terminal_bytes(agent_state, bytes, error_message)
    local ok, written = pcall(vim.fn.chansend, agent_state.job, bytes)
    if not ok or type(written) ~= "number" or written <= 0 then
        jpr().error(error_message)
        return false
    end
    return true
end

local function paste_and_submit(session, agent_state, dispatch, on_submitted)
    if not is_active_target(session, agent_state) then
        return
    end
    local paste_bytes = M.build_bracketed_paste_from_prompt(dispatch.prompt)
    if not send_terminal_bytes(agent_state, paste_bytes, "could not write prompt to the agent terminal") then
        return
    end
    local delay_ms = M.resolve_submit_delay_ms(jpr().config, dispatch.profile, agent_state.kind)
    vim.defer_fn(function()
        if not is_active_target(session, agent_state) then
            return
        end
        local submit_bytes = M.profile_to_submit_bytes(dispatch.profile)
        if not send_terminal_bytes(agent_state, submit_bytes, "could not submit prompt in the agent terminal") then
            return
        end
        terminal.scroll_to_bottom(agent_state)
        if type(on_submitted) == "function" then
            on_submitted(dispatch)
        end
    end, delay_ms)
end

local function deliver_now(session, agent_state, dispatch, on_submitted)
    if not is_active_target(session, agent_state) then
        return
    end
    local needs_visual_exit = agent_state.kind == "claude"
        and command.is_claude_vim_mode_enabled()
        and M.is_buffer_in_visual_mode(agent_state.buf)
    if not needs_visual_exit then
        return paste_and_submit(session, agent_state, dispatch, on_submitted)
    end
    if not send_terminal_bytes(agent_state, "\27", "could not exit visual mode in the agent terminal") then
        return
    end
    vim.defer_fn(function()
        paste_and_submit(session, agent_state, dispatch, on_submitted)
    end, VISUAL_EXIT_DELAY_MS)
end

local function flush_pending_dispatches(agent_state)
    local queued = agent_state.pending_dispatches
    if type(queued) ~= "table" or #queued == 0 then
        return
    end
    agent_state.pending_dispatches = {}
    for _, entry in ipairs(queued) do
        deliver_now(entry.session, agent_state, entry.dispatch, entry.on_submitted)
    end
end

local function mark_ready_and_flush(agent_state, settle_ms)
    if agent_state.is_ready or agent_state.exited then
        return
    end
    agent_state.is_ready = true
    if settle_ms and settle_ms > 0 then
        vim.defer_fn(function()
            if not agent_state.exited then
                flush_pending_dispatches(agent_state)
            end
        end, settle_ms)
    else
        flush_pending_dispatches(agent_state)
    end
end

--- Observes PTY `on_stdout` chunks for DECSET bracketed-paste enablement
--- (`\27[?2004h`) and flushes queued warm dispatches once ready.
function M.on_stdout(agent_state, data)
    if not agent_state or agent_state.is_ready or agent_state.exited or type(data) ~= "table" then
        return
    end
    for _, chunk in ipairs(data) do
        if type(chunk) == "string" and chunk:find(BRACKETED_PASTE_ENABLE_SEQ, 1, true) ~= nil then
            local config = jpr().config
            local settle_ms = (type(config.agent_ready_settle_ms) == "number" and config.agent_ready_settle_ms >= 0)
                and config.agent_ready_settle_ms
                or DEFAULT_READY_SETTLE_MS
            mark_ready_and_flush(agent_state, settle_ms)
            return
        end
    end
end

--- Starts a bounded fallback readiness timer so CLIs or test fixtures that never
--- emit `\27[?2004h` still become ready and flush queued dispatches.
function M.start_ready_fallback_timer(session, agent_state, timeout_ms)
    local delay_ms = (type(timeout_ms) == "number" and timeout_ms >= 0) and timeout_ms or 2500
    vim.defer_fn(function()
        if not is_active_target(session, agent_state) or agent_state.is_ready then
            return
        end
        mark_ready_and_flush(agent_state, 0)
    end, delay_ms)
end

--- Delivers `dispatch` to `agent_state` over PTY immediately when ready, or
--- queues it until PTY readiness is reached.
function M.enqueue_pty_dispatch(session, agent_state, dispatch, on_submitted)
    if not is_active_target(session, agent_state) then
        return
    end
    if agent_state.is_ready then
        return deliver_now(session, agent_state, dispatch, on_submitted)
    end
    agent_state.pending_dispatches = agent_state.pending_dispatches or {}
    agent_state.pending_dispatches[#agent_state.pending_dispatches + 1] = {
        session = session,
        dispatch = dispatch,
        on_submitted = on_submitted,
    }
end

return M
