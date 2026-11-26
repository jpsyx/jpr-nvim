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
        wizard.open_palette(commands, { has_session = true, title = " Jpr Palette " })
        assert(wizard.is_open() == true, "palette opens")

        local prompt_win = helpers.current_float_win()
        local prompt_buf = vim.api.nvim_win_get_buf(prompt_win)
        local results_win = helpers.palette_results_win()
        local results_buf = vim.api.nvim_win_get_buf(results_win)
        local prompt_config = vim.api.nvim_win_get_config(prompt_win)
        assert(prompt_win ~= results_win, "palette opens stacked prompt and results windows")
        assert(helpers.win_title(prompt_win) == " Jpr Palette ", "uses custom context title on prompt window")
        assert(vim.bo[prompt_buf].filetype == "jpr-tui-input" and vim.bo[prompt_buf].modifiable == true, "prompt buffer editable")
        assert(vim.bo[results_buf].filetype == "jpr-tui" and vim.bo[results_buf].buftype == "nofile", "results buffer options")
        assert(vim.bo[results_buf].modifiable == false and vim.wo[results_win].cursorline == true and vim.wo[results_win].wrap == false, "results window options")
        assert(vim.deep_equal(prompt_config.border, { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }), "prompt rounded border")

        local text_first = helpers.palette_results_text()
        assert(text_first:find("Pick an open pull request", 1, true) ~= nil, "command 1 help visible initially")
        assert(text_first:find("Fetch the latest pull request", 1, true) == nil, "command 2 help hidden initially")

        helpers.press_key("j")
        assert(helpers.palette_results_text():find("▸ Sync with GitHub", 1, true) ~= nil, "j moves selection to command 2")
        assert(helpers.palette_results_text():find("Fetch the latest pull request", 1, true) ~= nil, "command 2 help visible on hover")
        assert(helpers.palette_results_text():find("Pick an open pull request", 1, true) == nil, "command 1 help hidden when not hovered")

        helpers.press_key("k")
        assert(helpers.palette_results_text():find("▸ Open Pull Request", 1, true) ~= nil, "k moves selection back to command 1")
        helpers.press_key("k")
        assert(helpers.palette_results_text():find("▸ Close Review", 1, true) ~= nil, "k wraps from first command to last")
        helpers.press_key("j")
        assert(helpers.palette_results_text():find("▸ Open Pull Request", 1, true) ~= nil, "j wraps from last command to first")
        helpers.press_key("G")
        assert(helpers.palette_results_text():find("▸ Close Review", 1, true) ~= nil, "G jumps to last command")
        helpers.press_key("gg")
        assert(helpers.palette_results_text():find("▸ Open Pull Request", 1, true) ~= nil, "gg jumps to first command")
        wizard.close()
        assert(#executed_calls == 0, "closing without confirm does not execute")
        assert(not vim.api.nvim_win_is_valid(prompt_win) and not vim.api.nvim_win_is_valid(results_win), "close tears down both stacked windows")
    end

    local function test_palette_filters_live_in_insert_mode_moves_with_ctrl_jk_clears_with_ctrl_u_and_drops_to_normal_on_esc()
        local executed_calls = {}
        local commands = create_palette_commands(executed_calls)
        wizard.open_palette(commands, { has_session = true })

        local prompt_buf = vim.api.nvim_win_get_buf(helpers.current_float_win())

        -- Typing in Insert mode filters fuzzily and selects the top match; <Esc> in Insert drops to Normal without closing.
        helpers.press_key("icls<Esc>")
        vim.wait(50, function() return helpers.palette_results_text():find("Open Pull Request", 1, true) == nil end)
        assert(wizard.is_open() == true and vim.fn.mode(1):sub(1, 1) == "n", "Insert <Esc> drops to Normal mode without closing")
        assert(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false)[1] == "cls", "prompt holds typed filter")
        local filtered_text = helpers.palette_results_text()
        assert(filtered_text:find("▸ Close Review  [close]", 1, true) ~= nil, "fuzzy query cls selects Close Review: " .. filtered_text)
        assert(filtered_text:find("Open Pull Request", 1, true) == nil, "non-matching commands hidden")

        -- Re-entering Insert mode and pressing <C-u> clears the entire filter line (not just since Insert start).
        helpers.press_key("A<C-u><Esc>")
        assert(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false)[1] == "", "<C-u> clears entire filter line after re-entering Insert mode")
        local restored_text = helpers.palette_results_text()
        assert(restored_text:find("▸ Open Pull Request  [open]", 1, true) ~= nil, "clearing filter restores all commands")
        assert(restored_text:find("Sync with GitHub", 1, true) ~= nil, "all commands visible again")

        -- <C-j> and <C-k> move selection while in Insert mode.
        helpers.press_key("i<C-j><Esc>")
        assert(helpers.palette_results_text():find("▸ Sync with GitHub  [sync]", 1, true) ~= nil, "<C-j> moves down in Insert mode")
        helpers.press_key("i<C-k><Esc>")
        assert(helpers.palette_results_text():find("▸ Open Pull Request  [open]", 1, true) ~= nil, "<C-k> moves up in Insert mode")

        -- Whitespace-only query shows all commands; non-matching query shows (no matching commands).
        helpers.press_key("i   <Esc>")
        vim.wait(50, function() return vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false)[1] == "   " end)
        assert(helpers.palette_results_text():find("▸ Open Pull Request  [open]", 1, true) ~= nil, "whitespace-only query keeps full list")
        helpers.press_key("A<C-u>zzzz<Esc>")
        vim.wait(50, function() return helpers.palette_results_text():find("(no matching commands)", 1, true) ~= nil end)
        assert(helpers.palette_results_text():find("(no matching commands)", 1, true) ~= nil, "unmatched query shows no matching commands")
        helpers.press_key("A<C-j><C-k><CR><Esc>")
        assert(wizard.is_open() == true and #executed_calls == 0, "navigation/confirm on zero matches is safe no-op")

        -- <C-u> recovers, filter by id, and <CR> in Insert mode executes the matched command.
        helpers.press_key("A<C-u>syn<CR>")
        assert(wizard.is_open() == false, "<CR> in Insert mode executes filtered command and closes")
        assert(#executed_calls == 1 and executed_calls[1].id == "sync", "executed matched sync command")
    end

    local function test_palette_folds_multiline_paste_and_closes_sibling_on_external_win_close()
        local commands = create_palette_commands({})
        wizard.open_palette(commands, { has_session = true })

        local prompt_win = helpers.current_float_win()
        local prompt_buf = vim.api.nvim_win_get_buf(prompt_win)
        local results_win = helpers.palette_results_win()

        vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { "sync", "github" })
        vim.api.nvim_exec_autocmds("TextChanged", { buffer = prompt_buf })
        assert(#vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false) == 1, "multiline paste folded to 1 line")
        assert(helpers.palette_results_text():find("▸ Sync with GitHub  [sync]", 1, true) ~= nil, "folded query still filters")

        vim.api.nvim_win_close(results_win, true)
        vim.wait(50, function() return not vim.api.nvim_win_is_valid(prompt_win) end)
        assert(wizard.is_open() == false and not vim.api.nvim_win_is_valid(prompt_win), "closing results window tears down prompt window")
    end

    local function create_filtered_palette_commands(executed_calls)
        return {
            {
                id = "open",
                label = "Open Pull Request",
                help = "Pick an open pull request.",
                requires_session = false,
                execute = function() executed_calls[#executed_calls + 1] = "open" end,
            },
            {
                id = "sync",
                label = "Sync with GitHub",
                help = "Requires session.",
                requires_session = true,
                execute = function() executed_calls[#executed_calls + 1] = "sync" end,
            },
            {
                id = "comment",
                label = "Add Comment",
                help = "Draft a comment.",
                requires_session = false,
                steps = {
                    {
                        id = "kind",
                        label = "Comment Scope",
                        help = "Pick comment scope.",
                        kind = "select",
                        options = {
                            { value = "line", label = "Line Comment", badge = "[line]", when = function(_answers, command_context) return command_context.is_on_diff_line == true end },
                            { value = "file", label = "File Comment", badge = "[file]", when = function(_answers, command_context) return command_context.can_comment_file == true end },
                        },
                    },
                },
                execute = function(answers) executed_calls[#executed_calls + 1] = "comment:" .. tostring(answers.kind) end,
            },
        }
    end

    local function test_palette_omits_non_executable_commands_and_preserves_step_back()
        local executed_calls = {}
        local commands = create_filtered_palette_commands(executed_calls)

        wizard.open_palette(commands, { has_session = false, is_on_diff_line = false, can_comment_file = true })
        local initial_text = helpers.palette_results_text()
        assert(initial_text:find("Sync with GitHub", 1, true) == nil, "non-executable sync command hidden from palette")
        assert(initial_text:find("▸ Open Pull Request", 1, true) ~= nil, "open command visible")
        assert(initial_text:find("Add Comment", 1, true) ~= nil, "executable comment command visible")

        helpers.press_key("j<CR>")
        local step_text = helpers.current_text()
        assert(step_text:find("Line Comment", 1, true) == nil, "inapplicable line option hidden from select step")
        assert(step_text:find("▸ File Comment  [file]", 1, true) ~= nil, "applicable file option rendered and selected")

        helpers.press_key("h")
        local returned_text = helpers.palette_results_text()
        assert(returned_text:find("Sync with GitHub", 1, true) == nil, "filtered palette stays filtered on step back")
        assert(returned_text:find("▸ Add Comment", 1, true) ~= nil, "step back restores selection to Add Comment in filtered list")

        helpers.press_key("<CR><CR>")
        assert(wizard.is_open() == false, "confirming filtered step option closes modal")
        assert(vim.deep_equal(executed_calls, { "comment:file" }), "executes confirmed filtered option")
    end

    local function test_palette_shows_empty_placeholder_when_all_commands_are_filtered()
        local commands = create_filtered_palette_commands({})
        wizard.open_palette({ commands[2] }, { has_session = false })
        assert(helpers.palette_results_text():find("(no commands available)", 1, true) ~= nil, "all-filtered palette shows empty state")
        for _, key in ipairs({ "j", "k", "G", "gg", "<CR>" }) do
            helpers.press_key(key)
        end
        assert(wizard.is_open() == true, "navigation on all-filtered palette stays safe")
        wizard.close()
    end

    local function test_palette_syncs_selection_on_cursor_moved_and_cancels_on_q_or_esc()
        local executed_calls = {}
        local commands = create_palette_commands(executed_calls)
        wizard.open_palette(commands, { has_session = true })
        local prompt_win = helpers.current_float_win()
        local results_win = helpers.palette_results_win()
        local results_buf = vim.api.nvim_win_get_buf(results_win)
        assert(helpers.win_title(prompt_win) == " Jpr Commands ", "default palette title")

        local sync_row = helpers.find_line_number(helpers.palette_results_lines(), "Sync with GitHub")
        assert(sync_row ~= nil, "found sync command row")
        vim.api.nvim_win_set_cursor(results_win, { sync_row, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = results_buf })
        assert(helpers.palette_results_text():find("▸ Sync with GitHub", 1, true) ~= nil, "CursorMoved selects hovered command")
        assert(helpers.palette_results_text():find("Fetch the latest pull request", 1, true) ~= nil, "CursorMoved swaps helper text")

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
        assert(helpers.palette_results_text():find("(no commands available)", 1, true) ~= nil, "empty palette message rendered")
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

    local function test_palette_clicks_activate_commands_run_footer_actions_and_close_outside()
        local executed_calls = {}
        local commands = create_palette_commands(executed_calls)
        local original_getmousepos = vim.fn.getmousepos
        local is_ok, test_error = pcall(function()
            wizard.open_palette(commands, { has_session = true })
            local results_win = helpers.palette_results_win()
            local sync_line = helpers.find_line_number(helpers.palette_results_lines(), "Sync with GitHub")
            assert(sync_line ~= nil, "found Sync with GitHub row")
            vim.fn.getmousepos = function() return { winid = results_win, line = sync_line, column = 5 } end
            helpers.press_key("i<LeftMouse>")
            assert(wizard.is_open() == false, "Insert-mode click on results row activates command and closes palette")
            assert(#executed_calls == 1 and executed_calls[1].id == "sync", "clicked sync command executed")

            wizard.open_palette(commands, { has_session = true })
            local prompt_win = helpers.current_float_win()
            local prompt_buf = vim.api.nvim_win_get_buf(prompt_win)
            results_win = helpers.palette_results_win()
            helpers.press_key("isyn<Esc>")
            vim.wait(50, function() return helpers.palette_results_text():find("Open Pull Request", 1, true) == nil end)
            local lines = helpers.palette_results_lines()
            local footer_line = #lines
            local clear_col = lines[footer_line]:find("[C-u] clear", 1, true)
            assert(clear_col ~= nil, "found [C-u] clear token in palette footer")
            vim.fn.getmousepos = function() return { winid = results_win, line = footer_line, column = clear_col + 2 } end
            helpers.press_key("<LeftMouse>")
            assert(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false)[1] == "", "clicking [C-u] clear empties prompt")

            lines = helpers.palette_results_lines()
            footer_line = #lines
            local escape_col = lines[footer_line]:find("[Esc] normal/close", 1, true)
            assert(escape_col ~= nil, "found [Esc] normal/close token in palette footer")
            vim.fn.getmousepos = function() return { winid = results_win, line = footer_line, column = escape_col + 1 } end
            helpers.press_key("<LeftMouse>")
            assert(wizard.is_open() == false, "clicking [Esc] normal/close closes palette")

            wizard.open_palette(commands, { has_session = true })
            vim.fn.getmousepos = function() return { winid = 999999, line = 1, column = 1 } end
            helpers.press_key("<LeftMouse>")
            assert(wizard.is_open() == false, "clicking outside palette closes it")
        end)
        vim.fn.getmousepos = original_getmousepos
        wizard.close()
        assert(is_ok, tostring(test_error))
    end

    local function test_wizard_menu_clicks_select_options_run_footer_actions_and_close_outside()
        local commands = create_palette_commands({})
        local original_getmousepos = vim.fn.getmousepos
        local is_ok, test_error = pcall(function()
            local stepped_answers = nil
            local multi_command = {
                id = "mode",
                label = "Switch Mode",
                help = "Pick a mode.",
                steps = {
                    {
                        id = "mode",
                        kind = "select",
                        label = "Mode",
                        help = "Choose view mode.",
                        options = {
                            { value = "unified", label = "Unified", badge = "[unified]", help = "Single column." },
                            { value = "split", label = "Split", badge = "[split]", help = "Two columns." },
                        },
                    },
                },
                execute = function(answers) stepped_answers = answers end,
            }
            wizard.open_command(multi_command, {}, {}, {
                can_return_to_palette = true,
                palette_commands = commands,
                palette_index = 1,
            })
            local step_win = helpers.current_float_win()
            local step_lines = helpers.current_lines()
            local split_line = helpers.find_line_number(step_lines, "Split")
            assert(split_line ~= nil, "found Split option line")
            vim.fn.getmousepos = function() return { winid = step_win, line = split_line, column = 4 } end
            helpers.press_key("<LeftMouse>")
            assert(wizard.is_open() == false, "clicking step option completes single-step wizard")
            assert(stepped_answers ~= nil and stepped_answers.mode == "split", "clicked option value committed")

            wizard.open_command(multi_command, {}, { has_session = true }, {
                can_return_to_palette = true,
                palette_commands = commands,
                palette_index = 1,
            })
            step_win = helpers.current_float_win()
            step_lines = helpers.current_lines()
            local step_footer_line = #step_lines
            local back_col = step_lines[step_footer_line]:find("[h] palette", 1, true)
            assert(back_col ~= nil, "found [h] palette token in step footer")
            vim.fn.getmousepos = function() return { winid = step_win, line = step_footer_line, column = back_col + 1 } end
            helpers.press_key("<LeftMouse>")
            assert(wizard.is_open() == true and helpers.palette_results_win() ~= nil, "clicking [h] palette returns to palette")

            wizard.open_command(multi_command, {}, {})
            vim.fn.getmousepos = function() return { winid = 999999, line = 1, column = 1 } end
            helpers.press_key("<LeftMouse>")
            assert(wizard.is_open() == false, "clicking outside wizard menu closes it")
        end)
        vim.fn.getmousepos = original_getmousepos
        wizard.close()
        assert(is_ok, tostring(test_error))
    end

    test_palette_renders_floating_window_wraps_hover_navigation_and_closes_without_executing()
    test_palette_filters_live_in_insert_mode_moves_with_ctrl_jk_clears_with_ctrl_u_and_drops_to_normal_on_esc()
    test_palette_folds_multiline_paste_and_closes_sibling_on_external_win_close()
    test_palette_omits_non_executable_commands_and_preserves_step_back()
    test_palette_shows_empty_placeholder_when_all_commands_are_filtered()
    test_palette_syncs_selection_on_cursor_moved_and_cancels_on_q_or_esc()
    test_zero_step_command_executes_immediately_and_prunes_stale_answers()
    test_empty_palette_renders_placeholder_and_ignores_navigation()
    test_modal_opened_by_command_execute_remains_open()
    test_palette_clicks_activate_commands_run_footer_actions_and_close_outside()
    test_wizard_menu_clicks_select_options_run_footer_actions_and_close_outside()
end
