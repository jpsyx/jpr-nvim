-- Agent provider switching, view mode redraws, and `list_open_prs` CLI error path specs.
return function(context)
    local helpers = context.helpers
    local jpr = context.jpr
    local agent = context.agent
    local session = context.session
    local view_mode = context.view_mode
    local wizard = context.wizard

    local function test_live_agent_skips_provider_step_from_palette()
        local tab = vim.api.nvim_get_current_tabpage()
        local current_win = vim.api.nvim_get_current_win()
        local live_buf = vim.api.nvim_create_buf(false, true)
        local original_by_tab = session.by_tab[tab]
        local agent_calls = {}

        local function select_agent_from_palette()
            for _ = 1, 20 do
                local selected_line = helpers.current_text():match("▸[^\n]+") or ""
                if selected_line:find("[agent]", 1, true) ~= nil then
                    helpers.press_key("<CR>")
                    return
                end
                helpers.press_key("j")
            end
            error("agent command not found in palette:\n" .. helpers.current_text())
        end

        session.by_tab[tab] = {
            number = 42,
            repo = "octo/widgets",
            tab = tab,
            agent = { win = current_win, buf = live_buf, job = 99, exited = false, kind = "claude" },
        }
        local is_ok, call_error = pcall(context.with_stubbed_session_methods, {
            agent_current = function(provider) agent_calls[#agent_calls + 1] = { provider = provider } end,
        }, function()
            assert(agent.is_open(session.by_tab[tab]) == true, "agent.is_open detects open window")
            jpr.command({})
            select_agent_from_palette()
            assert(not wizard.is_open() and #agent_calls == 1 and agent_calls[1].provider == nil, "open agent skips stepper")

            -- Live-but-hidden agent also skips provider stepper.
            session.by_tab[tab].agent.win = nil
            assert(agent.is_open(session.by_tab[tab]) == false and agent.has_live_agent(session.by_tab[tab]) == true, "hidden live agent detected")
            jpr.command({})
            select_agent_from_palette()
            assert(not wizard.is_open() and #agent_calls == 2 and agent_calls[2].provider == nil, "hidden live agent skips stepper")
        end)
        session.by_tab[tab] = original_by_tab
        pcall(vim.api.nvim_buf_delete, live_buf, { force = true })
        if not is_ok then
            error(call_error, 0)
        end
    end

    local function test_agent_toggle_launches_explicit_provider_reopens_same_and_warns_on_mismatch()
        local launched_params = nil
        local tab = vim.api.nvim_get_current_tabpage()
        local fake_session = { number = 7, tab = tab }
        local live_buf = vim.api.nvim_create_buf(false, true)
        local is_ok, call_error = pcall(context.with_stubbed_session_methods, {
            request = function(_session, method, params)
                if method == "prepareAgentLaunch" then
                    launched_params = params
                end
            end,
        }, function()
            jpr.setup({ agent = "claude" })
            agent.toggle(fake_session, "codex")
            assert(launched_params ~= nil and launched_params.agent == "codex", "agent.toggle launches explicit agent_kind")
            fake_session.agent_pending_callbacks = nil

            -- Live hidden claude agent: explicit same provider reopens without switching notice.
            fake_session.agent = { buf = live_buf, win = nil, job = 42, exited = false, kind = "claude" }
            context.clear_notifications()
            agent.toggle(fake_session, "claude")
            assert(agent.is_open(fake_session) == true, "same explicit provider reopens hidden live agent")
            assert(not context.has_notification("already running", vim.log.levels.INFO), "same provider emits no switch warning")

            -- Live open claude agent: explicit different provider informs user and keeps window open.
            context.clear_notifications()
            agent.toggle(fake_session, "codex")
            assert(agent.is_open(fake_session) == true, "different explicit provider does not close running agent")
            assert(context.has_notification("already running claude; close it before switching to codex", vim.log.levels.INFO), "notifies running provider")
        end)
        if fake_session.agent and fake_session.agent.win and vim.api.nvim_win_is_valid(fake_session.agent.win) then
            pcall(vim.api.nvim_win_close, fake_session.agent.win, true)
        end
        pcall(vim.api.nvim_buf_delete, live_buf, { force = true })
        if not is_ok then
            error(call_error, 0)
        end
    end

    local function test_real_session_set_view_mode_updates_mode_and_redraws()
        context.with_temp_view_mode("unified", function()
            local tab = vim.api.nvim_get_current_tabpage()
            local original_by_tab = session.by_tab[tab]
            local original_diff, original_stream = package.loaded["jpr.views.diff"], package.loaded["jpr.views.stream"]
            local diff_redraws, stream_refreshes = 0, 0
            session.by_tab[tab] = { number = 7, tab = tab, client = {}, is_read_only = false }
            package.loaded["jpr.views.diff"] = { redraw_all = function() diff_redraws = diff_redraws + 1 end }
            package.loaded["jpr.views.stream"] = { refresh = function() stream_refreshes = stream_refreshes + 1 end }

            local is_ok, call_error = pcall(function()
                context.clear_notifications()
                session.set_view_mode("split")
                assert(view_mode.get() == "split" and diff_redraws == 1 and stream_refreshes == 1, "set_view_mode switches to split and redraws")
                assert(context.has_notification("split view", vim.log.levels.INFO), "set_view_mode notifies split view")

                context.clear_notifications()
                session.set_view_mode("unified")
                assert(view_mode.get() == "unified" and diff_redraws == 2 and stream_refreshes == 2, "set_view_mode switches to unified and redraws")
                assert(context.has_notification("unified view", vim.log.levels.INFO), "set_view_mode notifies unified view")

                context.clear_notifications()
                session.set_view_mode("invalid")
                assert(view_mode.get() == "unified" and diff_redraws == 2, "invalid mode keeps previous view_mode")
                assert(context.has_notification("invalid diff view", vim.log.levels.ERROR), "invalid mode emits error")
            end)

            session.by_tab[tab] = original_by_tab
            package.loaded["jpr.views.diff"], package.loaded["jpr.views.stream"] = original_diff, original_stream
            if not is_ok then
                error(call_error, 0)
            end
        end)
    end

    local function collect_list_open_prs_error(binary_path)
        local received_error = nil
        jpr.setup({ binary = binary_path })
        session.list_open_prs(function()
            error("expected list_open_prs to fail for " .. tostring(binary_path))
        end, function(error_message)
            received_error = error_message
        end)
        assert(vim.wait(3000, function()
            return received_error ~= nil
        end), "expected on_error callback to fire")
        jpr.setup({})
        return received_error
    end

    local function test_list_open_prs_reports_build_hint_sanitizes_stderr_and_rejects_invalid_json()
        local missing_error = collect_list_open_prs_error(vim.fn.tempname() .. "/missing-jpr-review")
        assert(missing_error:find(":Lazy build jpr-nvim", 1, true) ~= nil, "missing binary hints :Lazy build jpr-nvim: " .. missing_error)

        local failing_binary = context.write_executable_script({
            "#!/bin/sh",
            "printf 'gh auth required\\007\\nsecond line\\n' >&2",
            "exit 1",
        })
        local exit_error = collect_list_open_prs_error(failing_binary)
        assert(exit_error == "gh auth required second line", "non-zero exit sanitizes control bytes and newlines: " .. vim.inspect(exit_error))

        local malformed_binary = context.write_executable_script({ "#!/bin/sh", "printf '{not-json\\n'", "exit 0" })
        local parse_error = collect_list_open_prs_error(malformed_binary)
        assert(parse_error:find("failed to parse open pull requests", 1, true) ~= nil, "malformed JSON reports parse error: " .. parse_error)

        local object_binary = context.write_executable_script({ "#!/bin/sh", "printf '{}\\n'", "exit 0" })
        local object_error = collect_list_open_prs_error(object_binary)
        assert(object_error:find("failed to parse open pull requests", 1, true) ~= nil, "JSON object {} rejected as non-list: " .. object_error)
    end

    test_live_agent_skips_provider_step_from_palette()
    test_agent_toggle_launches_explicit_provider_reopens_same_and_warns_on_mismatch()
    test_real_session_set_view_mode_updates_mode_and_redraws()
    test_list_open_prs_reports_build_hint_sanitizes_stderr_and_rejects_invalid_json()
end
