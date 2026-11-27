-- Top-right color-coded floating toast stack for jpr: red (error), green
-- (success), blue (info / automatic updates), amber (warn), and animated
-- in-progress spinners that transition in place on completion.
local M = {}

local MAX_VISIBLE_TOASTS = 6
local SPINNER_INTERVAL_MS = 80
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local KIND_SPECS = {
    error = {
        title = " jpr · Error ",
        border_hl = "JprNotifyErrorBorder",
        title_hl = "JprNotifyErrorTitle",
        timeout_ms = 6000,
    },
    success = {
        title = " jpr · Done ",
        border_hl = "JprNotifySuccessBorder",
        title_hl = "JprNotifySuccessTitle",
        timeout_ms = 3500,
    },
    info = {
        title = " jpr · Update ",
        border_hl = "JprNotifyInfoBorder",
        title_hl = "JprNotifyInfoTitle",
        timeout_ms = 4500,
    },
    warn = {
        title = " jpr · Warning ",
        border_hl = "JprNotifyWarnBorder",
        title_hl = "JprNotifyWarnTitle",
        timeout_ms = 5000,
    },
    progress = {
        title = " jpr · Working ",
        border_hl = "JprNotifyProgressBorder",
        title_hl = "JprNotifyProgressTitle",
        timeout_ms = nil,
    },
}

local next_toast_id = 0
local toasts = {}
local pending_timers = {}
local spinner_timer = nil
local spinner_index = 1
local notify_listener = nil
local did_register_autocmds = false

local function stop_timer(timer)
    if not timer then
        return
    end
    pcall(timer.stop, timer)
    if not timer:is_closing() then
        pcall(timer.close, timer)
    end
end

local function close_toast_window(toast)
    stop_timer(toast.dismiss_timer)
    toast.dismiss_timer = nil
    if toast.win and vim.api.nvim_win_is_valid(toast.win) then
        pcall(vim.api.nvim_win_close, toast.win, true)
    end
    if toast.buf and vim.api.nvim_buf_is_valid(toast.buf) then
        pcall(vim.api.nvim_buf_delete, toast.buf, { force = true })
    end
    toast.win = nil
    toast.buf = nil
end

