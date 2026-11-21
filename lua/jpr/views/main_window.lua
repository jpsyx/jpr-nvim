-- The window beside the panel, where the stream and the files show. jpr's
-- side windows (the panel, a base file, the stream's left half) never count.
local M = {}

--- Whether `win` is one of jpr's side windows rather than the main window.
function M.is_side(session, win)
    return (session.panel ~= nil and win == session.panel.win) or vim.w[win].jpr_side == true
end

--- The main window of `session`'s tab, opened right of the panel when there
--- is none.
function M.find(session)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
        if not M.is_side(session, win) then
            return win
        end
    end
    local panel = session.panel
    local anchor = (panel and vim.api.nvim_win_is_valid(panel.win)) and panel.win or vim.api.nvim_get_current_win()
    local placeholder = vim.api.nvim_create_buf(false, true)
    vim.bo[placeholder].bufhidden = "wipe"
    return vim.api.nvim_open_win(placeholder, false, { split = "right", win = anchor })
end

--- Opens `path` (from the pull request, so untrusted) in `win`, focused, at
--- `line` when given. Only a plain path inside the worktree opens: one with
--- `..`, `.`, `//`, a leading `/`, or a symlink (even a dangling or looping
--- one) is refused, so a save can never write outside the worktree.
function M.edit(session, win, path, line)
    -- Anchored in the worktree, so a leading `+cmd`, `~` or `-` is not
    -- special, and escaped, so `%`, `#` and spaces are taken literally.
    local full_path = session.worktree .. "/" .. path
    if require("jpr.views.diff").name_to_relative_path(session.worktree, full_path) ~= path then
        return require("jpr").error(("refusing to open %s: not a plain file path inside the worktree"):format(path))
    end
    vim.api.nvim_set_current_win(win)
    vim.cmd.edit(vim.fn.fnameescape(full_path))
    if line then
        local last_line = vim.api.nvim_buf_line_count(0)
        vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(line, last_line)), 0 })
    end
end

--- Shows an empty scratch buffer in every window currently displaying `buf` so
--- wiping `buf` never closes the main window or tab.
function M.release_windows(buf)
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        local empty = vim.api.nvim_create_buf(false, true)
        vim.bo[empty].bufhidden = "wipe"
        pcall(vim.api.nvim_win_set_buf, win, empty)
    end
end

return M
