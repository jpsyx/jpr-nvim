-- Neovim floating window and timer primitives for `jpr.notify`.
local layout = require("jpr.notify.layout")

local M = {}

--- Safely stops and closes a `vim.uv` timer handle if still open.
function M.stop_timer(timer)
    if not timer then
        return
    end
    pcall(timer.stop, timer)
    if not timer:is_closing() then
        pcall(timer.close, timer)
    end
end

--- Closes `toast`'s floating window, deletes its scratch buffer, and stops its timer.
function M.close_toast(toast)
    M.stop_timer(toast.dismiss_timer)
    toast.dismiss_timer = nil
    if toast.win and vim.api.nvim_win_is_valid(toast.win) then
        pcall(vim.api.nvim_win_close, toast.win, true)
    end
    if toast.buf and vim.api.nvim_buf_is_valid(toast.buf) then
        pcall(vim.api.nvim_buf_delete, toast.buf, { force = true })
    end
    toast.win = nil
    toast.buf = nil
end

--- Paints `toast`'s buffer text, dimensions, and semantic `winhighlight`.
function M.paint_toast(toast, spinner_index)
    if not toast.buf or not vim.api.nvim_buf_is_valid(toast.buf) then
        return
    end
    local lines = layout.format_toast_lines(toast, spinner_index)
    local width, height = layout.compute_toast_dimensions(lines)
    toast.width = width
    toast.height = height
    vim.bo[toast.buf].modifiable = true
    vim.api.nvim_buf_set_lines(toast.buf, 0, -1, false, lines)
    vim.bo[toast.buf].modifiable = false
    if toast.win and vim.api.nvim_win_is_valid(toast.win) then
        local winhl = layout.build_winhighlight_from_kind(toast.kind)
        vim.api.nvim_set_option_value("winhighlight", winhl, { win = toast.win })
    end
end

--- Reflows all visible `toasts` downward from the top-right corner of the editor.
function M.reflow_toasts(toasts)
    local next_row = 1
    local max_row = math.max(2, vim.o.lines - 3)
    local anchor_col = math.max(1, vim.o.columns - 1)
    for _, toast in ipairs(toasts) do
        if toast.win and vim.api.nvim_win_is_valid(toast.win) then
            local row = math.min(next_row, max_row)
            local spec = layout.KIND_SPECS[toast.kind] or layout.KIND_SPECS.info
            pcall(vim.api.nvim_win_set_config, toast.win, {
                relative = "editor",
                anchor = "NE",
                row = row,
                col = anchor_col,
                width = toast.width,
                height = toast.height,
                border = "rounded",
                title = toast.title or spec.title,
                title_pos = "left",
                zindex = 250,
            })
            next_row = row + toast.height + 2
        end
    end
end

--- Opens a non-focusable top-right floating window for `toast` and attaches it.
function M.open_toast_window(toast, spinner_index)
    local spec = layout.KIND_SPECS[toast.kind] or layout.KIND_SPECS.info
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false
    toast.buf = buf
    M.paint_toast(toast, spinner_index)
    local is_opened, win = pcall(vim.api.nvim_open_win, buf, false, {
        relative = "editor",
        anchor = "NE",
        row = 1,
        col = math.max(1, vim.o.columns - 1),
        width = toast.width,
        height = toast.height,
        style = "minimal",
        border = "rounded",
        title = toast.title or spec.title,
        title_pos = "left",
        focusable = false,
        noautocmd = true,
        zindex = 250,
    })
    if not is_opened or not win then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        toast.buf = nil
        return false
    end
    toast.win = win
    vim.w[win].jpr_side = true
    local winhl = layout.build_winhighlight_from_kind(toast.kind)
    vim.api.nvim_set_option_value("winhighlight", winhl, { win = win })
    return true
end

return M
