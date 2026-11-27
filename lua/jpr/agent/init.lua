-- Interactive coding-agent terminal coordinator: cold-start CLI delivery,
-- readiness-gated warm PTY paste, focus preservation, and confirmed `:Jpr send`.
local command = require("jpr.agent.command")
local delivery = require("jpr.agent.delivery")
local terminal = require("jpr.agent.terminal")
local confirm = require("jpr.views.confirm")

local M = {}

M.MAX_CLI_PROMPT_BYTES = command.MAX_CLI_PROMPT_BYTES
M.parse_command_argv = command.parse_command_argv
M.build_claude_project_slug_from_worktree = command.build_claude_project_slug_from_worktree
M.has_claude_transcript = command.has_claude_transcript
M.can_use_cli_initial_prompt = command.can_use_cli_initial_prompt
M.create_launch_argv_from_plan = command.create_launch_argv_from_plan
M.is_claude_vim_mode_enabled = command.is_claude_vim_mode_enabled
M.extract_prompt_preview_items = command.extract_prompt_preview_items
M.build_bracketed_paste_from_prompt = delivery.build_bracketed_paste_from_prompt
M.profile_to_submit_bytes = delivery.profile_to_submit_bytes
M.is_open = terminal.is_open
M.has_live_agent = terminal.has_live_agent

local function jpr()
    return require("jpr")
end

local function agent_display_name(kind)
    return kind == "codex" and "Codex" or "Claude"
end

local function normalize_open_opts(opts_or_kind)
    if type(opts_or_kind) == "string" then
        return { agent_kind = opts_or_kind, focus = true }
    end
    if type(opts_or_kind) == "table" then
        return {
            agent_kind = opts_or_kind.agent_kind,
            focus = opts_or_kind.focus ~= false,
            initial_prompt = opts_or_kind.initial_prompt,
        }
    end
    return { focus = true }
end

local function close_send_confirm(session)
    if session and session.agent_confirm then
        local active = session.agent_confirm
        session.agent_confirm = nil
        confirm.close(active)
    end
end

local function spawn_agent_terminal(session, launch_plan, opts)
    local binary = require("jpr.binary")
    local config = jpr().config
    local argv = command.create_launch_argv_from_plan(
        config,
        session.worktree,
        launch_plan,
        nil,
        opts.initial_prompt
    )
    local socket = (type(launch_plan) == "table" and type(launch_plan.socket) == "string") and launch_plan.socket or ""
    local env = binary.create_agent_env_from_session(jpr().binary_path(), socket, session.number, vim.env.PATH)
    local kind = (type(launch_plan) == "table" and type(launch_plan.kind) == "string" and launch_plan.kind ~= "")
        and launch_plan.kind
        or opts.agent_kind
        or config.agent
        or "claude"
    local agent_state = terminal.spawn(session, argv, env, {
        kind = kind,
        focus = opts.focus,
        on_stdout = delivery.on_stdout,
        on_toggle_hide = function()
            M.toggle(session)
        end,
    })
    if agent_state then
        if command.can_use_cli_initial_prompt(kind, opts.initial_prompt) then
            agent_state.cli_initial_prompt = opts.initial_prompt
        end
        delivery.start_ready_fallback_timer(session, agent_state, config.agent_ready_timeout_ms)
    end
    return agent_state
end

local function drain_callbacks(callbacks, agent_state)
    for _, callback in ipairs(callbacks) do
        callback(agent_state)
    end
end

local function finish_pending_launch(session, pending, launch_plan, opts)
    if session.closing or session.agent_pending_callbacks ~= pending then
        return
    end
    session.agent_pending_callbacks = nil
    local agent_state
    if terminal.has_live_agent(session) then
        terminal.show(session, session.agent, {
            focus = opts.focus,
            on_toggle_hide = function()
                M.toggle(session)
            end,
        })
        agent_state = session.agent
    else
        terminal.close(session, session.agent)
        agent_state = spawn_agent_terminal(session, launch_plan, opts)
    end
    if agent_state then
        drain_callbacks(pending, agent_state)
    end
end

--- Ensures `session`'s interactive agent terminal is alive and shown according
--- to `opts_or_kind` (`string` kind or `{ agent_kind?, focus?, initial_prompt? }`),
--- then invokes `on_ready(agent_state)` when given.
function M.ensure_open(session, on_ready, opts_or_kind)
    local opts = normalize_open_opts(opts_or_kind)
    if terminal.has_live_agent(session) then
        terminal.show(session, session.agent, {
            focus = opts.focus,
            on_toggle_hide = function()
                M.toggle(session)
            end,
        })
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
    local pending = on_ready and { on_ready } or {}
    local selected_agent = (type(opts.agent_kind) == "string" and opts.agent_kind ~= "")
        and opts.agent_kind
        or jpr().config.agent
    opts.agent_kind = selected_agent
    session.agent_pending_callbacks = pending
    require("jpr.session").request(session, "prepareAgentLaunch", { agent = selected_agent }, function(launch_plan)
        finish_pending_launch(session, pending, launch_plan, opts)
    end, function()
        if session.agent_pending_callbacks == pending then
            session.agent_pending_callbacks = nil
        end
    end)
end

local function toggle_explicit_agent_kind(session, agent_kind)
    if not terminal.has_live_agent(session) then
        return M.ensure_open(session, nil, { agent_kind = agent_kind, focus = true })
    end
    local running_kind = session.agent.kind or jpr().config.agent or "claude"
    if running_kind ~= agent_kind then
        jpr().info(("agent panel is already running %s; close it before switching to %s"):format(running_kind, agent_kind))
    end
    M.ensure_open(session, nil, { focus = true })
