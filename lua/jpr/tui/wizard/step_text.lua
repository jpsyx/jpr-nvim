-- Single-line editable text-input wizard step painting, Insert-mode continuity, and keybindings.
local render = require("jpr.tui.render")
local window = require("jpr.tui.wizard.window")

local M = {}

local function read_text_step_value(buf)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return ""
    end
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
end

local function ensure_text_insert_mode(controller, state, target_win)
    if vim.fn.mode(1):sub(1, 1) == "i" then
        return
    end
    vim.schedule(function()
        if not controller.is_active(state) or state.win ~= target_win then
            return
        end
        if not target_win or not vim.api.nvim_win_is_valid(target_win) then
            return
        end
        if vim.api.nvim_get_current_win() ~= target_win then
            return
        end
        pcall(vim.cmd, "startinsert!")
    end)
end

local function bind_text_step_keys(controller, state, step)
    local submit = function()
        local value = read_text_step_value(state.buf)
        controller.commit_step_answer(state, step, value, function(error_message)
            local width = window.get_modal_width()
            local virt_lines = render.create_virt_lines_from_text_step(step, error_message, width)
            window.paint_text_virt_lines(state.buf, state.win, virt_lines, width)
            ensure_text_insert_mode(controller, state, state.win)
        end)
    end
    local go_back = function()
        local draft_value = read_text_step_value(state.buf)
        controller.step_back_from_step(state, step, draft_value, true)
    end
    local map_opts = { buffer = state.buf, nowait = true, silent = true }
    for _, lhs in ipairs({ "<CR>", "<Tab>" }) do
        vim.keymap.set({ "i", "n" }, lhs, submit, map_opts)
    end
    vim.keymap.set({ "i", "n" }, "<S-Tab>", go_back, map_opts)
    for _, lhs in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", lhs, controller.close, map_opts)
    end
end

--- Opens a `text` input step inside the active wizard `state`.
--- @param controller table
--- @param state table
--- @param step table
function M.open(controller, state, step)
    local width = window.get_modal_width()
    local preferred = controller.get_preferred_step_value(step, state.answers, state.context)
    local initial_text = preferred ~= nil and tostring(preferred) or ""
    local title = (" Step %d of %d · %s "):format(state.step_index, #state.active_steps, tostring(step.label))
    local footer = " "
        .. render.build_text_step_footer(state.step_index, #state.active_steps, state.can_return_to_palette)
        .. " "
    local virt_lines = render.create_virt_lines_from_text_step(step, nil, width)

    state.buf, state.win = window.create_text_window(title, footer, initial_text, virt_lines, width)
    controller.register_cleanup_guards(state, state.buf, state.win)
    bind_text_step_keys(controller, state, step)
    ensure_text_insert_mode(controller, state, state.win)
end

return M
