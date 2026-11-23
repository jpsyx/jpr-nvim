-- Floating Neovim command palette and step-by-step wizard modal controller.
local render = require("jpr.tui.render")
local schema = require("jpr.tui.schema")
local window = require("jpr.tui.wizard_window")

local M = {}

local active_state = nil
local active_request_id = 0

local function increment_request_id()
    active_request_id = active_request_id + 1
    return active_request_id
end

local function copy_shallow(source)
    local result = {}
    for key, value in pairs(source or {}) do
        result[key] = value
    end
    return result
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

local function find_option_index_by_value(options, target_value)
    if target_value == nil then
        return 1
    end
    for option_index, option in ipairs(options or {}) do
        if option.value == target_value or vim.deep_equal(option.value, target_value) then
            return option_index
        end
    end
    return 1
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

local function register_wipeout_guard(buf, state)
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            if active_state == state and state.buf == buf then
                active_state = nil
                increment_request_id()
            end
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

local function detach_current_window(state)
    local previous_win = state.win
    local previous_buf = state.buf
    state.win = nil
    state.buf = nil
    if previous_buf and vim.api.nvim_get_current_buf() == previous_buf then
        pcall(vim.cmd, "stopinsert")
    end
    window.close_handle(previous_win, previous_buf)
end

--- Closes any currently open wizard floating window and cancels pending async callbacks.
function M.close()
    increment_request_id()
    local state = active_state
    active_state = nil
    if state then
        detach_current_window(state)
    end
end

--- Returns `true` when an active wizard floating window is open and valid.
--- @return boolean
function M.is_open()
    return active_state ~= nil
        and active_state.win ~= nil
        and vim.api.nvim_win_is_valid(active_state.win)
end

local open_palette_at
local open_current_step

local function paint_palette(state)
    if active_state ~= state or not M.is_open() then
        return
    end
    local width = window.compute_modal_width()
    state.layout = render.build_palette_layout(state.commands, state.selected_index, width, state.context)
    state.is_painting = true
    window.paint_menu_window(state.buf, state.win, state.layout, width)
    state.is_painting = false
end

local function move_palette_selection(state, target_index)
    local count = #state.commands
    if count == 0 then
        return
    end
    state.selected_index = ((target_index - 1) % count) + 1
    paint_palette(state)
end

local function activate_palette_command(state)
    local command = state.commands[state.selected_index]
    if not command then
        return
    end
    local active_steps = schema.resolve_active_steps(command, {}, state.context)
    if #active_steps == 0 then
        local context = state.context
        M.close()
        if type(command.execute) == "function" then
            command.execute({}, context)
        end
        return
    end
    M.open_command(command, {}, state.context, {
        can_return_to_palette = true,
        palette_commands = state.commands,
        palette_index = state.selected_index,
    })
end

