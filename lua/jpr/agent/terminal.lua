-- Built-in Neovim `:terminal` lifecycle for the coding agent, enhanced with
-- on-demand `toggleterm.nvim` loading (for `TermOpen` mappings and shading),
-- hide-without-quitting semantics, multi-layout geometry, and focus control.
local window_util = require("jpr.tui.wizard.window")

local M = {}

local function jpr()
    return require("jpr")
end

--- Computes the vertical split width in columns from `config` and optional
--- `total_columns` (defaulting to `vim.o.columns`).
function M.resolve_vertical_width(config, total_columns)
    local columns = (type(total_columns) == "number" and total_columns > 0) and total_columns or vim.o.columns
    local configured = type(config) == "table" and config.agent_width or nil
    if type(configured) == "number" and configured > 0 then
        return math.min(math.floor(configured), math.max(20, columns - 10))
    end
    local max_width = math.max(20, columns - 20)
    local target = math.max(60, math.floor(columns * 0.4))
    return math.min(target, max_width)
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
    local has_lazy_cfg, lazy_cfg = pcall(require, "lazy.core.config")
    if not has_lazy_cfg or type(lazy_cfg.plugins) ~= "table" or lazy_cfg.plugins["toggleterm.nvim"] == nil then
        return false
    end
    local has_lazy, lazy = pcall(require, "lazy")
    if not has_lazy or type(lazy.load) ~= "function" then
        return false
    end
    pcall(lazy.load, { plugins = { "toggleterm.nvim" } })
    return package.loaded["toggleterm"] ~= nil
end

local function apply_toggleterm_window_hooks(buf, win, on_toggle_hide)
    local ok_cfg, tt_cfg = pcall(require, "toggleterm.config")
    if not ok_cfg or type(tt_cfg.get) ~= "function" then
        return
    end
    if tt_cfg.get("shade_terminals") then
        local ok_ui, tt_ui = pcall(require, "toggleterm.ui")
        if ok_ui and type(tt_ui.hl_term) == "function" then
            pcall(tt_ui.hl_term, { window = win, id = "JprAgent" })
        end
    end
    local open_mapping = tt_cfg.get("open_mapping")
    if type(open_mapping) == "string" and open_mapping ~= "" and type(on_toggle_hide) == "function" then
        vim.keymap.set({ "t", "n" }, open_mapping, function()
            if vim.fn.mode(1):sub(1, 1) == "t" then
                pcall(vim.cmd, "stopinsert")
            end
            on_toggle_hide()
        end, { buffer = buf, nowait = true, silent = true, desc = "Hide Jpr coding agent panel" })
    end
end

local function find_rightmost_window(session)
    local main_window = require("jpr.views.main_window")
    local best_normal, best_normal_column = nil, -1
    local best_any, best_any_column = nil, -1
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
        local win_cfg = vim.api.nvim_win_get_config(win)
        if not win_cfg.relative or win_cfg.relative == "" then
            local column = vim.api.nvim_win_get_position(win)[2]
            if column > best_any_column then
                best_any, best_any_column = win, column
            end
            if not main_window.is_side(session, win) and column > best_normal_column then
                best_normal, best_normal_column = win, column
            end
        end
    end
    return best_normal or best_any
end

local function style_agent_window(win, direction)
    local function set_local(name, value)
        vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
    end
    set_local("number", false)
    set_local("relativenumber", false)
    set_local("signcolumn", "no")
    if direction == "vertical" then
        vim.w[win].jpr_side = true
        set_local("winfixwidth", true)
    elseif direction == "horizontal" then
        vim.w[win].jpr_side = true
        set_local("winfixheight", true)
    end
end

local function open_float_window(buf, kind)
    local max_w = math.max(24, vim.o.columns - 4)
    local max_h = math.max(10, vim.o.lines - 4)
    local width = math.min(max_w, math.max(math.min(72, max_w), math.floor(vim.o.columns * 0.8)))
    local height = math.min(max_h, math.max(math.min(18, max_h), math.floor(vim.o.lines * 0.75)))
    local label = kind == "codex" and "Codex" or "Claude"
    local title = (" Jpr · %s "):format(label)
    local footer = " :q / ga hide without quitting "
    local cfg = window_util.create_window_config(width, height, title, footer)
    local ok, win = pcall(vim.api.nvim_open_win, buf, true, cfg)
    return (ok and win and vim.api.nvim_win_is_valid(win)) and win or nil
end

local function open_tab_window(buf)
    local ok = pcall(vim.cmd, "tabnew")
    if not ok then
        return nil
    end
    local win = vim.api.nvim_get_current_win()
    local placeholder = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf)
    if placeholder ~= buf and vim.api.nvim_buf_is_valid(placeholder) then
        pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
    end
    return win
