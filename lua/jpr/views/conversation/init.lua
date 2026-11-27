-- PR conversation view (`:Jpr conversation`): lists top-level PR issue
-- comments (`anchor.kind == "pr"`) in the main window beside the panel.
local actions = require("jpr.views.conversation.actions")
local diff_view = require("jpr.views.diff")
local layout_mod = require("jpr.views.conversation.layout")
local main_window = require("jpr.views.main_window")
local stream_view = require("jpr.views.stream")

local M = {}

local function is_visible(session)
    local state = session and session.conversation
    return state ~= nil
        and state.buf ~= nil
        and vim.api.nvim_buf_is_valid(state.buf)
        and #vim.fn.win_findbuf(state.buf) > 0
end

local function get_or_create_state(session)
    local existing = session.conversation
    if existing and existing.buf and vim.api.nvim_buf_is_valid(existing.buf) then
        return existing
    end
    local buf = vim.api.nvim_create_buf(false, true)
    local buf_key = require("jpr.session").buf_key(session)
    pcall(vim.api.nvim_buf_set_name, buf, "jpr://conversation/" .. buf_key)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading PR conversation..." })
    vim.bo[buf].modifiable = false
    local state = { buf = buf, request_id = 0 }
    session.conversation = state
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            if session.conversation == state then
                session.conversation = nil
            end
        end,
    })
    actions.bind_keys(M, session, buf)
    return state
end

local function scroll_to_target(buf, layout, target)
    if not layout or #(layout.lines or {}) == 0 or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local raw_line = target == "summary" and 1 or (layout.conversation_start_line or 1)
    local target_line = math.max(1, math.min(raw_line, #layout.lines))
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        pcall(vim.api.nvim_win_call, win, function()
            vim.fn.winrestview({ lnum = target_line, col = 0, topline = target_line })
        end)
    end
end

local function fetch_and_draw(session, state)
    state.request_id = (state.request_id or 0) + 1
    local request_id = state.request_id
    local buf = state.buf
    require("jpr.session").request(session, "threads", nil, function(result)
        if session.closing or session.conversation ~= state or state.request_id ~= request_id then
            return
        end
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        local width = 80
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            if vim.api.nvim_win_is_valid(win) then
                width = vim.api.nvim_win_get_width(win)
                break
            end
        end
        local layout = layout_mod.create_layout_from_threads(session, (result and result.threads) or {}, width)
        state.layout = layout
        layout_mod.paint_buffer(buf, layout)
        if state.pending_target then
            local target = state.pending_target
            state.pending_target = nil
            scroll_to_target(buf, layout, target)
        end
    end)
end

local function has_cached_buffer(session)
    local existing = session and session.conversation
    return existing ~= nil and existing.buf ~= nil and vim.api.nvim_buf_is_valid(existing.buf)
end

--- Opens or focuses the unified Diff summary + PR conversation buffer
--- (`jpr://conversation/<buf_key>`) in `session`'s main window beside the panel.
--- `opts.target` selects the initial scroll position: `"summary"` opens at
--- line 1 and `"conversation"` (default) opens at the Conversation heading.
function M.show(session, opts)
    if not session or session.closing then
        return
    end
    if session.is_read_only and not has_cached_buffer(session) then
        return require("jpr.session").report_read_only(session)
    end
    local target = (type(opts) == "table" and opts.target == "summary") and "summary" or "conversation"
    local state = get_or_create_state(session)
    state.pending_target = target
    local main_win = main_window.find(session)
    diff_view.clear(session, main_win)
    stream_view.close_left_window(session)
    vim.api.nvim_win_set_buf(main_win, state.buf)
    vim.api.nvim_set_option_value("wrap", true, { win = main_win, scope = "local" })
    vim.api.nvim_set_option_value("scrollbind", false, { win = main_win, scope = "local" })
    vim.api.nvim_set_option_value("cursorbind", false, { win = main_win, scope = "local" })
    vim.api.nvim_set_current_win(main_win)
    if state.layout then
        scroll_to_target(state.buf, state.layout, target)
    end
    if not session.is_read_only then
        fetch_and_draw(session, state)
    else
        state.pending_target = nil
    end
end

--- Updates the PR conversation buffer when it is currently visible.
function M.refresh(session)
    if not session or session.closing or session.is_read_only or not is_visible(session) then
        return
    end
    fetch_and_draw(session, session.conversation)
end

--- Closes and wipes `session`'s PR conversation buffer, if open.
function M.close(session)
    local state = session and session.conversation
    if not state then
        return
    end
    session.conversation = nil
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        main_window.release_windows(state.buf)
        pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
    end
end

return M
