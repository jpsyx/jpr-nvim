-- Anchored inline floating input box for sidebar rename (`r`) and create (`a`)
-- with live path-resolution hints, inline validation errors, and LSP file ops.
local lsp_files = require("jpr.lsp_files")
local panel_paths = require("jpr.views.panel_paths")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-panel-input")
local active_state = nil

local function build_title_from_context(context)
    if context.mode == "rename" then
        local prefix = context.is_directory and " Rename dir · " or " Rename · "
        return ("%s%s "):format(prefix, tostring(context.initial_text or ""))
    end
    return " New file or dir (trailing / for dir) "
end

local function compute_anchor_geometry(panel_win)
    local cursor_line = vim.api.nvim_win_get_cursor(panel_win)[1]
    local topline = vim.api.nvim_win_call(panel_win, function()
        return vim.fn.line("w0")
    end)
    local win_height = vim.api.nvim_win_get_height(panel_win)
    local panel_width = vim.api.nvim_win_get_width(panel_win)
    local rel_row = cursor_line - topline
    local anchor_row = (rel_row + 1 >= win_height) and math.max(0, rel_row - 1) or (rel_row + 1)
    local max_width = math.max(20, vim.o.columns - 4)
    local width = math.min(math.max(panel_width, 46), max_width)
    return { row = anchor_row, col = 0, width = width }
end

local function create_virt_lines_from_input(raw_input, context, explicit_error)
    if type(explicit_error) == "string" and explicit_error ~= "" then
        return { { { explicit_error, "JprError" } } }
    end
    if vim.trim(raw_input or "") == "" then
        if context.mode == "create" then
            local base = (context.current_dir or "") ~= "" and (context.current_dir .. "/") or "project root"
            return { { { ("Base: %s (use path/ for project root)"):format(base), "JprMuted" } } }
        end
        return { { { "Enter a new name or path", "JprMuted" } } }
    end
    local resolved = panel_paths.resolve_input_from_context(raw_input, context)
    if not resolved.ok then
        return { { { resolved.error, "JprError" } } }
    end
    local hl_group = resolved.mode == "project_root" and "JprHunk" or "JprMuted"
    return { { { resolved.hint, hl_group } } }
end

local function paint_virt_lines(state, explicit_error)
    if not state or not vim.api.nvim_buf_is_valid(state.buf) or not vim.api.nvim_win_is_valid(state.win) then
        return
    end
    local raw_input = vim.api.nvim_buf_get_lines(state.buf, 0, 1, false)[1] or ""
    local virt_lines = create_virt_lines_from_input(raw_input, state.context, explicit_error)
    vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
    vim.api.nvim_buf_set_extmark(state.buf, namespace, 0, 0, {
        virt_lines = virt_lines,
        virt_lines_above = false,
    })
    if vim.api.nvim_win_is_valid(state.anchor_win) then
        pcall(vim.api.nvim_win_set_config, state.win, {
            relative = "win",
            win = state.anchor_win,
            row = state.geometry.row,
            col = state.geometry.col,
            width = state.geometry.width,
            height = 1 + #virt_lines,
        })
    end
end

local function ensure_insert_mode(state)
    vim.schedule(function()
        if active_state ~= state or not vim.api.nvim_win_is_valid(state.win) then
            return
        end
        if vim.api.nvim_get_current_win() ~= state.win then
            return
        end
        pcall(vim.cmd, "startinsert!")
    end)
end

local function register_autocmds(state)
    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
        buffer = state.buf,
        callback = function()
            if active_state == state then
                paint_virt_lines(state, nil)
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = state.buf,
        once = true,
        callback = function()
            if active_state == state then
                M.close(false)
            end
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(state.win),
        once = true,
        callback = function()
            if active_state == state then
                M.close(false)
            end
        end,
    })
end

local function bind_input_keys(state, on_confirm)
    local map_opts = { buffer = state.buf, nowait = true, silent = true }
    local submit = function()
        if active_state ~= state or not vim.api.nvim_buf_is_valid(state.buf) then
            return
        end
        local raw_input = vim.api.nvim_buf_get_lines(state.buf, 0, 1, false)[1] or ""
        local resolved = panel_paths.resolve_input_from_context(raw_input, state.context)
        if not resolved.ok then
            paint_virt_lines(state, resolved.error)
            return
        end
        M.close(true)
        if type(on_confirm) == "function" then
            on_confirm(resolved)
        end
    end
    vim.keymap.set({ "i", "n" }, "<CR>", submit, map_opts)
    for _, lhs in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", lhs, function()
            M.close(true)
        end, map_opts)
    end
end