local function bind_palette_keys(state)
    local map = function(lhs, handler)
        vim.keymap.set("n", lhs, handler, { buffer = state.buf, nowait = true, silent = true })
    end
    local move_down = function() move_palette_selection(state, state.selected_index + 1) end
    local move_up = function() move_palette_selection(state, state.selected_index - 1) end
    local jump_first = function() move_palette_selection(state, 1) end
    local jump_last = function() move_palette_selection(state, #state.commands) end
    local confirm = function() activate_palette_command(state) end

    for _, lhs in ipairs({ "j", "<Down>" }) do map(lhs, move_down) end
    for _, lhs in ipairs({ "k", "<Up>" }) do map(lhs, move_up) end
    for _, lhs in ipairs({ "gg", "<Home>" }) do map(lhs, jump_first) end
    for _, lhs in ipairs({ "G", "<End>" }) do map(lhs, jump_last) end
    for _, lhs in ipairs({ "<CR>", "l", "<Right>", "<Tab>" }) do map(lhs, confirm) end
    for _, lhs in ipairs({ "q", "<Esc>" }) do map(lhs, M.close) end
end

open_palette_at = function(commands, context, initial_index)
    M.close()
    require("jpr").define_highlights()

    local command_list = commands or {}
    local current_context = context or {}
    local clamped_index = math.max(1, math.min(tonumber(initial_index) or 1, math.max(1, #command_list)))
    local width = window.compute_modal_width()
    local layout = render.build_palette_layout(command_list, clamped_index, width, current_context)
    local title = (type(current_context.title) == "string" and current_context.title ~= "")
        and current_context.title
        or " Jpr Commands "

    local state = {
        kind = "palette",
        commands = command_list,
        context = current_context,
        selected_index = clamped_index,
        layout = layout,
        is_painting = true,
    }
    state.buf, state.win = window.create_menu_window(title, layout, width)
    active_state = state
    state.is_painting = false

    register_wipeout_guard(state.buf, state)
    register_cursor_hover_sync(
        state,
        function() return state.selected_index end,
        function(index) state.selected_index = index end,
        function() paint_palette(state) end
    )
    bind_palette_keys(state)
end

--- Opens the centered floating command palette for `commands` in Normal mode.
--- @param commands table[]
--- @param context table|nil
function M.open_palette(commands, context)
    open_palette_at(commands, context, 1)
end

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
    local updated_steps = schema.resolve_active_steps(state.command, state.answers, state.context)
    local next_step_index = find_next_step_index(updated_steps, step.id, state.step_index, state.prefilled_keys)
    if next_step_index ~= nil then
        state.step_index = next_step_index
        open_current_step(state)
    else
        complete_command(state)
    end
end

local function step_back_from_step(state, step, draft_value, has_draft)
    if state.step_index <= 1 then
        if state.can_return_to_palette and type(state.palette_commands) == "table" and #state.palette_commands > 0 then
            open_palette_at(state.palette_commands, state.context, state.palette_index)
        end
        return
    end
    if has_draft then
        state.answers[step.id] = draft_value
    end
    state.step_index = state.step_index - 1
    local active_steps = schema.resolve_active_steps(state.command, state.answers, state.context)
    if #active_steps == 0 then
        complete_command(state)
        return
    end
    state.step_index = math.max(1, math.min(state.step_index, #active_steps))
    state.prefilled_keys[active_steps[state.step_index].id] = nil
    open_current_step(state)
end

local function create_menu_step_state(step, answers, context, can_return_to_palette)
    local preferred = get_preferred_step_value(step, answers, context)
    if step.kind == "toggle" then
        local options = schema.create_toggle_options_from_step(step)
        local target = false
        if preferred ~= nil then
            target = preferred
        end
        return {
            is_loading = false,
            options = options,
            selected_option_index = find_option_index_by_value(options, target),
            can_return_to_palette = can_return_to_palette,
        }
    end
    if step.kind == "async_select" then
        return {
            is_loading = true,
            options = {},
            selected_option_index = 1,
            can_return_to_palette = can_return_to_palette,
        }
    end
    local options = step.options or {}
    return {
        is_loading = false,
        options = options,
        selected_option_index = find_option_index_by_value(options, preferred),
        can_return_to_palette = can_return_to_palette,
    }
end

local function paint_menu_step(state)
    if active_state ~= state or not M.is_open() then
        return
    end
    local width = window.compute_modal_width()
    state.layout = render.build_step_layout(state.command, state.active_steps, state.step_index, state.step_state, width)
    state.is_painting = true
    window.paint_menu_window(state.buf, state.win, state.layout, width)
    state.is_painting = false
end

local function move_menu_option(state, target_index)
    local options = state.step_state.options or {}
    if state.step_state.is_loading or #options == 0 then
        return
    end
    state.step_state.selected_option_index = ((target_index - 1) % #options) + 1
    paint_menu_step(state)
end

local function confirm_menu_step(state, step)
    local options = state.step_state.options or {}
    if state.step_state.is_loading or #options == 0 then
        return
    end
    local selected_option = options[state.step_state.selected_option_index]
    if not selected_option then
        return
    end
    commit_step_answer(state, step, selected_option.value, function(error_message)
        state.step_state.error_message = error_message
        paint_menu_step(state)
    end)
end

local function step_back_from_menu(state, step)
    local options = state.step_state.options or {}
    local selected_option = nil
    if not state.step_state.is_loading then
        selected_option = options[state.step_state.selected_option_index]
    end
    if selected_option ~= nil then
        step_back_from_step(state, step, selected_option.value, true)
    else
        step_back_from_step(state, step, nil, false)
    end
end

local function bind_menu_step_keys(state, step)
    local map = function(lhs, handler)
        vim.keymap.set("n", lhs, handler, { buffer = state.buf, nowait = true, silent = true })
    end
    local move_down = function() move_menu_option(state, state.step_state.selected_option_index + 1) end
    local move_up = function() move_menu_option(state, state.step_state.selected_option_index - 1) end
    local jump_first = function() move_menu_option(state, 1) end
    local jump_last = function() move_menu_option(state, #(state.step_state.options or {})) end
    local go_back = function() step_back_from_menu(state, step) end
    local confirm = function() confirm_menu_step(state, step) end

    for _, lhs in ipairs({ "j", "<Down>" }) do map(lhs, move_down) end
    for _, lhs in ipairs({ "k", "<Up>" }) do map(lhs, move_up) end
    for _, lhs in ipairs({ "gg", "<Home>" }) do map(lhs, jump_first) end
    for _, lhs in ipairs({ "G", "<End>" }) do map(lhs, jump_last) end
    for _, lhs in ipairs({ "h", "<Left>", "<S-Tab>" }) do map(lhs, go_back) end
    for _, lhs in ipairs({ "<CR>", "l", "<Right>", "<Tab>" }) do map(lhs, confirm) end
    for _, lhs in ipairs({ "q", "<Esc>" }) do map(lhs, M.close) end
end

local function start_async_step_load(state, step)
    local request_id = increment_request_id()
    local step_id = step.id
    step.load(state.answers, state.context, function(loaded_options, error_message, empty_message)
        if active_request_id ~= request_id or active_state ~= state or state.current_step_id ~= step_id then
            return
        end
        if not M.is_open() then
            return
        end
        state.step_state.is_loading = false
        state.step_state.error_message = error_message
        state.step_state.empty_message = empty_message
        if type(loaded_options) == "table" and #loaded_options > 0 then
            local preferred = get_preferred_step_value(step, state.answers, state.context)
            state.step_state.options = loaded_options
            state.step_state.selected_option_index = find_option_index_by_value(loaded_options, preferred)
        else
            state.step_state.options = {}
            state.step_state.selected_option_index = 1
        end
        paint_menu_step(state)
    end)
end

local function open_menu_step(state, step)
    state.step_state = create_menu_step_state(step, state.answers, state.context, state.can_return_to_palette)
    local width = window.compute_modal_width()
    state.layout = render.build_step_layout(state.command, state.active_steps, state.step_index, state.step_state, width)
    state.is_painting = true
    state.buf, state.win = window.create_menu_window(" " .. tostring(state.command.label) .. " ", state.layout, width)
    state.is_painting = false

    register_wipeout_guard(state.buf, state)
    register_cursor_hover_sync(
        state,
        function() return state.step_state.selected_option_index end,
        function(index) state.step_state.selected_option_index = index end,
        function() paint_menu_step(state) end
    )
    bind_menu_step_keys(state, step)
    if step.kind == "async_select" and type(step.load) == "function" then
        start_async_step_load(state, step)
    end
end

local function read_text_step_value(buf)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return ""
    end
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
end

local function bind_text_step_keys(state, step)
    local submit = function()
        pcall(vim.cmd, "stopinsert")
        local value = read_text_step_value(state.buf)
        commit_step_answer(state, step, value, function(error_message)
            local width = window.compute_modal_width()
            local virt_lines = render.build_text_step_virt_lines(step, error_message, width)
            window.paint_text_virt_lines(state.buf, state.win, virt_lines, width)
            pcall(vim.cmd, "startinsert!")
        end)
    end
    local go_back = function()
        pcall(vim.cmd, "stopinsert")
        local draft_value = read_text_step_value(state.buf)
        step_back_from_step(state, step, draft_value, true)
    end
    local map_opts = { buffer = state.buf, nowait = true, silent = true }
    for _, lhs in ipairs({ "<CR>", "<Tab>" }) do
        vim.keymap.set({ "i", "n" }, lhs, submit, map_opts)
    end
    vim.keymap.set({ "i", "n" }, "<S-Tab>", go_back, map_opts)
    for _, lhs in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", lhs, M.close, map_opts)
    end
end

local function open_text_step(state, step)
    local width = window.compute_modal_width()
    local preferred = get_preferred_step_value(step, state.answers, state.context)
    local initial_text = preferred ~= nil and tostring(preferred) or ""
    local title = (" Step %d of %d · %s "):format(state.step_index, #state.active_steps, tostring(step.label))
    local footer = " " .. render.build_text_step_footer(state.step_index, #state.active_steps, state.can_return_to_palette) .. " "
    local virt_lines = render.build_text_step_virt_lines(step, nil, width)

    state.buf, state.win = window.create_text_window(title, footer, initial_text, virt_lines, width)
    register_wipeout_guard(state.buf, state)
    bind_text_step_keys(state, step)
    pcall(vim.cmd, "startinsert!")
end

open_current_step = function(state)
    increment_request_id()
    detach_current_window(state)
    state.active_steps = schema.resolve_active_steps(state.command, state.answers, state.context)
    if #state.active_steps == 0 then
        complete_command(state)
        return
    end
    state.step_index = math.max(1, math.min(state.step_index, #state.active_steps))
    local step = state.active_steps[state.step_index]
    state.current_step_id = step.id
    if step.kind == "text" then
        open_text_step(state, step)
    else
        open_menu_step(state, step)
    end
end

--- Opens the step-by-step floating wizard for `command` (or executes immediately when 0 steps are active).
--- @param command table
--- @param initial_answers table|nil
--- @param context table|nil
--- @param opts table|nil { can_return_to_palette?: boolean, palette_commands?: table[], palette_index?: integer, start_step_id?: string }
function M.open_command(command, initial_answers, context, opts)
    M.close()
    require("jpr").define_highlights()

    local options = opts or {}
    local answers = copy_shallow(initial_answers)
    local current_context = context or {}
    local active_steps = schema.resolve_active_steps(command, answers, current_context)
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
        is_painting = false,
    }
    active_state = state
    open_current_step(state)
end

return M
