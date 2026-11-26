-- Specs for built-in :terminal lifecycle, on-demand toggleterm hooks, hide-without-quitting,
-- proportional sizing, focus preservation, float background launch, and tab breakout toggling.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local terminal = require("jpr.agent.terminal")

local function create_mock_session()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    local origin_win = vim.api.nvim_get_current_win()
    local worktree = vim.fn.tempname()
    vim.fn.mkdir(worktree, "p")
    return {
        tab = tab,
        worktree = worktree,
        panel = nil,
        agent = nil,
    }, origin_win
end

local function test_resolve_vertical_width()
    assert(terminal.resolve_vertical_width({ agent_width = nil }, 160) == 64, "40% of 160 cols is 64")
    assert(terminal.resolve_vertical_width({ agent_width = nil }, 120) == 60, "clamps up to 60 on 120 cols")
    assert(terminal.resolve_vertical_width({ agent_width = nil }, 70) == 50, "respects columns - 20 on narrow screen")
    assert(terminal.resolve_vertical_width({ agent_width = 72 }, 160) == 72, "honors explicit agent_width")
    assert(terminal.resolve_vertical_width({ agent_width = 120 }, 100) == 90, "clamps explicit width to columns - 10")
end

local function test_on_demand_toggleterm_hooks_shading_and_open_mapping()
    local lazy_loads = {}
    local hl_calls = {}
    local saved = {
        ["lazy.core.config"] = package.loaded["lazy.core.config"],
        ["lazy"] = package.loaded["lazy"],
        ["toggleterm"] = package.loaded["toggleterm"],
        ["toggleterm.ui"] = package.loaded["toggleterm.ui"],
        ["toggleterm.config"] = package.loaded["toggleterm.config"],
    }

    package.loaded["lazy.core.config"] = { plugins = { ["toggleterm.nvim"] = {} } }
    package.loaded["lazy"] = {
        load = function(opts)
            lazy_loads[#lazy_loads + 1] = opts
            package.loaded["toggleterm"] = {}
            package.loaded["toggleterm.config"] = {
                get = function(key)
                    if key == "shade_terminals" then return true end
                    if key == "open_mapping" then return "<C-\\>" end
                    return nil
                end,
            }
            package.loaded["toggleterm.ui"] = {
                hl_term = function(term_like)
                    hl_calls[#hl_calls + 1] = term_like
                end,
            }
        end,
    }
    package.loaded["toggleterm"] = nil
    package.loaded["toggleterm.ui"] = nil
    package.loaded["toggleterm.config"] = nil

    assert(terminal.ensure_toggleterm_hooks({ agent_load_toggleterm = false }) == false, "disabled skips lazy load")
    assert(#lazy_loads == 0, "no lazy load when disabled")

    jpr.setup({ agent_load_toggleterm = true, agent_direction = "vertical", agent_width = nil })
    local session = create_mock_session()
    local toggled = 0
    local state = terminal.spawn(session, { "/bin/sh", "-c", "sleep 30" }, {}, {
        kind = "claude",
        focus = true,
        on_toggle_hide = function()
            toggled = toggled + 1
        end,
    })
    assert(state ~= nil, "spawned terminal")
    assert(#lazy_loads == 1, "lazy-loaded toggleterm.nvim once on demand")
    assert(#hl_calls == 1 and hl_calls[1].window == state.win, "applied toggleterm hl_term shading")
    assert(vim.bo[state.buf].filetype ~= "toggleterm", "does not set toggleterm filetype")
    assert(vim.b[state.buf].toggle_number == nil, "does not set toggle_number")
    assert(helpers.has_buf_map(state.buf, "t", "<C-Bslash>"), "maps open_mapping in terminal mode")
    assert(helpers.has_buf_map(state.buf, "n", "<C-Bslash>"), "maps open_mapping in normal mode")
    vim.cmd("stopinsert")
    helpers.press_key("<C-\\>")
    assert(toggled == 1, "buffer-local open_mapping calls on_toggle_hide")

    terminal.close(session, state)
    pcall(vim.cmd, "tabclose!")
    for name, value in pairs(saved) do
        package.loaded[name] = value
    end
end

local function test_hide_without_quitting_and_focus_preservation()
    jpr.setup({ agent_load_toggleterm = false, agent_direction = "vertical", agent_width = nil })
    local session, origin_win = create_mock_session()

    -- Spawn with focus = false: keeps origin_win focused in Normal mode.
    local state = terminal.spawn(session, { "/bin/sh", "-c", "sleep 30" }, {}, {
        kind = "claude",
        focus = false,
    })
    assert(state ~= nil and terminal.has_live_agent(session), "agent job is live")
    assert(vim.api.nvim_get_current_win() == origin_win, "focus = false keeps cursor in origin window")
    assert(vim.fn.mode(1):sub(1, 1) == "n", "focus = false stays in Normal mode")
    assert(vim.bo[state.buf].bufhidden == "hide", "bufhidden is hide")
    assert(vim.w[state.win].jpr_side == true, "vertical split marked jpr_side")

    -- Simulate user closing split with :q / nvim_win_close: job stays alive.
    local first_buf, first_job, first_win = state.buf, state.job, state.win
    vim.api.nvim_win_close(first_win, true)
    assert(vim.wait(1000, function() return state.win == nil end), "WinClosed clears state.win")
    assert(terminal.is_open(session) == false, "is_open is false after close")
    assert(terminal.has_live_agent(session) == true, "job stays live after window close")
    assert(vim.api.nvim_buf_is_valid(first_buf), "buffer survives window close")

    -- Re-showing reattaches the exact same buffer and job, and focus = true focuses it.
    local reopened_win = terminal.show(session, state, { focus = true })
    assert(reopened_win ~= nil and vim.api.nvim_win_is_valid(reopened_win), "show reopens window")
    assert(state.buf == first_buf and state.job == first_job, "reuses existing buffer and job")
    assert(vim.api.nvim_get_current_win() == reopened_win, "focus = true focuses agent window")
    vim.cmd("stopinsert")

    terminal.close(session, state)
    assert(not vim.api.nvim_buf_is_valid(first_buf), "close deletes buffer")
    assert(vim.fn.jobwait({ first_job }, 2000)[1] ~= -1, "close stops job")
    pcall(vim.cmd, "tabclose!")
end

local function test_float_background_launch_and_tab_breakout_toggling()
    -- 1. Float + focus = false launches in background without opening a float.
    jpr.setup({ agent_load_toggleterm = false, agent_direction = "float" })
    local float_session, float_origin = create_mock_session()
    local float_state = terminal.spawn(float_session, { "/bin/sh", "-c", "sleep 30" }, {}, {
        kind = "claude",
        focus = false,
    })
    assert(float_state ~= nil and terminal.has_live_agent(float_session), "float background spawn is live")
    assert(float_state.win == nil and terminal.is_open(float_session) == false, "float stays hidden on focus = false")
    assert(vim.api.nvim_get_current_win() == float_origin, "focus remains in origin window")

    local float_win = terminal.show(float_session, float_state, { focus = true })
    assert(float_win ~= nil and vim.api.nvim_win_get_config(float_win).relative == "editor", "interactive show opens float")
    vim.cmd("stopinsert")
    assert(terminal.hide(float_session, float_state) == true, "hide closes float")
    assert(terminal.has_live_agent(float_session) == true, "float job stays alive after hide")
    terminal.close(float_session, float_state)
    pcall(vim.cmd, "tabclose!")

    -- 2. Breakout tab toggling: agent as sole window in a second tab closes cleanly and returns to session.tab.
    jpr.setup({ agent_load_toggleterm = false, agent_direction = "tab" })
    local tab_session = create_mock_session()
    local tab_state = terminal.spawn(tab_session, { "/bin/sh", "-c", "sleep 30" }, {}, {
        kind = "claude",
        focus = true,
    })
    assert(tab_state ~= nil and tab_state.win ~= nil, "tab agent opened")
    vim.cmd("stopinsert")
    local agent_tab = vim.api.nvim_win_get_tabpage(tab_state.win)
    assert(agent_tab ~= tab_session.tab, "agent opened in dedicated tabpage")

    -- Switching back to session.tab and calling show() focuses the existing agent tab.
    vim.api.nvim_set_current_tabpage(tab_session.tab)
    terminal.show(tab_session, tab_state, { focus = true })
    vim.cmd("stopinsert")
    assert(vim.api.nvim_get_current_tabpage() == agent_tab, "show from review tab switches to existing agent tab")

    -- Calling hide() from the agent's own tab closes that tab without quitting Claude and returns to session.tab.
    assert(terminal.hide(tab_session, tab_state) == true, "hide closes dedicated agent tab")
    assert(vim.api.nvim_get_current_tabpage() == tab_session.tab, "returns focus to session.tab")
    assert(terminal.has_live_agent(tab_session) == true, "agent job stays alive after closing its tab")

    terminal.close(tab_session, tab_state)
    pcall(vim.cmd, "tabclose!")
end

test_resolve_vertical_width()
test_on_demand_toggleterm_hooks_shading_and_open_mapping()
test_hide_without_quitting_and_focus_preservation()
test_float_background_launch_and_tab_breakout_toggling()

print("agent_terminal_spec: ok")
