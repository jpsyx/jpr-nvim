-- Cursor clamping, row selection, collapse-state parsing, and post-viewed
-- advancement for the PR sidebar panel.
local render = require("jpr.render.panel")

local M = {}

--- Moves the panel window cursor to 1-based `target_line` without re-triggering clamping.
function M.set_cursor_line(panel, target_line)
    if not panel or not vim.api.nvim_win_is_valid(panel.win) or not target_line then
        return
    end
    panel.is_clamping = true
    pcall(vim.api.nvim_win_set_cursor, panel.win, { target_line, 0 })
    panel.is_clamping = false
end

--- Finds the nearest selectable line in `selectable_lines` to 1-based `line`.
function M.find_nearest_selectable_line(selectable_lines, line)
    local total = #(selectable_lines or {})
    if total == 0 then
        return nil
    end
    if line <= selectable_lines[1] then
        return selectable_lines[1]
    end
    if line >= selectable_lines[total] then
        return selectable_lines[total]
    end
    for _, candidate in ipairs(selectable_lines) do
        if candidate >= line then
            return candidate
        end
    end
    return selectable_lines[total]
end

--- Clamps `panel`'s cursor onto a selectable row at column 0.
function M.clamp_cursor(panel)
    if not panel or panel.is_clamping or not vim.api.nvim_win_is_valid(panel.win) then
        return
    end
    if vim.api.nvim_win_get_buf(panel.win) ~= panel.buf or #(panel.selectable_lines or {}) == 0 then
        return
    end
    local cursor = vim.api.nvim_win_get_cursor(panel.win)
    local target_line = panel.rows[cursor[1]] ~= nil and cursor[1]
        or M.find_nearest_selectable_line(panel.selectable_lines, cursor[1])
    if target_line and (target_line ~= cursor[1] or cursor[2] ~= 0) then
        M.set_cursor_line(panel, target_line)
    end
end

--- Returns the 1-based index of `line` in `selectable_lines`, or nil.
function M.find_selectable_index(selectable_lines, line)
    for index, candidate in ipairs(selectable_lines) do
        if candidate == line then
            return index
        end
    end
    return nil
end

--- Moves the panel selection by `delta` selectable rows.
function M.move_selection(session, delta)
    local panel = session.panel
    local selectable_lines = panel and panel.selectable_lines or {}
    if #selectable_lines == 0 or not vim.api.nvim_win_is_valid(panel.win) then
        return
    end
    local cursor_line = vim.api.nvim_win_get_cursor(panel.win)[1]
    local current_index = M.find_selectable_index(selectable_lines, cursor_line)
    if not current_index then
        return M.set_cursor_line(panel, M.find_nearest_selectable_line(selectable_lines, cursor_line))
    end
    local target_index = math.max(1, math.min(#selectable_lines, current_index + delta))
    M.set_cursor_line(panel, selectable_lines[target_index])
end

--- Jumps the panel selection to the first (`is_last == false`) or last selectable row.
function M.jump_selection(session, is_last)
    local panel = session.panel
    local selectable_lines = panel and panel.selectable_lines or {}
    if #selectable_lines == 0 then
        return
    end
    M.set_cursor_line(panel, is_last and selectable_lines[#selectable_lines] or selectable_lines[1])
end

--- Finds the 1-based line number of directory `dir_path` in `panel`, or nil.
function M.find_dir_line(panel, dir_path)
    for _, line in ipairs(panel.selectable_lines or {}) do
        local row = panel.rows[line]
        if row and row.kind == "dir" and row.path == dir_path then
            return line
        end
    end
    return nil
end

--- Collapse set from `view.collapsedDirs`. A missing value or a non-array means nothing is collapsed.
function M.collapsed_set_from_view(view)
    local set = {}
    local paths = type(view) == "table" and view.collapsedDirs or nil
    if type(paths) ~= "table" or (vim.islist and not vim.islist(paths)) then
        return set
    end
    for _, path in ipairs(paths) do
        if type(path) == "string" then
            set[path] = true
        end
    end
    return set
end

--- Finds the target cursor line in `built` that best preserves `prev_row` / `prev_line`.
function M.find_preserved_cursor_line(built, prev_row, prev_line)
    if #(built.selectable_lines or {}) == 0 then
        return nil
    end
    if not prev_row then
        return built.summary_line or built.conversation_line or built.selectable_lines[1]
    end
    if prev_row.kind == "summary" then
        return built.summary_line or built.selectable_lines[1]
    end
    if prev_row.kind == "conversation" then
        return built.conversation_line or built.selectable_lines[1]
    end
    if prev_row.path then
        local fallback_line = nil
        for _, line in ipairs(built.selectable_lines) do
            local row = built.rows[line]
            if row and row.path == prev_row.path then
                if row.kind == prev_row.kind then
                    return line
                end
                fallback_line = fallback_line or line
            end
        end
        if fallback_line then
            return fallback_line
        end
    end
    return M.find_nearest_selectable_line(built.selectable_lines, prev_line or built.selectable_lines[1])
end

local function get_window_changed_path(session, win)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return nil
    end
    local buf = vim.api.nvim_win_get_buf(win)
    local base_path = vim.b[buf].jpr_base_path
    if type(base_path) == "string" and base_path ~= "" then
        return base_path
    end
    return require("jpr.views.diff").buffer_to_changed_path(session, buf)
end

--- Advances an already-open main window to the next unviewed file (or the full
--- branch diff when all files are viewed) when it is showing one of
--- `marked_paths` and the full diff stream is not already visible. A closed
--- editor stays closed: marking viewed never opens a window.
function M.advance_after_viewed(session, updated_view, marked_paths, opts)
    if session.closing or not vim.api.nvim_tabpage_is_valid(session.tab) then
        return
    end
    local stream = require("jpr.views.stream")
    if stream.is_visible(session) then
        return
    end
    local main_window = require("jpr.views.main_window")
    local main_win = main_window.find_existing(session)
    if not main_win then
        return
    end
    local open_path = get_window_changed_path(session, main_win)
    if not open_path or not vim.tbl_contains(marked_paths or {}, open_path) then
        return
    end
    local should_focus_next = type(opts) == "table" and opts.focus_next == true
    local previous_win = vim.api.nvim_get_current_win()
    local next_path = render.find_next_unviewed_path(updated_view or session.view or {}, open_path)
    if next_path then
        main_window.edit(session, main_win, next_path, 1)
        if not should_focus_next and vim.api.nvim_win_is_valid(previous_win) then
            vim.api.nvim_set_current_win(previous_win)
        end
        return
    end
    stream.show(session, { focus = should_focus_next })
    require("jpr").info("all files viewed")
end

return M
