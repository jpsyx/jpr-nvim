-- Interactive coding-agent side panel, bracketed-paste delivery, and
-- two-phase dispatch for `:Jpr agent`, `:Jpr send`, and `:Jpr prepass`.
local M = {}

local function jpr()
    return require("jpr")
end

--- Builds the Claude Code project directory slug for `worktree`.
function M.build_claude_project_slug_from_worktree(worktree)
    local slug = tostring(worktree or ""):gsub("[^%w%-]", "-")
    return slug
end

--- Whether a Claude Code transcript file already exists for `worktree` and
--- `session_id` under `home_directory` (defaulting to the current user's home).
function M.has_claude_transcript(worktree, session_id, home_directory)
    if type(session_id) ~= "string" or session_id == "" then
        return false
    end
    local target_home_directory = (type(home_directory) == "string" and home_directory ~= "")
        and home_directory
        or vim.uv.os_homedir()
    if type(target_home_directory) ~= "string" or target_home_directory == "" then
        return false
    end
    local slug = M.build_claude_project_slug_from_worktree(worktree)
    local transcript_path = target_home_directory .. "/.claude/projects/" .. slug .. "/" .. session_id .. ".jsonl"
    return vim.uv.fs_stat(transcript_path) ~= nil
end

--- Creates the terminal argv for launching or resuming the configured agent CLI
--- from `config`, `worktree`, and `launch_plan`.
function M.create_launch_argv_from_plan(config, worktree, launch_plan, home_directory)
    local plan = type(launch_plan) == "table" and launch_plan or {}
    local active_config = type(config) == "table" and config or jpr().config
    local kind = (type(plan.kind) == "string" and plan.kind ~= "") and plan.kind or active_config.agent or "claude"
    local has_session_id = type(plan.sessionId) == "string" and plan.sessionId ~= ""
    local is_resume = plan.isResume == true
    if kind == "codex" then
        local command = active_config.codex_cmd or "codex"
        if is_resume and has_session_id then
            return { command, "resume", plan.sessionId }
        end
        return { command }
    end
    local command = active_config.claude_cmd or "claude"
    if not has_session_id then
        return { command }
    end
    if is_resume and M.has_claude_transcript(worktree, plan.sessionId, home_directory) then
        return { command, "--resume", plan.sessionId }
    end
    return { command, "--session-id", plan.sessionId }
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

local function find_rightmost_window(session)
    local main_window = require("jpr.views.main_window")
    local best_normal, best_normal_column = nil, -1
    local best_any, best_any_column = nil, -1
    for _, window in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
        local window_config = vim.api.nvim_win_get_config(window)
        if not window_config.relative or window_config.relative == "" then
            local column = vim.api.nvim_win_get_position(window)[2]
            if column > best_any_column then
                best_any, best_any_column = window, column
            end
            if not main_window.is_side(session, window) and column > best_normal_column then
                best_normal, best_normal_column = window, column
            end
        end
    end
    return best_normal or best_any
end

local function style_agent_window(window)
    vim.w[window].jpr_side = true
    local function set_local(name, value)
        vim.api.nvim_set_option_value(name, value, { win = window, scope = "local" })
    end
    set_local("winfixwidth", true)
    set_local("number", false)
    set_local("relativenumber", false)
    set_local("signcolumn", "no")
end

local function open_right_split(session, buffer)
    if not session.tab or not vim.api.nvim_tabpage_is_valid(session.tab) then
        return nil
    end
    local target_window = find_rightmost_window(session) or vim.api.nvim_tabpage_list_wins(session.tab)[1]
    if not target_window or not vim.api.nvim_win_is_valid(target_window) then
        return nil
    end
    local width = jpr().config.agent_width or 56
    local ok, window = pcall(vim.api.nvim_open_win, buffer, true, {
        split = "right",
        win = target_window,
        width = width,
    })
    if not ok or not window or not vim.api.nvim_win_is_valid(window) then
        return nil
    end
    style_agent_window(window)
    return window
end

local function cleanup_agent_state(agent_state)
    if agent_state.win and vim.api.nvim_win_is_valid(agent_state.win) then
        pcall(vim.api.nvim_win_close, agent_state.win, true)
    end
    if agent_state.buf and vim.api.nvim_buf_is_valid(agent_state.buf) then
        pcall(vim.api.nvim_buf_delete, agent_state.buf, { force = true })
    end
end

local function is_live_agent(agent_state)
    return agent_state ~= nil
        and not agent_state.exited
        and type(agent_state.job) == "number"
        and agent_state.job > 0
        and agent_state.buf ~= nil
        and vim.api.nvim_buf_is_valid(agent_state.buf)
end

local function ensure_agent_window(session, agent_state)
    if agent_state.win and vim.api.nvim_win_is_valid(agent_state.win) then
        if vim.api.nvim_win_get_buf(agent_state.win) ~= agent_state.buf then
            pcall(vim.api.nvim_win_set_buf, agent_state.win, agent_state.buf)
        end
        return agent_state.win
    end
    agent_state.win = open_right_split(session, agent_state.buf)
    return agent_state.win
end

local function spawn_terminal(session, launch_plan)
    local buffer = vim.api.nvim_create_buf(false, true)
    local window = open_right_split(session, buffer)
    if not window then
        pcall(vim.api.nvim_buf_delete, buffer, { force = true })
        jpr().error("could not open agent terminal window")
        return nil
    end
    local binary = require("jpr.binary")
    local argv = M.create_launch_argv_from_plan(jpr().config, session.worktree, launch_plan)
    local socket = (type(launch_plan) == "table" and type(launch_plan.socket) == "string") and launch_plan.socket or ""
    local agent_env = binary.create_agent_env_from_session(jpr().binary_path(), socket, session.number, vim.env.PATH)
    local agent_state = { buf = buffer, win = window, job = 0, exited = false }
    local ok, job = pcall(vim.fn.jobstart, argv, {
        term = true,
        cwd = session.worktree,
        env = agent_env,
        on_exit = function()
            if session.agent and session.agent.job == agent_state.job then
                session.agent.exited = true
            end
        end,
    })
    if not ok or type(job) ~= "number" or job <= 0 then
        cleanup_agent_state(agent_state)
        jpr().error("could not start agent terminal: " .. tostring(argv[1]))
        return nil
    end
    agent_state.job = job
    session.agent = agent_state
    return agent_state
end

local function drain_callbacks(callbacks, agent_state)
    for _, callback in ipairs(callbacks) do
        callback(agent_state)
    end
end

local function finish_pending_launch(session, pending, launch_plan)
    if session.closing or session.agent_pending_callbacks ~= pending then
        return
    end
    session.agent_pending_callbacks = nil
    local agent_state
    if is_live_agent(session.agent) then
        ensure_agent_window(session, session.agent)
        agent_state = session.agent
    else
        M.close(session)
        agent_state = spawn_terminal(session, launch_plan)
    end
    if agent_state then
        drain_callbacks(pending, agent_state)
    end
end

--- Ensures `session`'s interactive agent terminal is alive and visible on the
--- right side of the tab, then calls `on_ready(agent_state)` when given.
function M.ensure_open(session, on_ready)
    if is_live_agent(session.agent) then
        ensure_agent_window(session, session.agent)
        if on_ready then
            on_ready(session.agent)
        end
        return
    end
    if session.agent_pending_callbacks then
        if on_ready then
            session.agent_pending_callbacks[#session.agent_pending_callbacks + 1] = on_ready
        end
        return
    end
    local pending = {}
    if on_ready then
        pending[1] = on_ready
    end
    session.agent_pending_callbacks = pending
    require("jpr.session").request(session, "prepareAgentLaunch", { agent = jpr().config.agent }, function(launch_plan)
        finish_pending_launch(session, pending, launch_plan)
    end, function()
        if session.agent_pending_callbacks == pending then
            session.agent_pending_callbacks = nil
        end
    end)
end

--- Toggles `session`'s right-hand agent terminal split without stopping a live
--- agent process when hiding its window.
function M.toggle(session)
    local agent_state = session.agent
    if agent_state and agent_state.win and vim.api.nvim_win_is_valid(agent_state.win) then
        local window_tab = vim.api.nvim_win_get_tabpage(agent_state.win)
        if #vim.api.nvim_tabpage_list_wins(window_tab) <= 1 then
            return jpr().error("cannot close the last window in the tab")
        end
        local is_closed = pcall(vim.api.nvim_win_close, agent_state.win, true)
        if is_closed then
            agent_state.win = nil
        else
            jpr().error("cannot close the agent window")
        end
        return
    end
    M.ensure_open(session)
end

local function send_terminal_bytes(agent_state, bytes, error_message)
    local ok, written = pcall(vim.fn.chansend, agent_state.job, bytes)
    if not ok or type(written) ~= "number" or written <= 0 then
        jpr().error(error_message)
        return false
    end
    return true
end

local function submit_and_confirm(session, agent_state, dispatch)
    if session.closing or session.agent ~= agent_state or not is_live_agent(agent_state) then
        return
    end
    local submit_bytes = M.profile_to_submit_bytes(dispatch.profile)
    if not send_terminal_bytes(agent_state, submit_bytes, "could not submit prompt in the agent terminal") then
        return
    end
    if type(dispatch.round) ~= "number" or type(dispatch.kind) ~= "string" or dispatch.kind == "" then
        return jpr().error("invalid dispatch metadata: missing round or kind")
    end
    require("jpr.session").request(session, "confirmSend", {
        round = dispatch.round,
        kind = dispatch.kind,
        threadIds = type(dispatch.threadIds) == "table" and dispatch.threadIds or {},
        prompt = dispatch.prompt,
    }, function() end)
end

--- Delivers a prepared `dispatch` payload to `session`'s agent terminal via
--- bracketed paste, submits after the profile delay, and confirms the round.
function M.deliver_dispatch(session, dispatch)
    if type(dispatch) ~= "table" or type(dispatch.prompt) ~= "string" or dispatch.prompt == "" then
        return jpr().error("nothing to send to the agent")
    end
    M.ensure_open(session, function(agent_state)
        if session.closing or session.agent ~= agent_state or not is_live_agent(agent_state) then
            return
        end
        if not send_terminal_bytes(agent_state, M.build_bracketed_paste_from_prompt(dispatch.prompt), "could not write prompt to the agent terminal") then
            return
        end
        local delay_ms = type(dispatch.profile) == "table" and type(dispatch.profile.submitDelayMs) == "number" and dispatch.profile.submitDelayMs or 200
        vim.defer_fn(function()
            submit_and_confirm(session, agent_state, dispatch)
        end, delay_ms)
    end)
end

--- Sends unsent local threads in `session` (or only `only_thread_id` when
--- given) to the interactive agent terminal.
function M.send(session, only_thread_id)
    require("jpr.session").request(session, "prepareSend", {
        threadId = only_thread_id,
        agent = jpr().config.agent,
    }, function(dispatch)
        M.deliver_dispatch(session, dispatch)
    end)
end

--- Requests a pre-pass review prompt for `session` and sends it to the agent
--- terminal.
function M.prepass(session)
    require("jpr.session").request(session, "preparePrepass", {
        agent = jpr().config.agent,
    }, function(dispatch)
        M.deliver_dispatch(session, dispatch)
    end)
end

--- Requests a conflict-resolution prompt for `paths` in `session` and delivers
--- it to the interactive agent terminal.
function M.resolve_conflicts(session, paths)
    local safe_paths = require("jpr.session.events").collect_safe_worktree_paths(session, paths)
    if #safe_paths == 0 then
        return jpr().error("no conflicted files to resolve")
    end
    require("jpr.session").request(session, "prepareConflictResolution", {
        paths = safe_paths,
        agent = jpr().config.agent,
    }, function(dispatch)
        M.deliver_dispatch(session, dispatch)
    end)
end

--- Stops `session`'s agent job, closes its window, deletes its terminal
--- buffer, and clears `session.agent`.
function M.close(session)
    session.agent_pending_callbacks = nil
    local agent_state = session.agent
    if not agent_state then
        return
    end
    session.agent = nil
    if not agent_state.exited and type(agent_state.job) == "number" and agent_state.job > 0 then
        pcall(vim.fn.jobstop, agent_state.job)
    end
    cleanup_agent_state(agent_state)
end

return M
