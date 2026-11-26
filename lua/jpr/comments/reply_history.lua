-- Read-only thread history floating pane docked directly above the reply
-- compose window (`jpr.comments.compose`).
local popup = require("jpr.comments.popup")
local render = require("jpr.render.threads")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-reply-history")

--- Computes centered stacked geometry for a docked two-pane reply modal
--- (read-only thread history pane above the editable reply pane).
function M.compute_stacked_geometry(total_lines, total_cols, history_line_count)
    local width = math.min(86, math.max(54, total_cols - 12))
    local col = math.max(2, math.floor((total_cols - width) / 2))
    local usable_rows = math.max(8, total_lines - 6)
    local reply_height = math.min(10, math.max(4, math.floor(usable_rows * 0.4)))
    local max_history_height = math.max(4, usable_rows - reply_height)
    local history_height = math.min(max_history_height, math.max(4, history_line_count))
    local total_height = history_height + reply_height + 4
    local history_row = math.max(1, math.floor((total_lines - total_height) / 2))
    local reply_row = history_row + history_height + 2
    return {
        width = width,
        col = col,
        history_row = history_row,
        history_height = history_height,
        reply_row = reply_row,
        reply_height = reply_height,
    }
end

local function paint_history_buffer(buf, layout)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, layout.lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    for _, highlight in ipairs(layout.highlights) do
        vim.api.nvim_buf_set_extmark(buf, namespace, highlight.line, highlight.col_start, {
            end_col = highlight.col_end,
            hl_group = highlight.group,
            strict = false,
        })
    end
end

local function bind_history_keys(buf, callbacks)
    local map = function(lhs, handler, desc)
        vim.keymap.set("n", lhs, handler, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
    map("<Tab>", callbacks.on_focus_reply, "Focus reply input")
    map("<C-w>j", callbacks.on_focus_reply, "Focus reply input")
    map("q", callbacks.on_cancel, "Cancel reply")
    map("<Esc>", callbacks.on_cancel, "Cancel reply")
    map("<C-s>", callbacks.on_submit, "Submit reply")
end

--- Opens the read-only thread history floating pane for `thread` at `geometry`,
--- pre-scrolled to the start of the last message.
function M.open(thread, geometry, callbacks)
    local layout = render.create_popup_layout_from_threads({ thread }, { include_footer = false })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    paint_history_buffer(buf, layout)
    local win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        row = geometry.history_row,
        col = geometry.col,
        width = geometry.width,
        height = geometry.history_height,
        style = "minimal",
        border = "rounded",
        title = " Thread History ",
        title_pos = "center",
        footer = " <Tab>/<C-w>j reply · q cancel ",
        footer_pos = "center",
    })
    vim.api.nvim_set_option_value("wrap", true, { win = win, scope = "local" })
    popup.scroll_to_last_message(win, layout)
    bind_history_keys(buf, callbacks)
    return { buf = buf, win = win }
end

return M