--- Returns whether the anchored panel input float is currently open.
--- @return boolean
function M.is_open()
    return active_state ~= nil
        and vim.api.nvim_win_is_valid(active_state.win)
        and vim.api.nvim_buf_is_valid(active_state.buf)
end

--- Closes the active panel input float cleanly, optionally restoring panel focus.
--- @param restore_focus boolean|nil
function M.close(restore_focus)
    local state = active_state
    active_state = nil
    if not state then
        return
    end
    pcall(vim.cmd, "stopinsert")
    if state.win and vim.api.nvim_win_is_valid(state.win) then
        pcall(vim.api.nvim_win_close, state.win, true)
    end
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
    end
    if restore_focus and state.anchor_win and vim.api.nvim_win_is_valid(state.anchor_win) then
        pcall(vim.api.nvim_set_current_win, state.anchor_win)
    end
end

local function create_input_buffer(initial_text)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "jpr-panel-input"
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { initial_text })
    return buf
end

local function open_input_window(panel_win, buf, context, geometry, initial_text)
    local win_config = {
        relative = "win",
        win = panel_win,
        row = geometry.row,
        col = geometry.col,
        width = geometry.width,
        height = 2,
        style = "minimal",
        border = "rounded",
        title = build_title_from_context(context),
        title_pos = "left",
    }
    local is_opened, win_or_err = pcall(vim.api.nvim_open_win, buf, true, win_config)
    if not is_opened then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        error(win_or_err)
    end
    vim.api.nvim_set_option_value("wrap", false, { win = win_or_err, scope = "local" })
    vim.api.nvim_set_option_value("cursorline", false, { win = win_or_err, scope = "local" })
    pcall(vim.api.nvim_win_set_cursor, win_or_err, { 1, math.max(0, #initial_text) })
    return win_or_err
end

--- Opens a rounded floating input anchored below the hovered row in `session.panel.win`.
--- @param session table
--- @param context table
--- @param on_confirm fun(resolved: table)
function M.open(session, context, on_confirm)
    local panel = session and session.panel
    if not panel or not vim.api.nvim_win_is_valid(panel.win) then
        return
    end
    require("jpr").define_highlights()
    M.close(false)

    local initial_text = tostring(context.initial_text or "")
    local buf = create_input_buffer(initial_text)
    local geometry = compute_anchor_geometry(panel.win)
    local win = open_input_window(panel.win, buf, context, geometry, initial_text)

    local state = { buf = buf, win = win, anchor_win = panel.win, geometry = geometry, context = context }
    active_state = state
    paint_virt_lines(state, nil)
    register_autocmds(state)
    bind_input_keys(state, on_confirm)
    ensure_insert_mode(state)
end

--- Starts the inline rename/move workflow for the file or directory row under the panel cursor.
--- @param session table
function M.start_rename(session)
    local session_mod = require("jpr.session")
    if session.is_read_only then
        return session_mod.report_read_only(session)
    end
    local row_info = require("jpr.views.panel").get_row_under_cursor(session)
    if not row_info or (row_info.row.kind ~= "file" and row_info.row.kind ~= "dir") then
        return
    end
    local context = panel_paths.create_rename_context_from_row(session.worktree, row_info.row)
    M.open(session, context, function(resolved)
        local old_abs = session.worktree .. "/" .. context.target_path
        lsp_files.rename(old_abs, resolved.absolute_path, {}, function(is_ok, err)
            if not is_ok then
                if err and err ~= "Rename cancelled by user" then
                    require("jpr").error(err)
                end
                return
            end
            session_mod.refresh_worktree(session, {
                { oldPath = context.target_path, newPath = resolved.relative_path },
            })
        end)
    end)
end

--- Starts the inline file or directory creation workflow anchored under the panel cursor.
--- @param session table
function M.start_create(session)
    local session_mod = require("jpr.session")
    if session.is_read_only then
        return session_mod.report_read_only(session)
    end
    local row_info = require("jpr.views.panel").get_row_under_cursor(session)
    local context = panel_paths.create_create_context_from_row(session.worktree, row_info and row_info.row or nil)
    M.open(session, context, function(resolved)
        lsp_files.create(resolved.absolute_path, resolved.is_directory, {}, function(is_ok, err)
            if not is_ok then
                if err then
                    require("jpr").error(err)
                end
                return
            end
            session_mod.refresh_worktree(session, nil)
            if resolved.is_directory then
                return require("jpr").info(("Created directory %s"):format(resolved.relative_path))
            end
            local main_window = require("jpr.views.main_window")
            main_window.edit(session, main_window.find(session), resolved.relative_path)
        end)
    end)
end

return M
