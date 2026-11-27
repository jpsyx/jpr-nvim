-- Automatic review-tab window width manager across the diff sidebar panel,
-- main editor area, and vertical coding-agent terminal split.
local agent_window = require("jpr.agent.window")

local M = {}

local MIN_MAIN_WIDTH = 20
local MIN_SIDE_WIDTH = 15

local function clamp_side_pair(panel_target, agent_target, total_columns)
    local available = math.max(0, total_columns - 2 - MIN_MAIN_WIDTH)
    if panel_target + agent_target <= available then
        return panel_target, agent_target
    end
    if available <= 0 then
        return MIN_SIDE_WIDTH, MIN_SIDE_WIDTH
    end
    local ratio = panel_target / math.max(1, panel_target + agent_target)
    local max_panel = math.max(MIN_SIDE_WIDTH, available - MIN_SIDE_WIDTH)
    local clamped_panel = math.max(MIN_SIDE_WIDTH, math.min(max_panel, math.floor(available * ratio + 0.5)))
    local clamped_agent = math.max(MIN_SIDE_WIDTH, available - clamped_panel)
    return clamped_panel, clamped_agent
end

local function clamp_single_side(target_width, total_columns)
    local max_side = math.max(MIN_SIDE_WIDTH, total_columns - 1 - MIN_MAIN_WIDTH)
    return math.max(MIN_SIDE_WIDTH, math.min(target_width, max_side))
end

--- Pure width calculator for a review tab's vertical layout.
--- `state`: `{ has_panel, has_editor, has_agent, total_columns, panel_width, agent_width }`.
--- Returns `{ panel_width, agent_width, panel_fixwidth, agent_fixwidth }` where a
--- `nil` width means that pane expands to fill the remaining main width.
function M.compute_layout_widths(state)
    local total_columns = math.max(40, math.floor(tonumber(state.total_columns) or vim.o.columns))
    local panel_target = math.max(MIN_SIDE_WIDTH, math.floor(tonumber(state.panel_width) or 44))
    local agent_target = math.max(MIN_SIDE_WIDTH, math.floor(tonumber(state.agent_width) or 60))

    if state.has_panel and state.has_editor and state.has_agent then
        local panel_width, agent_width = clamp_side_pair(panel_target, agent_target, total_columns)
        return {
            panel_width = panel_width,
            agent_width = agent_width,
            panel_fixwidth = true,
            agent_fixwidth = true,
        }
    end
    if state.has_panel and not state.has_editor and state.has_agent then
        return {
            panel_width = clamp_single_side(panel_target, total_columns),
            agent_width = nil,
            panel_fixwidth = true,
            agent_fixwidth = false,
        }
    end
    if not state.has_panel and state.has_editor and state.has_agent then
        return {
            panel_width = nil,
            agent_width = clamp_single_side(agent_target, total_columns),
            panel_fixwidth = false,
            agent_fixwidth = true,
        }
    end
    if state.has_panel and state.has_editor and not state.has_agent then
        return {
            panel_width = clamp_single_side(panel_target, total_columns),
            agent_width = nil,
            panel_fixwidth = true,
            agent_fixwidth = false,
        }
    end
    return {
        panel_width = nil,
        agent_width = nil,
        panel_fixwidth = false,
        agent_fixwidth = false,
    }
end

local function is_floating_window(win)
    local config = vim.api.nvim_win_get_config(win)
    return type(config.relative) == "string" and config.relative ~= ""
end

local function is_panel_window(session, win)
    local panel = session.panel
    return panel ~= nil
        and win == panel.win
        and panel.buf ~= nil
        and vim.api.nvim_buf_is_valid(panel.buf)
        and vim.api.nvim_win_get_buf(win) == panel.buf
end

local function is_vertical_agent_window(session, win)
    local agent = session.agent
    if not agent or not agent.buf or not vim.api.nvim_buf_is_valid(agent.buf) then
        return false
    end
    if vim.api.nvim_win_get_buf(win) ~= agent.buf then
        return false
    end
    return vim.w[win].jpr_agent_vertical == true
end

