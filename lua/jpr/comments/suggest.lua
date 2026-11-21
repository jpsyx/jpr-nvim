-- `:Jpr suggest`: turns the reviewer's edit at the cursor line into a
-- GitHub `suggestion` draft comment and reverts just that hunk in the buffer
-- (and on disk when the buffer was already saved).
local diff_view = require("jpr.views.diff")
local view_mode = require("jpr.view_mode")

local M = {}

local function read_disk_bytes(full_path)
    local handle = io.open(full_path, "rb")
    if not handle then
        return nil
    end
    local content = handle:read("*a")
    handle:close()
    return content
end

local function write_reverted_text(buf, full_path, reverted_text, was_modified)
    local has_trailing_nl = reverted_text:sub(-1) == "\n"
    local body = has_trailing_nl and reverted_text:sub(1, -2) or reverted_text
    local lines = vim.split(body, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].eol = has_trailing_nl
    if not was_modified then
        if has_trailing_nl then
            vim.fn.writefile(lines, full_path)
        else
            vim.fn.writefile(lines, full_path, "b")
        end
    end
    local disk_bytes = read_disk_bytes(full_path)
    vim.bo[buf].modified = (disk_bytes ~= reverted_text)
end

local function refresh_diff_views(session, buf)
    diff_view.refresh_buffer(session, buf)
    if view_mode.get() == "split" then
        diff_view.redraw_threads(session)
    end
    require("jpr.views.stream").refresh(session, true)
end

--- Turns the local edit at the cursor line in the active changed worktree
--- buffer into a GitHub draft suggestion and reverts only that hunk.
function M.run(session)
    if not session or session.closing then
        return
    end
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local path = diff_view.buffer_to_changed_path(session, buf)
    if not path then
        return require("jpr").error(":Jpr suggest must be run inside a changed worktree file")
    end
    local initial_tick = vim.api.nvim_buf_get_changedtick(buf)
    local was_modified = vim.bo[buf].modified
    local eol = vim.bo[buf].eol
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
    local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local edited_text = table.concat(buf_lines, "\n") .. (eol and "\n" or "")
    local full_path = vim.api.nvim_buf_get_name(buf)
    require("jpr.session").request(session, "suggestFromEdit", {
        path = path,
        editedText = edited_text,
        cursorLine = cursor_line,
    }, function(result)
        if session.closing or not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        if vim.api.nvim_buf_get_changedtick(buf) ~= initial_tick then
            return
        end
        if not result or not result.suggested or type(result.suggested.revertedText) ~= "string" then
            return
        end
        write_reverted_text(buf, full_path, result.suggested.revertedText, was_modified)
        refresh_diff_views(session, buf)
        require("jpr").info(("created suggestion draft on %s"):format(path))
    end)
end

return M
