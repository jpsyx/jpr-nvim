-- Shared Neovim headless spec helpers for key simulation, fake-engine JSONL
-- inspection, buffer keymap checks, and observable floating-window lookup.
local M = {}

--- Feeds `lhs` through Neovim's keymap translation in synchronous test mode.
function M.press_key(lhs)
    local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    vim.api.nvim_feedkeys(keys, "xt", false)
end

--- Decodes JSON-RPC requests matching `method_name` from `log_path`.
function M.read_requests(log_path, method_name)
    if vim.fn.filereadable(log_path) == 0 then
        return {}
    end
    local matches = {}
    for _, line in ipairs(vim.fn.readfile(log_path)) do
        local ok, decoded = pcall(vim.json.decode, line)
        if ok and type(decoded) == "table" and decoded.method == method_name then
            matches[#matches + 1] = decoded
        end
    end
    return matches
end

--- Counts lines in `log_path` containing every substring passed in `...`.
function M.count_requests(log_path, ...)
    local needles, num_matches = { ... }, 0
    if vim.fn.filereadable(log_path) == 0 then
        return 0
    end
    for _, line in ipairs(vim.fn.readfile(log_path)) do
        local has_all = true
        for _, needle in ipairs(needles) do
            has_all = has_all and line:find(needle, 1, true) ~= nil
        end
        num_matches = num_matches + (has_all and 1 or 0)
    end
    return num_matches
end

--- Whether buffer `buf` defines a buffer-local mapping for `lhs` in `mode`.
function M.has_buf_map(buf, mode, lhs)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        if mapping.lhs == lhs then
            return true
        end
    end
    return false
end

--- Flattens `win`'s floating window title into a plain string.
function M.win_title(win)
    local title = vim.api.nvim_win_get_config(win).title
    if type(title) == "string" then
        return title
    end
    if type(title) == "table" then
        local parts = {}
        for _, chunk in ipairs(title) do
            parts[#parts + 1] = chunk[1]
        end
        return table.concat(parts)
    end
    return ""
end

--- Finds an open floating window whose title contains `title_substring` (or any
--- floating window when `title_substring` is nil).
function M.find_floating_win(title_substring)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) then
            local window_config = vim.api.nvim_win_get_config(win)
            if window_config.relative and window_config.relative ~= "" then
                if not title_substring or M.win_title(win):find(title_substring, 1, true) ~= nil then
                    return win
                end
            end
        end
    end
    return nil
end

--- Returns the current window after asserting it is a floating window.
function M.current_float_win()
    local win = vim.api.nvim_get_current_win()
    local config = vim.api.nvim_win_get_config(win)
    assert(config.relative and config.relative ~= "", "expected current window to be a floating window")
    return win
end

--- Returns all buffer lines of the currently focused floating window.
function M.current_lines()
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(M.current_float_win()), 0, -1, false)
end

--- Returns the newline-joined buffer text of the currently focused floating window.
function M.current_text()
    return table.concat(M.current_lines(), "\n")
end

--- Finds the open floating `jpr-tui` results window (falling back to the current float).
function M.palette_results_win()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) then
            local config = vim.api.nvim_win_get_config(win)
            if config.relative and config.relative ~= "" then
                local buf = vim.api.nvim_win_get_buf(win)
                if vim.bo[buf].filetype == "jpr-tui" then
                    return win
                end
            end
        end
    end
    return M.current_float_win()
end

--- Returns all buffer lines of the active palette results floating window.
function M.palette_results_lines()
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(M.palette_results_win()), 0, -1, false)
end

--- Returns the newline-joined buffer text of the active palette results floating window.
function M.palette_results_text()
    return table.concat(M.palette_results_lines(), "\n")
end

--- Finds the 1-based line number of the first line containing `needle`.
function M.find_line_number(lines, needle)
    for idx, line in ipairs(lines) do
        if line:find(needle, 1, true) then
            return idx
        end
    end
    return nil
end

return M
