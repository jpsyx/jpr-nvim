-- Foldtext, fold-option save/restore, and synchronized split fold toggling
-- for the full branch diff stream.
local M = {}

local STREAM_FOLD_OPTIONS = { "foldtext", "fillchars", "foldminlines" }

--- Virtual-text foldtext for collapsed viewed files: renders only the sanitized
--- file header line (`▸ ✓ path  +N -M`) in `JprFileHeader` with no extra banner.
function M.foldtext()
    local line_text = vim.fn.getline(vim.v.foldstart)
    return { { vim.fn.strtrans(line_text), "JprFileHeader" } }
end

local function merge_fold_fillchars(existing)
    local kept = {}
    for _, entry in ipairs(vim.split(tostring(existing or ""), ",", { plain = true, trimempty = true })) do
        if not vim.startswith(entry, "fold:") then
            kept[#kept + 1] = entry
        end
    end
    kept[#kept + 1] = "fold: "
    return table.concat(kept, ",")
end

--- Saves and applies window-local fold display options for stream window `win`.
function M.apply_window_fold_options(win)
    if type(vim.w[win].jpr_stream_fold_opts) ~= "table" then
        local saved = {}
        for _, name in ipairs(STREAM_FOLD_OPTIONS) do
            saved[name] = vim.api.nvim_get_option_value(name, { win = win, scope = "local" })
        end
        vim.w[win].jpr_stream_fold_opts = saved
    end
    vim.api.nvim_set_option_value("foldmethod", "manual", { win = win, scope = "local" })
    vim.api.nvim_set_option_value("foldenable", true, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("foldminlines", 0, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("foldtext", "v:lua.require('jpr.views.stream').foldtext()", { win = win, scope = "local" })
    vim.api.nvim_set_option_value("fillchars", merge_fold_fillchars(vim.w[win].jpr_stream_fold_opts.fillchars), { win = win, scope = "local" })
end

--- Restores window-local fold display options saved before `style_window` so
--- real files opened in the main window inherit zero stream fold styling.
function M.restore_window_fold_options(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    local saved = vim.w[win].jpr_stream_fold_opts
    if type(saved) ~= "table" then
        return
    end
    vim.w[win].jpr_stream_fold_opts = nil
    for _, name in ipairs(STREAM_FOLD_OPTIONS) do
        vim.api.nvim_set_option_value(name, saved[name], { win = win, scope = "local" })
    end
end

--- Executes manual fold command `command` (`zo`, `zc`, or `za`) at the cursor
--- line, keeping both split stream panes synchronized when split.
function M.toggle_fold(session, command)
    local current_win = vim.api.nvim_get_current_win()
    local cursor_line = vim.api.nvim_win_get_cursor(current_win)[1]
    local state = session and session.stream
    local windows = { current_win }
    if state and state.left_win and vim.api.nvim_win_is_valid(state.left_win) then
        local main_buf = state.buffers and state.buffers.main
        local main_win = main_buf and vim.fn.win_findbuf(main_buf)[1] or nil
        if current_win == main_win then
            windows[#windows + 1] = state.left_win
        elseif current_win == state.left_win and main_win and vim.api.nvim_win_is_valid(main_win) then
            windows[#windows + 1] = main_win
        end
    end
    for _, win in ipairs(windows) do
        vim.api.nvim_win_call(win, function()
            local max_line = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
            pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, math.min(cursor_line, max_line)), 0 })
            vim.cmd("silent! normal! " .. command)
        end)
    end
end

--- Folds the bodies of viewed files in `win`.
function M.set_folds(win, folds)
    vim.api.nvim_win_call(win, function()
        vim.cmd("silent! normal! zE")
        for _, fold in ipairs(folds) do
            vim.cmd(("%d,%dfold"):format(fold.first, fold.last))
        end
    end)
end

return M
