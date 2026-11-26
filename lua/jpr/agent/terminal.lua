-- Built-in Neovim `:terminal` lifecycle for the coding agent, enhanced with
-- on-demand `toggleterm.nvim` loading (for `TermOpen` mappings and shading),
-- hide-without-quitting semantics, buffer-local toggle keys, and focus control.
local agent_window = require("jpr.agent.window")

local M = {}

M.resolve_vertical_width = agent_window.resolve_vertical_width

local function jpr()
    return require("jpr")
end

--- Lazily loads `toggleterm.nvim` when installed under `lazy.nvim` so user
--- `TermOpen` (`pattern = "*"`) mappings and shading attach before spawning.
function M.ensure_toggleterm_hooks(config)
    local active_config = type(config) == "table" and config or jpr().config
    if active_config.agent_load_toggleterm == false then
        return false
    end
    if package.loaded["toggleterm"] ~= nil then
        return true
    end
    local has_lazy_config, lazy_config = pcall(require, "lazy.core.config")
    if not has_lazy_config or type(lazy_config.plugins) ~= "table" or lazy_config.plugins["toggleterm.nvim"] == nil then
        return false
    end
    local has_lazy, lazy = pcall(require, "lazy")
    if not has_lazy or type(lazy.load) ~= "function" then
        return false
    end
    pcall(lazy.load, { plugins = { "toggleterm.nvim" } })
    return package.loaded["toggleterm"] ~= nil
end

local function bind_agent_buffer_keys(config, buf, on_toggle_hide)
    if type(on_toggle_hide) ~= "function" then
        return
    end
    local keys = type(config) == "table" and type(config.keys) == "table" and config.keys or {}
    local toggle_key = keys.toggle_agent
    if type(toggle_key) == "string" and toggle_key ~= "" then
        vim.keymap.set("n", toggle_key, on_toggle_hide, {
            buffer = buf,
            nowait = true,
            silent = true,
            desc = "Hide Jpr coding agent panel",
        })
    end
    local panel_key = keys.toggle_panel
    if type(panel_key) == "string" and panel_key ~= "" then
        vim.keymap.set("n", panel_key, "<Plug>(jpr-toggle-panel)", {
            buffer = buf,
            remap = true,
            nowait = true,
            silent = true,
            desc = "Toggle Jpr diff sidebar panel",
        })
    end
end

local function apply_toggleterm_window_hooks(config, buf, win, on_toggle_hide)
    if (type(config) == "table" and config.agent_load_toggleterm == false) or package.loaded["toggleterm"] == nil then
        return
    end
    local has_toggleterm_config, toggleterm_config = pcall(require, "toggleterm.config")
    if not has_toggleterm_config or type(toggleterm_config.get) ~= "function" then
        return
    end
    if toggleterm_config.get("shade_terminals") then
        local has_toggleterm_ui, toggleterm_ui = pcall(require, "toggleterm.ui")
        if has_toggleterm_ui and type(toggleterm_ui.hl_term) == "function" then
            pcall(toggleterm_ui.hl_term, { window = win, id = "JprAgent" })
        end
    end
    local open_mapping = toggleterm_config.get("open_mapping")
    if type(open_mapping) == "string" and open_mapping ~= "" and type(on_toggle_hide) == "function" then
        vim.keymap.set({ "t", "n" }, open_mapping, function()
            if vim.fn.mode(1):sub(1, 1) == "t" then
                pcall(vim.cmd, "stopinsert")
            end
            on_toggle_hide()
        end, { buffer = buf, nowait = true, silent = true, desc = "Hide Jpr coding agent panel" })
    end
end

local function find_remaining_window_for_buf(buf, excluding_win)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return nil
    end
    for _, candidate in ipairs(vim.fn.win_findbuf(buf)) do
        if candidate ~= excluding_win and vim.api.nvim_win_is_valid(candidate) then
            return candidate
        end
    end
    return nil
end

local function attach_win_closed_guard(agent_state, win)
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        once = true,
        callback = function()
            if agent_state.win ~= win then
                return
            end
            local remaining_win = find_remaining_window_for_buf(agent_state.buf, win)
            agent_state.win = remaining_win
            if remaining_win then
                attach_win_closed_guard(agent_state, remaining_win)
            end
        end,
    })
end

