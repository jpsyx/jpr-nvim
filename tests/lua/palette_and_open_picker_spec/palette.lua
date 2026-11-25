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
        assert(#specs == 16, "expected 16 command specs, got " .. tostring(#specs))
        assert(vim.deep_equal(commands_schema.list_command_ids(), jpr.subcommands), "list_command_ids matches jpr.subcommands")
        local aliases_ok, aliases_error = commands_schema.validate_command_aliases()
        assert(aliases_ok == true, "command aliases are valid: " .. tostring(aliases_error))
        assert(not vim.tbl_contains(jpr.subcommands, "review"), "review stays out of the palette command list")

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

    local function extract_visible_command_ids(text)
        local ids = {}
        for line in (text or ""):gmatch("[^\n]+") do
            local id = line:match("%s+%[([%a_]+)%]%s*$")
            if id then
                ids[#ids + 1] = id
            end
        end
        return ids
    end

    local function select_palette_command(command_id)
        local needle = "[" .. command_id .. "]"
        for _ = 1, 20 do
            local selected_line = helpers.current_text():match("▸[^\n]+") or ""
            if selected_line:find(needle, 1, true) ~= nil then
                helpers.press_key("<CR>")
                return
            end
            helpers.press_key("j")
        end
        error("command " .. command_id .. " not found in palette:\n" .. helpers.current_text())
    end

    local function with_tab_session(stub_session, callback)
        local tab = vim.api.nvim_get_current_tabpage()
        local original_by_tab = session.by_tab[tab]
        session.by_tab[tab] = stub_session
        local is_ok, call_error = pcall(callback, tab)
        wizard.close()
        session.by_tab[tab] = original_by_tab
        if not is_ok then
            error(call_error, 0)
        end
    end

    local function test_bare_jpr_opens_palette_with_only_executable_commands_outside_session()
        jpr.command({})
        assert(wizard.is_open() == true, "bare :Jpr opens floating Command Palette")

        local first_text = helpers.current_text()
        assert(
            vim.deep_equal(extract_visible_command_ids(first_text), { "open", "local", "keys" }),
            "outside session in git repo shows only open, local, keys: " .. vim.inspect(extract_visible_command_ids(first_text))
        )
        assert(first_text:find("▸ Open Pull Request  [open]", 1, true) ~= nil, "first row selected: " .. first_text)
        assert(first_text:find("Pick an open pull request", 1, true) ~= nil, "open hover helper text visible")
        assert(first_text:find("Review the current worktree", 1, true) == nil, "local helper text hidden initially")

        helpers.press_key("j")
        local second_text = helpers.current_text()
        assert(second_text:find("▸ Review Current Worktree  [local]", 1, true) ~= nil, "j moves selection to local: " .. second_text)
        assert(second_text:find("Review the current worktree", 1, true) ~= nil, "local hover helper text visible")
        assert(second_text:find("Pick an open pull request", 1, true) == nil, "open helper text hidden after move")

        wizard.close()
        assert(wizard.is_open() == false, "palette closed cleanly")
    end

    local function test_palette_filters_by_session_mode_read_only_pending_tab_and_view()
        -- Pending checkout tab (no registered session yet) exposes close alongside open/local/keys.
        context.with_stubbed_session_methods({
            has_pending_tab = function() return true end,
        }, function()
            jpr.command({})
            local pending_ids = extract_visible_command_ids(helpers.current_text())
            assert(
                vim.deep_equal(pending_ids, { "open", "local", "close", "keys" }),
                "pending checkout tab shows open, local, close, keys: " .. vim.inspect(pending_ids)
            )
            wizard.close()
        end)

        -- Linked PR session in unrelated buffer (not on diff line/file, 0 unsent local threads).
        local tab = vim.api.nvim_get_current_tabpage()
        with_tab_session({ number = 7, repo = "octo/widgets", tab = tab, mode = "pr", view = { localUnsentCount = 0 } }, function()
            jpr.command({})
            local pr_panel_ids = extract_visible_command_ids(helpers.current_text())
            assert(
                vim.deep_equal(pr_panel_ids, {
                    "open",
                    "local",
                    "sync",
                    "toggle",
                    "stream",
                    "expand",
                    "conversation",
                    "submit",
                    "push",
                    "agent",
                    "prepass",
                    "close",
                    "keys",
                }),
                "linked PR outside diff hides comment, suggest, and send: " .. vim.inspect(pr_panel_ids)
            )
            wizard.close()
        end)

        -- Linked PR session with unsent local threads exposes send.
        with_tab_session({ number = 7, repo = "octo/widgets", tab = tab, mode = "pr", view = { localUnsentCount = 2 } }, function()
            jpr.command({})
            local ids_with_unsent = extract_visible_command_ids(helpers.current_text())
            assert(vim.tbl_contains(ids_with_unsent, "send"), "send appears when localUnsentCount > 0: " .. vim.inspect(ids_with_unsent))
            wizard.close()
        end)

        -- Unlinked local review session in a changed worktree file hides PR-only submit/push/suggest.
        local previous_buf = vim.api.nvim_get_current_buf()
        local changed_buf = vim.api.nvim_create_buf(false, true)
        local original_diff = package.loaded["jpr.views.diff"]
        package.loaded["jpr.views.diff"] = {
            buffer_to_changed_path = function(_session, buf)
                return buf == changed_buf and "lua/app.lua" or nil
            end,
        }
        vim.api.nvim_win_set_buf(0, changed_buf)
        local is_local_ok, local_err = pcall(function()
            with_tab_session({ mode = "local", tab = tab, view = { localUnsentCount = 0 } }, function()
                jpr.command({})
                local local_ids = extract_visible_command_ids(helpers.current_text())
                assert(vim.tbl_contains(local_ids, "sync"), "local review keeps sync to link PR")
                assert(vim.tbl_contains(local_ids, "conversation"), "local review keeps conversation for local notes")
                assert(vim.tbl_contains(local_ids, "comment"), "local review in changed file shows comment")
                assert(not vim.tbl_contains(local_ids, "submit"), "local review hides PR-only submit")
                assert(not vim.tbl_contains(local_ids, "push"), "local review hides PR-only push")
                assert(not vim.tbl_contains(local_ids, "suggest"), "local review hides PR-only suggest")
                wizard.close()
            end)

            -- Linked PR session in changed worktree file exposes both comment and suggest.
            with_tab_session({ number = 7, repo = "octo/widgets", tab = tab, mode = "pr", view = { localUnsentCount = 0 } }, function()
                jpr.command({})
                local diff_ids = extract_visible_command_ids(helpers.current_text())
                assert(vim.tbl_contains(diff_ids, "comment"), "linked PR in changed file shows comment")
                assert(vim.tbl_contains(diff_ids, "suggest"), "linked PR in changed file shows suggest")
                wizard.close()
            end)
        end)
        package.loaded["jpr.views.diff"] = original_diff
        vim.api.nvim_win_set_buf(0, previous_buf)
        pcall(vim.api.nvim_buf_delete, changed_buf, { force = true })
        if not is_local_ok then
            error(local_err, 0)
        end

        -- Read-only crashed session hides engine-RPC commands; keeps cached conversation and live agent only when present.
        local cached_conv_buf = vim.api.nvim_create_buf(false, true)
        local live_agent_buf = vim.api.nvim_create_buf(false, true)
        local is_ro_ok, ro_err = pcall(function()
            with_tab_session({ number = 7, repo = "octo/widgets", tab = tab, mode = "pr", is_read_only = true, view = { localUnsentCount = 3 } }, function()
                jpr.command({})
                local ro_minimal_ids = extract_visible_command_ids(helpers.current_text())
                assert(
                    vim.deep_equal(ro_minimal_ids, { "open", "local", "toggle", "expand", "close", "keys" }),
                    "read-only session hides RPC commands: " .. vim.inspect(ro_minimal_ids)
                )
                wizard.close()
            end)

            with_tab_session({
                number = 7,
                repo = "octo/widgets",
                tab = tab,
                mode = "pr",
                is_read_only = true,
                conversation = { buf = cached_conv_buf },
                agent = { buf = live_agent_buf, job = 55, exited = false },
            }, function()
                jpr.command({})
                local ro_cached_ids = extract_visible_command_ids(helpers.current_text())
                assert(
                    vim.deep_equal(ro_cached_ids, { "open", "local", "toggle", "expand", "conversation", "agent", "close", "keys" }),
                    "read-only session retains cached conversation and live agent: " .. vim.inspect(ro_cached_ids)
                )
                wizard.close()
            end)
        end)
        pcall(vim.api.nvim_buf_delete, cached_conv_buf, { force = true })
        pcall(vim.api.nvim_buf_delete, live_agent_buf, { force = true })
        if not is_ro_ok then
            error(ro_err, 0)
        end
    end

    local function test_stream_file_header_shows_only_file_comment_option_and_hides_suggest()
        local tab = vim.api.nvim_get_current_tabpage()
        local previous_buf = vim.api.nvim_get_current_buf()
        local stream_render = require("jpr.render.stream")
        local stream_layout = stream_render.create_layout_from_stream({
            mode = "unified",
            rows = {
                { kind = "file", path = "lua/app.lua", additions = 1, deletions = 0, viewed = "UNVIEWED", folded = false },
                { kind = "hunk", path = "lua/app.lua", header = "@@ -0,0 +1,1 @@", target = 1 },
                { kind = "line", path = "lua/app.lua", right = { line = 1, text = "local x = 1", change = "added", words = {} }, target = 1 },
            },
        })
        local stream_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(stream_buf, 0, -1, false, stream_layout.columns[1].lines)
        vim.api.nvim_win_set_buf(0, stream_buf)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        local stub_session = {
            number = 7,
            repo = "octo/widgets",
            tab = tab,
            mode = "pr",
            stream = {
                buffers = { main = stream_buf },
                layout = stream_layout,
            },
        }
        local recorded_opts = nil
        local is_ok, call_error = pcall(function()
            with_tab_session(stub_session, function()
                context.with_stubbed_session_methods({
                    comment_current = function(opts) recorded_opts = opts end,
                }, function()
                    jpr.command({})
                    local visible_ids = extract_visible_command_ids(helpers.current_text())
                    assert(vim.tbl_contains(visible_ids, "comment"), "stream file header shows comment")
                    assert(not vim.tbl_contains(visible_ids, "suggest"), "stream file header hides suggest")

                    select_palette_command("comment")
                    local step_text = helpers.current_text()
                    assert(step_text:find("▸ File-Level Comment  [file]", 1, true) ~= nil, "only file comment shown: " .. step_text)
                    assert(step_text:find("[line]", 1, true) == nil, "line comment hidden on file header")
                    assert(step_text:find("[suggest]", 1, true) == nil, "suggest comment hidden on file header")

                    helpers.press_key("<CR>")
                    assert(not wizard.is_open() and recorded_opts ~= nil and recorded_opts.file == true, "confirms file-level comment")

                    -- Moving to the diff line in the stream exposes line, file, and suggest comment options while keeping :Jpr suggest hidden.
                    vim.api.nvim_win_set_cursor(0, { 3, 0 })
                    jpr.command({})
                    local diff_line_ids = extract_visible_command_ids(helpers.current_text())
                    assert(vim.tbl_contains(diff_line_ids, "comment"), "stream diff line shows comment")
                    assert(not vim.tbl_contains(diff_line_ids, "suggest"), "stream diff line keeps :Jpr suggest hidden")
                    select_palette_command("comment")
                    local diff_step_text = helpers.current_text()
                    assert(diff_step_text:find("▸ Line / Selection Comment  [line]", 1, true) ~= nil, "stream diff line defaults to line comment")
                    assert(diff_step_text:find("[file]", 1, true) ~= nil and diff_step_text:find("[suggest]", 1, true) ~= nil, "stream diff line exposes all 3 comment scopes")
                    wizard.close()
                end)
            end)
        end)
        vim.api.nvim_win_set_buf(0, previous_buf)
        pcall(vim.api.nvim_buf_delete, stream_buf, { force = true })
        if not is_ok then
            error(call_error, 0)
        end
    end

    local function test_palette_multi_step_commands_preselect_and_dispatch_smart_defaults()
        context.with_temp_view_mode("unified", function()
            local tab = vim.api.nvim_get_current_tabpage()
            local previous_buf = vim.api.nvim_get_current_buf()
            local base_buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_win_set_buf(0, base_buf)
            vim.b[base_buf].jpr_base_path = "README.md"

            local recorded = {}
            local is_ok, call_error = pcall(function()
                with_tab_session({ number = 7, repo = "octo/widgets", tab = tab, mode = "pr" }, function()
                    context.with_stubbed_session_methods({
                        set_view_mode = function(mode) recorded[#recorded + 1] = { fn = "set_view_mode", mode = mode } end,
                        comment_current = function(opts) recorded[#recorded + 1] = { fn = "comment_current", opts = opts } end,
                        agent_current = function(provider) recorded[#recorded + 1] = { fn = "agent_current", provider = provider } end,
                    }, function()
                        jpr.command({})
                        select_palette_command("toggle")
                        assert(wizard.is_open() and helpers.current_text():find("▸ Side-by-Side Split  [split]", 1, true) ~= nil, "toggle defaults to split")
                        helpers.press_key("<CR>")
                        assert(not wizard.is_open() and recorded[#recorded].mode == "split", "toggle stepper calls set_view_mode('split')")

                        jpr.command({})
                        select_palette_command("comment")
                        assert(wizard.is_open() and helpers.current_text():find("▸ Line / Selection Comment  [line]", 1, true) ~= nil, "comment defaults to line on diff buffer")
                        helpers.press_key("j<CR>")
                        assert(not wizard.is_open() and recorded[#recorded].opts.file == true, "comment stepper calls comment_current({ file = true })")

                        jpr.setup({ agent = "codex" })
                        jpr.command({})
                        select_palette_command("agent")
                        assert(wizard.is_open() and helpers.current_text():find("▸ Codex  [codex]", 1, true) ~= nil, "agent defaults to config.agent")
                        helpers.press_key("<CR>")
                        assert(not wizard.is_open() and recorded[#recorded].provider == "codex", "agent stepper calls agent_current('codex')")
                    end)
                end)
            end)
            vim.api.nvim_win_set_buf(0, previous_buf)
            pcall(vim.api.nvim_buf_delete, base_buf, { force = true })
            if not is_ok then
                error(call_error, 0)
            end
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
            select_palette_command("comment")
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
    test_bare_jpr_opens_palette_with_only_executable_commands_outside_session()
    test_palette_filters_by_session_mode_read_only_pending_tab_and_view()
    test_stream_file_header_shows_only_file_comment_option_and_hides_suggest()
    test_palette_multi_step_commands_preselect_and_dispatch_smart_defaults()
    test_direct_subcommand_args_bypass_modal_and_reject_invalid_values()
    test_comment_smart_default_preselects_line_on_diff_line()
end
