-- Signcolumn management and in-place thread redrawing for diff windows (`jpr.views.diff`).
local M = {}

--- Ensures `win` displays a sign column while `has_threads` is true.
function M.set_window_signcolumn(session, win, has_threads)
    if not session.diff then
        return
    end
    if not vim.api.nvim_win_is_valid(win) then
        session.diff.saved_signcolumn[win] = nil
        return
    end
    if has_threads then
        if session.diff.saved_signcolumn[win] == nil then
            session.diff.saved_signcolumn[win] = vim.api.nvim_get_option_value("signcolumn", { win = win, scope = "local" })
        end
        vim.api.nvim_set_option_value("signcolumn", "yes", { win = win, scope = "local" })
    elseif session.diff.saved_signcolumn[win] ~= nil then
        vim.api.nvim_set_option_value("signcolumn", session.diff.saved_signcolumn[win], { win = win, scope = "local" })
        session.diff.saved_signcolumn[win] = nil
    end
end

--- Draws threads for unified mode on `buf` and updates `win`'s signcolumn.
function M.draw_unified_threads(session, win, buf, diff)
    require("jpr.views.threads").draw_on_buffer(session, buf, diff.threads)
    local list = session.buf_threads and session.buf_threads[buf]
    M.set_window_signcolumn(session, win, list ~= nil and #list > 0)
end

--- Draws threads for split mode on `base_buf` and `buf` and updates both signcolumns.
function M.draw_split_threads(session, base_win, win, base_buf, buf, diff)
    require("jpr.views.threads").draw_split(session, base_buf, buf, diff)
    local base_list = session.buf_threads and session.buf_threads[base_buf]
    local file_list = session.buf_threads and session.buf_threads[buf]
    M.set_window_signcolumn(session, base_win, base_list ~= nil and #base_list > 0)
    M.set_window_signcolumn(session, win, file_list ~= nil and #file_list > 0)
end

--- Attaches `redraw_threads` onto `diff_mod`.
function M.attach(diff_mod, is_current)
    --- Refreshes thread marks on a drawn diff window without tearing down split windows.
    local function redraw_window_threads(session, win, applied)
        if not is_current(session, win, applied) then
            return
        end
        local path = diff_mod.buffer_to_changed_path(session, applied.buf)
        if not path then
            return
        end
        require("jpr.session").request(session, "fileDiff", { path = path }, function(diff)
            if not is_current(session, win, applied) or type(diff) ~= "table" or diff.binary then
                return
            end
            if applied.mode == "unified" then
                return M.draw_unified_threads(session, win, applied.buf, diff)
            end
            local base_split = session.diff.splits[win]
            if base_split and vim.api.nvim_win_is_valid(base_split.base_win) and vim.api.nvim_buf_is_valid(base_split.base_buf) then
                return M.draw_split_threads(session, base_split.base_win, win, base_split.base_buf, applied.buf, diff)
            end
            diff_mod.clear(session, win)
            if vim.api.nvim_win_is_valid(win) then
                diff_mod.apply(session, win)
            end
        end)
    end

    --- Redraws threads on every drawn diff window in `session` without tearing
    --- down existing split windows.
    function diff_mod.redraw_threads(session)
        if not session.diff or not session.client then
            return
        end
        local targets = {}
        for win, applied in pairs(session.diff.applied) do
            targets[#targets + 1] = { win = win, applied = applied }
        end
        for _, target in ipairs(targets) do
            redraw_window_threads(session, target.win, target.applied)
        end
    end
end

return M
