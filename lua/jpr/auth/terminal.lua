-- Centered floating terminal runner for interactive `gh auth login`.
local window = require("jpr.tui.wizard.window")

local M = {}

local TERMINAL_TITLE = " GitHub CLI Login (gh auth login) "
local TERMINAL_FOOTER = " Complete sign-in in terminal · resumes automatically when done "

local function get_terminal_dimensions()
    local max_width = math.max(24, vim.o.columns - 4)
    local max_height = math.max(10, vim.o.lines - 4)
    local width = math.min(max_width, math.max(math.min(64, max_width), math.floor(vim.o.columns * 0.8)))
    local height = math.min(max_height, math.max(math.min(18, max_height), math.floor(vim.o.lines * 0.75)))
    return width, height
end

local function close_terminal_handles(state)
    if vim.fn.mode(1):sub(1, 1) == "t" then
        pcall(vim.cmd, "stopinsert")
    end
    local win, buf = state.win, state.buf
    state.win, state.buf = nil, nil
    window.close_handle(win, buf)
end

--- Stops any active `gh auth login` terminal job and closes its floating window.
function M.close(state)
    if not state then
        return
    end
    state.is_settled = true
    local job = state.job
    state.job = nil
    if type(job) == "number" and job > 0 then
        pcall(vim.fn.jobstop, job)
    end
    close_terminal_handles(state)
end

local function create_terminal_settler(state, on_finished)
    return function(exit_code)
        if state.is_settled then
            return
        end
        state.is_settled = true
        local active_job = state.job
        state.job = nil
        if exit_code == nil and type(active_job) == "number" and active_job > 0 then
            pcall(vim.fn.jobstop, active_job)
        end
        vim.schedule(function()
            close_terminal_handles(state)
            on_finished(exit_code)
        end)
    end
end

--- Opens a centered floating terminal running `gh auth login` and invokes
--- `on_finished(exit_code)` exactly once when the login job exits or the window
--- is closed manually.
function M.open(on_finished)
    require("jpr").define_highlights()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    local width, height = get_terminal_dimensions()
    local win = vim.api.nvim_open_win(
        buf,
        true,
        window.create_window_config(width, height, TERMINAL_TITLE, TERMINAL_FOOTER)
    )
    local state = { buf = buf, win = win, job = nil, is_settled = false }
    local settle = create_terminal_settler(state, on_finished)

    local is_started, job_id = pcall(vim.fn.jobstart, { "gh", "auth", "login" }, {
        term = true,
        on_exit = function(_, code)
            settle(code)
        end,
    })
    if not is_started or type(job_id) ~= "number" or job_id <= 0 then
        close_terminal_handles(state)
        return nil, "could not start `gh auth login`"
    end
    state.job = job_id
    vim.api.nvim_create_autocmd({ "WinClosed", "BufWipeout" }, {
        buffer = buf,
        once = true,
        callback = function()
            settle(nil)
        end,
    })
    pcall(vim.cmd, "startinsert")
    return state, nil
end

return M
