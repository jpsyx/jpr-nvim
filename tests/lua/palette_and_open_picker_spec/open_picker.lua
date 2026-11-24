-- `:Jpr open` PR picker listing, metadata hover, step-back manual input, empty state, and badges specs.
return function(context)
    local helpers = context.helpers
    local jpr = context.jpr
    local session = context.session
    local wizard = context.wizard

    local function test_open_picker_lists_prs_hovers_metadata_and_opens_selected()
        local fake_binary = context.write_fake_prs_binary(context.create_two_pr_payload())
        local opened_call = nil
        context.with_stubbed_session_methods({
            open = function(number, repo)
                opened_call = { number = number, repo = repo }
            end,
        }, function()
            jpr.setup({ binary = fake_binary })
            jpr.command({ "open" })
            assert(wizard.is_open() == true, ":Jpr open opens PR picker modal")
            assert(vim.wait(3000, function()
                return wizard.is_open() and helpers.current_text():find("#42  Add OAuth", 1, true) ~= nil
            end), "PR picker loads and paints open PRs")

            local first_text = helpers.current_text()
            assert(first_text:find("▸ #42  Add OAuth", 1, true) ~= nil, "PR #42 highlighted: " .. first_text)
            assert(first_text:find("#43  WIP refactor  [draft]", 1, true) ~= nil, "PR #43 shows [draft] badge: " .. first_text)
            assert(first_text:find("@alice · feat/oauth · updated 2026-11-23", 1, true) ~= nil, "PR #42 hover metadata visible")
            assert(first_text:find("@bob · refactor/core · updated 2026-11-22", 1, true) == nil, "PR #43 hover metadata hidden")

            helpers.press_key("j")
            local second_text = helpers.current_text()
            assert(second_text:find("▸ #43  WIP refactor  [draft]", 1, true) ~= nil, "j highlights PR #43")
            assert(second_text:find("@bob · refactor/core · updated 2026-11-22", 1, true) ~= nil, "PR #43 hover metadata visible")
            assert(second_text:find("@alice · feat/oauth · updated 2026-11-23", 1, true) == nil, "PR #42 hover metadata hidden")

            helpers.press_key("<CR>")
            assert(wizard.is_open() == false, "confirming PR closes picker")
            assert(opened_call ~= nil and opened_call.number == 43, "confirming PR #43 calls session.open(43)")
        end)
    end

    local function test_open_picker_skips_malformed_entries_and_falls_back_on_null_fields()
        local payload = '["bad",{"title":"missing number"},{"number":55,"title":null,"author":null,"headRef":null,"isDraft":false,"updatedAt":null}]'
        local fake_binary = context.write_fake_prs_binary(payload)
        context.with_stubbed_session_methods({}, function()
            jpr.setup({ binary = fake_binary })
            jpr.command({ "open" })
            assert(vim.wait(3000, function()
                return wizard.is_open() and helpers.current_text():find("#55", 1, true) ~= nil
            end), "PR picker renders valid PR even when malformed entries exist")

            local text = helpers.current_text()
            assert(text:find("vim.NIL", 1, true) == nil, "null title must not render vim.NIL: " .. text)
            assert(text:find("@ghost · updated unknown", 1, true) ~= nil, "null fields fall back safely: " .. text)
        end)
    end

    local function test_open_picker_steps_back_to_manual_input_and_opens_entered_pr()
        local fake_binary = context.write_fake_prs_binary(context.create_two_pr_payload())
        local opened_call = nil
        context.with_stubbed_session_methods({
            open = function(number, repo)
                opened_call = { number = number, repo = repo }
            end,
        }, function()
            jpr.setup({ binary = fake_binary })
            jpr.command({ "open" })
            assert(vim.wait(3000, function()
                return wizard.is_open() and helpers.current_text():find("#42  Add OAuth", 1, true) ~= nil
            end), "PR picker loaded before stepping back")

            helpers.press_key("h")
            assert(wizard.is_open() and helpers.current_text():find("Pull Request Source", 1, true) ~= nil, "h steps back to Step 1")

            helpers.press_key("j<CR>")
            assert(helpers.win_title(helpers.current_float_win()):find("Pull Request Number or URL", 1, true) ~= nil, "manual step opened")

            helpers.press_key("i#99<CR>")
            assert(wizard.is_open() == false, "submitting #99 closes manual step")
            assert(opened_call ~= nil and opened_call.number == 99, "manual input #99 calls session.open(99)")
        end)
    end

    local function test_open_picker_empty_prs_notifies_user()
        local fake_binary = context.write_fake_prs_binary("[]")
        context.clear_notifications()
        context.with_stubbed_session_methods({}, function()
            jpr.setup({ binary = fake_binary })
            jpr.command({ "open" })

            assert(vim.wait(3000, function()
                return context.has_notification("no open pull requests in this repository", vim.log.levels.INFO)
            end), "empty PR list notifies user: " .. vim.inspect(context.notifications))

            assert(wizard.is_open() == true, "empty picker stays open for h back or close")
            assert(helpers.current_text():find("No open pull requests in this repository", 1, true) ~= nil, "empty state message rendered")
        end)
    end

    local function test_open_picker_suppresses_empty_notification_after_async_cancellation()
        local pending_on_result = nil
        context.with_stubbed_session_methods({
            list_open_prs = function(on_result, _on_error)
                pending_on_result = on_result
            end,
        }, function()
            jpr.command({ "open" })
            assert(wizard.is_open() == true and pending_on_result ~= nil, "open picker starts async PR load")
            wizard.close()
            context.clear_notifications()
            pending_on_result({})
            assert(
                not context.has_notification("no open pull requests in this repository", vim.log.levels.INFO),
                "closing modal before empty callback suppresses INFO notification: " .. vim.inspect(context.notifications)
            )

            pending_on_result = nil
            jpr.command({ "open" })
            assert(wizard.is_open() == true and pending_on_result ~= nil, "reopened picker starts async PR load")
            helpers.press_key("h")
            assert(helpers.current_text():find("Pull Request Source", 1, true) ~= nil, "h steps back before load completes")
            context.clear_notifications()
            pending_on_result({})
            assert(
                not context.has_notification("no open pull requests in this repository", vim.log.levels.INFO),
                "stepping back before empty callback suppresses INFO notification: " .. vim.inspect(context.notifications)
            )
            assert(helpers.current_text():find("Pull Request Source", 1, true) ~= nil, "Step 1 stays displayed")
        end)
    end

    local function test_open_picker_shows_open_badge_for_active_tab_pr()
        local fake_binary = context.write_fake_prs_binary(context.create_two_pr_payload())
        local tab = vim.api.nvim_get_current_tabpage()
        local original_by_tab = session.by_tab[tab]
        session.by_tab[tab] = { number = 42, repo = "octo/widgets", tab = tab }

        local is_ok, call_error = pcall(context.with_stubbed_session_methods, {}, function()
            jpr.setup({ binary = fake_binary })
            jpr.command({ "open" })
            assert(vim.wait(3000, function()
                return wizard.is_open() and helpers.current_text():find("#42  Add OAuth", 1, true) ~= nil
            end), "PR picker loads with open tab")
            assert(helpers.current_text():find("#42  Add OAuth  [open]", 1, true) ~= nil, "open PR displays [open] badge")
        end)
        session.by_tab[tab] = original_by_tab
        if not is_ok then
            error(call_error, 0)
        end
    end

    test_open_picker_lists_prs_hovers_metadata_and_opens_selected()
    test_open_picker_skips_malformed_entries_and_falls_back_on_null_fields()
    test_open_picker_steps_back_to_manual_input_and_opens_entered_pr()
    test_open_picker_empty_prs_notifies_user()
    test_open_picker_suppresses_empty_notification_after_async_cancellation()
    test_open_picker_shows_open_badge_for_active_tab_pr()
end