--- Finds the most relevant visible window for `agent_state`: current window if
--- it shows `agent_state.buf`, then another window in the current tab, then
--- `agent_state.win` showing the buffer, then any other window showing it,
--- falling back to a still-valid `agent_state.win` handle.
function M.find_agent_window(agent_state)
    if not agent_state then
        return nil
    end
    local buf = agent_state.buf
    if buf and vim.api.nvim_buf_is_valid(buf) then
        local current_win = vim.api.nvim_get_current_win()
        if vim.api.nvim_win_is_valid(current_win) and vim.api.nvim_win_get_buf(current_win) == buf then
            return current_win
        end
        for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
            if vim.api.nvim_win_is_valid(candidate) and vim.api.nvim_win_get_buf(candidate) == buf then
                return candidate
            end
        end
        if agent_state.win and vim.api.nvim_win_is_valid(agent_state.win) and vim.api.nvim_win_get_buf(agent_state.win) == buf then
            return agent_state.win
        end
        local remaining_win = find_remaining_window_for_buf(buf, nil)
        if remaining_win then
            agent_state.win = remaining_win
            return remaining_win
        end
    end
    if agent_state.win and vim.api.nvim_win_is_valid(agent_state.win) then
        return agent_state.win
    end
    return nil
end

--- Whether `session`'s interactive agent terminal window is currently visible.
function M.is_open(session)
    return session ~= nil and M.find_agent_window(session.agent) ~= nil
end

--- Whether `session` has a live interactive agent process (visible or hidden).
function M.has_live_agent(session)
    local agent_state = session and session.agent
    return agent_state ~= nil
        and not agent_state.exited
        and type(agent_state.job) == "number"
        and agent_state.job > 0
        and agent_state.buf ~= nil
        and vim.api.nvim_buf_is_valid(agent_state.buf)
end

--- Scrolls `agent_state`'s visible window to the bottom of its terminal buffer.
function M.scroll_to_bottom(agent_state)
    local win = M.find_agent_window(agent_state)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    local line_count = vim.api.nvim_buf_line_count(agent_state.buf)
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, line_count), 0 })
end

local function apply_focus_policy(agent_state, origin_win, should_focus)
    M.scroll_to_bottom(agent_state)
    if should_focus then
        local win = M.find_agent_window(agent_state)
        if win and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_set_current_win, win)
            vim.schedule(function()
                if vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() == win then
                    pcall(vim.cmd, "startinsert")
                end
            end)
        end
        return
    end
    if origin_win and vim.api.nvim_win_is_valid(origin_win) then
        pcall(vim.api.nvim_set_current_win, origin_win)
    end
    pcall(vim.cmd, "stopinsert")
end

local function cleanup_failed_spawn(win, buf)
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
end

local function start_terminal_job(win, buf, argv, cwd, env, is_background_float, options, agent_state)
    local job_opts = {
        term = true,
        cwd = cwd,
        env = (type(env) == "table" and next(env) ~= nil) and env or nil,
        on_stdout = function(_, data)
            if type(options.on_stdout) == "function" then
                options.on_stdout(agent_state, data)
            end
        end,
        on_exit = function(_, code)
            agent_state.exited = true
            if type(options.on_exit) == "function" then
                options.on_exit(agent_state, code)
            end
        end,
    }
    if is_background_float or not win or not vim.api.nvim_win_is_valid(win) then
        return pcall(vim.api.nvim_buf_call, buf, function()
            return vim.fn.jobstart(argv, job_opts)
        end)
    end
    return pcall(vim.api.nvim_win_call, win, function()
        return vim.fn.jobstart(argv, job_opts)
    end)
end

local function create_agent_state(buf, win, kind)
    return {
        buf = buf,
        win = win,
        job = 0,
        exited = false,
        kind = kind,
        is_ready = false,
        ready_scheduled = false,
        is_delivering = false,
        stdout_tail = "",
        pending_dispatches = {},
    }
end

local function attach_window_integrations(config, agent_state, win, on_toggle_hide)
    bind_agent_buffer_keys(config, agent_state.buf, on_toggle_hide)
    if win and vim.api.nvim_win_is_valid(win) then
        apply_toggleterm_window_hooks(config, agent_state.buf, win, on_toggle_hide)
        attach_win_closed_guard(agent_state, win)
    end
end

