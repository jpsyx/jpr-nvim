-- Window layout, sizing, and styling helpers for the coding-agent terminal
-- across vertical splits, horizontal splits, centered floats, and breakout tabs.
local window_util = require("jpr.tui.wizard.window")

local M = {}

--- Computes the vertical split width in columns from `config` and optional
--- `total_columns` (defaulting to `vim.o.columns`).
function M.get_vertical_width(config, total_columns)
    local columns = (type(total_columns) == "number" and total_columns > 0) and total_columns or vim.o.columns
    local configured = type(config) == "table" and config.agent_width or nil
    if type(configured) == "number" and configured > 0 then
        return math.min(math.floor(configured), math.max(20, columns - 10))
    end
    local max_width = math.max(20, columns - 20)
    local target_width = math.max(60, math.floor(columns * 0.4))
    return math.min(target_width, max_width)
end

local function find_rightmost_window(session)
    local main_window = require("jpr.views.main_window")
    local best_normal, best_normal_column = nil, -1
    local best_any, best_any_column = nil, -1
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
        local window_config = vim.api.nvim_win_get_config(win)
        if not window_config.relative or window_config.relative == "" then
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
        vim.w[win].jpr_agent_vertical = true
        set_local("winfixwidth", true)
    elseif direction == "horizontal" then
        vim.w[win].jpr_side = true
        set_local("winfixheight", true)
    end
end

local function build_float_footer_from_config(config)
    local keys = type(config) == "table" and type(config.keys) == "table" and config.keys or {}
    local toggle_key = keys.toggle_agent
    if type(toggle_key) == "string" and toggle_key ~= "" then
        return (" :q / %s hide without quitting "):format(toggle_key)
    end
    return " :q hides without quitting "
end

local function open_float_window(buf, kind, config)
    local max_width = math.max(24, vim.o.columns - 4)
    local max_height = math.max(10, vim.o.lines - 4)
    local width = math.min(max_width, math.max(math.min(72, max_width), math.floor(vim.o.columns * 0.8)))
    local height = math.min(max_height, math.max(math.min(18, max_height), math.floor(vim.o.lines * 0.75)))
    local label = kind == "codex" and "Codex" or "Claude"
    local title = (" Jpr · %s "):format(label)
    local footer = build_float_footer_from_config(config)
    local float_config = window_util.create_window_config(width, height, title, footer)
    local ok, win = pcall(vim.api.nvim_open_win, buf, true, float_config)
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
    if vim.api.nvim_get_current_tabpage() ~= session.tab then
        pcall(vim.api.nvim_set_current_tabpage, session.tab)
    end
    if direction == "horizontal" then
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
    local width = M.get_vertical_width(config)
    local ok, win = pcall(vim.api.nvim_open_win, buf, true, { split = "right", win = target_win, width = width })
    return (ok and win and vim.api.nvim_win_is_valid(win)) and win or nil
end

--- Opens and styles a window displaying `buf` for `direction` (`"vertical"`,
--- `"horizontal"`, `"float"`, or `"tab"`).
function M.open_for_direction(session, buf, direction, kind, config)
    local win
    if direction == "float" then
        win = open_float_window(buf, kind, config)
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

return M