local function wrap_message_lines(text, max_width)
    local result = {}
    local safe_width = math.max(12, max_width)
    for _, raw_line in ipairs(vim.split(tostring(text or ""), "\n", { plain = true })) do
        local line = raw_line:gsub("\r", "")
        if #line <= safe_width then
            result[#result + 1] = line
        else
            local remaining = line
            while #remaining > safe_width do
                local break_at = remaining:sub(1, safe_width):match(".*()%s+")
                if break_at and break_at > 4 then
                    result[#result + 1] = vim.trim(remaining:sub(1, break_at))
                    remaining = vim.trim(remaining:sub(break_at + 1))
                else
                    result[#result + 1] = remaining:sub(1, safe_width)
                    remaining = remaining:sub(safe_width + 1)
                end
            end
            if remaining ~= "" then
                result[#result + 1] = remaining
            end
        end
    end
    return #result > 0 and result or { "" }
end

local function compute_toast_dimensions(lines)
    local max_width = math.min(56, math.max(24, vim.o.columns - 4))
    local width = 24
    for _, line in ipairs(lines) do
        width = math.max(width, math.min(max_width, vim.fn.strdisplaywidth(line) + 2))
    end
    local height = math.max(1, math.min(6, #lines))
    return width, height
end

local function format_toast_lines(toast)
    local max_content_width = math.min(54, math.max(20, vim.o.columns - 6))
    local text = toast.message
    if toast.kind == "progress" then
        text = SPINNER_FRAMES[spinner_index] .. " " .. text
    end
    local wrapped = wrap_message_lines(text, max_content_width)
    local padded = {}
    for _, line in ipairs(wrapped) do
        padded[#padded + 1] = " " .. line .. " "
    end
    return padded
end

local function build_winhighlight_from_kind(kind)
    local spec = KIND_SPECS[kind] or KIND_SPECS.info
    return ("NormalFloat:NormalFloat,FloatBorder:%s,FloatTitle:%s"):format(spec.border_hl, spec.title_hl)
end

local function reflow_toasts()
    local next_row = 1
    local max_row = math.max(2, vim.o.lines - 3)
    local anchor_col = math.max(1, vim.o.columns - 1)
    for _, toast in ipairs(toasts) do
        if toast.win and vim.api.nvim_win_is_valid(toast.win) then
            local row = math.min(next_row, max_row)
            local spec = KIND_SPECS[toast.kind] or KIND_SPECS.info
            pcall(vim.api.nvim_win_set_config, toast.win, {
                relative = "editor",
                anchor = "NE",
                row = row,
                col = anchor_col,
                width = toast.width,
                height = toast.height,
                border = "rounded",
                title = toast.title or spec.title,
                title_pos = "left",
                zindex = 250,
            })
            next_row = row + toast.height + 2
        end
    end
end

local function has_visible_progress_toast()
    for _, toast in ipairs(toasts) do
        if toast.kind == "progress" then
            return true
        end
    end
    return false
end

local function paint_toast(toast)
    if not toast.buf or not vim.api.nvim_buf_is_valid(toast.buf) then
        return
    end
    local lines = format_toast_lines(toast)
    local width, height = compute_toast_dimensions(lines)
    toast.width = width
    toast.height = height
    vim.bo[toast.buf].modifiable = true
    vim.api.nvim_buf_set_lines(toast.buf, 0, -1, false, lines)
    vim.bo[toast.buf].modifiable = false
    if toast.win and vim.api.nvim_win_is_valid(toast.win) then
        vim.api.nvim_set_option_value("winhighlight", build_winhighlight_from_kind(toast.kind), { win = toast.win })
    end
end

local function sync_spinner_timer()
    if not has_visible_progress_toast() then
        stop_timer(spinner_timer)
        spinner_timer = nil
        return
    end
    if spinner_timer then
        return
    end
    spinner_timer = vim.uv.new_timer()
    if not spinner_timer then
        return
    end
    spinner_timer:start(
        SPINNER_INTERVAL_MS,
        SPINNER_INTERVAL_MS,
        vim.schedule_wrap(function()
            if not has_visible_progress_toast() then
                sync_spinner_timer()
                return
            end
            spinner_index = (spinner_index % #SPINNER_FRAMES) + 1
            for _, toast in ipairs(toasts) do
                if toast.kind == "progress" then
                    paint_toast(toast)
                end
            end
        end)
    )
end

local function evict_if_full()
    while #toasts >= MAX_VISIBLE_TOASTS do
        local evict_index = nil
        for index, toast in ipairs(toasts) do
            if toast.kind ~= "progress" then
                evict_index = index
                break
            end
        end
        evict_index = evict_index or 1
        local evicted = table.remove(toasts, evict_index)
        close_toast_window(evicted)
    end
end

local function schedule_dismiss(toast, timeout_ms)
    stop_timer(toast.dismiss_timer)
    toast.dismiss_timer = nil
    if not timeout_ms or timeout_ms <= 0 then
        return
    end
    local timer = vim.uv.new_timer()
    if not timer then
        return
    end
    toast.dismiss_timer = timer
    timer:start(
        timeout_ms,
        0,
        vim.schedule_wrap(function()
            M.dismiss(toast.id)
        end)
    )
end

local function ensure_autocmds()
    if did_register_autocmds then
        return
    end
    did_register_autocmds = true
    local group = vim.api.nvim_create_augroup("jpr-notify", { clear = true })
    vim.api.nvim_create_autocmd("VimResized", {
        group = group,
        callback = reflow_toasts,
    })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = M.clear,
    })
end

local function kind_to_log_level(kind)
    if kind == "error" then
        return vim.log.levels.ERROR
    end
    if kind == "warn" then
        return vim.log.levels.WARN
    end
    return vim.log.levels.INFO
end

local function emit_listener(kind, message)
    if type(notify_listener) == "function" then
        pcall(notify_listener, kind, message, kind_to_log_level(kind))
    end
end

local function open_toast(kind, message, opts)
    ensure_autocmds()
    require("jpr.highlights").define_highlights()
    evict_if_full()
    next_toast_id = next_toast_id + 1
    local spec = KIND_SPECS[kind] or KIND_SPECS.info
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false

    local toast = {
        id = next_toast_id,
        kind = kind,
        message = tostring(message or ""),
        title = opts and opts.title or nil,
        buf = buf,
        win = nil,
        width = 24,
        height = 1,
        dismiss_timer = nil,
    }
    paint_toast(toast)
    local is_opened, win = pcall(vim.api.nvim_open_win, buf, false, {
        relative = "editor",
        anchor = "NE",
        row = 1,
        col = math.max(1, vim.o.columns - 1),
        width = toast.width,
        height = toast.height,
        style = "minimal",
        border = "rounded",
        title = toast.title or spec.title,
        title_pos = "left",
        focusable = false,
        noautocmd = true,
        zindex = 250,
    })
    if not is_opened or not win then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        return nil
    end
    toast.win = win
    vim.w[win].jpr_side = true
    vim.api.nvim_set_option_value("winhighlight", build_winhighlight_from_kind(kind), { win = win })
    toasts[#toasts + 1] = toast
    reflow_toasts()
    local timeout_ms = (opts and opts.timeout_ms ~= nil) and opts.timeout_ms or spec.timeout_ms
    schedule_dismiss(toast, timeout_ms)
    sync_spinner_timer()
    return toast
end

local function find_toast_index(id)
    for index, toast in ipairs(toasts) do
        if toast.id == id then
            return index
        end
    end
    return nil
end

--- Dismisses the toast with identifier `id` and reflows remaining toasts.
function M.dismiss(id)
    local index = find_toast_index(id)
    if not index then
        return
    end
    local toast = table.remove(toasts, index)
    close_toast_window(toast)
    reflow_toasts()
    sync_spinner_timer()
end

--- Shows a red error toast in the top-right stack.
function M.error(message, opts)
    emit_listener("error", message)
    local toast = open_toast("error", message, opts)
    return toast and toast.id or nil
end

--- Shows a green success toast in the top-right stack.
function M.success(message, opts)
    emit_listener("success", message)
    local toast = open_toast("success", message, opts)
    return toast and toast.id or nil
end

--- Shows a blue informational / automatic-update toast in the top-right stack.
function M.info(message, opts)
    emit_listener("info", message)
    local toast = open_toast("info", message, opts)
    return toast and toast.id or nil
end

--- Shows an amber warning toast in the top-right stack.
function M.warn(message, opts)
    emit_listener("warn", message)
    local toast = open_toast("warn", message, opts)
    return toast and toast.id or nil
end

local function transition_progress_toast(state, kind, message, timeout_override)
    if state.finished then
        return
    end
    state.finished = true
    if state.delay_timer then
        pending_timers[state.delay_timer] = nil
        stop_timer(state.delay_timer)
        state.delay_timer = nil
    end
    emit_listener(kind, message)
    local spec = KIND_SPECS[kind] or KIND_SPECS.info
    local timeout_ms = timeout_override ~= nil and timeout_override or spec.timeout_ms
    if state.toast and find_toast_index(state.toast.id) then
        state.toast.kind = kind
        state.toast.message = tostring(message or "")
        state.toast.title = nil
        paint_toast(state.toast)
        reflow_toasts()
        schedule_dismiss(state.toast, timeout_ms)
        sync_spinner_timer()
    else
        open_toast(kind, message, { timeout_ms = timeout_ms })
    end
end

--- Starts an animated in-progress toast (optionally deferred by `opts.delay_ms`)
--- and returns a lifecycle handle `{ update, succeed, fail, cancel }`.
function M.progress(message, opts)
    local options = opts or {}
    local delay_ms = type(options.delay_ms) == "number" and options.delay_ms or 0
    local state = {
        message = tostring(message or ""),
        title = options.title,
        toast = nil,
        delay_timer = nil,
        finished = false,
    }
    local function open_now()
        if state.finished or state.toast then
            return
        end
        state.toast = open_toast("progress", state.message, { title = state.title })
    end
    if delay_ms > 0 then
        local timer = vim.uv.new_timer()
        if timer then
            state.delay_timer = timer
            pending_timers[timer] = true
            timer:start(
                delay_ms,
                0,
                vim.schedule_wrap(function()
                    pending_timers[timer] = nil
                    stop_timer(timer)
                    state.delay_timer = nil
                    open_now()
                end)
            )
        else
            open_now()
        end
    else
        open_now()
    end

    return {
        update = function(_, next_message)
            if state.finished then
                return
            end
            state.message = tostring(next_message or "")
            if state.toast and find_toast_index(state.toast.id) then
                state.toast.message = state.message
                paint_toast(state.toast)
                reflow_toasts()
            end
        end,
        succeed = function(_, success_message, timeout_ms)
            if success_message == nil or success_message == "" then
                if not state.finished then
                    state.finished = true
                    if state.delay_timer then
                        pending_timers[state.delay_timer] = nil
                        stop_timer(state.delay_timer)
                        state.delay_timer = nil
                    end
                    if state.toast then
                        M.dismiss(state.toast.id)
                    end
                end
                return
            end
            transition_progress_toast(state, "success", success_message, timeout_ms)
        end,
        fail = function(_, error_message, timeout_ms)
            transition_progress_toast(state, "error", error_message, timeout_ms)
        end,
        cancel = function()
            if state.finished then
                return
            end
            state.finished = true
            if state.delay_timer then
                pending_timers[state.delay_timer] = nil
                stop_timer(state.delay_timer)
                state.delay_timer = nil
            end
            if state.toast then
                M.dismiss(state.toast.id)
            end
        end,
    }
end

--- Returns the currently visible toasts (in top-to-bottom stack order).
function M.get_toasts()
    local copy = {}
    for index, toast in ipairs(toasts) do
        copy[index] = toast
    end
    return copy
end

--- Registers an optional listener `fn(kind, message)` invoked whenever a
--- non-progress notification is emitted (useful for automated tests).
function M.set_listener(listener)
    notify_listener = type(listener) == "function" and listener or nil
end

--- Closes all visible toasts and stops all active spinner and delay timers.
function M.clear()
    for timer in pairs(pending_timers) do
        pending_timers[timer] = nil
        stop_timer(timer)
    end
    stop_timer(spinner_timer)
    spinner_timer = nil
    for index = #toasts, 1, -1 do
        close_toast_window(toasts[index])
        toasts[index] = nil
    end
end

return M
