-- Specs for automatic review-tab layout width reconciliation across panel,
-- editor, and vertical AI agent windows, plus `:Jpr panel` / `gP` toggle.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local layout = require("jpr.views.layout")
local panel_view = require("jpr.views.panel")
local session = require("jpr.session")
local view_mode = require("jpr.view_mode")

local function test_compute_layout_widths()
    -- 1. Sidebar + Editor + AI -> both side widths locked, editor fills middle.
    local all_three = layout.compute_layout_widths({
        has_panel = true,
        has_editor = true,
        has_agent = true,
        total_columns = 180,
        panel_width = 44,
        agent_width = 60,
    })
    assert(all_three.panel_width == 44 and all_three.panel_fixwidth == true, "all three: panel fixed at 44")
    assert(all_three.agent_width == 60 and all_three.agent_fixwidth == true, "all three: agent fixed at 60")

    -- 2. Sidebar + AI (no Editor) -> sidebar fixed, AI takes remaining main width.
    local panel_and_agent = layout.compute_layout_widths({
        has_panel = true,
        has_editor = false,
        has_agent = true,
        total_columns = 180,
        panel_width = 44,
        agent_width = 60,
    })
    assert(panel_and_agent.panel_width == 44 and panel_and_agent.panel_fixwidth == true, "panel+agent: panel fixed at 44")
    assert(panel_and_agent.agent_width == nil and panel_and_agent.agent_fixwidth == false, "panel+agent: agent expands to main width")

    -- 3. Editor + AI (no Sidebar) -> editor takes main width, AI at side width.
    local editor_and_agent = layout.compute_layout_widths({
        has_panel = false,
        has_editor = true,
        has_agent = true,
        total_columns = 180,
        panel_width = 44,
        agent_width = 60,
    })
    assert(editor_and_agent.panel_width == nil and editor_and_agent.panel_fixwidth == false, "editor+agent: no panel")
    assert(editor_and_agent.agent_width == 60 and editor_and_agent.agent_fixwidth == true, "editor+agent: agent fixed at 60")

    -- 4. Sidebar + Editor (no AI) -> sidebar at side width, editor takes main width.
    local panel_and_editor = layout.compute_layout_widths({
        has_panel = true,
        has_editor = true,
        has_agent = false,
        total_columns = 180,
        panel_width = 44,
        agent_width = 60,
    })
    assert(panel_and_editor.panel_width == 44 and panel_and_editor.panel_fixwidth == true, "panel+editor: panel fixed at 44")
    assert(panel_and_editor.agent_width == nil and panel_and_editor.agent_fixwidth == false, "panel+editor: no agent")

    -- 5. Single window -> no fixed width constraints.
    local panel_only = layout.compute_layout_widths({
        has_panel = true,
        has_editor = false,
        has_agent = false,
        total_columns = 180,
        panel_width = 44,
        agent_width = 60,
    })
    assert(panel_only.panel_width == nil and panel_only.panel_fixwidth == false, "panel only: unfixed")

    -- 6. Narrow terminal (75 cols) clamps side widths so editor keeps >= 20 cols.
    local narrow = layout.compute_layout_widths({
        has_panel = true,
        has_editor = true,
        has_agent = true,
        total_columns = 75,
        panel_width = 44,
        agent_width = 40,
    })
    assert(narrow.panel_width >= 15 and narrow.agent_width >= 15, "narrow: side widths stay usable")
    assert(75 - narrow.panel_width - narrow.agent_width - 2 >= 20, "narrow: editor keeps >= 20 cols")
end

local function setup_session()
    vim.o.columns = 180
    view_mode.path = vim.fn.tempname()
    vim.env.FAKE_ENGINE_LOG = vim.fn.tempname()
    local worktree = vim.fn.tempname()
    vim.fn.mkdir(worktree .. "/src", "p")
    vim.fn.writefile({ "hello", "world" }, worktree .. "/README.md")
    vim.fn.writefile({ "local x = 1" }, worktree .. "/src/main.lua")

    jpr.setup({
        binary = root .. "/tests/lua/fixtures/fake_engine.sh",
        panel_width = 40,
        agent_width = 50,
        agent_load_toggleterm = false,
        view = "unified",
    })

    session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
    local review = session.current()
    assert(vim.wait(3000, function()
        return review.view.pr ~= nil and review.panel ~= nil and review.stream ~= nil and review.stream.layout ~= nil
    end), "review session initialized")
    return review
end

local function attach_fake_vertical_agent(review)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    local agent_window = require("jpr.agent.window")
    local win = agent_window.open_for_direction(review, buf, "vertical", "claude", jpr.config)
    review.agent = { buf = buf, win = win, job = 999, exited = false, kind = "claude" }
    layout.reconcile(review, { force = true })
    return win, buf
end

