-- The PR panel window: draws render.panel output and opens files on <CR>.
local render = require("jpr.render.panel")

local M = {}

local ns = vim.api.nvim_create_namespace("jpr-panel")

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
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].winfixwidth = true
    vim.wo[win].cursorline = true
    vim.wo[win].wrap = false
    session.panel = { buf = buf, win = win, paths = {} }
    vim.keymap.set("n", "<CR>", function()
        M.open_file_under_cursor(session)
    end, { buffer = buf, desc = "Open the file under the cursor" })
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
    vim.bo[panel.buf].modifiable = true
    vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, built.lines)
    vim.bo[panel.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(panel.buf, ns, 0, -1)
    for _, hl in ipairs(built.highlights) do
        vim.api.nvim_buf_set_extmark(panel.buf, ns, hl.line, hl.col_start, { end_col = hl.col_end, hl_group = hl.group })
    end
end

--- Opens the file on the cursor line in the window beside the panel.
function M.open_file_under_cursor(session)
    local panel = session.panel
    local path = panel.paths[vim.api.nvim_win_get_cursor(panel.win)[1]]
    if not path then
        return
    end
    local target
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if win ~= panel.win then
            target = win
            break
        end
    end
    if not target then
        vim.cmd("rightbelow vsplit")
        target = vim.api.nvim_get_current_win()
    end
    vim.api.nvim_set_current_win(target)
    -- Relative to the tab's directory, which is the worktree.
    vim.cmd.edit(path)
end

return M
