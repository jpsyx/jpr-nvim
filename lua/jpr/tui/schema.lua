-- Pure declarative command and wizard step schema validation and resolution.
-- Contains no window, buffer, or UI side effects.
local M = {}

--- Allowed wizard step kinds supported by the TUI engine.
M.VALID_STEP_KINDS = {
    select = true,
    async_select = true,
    toggle = true,
    text = true,
}

local function is_non_empty_string(value)
    return type(value) == "string" and value:match("%S") ~= nil
end

local function is_non_empty_option_value(value)
    if type(value) == "string" then
        return value:match("%S") ~= nil
    end
    return value ~= nil
end

local function validate_select_options(command_id, step)
    if type(step.options) ~= "table" or #step.options == 0 then
        return false, ("command %q step %q: select step requires a non-empty options list"):format(command_id, step.id)
    end
    for option_index, option in ipairs(step.options) do
        if type(option) ~= "table" then
            return false,
                ("command %q step %q option %d: expected table"):format(command_id, step.id, option_index)
        end
        if not is_non_empty_option_value(option.value) then
            return false,
                ("command %q step %q option %d: missing non-empty value"):format(command_id, step.id, option_index)
        end
        if not is_non_empty_string(option.label) then
            return false,
                ("command %q step %q option %d: missing non-empty label"):format(command_id, step.id, option_index)
        end
    end
    return true, nil
end

local function validate_step_kind_fields(command_id, step)
    if step.kind == "select" then
        return validate_select_options(command_id, step)
    end
    if step.kind == "async_select" and type(step.load) ~= "function" then
        return false, ("command %q step %q: async_select step requires a load function"):format(command_id, step.id)
    end
    if step.kind == "toggle" then
        if not is_non_empty_string(step.yes_label) then
            return false, ("command %q step %q: toggle step requires non-empty yes_label"):format(command_id, step.id)
        end
        if not is_non_empty_string(step.no_label) then
            return false, ("command %q step %q: toggle step requires non-empty no_label"):format(command_id, step.id)
        end
    end
    return true, nil
end

local function validate_step_spec(command_id, step, step_index, seen_step_ids)
    if type(step) ~= "table" then
        return false, ("command %q step %d: expected table"):format(command_id, step_index)
    end
    if not is_non_empty_string(step.id) then
        return false, ("command %q step %d: missing non-empty id"):format(command_id, step_index)
    end
    if seen_step_ids[step.id] then
        return false, ("command %q: duplicate step id %q"):format(command_id, step.id)
    end
    seen_step_ids[step.id] = true
    if not is_non_empty_string(step.label) then
        return false, ("command %q step %q: missing non-empty label"):format(command_id, step.id)
    end
    if not is_non_empty_string(step.help) then
        return false, ("command %q step %q: missing non-empty help"):format(command_id, step.id)
    end
    if M.VALID_STEP_KINDS[step.kind] ~= true then
        return false, ("command %q step %q: unknown step kind %q"):format(command_id, step.id, tostring(step.kind))
    end
    if step.when ~= nil and type(step.when) ~= "function" then
        return false, ("command %q step %q: when predicate must be a function"):format(command_id, step.id)
    end
    return validate_step_kind_fields(command_id, step)
end

local function validate_command_spec(command, command_index, seen_command_ids)
    if type(command) ~= "table" then
        return false, ("command %d: expected table"):format(command_index)
    end
    if not is_non_empty_string(command.id) then
        return false, ("command %d: missing non-empty id"):format(command_index)
    end
    if seen_command_ids[command.id] then
        return false, ("duplicate command id %q"):format(command.id)
    end
    seen_command_ids[command.id] = true
    if not is_non_empty_string(command.label) then
        return false, ("command %q: missing non-empty label"):format(command.id)
    end
    if not is_non_empty_string(command.help) then
        return false, ("command %q: missing non-empty help"):format(command.id)
    end
    if command.steps == nil then
        return true, nil
    end
    if type(command.steps) ~= "table" then
        return false, ("command %q: steps must be a list"):format(command.id)
    end
    local seen_step_ids = {}
    for step_index, step in ipairs(command.steps) do
        local is_valid, error_message = validate_step_spec(command.id, step, step_index, seen_step_ids)
        if not is_valid then
            return false, error_message
        end
    end
    return true, nil
end

--- Validates a list of declarative command specifications.
--- Returns `true, nil` when every command and step is valid, or `false, error_message`.
--- @param commands table[]
--- @return boolean, string|nil
function M.validate_command_specs(commands)
    if type(commands) ~= "table" or #commands == 0 then
        return false, "commands must be a non-empty list"
    end
    local seen_command_ids = {}
    for command_index, command in ipairs(commands) do
        local is_valid, error_message = validate_command_spec(command, command_index, seen_command_ids)
        if not is_valid then
            return false, error_message
        end
    end
    return true, nil
end

--- Resolves the ordered list of active steps for `command` given `answers` and `context`.
--- Keeps every step whose `when` predicate is absent or returns `true`.
--- @param command table
--- @param answers table|nil
--- @param context table|nil
--- @return table[]
function M.resolve_active_steps(command, answers, context)
    local active_steps = {}
    local current_answers = answers or {}
    local current_context = context or {}
    local steps = (command and command.steps) or {}
    for _, step in ipairs(steps) do
        if step.when == nil or step.when(current_answers, current_context) == true then
            active_steps[#active_steps + 1] = step
        end
    end
    return active_steps
end

--- Computes the default value for `step`, calling `step.default(answers, context)` when
--- it is a function or returning `step.default` directly otherwise.
--- @param step table|nil
--- @param answers table|nil
--- @param context table|nil
--- @return any
function M.get_default_value_from_step(step, answers, context)
    if step == nil then
        return nil
    end
    if type(step.default) == "function" then
        return step.default(answers or {}, context or {})
    end
    return step.default
end

--- Returns a copy of `answers` containing only keys belonging to active steps of `command`.
--- Iterates to a fixed point so transitive `when` branches prune cleanly without mutating `answers`.
--- @param command table
--- @param answers table|nil
--- @param context table|nil
--- @return table
function M.prune_inactive_answers(command, answers, context)
    local current = {}
    for key, value in pairs(answers or {}) do
        current[key] = value
    end
    while true do
        local active_steps = M.resolve_active_steps(command, current, context)
        local active_step_ids = {}
        for _, step in ipairs(active_steps) do
            active_step_ids[step.id] = true
        end
        local pruned = {}
        local has_removed = false
        for key, value in pairs(current) do
            if active_step_ids[key] then
                pruned[key] = value
            else
                has_removed = true
            end
        end
        if not has_removed then
            return pruned
        end
        current = pruned
    end
end

--- Builds the shared two-option list for a `toggle` step so renderer and wizard agree.
--- @param step table
--- @return table[]
function M.create_toggle_options_from_step(step)
    return {
        { value = false, label = step.no_label, help = step.no_help },
        { value = true, label = step.yes_label, help = step.yes_help },
    }
end

return M
