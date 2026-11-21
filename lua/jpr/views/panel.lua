-- The PR panel window: draws render.panel output, opens files on <CR> and
-- toggles viewed on v.
local render = require("jpr.render.panel")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-panel")

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
end

--- Opens the panel on the left of the current tab for `session`.
function M.open(session)
    local buf = vim.api.nvim_create_buf(false, true)
    local named, name_err = pcall(vim.api.nvim_buf_set_name, buf, ("jpr://panel/%d"):format(session.number))
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
    session.panel = { buf = buf, win = win, paths = {} }
    vim.keymap.set("n", "<CR>", function()
        M.open_file_under_cursor(session)
    end, { buffer = buf, desc = "Open the file under the cursor" })
    vim.keymap.set("n", "v", function()
        M.toggle_viewed_under_cursor(session)
    end, { buffer = buf, desc = "Toggle viewed for the file under the cursor" })
    M.render(session, session.view or {})
end

--- Wipes the panel buffer, which also closes its window.
function M.close(session)
    local panel = session.panel
    if panel and vim.api.nvim_buf_is_valid(panel.buf) then
        vim.api.nvim_buf_delete(panel.buf, { force = true })
    end
end

--- Redraws the panel from `view`.
function M.render(session, view)
    local panel = session.panel
    if not panel or not vim.api.nvim_buf_is_valid(panel.buf) then
        return
    end
    local built = render.build(view, os.time())
    panel.paths = built.paths
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

--- Marks the file on the cursor line viewed, or unviewed when it is.
function M.toggle_viewed_under_cursor(session)
    local panel = session.panel
    local path = panel.paths[vim.api.nvim_win_get_cursor(panel.win)[1]]
    if not path then
        return
    end
    local viewed
    for _, file in ipairs((session.view and session.view.files) or {}) do
        if file.path == path then
            viewed = file.viewed
        end
    end
    require("jpr.session").request(session, "setViewed", { path = path, viewed = viewed ~= "VIEWED" }, function() end)
end

return M
