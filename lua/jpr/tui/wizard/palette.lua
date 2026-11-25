-- Command palette modal rendering, hover movement, activation, and keybindings.
local render = require("jpr.tui.render")
local schema = require("jpr.tui.schema")
local window = require("jpr.tui.wizard.window")

local M = {}

local function paint_palette(controller, state)
    if not controller.is_active(state) then
        return
    end
    local width = window.get_modal_width()
    state.layout = render.create_palette_layout_from_commands(
        state.commands,
        state.selected_index,
        width,
        state.context
    )
    state.is_painting = true
    window.paint_menu_window(state.buf, state.win, state.layout, width)
    state.is_painting = false
end

local function move_palette_selection(controller, state, target_index)
    local command_count = #state.commands
    if command_count == 0 then
        return
    end
    state.selected_index = ((target_index - 1) % command_count) + 1
    paint_palette(controller, state)
end

local function activate_palette_command(controller, state)
    local command = state.commands[state.selected_index]
    if not command then
        return
    end
    local active_steps = schema.get_active_steps_from_command(command, {}, state.context)
    if #active_steps == 0 then
        local context = state.context
        controller.close()
        if type(command.execute) == "function" then
            command.execute({}, context)
        end
        return
    end
    controller.open_command(command, {}, state.context, {
        can_return_to_palette = true,
        palette_commands = state.commands,
        palette_index = state.selected_index,
        origin_win = state.origin_win,
    })
end

local function bind_palette_keys(controller, state)
    local map = function(lhs, handler)
        vim.keymap.set("n", lhs, handler, { buffer = state.buf, nowait = true, silent = true })
    end
    local move_down = function()
        move_palette_selection(controller, state, state.selected_index + 1)
    end
    local move_up = function()
        move_palette_selection(controller, state, state.selected_index - 1)
    end
    local jump_first = function()
        move_palette_selection(controller, state, 1)
    end
    local jump_last = function()
        move_palette_selection(controller, state, #state.commands)
    end
    local confirm = function()
        activate_palette_command(controller, state)
    end

    for _, lhs in ipairs({ "j", "<Down>" }) do map(lhs, move_down) end
    for _, lhs in ipairs({ "k", "<Up>" }) do map(lhs, move_up) end
    for _, lhs in ipairs({ "gg", "<Home>" }) do map(lhs, jump_first) end
    for _, lhs in ipairs({ "G", "<End>" }) do map(lhs, jump_last) end
    for _, lhs in ipairs({ "<CR>", "l", "<Right>", "<Tab>" }) do map(lhs, confirm) end
    if type(state.context and state.context.on_back) == "function" then
        local go_back = function()
            local on_back = state.context.on_back
            controller.close()
            on_back()
        end
        for _, lhs in ipairs({ "h", "<Left>", "<S-Tab>" }) do map(lhs, go_back) end
    end
    for _, lhs in ipairs({ "q", "<Esc>" }) do map(lhs, controller.close) end
end

--- Opens the floating command palette at `initial_index`, preserving `preserved_origin_win` when given.
--- @param controller table
--- @param commands table[]
--- @param context table|nil
--- @param initial_index integer|nil
--- @param preserved_origin_win integer|nil
function M.open_at(controller, commands, context, initial_index, preserved_origin_win)
    local origin_win = controller.capture_origin_win(preserved_origin_win)
    controller.close()
    require("jpr").define_highlights()

    local command_list = commands or {}
    local current_context = context or {}
    local clamped_index = math.max(1, math.min(tonumber(initial_index) or 1, math.max(1, #command_list)))
    local width = window.get_modal_width()
    local layout = render.create_palette_layout_from_commands(command_list, clamped_index, width, current_context)
    local title = (type(current_context.title) == "string" and current_context.title ~= "")
            and current_context.title
        or " Jpr Commands "

    local state = {
        kind = "palette",
        commands = command_list,
        context = current_context,
        selected_index = clamped_index,
        layout = layout,
        origin_win = origin_win,
        is_painting = true,
    }
    state.buf, state.win = window.create_menu_window(title, layout, width)
    controller.set_active_state(state)
    state.is_painting = false

    controller.register_cleanup_guards(state, state.buf, state.win)
    controller.register_cursor_hover_sync(
        state,
        function() return state.selected_index end,
        function(index) state.selected_index = index end,
        function() paint_palette(controller, state) end
    )
    bind_palette_keys(controller, state)
end

return M