end

--- Toggles `session`'s agent terminal window without stopping a live agent
--- process when hiding. When optional `agent_kind` (`"claude"` or `"codex"`) is
--- provided, launches or focuses the panel explicitly.
function M.toggle(session, agent_kind)
    if type(agent_kind) == "string" and agent_kind ~= "" then
        return toggle_explicit_agent_kind(session, agent_kind)
    end
    local open_win = terminal.find_agent_window(session and session.agent)
    if open_win then
        local win_tab = vim.api.nvim_win_get_tabpage(open_win)
        local current_tab = vim.api.nvim_get_current_tabpage()
        if win_tab ~= session.tab and current_tab == session.tab then
            return terminal.show(session, session.agent, { focus = true })
        end
        return terminal.hide(session, session.agent)
    end
    M.ensure_open(session, nil, { focus = true })
end

local function confirm_dispatch_round(session, dispatch)
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

local function maybe_notify_background_float(dispatch)
    if (jpr().config.agent_direction or "vertical") ~= "float" then
        return
    end
    local thread_count = type(dispatch.threadIds) == "table" and #dispatch.threadIds or 0
    local label = thread_count > 0 and ("sent %d thread(s) to agent (press ga to open)"):format(thread_count)
        or "sent prompt to agent (press ga to open)"
    jpr().info(label)
end

--- Delivers a prepared `dispatch` payload to `session`'s agent terminal, using
--- cold-start CLI `-- <prompt>` for fresh Claude launches or readiness-gated
--- PTY bracketed paste + submit for warm/Codex/oversized dispatches.
function M.deliver_dispatch(session, dispatch)
    if type(dispatch) ~= "table" or type(dispatch.prompt) ~= "string" or dispatch.prompt == "" then
        return jpr().error("nothing to send to the agent")
    end
    local target_kind = (type(dispatch.profile) == "table" and type(dispatch.profile.kind) == "string" and dispatch.profile.kind ~= "")
        and dispatch.profile.kind
        or jpr().config.agent
        or "claude"
    local use_cli_cold_start = not terminal.has_live_agent(session)
        and session.agent_pending_callbacks == nil
        and command.can_use_cli_initial_prompt(target_kind, dispatch.prompt)
    local enqueue_warm = function(agent_state)
        delivery.enqueue_pty_dispatch(session, agent_state, dispatch, function(done_dispatch)
            confirm_dispatch_round(session, done_dispatch)
            maybe_notify_background_float(done_dispatch)
        end)
    end
    if use_cli_cold_start then
        return M.ensure_open(session, function(agent_state)
            if session.closing or session.agent ~= agent_state or not terminal.has_live_agent(session) then
                return
            end
            if agent_state.cli_initial_prompt ~= dispatch.prompt then
                return enqueue_warm(agent_state)
            end
            agent_state.cli_initial_prompt = nil
            confirm_dispatch_round(session, dispatch)
            maybe_notify_background_float(dispatch)
        end, { agent_kind = target_kind, focus = false, initial_prompt = dispatch.prompt })
    end
    M.ensure_open(session, enqueue_warm, { agent_kind = target_kind, focus = false })
end

local function open_send_confirmation(session, dispatch)
    close_send_confirm(session)
    local thread_count = type(dispatch.threadIds) == "table" and #dispatch.threadIds or 0
    local target_kind = (type(dispatch.profile) == "table" and dispatch.profile.kind) or jpr().config.agent or "claude"
    local name = agent_display_name(target_kind)
    local noun = thread_count == 1 and "thread" or "threads"
    local title_noun = thread_count == 1 and "Thread" or "Threads"
    local state
    state = confirm.open({
        title = " Send to Coding Agent ",
        headline = ("Send %d local review %s to %s?"):format(thread_count, noun, name),
        items = command.extract_prompt_preview_items(dispatch.prompt, 5),
        confirm_label = ("Send %d %s to %s"):format(thread_count, title_noun, name),
        confirm_badge = "[send]",
        confirm_help = ("Auto-submit %s to the %s terminal while keeping focus here."):format(noun, name),
        cancel_label = "Cancel",
        cancel_help = "Dismiss without sending or opening the agent.",
        on_confirm = function()
            if session.agent_confirm == state then
                session.agent_confirm = nil
            end
            if not session.closing then
                M.deliver_dispatch(session, dispatch)
            end
        end,
        on_cancel = function()
            if session.agent_confirm == state then
                session.agent_confirm = nil
            end
        end,
    })
    session.agent_confirm = state
end

--- Prepares unsent local threads in `session` (or only `only_thread_id`) and
--- opens a confirmation modal showing the exact count before dispatching
--- (unless `opts.skip_confirm == true`).
function M.send(session, only_thread_id, opts)
    require("jpr.session").request(session, "prepareSend", {
        threadId = only_thread_id,
        agent = jpr().config.agent,
    }, function(dispatch)
        if session.closing then
            return
        end
        if type(dispatch) ~= "table" or type(dispatch.prompt) ~= "string" or dispatch.prompt == "" then
            return jpr().error("nothing to send to the agent")
        end
        if type(opts) == "table" and opts.skip_confirm == true then
            return M.deliver_dispatch(session, dispatch)
        end
        open_send_confirmation(session, dispatch)
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

--- Stops `session`'s agent job, closes its window and any pending send
--- confirmation modal, deletes its terminal buffer, and clears `session.agent`.
function M.close(session)
    session.agent_pending_callbacks = nil
    close_send_confirm(session)
    terminal.close(session, session.agent)
end

return M
