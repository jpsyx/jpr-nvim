-- Filterable command palette modal: stacked prompt + results windows, fuzzy filtering,
-- hover movement, activation, and Insert/Normal keybindings.
local fuzzy = require("jpr.tui.fuzzy")
local render = require("jpr.tui.render")
local schema = require("jpr.tui.schema")
local window = require("jpr.tui.wizard.window")

local M = {}

local function is_non_blank(text)
    return type(text) == "string" and text:match("%S") ~= nil
end

local function paint_palette(controller, state)
    if not controller.is_active(state) then
        return
    end
    local width = window.get_modal_width()
    state.layout = render.create_palette_layout_from_commands(
        state.commands,
        state.selected_index,
        width,
        state.context,
        { is_filtered = is_non_blank(state.query) }
    )
    state.is_painting = true
    window.paint_palette_results(state.buf, state.win, state.prompt_win, state.layout, width)
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

local function find_command_index(commands, target_command)
    for index, command in ipairs(commands) do
        if command == target_command or command.id == target_command.id then
            return index
        end
    end
    return 1
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
        palette_commands = state.all_commands,
        palette_index = find_command_index(state.all_commands, command),
        origin_win = state.origin_win,
    })
end

local function read_single_line_query(state)
    local prompt_buf = state.prompt_buf
    if not prompt_buf or not vim.api.nvim_buf_is_valid(prompt_buf) then
        return ""
    end
    local lines = vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false)
    if #lines <= 1 then
        return lines[1] or ""
    end
    local folded = render.to_single_line(table.concat(lines, " "))
    state.is_normalizing_prompt = true
    vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { folded })
    if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
        pcall(vim.api.nvim_win_set_cursor, state.prompt_win, { 1, #folded })
    end
    state.is_normalizing_prompt = false
    return folded
end

local function sync_filter_from_prompt(controller, state)
    if state.is_normalizing_prompt or not controller.is_active(state) then
        return
    end
    local next_query = read_single_line_query(state)
    local has_query_changed = next_query ~= state.query
    state.query = next_query
    window.paint_palette_prompt_decorations(state.prompt_buf, next_query == "")
    if not has_query_changed then
        return
    end
    state.commands = fuzzy.filter_commands(state.all_commands, next_query)
    state.selected_index = 1
    paint_palette(controller, state)
end

local function clear_filter_input(controller, state)
    if not controller.is_active(state) or not state.prompt_buf or not vim.api.nvim_buf_is_valid(state.prompt_buf) then
        return
    end
    state.is_normalizing_prompt = true
    vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { "" })
    if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
        pcall(vim.api.nvim_win_set_cursor, state.prompt_win, { 1, 0 })
    end
    state.is_normalizing_prompt = false
    sync_filter_from_prompt(controller, state)
end

local function ensure_palette_insert_mode(controller, state, target_win)
    if vim.fn.mode(1):sub(1, 1) == "i" then
        return
    end
    vim.schedule(function()
        if not controller.is_active(state) or state.prompt_win ~= target_win then
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

local function create_palette_actions(controller, state)
    local on_back = type(state.context and state.context.on_back) == "function" and state.context.on_back or nil
    return {
        move_down = function()
            sync_filter_from_prompt(controller, state)
            move_palette_selection(controller, state, state.selected_index + 1)
        end,
        move_up = function()
            sync_filter_from_prompt(controller, state)
            move_palette_selection(controller, state, state.selected_index - 1)
        end,
        jump_first = function()
            sync_filter_from_prompt(controller, state)
            move_palette_selection(controller, state, 1)
        end,
        jump_last = function()
            sync_filter_from_prompt(controller, state)
            move_palette_selection(controller, state, #state.commands)
        end,
        confirm = function()
            sync_filter_from_prompt(controller, state)
            activate_palette_command(controller, state)
        end,
        clear_filter = function() clear_filter_input(controller, state) end,
        go_back = on_back and function()
            controller.close()
            on_back()
        end or nil,
    }
end

local function bind_normal_palette_keys(buf, actions, close_fn)
    local map = function(lhs, handler)
        vim.keymap.set("n", lhs, handler, { buffer = buf, nowait = true, silent = true })
    end
    for _, lhs in ipairs({ "j", "<Down>", "<C-j>" }) do map(lhs, actions.move_down) end
    for _, lhs in ipairs({ "k", "<Up>", "<C-k>" }) do map(lhs, actions.move_up) end
    for _, lhs in ipairs({ "gg", "<Home>" }) do map(lhs, actions.jump_first) end
    for _, lhs in ipairs({ "G", "<End>" }) do map(lhs, actions.jump_last) end
    for _, lhs in ipairs({ "<CR>", "l", "<Right>", "<Tab>" }) do map(lhs, actions.confirm) end
    map("<C-u>", actions.clear_filter)
    if actions.go_back then
        for _, lhs in ipairs({ "h", "<Left>", "<S-Tab>" }) do map(lhs, actions.go_back) end
    end
    for _, lhs in ipairs({ "q", "<Esc>" }) do map(lhs, close_fn) end
end

local function bind_insert_palette_keys(prompt_buf, actions)
    local map = function(lhs, handler)
        vim.keymap.set("i", lhs, handler, { buffer = prompt_buf, nowait = true, silent = true })
    end
    for _, lhs in ipairs({ "<C-j>", "<Down>" }) do map(lhs, actions.move_down) end
    for _, lhs in ipairs({ "<C-k>", "<Up>" }) do map(lhs, actions.move_up) end
    map("<C-u>", actions.clear_filter)
    for _, lhs in ipairs({ "<CR>", "<Tab>" }) do map(lhs, actions.confirm) end
    if actions.go_back then
        map("<S-Tab>", actions.go_back)
    end
end

local function register_prompt_filter_autocmds(controller, state)
    vim.api.nvim_buf_attach(state.prompt_buf, false, {
        on_lines = function()
            if not controller.is_active(state) then
                return true
            end
            vim.schedule(function()
                sync_filter_from_prompt(controller, state)
            end)
            return false
        end,
    })
    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
        buffer = state.prompt_buf,
        callback = function()
            sync_filter_from_prompt(controller, state)
        end,
    })
end

--- Opens the filterable floating command palette at `initial_index`, preserving `preserved_origin_win` when given.
--- @param controller table
--- @param commands table[]
--- @param context table|nil
--- @param initial_index integer|nil
--- @param preserved_origin_win integer|nil
function M.open_at(controller, commands, context, initial_index, preserved_origin_win)
    local origin_win = controller.capture_origin_win(preserved_origin_win)
    controller.close()
    require("jpr").define_highlights()

    local current_context = context or {}
    local command_list = schema.get_active_commands(commands, current_context)
    local clamped_index = math.max(1, math.min(tonumber(initial_index) or 1, math.max(1, #command_list)))
    local width = window.get_modal_width()
    local layout = render.create_palette_layout_from_commands(command_list, clamped_index, width, current_context, { is_filtered = false })
    local title = (type(current_context.title) == "string" and current_context.title ~= "")
            and current_context.title
        or " Jpr Commands "

    local state = {
        kind = "palette",
        all_commands = command_list,
        commands = command_list,
        query = "",
        context = current_context,
        selected_index = clamped_index,
        layout = layout,
        origin_win = origin_win,
        is_painting = true,
        is_normalizing_prompt = false,
    }
    state.prompt_buf, state.prompt_win, state.buf, state.win = window.create_palette_windows(title, layout, width)
    controller.set_active_state(state)
    state.is_painting = false

    controller.register_cleanup_guards(state, state.buf, state.win)
    controller.register_cleanup_guards(state, state.prompt_buf, state.prompt_win)
    controller.register_cursor_hover_sync(
        state,
        function() return state.selected_index end,
        function(index) state.selected_index = index end,
        function() paint_palette(controller, state) end
    )
    local actions = create_palette_actions(controller, state)
    bind_normal_palette_keys(state.prompt_buf, actions, controller.close)
    bind_normal_palette_keys(state.buf, actions, controller.close)
    bind_insert_palette_keys(state.prompt_buf, actions)
    register_prompt_filter_autocmds(controller, state)
    ensure_palette_insert_mode(controller, state, state.prompt_win)
end

return M
