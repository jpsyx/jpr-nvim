-- Changed files shown as diffs: extmark overlays on the file itself
-- (unified), or Neovim's diff mode beside a read-only base buffer (split).
-- The engine computes every diff; this only draws it and manages the base
-- windows.
local diff_threads = require("jpr.views.diff.threads")
local overlay = require("jpr.render.overlay")
local view_mode = require("jpr.view_mode")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-diff")

--- Whether `record` is still what `win` should draw: the session lives and
--- the window still shows the buffer the request was made for.
local function is_current(session, win, record)
    return session.diff ~= nil
        and session.diff.applied[win] == record
        and vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_buf(win) == record.buf
end

--- Gives up on `win`'s diff after the `fileDiff` for `path` failed: the
--- window is no longer marked drawn, and `path` is not asked for again until
--- `redraw_all` (a toggle or moved commits), so a lasting error does not send
--- a request on every BufEnter. A stale request's failure changes nothing.
local function give_up(session, win, record, path)
    if is_current(session, win, record) then
        session.diff.applied[win] = nil
        session.diff.failed[path] = true
    end
end

--- Shows the file in `win` as a diff in the current mode, unless it already
--- does or its last `fileDiff` failed.
function M.apply(session, win)
    local buf = vim.api.nvim_win_get_buf(win)
    local path = M.buffer_to_changed_path(session, buf)
    local mode = view_mode.get()
    local applied = session.diff.applied[win]
    local is_drawn = applied and applied.buf == buf and applied.mode == mode
    if not path or not session.client or is_drawn or session.diff.failed[path] then
        return
    end
    local record = { buf = buf, mode = mode }
    session.diff.applied[win] = record
    require("jpr.session").request(session, "fileDiff", { path = path }, function(diff)
        if not is_current(session, win, record) then
            return
        end
        if type(diff) ~= "table" then
            give_up(session, win, record, path)
            return require("jpr").error(("the engine sent no diff for %s"):format(path))
        end
        if diff.binary then
            return require("jpr").info(("%s is a binary file; it has no diff"):format(path))
        end
        require("jpr").bind_buffer_keys(buf)
        if mode == "unified" then
            M.draw_overlay(buf, diff, win)
            diff_threads.draw_unified_threads(session, win, buf, diff)
        else
            M.open_base(session, win, buf, diff)
        end
    end, function()
        give_up(session, win, record, path)
    end)
end

--- How many removed lines `marks` draw above the buffer's first line.
local function count_lines_above_first(marks)
    local count = 0
    for _, mark in ipairs(marks) do
        if mark.line == 0 and mark.opts.virt_lines_above then
            count = count + #mark.opts.virt_lines
        end
    end
    return count
end

--- Scrolls every window showing the top of `buf` up to the `count` virtual
--- lines above its first line, which Neovim otherwise keeps hidden until the
--- user scrolls up (a deleted header, or all of a deleted file).
local function reveal_lines_above_first(buf, count)
    if count == 0 then
        return
    end
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.api.nvim_win_call(win, function()
            local view = vim.fn.winsaveview()
            if view.topline == 1 then
                view.topfill = count
                vim.fn.winrestview(view)
            end
        end)
    end
end

--- Draws `diff` on `buf` as extmarks: added lines, changed words, and the
--- removed lines as virtual lines.
function M.draw_overlay(buf, diff, win)
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    local opts = { width = vim.api.nvim_win_get_width(win), tabstop = vim.bo[buf].tabstop }
    local marks = overlay.create_extmarks_from_diff(diff, vim.api.nvim_buf_line_count(buf), opts)
    for _, mark in ipairs(marks) do
        -- A buffer edited since its last save can be shorter than the diff.
        local mark_opts = vim.tbl_extend("force", mark.opts, { strict = false })
        pcall(vim.api.nvim_buf_set_extmark, buf, namespace, mark.line, mark.col, mark_opts)
    end
    reveal_lines_above_first(buf, count_lines_above_first(marks))
end

--- Opens `diff`'s base in a read-only window left of `win`, and turns on
--- diff mode in both.
function M.open_base(session, win, buf, diff)
    local base_buf = vim.api.nvim_create_buf(false, true)
    -- A second window on the same file makes a second base; the name is only
    -- for display, so a clash is harmless.
    pcall(vim.api.nvim_buf_set_name, base_buf, ("jpr://base/%d/%s"):format(session.number, diff.path))
    vim.api.nvim_buf_set_lines(base_buf, 0, -1, false, overlay.text_to_lines(diff.baseText))
    vim.bo[base_buf].bufhidden = "wipe"
    vim.bo[base_buf].modifiable = false
    vim.bo[base_buf].filetype = vim.bo[buf].filetype
    vim.b[base_buf].jpr_base_path = diff.path
    require("jpr").bind_buffer_keys(base_buf)
    local base_win = vim.api.nvim_open_win(base_buf, false, { split = "left", win = win })
    vim.w[base_win].jpr_side = true
    session.diff.splits[win] = { base_win = base_win, base_buf = base_buf }
    for _, diff_win in ipairs({ base_win, win }) do
        vim.api.nvim_win_call(diff_win, function()
            vim.cmd("diffthis")
        end)
    end
    diff_threads.draw_split_threads(session, base_win, win, base_buf, buf, diff)
