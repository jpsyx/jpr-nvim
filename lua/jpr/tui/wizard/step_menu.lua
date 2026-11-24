-- Menu, toggle, and async_select wizard step painting, keybindings, and async loading.
local render = require("jpr.tui.render")
local schema = require("jpr.tui.schema")
local window = require("jpr.tui.wizard.window")

local M = {}

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

local function create_menu_step_state(controller, step, answers, context, is_palette_returnable)
    local preferred = controller.get_preferred_step_value(step, answers, context)
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
            can_return_to_palette = is_palette_returnable,
        }
    end
    if step.kind == "async_select" then
        return {
            is_loading = true,
            options = {},
            selected_option_index = 1,
            can_return_to_palette = is_palette_returnable,
        }
    end
    local options = step.options or {}
    return {
        is_loading = false,
        options = options,
        selected_option_index = find_option_index_by_value(options, preferred),
        can_return_to_palette = is_palette_returnable,
    }
end

local function paint_menu_step(controller, state)
    if not controller.is_active(state) then
        return
    end
    local width = window.get_modal_width()
    state.layout = render.create_step_layout_from_state(
        state.command,
        state.active_steps,
        state.step_index,
        state.step_state,
        width
    )
    state.is_painting = true
    window.paint_menu_window(state.buf, state.win, state.layout, width)
    state.is_painting = false
end

local function move_menu_option(controller, state, target_index)
    local options = state.step_state.options or {}
    if state.step_state.is_loading or #options == 0 then
        return
    end
    state.step_state.selected_option_index = ((target_index - 1) % #options) + 1
    paint_menu_step(controller, state)
end

local function confirm_menu_step(controller, state, step)
    local options = state.step_state.options or {}
    if state.step_state.is_loading or #options == 0 then
        return
    end
    local selected_option = options[state.step_state.selected_option_index]
    if not selected_option then
        return
    end
    controller.commit_step_answer(state, step, selected_option.value, function(error_message)
        state.step_state.error_message = error_message
        paint_menu_step(controller, state)
    end)
end

local function step_back_from_menu(controller, state, step)
    local options = state.step_state.options or {}
    local selected_option = nil
    if not state.step_state.is_loading then
        selected_option = options[state.step_state.selected_option_index]
    end
    if selected_option ~= nil then
        controller.step_back_from_step(state, step, selected_option.value, true)
    else
        controller.step_back_from_step(state, step, nil, false)
    end
end

local function bind_menu_step_keys(controller, state, step)
    local map = function(lhs, handler)
        vim.keymap.set("n", lhs, handler, { buffer = state.buf, nowait = true, silent = true })
    end
    local move_down = function()
        move_menu_option(controller, state, state.step_state.selected_option_index + 1)
    end
    local move_up = function()
        move_menu_option(controller, state, state.step_state.selected_option_index - 1)
    end
    local jump_first = function()
        move_menu_option(controller, state, 1)
    end
    local jump_last = function()
        move_menu_option(controller, state, #(state.step_state.options or {}))
    end
    local go_back = function()
        step_back_from_menu(controller, state, step)
    end
    local confirm = function()
        confirm_menu_step(controller, state, step)
    end

    for _, lhs in ipairs({ "j", "<Down>" }) do map(lhs, move_down) end
    for _, lhs in ipairs({ "k", "<Up>" }) do map(lhs, move_up) end
    for _, lhs in ipairs({ "gg", "<Home>" }) do map(lhs, jump_first) end
    for _, lhs in ipairs({ "G", "<End>" }) do map(lhs, jump_last) end
    for _, lhs in ipairs({ "h", "<Left>", "<S-Tab>" }) do map(lhs, go_back) end
    for _, lhs in ipairs({ "<CR>", "l", "<Right>", "<Tab>" }) do map(lhs, confirm) end
    for _, lhs in ipairs({ "q", "<Esc>" }) do map(lhs, controller.close) end
end

local function apply_async_loaded_result(
    controller,
    state,
    step,
    request_id,
    loaded_options,
    error_message,
    empty_message
)
    if not controller.is_current_request(state, step.id, request_id) then
        return false
    end
    state.step_state.is_loading = false
    state.step_state.error_message = error_message
    state.step_state.empty_message = empty_message
    if type(loaded_options) == "table" and #loaded_options > 0 then
        local preferred = controller.get_preferred_step_value(step, state.answers, state.context)
        state.step_state.options = loaded_options
        state.step_state.selected_option_index = find_option_index_by_value(loaded_options, preferred)
    else
        state.step_state.options = {}
        state.step_state.selected_option_index = 1
    end
    paint_menu_step(controller, state)
    return true
end

local function start_async_step_load(controller, state, step)
    local request_id = controller.increment_request_id()
    local is_settled = false
    local function on_loaded(loaded_options, error_message, empty_message)
        if is_settled then
            return false
        end
        is_settled = true
        if vim.in_fast_event() then
            local is_matching = controller.is_request_matching(state, step.id, request_id)
            vim.schedule(function()
                apply_async_loaded_result(
                    controller,
                    state,
                    step,
                    request_id,
                    loaded_options,
                    error_message,
                    empty_message
                )
            end)
            return is_matching
        end
        return apply_async_loaded_result(
            controller,
            state,
            step,
            request_id,
            loaded_options,
            error_message,
            empty_message
        )
    end
    if type(step.load) ~= "function" then
        on_loaded(nil, "Async loader is missing.", nil)
        return
    end
    local is_ok, load_error = pcall(step.load, state.answers, state.context, on_loaded)
    if not is_ok then
        on_loaded(nil, tostring(load_error), nil)
    end
end

--- Opens a menu (`select`, `toggle`, or `async_select`) step inside the active wizard `state`.
--- @param controller table
--- @param state table
--- @param step table
function M.open(controller, state, step)
    state.step_state = create_menu_step_state(controller, step, state.answers, state.context, state.can_return_to_palette)
    local width = window.get_modal_width()
    state.layout = render.create_step_layout_from_state(
        state.command,
        state.active_steps,
        state.step_index,
        state.step_state,
        width
    )
    state.is_painting = true
    state.buf, state.win = window.create_menu_window(" " .. tostring(state.command.label) .. " ", state.layout, width)
    state.is_painting = false

    controller.register_cleanup_guards(state, state.buf, state.win)
    controller.register_cursor_hover_sync(
        state,
        function() return state.step_state.selected_option_index end,
        function(index) state.step_state.selected_option_index = index end,
        function() paint_menu_step(controller, state) end
    )
    bind_menu_step_keys(controller, state, step)
    if step.kind == "async_select" then
        start_async_step_load(controller, state, step)
    end
end

return M
