-- Open pull request command specification and async open-PR option formatting.
local M = {}

local open_pr_load_generation = 0

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
            local open_spec = require("jpr.commands.schema").find_command_spec("open")
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

--- Creates the declarative command spec for `:Jpr open`.
--- @return table
function M.create_open_command_spec()
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

return M