end

--- Whether some window still has a diff drawn for `buf`.
local function is_buffer_drawn(session, buf)
    for _, applied in pairs(session.diff.applied) do
        if applied.buf == buf then
            return true
        end
    end
    return false
end

--- Stops showing `win`'s file as a diff: clears the overlay (unless another
--- window still shows it: extmarks belong to the buffer), closes the base
--- window and turns diff mode off.
function M.clear(session, win)
    if not session.diff then
        return
    end
    local threads = require("jpr.views.threads")
    local applied = session.diff.applied[win]
    session.diff.applied[win] = nil
    diff_threads.set_window_signcolumn(session, win, false)
    session.diff.saved_signcolumn[win] = nil
    if applied and not is_buffer_drawn(session, applied.buf) then
        if vim.api.nvim_buf_is_valid(applied.buf) then
            vim.api.nvim_buf_clear_namespace(applied.buf, namespace, 0, -1)
        end
        threads.clear_buffer(session, applied.buf)
    end
    local base_split = session.diff.splits[win]
    session.diff.splits[win] = nil
    if not base_split then
        return
    end
    if base_split.base_buf then
        threads.clear_buffer(session, base_split.base_buf)
    end
    diff_threads.set_window_signcolumn(session, base_split.base_win, false)
    session.diff.saved_signcolumn[base_split.base_win] = nil
    if vim.api.nvim_win_is_valid(base_split.base_win) then
        pcall(vim.api.nvim_win_close, base_split.base_win, true)
    end
    if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_call(win, function()
            vim.cmd("diffoff")
        end)
    end
end

--- Brings every window of `session`'s tab in line: one that no longer shows
--- the buffer it was drawn for is cleared, and one showing a changed file
--- gets its diff.
function M.reconcile(session)
    if not session.diff then
        return
    end
    for win, applied in pairs(session.diff.applied) do
        if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= applied.buf then
            M.clear(session, win)
        end
    end
    if not vim.api.nvim_tabpage_is_valid(session.tab) then
        return
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
        M.apply(session, win)
    end
end

--- Draws every diff of `session`'s tab again, for a new view mode or new
--- commits.
function M.redraw_all(session)
    if not session.diff then
        return
    end
    -- Clearing a field while traversing is allowed; adding one is not, so
    -- the redraw happens after the loop.
    for win in pairs(session.diff.applied) do
        M.clear(session, win)
    end
    -- A new mode or new commits is worth asking again for a failed diff.
    session.diff.failed = {}
    M.reconcile(session)
end

--- Redraws `buf`'s unified overlays after a save changed it on disk.
function M.refresh_buffer(session, buf)
    local windows = {}
    for win, applied in pairs(session.diff.applied) do
        if applied.buf == buf and applied.mode == "unified" then
            windows[#windows + 1] = win
        end
    end
    for _, win in ipairs(windows) do
        -- A window closed while another tab was current was never
        -- reconciled, so clearing it here drops it.
        M.clear(session, win)
        if vim.api.nvim_win_is_valid(win) then
            M.apply(session, win)
        end
    end
end

local function handle_buf_write(session, buf)
    local path = session.diff and M.buffer_to_changed_path(session, buf)
    if not path then
        return
    end
    local function refresh_after_write()
        if session.closing or not session.diff then
            return
        end
        if vim.api.nvim_buf_is_valid(buf) then
            M.refresh_buffer(session, buf)
        end
        require("jpr.views.stream").refresh(session, true)
    end
    local updates = require("jpr.views.threads").collect_shifted_local_anchors(session, buf)
    if #updates > 0 and session.client then
        require("jpr.session").request(session, "updateLocalAnchors", {
            path = path,
            updates = updates,
        }, refresh_after_write, refresh_after_write)
        return
    end
    refresh_after_write()
end

--- Keeps `session`'s windows drawn as diffs for as long as it lives.
function M.attach(session)
    local group = vim.api.nvim_create_augroup(("jpr-diff-%d"):format(session.tab), { clear = true })
    -- applied: window to the { buf, mode } it is drawn for; splits: window
    -- to its base window; failed: paths whose fileDiff failed.
    session.diff = { applied = {}, splits = {}, failed = {}, saved_signcolumn = {}, group = group }
    vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinClosed" }, {
        group = group,
        callback = function()
            vim.schedule(function()
                if session.diff and vim.api.nvim_get_current_tabpage() == session.tab then
                    M.reconcile(session)
                end
            end)
        end,
    })
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        callback = function(event)
            handle_buf_write(session, event.buf)
        end,
    })
end

--- Clears every diff of `session` and stops following its windows.
function M.detach(session)
    if not session.diff then
        return
    end
    pcall(vim.api.nvim_del_augroup_by_id, session.diff.group)
    for win in pairs(session.diff.applied) do
        M.clear(session, win)
    end
    session.diff = nil
end

require("jpr.views.diff.paths").attach(M)
diff_threads.attach(M, is_current)

return M
