return function()
    local schema = require("jpr.tui.schema")

-- 1. validate_command_specs accepts a complete valid spec set across all four step kinds.
local valid_commands = {
    {
        id = "open",
        label = "Open Pull Request",
        help = "Pick an open pull request or enter a PR number or URL.",
        requires_session = false,
        steps = {
            {
                id = "source",
                label = "Pull Request Source",
                help = "Choose whether to pick from open PRs or type a number.",
                kind = "select",
                default = "list",
                options = {
                    { value = "list", label = "Pick from Open PRs", help = "Load open pull requests." },
                    { value = "manual", label = "Enter PR Number or URL", help = "Type a PR number or URL." },
                },
            },
            {
                id = "pr",
                label = "Open Pull Requests",
                help = "Select a pull request to review.",
                kind = "async_select",
                when = function(answers)
                    return answers.source == "list"
                end,
                load = function(_answers, _context, callback)
                    callback({})
                end,
            },
            {
                id = "manual_pr",
                label = "Pull Request Number or URL",
                help = "Enter a PR number, #number, or GitHub URL.",
                kind = "text",
                when = function(answers)
                    return answers.source == "manual"
                end,
                default = "",
            },
            {
                id = "open_drafts",
                label = "Include Drafts",
                help = "Choose whether to include draft pull requests.",
                kind = "toggle",
                yes_label = "Yes",
                yes_help = "Include draft pull requests.",
                no_label = "No",
                no_help = "Hide draft pull requests.",
                default = false,
            },
        },
    },
    {
        id = "sync",
        label = "Sync with GitHub",
        help = "Fetch the latest pull request commits and comments.",
        requires_session = true,
    },
}

local is_valid, validation_error = schema.validate_command_specs(valid_commands)
assert(is_valid == true and validation_error == nil, "valid specs pass: " .. tostring(validation_error))

-- 2. validate_command_specs rejects invalid specs with clear error messages.
local function assert_invalid(commands, expected_substring, description)
    local is_valid, error_message = schema.validate_command_specs(commands)
    assert(is_valid == false, description .. ": expected false, got true")
    assert(type(error_message) == "string" and error_message ~= "", description .. ": expected error message")
    assert(
        error_message:lower():find(expected_substring:lower(), 1, true) ~= nil,
        description .. ": expected '" .. expected_substring .. "' in '" .. error_message .. "'"
    )
end

assert_invalid({}, "non-empty", "empty command list")
assert_invalid("not a table", "non-empty", "non-table command list")
assert_invalid({ { id = "", label = "Open", help = "Help." } }, "id", "empty command id")
assert_invalid({ { id = "open", label = "", help = "Help." } }, "label", "missing command label")
assert_invalid({ { id = "open", label = "Open", help = "   " } }, "help", "blank command help")
assert_invalid({
    { id = "open", label = "Open", help = "First." },
    { id = "open", label = "Open Again", help = "Second." },
}, "duplicate", "duplicate command id")
assert_invalid({
    {
        id = "open",
        label = "Open",
        help = "Help.",
        steps = {
            { id = "mode", label = "Mode", help = "Pick mode.", kind = "bogus" },
        },
    },
}, "kind", "invalid step kind")
assert_invalid({
    {
        id = "open",
        label = "Open",
        help = "Help.",
        steps = {
            { id = "mode", label = "Mode 1", help = "Pick.", kind = "text" },
            { id = "mode", label = "Mode 2", help = "Pick.", kind = "text" },
        },
    },
}, "duplicate", "duplicate step id")
assert_invalid({
    {
        id = "open",
        label = "Open",
        help = "Help.",
        steps = {
            { id = "mode", label = "Mode", help = "Pick.", kind = "select", options = {} },
        },
    },
}, "options", "empty select options")
assert_invalid({
    {
        id = "open",
        label = "Open",
        help = "Help.",
        steps = {
            {
                id = "mode",
                label = "Mode",
                help = "Pick.",
                kind = "select",
                options = { { value = "", label = "Empty Value" } },
            },
        },
    },
}, "value", "empty select option value")
assert_invalid({
    {
        id = "open",
        label = "Open",
        help = "Help.",
        steps = {
            {
                id = "mode",
                label = "Mode",
                help = "Pick.",
                kind = "select",
                options = { { value = "a", label = "" } },
            },
        },
    },
}, "label", "empty select option label")
assert_invalid({
    {
        id = "open",
        label = "Open",
        help = "Help.",
        steps = {
            { id = "pr", label = "PR", help = "Pick.", kind = "async_select" },
        },
    },
}, "load", "missing async_select loader")
assert_invalid({
    {
        id = "open",
        label = "Open",
        help = "Help.",
        steps = {
            { id = "flag", label = "Flag", help = "Toggle.", kind = "toggle", yes_label = "Yes", no_label = "" },
        },
    },
}, "no_label", "missing toggle no_label")
assert_invalid({
    {
        id = "open",
        label = "Open",
        help = "Help.",
        steps = {
            { id = "flag", label = "Flag", help = "Toggle.", kind = "toggle", yes_label = "", no_label = "No" },
        },
    },
}, "yes_label", "missing toggle yes_label")
assert_invalid({
    { id = "open", label = "Open", help = "Help.", when = "not-a-function" },
}, "when", "non-function command when predicate")
assert_invalid({
    {
        id = "open",
        label = "Open",
        help = "Help.",
        steps = {
            {
                id = "mode",
                label = "Mode",
                help = "Pick.",
                kind = "select",
                options = { { value = "a", label = "Option A", when = true } },
            },
        },
    },
}, "when", "non-function select option when predicate")


    return valid_commands
end
