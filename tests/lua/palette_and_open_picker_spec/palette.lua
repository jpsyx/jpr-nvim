-- `:Jpr` command schema validation, bare Command Palette dispatch, smart defaults, and direct args specs.
return function(context)
    local helpers = context.helpers
    local jpr = context.jpr
    local session = context.session
    local wizard = context.wizard
    local tui_schema = context.tui_schema
    local commands_schema = context.commands_schema

    local function test_command_specs_validate_and_match_jpr_subcommands()
        local specs = commands_schema.create_command_specs()
        local is_valid, validation_error = tui_schema.validate_command_specs(specs)
        assert(is_valid == true, "command specs valid: " .. tostring(validation_error))
        assert(#specs == 15, "expected 15 command specs, got " .. tostring(#specs))
        assert(vim.deep_equal(commands_schema.list_command_ids(), jpr.subcommands), "list_command_ids matches jpr.subcommands")

        local keys_spec = commands_schema.find_command_spec("keys")
        assert(keys_spec ~= nil, "keys command spec is registered")
        assert(keys_spec.label == "Keyboard Shortcuts", "keys command has human-readable label")
        assert(keys_spec.requires_session == false, "keys command does not require a session")

        for _, spec in ipairs(specs) do
            assert(spec.label ~= spec.id, "label must be human-readable and distinct from id: " .. spec.id)
            assert(type(spec.help) == "string" and spec.help:match("%S") ~= nil, "help must be non-empty: " .. spec.id)
            assert(not spec.help:find("\226\128\148", 1, true), "help must not contain em dash: " .. spec.id)
        end
    end

    local function test_format_pr_updated_date_extracts_iso_date_or_falls_back_to_unknown()
        assert(commands_schema.format_pr_updated_date("2026-11-23T12:00:00Z") == "2026-11-23", "extracts ISO date")
        assert(commands_schema.format_pr_updated_date("") == "unknown", "empty timestamp falls back to unknown")
        assert(commands_schema.format_pr_updated_date(nil) == "unknown", "nil timestamp falls back to unknown")
    end

    local function test_bare_jpr_opens_palette_with_hover_helper_text()
        jpr.command({})
        assert(wizard.is_open() == true, "bare :Jpr opens floating Command Palette")

        local first_text = helpers.current_text()
        assert(first_text:find("▸ Open Pull Request  [open]", 1, true) ~= nil, "first row selected: " .. first_text)
        assert(first_text:find("Pick an open pull request", 1, true) ~= nil, "open hover helper text visible")
        assert(first_text:find("Fetch the latest pull request commits", 1, true) == nil, "sync helper text hidden initially")

        helpers.press_key("j")
        local second_text = helpers.current_text()
        assert(second_text:find("▸ Sync with GitHub  [sync]", 1, true) ~= nil, "j moves selection to sync: " .. second_text)
        assert(second_text:find("Fetch the latest pull request commits", 1, true) ~= nil, "sync hover helper text visible")
        assert(second_text:find("Pick an open pull request", 1, true) == nil, "open helper text hidden after move")

        wizard.close()
        assert(wizard.is_open() == false, "palette closed cleanly")
    end

    local function test_palette_multi_step_commands_preselect_and_dispatch_smart_defaults()
        context.with_temp_view_mode("unified", function()
            local recorded = {}
            context.with_stubbed_session_methods({
                set_view_mode = function(mode) recorded[#recorded + 1] = { fn = "set_view_mode", mode = mode } end,
                comment_current = function(opts) recorded[#recorded + 1] = { fn = "comment_current", opts = opts } end,
                agent_current = function(provider) recorded[#recorded + 1] = { fn = "agent_current", provider = provider } end,
            }, function()
                jpr.command({})
                helpers.press_key("jj<CR>")
                assert(wizard.is_open() and helpers.current_text():find("▸ Side-by-Side Split  [split]", 1, true) ~= nil, "toggle defaults to split")
                helpers.press_key("<CR>")
                assert(not wizard.is_open() and recorded[#recorded].mode == "split", "toggle stepper calls set_view_mode('split')")

                jpr.command({})
                helpers.press_key("jjjj<CR>")
                assert(wizard.is_open() and helpers.current_text():find("▸ File-Level Comment  [file]", 1, true) ~= nil, "comment defaults to file")
                helpers.press_key("<CR>")
                assert(not wizard.is_open() and recorded[#recorded].opts.file == true, "comment stepper calls comment_current({ file = true })")

                jpr.setup({ agent = "codex" })
                jpr.command({})
                helpers.press_key(string.rep("j", 10) .. "<CR>")
                assert(wizard.is_open() and helpers.current_text():find("▸ Codex  [codex]", 1, true) ~= nil, "agent defaults to config.agent")
                helpers.press_key("<CR>")
                assert(not wizard.is_open() and recorded[#recorded].provider == "codex", "agent stepper calls agent_current('codex')")
            end)
        end)
    end

    local function test_direct_subcommand_args_bypass_modal_and_reject_invalid_values()
        local recorded = {}
        context.with_stubbed_session_methods({
            set_view_mode = function(mode) recorded[#recorded + 1] = { fn = "set_view_mode", mode = mode } end,
            comment_current = function(opts) recorded[#recorded + 1] = { fn = "comment_current", opts = opts } end,
            agent_current = function(provider) recorded[#recorded + 1] = { fn = "agent_current", provider = provider } end,
        }, function()
            jpr.command({ "toggle", "split" })
            assert(not wizard.is_open() and recorded[#recorded].mode == "split", "direct toggle split bypasses modal")

            jpr.command({ "comment", "file" })
            assert(not wizard.is_open() and recorded[#recorded].opts.file == true, "direct comment file bypasses modal")

            jpr.command({ "comment", "suggest" })
            assert(not wizard.is_open() and recorded[#recorded].opts.suggest == true, "direct comment suggest bypasses modal")

            jpr.command({ "agent", "codex" })
            assert(not wizard.is_open() and recorded[#recorded].provider == "codex", "direct agent codex bypasses modal")

            context.clear_notifications()
            jpr.command({ "toggle", "invalid" })
            assert(not wizard.is_open() and context.has_notification("invalid diff view", vim.log.levels.ERROR), "invalid toggle arg errors")

            context.clear_notifications()
            jpr.command({ "comment", "invalid" })
            assert(not wizard.is_open() and context.has_notification("invalid comment scope", vim.log.levels.ERROR), "invalid comment arg errors")

            context.clear_notifications()
            jpr.command({ "agent", "invalid" })
            assert(not wizard.is_open() and context.has_notification("invalid agent", vim.log.levels.ERROR), "invalid agent arg errors")
        end)
    end

    local function test_comment_smart_default_preselects_line_on_diff_line()
        local tab = vim.api.nvim_get_current_tabpage()
        local buf = vim.api.nvim_create_buf(false, true)
        local previous_buf = vim.api.nvim_get_current_buf()
        local original_by_tab = session.by_tab[tab]
        local recorded_opts = nil

        vim.api.nvim_win_set_buf(0, buf)
        vim.b[buf].jpr_base_path = "README.md"
        session.by_tab[tab] = { number = 7, repo = "octo/widgets", tab = tab }

        local is_ok, call_error = pcall(context.with_stubbed_session_methods, {
            comment_current = function(opts) recorded_opts = opts end,
        }, function()
            jpr.command({})
            helpers.press_key("jjjj<CR>")
            assert(wizard.is_open() == true, "comment opens stepper from palette on diff line")
            assert(helpers.current_text():find("▸ Line / Selection Comment  [line]", 1, true) ~= nil, "comment defaults to line on diff line: " .. helpers.current_text())
            helpers.press_key("<CR>")
            assert(wizard.is_open() == false, "confirming line comment closes stepper")
            assert(recorded_opts == nil or (not recorded_opts.file and not recorded_opts.suggest), "line comment dispatched without file/suggest flag")
        end)

        session.by_tab[tab] = original_by_tab
        vim.api.nvim_win_set_buf(0, previous_buf)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        if not is_ok then
            error(call_error, 0)
        end
    end

    test_command_specs_validate_and_match_jpr_subcommands()
    test_format_pr_updated_date_extracts_iso_date_or_falls_back_to_unknown()
    test_bare_jpr_opens_palette_with_hover_helper_text()
    test_palette_multi_step_commands_preselect_and_dispatch_smart_defaults()
    test_direct_subcommand_args_bypass_modal_and_reject_invalid_values()
    test_comment_smart_default_preselects_line_on_diff_line()
end
