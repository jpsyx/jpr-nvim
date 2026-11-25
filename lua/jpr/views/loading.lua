-- Live 4-stage pull-request loading view: shows checkout progress, engine
-- startup, GitHub sync, and per-file diff progress until the stream draws.
local main_window = require("jpr.views.main_window")
local panel_render = require("jpr.render.panel")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-loading")

local STAGES = {
    "Checking out worktree",
    "Starting review engine",
    "Syncing with GitHub",
    "Computing diffs",
}
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local CHECK_ICON = "✓"
local PENDING_ICON = "○"
local STAGE_INDENT = "  "
local DETAIL_INDENT = "     "
local PROGRESS_BAR_WIDTH = 20
local SPINNER_INTERVAL_MS = 100

local function append_line(layout, text, group)
    layout.lines[#layout.lines + 1] = text
    if group then
        layout.highlights[#layout.highlights + 1] = {
            line = #layout.lines - 1,
            col_start = 0,
            col_end = #text,
            group = group,
        }
    end
end

local function append_stage_line(layout, stage_index, label, active_stage, spinner_frame)
    local step_label = ("%d/%d  %s"):format(stage_index, #STAGES, label)
    if stage_index < active_stage then
        local text = STAGE_INDENT .. CHECK_ICON .. "  " .. step_label
        local line = #layout.lines
        layout.lines[line + 1] = text
        layout.highlights[#layout.highlights + 1] = {
            line = line,
            col_start = #STAGE_INDENT,
            col_end = #STAGE_INDENT + #CHECK_ICON,
            group = "JprViewed",
        }
        layout.highlights[#layout.highlights + 1] = {
            line = line,
            col_start = #STAGE_INDENT + #CHECK_ICON,
            col_end = #text,
            group = "JprMuted",
        }
        return
    end
    if stage_index == active_stage then
        local text = STAGE_INDENT .. spinner_frame .. "  " .. step_label .. "..."
        append_line(layout, text, "JprTitle")
        return
    end
    append_line(layout, STAGE_INDENT .. PENDING_ICON .. "  " .. step_label, "JprMuted")
end

local function append_progress_lines(layout, progress)
    if type(progress) ~= "table" then
        return
    end
    local total = math.max(0, math.floor(tonumber(progress.total) or 0))
    if total <= 0 then
        return
    end
    local progress_bar = panel_render.create_progress_bar_from_counts(
        progress.completed or 0,
        total,
        PROGRESS_BAR_WIDTH,
        "files"
    )
    local line = #layout.lines
    layout.lines[line + 1] = DETAIL_INDENT .. progress_bar.text
    panel_render.append_progress_bar_highlights(layout.highlights, line, #DETAIL_INDENT, progress_bar)
    local clean_path = type(progress.path) == "string" and panel_render.one_line(progress.path) or ""
    if clean_path ~= "" then
        append_line(layout, DETAIL_INDENT .. clean_path, "JprMuted")
    end
end

--- Builds the pure lines and highlight ranges for `state`:
--- `{ number, title, stage (1..4), detail, progress = { completed, total, path }, spinner_index }`.
function M.create_layout_from_state(state)
    local safe_state = type(state) == "table" and state or {}
    local pr_number = tonumber(safe_state.number) or 0
    local active_stage = math.max(1, math.min(#STAGES, math.floor(tonumber(safe_state.stage) or 1)))
    local spinner_index = math.max(0, math.floor(tonumber(safe_state.spinner_index) or 0))
    local spinner_frame = SPINNER_FRAMES[(spinner_index % #SPINNER_FRAMES) + 1]
    local layout = { lines = {}, highlights = {} }

    append_line(layout, "")
    local clean_title = type(safe_state.title) == "string" and panel_render.one_line(safe_state.title) or ""
    local header = clean_title ~= "" and (STAGE_INDENT .. ("#%d %s"):format(pr_number, clean_title))
        or (STAGE_INDENT .. ("Pull Request #%d"):format(pr_number))
    append_line(layout, header, "JprTitle")
    append_line(layout, "")

    for stage_index, label in ipairs(STAGES) do
        append_stage_line(layout, stage_index, label, active_stage, spinner_frame)
        if stage_index == 1 and active_stage == 1 then
            local clean_detail = type(safe_state.detail) == "string" and panel_render.one_line(safe_state.detail) or ""
            if clean_detail ~= "" then
                append_line(layout, DETAIL_INDENT .. clean_detail, "JprMuted")
            end
        elseif stage_index == 4 and active_stage == 4 then
            append_progress_lines(layout, safe_state.progress)
        end
    end

    append_line(layout, "")
    append_line(layout, STAGE_INDENT .. "Close this tab or run :Jpr close to cancel.", "JprMuted")
    return layout
end

local function style_window(win)
    local function set_option(name, value)
        vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
    end
    set_option("number", false)
    set_option("relativenumber", false)
    set_option("signcolumn", "no")
    set_option("cursorline", false)
    set_option("wrap", false)
end

local function render_record(record)
    if not record or not vim.api.nvim_buf_is_valid(record.buf) then
        return
    end
    local layout = M.create_layout_from_state(record.state)
    vim.bo[record.buf].modifiable = true
    vim.api.nvim_buf_set_lines(record.buf, 0, -1, false, layout.lines)
    vim.bo[record.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(record.buf, namespace, 0, -1)
    for _, highlight in ipairs(layout.highlights) do
        vim.api.nvim_buf_set_extmark(record.buf, namespace, highlight.line, highlight.col_start, {
            end_col = highlight.col_end,
            hl_group = highlight.group,
            strict = false,
        })
    end
end

local function stop_timer(record)
    local timer = record and record.timer
    if not timer then
        return
    end
    record.timer = nil
    pcall(timer.stop, timer)
    if not timer:is_closing() then
        pcall(timer.close, timer)
    end
end

local function start_spinner_timer(session, record)
    local uv = vim.uv or vim.loop
    if not uv or type(uv.new_timer) ~= "function" then
        return
    end
    local timer = uv.new_timer()
    if not timer then
        return
    end
    record.timer = timer
    timer:start(
        SPINNER_INTERVAL_MS,
        SPINNER_INTERVAL_MS,
        vim.schedule_wrap(function()
            if session.loading ~= record or not vim.api.nvim_buf_is_valid(record.buf) then
                stop_timer(record)
                return
            end
            if #vim.fn.win_findbuf(record.buf) == 0 then
                return
            end
            record.state.spinner_index = (record.state.spinner_index or 0) + 1
            render_record(record)
        end)
    )
end

--- Opens the live loading buffer in the active window for `session` and
--- animates the active stage spinner until updated or closed. Returns the
--- loading buffer handle.
function M.open(session, initial_state)
    if session.loading then
        M.close(session)
    end
    local state = vim.deepcopy(type(initial_state) == "table" and initial_state or {})
    state.number = state.number or session.number
    state.stage = state.stage or 1
    state.spinner_index = state.spinner_index or 0

    local buf = vim.api.nvim_create_buf(false, true)
    local buf_key = state.number and tostring(state.number) or require("jpr.session").buf_key(session)
    pcall(vim.api.nvim_buf_set_name, buf, "jpr://loading/" .. buf_key)
    vim.bo[buf].filetype = "jpr-loading"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false

    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    style_window(win)

    local record = { buf = buf, win = win, state = state, timer = nil }
    session.loading = record
    render_record(record)

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            stop_timer(record)
            if session.loading == record then
                session.loading = nil
            end
        end,
    })
    start_spinner_timer(session, record)
    return buf
end

--- Merges `patch` into `session.loading.state` and re-renders the loading view.
function M.update(session, patch)
    local record = session and session.loading
    if not record or not vim.api.nvim_buf_is_valid(record.buf) or type(patch) ~= "table" then
        return
    end
    for key, value in pairs(patch) do
        record.state[key] = type(value) == "table" and vim.deepcopy(value) or value
    end
    render_record(record)
end

--- Whether `buf` is the active loading buffer belonging to `session`.
function M.is_loading_buffer(session, buf)
    local record = session and session.loading
    return record ~= nil and record.buf == buf and vim.api.nvim_buf_is_valid(buf)
end

--- Stops the spinner timer, wipes the loading buffer cleanly without closing
--- its window, and clears `session.loading`.
function M.close(session)
    local record = session and session.loading
    if not record then
        return
    end
    session.loading = nil
    stop_timer(record)
    if vim.api.nvim_buf_is_valid(record.buf) then
        main_window.release_windows(record.buf)
        if vim.api.nvim_buf_is_valid(record.buf) then
            pcall(vim.api.nvim_buf_delete, record.buf, { force = true })
        end
    end
end

return M
