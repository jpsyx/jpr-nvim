-- Floating Neovim command palette and step-by-step wizard modal controller.
local palette = require("jpr.tui.wizard.palette")
local schema = require("jpr.tui.schema")
local step_menu = require("jpr.tui.wizard.step_menu")
local step_text = require("jpr.tui.wizard.step_text")
local window = require("jpr.tui.wizard.window")

local M = {}

local active_state = nil
local active_request_id = 0

local function increment_request_id()
    active_request_id = active_request_id + 1
    return active_request_id
end

local function create_prefilled_set(initial_answers)
    local prefilled_keys = {}
    for key, value in pairs(initial_answers or {}) do
        if value ~= nil then
            prefilled_keys[key] = true
        end
    end
    return prefilled_keys
end

local function capture_origin_win(preserved_origin_win)
    if preserved_origin_win ~= nil and vim.api.nvim_win_is_valid(preserved_origin_win) then
        return preserved_origin_win
    end
    if active_state ~= nil and active_state.origin_win ~= nil and vim.api.nvim_win_is_valid(active_state.origin_win) then
        return active_state.origin_win
    end
    local current_win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_is_valid(current_win) then
        return current_win
    end
    return nil
end

local function restore_origin_window(origin_win)
    if origin_win == nil or not vim.api.nvim_win_is_valid(origin_win) then
        return
    end
    if vim.api.nvim_win_get_tabpage(origin_win) ~= vim.api.nvim_get_current_tabpage() then
        return
    end
    pcall(vim.api.nvim_set_current_win, origin_win)
end

local function find_starting_step_index(active_steps, answers, start_step_id)
    if type(start_step_id) == "string" and start_step_id ~= "" then
        for step_index, step in ipairs(active_steps) do
            if step.id == start_step_id then
                return step_index
            end
        end
    end
    for step_index, step in ipairs(active_steps) do
        if answers[step.id] == nil then
            return step_index
        end
    end
    return 1
end

local function find_next_step_index(active_steps, current_step_id, fallback_index, prefilled_keys)
    local current_position = fallback_index
    for step_index, step in ipairs(active_steps) do
        if step.id == current_step_id then
            current_position = step_index
            break
        end
    end
    for candidate_index = current_position + 1, #active_steps do
        if not prefilled_keys[active_steps[candidate_index].id] then
            return candidate_index
        end
    end
    return nil
end

local function validate_step_value(step, value, answers, context)
    if type(step.validate) ~= "function" then
        return true, nil
    end
    local first_result, second_result = step.validate(value, answers, context)
    if first_result == false then
        local message = (type(second_result) == "string" and second_result ~= "")
                and second_result
            or "Invalid value."
        return false, message
    end
    if first_result == nil and type(second_result) == "string" and second_result ~= "" then
        return false, second_result
    end
    if type(first_result) == "string" and first_result ~= "" then
        return false, first_result
    end
    return true, nil
end

local function get_preferred_step_value(step, answers, context)
    if answers[step.id] ~= nil then
        return answers[step.id]
    end
    return schema.get_default_value_from_step(step, answers, context)
end

local function handle_external_close(state, buf, win, should_close_win)
    if active_state ~= state or (state.buf ~= buf and state.win ~= win) then
        return
    end
    active_state = nil
    increment_request_id()
    state.buf = nil
    state.win = nil
    if vim.fn.mode(1):sub(1, 1) == "i" then
        pcall(vim.cmd, "stopinsert")
    end
    local origin_win = state.origin_win
    vim.schedule(function()
        window.close_handle(should_close_win and win or nil, buf)
        if active_state == nil then
            restore_origin_window(origin_win)
        end
    end)
end

local function register_cleanup_guards(state, buf, win)
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            handle_external_close(state, buf, win, true)
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        once = true,
        callback = function()
            handle_external_close(state, buf, win, false)
        end,
    })
end

local function register_cursor_hover_sync(state, get_index, set_index, repaint)
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = state.buf,
        callback = function()
            if state.is_painting or active_state ~= state then
                return
            end
            if not state.win or not vim.api.nvim_win_is_valid(state.win) then
                return
            end
            local row = vim.api.nvim_win_get_cursor(state.win)[1]
            local hovered_index = state.layout and state.layout.item_for_line[row]
            if hovered_index ~= nil and hovered_index ~= get_index() then
                set_index(hovered_index)
                repaint()
            end
        end,
    })
end

local function detach_current_window(state, should_stop_insert)
    local previous_win = state.win
    local previous_buf = state.buf
    state.win = nil
    state.buf = nil
    if should_stop_insert and previous_buf and vim.api.nvim_get_current_buf() == previous_buf then
        if vim.fn.mode(1):sub(1, 1) == "i" then
            pcall(vim.cmd, "stopinsert")
        end
    end
    window.close_handle(previous_win, previous_buf)
end

--- Closes any currently open wizard floating window and cancels pending async callbacks.
function M.close()
    increment_request_id()
    local state = active_state
    active_state = nil
    if state then
        detach_current_window(state, true)
        restore_origin_window(state.origin_win)
    end
end

--- Returns `true` when an active wizard floating window is open and valid.
--- @return boolean
function M.is_open()
    return active_state ~= nil
        and active_state.win ~= nil
        and vim.api.nvim_win_is_valid(active_state.win)
