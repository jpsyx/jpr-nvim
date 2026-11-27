-- Top-right color-coded floating toast stack for jpr: red (error), green
-- (success), blue (info / automatic updates), amber (warn), and animated
-- in-progress spinners that transition in place on completion.
local layout = require("jpr.notify.layout")
local window = require("jpr.notify.window")

local M = {}

local next_toast_id = 0
local toasts = {}
local pending_timers = {}
local spinner_timer = nil
local spinner_index = 1
local notify_listener = nil
local did_register_autocmds = false

local function has_visible_progress_toast()
    for _, toast in ipairs(toasts) do
        if toast.kind == "progress" then
            return true
        end
    end
    return false
end

local function find_toast_index(id)
    for index, toast in ipairs(toasts) do
        if toast.id == id then
            return index
        end
    end
    return nil
end

local function sync_spinner_timer()
    if not has_visible_progress_toast() then
        window.stop_timer(spinner_timer)
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
        layout.SPINNER_INTERVAL_MS,
        layout.SPINNER_INTERVAL_MS,
        vim.schedule_wrap(function()
            if not has_visible_progress_toast() then
                sync_spinner_timer()
                return
            end
            spinner_index = (spinner_index % #layout.SPINNER_FRAMES) + 1
            for _, toast in ipairs(toasts) do
                if toast.kind == "progress" then
                    window.paint_toast(toast, spinner_index)
                end
            end
        end)
    )
end

local function evict_if_full()
    while #toasts >= layout.MAX_VISIBLE_TOASTS do
        local evict_index = nil
        for index, toast in ipairs(toasts) do
            if toast.kind ~= "progress" then
                evict_index = index
                break
            end
        end
        local evicted = table.remove(toasts, evict_index or 1)
        window.close_toast(evicted)
    end
end

local function schedule_dismiss(toast, timeout_ms)
    window.stop_timer(toast.dismiss_timer)
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
        callback = function()
            window.reflow_toasts(toasts)
        end,
    })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = M.clear,
    })
end

local function emit_listener(kind, message)
    if type(notify_listener) == "function" then
        pcall(notify_listener, kind, message, layout.kind_to_log_level(kind))
    end
end

local function open_toast(kind, message, opts)
    ensure_autocmds()
    require("jpr.highlights").define_highlights()
    evict_if_full()
    next_toast_id = next_toast_id + 1
    local spec = layout.KIND_SPECS[kind] or layout.KIND_SPECS.info
    local toast = {
        id = next_toast_id,
        kind = kind,
        message = tostring(message or ""),
        title = opts and opts.title or nil,
        buf = nil,
        win = nil,
        width = 24,
        height = 1,
        dismiss_timer = nil,
    }
    if not window.open_toast_window(toast, spinner_index) then
        return nil
    end
    toasts[#toasts + 1] = toast
    window.reflow_toasts(toasts)
    local timeout_ms = (opts and opts.timeout_ms ~= nil) and opts.timeout_ms or spec.timeout_ms
    schedule_dismiss(toast, timeout_ms)
    sync_spinner_timer()
    return toast
end

local function clear_delay_timer(state)
    if not state.delay_timer then
        return
    end
    pending_timers[state.delay_timer] = nil
    window.stop_timer(state.delay_timer)
    state.delay_timer = nil
end

local function transition_progress_toast(state, kind, message, timeout_override)
    if state.finished then
        return
    end
    state.finished = true
    clear_delay_timer(state)
    emit_listener(kind, message)
    local spec = layout.KIND_SPECS[kind] or layout.KIND_SPECS.info
    local timeout_ms = timeout_override ~= nil and timeout_override or spec.timeout_ms
    if state.toast and find_toast_index(state.toast.id) then
        state.toast.kind = kind
        state.toast.message = tostring(message or "")
        state.toast.title = nil
        window.paint_toast(state.toast, spinner_index)
        window.reflow_toasts(toasts)
        schedule_dismiss(state.toast, timeout_ms)
        sync_spinner_timer()
    else
        open_toast(kind, message, { timeout_ms = timeout_ms })
    end
end

local function finish_progress_silently(state)
    if state.finished then
        return
    end
    state.finished = true
    clear_delay_timer(state)
    if state.toast then
        M.dismiss(state.toast.id)
    end
end

local function create_progress_handle(state)
    return {
        update = function(_, next_message)
            if state.finished then
                return
            end
            state.message = tostring(next_message or "")
            if state.toast and find_toast_index(state.toast.id) then
                state.toast.message = state.message
                window.paint_toast(state.toast, spinner_index)
                window.reflow_toasts(toasts)
            end
        end,
        succeed = function(_, success_message, timeout_ms)
            if success_message == nil or success_message == "" then
                return finish_progress_silently(state)
            end
            transition_progress_toast(state, "success", success_message, timeout_ms)
        end,
        fail = function(_, error_message, timeout_ms)
            transition_progress_toast(state, "error", error_message, timeout_ms)
        end,
        cancel = function()
            finish_progress_silently(state)
        end,
    }
end

--- Dismisses the toast with identifier `id` and reflows remaining toasts.
function M.dismiss(id)
    local index = find_toast_index(id)
    if not index then
        return
    end
    local toast = table.remove(toasts, index)
    window.close_toast(toast)
    window.reflow_toasts(toasts)
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
        if not state.finished and not state.toast then
            state.toast = open_toast("progress", state.message, { title = state.title })
        end
    end
    local timer = delay_ms > 0 and vim.uv.new_timer() or nil
    if timer then
        state.delay_timer = timer
        pending_timers[timer] = true
        timer:start(
            delay_ms,
            0,
            vim.schedule_wrap(function()
                clear_delay_timer(state)
                open_now()
            end)
        )
    else
        open_now()
    end
    return create_progress_handle(state)
end

--- Returns the currently visible toasts (in top-to-bottom stack order).
function M.get_toasts()
    local copy = {}
    for index, toast in ipairs(toasts) do
        copy[index] = toast
    end
    return copy
end

--- Registers an optional listener `fn(kind, message, level)` invoked whenever a
--- non-progress notification is emitted (useful for automated tests).
function M.set_listener(listener)
    notify_listener = type(listener) == "function" and listener or nil
end

--- Closes all visible toasts and stops all active spinner and delay timers.
function M.clear()
    for timer in pairs(pending_timers) do
        pending_timers[timer] = nil
        window.stop_timer(timer)
    end
    window.stop_timer(spinner_timer)
    spinner_timer = nil
    for index = #toasts, 1, -1 do
        window.close_toast(toasts[index])
        toasts[index] = nil
    end
end

return M
