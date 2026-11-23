local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local helpers = dofile(root .. "/tests/lua/support/helpers.lua")
local wizard = require("jpr.tui.wizard")

local function current_float_win()
    local win = vim.api.nvim_get_current_win()
    local config = vim.api.nvim_win_get_config(win)
    assert(config.relative and config.relative ~= "", "expected current window to be a floating window")
    return win
end

local function current_lines()
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(current_float_win()), 0, -1, false)
end

local function current_text()
    return table.concat(current_lines(), "\n")
end

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

local function create_palette_commands(executed_calls)
    local function record(id)
        return function(answers, context)
            executed_calls[#executed_calls + 1] = { id = id, answers = answers, context = context }
        end
    end
    return {
        { id = "open", label = "Open Pull Request", help = "Pick an open pull request or enter a PR number.", execute = record("open") },
        { id = "sync", label = "Sync with GitHub", help = "Fetch the latest pull request commits and review threads.", requires_session = true, execute = record("sync") },
        { id = "close", label = "Close Review", help = "Shut down the active review session and close buffers.", requires_session = true, execute = record("close") },
    }
end

local function test_palette_window_and_hover_navigation()
    local executed_calls = {}
    local commands = create_palette_commands(executed_calls)
    wizard.open_palette(commands, { has_session = false, title = " Jpr Palette " })
    assert(wizard.is_open() == true, "palette opens")

    local win = current_float_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local config = vim.api.nvim_win_get_config(win)
    assert(helpers.win_title(win) == " Jpr Palette ", "uses custom context title")
    assert(vim.bo[buf].filetype == "jpr-tui" and vim.bo[buf].buftype == "nofile", "palette buffer options")
    assert(vim.bo[buf].modifiable == false and vim.wo[win].cursorline == true and vim.wo[win].wrap == false, "palette window options")
    assert(vim.deep_equal(config.border, { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }), "palette rounded border")

    local text_first = current_text()
    assert(text_first:find("Pick an open pull request", 1, true) ~= nil, "command 1 help visible initially")
    assert(text_first:find("Fetch the latest pull request", 1, true) == nil, "command 2 help hidden initially")

    helpers.press_key("j")
    assert(current_text():find("▸ Sync with GitHub", 1, true) ~= nil, "j moves selection to command 2")
    assert(current_text():find("Fetch the latest pull request", 1, true) ~= nil, "command 2 help visible on hover")
    assert(current_text():find("Pick an open pull request", 1, true) == nil, "command 1 help hidden when not hovered")

    helpers.press_key("k")
    assert(current_text():find("▸ Open Pull Request", 1, true) ~= nil, "k moves selection back to command 1")
    helpers.press_key("k")
    assert(current_text():find("▸ Close Review", 1, true) ~= nil, "k wraps from first command to last")
    helpers.press_key("j")
    assert(current_text():find("▸ Open Pull Request", 1, true) ~= nil, "j wraps from last command to first")
    helpers.press_key("G")
    assert(current_text():find("▸ Close Review", 1, true) ~= nil, "G jumps to last command")
    helpers.press_key("gg")
    assert(current_text():find("▸ Open Pull Request", 1, true) ~= nil, "gg jumps to first command")
    wizard.close()
    assert(#executed_calls == 0, "closing without confirm does not execute")
end

local function test_palette_cursor_sync_and_cancel()
    local executed_calls = {}
    local commands = create_palette_commands(executed_calls)
    wizard.open_palette(commands, { has_session = true })
    local win = current_float_win()
    local buf = vim.api.nvim_win_get_buf(win)
    assert(helpers.win_title(win) == " Jpr Commands ", "default palette title")

    local sync_row = helpers.find_line_number(current_lines(), "Sync with GitHub")
    assert(sync_row ~= nil, "found sync command row")
    vim.api.nvim_win_set_cursor(win, { sync_row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    assert(current_text():find("▸ Sync with GitHub", 1, true) ~= nil, "CursorMoved selects hovered command")
    assert(current_text():find("Fetch the latest pull request", 1, true) ~= nil, "CursorMoved swaps helper text")

    helpers.press_key("q")
    assert(wizard.is_open() == false and #executed_calls == 0, "q closes palette without execute")

    wizard.open_palette(commands, { has_session = true })
    helpers.press_key("<Esc>")
    assert(wizard.is_open() == false and #executed_calls == 0, "<Esc> closes palette without execute")
end

local function test_zero_step_command_execution()
    local received = {}
    local commands = {
        {
            id = "sync",
            label = "Sync with GitHub",
            help = "Fetch the latest commits and comments.",
            execute = function(answers, context)
                received[#received + 1] = { answers = answers, context = context }
            end,
        },
    }
    local context = { has_session = true, marker = "ctx-1" }

    wizard.open_palette(commands, context)
    helpers.press_key("<CR>")
    assert(wizard.is_open() == false and #received == 1, "<CR> on 0-step command closes and executes")
    assert(vim.deep_equal(received[1].answers, {}) and received[1].context.marker == "ctx-1", "0-step receives empty answers + context")

    wizard.open_command(commands[1], { stale = "ignored" }, context)
    assert(wizard.is_open() == false and #received == 2, "direct open_command on 0-step command executes immediately")
    assert(vim.deep_equal(received[2].answers, {}), "stale answers pruned on direct 0-step execution")
end

local function create_branch_commands(on_execute)
    return {
        { id = "other", label = "Other Action", help = "Unrelated first command.", execute = function() end },
        {
            id = "branch_cmd",
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

local function test_discriminant_stepper_back_and_pruning()
    local executed_answers = nil
    local commands = create_branch_commands(function(answers) executed_answers = answers end)

    wizard.open_palette(commands, {})
    helpers.press_key("j")
    helpers.press_key("<CR>")
    assert(helpers.win_title(current_float_win()) == " Configure Target ", "step menu title uses command label")
    assert(current_text():find("Step 1 of 1", 1, true) ~= nil, "discriminant starts as Step 1 of 1")
    assert(current_text():find("▸ Automatic", 1, true) ~= nil, "default option preselected")

    helpers.press_key("h")
    assert(wizard.is_open() and current_text():find("▸ Configure Target", 1, true) ~= nil, "h returns to palette on originating command")

    helpers.press_key("<CR>")
    helpers.press_key("j")
    helpers.press_key("l")
    local step2_win = current_float_win()
    local step2_buf = vim.api.nvim_win_get_buf(step2_win)
    assert(vim.bo[step2_buf].filetype == "jpr-tui-input" and vim.bo[step2_buf].modifiable == true, "text step buffer editable")
    assert(vim.wo[step2_win].cursorline == false, "text step disables cursorline")
    assert(helpers.win_title(step2_win):find("Step 2 of 2", 1, true) ~= nil, "text step title shows Step 2 of 2")
    assert(win_footer(step2_win):find("[S-Tab] back", 1, true) ~= nil, "text step footer shows back hint")
    assert(vim.api.nvim_buf_get_lines(step2_buf, 0, -1, false)[1] == "default-val", "line 1 prefilled with default")
    assert(read_virt_lines_above(step2_buf):find("Type the custom target identifier.", 1, true) ~= nil, "virt_lines_above shows step help")

    helpers.press_key("<S-Tab>")
    assert(wizard.is_open() and current_text():find("▸ Custom", 1, true) ~= nil, "<S-Tab> returns to Step 1 with Custom highlighted")
    helpers.press_key("k")
    helpers.press_key("<CR>")
    assert(wizard.is_open() == false, "confirming final step closes wizard")
    assert(vim.deep_equal(executed_answers, { mode = "auto" }), "stale custom_value pruned: " .. vim.inspect(executed_answers))
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

local function test_text_validation_and_escape_behavior()
    local executed_answers = nil
    local command = create_text_validation_command(function(answers) executed_answers = answers end)

    wizard.open_command(command, {}, {})
    local buf = vim.api.nvim_win_get_buf(current_float_win())
    assert(helpers.has_buf_map(buf, "i", "<CR>") and helpers.has_buf_map(buf, "i", "<Tab>") and helpers.has_buf_map(buf, "i", "<S-Tab>"), "insert maps set")
    assert(not helpers.has_buf_map(buf, "i", "<Esc>") and helpers.has_buf_map(buf, "n", "<Esc>") and helpers.has_buf_map(buf, "n", "q"), "escape/quit maps set")

    helpers.press_key("A<CR>")
    assert(wizard.is_open() == true and executed_answers == nil, "validation error keeps text modal open")
    local virt_text, virt_groups = read_virt_lines_above(buf)
    assert(virt_text:find("PR number must contain digits only.", 1, true) ~= nil and virt_groups.JprError == true, "validation error rendered with JprError")

    helpers.press_key("A<Esc>")
    assert(wizard.is_open() == true and vim.fn.mode(1):sub(1, 1) == "n", "Insert-mode <Esc> drops to Normal without closing")
    helpers.press_key("ciw42<Esc>")
    assert(wizard.is_open() == true and vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "42", "Vim ciw edits line 1")
    helpers.press_key("<CR>")
    assert(wizard.is_open() == false and vim.deep_equal(executed_answers, { pr_number = "42" }), "Normal-mode <CR> submits fixed value")

    executed_answers = nil
    wizard.open_command(command, {}, {})
    helpers.press_key("A<Esc>ciw99<CR>")
    assert(wizard.is_open() == false and vim.deep_equal(executed_answers, { pr_number = "99" }), "Insert-mode <CR> submits edited value")

    executed_answers = nil
    wizard.open_command(command, {}, {})
    helpers.press_key("<Esc>")
    assert(wizard.is_open() == false and executed_answers == nil, "Normal-mode <Esc> cancels text modal")
    wizard.open_command(command, {}, {})
    helpers.press_key("q")
    assert(wizard.is_open() == false and executed_answers == nil, "Normal-mode q cancels text modal")
end

local function create_async_pr_command(on_load, on_execute)
    return {
        id = "open_pr",
        label = "Open Pull Request",
        help = "Pick a pull request from GitHub.",
        steps = {
            {
                id = "source",
                label = "Pull Request Source",
                help = "Choose how to select a pull request.",
                kind = "select",
                default = "list",
                options = {
                    { value = "list", label = "Pick from Open PRs", help = "Load open PRs from GitHub." },
                    { value = "manual", label = "Enter PR Number", help = "Type a PR number." },
                },
            },
            {
                id = "pr",
                label = "Open Pull Requests",
                help = "Pick a pull request to open.",
                kind = "async_select",
                when = function(answers) return answers.source == "list" end,
                load = on_load,
            },
        },
        execute = on_execute,
    }
end

local function test_async_select_loading_and_selection()
    local executed_answers, pending_callback = nil, nil
    local command = create_async_pr_command(
        function(_answers, _context, on_loaded) pending_callback = on_loaded end,
        function(answers) executed_answers = answers end
    )

    local caller_answers = { source = "list" }
    wizard.open_command(command, caller_answers, {}, { start_step_id = "pr" })
    assert(wizard.is_open() == true and current_text():find("Loading...", 1, true) ~= nil, "renders Loading... immediately")
    helpers.press_key("<CR>")
    assert(wizard.is_open() == true and executed_answers == nil, "<CR> while loading is a no-op")

    pending_callback({
        { value = "101", label = "#101 Fix auth", help = "By alice" },
        { value = "202", label = "#202 Add TUI", help = "By bob" },
    })
    assert(current_text():find("▸ #101 Fix auth", 1, true) ~= nil, "loaded options render")
    helpers.press_key("j")
    helpers.press_key("<CR>")
    assert(wizard.is_open() == false, "confirming async option closes modal")
    assert(vim.deep_equal(executed_answers, { source = "list", pr = "202" }), "execute receives option 2 value")
    assert(vim.deep_equal(caller_answers, { source = "list" }), "caller initial_answers not mutated")
end

local function test_async_empty_back_and_stale_close()
    local pending_callback = nil
    local command = create_async_pr_command(
        function(_answers, _context, on_loaded) pending_callback = on_loaded end,
        function() end
    )

    wizard.open_command(command, { source = "list" }, {}, { start_step_id = "pr" })
    pending_callback({}, nil, "No open pull requests found.")
    assert(current_text():find("No open pull requests found.", 1, true) ~= nil, "empty_message rendered")
    helpers.press_key("h")
    assert(wizard.is_open() and current_text():find("Pull Request Source", 1, true) ~= nil, "h returns to Step 1 from empty list")
    assert(current_text():find("▸ Pick from Open PRs", 1, true) ~= nil, "Step 1 retains prefilled selection")
    wizard.close()

    pending_callback = nil
    wizard.open_command(command, { source = "list" }, {}, { start_step_id = "pr" })
    local stale_callback = pending_callback
    wizard.close()
    assert(wizard.is_open() == false, "wizard.close() closes modal")
    stale_callback({ { value = "999", label = "#999 Late PR", help = "Should be ignored." } })
    assert(wizard.is_open() == false, "stale async callback after close does not reopen modal")
end

local function create_toggle_command(on_execute)
    return {
        id = "toggle_demo",
        label = "Toggle Demo",
        help = "Exercises toggle defaults and prefilled skipping.",
        steps = {
            {
                id = "first",
                label = "First Step",
                help = "Choose first option.",
                kind = "select",
                options = {
                    { value = "a", label = "Option A", help = "Help A." },
                    { value = "b", label = "Option B", help = "Help B." },
                },
            },
            {
                id = "include_drafts",
                label = "Include Drafts",
                help = "Choose whether to include drafts.",
                kind = "toggle",
                no_label = "No",
                no_help = "Exclude drafts.",
                yes_label = "Yes",
                yes_help = "Include drafts.",
            },
        },
        execute = on_execute,
    }
end

local function test_toggle_and_prefilled_step_skipping()
    local executed_answers = nil
    local command = create_toggle_command(function(answers) executed_answers = answers end)

    wizard.open_command(command, { include_drafts = false }, {})
    assert(current_text():find("First Step", 1, true) ~= nil, "starts on first unanswered step")
    helpers.press_key("h")
    assert(current_text():find("First Step", 1, true) ~= nil, "step-1 Back without palette is a no-op")
    helpers.press_key("<CR>")
    assert(wizard.is_open() == false, "skips prefilled trailing toggle step")
    assert(vim.deep_equal(executed_answers, { first = "a", include_drafts = false }), "preserves prefilled false toggle")

    executed_answers = nil
    wizard.open_command(command, {}, {})
    helpers.press_key("<CR>")
    assert(current_text():find("▸ No", 1, true) ~= nil, "toggle defaults to false")
    helpers.press_key("j")
    helpers.press_key("<CR>")
    assert(wizard.is_open() == false and vim.deep_equal(executed_answers, { first = "a", include_drafts = true }), "toggle submits true")
end

local function create_guarded_command(on_load, on_execute)
    return {
        id = "guarded",
        label = "Guarded Flow",
        help = "Exercises menu validation and step-back cancellation.",
        steps = {
            {
                id = "choice",
                label = "Choice",
                help = "Pick a valid choice.",
                kind = "select",
                options = {
                    { value = "blocked", label = "Blocked", help = "Always fails validation." },
                    { value = "allowed", label = "Allowed", help = "Passes validation." },
                },
                validate = function(value)
                    if value == "blocked" then
                        return false, "This option is currently blocked."
                    end
                    return true
                end,
            },
            { id = "item", label = "Remote Item", help = "Pick a remote item.", kind = "async_select", load = on_load },
        },
        execute = on_execute,
    }
end

local function test_singleton_menu_validation_and_back_stale_async()
    local pending_callback, executed_answers = nil, nil
    local command = create_guarded_command(
        function(_answers, _context, on_loaded) pending_callback = on_loaded end,
        function(answers) executed_answers = answers end
    )

    wizard.open_command(command, {}, {})
    local first_win = current_float_win()
    wizard.open_command(command, {}, {})
    assert(not vim.api.nvim_win_is_valid(first_win) and vim.api.nvim_win_is_valid(current_float_win()), "singleton guard replaces window")

    helpers.press_key("<CR>")
    assert(wizard.is_open() and current_text():find("This option is currently blocked.", 1, true) ~= nil, "menu validation error rendered")

    helpers.press_key("j")
    helpers.press_key("<CR>")
    assert(current_text():find("Loading...", 1, true) ~= nil, "entered async step 2")
    local stale_callback = pending_callback
    helpers.press_key("h")
    assert(current_text():find("Choice", 1, true) ~= nil, "h returned to Step 1")
    stale_callback({ { value = "stale", label = "Stale Item", help = "Must not overwrite Step 1." } })
    assert(current_text():find("Stale Item", 1, true) == nil and current_text():find("Choice", 1, true) ~= nil, "stale async after step-back ignored")
    wizard.close()
    assert(executed_answers == nil, "closed without executing")
end

test_palette_window_and_hover_navigation()
test_palette_cursor_sync_and_cancel()
test_zero_step_command_execution()
test_discriminant_stepper_back_and_pruning()
test_text_validation_and_escape_behavior()
test_async_select_loading_and_selection()
test_async_empty_back_and_stale_close()
test_toggle_and_prefilled_step_skipping()
test_singleton_menu_validation_and_back_stale_async()

print("tui_wizard_spec: ok")
