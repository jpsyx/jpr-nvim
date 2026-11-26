-- Floating window creation, geometry clamping, and buffer/extmark painting
-- helpers shared by the command palette and step-by-step wizard controller.
local render = require("jpr.tui.render")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-tui")
local prompt_namespace = vim.api.nvim_create_namespace("jpr-tui-prompt")
local PROMPT_OUTER_HEIGHT = 3
local PALETTE_PLACEHOLDER = "Type to filter commands..."

local function get_centered_row(height)
    local centered = math.floor((vim.o.lines - height) / 2) - 1
    local max_row = math.max(0, vim.o.lines - height - 2)
    return math.max(0, math.min(centered, max_row))
end

local function get_centered_col(width)
    return math.max(0, math.floor((vim.o.columns - width) / 2))
end

local function open_floating_window_or_cleanup(buf, config, should_enter)
    local enter = should_enter ~= false
    local is_ok, window_or_error = pcall(vim.api.nvim_open_win, buf, enter, config)
    if not is_ok then
        if vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
        error(window_or_error)
    end
    return window_or_error
end

--- Returns the clamped floating modal inner width for the current editor size.
--- @return integer
function M.get_modal_width()
    local preferred_width = math.max(56, math.min(92, vim.o.columns - 6))
    local max_allowed_width = math.max(20, vim.o.columns - 4)
    return math.min(preferred_width, max_allowed_width)
end

--- Returns the clamped floating modal inner height for `line_count` and `min_height`.
--- @param line_count integer
--- @param min_height integer
--- @return integer
function M.get_modal_height_from_lines(line_count, min_height)
    local max_viewport_height = math.max(1, vim.o.lines - 4)
    local floor_height = math.min(math.max(1, tonumber(min_height) or 6), max_viewport_height)
    return math.min(math.max(floor_height, tonumber(line_count) or floor_height), max_viewport_height)
end