local function test_live_layout_transitions_and_panel_toggle()
    local review = setup_session()
    local main_window = require("jpr.views.main_window")

    -- 1. Close main window -> panel expands; reopen file from panel -> panel snaps back to 40.
    local main_win = main_window.find(review)
    vim.api.nvim_win_close(main_win, true)
    assert(vim.wait(1000, function()
        return vim.api.nvim_win_get_width(review.panel.win) > 100
    end), "panel expands when main window closes")

    local file_line = nil
    for line, path in pairs(review.panel.paths) do
        if path == "README.md" then
            file_line = line
            break
        end
    end
    assert(file_line ~= nil, "README.md found in panel")
    vim.api.nvim_set_current_win(review.panel.win)
    vim.api.nvim_win_set_cursor(review.panel.win, { file_line, 0 })
    panel_view.open_file_under_cursor(review)
    assert(vim.wait(1000, function()
        return vim.api.nvim_win_get_width(review.panel.win) == 40
    end), "panel snaps back to 40 when file opens, got " .. tostring(vim.api.nvim_win_get_width(review.panel.win)))

    -- 2. Open vertical AI agent alongside sidebar + editor -> both at side widths.
    local agent_win, agent_buf = attach_fake_vertical_agent(review)
    assert(vim.api.nvim_win_get_width(review.panel.win) == 40, "sidebar width 40 with all 3 open")
    assert(vim.api.nvim_win_get_width(agent_win) == 50, "agent width 50 with all 3 open")
    assert(vim.api.nvim_get_option_value("winfixwidth", { win = agent_win, scope = "local" }) == true, "agent winfixwidth true with editor open")

    -- 3. Close editor while sidebar + AI are open -> sidebar stays 40, AI takes main width (~139).
    local editor_win = main_window.find(review)
    vim.api.nvim_win_close(editor_win, true)
    assert(vim.wait(1000, function()
        return vim.api.nvim_win_get_width(review.panel.win) == 40
            and vim.api.nvim_win_get_width(agent_win) >= 120
            and vim.api.nvim_get_option_value("winfixwidth", { win = agent_win, scope = "local" }) == false
    end), "closing editor lets AI take main width while sidebar stays 40")

    -- 4. Reopen file from panel -> editor returns in middle, sidebar=40, AI=50.
    vim.api.nvim_set_current_win(review.panel.win)
    vim.api.nvim_win_set_cursor(review.panel.win, { file_line, 0 })
    panel_view.open_file_under_cursor(review)
    assert(vim.wait(1000, function()
        return vim.api.nvim_win_get_width(review.panel.win) == 40
            and vim.api.nvim_win_get_width(agent_win) == 50
            and vim.api.nvim_get_option_value("winfixwidth", { win = agent_win, scope = "local" }) == true
    end), "reopening file restores sidebar=40 and agent=50")

    -- 5. Manual resize is preserved while topology stays unchanged.
    vim.api.nvim_win_set_width(review.panel.win, 54)
    layout.reconcile(review)
    assert(vim.api.nvim_win_get_width(review.panel.win) == 54, "manual resize preserved when topology unchanged")

    -- 6. Toggle sidebar closed with `:Jpr panel` -> editor takes main width, AI stays 50.
    review.panel.collapsed_dirs["src"] = true
    session.panel_current()
    assert(not panel_view.is_open(review), "panel closed by :Jpr panel")
    assert(vim.wait(1000, function()
        local active_editor = main_window.find(review)
        return vim.api.nvim_win_get_width(agent_win) == 50 and vim.api.nvim_win_get_width(active_editor) >= 120
    end), "editor takes main width and AI stays 50 when sidebar closed")

    -- 7. Reopen sidebar via `gP` -> returns on far left at 40, preserving collapsed_dirs.
    local active_editor = main_window.find(review)
    vim.api.nvim_set_current_win(active_editor)
    helpers.press_key("gP")
    assert(vim.wait(1000, function()
        return panel_view.is_open(review) and vim.api.nvim_win_get_width(review.panel.win) == 40
    end), "gP reopens sidebar at width 40")
    assert(review.panel.collapsed_dirs["src"] == true, "collapsed_dirs preserved across close/reopen")
    assert(vim.api.nvim_win_get_width(agent_win) == 50, "agent stays 50 after sidebar reopens")

    -- 8. Cannot close sidebar when it is the only window in the tab.
    vim.api.nvim_win_close(agent_win, true)
    vim.api.nvim_win_close(active_editor, true)
    if vim.api.nvim_buf_is_valid(agent_buf) then
        vim.api.nvim_buf_delete(agent_buf, { force = true })
    end
    review.agent = nil
    local errors = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then
            errors[#errors + 1] = msg
        end
    end
    session.panel_current()
    vim.notify = orig_notify
    assert(panel_view.is_open(review), "panel stays open when it is the last window")
    assert(#errors >= 1, "closing last window reports an error")

    session.close_current()
    jpr.setup({})
end

test_compute_layout_widths()
test_live_layout_transitions_and_panel_toggle()

print("layout_and_panel_toggle_spec: ok")
