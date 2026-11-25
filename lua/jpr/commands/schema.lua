-- Declarative schema for all 16 `:Jpr` subcommands, driving the floating
-- command palette, interactive steppers, and subcommand argument completion.
-- Command aliases live in `COMMAND_ALIASES` and are not palette entries.
local M = {}

--- Alternate `:Jpr` names that dispatch as an existing command.
--- Add a row to accept another typed name without a palette entry or a
--- completion candidate. Keys are the alias; values are canonical command ids.
local COMMAND_ALIASES = {
    review = "open",
    self = "local",
}

local function jpr()
    return require("jpr")
end

local function session_module()
    return require("jpr.session")
end

--- Extracts the `YYYY-MM-DD` date prefix from an ISO-8601 `iso_timestamp`,
--- returning `"unknown"` when the timestamp is missing or unparseable.
--- @param iso_timestamp string|nil
--- @return string
function M.format_pr_updated_date(iso_timestamp)
    if type(iso_timestamp) ~= "string" then
        return "unknown"
    end
    return iso_timestamp:match("^(%d%d%d%d%-%d%d%-%d%d)") or "unknown"
end

local function build_pr_badge(pr, open_tabs)
    local tags = {}
    if pr.isDraft == true then
        tags[#tags + 1] = "[draft]"
    end
    if open_tabs[pr.number] then
        tags[#tags + 1] = "[open]"
    end
    if #tags == 0 then
        return nil
    end
    return table.concat(tags, " ")
end

local function build_pr_help(pr)
    local author = (type(pr.author) == "string" and pr.author ~= "") and pr.author or "ghost"
    local parts = { "@" .. author }
    if type(pr.headRef) == "string" and pr.headRef ~= "" then
        parts[#parts + 1] = pr.headRef
    end
    parts[#parts + 1] = "updated " .. M.format_pr_updated_date(pr.updatedAt)
    return table.concat(parts, " · ")
end

local function create_pr_options_from_list(prs, open_tabs, repo)
    local options = {}
    for _, pr in ipairs(prs) do
        if type(pr) == "table" and type(pr.number) == "number" then
            local title = type(pr.title) == "string" and pr.title or ""
            options[#options + 1] = {
                value = { number = pr.number, repo = repo },
                label = ("#%d  %s"):format(pr.number, title),
                badge = build_pr_badge(pr, open_tabs),
                help = build_pr_help(pr),
            }
        end
    end
    return options
end

local open_pr_load_generation = 0

local function load_open_pr_options(_answers, context, on_loaded)
    open_pr_load_generation = open_pr_load_generation + 1
    local generation = open_pr_load_generation
    local session = session_module()
    local target_repo = type(context) == "table" and type(context.repo) == "string" and context.repo ~= ""
            and context.repo
        or nil
    session.list_open_prs(function(prs)
        if #prs == 0 then
            local is_applied = on_loaded(
                {},
                nil,
                "No open pull requests in this repository. Press h to enter a PR number or URL."
            )
            if is_applied == true then
                jpr().info("no open pull requests in this repository")
            end
            return
        end
        local open_tabs = type(session.open_tab_numbers) == "function" and session.open_tab_numbers(target_repo) or {}
        on_loaded(create_pr_options_from_list(prs, open_tabs, target_repo))
    end, function(error_message)
        on_loaded(nil, error_message)
    end, {
        repo = target_repo,
        is_active = function()
            return require("jpr.tui.wizard").is_open() and open_pr_load_generation == generation
        end,
        on_reopen = function()
            local open_spec = M.find_command_spec("open")
            require("jpr.tui.wizard").open_command(open_spec, { source = "list" }, context, { start_step_id = "pr" })
        end,
    })
end

local function execute_open_command(answers, context)
    local fallback_repo = type(context) == "table" and type(context.repo) == "string" and context.repo ~= ""
            and context.repo
        or nil
    if answers.source == "list" and answers.pr ~= nil then
        local number = type(answers.pr) == "table" and answers.pr.number or answers.pr
        local repo = (type(answers.pr) == "table" and answers.pr.repo) or fallback_repo
        return session_module().open(number, repo)
    end
    local number, repo = jpr().parse_pr_arg(vim.trim(tostring(answers.pr_input or "")))
    if number then
        return session_module().open(number, repo or fallback_repo)
    end
end

local function create_open_command_spec()
    return {
        id = "open",
        label = "Open Pull Request",
        help = "Pick an open pull request or enter a PR number or URL to start reviewing.",
        requires_session = false,
        steps = {
            {
                id = "source",
                label = "Pull Request Source",
                help = "Choose whether to pick an open pull request from GitHub or enter one manually.",
                kind = "select",
                default = "list",
                options = {
                    { value = "list", label = "Pick from Open PRs", badge = "[list]", help = "Load open pull requests from this repository and choose one from a list." },
                    { value = "manual", label = "Enter PR Number or URL", badge = "[manual]", help = "Type a pull request number, #number, or full GitHub pull request URL." },
                },
            },
            {
                id = "pr",
                label = "Select Open Pull Request",
                help = "Choose an open pull request from this repository to open in a review tab.",
                kind = "async_select",
                when = function(answers) return answers.source == "list" end,
                load = load_open_pr_options,
            },
            {
                id = "pr_input",
                label = "Pull Request Number or URL",
                help = "Enter a pull request number, #number, or GitHub pull request URL.",
                kind = "text",
                default = "",
                when = function(answers) return answers.source == "manual" end,
                validate = function(value)
                    if not jpr().parse_pr_arg(vim.trim(tostring(value or ""))) then
                        return false, "Enter a PR number, #number, or GitHub PR URL."
                    end
                    return true
                end,
            },
        },
        execute = execute_open_command,
    }
end

local function create_toggle_command_spec()
    return {
        id = "toggle",
        label = "Switch Diff View",
        help = "Choose between unified inline diffs and side-by-side split diffs for review buffers.",
        requires_session = true,
        steps = {
            {
                id = "mode",
                label = "Diff View Layout",
                help = "Pick the diff layout to use for review buffers.",
                kind = "select",
                default = function()
                    return require("jpr.view_mode").get() == "split" and "unified" or "split"
                end,
                options = {
                    { value = "unified", label = "Unified Diff", badge = "[unified]", help = "Display additions and removals inline within a single diff pane." },
                    { value = "split", label = "Side-by-Side Split", badge = "[split]", help = "Display the base and head versions side by side in two panes." },
                },
            },
        },
        execute = function(answers)
            session_module().set_view_mode(answers.mode)
        end,
    }
end

local function build_comment_opts_with_extra(cmd_opts, extra)
    local merged = {}
    if type(cmd_opts) == "table" then
        merged.line1 = cmd_opts.line1
        merged.line2 = cmd_opts.line2
        merged.range = cmd_opts.range
    end
    for key, value in pairs(extra or {}) do
        merged[key] = value
    end
    return merged
end

local function execute_comment_command(answers, context)
    local cmd_opts = context and context.cmd_opts or nil
    if answers.kind == "file" then
        return session_module().comment_current({ file = true })
    end
    if answers.kind == "suggest" then
        return session_module().comment_current(build_comment_opts_with_extra(cmd_opts, { suggest = true }))
    end
    return session_module().comment_current(cmd_opts)
end

local function is_live_session(context)
    return type(context) == "table" and context.has_session == true and context.is_read_only ~= true
end

local function is_live_linked_pr_session(context)
    return is_live_session(context) and context.is_linked_pr == true
end

local function is_comment_executable(context)
    return is_live_session(context)
        and (context.is_on_diff_line == true or context.can_comment_file == true)
end

local function is_suggest_executable(context)
    return is_live_linked_pr_session(context) and context.is_in_changed_worktree_file == true
end

local function is_conversation_executable(context)
    return type(context) == "table"
        and context.has_session == true
        and (context.is_read_only ~= true or context.has_cached_conversation == true)
end

local function is_agent_executable(context)
    return type(context) == "table"
        and context.has_session == true
        and (context.is_read_only ~= true or context.has_live_agent == true)
end

local function is_send_executable(context)
    return is_live_session(context) and (tonumber(context.local_unsent_count) or 0) > 0
end

local function is_close_executable(context)
    return type(context) == "table" and (context.has_session == true or context.has_pending_tab == true)
end

local function create_comment_command_spec()
    return {
        id = "comment",
        label = "Add Review Comment",
        help = "Draft a new review comment on the current line, visual selection, or entire file.",
        requires_session = true,
        when = is_comment_executable,
        steps = {
            {
                id = "kind",
                label = "Comment Scope",
                help = "Choose whether to comment on the current line, the whole file, or suggest code.",
                kind = "select",
                default = function(_answers, context)
                    return (context and context.is_on_diff_line) and "line" or "file"
                end,
                options = {
                    {
                        value = "line",
                        label = "Line / Selection Comment",
                        badge = "[line]",
                        help = "Attach a review comment to the current diff line or visual selection.",
                        when = function(_answers, context)
                            return type(context) == "table" and context.is_on_diff_line == true
                        end,
                    },
                    {
                        value = "file",
                        label = "File-Level Comment",
                        badge = "[file]",
                        help = "Attach a review comment to the current file without anchoring to a line.",
                        when = function(_answers, context)
                            return type(context) == "table" and context.can_comment_file == true
                        end,
                    },
                    {
                        value = "suggest",
                        label = "Code Suggestion",
                        badge = "[suggest]",
                        help = "Draft a review comment pre-filled with a GitHub code suggestion block.",
                        when = function(_answers, context)
                            return type(context) == "table" and context.is_on_diff_line == true
                        end,
                    },
                },
            },
        },
        execute = execute_comment_command,
    }
end

local function create_agent_command_spec()
    return {
        id = "agent",
        label = "Coding Agent Panel",
        help = "Open, configure, or hide the interactive coding-agent terminal split for this review.",
        requires_session = true,
        when = is_agent_executable,
        steps = {
            {
                id = "provider",
                label = "Coding Agent Provider",
                help = "Choose which coding agent CLI to launch in the review terminal split.",
                kind = "select",
                when = function(_answers, context)
                    return not (context and (context.is_agent_open or context.has_live_agent))
                end,
                default = function()
                    return jpr().config.agent or "claude"
                end,
                options = {
                    { value = "claude", label = "Claude Code", badge = "[claude]", help = "Launch Claude Code in the review worktree terminal split." },
                    { value = "codex", label = "Codex", badge = "[codex]", help = "Launch Codex in the review worktree terminal split." },
                },
            },
        },
        execute = function(answers)
            session_module().agent_current(answers.provider)
        end,
    }
end

local function create_session_action_spec(id, label, help, session_method, when_predicate)
    return {
        id = id,
        label = label,
        help = help,
        requires_session = true,
        when = when_predicate,
        execute = function()
            session_module()[session_method]()
        end,
    }
end

local function create_close_command_spec()
    return {
        id = "close",
        label = "Close Review Session",
        help = "Close the current tab's pull request review session and stop its background engine.",
        requires_session = false,
        when = is_close_executable,
        execute = function()
            session_module().close_current()
        end,
    }
end

local function create_keys_command_spec()
    return {
        id = "keys",
        label = "Keyboard Shortcuts",
        help = "Show all keyboard shortcuts for navigating reviews, comments, panels, and menus.",
        requires_session = false,
        execute = function()
            require("jpr.views.cheatsheet").open()
        end,
    }
end

local function validate_local_base_ref(value)
    local trimmed = vim.trim(tostring(value or ""))
    if trimmed == "" then
        return false, "Enter a git ref such as develop, main, or HEAD."
    end
    if trimmed:sub(1, 1) == "-" or trimmed:find("%s") ~= nil or trimmed:find("%c") ~= nil then
        return false, "Base git ref cannot start with '-' or contain whitespace."
    end
    return true
end

local function create_local_command_spec()
    return {
        id = "local",
        label = "Review Current Worktree",
        help = "Review the current worktree against its base branch (auto-attaches if an open PR exists).",
        requires_session = false,
        requires_git_repo = true,
        steps = {
            {
                id = "base_mode",
                label = "Base Branch",
                help = "Auto-detect the base branch (and attach to an open PR if one exists) or pick a custom ref.",
                kind = "select",
                default = "auto",
                options = {
                    { value = "auto", label = "Auto-detect base branch", badge = "[auto]", help = "Use develop if present else main, and auto-attach if an open PR exists." },
                    { value = "custom", label = "Custom git ref (local only)", badge = "[custom]", help = "Diff against a specific git ref such as HEAD; stays local-only." },
                },
            },
            {
                id = "base",
                label = "Base Git Ref",
                help = "Enter the git ref to diff the current worktree against (for example develop, main, or HEAD).",
                kind = "text",
                default = "HEAD",
                when = function(answers) return answers.base_mode == "custom" end,
                validate = validate_local_base_ref,
            },
        },
        execute = function(answers, context)
            if type(context) == "table" and context.is_git_repo == false then
                return jpr().error("Review Current Worktree requires a local git checkout")
            end
            local base_ref = answers.base_mode == "custom" and vim.trim(tostring(answers.base or "")) or nil
            return session_module().open_local(base_ref)
        end,
    }
end

--- Builds the ordered list of declarative specs for all 16 `:Jpr` subcommands.
--- @return table[]
function M.create_command_specs()
    return {
        create_open_command_spec(),
        create_local_command_spec(),
        create_session_action_spec("sync", "Sync with GitHub", "Sync with GitHub (or detect and link an open PR when reviewing locally).", "sync_current", is_live_session),
        create_toggle_command_spec(),
        create_session_action_spec("stream", "Open Stream View", "View all changed files stacked continuously in a single scrollable diff stream.", "stream_current", is_live_session),
        create_comment_command_spec(),
        create_session_action_spec("suggest", "Suggest Code Change", "Draft a review comment pre-filled with a GitHub suggestion block for the current line.", "suggest_current", is_suggest_executable),
        create_session_action_spec("expand", "Expand Inline Threads", "Toggle inline expansion of review threads across diff and stream buffers.", "expand_current"),
        create_session_action_spec("conversation", "Open PR Conversation", "Read and post top-level pull request issue comments in the main review window.", "conversation_current", is_conversation_executable),
        create_session_action_spec("submit", "Submit Review", "Preview pending draft comments and submit your review decision to GitHub.", "submit_current", is_live_linked_pr_session),
        create_session_action_spec("push", "Push Head Branch", "Push local commits on the checked-out pull request branch back to GitHub.", "push_current", is_live_linked_pr_session),
        create_agent_command_spec(),
        create_session_action_spec("send", "Send Local Threads to Agent", "Prompt the coding agent to address pending local review threads in this worktree.", "send_current", is_send_executable),
        create_session_action_spec("prepass", "Run Agent Pre-Pass", "Ask the coding agent to scan the pull request diff and post local pre-pass findings.", "prepass_current", is_live_session),
        create_close_command_spec(),
        create_keys_command_spec(),
    }
end

--- Finds the declarative command spec matching `id`, or `nil` if unknown.
--- @param id string
--- @return table|nil
function M.find_command_spec(id)
    for _, command in ipairs(M.create_command_specs()) do
        if command.id == id then
            return command
        end
    end
    return nil
end

--- Returns configured aliases sorted by alias name.
--- Each entry is `{ alias = string, command_id = string }`.
--- @return table[]
function M.list_command_aliases()
    local aliases = {}
    for alias, command_id in pairs(COMMAND_ALIASES) do
        aliases[#aliases + 1] = { alias = alias, command_id = command_id }
    end
    table.sort(aliases, function(left, right)
        return left.alias < right.alias
    end)
    return aliases
end

--- Maps `name` to its canonical command id.
--- A known command id maps to itself. An alias maps to its target.
--- An unknown name returns nil.
--- @param name string|nil
--- @return string|nil
function M.resolve_command_id(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local alias_target = COMMAND_ALIASES[name]
    if type(alias_target) == "string" then
        return alias_target
    end
    if M.find_command_spec(name) ~= nil then
        return name
    end
    return nil
end

--- Checks that every alias names a real command and does not reuse a command id.
--- @return boolean, string|nil
function M.validate_command_aliases()
    local command_ids = {}
    for _, command_id in ipairs(M.list_command_ids()) do
        command_ids[command_id] = true
    end
    for _, entry in ipairs(M.list_command_aliases()) do
        if command_ids[entry.alias] then
            return false, ("alias %q collides with a command id"):format(entry.alias)
        end
        if not command_ids[entry.command_id] then
            return false, ("alias %q targets unknown command %q"):format(entry.alias, tostring(entry.command_id))
        end
    end
    return true
end

--- Returns the ordered list of all 16 `:Jpr` subcommand IDs.
--- @return string[]
function M.list_command_ids()
    local ids = {}
    for _, command in ipairs(M.create_command_specs()) do
        ids[#ids + 1] = command.id
    end
    return ids
end

--- Returns valid direct argument completions for `subcommand`, derived from its
--- single-step select options in the schema (or `{}` when none apply).
--- @param subcommand string|nil
--- @return string[]
function M.subcommand_arg_completions(subcommand)
    local resolved_id = M.resolve_command_id(subcommand) or subcommand
    local command = M.find_command_spec(resolved_id)
    if not command or type(command.steps) ~= "table" or #command.steps ~= 1 then
        return {}
    end
    local step = command.steps[1]
    if step.kind ~= "select" or type(step.options) ~= "table" then
        return {}
    end
    local values = {}
    for _, option in ipairs(step.options) do
        if type(option.value) == "string" then
            values[#values + 1] = option.value
        end
    end
    return values
end

return M
