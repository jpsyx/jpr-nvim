-- Executable-only Command Palette filtering across pending tabs, session modes,
-- read-only fallback, unsent local comments, changed files, and stream rows.
return function(context)
    local helpers = context.helpers
    local jpr = context.jpr
    local session = context.session
    local wizard = context.wizard

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
            local selected_line = helpers.palette_results_text():match("▸[^\n]+") or ""
            if selected_line:find(needle, 1, true) ~= nil then
                helpers.press_key("<CR>")
                return
            end
            helpers.press_key("j")
        end
        error("command " .. command_id .. " not found in palette:\n" .. helpers.palette_results_text())
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

    local function with_changed_worktree_buffer(callback)
        local previous_buf = vim.api.nvim_get_current_buf()
        local changed_buf = vim.api.nvim_create_buf(false, true)
        local original_diff = package.loaded["jpr.views.diff"]
        package.loaded["jpr.views.diff"] = {
            buffer_to_changed_path = function(_session, buf)
                return buf == changed_buf and "lua/app.lua" or nil
            end,
        }
        vim.api.nvim_win_set_buf(0, changed_buf)
        local is_ok, call_error = pcall(callback)
        package.loaded["jpr.views.diff"] = original_diff
        vim.api.nvim_win_set_buf(0, previous_buf)
        pcall(vim.api.nvim_buf_delete, changed_buf, { force = true })
        if not is_ok then
            error(call_error, 0)
        end
    end

    local function create_stream_session_fixture(tab)
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
        local stub_session = {
            number = 7,
            repo = "octo/widgets",
            tab = tab,
            mode = "pr",
            stream = { buffers = { main = stream_buf }, layout = stream_layout },
        }
        return stream_buf, stub_session
    end

    local function test_pending_checkout_tab_exposes_close_without_session_commands()
        context.with_stubbed_session_methods({
            has_pending_tab = function() return true end,
        }, function()
            jpr.command({})
            local pending_ids = extract_visible_command_ids(helpers.palette_results_text())
            assert(
                vim.deep_equal(pending_ids, { "open", "local", "close", "keys" }),
                "pending checkout tab shows open, local, close, keys: " .. vim.inspect(pending_ids)
            )
            wizard.close()
        end)
    end

    local function test_linked_pr_outside_diff_hides_comment_suggest_and_zero_unsent_send()
        local tab = vim.api.nvim_get_current_tabpage()
        with_tab_session({ number = 7, repo = "octo/widgets", tab = tab, mode = "pr", view = { localUnsentCount = 0 } }, function()
            jpr.command({})
            local pr_panel_ids = extract_visible_command_ids(helpers.palette_results_text())
            assert(
                vim.deep_equal(pr_panel_ids, {
                    "open", "local", "sync", "toggle", "stream", "expand",
                    "conversation", "submit", "push", "agent", "prepass", "close", "keys",
                }),
                "linked PR outside diff hides comment, suggest, and send: " .. vim.inspect(pr_panel_ids)
            )
            wizard.close()
        end)

        with_tab_session({ number = 7, repo = "octo/widgets", tab = tab, mode = "pr", view = { localUnsentCount = 2 } }, function()
            jpr.command({})
            local ids_with_unsent = extract_visible_command_ids(helpers.palette_results_text())
            assert(vim.tbl_contains(ids_with_unsent, "send"), "send appears when localUnsentCount > 0")
            wizard.close()
        end)
    end

    local function test_unlinked_local_review_hides_pr_only_commands_in_changed_file()
        local tab = vim.api.nvim_get_current_tabpage()
        with_changed_worktree_buffer(function()
            with_tab_session({ mode = "local", tab = tab, view = { localUnsentCount = 0 } }, function()
                jpr.command({})
                local local_ids = extract_visible_command_ids(helpers.palette_results_text())
                assert(vim.tbl_contains(local_ids, "sync"), "local review keeps sync to link PR")
                assert(vim.tbl_contains(local_ids, "conversation"), "local review keeps conversation for local notes")
                assert(vim.tbl_contains(local_ids, "comment"), "local review in changed file shows comment")
                assert(not vim.tbl_contains(local_ids, "submit"), "local review hides PR-only submit")
                assert(not vim.tbl_contains(local_ids, "push"), "local review hides PR-only push")
                assert(not vim.tbl_contains(local_ids, "suggest"), "local review hides PR-only suggest")
                wizard.close()
            end)

            with_tab_session({ number = 7, repo = "octo/widgets", tab = tab, mode = "pr", view = { localUnsentCount = 0 } }, function()
                jpr.command({})
                local diff_ids = extract_visible_command_ids(helpers.palette_results_text())
                assert(vim.tbl_contains(diff_ids, "comment"), "linked PR in changed file shows comment")
                assert(vim.tbl_contains(diff_ids, "suggest"), "linked PR in changed file shows suggest")
                wizard.close()
            end)
        end)
    end

    local function test_read_only_crashed_session_hides_rpc_commands_unless_cached_or_live()
        local tab = vim.api.nvim_get_current_tabpage()
        local cached_conversation_buf = vim.api.nvim_create_buf(false, true)
        local live_agent_buf = vim.api.nvim_create_buf(false, true)
        local is_read_only_ok, read_only_error = pcall(function()
            with_tab_session({ number = 7, repo = "octo/widgets", tab = tab, mode = "pr", is_read_only = true, view = { localUnsentCount = 3 } }, function()
                jpr.command({})
                local read_only_minimal_ids = extract_visible_command_ids(helpers.palette_results_text())
                assert(
                    vim.deep_equal(read_only_minimal_ids, { "open", "local", "toggle", "expand", "close", "keys" }),
                    "read-only session hides RPC commands: " .. vim.inspect(read_only_minimal_ids)
                )
                wizard.close()
            end)

            with_tab_session({
                number = 7,
                repo = "octo/widgets",
                tab = tab,
                mode = "pr",
                is_read_only = true,
                conversation = { buf = cached_conversation_buf },
                agent = { buf = live_agent_buf, job = 55, exited = false },
            }, function()
                jpr.command({})
                local read_only_cached_ids = extract_visible_command_ids(helpers.palette_results_text())
                assert(
                    vim.deep_equal(read_only_cached_ids, { "open", "local", "toggle", "expand", "conversation", "agent", "close", "keys" }),
                    "read-only session retains cached conversation and live agent: " .. vim.inspect(read_only_cached_ids)
                )
                wizard.close()
            end)
        end)
        pcall(vim.api.nvim_buf_delete, cached_conversation_buf, { force = true })
        pcall(vim.api.nvim_buf_delete, live_agent_buf, { force = true })
        if not is_read_only_ok then
            error(read_only_error, 0)
        end
    end

    local function test_stream_rows_gate_comment_scopes_and_hide_worktree_suggest()
        local tab = vim.api.nvim_get_current_tabpage()
        local previous_buf = vim.api.nvim_get_current_buf()
        local stream_buf, stub_session = create_stream_session_fixture(tab)
        vim.api.nvim_win_set_buf(0, stream_buf)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        local recorded_opts = nil
        local is_ok, call_error = pcall(function()
            with_tab_session(stub_session, function()
                context.with_stubbed_session_methods({
                    comment_current = function(opts) recorded_opts = opts end,
                }, function()
                    jpr.command({})
                    local header_ids = extract_visible_command_ids(helpers.palette_results_text())
                    assert(vim.tbl_contains(header_ids, "comment"), "stream file header shows comment")
                    assert(not vim.tbl_contains(header_ids, "suggest"), "stream file header hides suggest")

                    select_palette_command("comment")
                    local header_step_text = helpers.current_text()
                    assert(header_step_text:find("▸ File-Level Comment  [file]", 1, true) ~= nil, "only file comment shown")
                    assert(header_step_text:find("[line]", 1, true) == nil and header_step_text:find("[suggest]", 1, true) == nil, "line and suggest hidden on header")
                    helpers.press_key("<CR>")
                    assert(not wizard.is_open() and recorded_opts ~= nil and recorded_opts.file == true, "confirms file-level comment")

                    vim.api.nvim_win_set_cursor(0, { 3, 0 })
                    jpr.command({})
                    assert(not vim.tbl_contains(extract_visible_command_ids(helpers.palette_results_text()), "suggest"), "stream diff line keeps suggest hidden")
                    select_palette_command("comment")
                    local diff_step_text = helpers.current_text()
                    assert(diff_step_text:find("▸ Line / Selection Comment  [line]", 1, true) ~= nil, "stream diff line defaults to line")
                    assert(diff_step_text:find("[file]", 1, true) ~= nil and diff_step_text:find("[suggest]", 1, true) ~= nil, "stream diff line exposes all scopes")
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

    test_pending_checkout_tab_exposes_close_without_session_commands()
    test_linked_pr_outside_diff_hides_comment_suggest_and_zero_unsent_send()
    test_unlinked_local_review_hides_pr_only_commands_in_changed_file()
    test_read_only_crashed_session_hides_rpc_commands_unless_cached_or_live()
    test_stream_rows_gate_comment_scopes_and_hide_worktree_suggest()
end