end

local controller
local open_current_step

local function complete_command(state)
    local command = state.command
    local context = state.context
    local pruned_answers = schema.prune_inactive_answers(command, state.answers, context)
    M.close()
    if type(command.execute) == "function" then
        command.execute(pruned_answers, context)
    end
end

local function commit_step_answer(state, step, candidate_value, on_validation_error)
    local is_valid, error_message = validate_step_value(step, candidate_value, state.answers, state.context)
    if not is_valid then
        on_validation_error(error_message)
        return
    end
    state.answers[step.id] = candidate_value
    state.prefilled_keys[step.id] = nil
    local updated_steps = schema.get_active_steps_from_command(state.command, state.answers, state.context)
    local next_step_index = find_next_step_index(updated_steps, step.id, state.step_index, state.prefilled_keys)
    if next_step_index ~= nil then
        state.step_index = next_step_index
        open_current_step(state)
    else
        complete_command(state)
    end
end

local function can_return_to_palette(state)
    return state.can_return_to_palette
        and type(state.palette_commands) == "table"
        and #state.palette_commands > 0
end

local function step_back_from_step(state, step, draft_value, has_draft)
    if state.step_index <= 1 then
        if can_return_to_palette(state) then
            palette.open_at(controller, state.palette_commands, state.context, state.palette_index, state.origin_win)
        end
        return
    end
    if has_draft then
        state.answers[step.id] = draft_value
    end
    state.step_index = state.step_index - 1
    local active_steps = schema.get_active_steps_from_command(state.command, state.answers, state.context)
    if #active_steps == 0 then
        if can_return_to_palette(state) then
            palette.open_at(controller, state.palette_commands, state.context, state.palette_index, state.origin_win)
        else
            M.close()
        end
        return
    end
    state.step_index = math.max(1, math.min(state.step_index, #active_steps))
    state.prefilled_keys[active_steps[state.step_index].id] = nil
    open_current_step(state)
end

open_current_step = function(state)
    increment_request_id()
    state.active_steps = schema.get_active_steps_from_command(state.command, state.answers, state.context)
    if #state.active_steps == 0 then
        detach_current_window(state, true)
        complete_command(state)
        return
    end
    state.step_index = math.max(1, math.min(state.step_index, #state.active_steps))
    local step = state.active_steps[state.step_index]
    state.current_step_id = step.id
    if step.kind == "text" then
        detach_current_window(state, false)
        step_text.open(controller, state, step)
    else
        detach_current_window(state, true)
        step_menu.open(controller, state, step)
    end
end

controller = {
    close = M.close,
    open_command = function(...) return M.open_command(...) end,
    capture_origin_win = capture_origin_win,
    register_cleanup_guards = register_cleanup_guards,
    register_cursor_hover_sync = register_cursor_hover_sync,
    get_preferred_step_value = get_preferred_step_value,
    commit_step_answer = commit_step_answer,
    step_back_from_step = step_back_from_step,
    increment_request_id = increment_request_id,
    set_active_state = function(state) active_state = state end,
    is_active = function(state) return active_state == state and M.is_open() end,
    is_request_matching = function(state, step_id, request_id)
        return active_request_id == request_id
            and active_state == state
            and state.current_step_id == step_id
            and state.win ~= nil
    end,
    is_current_request = function(state, step_id, request_id)
        return active_request_id == request_id
            and active_state == state
            and state.current_step_id == step_id
            and M.is_open()
    end,
}

--- Opens the centered floating command palette for `commands` in Normal mode.
--- @param commands table[]
--- @param context table|nil
function M.open_palette(commands, context)
    palette.open_at(controller, commands, context, 1, nil)
end

--- Opens the step-by-step floating wizard for `command` (or executes immediately when 0 steps are active).
--- @param command table
--- @param initial_answers table|nil
--- @param context table|nil
--- @param opts table|nil { can_return_to_palette?: boolean, palette_commands?: table[], palette_index?: integer, start_step_id?: string }
function M.open_command(command, initial_answers, context, opts)
    local options = opts or {}
    local origin_win = capture_origin_win(options.origin_win)
    M.close()
    require("jpr").define_highlights()

    local answers = vim.tbl_extend("force", {}, initial_answers or {})
    local current_context = context or {}
    local active_steps = schema.get_active_steps_from_command(command, answers, current_context)
    if #active_steps == 0 then
        if type(command.execute) == "function" then
            command.execute(schema.prune_inactive_answers(command, answers, current_context), current_context)
        end
        return
    end

    local starting_step_index = find_starting_step_index(active_steps, answers, options.start_step_id)
    local prefilled_keys = create_prefilled_set(answers)
    prefilled_keys[active_steps[starting_step_index].id] = nil

    local state = {
        kind = "wizard",
        command = command,
        answers = answers,
        prefilled_keys = prefilled_keys,
        context = current_context,
        active_steps = active_steps,
        step_index = starting_step_index,
        can_return_to_palette = options.can_return_to_palette == true,
        palette_commands = options.palette_commands,
        palette_index = options.palette_index or 1,
        origin_win = origin_win,
        is_painting = false,
    }
    active_state = state
    open_current_step(state)
end

return M
