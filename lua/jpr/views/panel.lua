-- The PR panel window: draws render.panel output as a vertical-only collapsible
-- menu, opens files/conversation, toggles directories, and toggles viewed on v.
local render = require("jpr.render.panel")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-panel")
local HORIZONTAL_NOOP_KEYS = { "0", "^", "$", "w", "W", "b", "B", "e", "E", "ge", "gE", "f", "F", "t", "T", ";", "," }

--- The panel's look in `win`, local to the window: `vim.wo` would also set
--- the window's global values, which a window split from the panel (the main
--- window, when there is none) would inherit for the files it opens.
local function style_window(win)
    local function set(name, value)
        vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
    end
    set("number", false)
    set("relativenumber", false)
    set("signcolumn", "no")
    set("winfixwidth", true)
    set("cursorline", true)
    set("wrap", false)
    set("sidescrolloff", 0)
end

local function set_cursor_line(panel, target_line)
    if not panel or not vim.api.nvim_win_is_valid(panel.win) or not target_line then
        return
    end
    panel.is_clamping = true
    pcall(vim.api.nvim_win_set_cursor, panel.win, { target_line, 0 })
    panel.is_clamping = false
end

local function find_nearest_selectable_line(selectable_lines, line)
    local total = #(selectable_lines or {})
    if total == 0 then
        return nil
    end
    if line <= selectable_lines[1] then
        return selectable_lines[1]
    end
    if line >= selectable_lines[total] then
        return selectable_lines[total]
    end
    for _, candidate in ipairs(selectable_lines) do
        if candidate >= line then
            return candidate
        end
    end
    return selectable_lines[total]
end

local function clamp_cursor(panel)
    if not panel or panel.is_clamping or not vim.api.nvim_win_is_valid(panel.win) then
        return
    end
    if vim.api.nvim_win_get_buf(panel.win) ~= panel.buf or #(panel.selectable_lines or {}) == 0 then
        return
    end
    local cursor = vim.api.nvim_win_get_cursor(panel.win)
    local target_line = panel.rows[cursor[1]] ~= nil and cursor[1] or find_nearest_selectable_line(panel.selectable_lines, cursor[1])
    if target_line and (target_line ~= cursor[1] or cursor[2] ~= 0) then
        set_cursor_line(panel, target_line)
    end
end

local function find_selectable_index(selectable_lines, line)
    for index, candidate in ipairs(selectable_lines) do
        if candidate == line then
            return index
        end
    end
    return nil
end

