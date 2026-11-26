-- Pure mouse hit-testing, footer action span parsing, and thin Neovim click
-- helpers shared across jpr-nvim's interactive buffers and floating modals.
local M = {}

--- Whether `mouse` (from `vim.fn.getmousepos()`) landed inside `win` on a valid line.
--- @param mouse table|nil
--- @param win integer|nil
--- @return boolean
function M.is_click_in_window(mouse, win)
    return type(mouse) == "table"
        and win ~= nil
        and mouse.winid == win
        and type(mouse.line) == "number"
        and mouse.line >= 1
end

--- Finds literal `{ token, action }` spans on `line_text`, returning 1-based
--- inclusive `{ action, col_start, col_end }` byte-column entries.
--- @param line_text string|nil
--- @param specs { token: string, action: string }[]
--- @return { action: string, col_start: integer, col_end: integer }[]
function M.parse_footer_actions(line_text, specs)
    if type(line_text) ~= "string" or type(specs) ~= "table" then
        return {}
    end
    local spans = {}
    for _, spec in ipairs(specs) do
        if type(spec) == "table" and type(spec.token) == "string" and spec.token ~= "" then
            local col_start, col_end = line_text:find(spec.token, 1, true)
            if col_start and col_end then
                spans[#spans + 1] = {
                    action = spec.action,
                    col_start = col_start,
                    col_end = col_end,
                }
            end
        end
    end
    return spans
end

--- Returns the matched action id when `(line, col)` hits a parsed span on `footer_line`.
--- @param footer_line integer|nil
--- @param spans { action: string, col_start: integer, col_end: integer }[]|nil
--- @param line integer|nil
--- @param col integer|nil
--- @return string|nil
function M.hit_test_footer_action(footer_line, spans, line, col)
    if type(footer_line) ~= "number" or line ~= footer_line or type(col) ~= "number" or col < 1 then
        return nil
    end
    for _, span in ipairs(spans or {}) do
        if col >= span.col_start and col <= span.col_end then
            return span.action
        end
    end
    return nil
end

--- Returns the matched action id when `click` hits a parsed footer token on
--- `footer_line` (defaulting to `#lines`, the last rendered line), or `nil`.
--- @param lines string[]|nil
--- @param specs { token: string, action: string }[]
--- @param click table|nil
--- @param footer_line integer|nil
--- @return string|nil
function M.hit_test_footer_line(lines, specs, click, footer_line)
    if type(lines) ~= "table" or #lines == 0 or type(click) ~= "table" then
        return nil
    end
    local target_line = type(footer_line) == "number" and footer_line or #lines
    if click.line ~= target_line then
        return nil
    end
    local spans = M.parse_footer_actions(lines[target_line], specs)
    return M.hit_test_footer_action(target_line, spans, click.line, click.column)
end

--- Safely reads `vim.fn.getmousepos()`, returning the table or `nil`.
--- @return table|nil
function M.get_click()
    local is_ok, position = pcall(vim.fn.getmousepos)
    if is_ok and type(position) == "table" then
        return position
    end
    return nil
end

--- Forwards a mouse key (default `"<LeftMouse>"`) natively without remapping so
--- clicks outside a split window still focus other windows or drag borders.
--- @param key string|nil
function M.passthrough(key)
    vim.api.nvim_feedkeys(vim.keycode(key or "<LeftMouse>"), "n", false)
end

--- Moves `win`'s cursor to the clicked 1-based line and column, clamped to buffer bounds.
--- @param win integer|nil
--- @param mouse table|nil
function M.set_cursor_from_click(win, mouse)
    if not win or not vim.api.nvim_win_is_valid(win) or type(mouse) ~= "table" then
        return
    end
    local buf = vim.api.nvim_win_get_buf(win)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local line_count = math.max(1, vim.api.nvim_buf_line_count(buf))
    local target_line = math.max(1, math.min(tonumber(mouse.line) or 1, line_count))
    local line_text = vim.api.nvim_buf_get_lines(buf, target_line - 1, target_line, false)[1] or ""
    local max_col = math.max(0, #line_text - 1)
    local target_col = math.max(0, math.min((tonumber(mouse.column) or 1) - 1, max_col))
    pcall(vim.api.nvim_win_set_cursor, win, { target_line, target_col })
end

return M
