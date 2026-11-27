return function(valid_commands)
    local schema = require("jpr.tui.schema")

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

-- 8. is_command_executable and get_active_commands enforce requires_session, requires_git_repo, and command.when.
local gated_commands = {
    { id = "open", label = "Open", help = "Open PR.", requires_session = false },
    { id = "local", label = "Local", help = "Local review.", requires_session = false, requires_git_repo = true },
    { id = "sync", label = "Sync", help = "Sync PR.", requires_session = true },
    {
        id = "stream",
        label = "Full Branch Diff",
        help = "Return to full diff.",
        requires_session = true,
        when = function(context)
            return not (context and context.is_stream_visible == true)
        end,
    },
    {
        id = "submit",
        label = "Submit",
        help = "Submit PR review.",
        requires_session = true,
        when = function(context)
            return context.is_linked_pr == true and not context.is_read_only
        end,
    },
}

local function extract_command_ids(commands)
    local ids = {}
    for _, command in ipairs(commands) do
        ids[#ids + 1] = command.id
    end
    return ids
end

assert(schema.is_command_executable(gated_commands[1], {}) == true, "unconditional command is executable")
assert(schema.is_command_executable(gated_commands[2], { is_git_repo = false }) == false, "requires_git_repo fails when is_git_repo == false")
assert(schema.is_command_executable(gated_commands[2], {}) == true, "requires_git_repo defaults to true when is_git_repo is omitted")
assert(schema.is_command_executable(gated_commands[3], { has_session = false }) == false, "requires_session fails without session")
assert(schema.is_command_executable(gated_commands[4], { has_session = true, is_stream_visible = true }) == false, "command.when hides stream when already visible")
assert(schema.is_command_executable(gated_commands[4], { has_session = true, is_stream_visible = false }) == true, "command.when shows stream when not visible")
assert(schema.is_command_executable(gated_commands[5], { has_session = true, is_linked_pr = false }) == false, "command.when filters unlinked session")
assert(schema.is_command_executable(gated_commands[5], { has_session = true, is_linked_pr = true, is_read_only = true }) == false, "command.when filters read-only session")
assert(schema.is_command_executable(gated_commands[5], { has_session = true, is_linked_pr = true }) == true, "command.when allows matching context")

assert(
    vim.deep_equal(extract_command_ids(schema.get_active_commands(gated_commands, { has_session = false, is_git_repo = false })), { "open" }),
    "filters session and git repo commands outside git without session"
)
assert(
    vim.deep_equal(extract_command_ids(schema.get_active_commands(gated_commands, { has_session = false, is_git_repo = true })), { "open", "local" }),
    "keeps open and local in git repo without session"
)
assert(
    vim.deep_equal(
        extract_command_ids(schema.get_active_commands(gated_commands, { has_session = true, is_git_repo = true, is_linked_pr = false, is_stream_visible = true })),
        { "open", "local", "sync" }
    ),
    "hides PR-only submit in unlinked local session and hides stream when visible"
)
assert(
    vim.deep_equal(
        extract_command_ids(schema.get_active_commands(gated_commands, { has_session = true, is_git_repo = true, is_linked_pr = true, is_stream_visible = false })),
        { "open", "local", "sync", "stream", "submit" }
    ),
    "includes all executable commands in linked PR session when stream is not visible"
)

-- 9. get_active_options_from_step filters select options by option.when without mutating step.options.
local gated_step = {
    id = "kind",
    label = "Comment Scope",
    help = "Choose comment scope.",
    kind = "select",
    options = {
        { value = "line", label = "Line", when = function(_answers, command_context) return command_context.is_on_diff_line == true end },
        { value = "file", label = "File", when = function(_answers, command_context) return command_context.can_comment_file == true end },
        { value = "always", label = "Always" },
    },
}
local file_only_options = schema.get_active_options_from_step(gated_step, {}, { is_on_diff_line = false, can_comment_file = true })
assert(#file_only_options == 2 and file_only_options[1].value == "file" and file_only_options[2].value == "always", "filters select options by when")
assert(#gated_step.options == 3, "step.options is not mutated")

end
