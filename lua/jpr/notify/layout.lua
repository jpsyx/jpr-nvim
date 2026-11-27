-- Pure formatting, wrapping, and visual spec helpers for `jpr.notify`.
local M = {}

M.MAX_VISIBLE_TOASTS = 6
M.SPINNER_INTERVAL_MS = 80
M.SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

M.KIND_SPECS = {
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

--- Maps a notification `kind` to its corresponding `vim.log.levels` value.
function M.kind_to_log_level(kind)
    if kind == "error" then
        return vim.log.levels.ERROR
    end
    if kind == "warn" then
        return vim.log.levels.WARN
    end
    return vim.log.levels.INFO
end

--- Builds the Neovim `winhighlight` string for notification `kind`.
function M.build_winhighlight_from_kind(kind)
    local spec = M.KIND_SPECS[kind] or M.KIND_SPECS.info
    return ("NormalFloat:NormalFloat,FloatBorder:%s,FloatTitle:%s"):format(spec.border_hl, spec.title_hl)
end

local function wrap_single_line(raw_line, safe_width, result)
    local line = raw_line:gsub("\r", "")
    if #line <= safe_width then
        result[#result + 1] = line
        return
    end
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

--- Wraps `text` to `max_width` columns without breaking words when possible.
function M.wrap_message_lines(text, max_width)
    local result = {}
    local safe_width = math.max(12, max_width)
    for _, raw_line in ipairs(vim.split(tostring(text or ""), "\n", { plain = true })) do
        wrap_single_line(raw_line, safe_width, result)
    end
    return #result > 0 and result or { "" }
end

--- Computes clamped `{ width, height }` for rendered toast `lines`.
function M.compute_toast_dimensions(lines)
    local max_width = math.min(56, math.max(24, vim.o.columns - 4))
    local width = 24
    for _, line in ipairs(lines) do
        width = math.max(width, math.min(max_width, vim.fn.strdisplaywidth(line) + 2))
    end
    local height = math.max(1, math.min(6, #lines))
    return width, height
end

--- Formats padded buffer lines for `toast` using `spinner_index` when active.
function M.format_toast_lines(toast, spinner_index)
    local max_content_width = math.min(54, math.max(20, vim.o.columns - 6))
    local text = toast.message
    if toast.kind == "progress" then
        text = M.SPINNER_FRAMES[spinner_index] .. " " .. text
    end
    local wrapped = M.wrap_message_lines(text, max_content_width)
    local padded = {}
    for _, line in ipairs(wrapped) do
        padded[#padded + 1] = " " .. line .. " "
    end
    return padded
end

return M