end

local function open_split_window(session, buf, direction, config)
    if not session.tab or not vim.api.nvim_tabpage_is_valid(session.tab) then
        return nil
    end
    if direction == "horizontal" then
        local current_tab = vim.api.nvim_get_current_tabpage()
        if current_tab ~= session.tab then
            pcall(vim.api.nvim_set_current_tabpage, session.tab)
        end
        local height = math.max(15, math.floor(vim.o.lines * 0.3))
        local ok = pcall(vim.cmd, ("botright %dsplit"):format(height))
        if not ok then
            return nil
        end
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
        return win
    end
    local target_win = find_rightmost_window(session) or vim.api.nvim_tabpage_list_wins(session.tab)[1]
    if not target_win or not vim.api.nvim_win_is_valid(target_win) then
        return nil
    end
    local width = M.resolve_vertical_width(config)
    local ok, win = pcall(vim.api.nvim_open_win, buf, true, { split = "right", win = target_win, width = width })
    return (ok and win and vim.api.nvim_win_is_valid(win)) and win or nil
end

local function open_window_for_direction(session, buf, direction, kind, config)
    local win
    if direction == "float" then
        win = open_float_window(buf, kind)
    elseif direction == "tab" then
        win = open_tab_window(buf)
    else
        win = open_split_window(session, buf, direction, config)
    end
    if win then
        style_agent_window(win, direction)
    end
    return win
end

local function attach_win_closed_guard(agent_state, win)
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        once = true,
        callback = function()
            if agent_state.win ~= win then
                return
            end
            local remaining = (agent_state.buf and vim.api.nvim_buf_is_valid(agent_state.buf))
                and vim.fn.win_findbuf(agent_state.buf)
                or {}
            local next_win = nil
            for _, candidate in ipairs(remaining) do
                if candidate ~= win and vim.api.nvim_win_is_valid(candidate) then
                    next_win = candidate
                    break
                end
            end
            agent_state.win = next_win
        end,
    })
end

--- Finds any valid window currently displaying `agent_state.buf`, preferring
--- `agent_state.win` when valid.
function M.find_agent_window(agent_state)
    if not agent_state then
        return nil
    end
    if agent_state.win and vim.api.nvim_win_is_valid(agent_state.win) then
        return agent_state.win
    end
    if not agent_state.buf or not vim.api.nvim_buf_is_valid(agent_state.buf) then
        return nil
    end
    local windows = vim.fn.win_findbuf(agent_state.buf)
    for _, candidate in ipairs(windows) do
        if vim.api.nvim_win_is_valid(candidate) then
            agent_state.win = candidate
            return candidate
        end
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

local function start_terminal_job(buf, argv, cwd, env, is_background_float, options, agent_state)
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
    if is_background_float then
        return pcall(vim.api.nvim_buf_call, buf, function()
            return vim.fn.jobstart(argv, job_opts)
        end)
    end
    return pcall(vim.fn.jobstart, argv, job_opts)
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
        win = open_window_for_direction(session, buf, direction, options.kind, config)
        if not win then
            cleanup_failed_spawn(nil, buf)
            jpr().error("could not open agent terminal window")
            return nil
        end
    end

    local agent_state = {
        buf = buf,
        win = win,
        job = 0,
        exited = false,
        kind = options.kind or config.agent or "claude",
        is_ready = false,
        pending_dispatches = {},
    }
    local ok, job = start_terminal_job(buf, argv, session.worktree, env, is_background_float, options, agent_state)
    if not ok or type(job) ~= "number" or job <= 0 then
        cleanup_failed_spawn(win, buf)
        jpr().error("could not start agent terminal: " .. tostring(argv[1]))
        return nil
    end

    agent_state.job = job
    vim.bo[buf].bufhidden = "hide"
    if win and vim.api.nvim_win_is_valid(win) then
        apply_toggleterm_window_hooks(buf, win, options.on_toggle_hide)
        attach_win_closed_guard(agent_state, win)
    end
    session.agent = agent_state
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
    if not existing_win and agent_state.win and vim.api.nvim_win_is_valid(agent_state.win) then
        existing_win = agent_state.win
    end
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
    local win = open_window_for_direction(session, agent_state.buf, direction, agent_state.kind, config)
    if not win then
        return nil
    end
    agent_state.win = win
    apply_toggleterm_window_hooks(agent_state.buf, win, options.on_toggle_hide)
    attach_win_closed_guard(agent_state, win)
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
    agent_state.win = nil
    if win_tab ~= session.tab and session.tab and vim.api.nvim_tabpage_is_valid(session.tab) then
        pcall(vim.api.nvim_set_current_tabpage, session.tab)
    end
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
