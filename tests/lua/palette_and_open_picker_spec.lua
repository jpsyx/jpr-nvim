local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")

local helpers = dofile(root .. "/tests/lua/support/helpers.lua")
local jpr = require("jpr")
local session = require("jpr.session")
local view_mode = require("jpr.view_mode")
local wizard = require("jpr.tui.wizard")
local tui_schema = require("jpr.tui.schema")
local commands_schema = require("jpr.commands.schema")

local notifications = {}
vim.notify = function(message, level)
    notifications[#notifications + 1] = { text = message, level = level }
end

local function clear_notifications()
    notifications = {}
end

local function has_notification(substring, expected_level)
    for _, entry in ipairs(notifications) do
        local level_ok = expected_level == nil or entry.level == expected_level
        if level_ok and entry.text:find(substring, 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function current_float_win()
    local win = vim.api.nvim_get_current_win()
    local config = vim.api.nvim_win_get_config(win)
    assert(config.relative and config.relative ~= "", "expected active floating window")
    return win
end

local function current_text()
    local win = current_float_win()
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    return table.concat(lines, "\n")
end

local function write_fake_prs_binary(payload_json)
    local script_path = vim.fn.tempname() .. "-jpr-review"
    vim.fn.writefile({
        "#!/bin/sh",
        'if [ "$1" = "prs" ]; then',
        "  printf '%s\\n' " .. vim.fn.shellescape(payload_json),
        "  exit 0",
        "fi",
        "exit 1",
    }, script_path)
    vim.uv.fs_chmod(script_path, tonumber("755", 8))
    return script_path
end

local function create_two_pr_payload()
    return vim.json.encode({
        {
            number = 42,
            title = "Add OAuth",
            author = "alice",
            headRef = "feat/oauth",
            isDraft = false,
            updatedAt = "2026-11-23T12:00:00Z",
        },
        {
            number = 43,
            title = "WIP refactor",
            author = "bob",
            headRef = "refactor/core",
            isDraft = true,
            updatedAt = "2026-11-22T09:30:00Z",
        },
    })
end

local function with_stubbed_session_methods(stubs, callback)
    local originals = {}
    for key, replacement in pairs(stubs) do
        originals[key] = session[key]
        session[key] = replacement
    end
    local is_ok, err = pcall(callback)
    for key, original in pairs(originals) do
        session[key] = original
    end
    jpr.setup({})
    if not is_ok then
        error(err, 0)
    end
end

local function test_command_schema_completeness()
    local specs = commands_schema.create_command_specs()
    local is_valid, validation_error = tui_schema.validate_command_specs(specs)
    assert(is_valid == true, "command specs valid: " .. tostring(validation_error))
    assert(#specs == 14, "expected 14 command specs, got " .. tostring(#specs))
    assert(vim.deep_equal(commands_schema.list_command_ids(), jpr.subcommands), "list_command_ids matches jpr.subcommands")

    for _, spec in ipairs(specs) do
        assert(spec.label ~= spec.id, "label must be human-readable and distinct from id: " .. spec.id)
        assert(type(spec.help) == "string" and spec.help:match("%S") ~= nil, "help must be non-empty: " .. spec.id)
        assert(not spec.help:find("\226\128\148", 1, true), "help must not contain em dash: " .. spec.id)
    end

    assert(commands_schema.format_pr_updated_date("2026-11-23T12:00:00Z") == "2026-11-23", "extracts ISO date")
    assert(commands_schema.format_pr_updated_date("") == "unknown", "empty timestamp falls back to unknown")
    assert(commands_schema.format_pr_updated_date(nil) == "unknown", "nil timestamp falls back to unknown")
end

local function test_bare_jpr_opens_palette_with_hover_helper_text()
    jpr.command({})
    assert(wizard.is_open() == true, "bare :Jpr opens floating Command Palette")

    local first_text = current_text()
    assert(first_text:find("▸ Open Pull Request  [open]", 1, true) ~= nil, "first row selected: " .. first_text)
    assert(first_text:find("Pick an open pull request", 1, true) ~= nil, "open hover helper text visible")
    assert(first_text:find("Fetch the latest pull request commits", 1, true) == nil, "sync helper text hidden initially")

    helpers.press_key("j")
    local second_text = current_text()
    assert(second_text:find("▸ Sync with GitHub  [sync]", 1, true) ~= nil, "j moves selection to sync: " .. second_text)
    assert(second_text:find("Fetch the latest pull request commits", 1, true) ~= nil, "sync hover helper text visible")
    assert(second_text:find("Pick an open pull request", 1, true) == nil, "open helper text hidden after move")

    wizard.close()
    assert(wizard.is_open() == false, "palette closed cleanly")
end

local function test_open_picker_lists_prs_hovers_metadata_and_opens_selected()
    local fake_binary = write_fake_prs_binary(create_two_pr_payload())
    local opened_call = nil
    with_stubbed_session_methods({
        open = function(number, repo)
            opened_call = { number = number, repo = repo }
        end,
    }, function()
        jpr.setup({ binary = fake_binary })
        jpr.command({ "open" })
        assert(wizard.is_open() == true, ":Jpr open opens PR picker modal")
        assert(vim.wait(3000, function()
            return wizard.is_open() and current_text():find("#42  Add OAuth", 1, true) ~= nil
        end), "PR picker loads and paints open PRs")

        local first_text = current_text()
        assert(first_text:find("▸ #42  Add OAuth", 1, true) ~= nil, "PR #42 highlighted: " .. first_text)
        assert(first_text:find("#43  WIP refactor  [draft]", 1, true) ~= nil, "PR #43 shows [draft] badge: " .. first_text)
        assert(first_text:find("@alice · feat/oauth · updated 2026-11-23", 1, true) ~= nil, "PR #42 hover metadata visible")
        assert(first_text:find("@bob · refactor/core · updated 2026-11-22", 1, true) == nil, "PR #43 hover metadata hidden")

        helpers.press_key("j")
        local second_text = current_text()
        assert(second_text:find("▸ #43  WIP refactor  [draft]", 1, true) ~= nil, "j highlights PR #43")
        assert(second_text:find("@bob · refactor/core · updated 2026-11-22", 1, true) ~= nil, "PR #43 hover metadata visible")
        assert(second_text:find("@alice · feat/oauth · updated 2026-11-23", 1, true) == nil, "PR #42 hover metadata hidden")

        helpers.press_key("<CR>")
        assert(wizard.is_open() == false, "confirming PR closes picker")
        assert(opened_call ~= nil and opened_call.number == 43, "confirming PR #43 calls session.open(43)")
    end)
end

local function test_open_picker_step_back_to_manual_pr_input()
    local fake_binary = write_fake_prs_binary(create_two_pr_payload())
    local opened_call = nil
    with_stubbed_session_methods({
        open = function(number, repo)
            opened_call = { number = number, repo = repo }
        end,
    }, function()
        jpr.setup({ binary = fake_binary })
        jpr.command({ "open" })
        assert(vim.wait(3000, function()
            return wizard.is_open() and current_text():find("#42  Add OAuth", 1, true) ~= nil
        end), "PR picker loaded before stepping back")

        helpers.press_key("h")
        assert(wizard.is_open() and current_text():find("Pull Request Source", 1, true) ~= nil, "h steps back to Step 1")

        helpers.press_key("j<CR>")
        assert(helpers.win_title(current_float_win()):find("Pull Request Number or URL", 1, true) ~= nil, "manual step opened")

        helpers.press_key("i#99<CR>")
        assert(wizard.is_open() == false, "submitting #99 closes manual step")
        assert(opened_call ~= nil and opened_call.number == 99, "manual input #99 calls session.open(99)")
    end)
end

local function test_open_picker_empty_prs_notifies_user()
    local fake_binary = write_fake_prs_binary("[]")
    clear_notifications()
    jpr.setup({ binary = fake_binary })
    jpr.command({ "open" })

    assert(vim.wait(3000, function()
        return has_notification("no open pull requests in this repository", vim.log.levels.INFO)
    end), "empty PR list notifies user: " .. vim.inspect(notifications))

    assert(wizard.is_open() == true, "empty picker stays open for h back or close")
    assert(current_text():find("No open pull requests in this repository", 1, true) ~= nil, "empty state message rendered")

    wizard.close()
    jpr.setup({})
end

local function test_multi_step_palette_commands_smart_defaults()
    view_mode.path = vim.fn.tempname()
    view_mode.reset()
    view_mode.set("unified")

    local recorded = {}
    with_stubbed_session_methods({
        set_view_mode = function(mode) recorded[#recorded + 1] = { fn = "set_view_mode", mode = mode } end,
        comment_current = function(opts) recorded[#recorded + 1] = { fn = "comment_current", opts = opts } end,
        agent_current = function(provider) recorded[#recorded + 1] = { fn = "agent_current", provider = provider } end,
    }, function()
        jpr.command({})
        helpers.press_key("jj<CR>")
        assert(wizard.is_open() and current_text():find("▸ Side-by-Side Split  [split]", 1, true) ~= nil, "toggle defaults to split")
        helpers.press_key("<CR>")
        assert(not wizard.is_open() and recorded[#recorded].mode == "split", "toggle stepper calls set_view_mode('split')")

        jpr.command({})
        helpers.press_key("jjjj<CR>")
        assert(wizard.is_open() and current_text():find("▸ File-Level Comment  [file]", 1, true) ~= nil, "comment defaults to file")
        helpers.press_key("<CR>")
        assert(not wizard.is_open() and recorded[#recorded].opts.file == true, "comment stepper calls comment_current({ file = true })")

        jpr.setup({ agent = "codex" })
        jpr.command({})
        helpers.press_key(string.rep("j", 10) .. "<CR>")
        assert(wizard.is_open() and current_text():find("▸ Codex  [codex]", 1, true) ~= nil, "agent defaults to config.agent")
        helpers.press_key("<CR>")
        assert(not wizard.is_open() and recorded[#recorded].provider == "codex", "agent stepper calls agent_current('codex')")
    end)
end

local function test_direct_subcommand_args_and_validation()
    local recorded = {}
    with_stubbed_session_methods({
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

        clear_notifications()
        jpr.command({ "toggle", "invalid" })
        assert(not wizard.is_open() and has_notification("invalid diff view", vim.log.levels.ERROR), "invalid toggle arg errors")

        clear_notifications()
        jpr.command({ "comment", "invalid" })
        assert(not wizard.is_open() and has_notification("invalid comment scope", vim.log.levels.ERROR), "invalid comment arg errors")

        clear_notifications()
        jpr.command({ "agent", "invalid" })
        assert(not wizard.is_open() and has_notification("invalid agent", vim.log.levels.ERROR), "invalid agent arg errors")
    end)
end

local function test_open_tab_badge_and_open_agent_skips_provider_step()
    local fake_binary = write_fake_prs_binary(create_two_pr_payload())
    local tab = vim.api.nvim_get_current_tabpage()
    local current_win = vim.api.nvim_get_current_win()
    local original_by_tab = session.by_tab[tab]
    local agent_calls = {}

    session.by_tab[tab] = { number = 42, repo = "octo/widgets", tab = tab, agent = { win = current_win } }
    with_stubbed_session_methods({
        agent_current = function(provider)
            agent_calls[#agent_calls + 1] = { provider = provider }
        end,
    }, function()
        jpr.setup({ binary = fake_binary })
        jpr.command({ "open" })
        assert(vim.wait(3000, function()
            return wizard.is_open() and current_text():find("#42  Add OAuth", 1, true) ~= nil
        end), "PR picker loads with open tab")
        assert(current_text():find("#42  Add OAuth  [open]", 1, true) ~= nil, "open PR displays [open] badge")
        wizard.close()

        assert(require("jpr.agent").is_open(session.by_tab[tab]) == true, "agent.is_open detects open window")
        jpr.command({})
        helpers.press_key(string.rep("j", 10) .. "<CR>")
        assert(not wizard.is_open(), "open agent skips provider stepper and closes palette")
        assert(#agent_calls == 1 and agent_calls[1].provider == nil, "open agent calls agent_current(nil) immediately")
    end)
    session.by_tab[tab] = original_by_tab
end

local function test_agent_toggle_forwards_explicit_agent_kind()
    local launched_params = nil
    local fake_session = { number = 7, tab = vim.api.nvim_get_current_tabpage() }
    with_stubbed_session_methods({
        request = function(_session, method, params)
            if method == "prepareAgentLaunch" then
                launched_params = params
            end
        end,
    }, function()
        jpr.setup({ agent = "claude" })
        require("jpr.agent").toggle(fake_session, "codex")
        assert(launched_params ~= nil and launched_params.agent == "codex", "agent.toggle forwards explicit agent_kind")
        fake_session.agent_pending_callbacks = nil
    end)
end

local function write_executable_script(script_lines)
    local script_path = vim.fn.tempname() .. "-jpr-review"
    vim.fn.writefile(script_lines, script_path)
    vim.uv.fs_chmod(script_path, tonumber("755", 8))
    return script_path
end

local function test_real_session_set_view_mode_updates_mode_and_redraws()
    view_mode.path = vim.fn.tempname()
    view_mode.reset()
    view_mode.set("unified")

    local tab = vim.api.nvim_get_current_tabpage()
    local original_by_tab = session.by_tab[tab]
    local original_diff, original_stream = package.loaded["jpr.views.diff"], package.loaded["jpr.views.stream"]
    local diff_redraws, stream_refreshes = 0, 0
    local fake_session = { number = 7, tab = tab, client = {}, is_read_only = false }
    session.by_tab[tab] = fake_session
    package.loaded["jpr.views.diff"] = { redraw_all = function() diff_redraws = diff_redraws + 1 end }
    package.loaded["jpr.views.stream"] = { refresh = function() stream_refreshes = stream_refreshes + 1 end }

    local is_ok, err = pcall(function()
        clear_notifications()
        session.set_view_mode("split")
        assert(view_mode.get() == "split" and diff_redraws == 1 and stream_refreshes == 1, "set_view_mode switches to split and redraws")
        assert(has_notification("split view", vim.log.levels.INFO), "set_view_mode notifies split view")

        clear_notifications()
        session.set_view_mode("unified")
        assert(view_mode.get() == "unified" and diff_redraws == 2 and stream_refreshes == 2, "set_view_mode switches to unified and redraws")
        assert(has_notification("unified view", vim.log.levels.INFO), "set_view_mode notifies unified view")

        clear_notifications()
        session.set_view_mode("invalid")
        assert(view_mode.get() == "unified" and diff_redraws == 2, "invalid mode keeps previous view_mode")
        assert(has_notification("invalid diff view", vim.log.levels.ERROR), "invalid mode emits error")
    end)

    session.by_tab[tab] = original_by_tab
    package.loaded["jpr.views.diff"], package.loaded["jpr.views.stream"] = original_diff, original_stream
    if not is_ok then
        error(err, 0)
    end
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

local function test_list_open_prs_error_paths()
    local missing_err = collect_list_open_prs_error(vim.fn.tempname() .. "/missing-jpr-review")
    assert(missing_err:find(":Lazy build jpr-nvim", 1, true) ~= nil, "missing binary hints :Lazy build jpr-nvim: " .. missing_err)

    local failing_bin = write_executable_script({
        "#!/bin/sh",
        "echo 'gh auth required' >&2",
        "exit 1",
    })
    local exit_err = collect_list_open_prs_error(failing_bin)
    assert(exit_err:find("gh auth required", 1, true) ~= nil, "non-zero exit surfaces stderr: " .. exit_err)

    local malformed_bin = write_executable_script({
        "#!/bin/sh",
        "printf '{not-json\\n'",
        "exit 0",
    })
    local parse_err = collect_list_open_prs_error(malformed_bin)
    assert(parse_err:find("failed to parse open pull requests", 1, true) ~= nil, "malformed JSON reports parse error: " .. parse_err)
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

    with_stubbed_session_methods({
        comment_current = function(opts)
            recorded_opts = opts
        end,
    }, function()
        jpr.command({})
        helpers.press_key("jjjj<CR>")
        assert(wizard.is_open() == true, "comment opens stepper from palette on diff line")
        assert(current_text():find("▸ Line / Selection Comment  [line]", 1, true) ~= nil, "comment defaults to line on diff line: " .. current_text())
        helpers.press_key("<CR>")
        assert(wizard.is_open() == false, "confirming line comment closes stepper")
        assert(recorded_opts == nil or (not recorded_opts.file and not recorded_opts.suggest), "line comment dispatched without file/suggest flag")
    end)

    session.by_tab[tab] = original_by_tab
    vim.api.nvim_win_set_buf(0, previous_buf)
    vim.api.nvim_buf_delete(buf, { force = true })
end

test_command_schema_completeness()
test_bare_jpr_opens_palette_with_hover_helper_text()
test_open_picker_lists_prs_hovers_metadata_and_opens_selected()
test_open_picker_step_back_to_manual_pr_input()
test_open_picker_empty_prs_notifies_user()
test_multi_step_palette_commands_smart_defaults()
test_direct_subcommand_args_and_validation()
test_open_tab_badge_and_open_agent_skips_provider_step()
test_agent_toggle_forwards_explicit_agent_kind()
test_real_session_set_view_mode_updates_mode_and_redraws()
test_list_open_prs_error_paths()
test_comment_smart_default_preselects_line_on_diff_line()

print("palette_and_open_picker_spec: ok")
