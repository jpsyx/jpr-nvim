-- Pure layout builder for the Neovim command palette and step-by-step wizard.
-- Contains no window, buffer, or extmark side effects.
local schema = require("jpr.tui.schema")

local M = {}

local SELECTED_PREFIX = "▸ "
local UNSELECTED_PREFIX = "  "
local HELP_INDENT = "    "
local PALETTE_FOOTER = "[j/k] move  [Enter/l] select  [q/Esc] close"

local function to_single_line(text)
    return (tostring(text or ""):gsub("[\r\n]+", " "))
end

local function is_non_blank_string(value)
    return type(value) == "string" and value:match("%S") ~= nil
end

local function clamp_index(index, total_count)
    if total_count <= 0 then
        return 1
    end
    local numeric_index = tonumber(index) or 1
    return math.max(1, math.min(numeric_index, total_count))
end

local function append_highlight(highlights, line_index, col_start, col_end, group)
    if group and col_end > col_start then
        highlights[#highlights + 1] = {
            line = line_index,
            col_start = col_start,
            col_end = col_end,
            group = group,
        }
    end
end

local function append_line(layout, text, group)
    layout.lines[#layout.lines + 1] = text
    local row_number = #layout.lines
    if group then
        append_highlight(layout.highlights, row_number - 1, 0, #text, group)
    end
    return row_number
end

local function split_overlong_word(word, limit)
    local chunks = {}
    local char_count = vim.fn.strchars(word)
    local current_chunk = ""
    local current_width = 0
    for char_index = 0, char_count - 1 do
        local character = vim.fn.strcharpart(word, char_index, 1)
        local char_width = vim.fn.strdisplaywidth(character)
        if current_chunk ~= "" and current_width + char_width > limit then
            chunks[#chunks + 1] = current_chunk
            current_chunk = character
            current_width = char_width
        else
            current_chunk = current_chunk .. character
            current_width = current_width + char_width
        end
    end
    if current_chunk ~= "" then
        chunks[#chunks + 1] = current_chunk
    end
    return chunks
end

local function append_word_chunks(wrapped_lines, word, word_width, limit)
    if word_width <= limit then
        return word, word_width
    end
    local chunks = split_overlong_word(word, limit)
    for chunk_index = 1, #chunks - 1 do
        wrapped_lines[#wrapped_lines + 1] = chunks[chunk_index]
    end
    local last_chunk = chunks[#chunks] or ""
    return last_chunk, vim.fn.strdisplaywidth(last_chunk)
end

--- Wraps `text` onto lines of at most `math.max(1, max_width)` display columns.
--- Breaks on whitespace where possible and hard-splits overlong words on UTF-8 boundaries.
--- @param text string|nil
--- @param max_width integer
--- @return string[]
function M.wrap_text(text, max_width)
    local limit = math.max(1, tonumber(max_width) or 1)
    local wrapped_lines = {}
    local current_line = ""
    local current_width = 0
    for word in tostring(text or ""):gmatch("%S+") do
        local word_width = vim.fn.strdisplaywidth(word)
        if current_width == 0 then
            current_line, current_width = append_word_chunks(wrapped_lines, word, word_width, limit)
        elseif current_width + 1 + word_width <= limit then
            current_line = current_line .. " " .. word
            current_width = current_width + 1 + word_width
        else
            wrapped_lines[#wrapped_lines + 1] = current_line
            current_line, current_width = append_word_chunks(wrapped_lines, word, word_width, limit)
        end
    end
    if current_line ~= "" or #wrapped_lines == 0 then
        wrapped_lines[#wrapped_lines + 1] = current_line
    end
    return wrapped_lines
end

local function append_wrapped_lines(layout, text, indent, max_width, group, item_index)
    if not is_non_blank_string(text) then
        return
    end
    local indent_width = vim.fn.strdisplaywidth(indent)
    local available_width = math.max(1, max_width - indent_width)
    for _, wrapped_line in ipairs(M.wrap_text(text, available_width)) do
        local row_number = append_line(layout, indent .. wrapped_line, group)
        if item_index ~= nil then
            layout.item_for_line[row_number] = item_index
        end
    end
end

local function append_palette_command(layout, command, command_index, is_selected, has_session, max_width)
    local prefix = is_selected and SELECTED_PREFIX or UNSELECTED_PREFIX
    local label = to_single_line(command.label)
    local id_tag = "[" .. to_single_line(command.id) .. "]"
    local row_text = prefix .. label .. "  " .. id_tag
    local row_number = append_line(layout, row_text, nil)
    local line_index = row_number - 1

    layout.item_for_line[row_number] = command_index
    if is_selected then
        layout.cursor_line = row_number
        append_highlight(layout.highlights, line_index, 0, #prefix, "JprTitle")
    end
    if command.requires_session and not has_session then
        append_highlight(layout.highlights, line_index, #prefix, #prefix + #label, "JprMuted")
    end
    local id_col_start = #prefix + #label + 2
    append_highlight(layout.highlights, line_index, id_col_start, id_col_start + #id_tag, "JprMuted")

    if is_selected then
        append_wrapped_lines(layout, command.help, HELP_INDENT, max_width, "JprMuted", command_index)
    end
end

--- Builds lines, byte-range highlights, cursor row, and line-to-item map for the command palette.
--- Emits 1-sentence helper text strictly underneath the currently selected command.
--- @param commands table[]
--- @param selected_index integer
--- @param max_width integer
--- @param context table|nil
--- @return table { lines: string[], highlights: table[], cursor_line: integer, item_for_line: table<integer, integer> }
function M.build_palette_layout(commands, selected_index, max_width, context)
    local layout = { lines = {}, highlights = {}, cursor_line = 1, item_for_line = {} }
    local command_list = commands or {}
    local width = math.max(1, tonumber(max_width) or 80)
    local has_session = (context and context.has_session) == true

    if #command_list == 0 then
        layout.cursor_line = append_line(layout, "  (no commands available)", "JprMuted")
    else
        local clamped_selected = clamp_index(selected_index, #command_list)
        for command_index, command in ipairs(command_list) do
            append_palette_command(layout, command, command_index, command_index == clamped_selected, has_session, width)
        end
    end

    append_line(layout, "", nil)
    append_line(layout, PALETTE_FOOTER, "JprMuted")
    return layout
end

local function append_step_header(layout, step, step_index, total_steps, max_width)
    local heading = ("Step %d of %d · %s"):format(step_index, total_steps, to_single_line(step.label))
    local dot_parts = {}
    for dot_index = 1, total_steps do
        dot_parts[dot_index] = dot_index <= step_index and "●" or "○"
    end
    local header_text = heading .. "  " .. table.concat(dot_parts, " ")
    local row_number = append_line(layout, header_text, nil)
    local line_index = row_number - 1

    append_highlight(layout.highlights, line_index, 0, #heading, "JprTitle")
    local byte_offset = #heading + 2
    for dot_index, dot_symbol in ipairs(dot_parts) do
        local dot_group = dot_index <= step_index and "JprTitle" or "JprMuted"
        append_highlight(layout.highlights, line_index, byte_offset, byte_offset + #dot_symbol, dot_group)
        byte_offset = byte_offset + #dot_symbol + 1
    end

    append_wrapped_lines(layout, step.help, "", max_width, "JprMuted", nil)
end

local function resolve_step_options(step, step_state)
    if step_state.options ~= nil then
        return step_state.options
    end
    if step.kind == "toggle" then
        return schema.create_toggle_options_from_step(step)
    end
    if step.kind == "select" then
        return step.options or {}
    end
    return {}
end

local function append_step_option(layout, option, option_index, is_selected, max_width)
    local prefix = is_selected and SELECTED_PREFIX or UNSELECTED_PREFIX
    local label = to_single_line(option.label)
    local has_badge = is_non_blank_string(option.badge)
    local badge = has_badge and to_single_line(option.badge) or nil
    local row_text = badge and (prefix .. label .. "  " .. badge) or (prefix .. label)
    local row_number = append_line(layout, row_text, nil)
    local line_index = row_number - 1

    layout.item_for_line[row_number] = option_index
    if is_selected then
        layout.cursor_line = row_number
        append_highlight(layout.highlights, line_index, 0, #prefix, "JprTitle")
    end
    if badge then
        local badge_col_start = #prefix + #label + 2
        append_highlight(layout.highlights, line_index, badge_col_start, badge_col_start + #badge, "JprMuted")
    end
    if is_selected then
        append_wrapped_lines(layout, option.help, HELP_INDENT, max_width, "JprMuted", option_index)
    end
end

local function append_step_body(layout, step, step_state, max_width)
    if step_state.is_loading then
        layout.cursor_line = append_line(layout, "  Loading...", "JprMuted")
        return
    end
    local options = resolve_step_options(step, step_state)
    if #options == 0 then
        local empty_text = is_non_blank_string(step_state.empty_message) and to_single_line(step_state.empty_message)
            or "  (no options available)"
        layout.cursor_line = append_line(layout, empty_text, "JprMuted")
        return
    end
    local clamped_option = clamp_index(step_state.selected_option_index, #options)
    for option_index, option in ipairs(options) do
        append_step_option(layout, option, option_index, option_index == clamped_option, max_width)
    end
end

local function build_back_hint(step_index, can_return_to_palette, key_label)
    if step_index == 1 and can_return_to_palette then
        return key_label .. " palette"
    end
    if step_index > 1 then
        return key_label .. " back"
    end
    return nil
end

local function build_step_footer(step_index, total_steps, can_return_to_palette)
    local confirm_hint = step_index == total_steps and "[Enter/l] run" or "[Enter/l] next"
    local back_hint = build_back_hint(step_index, can_return_to_palette, "[h]")
    if back_hint then
        return "[j/k] move  " .. back_hint .. "  " .. confirm_hint .. "  [q/Esc] close"
    end
    return "[j/k] move  " .. confirm_hint .. "  [q/Esc] close"
end

--- Builds lines, highlights, cursor row, and line-to-option map for a menu/toggle/async step.
--- Emits option helper text strictly underneath the currently selected option.
--- @param command table
--- @param active_steps table[]
--- @param step_index integer
--- @param step_state table|nil
--- @param max_width integer
--- @return table { lines: string[], highlights: table[], cursor_line: integer, item_for_line: table<integer, integer> }
function M.build_step_layout(command, active_steps, step_index, step_state, max_width)
    local layout = { lines = {}, highlights = {}, cursor_line = 1, item_for_line = {} }
    local steps = active_steps or {}
    local total_steps = #steps
    local width = math.max(1, tonumber(max_width) or 80)
    if total_steps == 0 then
        local title = command and to_single_line(command.label) or ""
        append_line(layout, title, "JprTitle")
        return layout
    end

    local clamped_step = clamp_index(step_index, total_steps)
    local step = steps[clamped_step]
    local state = step_state or {}

    append_step_header(layout, step, clamped_step, total_steps, width)
    append_line(layout, "", nil)
    if is_non_blank_string(state.error_message) then
        append_wrapped_lines(layout, state.error_message, "", width, "JprError", nil)
        append_line(layout, "", nil)
    end
    append_step_body(layout, step, state, width)
    append_line(layout, "", nil)
    append_line(layout, build_step_footer(clamped_step, total_steps, state.can_return_to_palette == true), "JprMuted")
    return layout
end

--- Builds Neovim `virt_lines` tuples for `virt_lines_above = true` on line 0 of text steps.
--- Includes wrapped step helper text, optional validation error, and a trailing blank separator.
--- @param step table|nil
--- @param error_message string|nil
--- @param max_width integer
--- @return table[]
function M.build_text_step_virt_lines(step, error_message, max_width)
    local width = math.max(1, tonumber(max_width) or 80)
    local virt_lines = {}
    if step and is_non_blank_string(step.help) then
        for _, wrapped_line in ipairs(M.wrap_text(step.help, width)) do
            virt_lines[#virt_lines + 1] = { { wrapped_line, "JprMuted" } }
        end
    end
    if is_non_blank_string(error_message) then
        if #virt_lines > 0 then
            virt_lines[#virt_lines + 1] = { { "", "JprMuted" } }
        end
        for _, wrapped_error in ipairs(M.wrap_text(error_message, width)) do
            virt_lines[#virt_lines + 1] = { { wrapped_error, "JprError" } }
        end
    end
    virt_lines[#virt_lines + 1] = { { "", "JprMuted" } }
    return virt_lines
end

--- Builds the contextual window footer string for text-input wizard steps.
--- @param step_index integer
--- @param total_steps integer
--- @param can_return_to_palette boolean
--- @return string
function M.build_text_step_footer(step_index, total_steps, can_return_to_palette)
    local clamped_total = math.max(1, tonumber(total_steps) or 1)
    local clamped_index = clamp_index(step_index, clamped_total)
    local confirm_hint = clamped_index == clamped_total and "[Enter/Tab] run" or "[Enter/Tab] next"
    local back_hint = build_back_hint(clamped_index, can_return_to_palette == true, "[S-Tab]")
    if back_hint then
        return confirm_hint .. "  " .. back_hint .. "  [Esc] normal/cancel"
    end
    return confirm_hint .. "  [Esc] normal/cancel"
end

return M