local function move_selection(session, delta)
    local panel = session.panel
    local selectable_lines = panel and panel.selectable_lines or {}
    if #selectable_lines == 0 or not vim.api.nvim_win_is_valid(panel.win) then
        return
    end
    local cursor_line = vim.api.nvim_win_get_cursor(panel.win)[1]
    local current_index = find_selectable_index(selectable_lines, cursor_line)
    if not current_index then
        return set_cursor_line(panel, find_nearest_selectable_line(selectable_lines, cursor_line))
    end
    local target_index = math.max(1, math.min(#selectable_lines, current_index + delta))
    set_cursor_line(panel, selectable_lines[target_index])
end

local function jump_selection(session, is_last)
    local panel = session.panel
    local selectable_lines = panel and panel.selectable_lines or {}
    if #selectable_lines == 0 then
        return
    end
    set_cursor_line(panel, is_last and selectable_lines[#selectable_lines] or selectable_lines[1])
end

local function find_dir_line(panel, dir_path)
    for _, line in ipairs(panel.selectable_lines or {}) do
        local row = panel.rows[line]
        if row and row.kind == "dir" and row.path == dir_path then
            return line
        end
    end
    return nil
end

local function handle_left(session)
    local row_info = M.get_row_under_cursor(session)
    if not row_info then
        return
    end
    local panel, row = session.panel, row_info.row
    if row.kind == "dir" and not row.is_collapsed then
        panel.collapsed_dirs[row.path] = true
        return M.render(session, session.view or {})
    end
    if row.parent_dir then
        local parent_line = find_dir_line(panel, row.parent_dir)
        if parent_line then
            set_cursor_line(panel, parent_line)
        end
    end
end

local function handle_right(session)
    local row_info = M.get_row_under_cursor(session)
    if not row_info then
        return
    end
    local panel, row = session.panel, row_info.row
    if row.kind ~= "dir" then
        return
    end
    if row.is_collapsed then
        panel.collapsed_dirs[row.path] = nil
        return M.render(session, session.view or {})
    end
    local current_index = find_selectable_index(panel.selectable_lines, row_info.line)
    local next_line = current_index and panel.selectable_lines[current_index + 1] or nil
    local next_row = next_line and panel.rows[next_line] or nil
    if next_row and type(next_row.depth) == "number" and next_row.depth > row.depth then
        set_cursor_line(panel, next_line)
    end
end

local function handle_open_key(session)
    local row_info = M.get_row_under_cursor(session)
    if not row_info then
        return
    end
    local row = row_info.row
    if row.kind == "dir" then
        if row.is_collapsed then
            session.panel.collapsed_dirs[row.path] = nil
            M.render(session, session.view or {})
        end
        return
    end
    M.open_file_under_cursor(session)
end

local function handle_enter_key(session)
    local row_info = M.get_row_under_cursor(session)
    if not row_info then
        return
    end
    local row = row_info.row
    if row.kind == "dir" then
        session.panel.collapsed_dirs[row.path] = (not row.is_collapsed) and true or nil
        return M.render(session, session.view or {})
    end
    M.open_file_under_cursor(session)
end

local function bind_navigation_keymaps(session, buf)
    local map = function(lhs, rhs, desc)
        vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
    for _, key in ipairs(HORIZONTAL_NOOP_KEYS) do
        map(key, "<Nop>", "Disabled horizontal motion in Jpr panel")
    end
    map("j", function() move_selection(session, vim.v.count1) end, "Next item in Jpr panel")
    map("<Down>", function() move_selection(session, vim.v.count1) end, "Next item in Jpr panel")
    map("k", function() move_selection(session, -vim.v.count1) end, "Previous item in Jpr panel")
    map("<Up>", function() move_selection(session, -vim.v.count1) end, "Previous item in Jpr panel")
    map("gg", function() jump_selection(session, false) end, "First item in Jpr panel")
    map("<Home>", function() jump_selection(session, false) end, "First item in Jpr panel")
    map("G", function() jump_selection(session, true) end, "Last item in Jpr panel")
    map("<End>", function() jump_selection(session, true) end, "Last item in Jpr panel")
    map("h", function() handle_left(session) end, "Collapse directory or jump to parent")
    map("<Left>", function() handle_left(session) end, "Collapse directory or jump to parent")
    map("l", function() handle_right(session) end, "Expand directory or step into first child")
    map("<Right>", function() handle_right(session) end, "Expand directory or step into first child")
end

local function bind_action_keymaps(session, buf)
    vim.keymap.set("n", "<CR>", function()
        handle_enter_key(session)
    end, { buffer = buf, nowait = true, silent = true, desc = "Open the conversation or file, or toggle directory" })
    vim.keymap.set("n", "o", function()
        handle_open_key(session)
    end, { buffer = buf, nowait = true, silent = true, desc = "Open the conversation or file under the cursor" })
    vim.keymap.set("n", "v", function()
        M.toggle_viewed_under_cursor(session)
    end, { buffer = buf, nowait = true, silent = true, desc = "Toggle viewed for the file or directory under the cursor" })
    vim.keymap.set("n", "r", function()
        require("jpr.views.panel_input").start_rename(session)
    end, { buffer = buf, nowait = true, silent = true, desc = "Rename or move file or directory under cursor" })
    vim.keymap.set("n", "a", function()
        require("jpr.views.panel_input").start_create(session)
    end, { buffer = buf, nowait = true, silent = true, desc = "Create file or directory under cursor" })
    vim.keymap.set("n", "?", function()
        require("jpr.views.cheatsheet").open()
    end, { buffer = buf, nowait = true, silent = true, desc = "Show Jpr keyboard shortcuts" })
    local jpr = require("jpr")
    jpr.bind_session_keys(buf)
    local keys = jpr.config.keys or {}
    if type(keys.full_diff) == "string" and keys.full_diff ~= "" then
        vim.keymap.set("n", keys.full_diff, "<Plug>(jpr-full-diff)", { buffer = buf, remap = true, silent = true, nowait = true, desc = "Switch to the full branch diff view" })
    end
    if type(keys.toggle_viewed) == "string" and keys.toggle_viewed ~= "" and keys.toggle_viewed ~= "v" then
        vim.keymap.set("n", keys.toggle_viewed, "<Plug>(jpr-toggle-viewed)", { buffer = buf, remap = true, silent = true, nowait = true, desc = "Toggle viewed for the file or directory under the cursor" })
    end
end

--- Opens the panel on the left of the current tab for `session`.
function M.open(session)
    local buf = vim.api.nvim_create_buf(false, true)
    local buf_key = require("jpr.session").buf_key(session)
    local named, name_err = pcall(vim.api.nvim_buf_set_name, buf, "jpr://panel/" .. buf_key)
    if not named then
        vim.api.nvim_buf_delete(buf, { force = true })
        error(name_err, 0)
    end
    vim.bo[buf].filetype = "jpr-panel"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false
    vim.cmd("topleft vsplit")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_width(win, require("jpr").config.panel_width)
    style_window(win)
    session.panel = { buf = buf, win = win, paths = {}, rows = {}, selectable_lines = {}, collapsed_dirs = {} }
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = buf,
        callback = function()
            clamp_cursor(session.panel)
        end,
    })
    bind_navigation_keymaps(session, buf)
    bind_action_keymaps(session, buf)
    M.render(session, session.view or {})
end

--- Wipes the panel buffer, which also closes its window.
function M.close(session)
    local panel = session.panel
    if panel and vim.api.nvim_buf_is_valid(panel.buf) then
        vim.api.nvim_buf_delete(panel.buf, { force = true })
    end
end

local function find_preserved_cursor_line(built, prev_row, prev_line)
    if #(built.selectable_lines or {}) == 0 then
        return nil
    end
    if not prev_row then
        return built.conversation_line or built.selectable_lines[1]
    end
    if prev_row.kind == "conversation" then
        return built.conversation_line or built.selectable_lines[1]
    end
    if prev_row.path then
        local fallback_line = nil
        for _, line in ipairs(built.selectable_lines) do
            local row = built.rows[line]
            if row and row.path == prev_row.path then
                if row.kind == prev_row.kind then
                    return line
                end
                fallback_line = fallback_line or line
            end
        end
        if fallback_line then
            return fallback_line
        end
    end
    return find_nearest_selectable_line(built.selectable_lines, prev_line or built.selectable_lines[1])
end

--- Redraws the panel from `view`, preserving the cursor on the same item path.
function M.render(session, view)
    local panel = session.panel
    if not panel or not vim.api.nvim_buf_is_valid(panel.buf) then
        return
    end
    local prev_line = vim.api.nvim_win_is_valid(panel.win) and vim.api.nvim_win_get_cursor(panel.win)[1] or nil
    local prev_row = prev_line and panel.rows and panel.rows[prev_line] or nil
    local effective_view = view
    if session.is_read_only == true and (type(view) ~= "table" or view.isReadOnly ~= true) then
        effective_view = vim.tbl_extend("force", type(view) == "table" and view or {}, { isReadOnly = true })
    end
    local built = render.build(effective_view, os.time(), { collapsed_dirs = panel.collapsed_dirs })
    panel.paths = built.paths
    panel.rows = built.rows
    panel.selectable_lines = built.selectable_lines
    panel.conversation_line = built.conversation_line
    vim.bo[panel.buf].modifiable = true
    vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, built.lines)
    vim.bo[panel.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(panel.buf, namespace, 0, -1)
    for _, highlight in ipairs(built.highlights) do
        vim.api.nvim_buf_set_extmark(
            panel.buf,
            namespace,
            highlight.line,
            highlight.col_start,
            { end_col = highlight.col_end, hl_group = highlight.group }
        )
    end
    local target_line = find_preserved_cursor_line(built, prev_row, prev_line)
    if target_line then
        set_cursor_line(panel, target_line)
    end
end

--- Returns the 1-based cursor line and row metadata under the panel cursor, or nil.
function M.get_row_under_cursor(session)
    local panel = session and session.panel
    if not panel or not vim.api.nvim_win_is_valid(panel.win) then
        return nil
    end
    local cursor_line = vim.api.nvim_win_get_cursor(panel.win)[1]
    local row = panel.rows and panel.rows[cursor_line] or nil
    if not row then
        return nil
    end
    return { line = cursor_line, row = row }
end

--- Opens the conversation or file on the cursor line in the main window beside the panel.
function M.open_file_under_cursor(session)
    local panel = session.panel
    local cursor_line = vim.api.nvim_win_get_cursor(panel.win)[1]
    if cursor_line == panel.conversation_line then
        return require("jpr.session").conversation_current()
    end
    local path = panel.paths[cursor_line]
    if not path then
        return
    end
    local main_window = require("jpr.views.main_window")
    main_window.edit(session, main_window.find(session), path)
end

local function get_window_changed_path(session, win)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return nil
    end
    local buf = vim.api.nvim_win_get_buf(win)
    local base_path = vim.b[buf].jpr_base_path
    if type(base_path) == "string" and base_path ~= "" then
        return base_path
    end
    return require("jpr.views.diff").buffer_to_changed_path(session, buf)
end

--- Advances the main window to the next unviewed file (or full branch diff when
--- all files are viewed) if it is currently showing one of `marked_paths` and
--- the full diff stream is not already visible.
function M.advance_after_viewed(session, updated_view, marked_paths, opts)
    if session.closing or not vim.api.nvim_tabpage_is_valid(session.tab) then
        return
    end
    local stream = require("jpr.views.stream")
    if stream.is_visible(session) then
        return
    end
    local main_window = require("jpr.views.main_window")
    local main_win = main_window.find(session)
    local open_path = get_window_changed_path(session, main_win)
    if not open_path or not vim.tbl_contains(marked_paths or {}, open_path) then
        return
    end
    local should_focus_next = type(opts) == "table" and opts.focus_next == true
    local previous_win = vim.api.nvim_get_current_win()
    local next_path = render.find_next_unviewed_path(updated_view or session.view or {}, open_path)
    if next_path then
        main_window.edit(session, main_win, next_path, 1)
        if not should_focus_next and vim.api.nvim_win_is_valid(previous_win) then
            vim.api.nvim_set_current_win(previous_win)
        end
        return
    end
    stream.show(session, { focus = should_focus_next })
    require("jpr").info("all files viewed")
end

--- Marks the file or directory on the cursor line viewed, or unviewed when
--- already viewed.
function M.toggle_viewed_under_cursor(session)
    local row_info = M.get_row_under_cursor(session)
    if not row_info then
        return
    end
    local row = row_info.row
    local files = (session.view and session.view.files) or {}
    if row.kind == "dir" then
        local toggle = render.collect_directory_toggle_from_files(files, row.path)
        if not toggle then
            return
        end
        require("jpr.session").request(session, "setViewed", { paths = toggle.paths, viewed = toggle.viewed }, function(updated_view)
            if toggle.viewed then
                M.advance_after_viewed(session, updated_view, toggle.paths, { focus_next = false })
            end
        end)
        return
    end
    if row.kind ~= "file" or not row.path then
        return
    end
    local viewed
    for _, file in ipairs(files) do
        if file.path == row.path then
            viewed = file.viewed
        end
    end
    local target_viewed = viewed ~= "VIEWED"
    require("jpr.session").request(session, "setViewed", { path = row.path, viewed = target_viewed }, function(updated_view)
        if target_viewed then
            M.advance_after_viewed(session, updated_view, { row.path }, { focus_next = false })
        end
    end)
end

return M
