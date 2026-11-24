-- Async select loading, stale callback cancellation, error rendering, and external window close specs.
return function(context)
    local helpers = context.helpers
    local wizard = context.wizard

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

    local function test_async_select_shows_loading_ignores_early_confirm_and_dispatches_selected_option()
        local executed_answers, pending_callback = nil, nil
        local command = create_async_pr_command(
            function(_answers, _context, on_loaded) pending_callback = on_loaded end,
            function(answers) executed_answers = answers end
        )

        local caller_answers = { source = "list" }
        wizard.open_command(command, caller_answers, {}, { start_step_id = "pr" })
        assert(wizard.is_open() == true and helpers.current_text():find("Loading...", 1, true) ~= nil, "renders Loading... immediately")
        helpers.press_key("<CR>")
        assert(wizard.is_open() == true and executed_answers == nil, "<CR> while loading is a no-op")

        local is_applied = pending_callback({
            { value = "101", label = "#101 Fix auth", help = "By alice" },
            { value = "202", label = "#202 Add TUI", help = "By bob" },
        })
        assert(is_applied == true, "active async callback returns true when applied")
        assert(helpers.current_text():find("▸ #101 Fix auth", 1, true) ~= nil, "loaded options render")
        helpers.press_key("j")
        helpers.press_key("<CR>")
        assert(wizard.is_open() == false, "confirming async option closes modal")
        assert(vim.deep_equal(executed_answers, { source = "list", pr = "202" }), "execute receives option 2 value")
        assert(vim.deep_equal(caller_answers, { source = "list" }), "caller initial_answers not mutated")
    end

    local function test_async_select_renders_empty_message_allows_back_and_ignores_callbacks_after_close()
        local pending_callback = nil
        local command = create_async_pr_command(
            function(_answers, _context, on_loaded) pending_callback = on_loaded end,
            function() end
        )

        wizard.open_command(command, { source = "list" }, {}, { start_step_id = "pr" })
        assert(pending_callback({}, nil, "No open pull requests found.") == true, "empty callback applied")
        assert(helpers.current_text():find("No open pull requests found.", 1, true) ~= nil, "empty_message rendered")
        helpers.press_key("h")
        assert(wizard.is_open() and helpers.current_text():find("Pull Request Source", 1, true) ~= nil, "h returns to Step 1 from empty list")
        assert(helpers.current_text():find("▸ Pick from Open PRs", 1, true) ~= nil, "Step 1 retains prefilled selection")
        wizard.close()

        pending_callback = nil
        wizard.open_command(command, { source = "list" }, {}, { start_step_id = "pr" })
        local stale_callback = pending_callback
        wizard.close()
        assert(wizard.is_open() == false, "wizard.close() closes modal")
        local is_applied = stale_callback({ { value = "999", label = "#999 Late PR", help = "Should be ignored." } })
        assert(is_applied == false, "stale async callback after close returns false")
        assert(wizard.is_open() == false, "stale async callback after close does not reopen modal")
    end

    local function test_wizard_replaces_existing_modal_blocks_invalid_menu_option_and_drops_stale_async_after_back()
        local pending_callback, executed_answers = nil, nil
        local command = create_guarded_command(
            function(_answers, _context, on_loaded) pending_callback = on_loaded end,
            function(answers) executed_answers = answers end
        )

        wizard.open_command(command, {}, {})
        local first_win = helpers.current_float_win()
        wizard.open_command(command, {}, {})
        assert(not vim.api.nvim_win_is_valid(first_win) and vim.api.nvim_win_is_valid(helpers.current_float_win()), "singleton guard replaces window")

        helpers.press_key("<CR>")
        assert(wizard.is_open() and helpers.current_text():find("This option is currently blocked.", 1, true) ~= nil, "menu validation error rendered")

        helpers.press_key("j")
        helpers.press_key("<CR>")
        assert(helpers.current_text():find("Loading...", 1, true) ~= nil, "entered async step 2")
        local stale_callback = pending_callback
        helpers.press_key("h")
        assert(helpers.current_text():find("Choice", 1, true) ~= nil, "h returned to Step 1")
        local is_applied = stale_callback({ { value = "stale", label = "Stale Item", help = "Must not overwrite Step 1." } })
        assert(is_applied == false, "stale async callback after step-back returns false")
        assert(helpers.current_text():find("Stale Item", 1, true) == nil and helpers.current_text():find("Choice", 1, true) ~= nil, "stale async after step-back ignored")
        wizard.close()
        assert(executed_answers == nil, "closed without executing")
    end

    local function test_async_select_error_renders_jpr_error_ignores_confirm_and_returns_on_back()
        local pending_callback, executed_answers = nil, nil
        local command = create_async_pr_command(
            function(_answers, _context, on_loaded) pending_callback = on_loaded end,
            function(answers) executed_answers = answers end
        )

        wizard.open_command(command, { source = "list" }, {}, { start_step_id = "pr" })
        pending_callback(nil, "gh auth failed")

        local buf = vim.api.nvim_win_get_buf(helpers.current_float_win())
        assert(helpers.current_text():find("gh auth failed", 1, true) ~= nil, "async error message rendered in buffer")
        assert(context.has_buffer_highlight_group(buf, "JprError", "gh auth failed"), "async error highlighted with JprError")

        helpers.press_key("<CR>")
        assert(wizard.is_open() == true and executed_answers == nil, "<CR> on async error state is a no-op")

        helpers.press_key("h")
        assert(wizard.is_open() == true and helpers.current_text():find("Pull Request Source", 1, true) ~= nil, "h steps Back from async error")
        wizard.close()
    end

    local function test_external_win_close_clears_state_exits_insert_and_restores_origin_focus()
        local origin_win = vim.api.nvim_get_current_win()
        local pending_callback = nil
        local async_command = create_async_pr_command(
            function(_answers, _context, on_loaded) pending_callback = on_loaded end,
            function() end
        )

        wizard.open_command(async_command, { source = "list" }, {}, { start_step_id = "pr" })
        local float_win = helpers.current_float_win()
        local stale_callback = pending_callback
        vim.api.nvim_win_close(float_win, true)
        assert(wizard.is_open() == false, "external nvim_win_close clears wizard state via WinClosed")
        assert(stale_callback({ { value = "99", label = "#99 Stale", help = "Ignored." } }) == false, "stale callback dropped after WinClosed")
        assert(wizard.is_open() == false, "stale async callback dropped after WinClosed")

        -- External close on a text step exits Insert mode cleanly and restores origin_win.
        local text_command = context.create_text_validation_command(function() end)
        wizard.open_command(text_command, {}, {})
        local text_win = helpers.current_float_win()
        vim.api.nvim_win_close(text_win, true)
        vim.wait(20, function() return false end)
        assert(wizard.is_open() == false, "text step external close clears wizard state")
        assert(vim.fn.mode(1):sub(1, 1) == "n", "no Insert-mode leak after external text window close")
        assert(vim.api.nvim_get_current_win() == origin_win, "focus restored to origin_win")

        -- Palette -> command -> q close preserves and restores origin_win.
        local branch_commands = context.create_branch_commands(function() end)
        wizard.open_palette(branch_commands, {})
        helpers.press_key("j")
        helpers.press_key("<CR>")
        helpers.press_key("q")
        assert(vim.api.nvim_get_current_win() == origin_win, "palette -> command -> close restores origin_win")
    end

    local function test_async_loader_renders_thrown_error_and_ignores_duplicate_sync_callbacks()
        local throwing_command = create_async_pr_command(function() error("network_down") end, function() end)
        wizard.open_command(throwing_command, { source = "list" }, {}, { start_step_id = "pr" })
        local buf = vim.api.nvim_win_get_buf(helpers.current_float_win())
        assert(helpers.current_text():find("network_down", 1, true) ~= nil, "thrown loader error rendered")
        assert(context.has_buffer_highlight_group(buf, "JprError", "network_down"), "thrown loader error highlighted with JprError")
        helpers.press_key("h")
        assert(helpers.current_text():find("Pull Request Source", 1, true) ~= nil, "h steps Back after loader throw")
        wizard.close()

        local duplicate_applied = nil
        local sync_command = create_async_pr_command(function(_answers, _context, on_loaded)
            assert(on_loaded({ { value = "1", label = "#1 First", help = "First sync result." } }) == true, "first sync callback applied")
            duplicate_applied = on_loaded({ { value = "2", label = "#2 Duplicate", help = "Must be ignored." } })
        end, function() end)
        wizard.open_command(sync_command, { source = "list" }, {}, { start_step_id = "pr" })
        assert(duplicate_applied == false, "duplicate on_loaded call returns false")
        assert(helpers.current_text():find("▸ #1 First", 1, true) ~= nil, "synchronous on_loaded renders options")
        assert(helpers.current_text():find("#2 Duplicate", 1, true) == nil, "duplicate on_loaded call ignored")
        wizard.close()
    end

    test_async_select_shows_loading_ignores_early_confirm_and_dispatches_selected_option()
    test_async_select_renders_empty_message_allows_back_and_ignores_callbacks_after_close()
    test_wizard_replaces_existing_modal_blocks_invalid_menu_option_and_drops_stale_async_after_back()
    test_async_select_error_renders_jpr_error_ignores_confirm_and_returns_on_back()
    test_external_win_close_clears_state_exits_insert_and_restores_origin_focus()
    test_async_loader_renders_thrown_error_and_ignores_duplicate_sync_callbacks()
end
