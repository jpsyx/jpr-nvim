local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local helpers = dofile(root .. "/tests/lua/support/helpers.lua")
local wizard = require("jpr.tui.wizard")

local function read_virt_lines_above(buf)
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    local texts, groups = {}, {}
    for _, mark in ipairs(marks) do
        local details = mark[4]
        if details and details.virt_lines_above and type(details.virt_lines) == "table" then
            for _, line_chunks in ipairs(details.virt_lines) do
                local parts = {}
                for _, chunk in ipairs(line_chunks) do
                    parts[#parts + 1] = chunk[1]
                    if chunk[2] then
                        groups[chunk[2]] = true
                    end
                end
                texts[#texts + 1] = table.concat(parts)
            end
        end
    end
    return table.concat(texts, "\n"), groups
end

local function win_footer(win)
    local footer = vim.api.nvim_win_get_config(win).footer
    if type(footer) == "string" then
        return footer
    end
    if type(footer) == "table" then
        local parts = {}
        for _, chunk in ipairs(footer) do
            parts[#parts + 1] = chunk[1]
        end
        return table.concat(parts)
    end
    return ""
end

local function has_buffer_highlight_group(buf, target_group, expected_text)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    for _, mark in ipairs(marks) do
        local details = mark[4]
        if details and details.hl_group == target_group then
            local line_text = lines[mark[2] + 1] or ""
            local highlighted = line_text:sub(mark[3] + 1, details.end_col or #line_text)
            if not expected_text or highlighted:find(expected_text, 1, true) ~= nil then
                return true
            end
        end
    end
    return false
end

local function create_branch_commands(on_execute)
    return {
        { id = "other", label = "Other Action", help = "Unrelated first command.", execute = function() end },
        {
            id = "branch_command",
            label = "Configure Target",
            help = "Choose automatic or custom target.",
            steps = {
                {
                    id = "mode",
                    label = "Target Mode",
                    help = "Select automatic detection or enter a custom value.",
                    kind = "select",
                    default = "auto",
                    options = {
                        { value = "auto", label = "Automatic", help = "Use the default target." },
                        { value = "custom", label = "Custom", help = "Enter a custom target name." },
                    },
                },
                {
                    id = "custom_value",
                    label = "Custom Value",
                    help = "Type the custom target identifier.",
                    kind = "text",
                    default = "default-val",
                    when = function(answers) return answers.mode == "custom" end,
                },
            },
            execute = on_execute,
        },
    }
end

local function create_text_validation_command(on_execute)
    return {
        id = "manual",
        label = "Enter PR",
        help = "Type a pull request number.",
        steps = {
            {
                id = "pr_number",
                label = "PR Number",
                help = "Enter a positive integer PR number.",
                kind = "text",
                default = "bad",
                validate = function(value)
                    if not tostring(value):match("^%d+$") then
                        return false, "PR number must contain digits only."
                    end
                    return true
                end,
            },
        },
        execute = on_execute,
    }
end

local context = {
    helpers = helpers,
    wizard = wizard,
    read_virt_lines_above = read_virt_lines_above,
    win_footer = win_footer,
    has_buffer_highlight_group = has_buffer_highlight_group,
    create_branch_commands = create_branch_commands,
    create_text_validation_command = create_text_validation_command,
}

dofile(root .. "/tests/lua/tui_wizard_spec/palette.lua")(context)
dofile(root .. "/tests/lua/tui_wizard_spec/navigation_and_text.lua")(context)
dofile(root .. "/tests/lua/tui_wizard_spec/async_and_lifecycle.lua")(context)

print("tui_wizard_spec: ok")