--- Inspects non-floating windows in `session.tab` and classifies the diff
--- sidebar, vertical agent split, and whether an editor window is open.
function M.classify_tab_windows(session)
    local panel_win, agent_win = nil, nil
    local has_editor = false
    if session and session.tab and vim.api.nvim_tabpage_is_valid(session.tab) then
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
            if not is_floating_window(win) then
                if not panel_win and is_panel_window(session, win) then
                    panel_win = win
                elseif not agent_win and is_vertical_agent_window(session, win) then
                    agent_win = win
                else
                    has_editor = true
                end
            end
        end
    end
    local topology_key = ("%s:%s:%s:%d"):format(
        tostring(panel_win or 0),
        tostring(agent_win or 0),
        tostring(has_editor),
        vim.o.columns
    )
    return {
        panel_win = panel_win,
        agent_win = agent_win,
        has_editor = has_editor,
        topology_key = topology_key,
    }
end

local function set_local_winfixwidth(win, enabled)
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_set_option_value, "winfixwidth", enabled, { win = win, scope = "local" })
    end
end

local function apply_layout_plan(info, plan)
    if info.panel_win and not plan.panel_fixwidth then
        set_local_winfixwidth(info.panel_win, false)
    end
    if info.agent_win and not plan.agent_fixwidth then
        set_local_winfixwidth(info.agent_win, false)
    end
    if info.panel_win and plan.panel_width then
        pcall(vim.api.nvim_win_set_width, info.panel_win, plan.panel_width)
    end
    if info.agent_win and plan.agent_width then
        pcall(vim.api.nvim_win_set_width, info.agent_win, plan.agent_width)
    end
    if info.panel_win and plan.panel_fixwidth then
        set_local_winfixwidth(info.panel_win, true)
    end
    if info.agent_win and plan.agent_fixwidth then
        set_local_winfixwidth(info.agent_win, true)
    end
end

--- Reconciles sidebar and vertical agent window widths in `session.tab` when
--- the tab's window topology or terminal width changed (or when `opts.force`
--- is true). Returns whether widths were applied.
function M.reconcile(session, opts)
    if not session or session.closing or session.layout_reconciling then
        return false
    end
    if not session.tab or not vim.api.nvim_tabpage_is_valid(session.tab) then
        return false
    end
    local info = M.classify_tab_windows(session)
    local is_forced = type(opts) == "table" and opts.force == true
    if not is_forced and session.layout_topology_key == info.topology_key then
        return false
    end
    session.layout_topology_key = info.topology_key
    local config = require("jpr").config
    local plan = M.compute_layout_widths({
        has_panel = info.panel_win ~= nil,
        has_editor = info.has_editor,
        has_agent = info.agent_win ~= nil,
        total_columns = vim.o.columns,
        panel_width = config.panel_width,
        agent_width = agent_window.get_vertical_width(config, vim.o.columns),
    })
    session.layout_reconciling = true
    apply_layout_plan(info, plan)
    session.layout_reconciling = false
    return true
end

--- Attaches tab-scoped autocmds to keep `session`'s sidebar and vertical agent
--- widths synchronized across window opens, closes, and terminal resizes.
function M.attach(session)
    if not session or not session.tab then
        return
    end
    local group = vim.api.nvim_create_augroup(("jpr-layout-%d"):format(session.tab), { clear = true })
    session.layout_group = group
    vim.api.nvim_create_autocmd({ "WinNew", "WinClosed", "BufWinEnter", "VimResized" }, {
        group = group,
        callback = function()
            vim.schedule(function()
                if not session.closing and session.layout_group == group then
                    if vim.api.nvim_tabpage_is_valid(session.tab) and vim.api.nvim_get_current_tabpage() == session.tab then
                        M.reconcile(session)
                    end
                end
            end)
        end,
    })
end

--- Removes `session`'s layout autocmd group.
function M.detach(session)
    if not session or not session.layout_group then
        return
    end
    pcall(vim.api.nvim_del_augroup_by_id, session.layout_group)
    session.layout_group = nil
    session.layout_topology_key = nil
end

return M
