-- Discriminant stepper navigation, toggle prefilling, and text-input modal specs.
return function(context)
    local helpers = context.helpers
    local wizard = context.wizard

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

    local function test_discriminant_stepper_returns_on_back_and_prunes_stale_branch_answers()
        local executed_answers = nil
        local commands = context.create_branch_commands(function(answers) executed_answers = answers end)

        wizard.open_palette(commands, {})
        helpers.press_key("j")
        helpers.press_key("<CR>")
        assert(helpers.win_title(helpers.current_float_win()) == " Configure Target ", "step menu title uses command label")
        assert(helpers.current_text():find("Step 1 of 1", 1, true) ~= nil, "discriminant starts as Step 1 of 1")
        assert(helpers.current_text():find("▸ Automatic", 1, true) ~= nil, "default option preselected")

        helpers.press_key("h")
        assert(wizard.is_open() and helpers.current_text():find("▸ Configure Target", 1, true) ~= nil, "h returns to palette on originating command")

        helpers.press_key("<CR>")
        helpers.press_key("j")
        helpers.press_key("l")
        local step2_win = helpers.current_float_win()
        local step2_buf = vim.api.nvim_win_get_buf(step2_win)
        assert(vim.bo[step2_buf].filetype == "jpr-tui-input" and vim.bo[step2_buf].modifiable == true, "text step buffer editable")
        assert(vim.wo[step2_win].cursorline == false, "text step disables cursorline")
        assert(helpers.win_title(step2_win):find("Step 2 of 2", 1, true) ~= nil, "text step title shows Step 2 of 2")
        assert(context.win_footer(step2_win):find("[S-Tab] back", 1, true) ~= nil, "text step footer shows back hint")
        assert(vim.api.nvim_buf_get_lines(step2_buf, 0, -1, false)[1] == "default-val", "line 1 prefilled with default")
        assert(context.read_virt_lines_above(step2_buf):find("Type the custom target identifier.", 1, true) ~= nil, "virt_lines_above shows step help")

        helpers.press_key("<S-Tab>")
        assert(wizard.is_open() and helpers.current_text():find("▸ Custom", 1, true) ~= nil, "<S-Tab> returns to Step 1 with Custom highlighted")
        helpers.press_key("k")
        helpers.press_key("<CR>")
        assert(wizard.is_open() == false, "confirming final step closes wizard")
        assert(vim.deep_equal(executed_answers, { mode = "auto" }), "stale custom_value pruned: " .. vim.inspect(executed_answers))
    end

    local function test_text_step_blocks_invalid_submit_drops_to_normal_on_insert_esc_and_cancels_in_normal_mode()
        local executed_answers = nil
        local command = context.create_text_validation_command(function(answers) executed_answers = answers end)

        wizard.open_command(command, {}, {})
        local buf = vim.api.nvim_win_get_buf(helpers.current_float_win())

        helpers.press_key("A<CR>")
        assert(wizard.is_open() == true and executed_answers == nil, "validation error keeps text modal open")
        local virt_text, virt_groups = context.read_virt_lines_above(buf)
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
        helpers.press_key("A<Esc>ciw77<Tab>")
        assert(wizard.is_open() == false and vim.deep_equal(executed_answers, { pr_number = "77" }), "Insert-mode <Tab> submits edited value")

        executed_answers = nil
        wizard.open_command(command, {}, {})
        helpers.press_key("<Esc>")
        assert(wizard.is_open() == false and executed_answers == nil, "Normal-mode <Esc> cancels text modal")
        wizard.open_command(command, {}, {})
        helpers.press_key("q")
        assert(wizard.is_open() == false and executed_answers == nil, "Normal-mode q cancels text modal")
    end

    local function test_wizard_skips_prefilled_toggle_preserving_false_and_defaults_unprefilled_toggle_to_false()
        local executed_answers = nil
        local command = create_toggle_command(function(answers) executed_answers = answers end)

        wizard.open_command(command, { include_drafts = false }, {})
        assert(helpers.current_text():find("First Step", 1, true) ~= nil, "starts on first unanswered step")
        helpers.press_key("h")
        assert(helpers.current_text():find("First Step", 1, true) ~= nil, "step-1 Back without palette is a no-op")
        helpers.press_key("<CR>")
        assert(wizard.is_open() == false, "skips prefilled trailing toggle step")
        assert(vim.deep_equal(executed_answers, { first = "a", include_drafts = false }), "preserves prefilled false toggle")

        executed_answers = nil
        wizard.open_command(command, {}, {})
        helpers.press_key("<CR>")
        assert(helpers.current_text():find("▸ No", 1, true) ~= nil, "toggle defaults to false")
        helpers.press_key("j")
        helpers.press_key("<CR>")
        assert(wizard.is_open() == false and vim.deep_equal(executed_answers, { first = "a", include_drafts = true }), "toggle submits true")
    end

    local function test_toggle_false_draft_preserved_on_step_back()
        local executed_answers = nil
        local command = create_toggle_command(function(answers) executed_answers = answers end)
        command.steps[2].default = true

        wizard.open_command(command, {}, {})
        helpers.press_key("<CR>")
        assert(helpers.current_text():find("▸ Yes", 1, true) ~= nil, "toggle with default=true starts on Yes")

        -- Highlight No (false), step Back to Step 1, then advance forward again.
        helpers.press_key("k")
        assert(helpers.current_text():find("▸ No", 1, true) ~= nil, "k selects No (false) on toggle step")
        helpers.press_key("h")
        assert(helpers.current_text():find("First Step", 1, true) ~= nil, "h returns to Step 1")

        helpers.press_key("<CR>")
        assert(helpers.current_text():find("▸ No", 1, true) ~= nil, "returning to toggle step preserves No (false) draft")
        helpers.press_key("<CR>")
        assert(wizard.is_open() == false, "confirming preserved No closes modal")
        assert(
            vim.deep_equal(executed_answers, { first = "a", include_drafts = false }),
            "confirmed preserved false draft: " .. vim.inspect(executed_answers)
        )
    end

    local function test_insert_mode_persists_across_validation_error_and_consecutive_text_steps()
        local executed_answers = nil
        local command = {
            id = "two_texts",
            label = "Two Text Steps",
            help = "Exercises Insert-mode continuity across validation and consecutive text steps.",
            steps = {
                {
                    id = "first_text",
                    label = "First Text",
                    help = "Enter digits only.",
                    kind = "text",
                    default = "bad",
                    validate = function(value)
                        if not tostring(value):match("^%d+$") then
                            return nil, "Need digits"
                        end
                        return true
                    end,
                },
                {
                    id = "second_text",
                    label = "Second Text",
                    help = "Append suffix.",
                    kind = "text",
                    default = "prefix-",
                },
            },
            execute = function(answers) executed_answers = answers end,
        }

        wizard.open_command(command, {}, {})
        -- Enter Insert mode once, fail validation (<CR>), edit and submit Step 1, then type directly into Step 2.
        helpers.press_key("A<CR><BS><BS><BS>42<CR>done<CR>")
        assert(wizard.is_open() == false, "consecutive text steps complete cleanly")
        assert(
            vim.deep_equal(executed_answers, { first_text = "42", second_text = "prefix-done" }),
            "Insert mode persisted across validation failure and consecutive text steps: " .. vim.inspect(executed_answers)
        )
    end

    local function test_step_back_never_executes_when_no_active_steps_remain()
        local execute_count = 0
        local command = {
            id = "disappearing",
            label = "Disappearing Step",
            help = "Step 1 hides when Step 2 draft is hide.",
            steps = {
                {
                    id = "first",
                    label = "First",
                    help = "First step.",
                    kind = "select",
                    when = function(answers) return answers.second ~= "hide" end,
                    options = { { value = "ok", label = "OK", help = "Continue." } },
                },
                {
                    id = "second",
                    label = "Second",
                    help = "Second step.",
                    kind = "text",
                    default = "hide",
                    when = function(answers) return answers.first == "ok" and answers.second ~= "hide" end,
                },
            },
            execute = function() execute_count = execute_count + 1 end,
        }

        wizard.open_command(command, {}, {})
        helpers.press_key("<CR>")
        helpers.press_key("<S-Tab>")
        assert(wizard.is_open() == false, "step back with zero active steps closes modal cleanly")
        assert(execute_count == 0, "step back MUST NOT execute command")
    end

    test_discriminant_stepper_returns_on_back_and_prunes_stale_branch_answers()
    test_text_step_blocks_invalid_submit_drops_to_normal_on_insert_esc_and_cancels_in_normal_mode()
    test_wizard_skips_prefilled_toggle_preserving_false_and_defaults_unprefilled_toggle_to_false()
    test_toggle_false_draft_preserved_on_step_back()
    test_insert_mode_persists_across_validation_error_and_consecutive_text_steps()
    test_step_back_never_executes_when_no_active_steps_remain()
end
