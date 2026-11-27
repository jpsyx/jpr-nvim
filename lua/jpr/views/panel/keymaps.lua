-- Keymaps, mouse click handling, and cursor autocmds for the PR sidebar panel.
local mouse = require("jpr.mouse")
local navigation = require("jpr.views.panel.navigation")
local panel_cursor = require("jpr.views.panel_cursor")

local M = {}

local HORIZONTAL_NOOP_KEYS = { "0", "^", "$", "w", "W", "b", "B", "e", "E", "ge", "gE", "f", "F", "t", "T", ";", "," }

local function request_set_collapsed(session, path, collapsed)
    require("jpr.session").request(session, "setCollapsed", { path = path, collapsed = collapsed }, function(updated_view)
        if type(updated_view) == "table" then
            require("jpr.session").show_panel_only(session, updated_view)
        end
    end)
end

local function handle_left(panel_mod, session)
    local row_info = panel_mod.get_row_under_cursor(session)
    if not row_info then
        return
    end
    local panel, row = session.panel, row_info.row
    if row.kind == "dir" and not row.is_collapsed then
        return request_set_collapsed(session, row.path, true)
    end
    if row.parent_dir then
        local parent_line = navigation.find_dir_line(panel, row.parent_dir)
        if parent_line then
            navigation.set_cursor_line(panel, parent_line)
        end
    end
end

local function handle_right(panel_mod, session)
    local row_info = panel_mod.get_row_under_cursor(session)
    if not row_info then
        return
    end
    local panel, row = session.panel, row_info.row
    if row.kind ~= "dir" then
        return
    end
    if row.is_collapsed then
        return request_set_collapsed(session, row.path, false)
    end
    local current_index = navigation.find_selectable_index(panel.selectable_lines, row_info.line)
    local next_line = current_index and panel.selectable_lines[current_index + 1] or nil
    local next_row = next_line and panel.rows[next_line] or nil
    if next_row and type(next_row.depth) == "number" and next_row.depth > row.depth then
        navigation.set_cursor_line(panel, next_line)
    end
end

local function handle_open_key(panel_mod, session)
    local row_info = panel_mod.get_row_under_cursor(session)
    if not row_info then
        return
    end
    local row = row_info.row
    if row.kind == "dir" then
        if row.is_collapsed then
            request_set_collapsed(session, row.path, false)
        end
        return
    end
    panel_mod.open_file_under_cursor(session)
end

local function handle_enter_key(panel_mod, session)
    local row_info = panel_mod.get_row_under_cursor(session)
    if not row_info then
        return
    end
    local row = row_info.row
    if row.kind == "dir" then
        return request_set_collapsed(session, row.path, not row.is_collapsed)
    end
    panel_mod.open_file_under_cursor(session)
end

local function toggle_unviewed_filter(panel_mod, session)
    session.panel_hide_viewed = not session.panel_hide_viewed
    panel_mod.render(session, session.view or {})
end

local function handle_left_click(panel_mod, session)
    local panel = session.panel
    local click = mouse.get_click()
    if not panel or not click then
        return
    end
    if not mouse.is_click_in_window(click, panel.win) then
        return mouse.passthrough("<LeftMouse>")
    end
    if click.line == panel.filter_line then
        return toggle_unviewed_filter(panel_mod, session)
    end
    if panel.rows[click.line] == nil then
        return
    end
    navigation.set_cursor_line(panel, click.line)
    handle_enter_key(panel_mod, session)
end

local function bind_cursor_autocmds(session, buf)
    vim.api.nvim_create_autocmd({ "CursorMoved", "WinEnter", "WinScrolled", "VimResized" }, {
        buffer = buf,
        callback = function()
            if not session.panel or vim.api.nvim_get_current_win() ~= session.panel.win then
                return
            end
            navigation.clamp_cursor(session.panel)
            panel_cursor.sync(session.panel)
        end,
    })
    vim.api.nvim_create_autocmd("WinLeave", {
        buffer = buf,
        callback = function()
            panel_cursor.clear(session.panel)
        end,
    })
    vim.api.nvim_create_autocmd("ColorScheme", {
        buffer = buf,
        callback = function()
            panel_cursor.sync(session.panel)
        end,
    })
