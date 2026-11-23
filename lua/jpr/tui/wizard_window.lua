-- Floating window creation, geometry clamping, and buffer/extmark painting
-- helpers shared by the command palette and step-by-step wizard controller.
local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-tui")

local function sanitize_single_line(text)
    return (tostring(text or ""):gsub("[\r\n]+", " "))
end

local function compute_centered_row(height)
    return math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
end

local function compute_centered_col(width)
    return math.max(1, math.floor((vim.o.columns - width) / 2))
end

--- Computes the clamped floating modal inner width for the current editor size.
--- @return integer
function M.compute_modal_width()
    local preferred_width = math.max(56, math.min(92, vim.o.columns - 6))
    local max_allowed_width = math.max(20, vim.o.columns - 4)
    return math.min(preferred_width, max_allowed_width)
end

--- Computes the clamped floating modal inner height for `line_count` and `min_height`.
--- @param line_count integer
--- @param min_height integer
--- @return integer
function M.compute_modal_height(line_count, min_height)
    local floor_height = math.max(1, tonumber(min_height) or 6)
    local max_allowed_height = math.max(floor_height, vim.o.lines - 4)
    return math.min(math.max(floor_height, tonumber(line_count) or floor_height), max_allowed_height)
end

--- Builds centered rounded floating window options for `nvim_open_win`.
--- @param width integer
--- @param height integer
--- @param title string
--- @param footer string|nil
--- @return table
function M.create_window_config(width, height, title, footer)
    local config = {
        relative = "editor",
        row = compute_centered_row(height),
        col = compute_centered_col(width),
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = sanitize_single_line(title),
        title_pos = "center",
    }
    if type(footer) == "string" and footer ~= "" then
        config.footer = sanitize_single_line(footer)
        config.footer_pos = "center"
    end
    return config
end

--- Safely closes a floating window handle and force-deletes its scratch buffer.
--- @param win integer|nil
--- @param buf integer|nil
function M.close_handle(win, buf)
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
end

local function apply_layout_to_buffer(buf, layout)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, layout.lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    for _, highlight in ipairs(layout.highlights or {}) do
        vim.api.nvim_buf_set_extmark(buf, namespace, highlight.line, highlight.col_start, {
            end_col = highlight.col_end,
            hl_group = highlight.group,
            strict = false,
        })
    end
end

local function resize_centered_window(win, width, height)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    pcall(vim.api.nvim_win_set_config, win, {
        relative = "editor",
        row = compute_centered_row(height),
        col = compute_centered_col(width),
        width = width,
        height = height,
    })
end

--- Creates a Normal-mode scratch buffer and centered floating window for a menu layout.
--- @param title string
--- @param layout table
--- @param width integer
--- @return integer buf, integer win
function M.create_menu_window(title, layout, width)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "jpr-tui"
    apply_layout_to_buffer(buf, layout)

    local height = M.compute_modal_height(#layout.lines, 6)
    local win = vim.api.nvim_open_win(buf, true, M.create_window_config(width, height, title, nil))
    vim.api.nvim_set_option_value("cursorline", true, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("wrap", false, { win = win, scope = "local" })
    local cursor_line = math.max(1, math.min(layout.cursor_line or 1, math.max(1, #layout.lines)))
    pcall(vim.api.nvim_win_set_cursor, win, { cursor_line, 0 })
    return buf, win
end

--- Repaints a menu floating window with `layout`, updating height and cursor row.
--- @param buf integer
--- @param win integer
--- @param layout table
--- @param width integer
function M.paint_menu_window(buf, win, layout, width)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    apply_layout_to_buffer(buf, layout)
    local height = M.compute_modal_height(#layout.lines, 6)
    resize_centered_window(win, width, height)
    if win and vim.api.nvim_win_is_valid(win) then
        local cursor_line = math.max(1, math.min(layout.cursor_line or 1, math.max(1, #layout.lines)))
        pcall(vim.api.nvim_win_set_cursor, win, { cursor_line, 0 })
    end
end

--- Applies `virt_lines_above = true` extmarks on line 0 of a text-step buffer and resizes.
--- @param buf integer
--- @param win integer
--- @param virt_lines table[]
--- @param width integer
function M.paint_text_virt_lines(buf, win, virt_lines, width)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
        virt_lines = virt_lines,
        virt_lines_above = true,
    })
    local height = M.compute_modal_height(#virt_lines + 1, 4)
    resize_centered_window(win, width, height)
end

--- Creates a single-line editable floating window for a wizard `text` step.
--- @param title string
--- @param footer string
--- @param initial_text string
--- @param virt_lines table[]
--- @param width integer
--- @return integer buf, integer win
function M.create_text_window(title, footer, initial_text, virt_lines, width)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "jpr-tui-input"
    vim.bo[buf].modifiable = true

    local single_line_text = sanitize_single_line(initial_text)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { single_line_text })

    local height = M.compute_modal_height(#virt_lines + 1, 4)
    local win = vim.api.nvim_open_win(buf, true, M.create_window_config(width, height, title, footer))
    vim.api.nvim_set_option_value("cursorline", false, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("wrap", false, { win = win, scope = "local" })
    M.paint_text_virt_lines(buf, win, virt_lines, width)
    pcall(vim.api.nvim_win_set_cursor, win, { 1, math.max(0, #single_line_text - 1) })
    return buf, win
end

return M
