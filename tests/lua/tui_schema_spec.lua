local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

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

-- 3. get_active_steps_from_command evaluates discriminant predicates with answers and context.
local branch_command = {
    id = "branch_demo",
    label = "Branch Demo",
    help = "Exercises discriminant resolution.",
    steps = {
        { id = "mode", label = "Mode", help = "Pick mode.", kind = "text" },
        {
            id = "custom_kind",
            label = "Custom Kind",
            help = "Pick custom kind.",
            kind = "text",
            when = function(answers)
                return answers.mode == "custom"
            end,
        },
        {
            id = "custom_detail",
            label = "Custom Detail",
            help = "Provide custom detail.",
            kind = "text",
            when = function(answers)
                return answers.custom_kind == "advanced"
            end,
        },
        {
            id = "session_note",
            label = "Session Note",
            help = "Note for active session.",
            kind = "text",
            when = function(_answers, context)
                return context.has_session == true
            end,
        },
    },
}

local function extract_step_ids(steps)
    local step_ids = {}
    for _, step in ipairs(steps) do
        step_ids[#step_ids + 1] = step.id
    end
    return step_ids
end

assert(
    vim.deep_equal(extract_step_ids(schema.get_active_steps_from_command(branch_command, {}, {})), { "mode" }),
    "only unconditional step active initially"
)
assert(
    vim.deep_equal(
        extract_step_ids(
            schema.get_active_steps_from_command(branch_command, { mode = "custom" }, { has_session = true })
        ),
        { "mode", "custom_kind", "session_note" }
    ),
    "discriminant and context predicates include matching steps"
)
assert(
    vim.deep_equal(
        extract_step_ids(
            schema.get_active_steps_from_command(
                branch_command,
                { mode = "custom", custom_kind = "advanced" },
                { has_session = false }
            )
        ),
        { "mode", "custom_kind", "custom_detail" }
    ),
    "chained discriminants resolve in order"
)

-- 5. get_default_value_from_step handles static values (including false) and functions.
assert(schema.get_default_value_from_step({ default = "list" }, {}, {}) == "list", "static string default")
assert(schema.get_default_value_from_step({ default = false }, {}, {}) == false, "static boolean false default")
assert(schema.get_default_value_from_step({}, {}, {}) == nil, "missing default returns nil")
assert(
    schema.get_default_value_from_step({
        default = function(answers, context)
            return (answers.mode or "none") .. ":" .. (context.default_agent or "claude")
        end,
    }, { mode = "auto" }, { default_agent = "codex" }) == "auto:codex",
    "function default receives answers and context"
)

-- 6. prune_inactive_answers prunes transitive when chains without mutating input.
local original_answers = {
    mode = "auto",
    custom_kind = "advanced",
    custom_detail = "secret-value",
    unrelated_stale = "drop-me",
}
local snapshot_before = vim.deepcopy(original_answers)
local pruned = schema.prune_inactive_answers(branch_command, original_answers, { has_session = false })
assert(vim.deep_equal(pruned, { mode = "auto" }), "transitive inactive answers pruned: " .. vim.inspect(pruned))
assert(vim.deep_equal(original_answers, snapshot_before), "input answers table is never mutated")

local boolean_pruned = schema.prune_inactive_answers(
    valid_commands[1],
    { source = "list", open_drafts = false, manual_pr = "#99" },
    {}
)
assert(
    vim.deep_equal(boolean_pruned, { source = "list", open_drafts = false }),
    "active false boolean answer preserved while inactive manual_pr pruned: " .. vim.inspect(boolean_pruned)
)

-- 7. create_toggle_options_from_step builds the shared 2-option representation.
local toggle_options = schema.create_toggle_options_from_step({
    no_label = "No (default)",
    no_help = "Keep drafts hidden.",
    yes_label = "Yes",
    yes_help = "Include draft pull requests.",
})
assert(
    vim.deep_equal(toggle_options, {
        { value = false, label = "No (default)", help = "Keep drafts hidden." },
        { value = true, label = "Yes", help = "Include draft pull requests." },
    }),
    "toggle options match expected structure: " .. vim.inspect(toggle_options)
)

print("tui_schema_spec: ok")