--- Spawns a new built-in `:terminal` running `argv` in `session.worktree`.
function M.spawn(session, argv, env, opts)
    local options = type(opts) == "table" and opts or {}
    local config = jpr().config
    local direction = config.agent_direction or "vertical"
    local should_focus = options.focus == true
    local origin_win = vim.api.nvim_get_current_win()

    M.ensure_toggleterm_hooks(config)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"

    local is_background_float = direction == "float" and not should_focus
    local win = nil
    if not is_background_float then
        win = agent_window.open_for_direction(session, buf, direction, options.kind, config)
        if not win then
            cleanup_failed_spawn(nil, buf)
            jpr().error("could not open agent terminal window")
            return nil
        end
    end

    local agent_state = create_agent_state(buf, win, options.kind or config.agent or "claude")
    local ok, job = start_terminal_job(win, buf, argv, session.worktree, env, is_background_float, options, agent_state)
    if not ok or type(job) ~= "number" or job <= 0 then
        cleanup_failed_spawn(win, buf)
        jpr().error("could not start agent terminal: " .. tostring(argv[1]))
        return nil
    end

    agent_state.job = job
    vim.bo[buf].bufhidden = "hide"
    attach_window_integrations(config, agent_state, win, options.on_toggle_hide)
    session.agent = agent_state
    require("jpr.views.layout").reconcile(session, { force = true })
    apply_focus_policy(agent_state, origin_win, should_focus)
    return agent_state
end

--- Shows or reattaches `agent_state`'s live terminal buffer according to
--- `config.agent_direction` and `opts.focus`.
function M.show(session, agent_state, opts)
    local options = type(opts) == "table" and opts or {}
    local config = jpr().config
    local direction = config.agent_direction or "vertical"
    local should_focus = options.focus == true
    local origin_win = vim.api.nvim_get_current_win()

    local existing_win = M.find_agent_window(agent_state)
    if existing_win then
        if vim.api.nvim_win_get_buf(existing_win) ~= agent_state.buf then
            pcall(vim.api.nvim_win_set_buf, existing_win, agent_state.buf)
        end
        apply_focus_policy(agent_state, origin_win, should_focus)
        return existing_win
    end

    if direction == "float" and not should_focus then
        return nil
    end

    vim.bo[agent_state.buf].bufhidden = "hide"
    local win = agent_window.open_for_direction(session, agent_state.buf, direction, agent_state.kind, config)
    if not win then
        return nil
    end
    agent_state.win = win
    attach_window_integrations(config, agent_state, win, options.on_toggle_hide)
    require("jpr.views.layout").reconcile(session, { force = true })
    apply_focus_policy(agent_state, origin_win, should_focus)
    return win
end

--- Hides `agent_state`'s window without stopping its live job. Handles both
--- splits in `session.tab` and dedicated breakout tabs (`agent_direction = "tab"`
--- or `<leader>o`).
function M.hide(session, agent_state)
    local win = M.find_agent_window(agent_state)
    if not win then
        return false
    end
    local win_tab = vim.api.nvim_win_get_tabpage(win)
    local tab_wins = vim.api.nvim_tabpage_list_wins(win_tab)
    if #tab_wins <= 1 then
        local total_tabs = #vim.api.nvim_list_tabpages()
        if total_tabs <= 1 or win_tab == session.tab then
            jpr().error("cannot close the last window in the tab")
            return false
        end
    end
    vim.bo[agent_state.buf].bufhidden = "hide"
    local is_closed = pcall(vim.api.nvim_win_close, win, true)
    if not is_closed then
        jpr().error("cannot close the agent window")
        return false
    end
    agent_state.win = find_remaining_window_for_buf(agent_state.buf, win)
    if agent_state.win then
        attach_win_closed_guard(agent_state, agent_state.win)
    end
    if win_tab ~= session.tab and session.tab and vim.api.nvim_tabpage_is_valid(session.tab) then
        pcall(vim.api.nvim_set_current_tabpage, session.tab)
    end
    require("jpr.views.layout").reconcile(session, { force = true })
    return true
end

--- Stops `agent_state`'s job, closes its window(s), wipes its buffer, and clears
--- `session.agent`.
function M.close(session, agent_state)
    local target = agent_state or (session and session.agent)
    if not target then
        return
    end
    if session and session.agent == target then
        session.agent = nil
    end
    if not target.exited and type(target.job) == "number" and target.job > 0 then
        pcall(vim.fn.jobstop, target.job)
    end
    if target.buf and vim.api.nvim_buf_is_valid(target.buf) then
        for _, win in ipairs(vim.fn.win_findbuf(target.buf)) do
            if vim.api.nvim_win_is_valid(win) then
                pcall(vim.api.nvim_win_close, win, true)
            end
        end
        pcall(vim.api.nvim_buf_delete, target.buf, { force = true })
    elseif target.win and vim.api.nvim_win_is_valid(target.win) then
        pcall(vim.api.nvim_win_close, target.win, true)
    end
    target.win = nil
end

return M
