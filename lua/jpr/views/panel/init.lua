-- The PR panel window: draws render.panel output as a vertical-only collapsible
-- menu, opens files/conversation, toggles directories, toggles viewed on v,
-- and filters to files that still need review on u or by clicking the filter pill.
local keymaps = require("jpr.views.panel.keymaps")
local navigation = require("jpr.views.panel.navigation")
local panel_cursor = require("jpr.views.panel_cursor")
local render = require("jpr.render.panel")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-panel")

local function git_stdout(worktree, args)
    local command = { "git", "-C", worktree }
    for _, arg in ipairs(args) do
        command[#command + 1] = arg
    end
    local output = vim.fn.system(command)
    if vim.v.shell_error ~= 0 then
        return nil
    end
    return vim.trim(output or "")
end

--- The branch checked out in `worktree`, or nil when git cannot answer.
--- Uses `vim.fn.system` so a panel redraw inside a job callback cannot stall
--- the libuv loop the way `vim.system(...):wait()` can.
local function read_checked_out_branch(worktree)
    if type(worktree) ~= "string" or worktree == "" or vim.fn.isdirectory(worktree) ~= 1 then
        return nil
    end
    local name = git_stdout(worktree, { "branch", "--show-current" })
    if name == nil then
        return nil
    end
    if name ~= "" then
        return name
    end
    local sha = git_stdout(worktree, { "rev-parse", "--short", "HEAD" })
    if sha == nil or sha == "" then
        return nil
    end
    return "detached-" .. sha
end

local function cached_checkout_branch(session)
    if type(session.worktree) ~= "string" or session.worktree == "" then
        return nil
    end
    if session.checkout_branch_known == true then
        return session.checkout_branch
    end
    session.checkout_branch = read_checked_out_branch(session.worktree)
    session.checkout_branch_known = true
    return session.checkout_branch
end

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

local function count_non_floating_windows(tab)
    if not tab or not vim.api.nvim_tabpage_is_valid(tab) then
        return 0
    end
    local window_count = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        local win_config = vim.api.nvim_win_get_config(win)
        if not win_config.relative or win_config.relative == "" then
            window_count = window_count + 1
        end
    end
    return window_count
end

--- Returns whether `session`'s diff sidebar panel window is currently open.
function M.is_open(session)
    local panel = session and session.panel
    return panel ~= nil
        and panel.win ~= nil
        and panel.buf ~= nil
        and vim.api.nvim_win_is_valid(panel.win)
        and vim.api.nvim_buf_is_valid(panel.buf)
        and vim.api.nvim_win_get_buf(panel.win) == panel.buf
        and vim.api.nvim_win_get_tabpage(panel.win) == session.tab
end

--- Opens the panel on the left of `session`'s tab (or focuses it if already open).
function M.open(session)
    if M.is_open(session) then
        vim.api.nvim_set_current_win(session.panel.win)
        require("jpr.views.layout").reconcile(session, { force = true })
        return
    end
    if session.tab and vim.api.nvim_tabpage_is_valid(session.tab) and vim.api.nvim_get_current_tabpage() ~= session.tab then
        vim.api.nvim_set_current_tabpage(session.tab)
    end
    local collapsed_dirs = navigation.collapsed_set_from_view(session.view)
    M.close(session)
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
    session.panel_collapsed_dirs = collapsed_dirs
    session.panel = { buf = buf, win = win, paths = {}, rows = {}, selectable_lines = {}, collapsed_dirs = collapsed_dirs }
    keymaps.bind_all(M, session, buf)
    M.render(session, session.view or {})
    require("jpr.views.layout").reconcile(session, { force = true })
end

--- Toggles `session`'s diff sidebar panel, preserving collapsed directories and
--- refusing to close the last window in the tab.
function M.toggle(session)
    if M.is_open(session) then
        if count_non_floating_windows(session.tab) <= 1 then
            require("jpr").error("cannot close the last window in the tab")
            return false
        end
        session.panel_collapsed_dirs = session.panel.collapsed_dirs
        M.close(session)
        session.panel = nil
        require("jpr.views.layout").reconcile(session, { force = true })
        return true
    end
    M.open(session)
    return true
end

--- Wipes the panel buffer, which also closes its window.
function M.close(session)
    local panel = session.panel
    if panel then
        panel_cursor.clear(panel)
    end
    if panel and panel.collapsed_dirs then
        session.panel_collapsed_dirs = panel.collapsed_dirs
    end
    if panel and panel.buf and vim.api.nvim_buf_is_valid(panel.buf) then
        vim.api.nvim_buf_delete(panel.buf, { force = true })
    end
end

local function apply_panel_buffer(panel, built)
    panel.paths = built.paths
    panel.rows = built.rows
    panel.highlights = built.highlights
    panel.selectable_lines = built.selectable_lines
    panel.filter_line = built.filter_line
    panel.summary_line = built.summary_line
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
    local width = vim.api.nvim_win_is_valid(panel.win) and vim.api.nvim_win_get_width(panel.win) or nil
    local collapsed_dirs = navigation.collapsed_set_from_view(effective_view)
    panel.collapsed_dirs = collapsed_dirs
    session.panel_collapsed_dirs = collapsed_dirs
    local built = render.build(effective_view, os.time(), {
        collapsed_dirs = collapsed_dirs,
        width = width,
        checkout_branch = cached_checkout_branch(session),
        hide_viewed = session.panel_hide_viewed == true,
    })
    apply_panel_buffer(panel, built)
    local target_line = navigation.find_preserved_cursor_line(built, prev_row, prev_line)
    if target_line then
        navigation.set_cursor_line(panel, target_line)
    end
    panel_cursor.sync(panel)
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

--- Opens the diff summary, conversation, or file on the cursor line in the main window beside the panel.
function M.open_file_under_cursor(session)
    local panel = session.panel
    local cursor_line = vim.api.nvim_win_get_cursor(panel.win)[1]
    if cursor_line == panel.summary_line then
        return require("jpr.session").summary_current()
    end
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

M.advance_after_viewed = navigation.advance_after_viewed

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
