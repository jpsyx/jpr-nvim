local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")

local helpers = dofile(root .. "/tests/lua/support/helpers.lua")
local jpr = require("jpr")
local agent = require("jpr.agent")
local session = require("jpr.session")
local view_mode = require("jpr.view_mode")
local wizard = require("jpr.tui.wizard")
local tui_schema = require("jpr.tui.schema")
local commands_schema = require("jpr.commands.schema")

local notifications = {}
local temp_files = {}

vim.notify = function(message, level)
    notifications[#notifications + 1] = { text = message, level = level }
end

local function clear_notifications()
    for index = #notifications, 1, -1 do
        notifications[index] = nil
    end
end

local function has_notification(substring, expected_level)
    for _, entry in ipairs(notifications) do
        local is_expected_level = expected_level == nil or entry.level == expected_level
        if is_expected_level and entry.text:find(substring, 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function track_temp_file(path)
    temp_files[#temp_files + 1] = path
    return path
end

local function cleanup_temp_files()
    for _, path in ipairs(temp_files) do
        pcall(vim.fn.delete, path)
    end
    temp_files = {}
end

local function write_executable_script(script_lines)
    local script_path = track_temp_file(vim.fn.tempname() .. "-jpr-review")
    vim.fn.writefile(script_lines, script_path)
    vim.uv.fs_chmod(script_path, tonumber("755", 8))
    return script_path
end

local function write_fake_prs_binary(payload_json)
    return write_executable_script({
        "#!/bin/sh",
        'if [ "$1" = "prs" ]; then',
        "  printf '%s\\n' " .. vim.fn.shellescape(payload_json),
        "  exit 0",
        "fi",
        "exit 1",
    })
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

local function with_temp_view_mode(initial_mode, callback)
    local original_path = view_mode.path
    local temp_path = track_temp_file(vim.fn.tempname())
    view_mode.path = temp_path
    view_mode.reset()
    if initial_mode then
        view_mode.set(initial_mode)
    end
    local is_ok, call_error = pcall(callback)
    view_mode.path = original_path
    view_mode.reset()
    if not is_ok then
        error(call_error, 0)
    end
end

local function with_stubbed_session_methods(stubs, callback)
    local originals = {}
    for key, replacement in pairs(stubs) do
        originals[key] = session[key]
        session[key] = replacement
    end
    local is_ok, call_error = pcall(callback)
    wizard.close()
    for key in pairs(stubs) do
        session[key] = originals[key]
    end
    jpr.setup({})
    if not is_ok then
        error(call_error, 0)
    end
end

local context = {
    helpers = helpers,
    jpr = jpr,
    agent = agent,
    session = session,
    view_mode = view_mode,
    wizard = wizard,
    tui_schema = tui_schema,
    commands_schema = commands_schema,
    notifications = notifications,
    clear_notifications = clear_notifications,
    has_notification = has_notification,
    write_executable_script = write_executable_script,
    write_fake_prs_binary = write_fake_prs_binary,
    create_two_pr_payload = create_two_pr_payload,
    with_temp_view_mode = with_temp_view_mode,
    with_stubbed_session_methods = with_stubbed_session_methods,
}

local is_suite_ok, suite_error = pcall(function()
    dofile(root .. "/tests/lua/palette_and_open_picker_spec/palette.lua")(context)
    dofile(root .. "/tests/lua/palette_and_open_picker_spec/open_picker.lua")(context)
    dofile(root .. "/tests/lua/palette_and_open_picker_spec/session_integration.lua")(context)
end)
cleanup_temp_files()
if not is_suite_ok then
    error(suite_error, 0)
end

print("palette_and_open_picker_spec: ok")