--- Creates centered rounded floating window options for `nvim_open_win`.
--- @param width integer
--- @param height integer
--- @param title string
--- @param footer string|nil
--- @return table
function M.create_window_config(width, height, title, footer)
    local config = {
        relative = "editor",
        row = get_centered_row(height),
        col = get_centered_col(width),
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = render.to_single_line(title),
        title_pos = "center",
    }
    if type(footer) == "string" and footer ~= "" then
        config.footer = render.to_single_line(footer)
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
        row = get_centered_row(height),
        col = get_centered_col(width),
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

    local height = M.get_modal_height_from_lines(#layout.lines, 6)
    local win = open_floating_window_or_cleanup(buf, M.create_window_config(width, height, title, nil))
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
    local height = M.get_modal_height_from_lines(#layout.lines, 6)
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
    local height = M.get_modal_height_from_lines(#virt_lines + 1, 4)
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

    local single_line_text = render.to_single_line(initial_text)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { single_line_text })

    local height = M.get_modal_height_from_lines(#virt_lines + 1, 4)
    local win = open_floating_window_or_cleanup(buf, M.create_window_config(width, height, title, footer))
    vim.api.nvim_set_option_value("cursorline", false, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("wrap", false, { win = win, scope = "local" })
    M.paint_text_virt_lines(buf, win, virt_lines, width)
    local is_insert_mode = vim.fn.mode(1):sub(1, 1) == "i"
    local cursor_col = is_insert_mode and #single_line_text or math.max(0, #single_line_text - 1)
    pcall(vim.api.nvim_win_set_cursor, win, { 1, cursor_col })
    return buf, win
end

local function create_palette_stack_geometry(results_line_count, width)
    local max_results_height = math.max(1, vim.o.lines - PROMPT_OUTER_HEIGHT - 4)
    local floor_height = math.min(6, max_results_height)
    local results_height = math.min(math.max(floor_height, tonumber(results_line_count) or floor_height), max_results_height)
    local total_outer_height = PROMPT_OUTER_HEIGHT + results_height + 2
    local centered_row = math.floor((vim.o.lines - total_outer_height) / 2)
    local max_row = math.max(0, vim.o.lines - total_outer_height - 1)
    local prompt_row = math.max(0, math.min(centered_row, max_row))
    return {
        prompt_row = prompt_row,
        results_row = prompt_row + PROMPT_OUTER_HEIGHT,
        col = get_centered_col(width),
        width = width,
        results_height = results_height,
    }
end

--- Applies inline `> ` prompt prefix and optional empty placeholder to `prompt_buf`.
--- @param prompt_buf integer
--- @param is_empty boolean
function M.paint_palette_prompt_decorations(prompt_buf, is_empty)
    if not prompt_buf or not vim.api.nvim_buf_is_valid(prompt_buf) then
        return
    end
    vim.api.nvim_buf_clear_namespace(prompt_buf, prompt_namespace, 0, -1)
    vim.api.nvim_buf_set_extmark(prompt_buf, prompt_namespace, 0, 0, {
        virt_text = { { "> ", "JprTitle" } },
        virt_text_pos = "inline",
        right_gravity = false,
    })
    if is_empty then
        vim.api.nvim_buf_set_extmark(prompt_buf, prompt_namespace, 0, 0, {
            virt_text = { { PALETTE_PLACEHOLDER, "JprMuted" } },
            virt_text_pos = "eol",
        })
    end
end

local function create_stacked_window_config(row, col, width, height, title)
    local config = {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
    }
    if type(title) == "string" and title ~= "" then
        config.title = render.to_single_line(title)
        config.title_pos = "center"
    end
    return config
end

--- Creates stacked floating windows for the filterable command palette:
--- a 1-line editable prompt on top and a read-only scrollable results window below.
--- @param title string
--- @param layout table
--- @param width integer
--- @return integer prompt_buf, integer prompt_win, integer results_buf, integer results_win
function M.create_palette_windows(title, layout, width)
    local geometry = create_palette_stack_geometry(#layout.lines, width)

    local results_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[results_buf].buftype = "nofile"
    vim.bo[results_buf].bufhidden = "wipe"
    vim.bo[results_buf].filetype = "jpr-tui"
    apply_layout_to_buffer(results_buf, layout)

    local results_config = create_stacked_window_config(geometry.results_row, geometry.col, width, geometry.results_height, nil)
    local results_win = open_floating_window_or_cleanup(results_buf, results_config, false)
    vim.api.nvim_set_option_value("cursorline", true, { win = results_win, scope = "local" })
    vim.api.nvim_set_option_value("wrap", false, { win = results_win, scope = "local" })
    local cursor_line = math.max(1, math.min(layout.cursor_line or 1, math.max(1, #layout.lines)))
    pcall(vim.api.nvim_win_set_cursor, results_win, { cursor_line, 0 })

    local prompt_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[prompt_buf].buftype = "nofile"
    vim.bo[prompt_buf].bufhidden = "wipe"
    vim.bo[prompt_buf].filetype = "jpr-tui-input"
    vim.bo[prompt_buf].modifiable = true
    vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { "" })

    local prompt_config = create_stacked_window_config(geometry.prompt_row, geometry.col, width, 1, title)
    local is_ok, prompt_win_or_err = pcall(open_floating_window_or_cleanup, prompt_buf, prompt_config, true)
    if not is_ok then
        M.close_handle(results_win, results_buf)
        error(prompt_win_or_err)
    end
    vim.api.nvim_set_option_value("cursorline", false, { win = prompt_win_or_err, scope = "local" })
    vim.api.nvim_set_option_value("wrap", false, { win = prompt_win_or_err, scope = "local" })
    M.paint_palette_prompt_decorations(prompt_buf, true)
    return prompt_buf, prompt_win_or_err, results_buf, results_win
end

--- Repaints the palette results buffer and repositions both stacked floating windows.
--- @param results_buf integer
--- @param results_win integer
--- @param prompt_win integer
--- @param layout table
--- @param width integer
function M.paint_palette_results(results_buf, results_win, prompt_win, layout, width)
    if not results_buf or not vim.api.nvim_buf_is_valid(results_buf) then
        return
    end
    apply_layout_to_buffer(results_buf, layout)
    local geometry = create_palette_stack_geometry(#layout.lines, width)
    if prompt_win and vim.api.nvim_win_is_valid(prompt_win) then
        pcall(vim.api.nvim_win_set_config, prompt_win, {
            relative = "editor",
            row = geometry.prompt_row,
            col = geometry.col,
            width = width,
            height = 1,
        })
    end
    if results_win and vim.api.nvim_win_is_valid(results_win) then
        pcall(vim.api.nvim_win_set_config, results_win, {
            relative = "editor",
            row = geometry.results_row,
            col = geometry.col,
            width = width,
            height = geometry.results_height,
        })
        local cursor_line = math.max(1, math.min(layout.cursor_line or 1, math.max(1, #layout.lines)))
        pcall(vim.api.nvim_win_set_cursor, results_win, { cursor_line, 0 })
    end
end

return M