end

local function bind_navigation_keymaps(panel_mod, session, buf)
    local map = function(lhs, rhs, desc)
        vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
    for _, key in ipairs(HORIZONTAL_NOOP_KEYS) do
        map(key, "<Nop>", "Disabled horizontal motion in Jpr panel")
    end
    map("j", function() navigation.move_selection(session, vim.v.count1) end, "Next item in Jpr panel")
    map("<Down>", function() navigation.move_selection(session, vim.v.count1) end, "Next item in Jpr panel")
    map("k", function() navigation.move_selection(session, -vim.v.count1) end, "Previous item in Jpr panel")
    map("<Up>", function() navigation.move_selection(session, -vim.v.count1) end, "Previous item in Jpr panel")
    map("gg", function() navigation.jump_selection(session, false) end, "First item in Jpr panel")
    map("<Home>", function() navigation.jump_selection(session, false) end, "First item in Jpr panel")
    map("G", function() navigation.jump_selection(session, true) end, "Last item in Jpr panel")
    map("<End>", function() navigation.jump_selection(session, true) end, "Last item in Jpr panel")
    map("h", function() handle_left(panel_mod, session) end, "Collapse directory or jump to parent")
    map("<Left>", function() handle_left(panel_mod, session) end, "Collapse directory or jump to parent")
    map("l", function() handle_right(panel_mod, session) end, "Expand directory or step into first child")
    map("<Right>", function() handle_right(panel_mod, session) end, "Expand directory or step into first child")
end

local function bind_action_keymaps(panel_mod, session, buf)
    local map = function(lhs, rhs, desc)
        vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
    map("<CR>", function() handle_enter_key(panel_mod, session) end, "Open the conversation or file, or toggle directory")
    map("<LeftMouse>", function() handle_left_click(panel_mod, session) end, "Click to open file or toggle directory")
    map("o", function() handle_open_key(panel_mod, session) end, "Open the conversation or file under the cursor")
    map("v", function() panel_mod.toggle_viewed_under_cursor(session) end, "Toggle viewed for the file or directory under the cursor")
    map("u", function() toggle_unviewed_filter(panel_mod, session) end, "Show only files and directories that still need review")
    map("r", function() require("jpr.views.panel_input").start_rename(session) end, "Rename or move file or directory under cursor")
    map("a", function() require("jpr.views.panel_input").start_create(session) end, "Create file or directory under cursor")
    map("?", function() require("jpr.views.cheatsheet").open() end, "Show Jpr keyboard shortcuts")
    local jpr = require("jpr")
    jpr.bind_session_keys(buf)
    local keys = jpr.config.keys or {}
    if type(keys.full_diff) == "string" and keys.full_diff ~= "" then
        vim.keymap.set("n", keys.full_diff, "<Plug>(jpr-full-diff)", { buffer = buf, remap = true, silent = true, nowait = true, desc = "Switch to the full branch diff view" })
    end
    if type(keys.file_comment) == "string" and keys.file_comment ~= "" then
        vim.keymap.set("n", keys.file_comment, "<Plug>(jpr-file-comment)", { buffer = buf, remap = true, silent = true, nowait = true, desc = "New file-level comment on the file under the cursor" })
    end
    if type(keys.toggle_viewed) == "string" and keys.toggle_viewed ~= "" and keys.toggle_viewed ~= "v" then
        vim.keymap.set("n", keys.toggle_viewed, "<Plug>(jpr-toggle-viewed)", { buffer = buf, remap = true, silent = true, nowait = true, desc = "Toggle viewed for the file or directory under the cursor" })
    end
end

--- Attaches cursor autocmds, navigation keymaps, and action keymaps to `buf`.
function M.bind_all(panel_mod, session, buf)
    bind_cursor_autocmds(session, buf)
    bind_navigation_keymaps(panel_mod, session, buf)
    bind_action_keymaps(panel_mod, session, buf)
end

return M
