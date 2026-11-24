-- Command palette floating window, hover navigation, cursor sync, and zero-step execution specs.
return function(context)
    local helpers = context.helpers
    local wizard = context.wizard

    local function create_palette_commands(executed_calls)
        local function record(id)
            return function(answers, command_context)
                executed_calls[#executed_calls + 1] = { id = id, answers = answers, context = command_context }
            end
        end
        return {
            { id = "open", label = "Open Pull Request", help = "Pick an open pull request or enter a PR number.", execute = record("open") },
            { id = "sync", label = "Sync with GitHub", help = "Fetch the latest pull request commits and review threads.", requires_session = true, execute = record("sync") },
            { id = "close", label = "Close Review", help = "Shut down the active review session and close buffers.", requires_session = true, execute = record("close") },
        }
    end

    local function test_palette_renders_floating_window_wraps_hover_navigation_and_closes_without_executing()
        local executed_calls = {}
        local commands = create_palette_commands(executed_calls)
        wizard.open_palette(commands, { has_session = false, title = " Jpr Palette " })
        assert(wizard.is_open() == true, "palette opens")

        local win = helpers.current_float_win()
        local buf = vim.api.nvim_win_get_buf(win)
        local config = vim.api.nvim_win_get_config(win)
        assert(helpers.win_title(win) == " Jpr Palette ", "uses custom context title")
        assert(vim.bo[buf].filetype == "jpr-tui" and vim.bo[buf].buftype == "nofile", "palette buffer options")
        assert(vim.bo[buf].modifiable == false and vim.wo[win].cursorline == true and vim.wo[win].wrap == false, "palette window options")
        assert(vim.deep_equal(config.border, { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }), "palette rounded border")

        local text_first = helpers.current_text()
        assert(text_first:find("Pick an open pull request", 1, true) ~= nil, "command 1 help visible initially")
        assert(text_first:find("Fetch the latest pull request", 1, true) == nil, "command 2 help hidden initially")

        helpers.press_key("j")
        assert(helpers.current_text():find("▸ Sync with GitHub", 1, true) ~= nil, "j moves selection to command 2")
        assert(helpers.current_text():find("Fetch the latest pull request", 1, true) ~= nil, "command 2 help visible on hover")
        assert(helpers.current_text():find("Pick an open pull request", 1, true) == nil, "command 1 help hidden when not hovered")

        helpers.press_key("k")
        assert(helpers.current_text():find("▸ Open Pull Request", 1, true) ~= nil, "k moves selection back to command 1")
        helpers.press_key("k")
        assert(helpers.current_text():find("▸ Close Review", 1, true) ~= nil, "k wraps from first command to last")
        helpers.press_key("j")
        assert(helpers.current_text():find("▸ Open Pull Request", 1, true) ~= nil, "j wraps from last command to first")
        helpers.press_key("G")
        assert(helpers.current_text():find("▸ Close Review", 1, true) ~= nil, "G jumps to last command")
        helpers.press_key("gg")
        assert(helpers.current_text():find("▸ Open Pull Request", 1, true) ~= nil, "gg jumps to first command")
        wizard.close()
        assert(#executed_calls == 0, "closing without confirm does not execute")
    end

    local function test_palette_syncs_selection_on_cursor_moved_and_cancels_on_q_or_esc()
        local executed_calls = {}
        local commands = create_palette_commands(executed_calls)
        wizard.open_palette(commands, { has_session = true })
        local win = helpers.current_float_win()
        local buf = vim.api.nvim_win_get_buf(win)
        assert(helpers.win_title(win) == " Jpr Commands ", "default palette title")

        local sync_row = helpers.find_line_number(helpers.current_lines(), "Sync with GitHub")
        assert(sync_row ~= nil, "found sync command row")
        vim.api.nvim_win_set_cursor(win, { sync_row, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
        assert(helpers.current_text():find("▸ Sync with GitHub", 1, true) ~= nil, "CursorMoved selects hovered command")
        assert(helpers.current_text():find("Fetch the latest pull request", 1, true) ~= nil, "CursorMoved swaps helper text")

        helpers.press_key("q")
        assert(wizard.is_open() == false and #executed_calls == 0, "q closes palette without execute")

        wizard.open_palette(commands, { has_session = true })
        helpers.press_key("<Esc>")
        assert(wizard.is_open() == false and #executed_calls == 0, "<Esc> closes palette without execute")
    end

    local function test_zero_step_command_executes_immediately_and_prunes_stale_answers()
        local received = {}
        local commands = {
            {
                id = "sync",
                label = "Sync with GitHub",
                help = "Fetch the latest commits and comments.",
                execute = function(answers, command_context)
                    received[#received + 1] = { answers = answers, context = command_context }
                end,
            },
        }
        local command_context = { has_session = true, marker = "ctx-1" }

        wizard.open_palette(commands, command_context)
        helpers.press_key("<CR>")
        assert(wizard.is_open() == false and #received == 1, "<CR> on 0-step command closes and executes")
        assert(vim.deep_equal(received[1].answers, {}) and received[1].context.marker == "ctx-1", "0-step receives empty answers + context")

        wizard.open_command(commands[1], { stale = "ignored" }, command_context)
        assert(wizard.is_open() == false and #received == 2, "direct open_command on 0-step command executes immediately")
        assert(vim.deep_equal(received[2].answers, {}), "stale answers pruned on direct 0-step execution")
    end

    local function test_empty_palette_renders_placeholder_and_ignores_navigation()
        wizard.open_palette({}, {})
        assert(wizard.is_open() == true, "empty palette opens cleanly")
        assert(helpers.current_text():find("(no commands available)", 1, true) ~= nil, "empty palette message rendered")
        for _, key in ipairs({ "j", "k", "G", "gg", "<CR>" }) do
            helpers.press_key(key)
        end
        assert(wizard.is_open() == true, "navigation and confirm on empty palette are safe no-ops")
        helpers.press_key("q")
        assert(wizard.is_open() == false, "q closes empty palette")
    end

    local function test_modal_opened_by_command_execute_remains_open()
        local second_command = context.create_text_validation_command(function() end)
        local chained_commands = {
            {
                id = "chain",
                label = "Chain Modal",
                help = "Opens another wizard modal from execute.",
                execute = function() wizard.open_command(second_command, {}, {}) end,
            },
        }
        wizard.open_palette(chained_commands, {})
        helpers.press_key("<CR>")
        assert(wizard.is_open() == true, "modal opened by command.execute stays open")
        assert(helpers.win_title(helpers.current_float_win()):find("PR Number", 1, true) ~= nil, "chained modal is active")
        wizard.close()
    end

    test_palette_renders_floating_window_wraps_hover_navigation_and_closes_without_executing()
    test_palette_syncs_selection_on_cursor_moved_and_cancels_on_q_or_esc()
    test_zero_step_command_executes_immediately_and_prunes_stale_answers()
    test_empty_palette_renders_placeholder_and_ignores_navigation()
    test_modal_opened_by_command_execute_remains_open()
end
