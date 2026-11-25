-- Non-git-repo detection and pre-palette GitHub owner/repository picker.
local auth = require("jpr.auth")
local crash = require("jpr.session.crash")
local wizard = require("jpr.tui.wizard")

local M = {}

local function jpr()
    return require("jpr")
end

local function format_updated_date(iso_timestamp)
    if type(iso_timestamp) ~= "string" then
        return "unknown"
    end
    return iso_timestamp:match("^(%d%d%d%d%-%d%d%-%d%d)") or "unknown"
end

--- Synchronously checks whether `cwd` is inside a git repository or linked
--- worktree by walking upward for a `.git` directory or file.
function M.is_git_repo(cwd)
    local target = (type(cwd) == "string" and cwd ~= "") and cwd or vim.fn.getcwd()
    local found = vim.fs.find(".git", { path = target, upward = true, limit = 1 })
    return #found > 0
end

--- Detects whether `cwd` is inside a git repository and invokes `callback(is_git_repo)`.
function M.detect_git_repo(cwd, callback)
    callback(M.is_git_repo(cwd))
end

local function run_discovery_cli(subcommand_args, error_label, on_result, on_error, on_reopen)
    local binary_path = jpr().binary_path()
    if vim.fn.executable(binary_path) ~= 1 then
        return on_error("jpr-review binary is missing; run :Lazy build jpr-nvim")
    end
    local args = { binary_path }
    vim.list_extend(args, subcommand_args)
    local is_started, start_error = pcall(
        vim.system,
        args,
        { cwd = vim.fn.getcwd(), text = true },
        vim.schedule_wrap(function(result)
            if result.code ~= 0 then
                if auth.is_cli_auth_error(result) then
                    return auth.prompt_and_resume({
                        is_background = false,
                        on_authenticated = function()
                            if type(on_reopen) == "function" then
                                on_reopen()
                            else
                                run_discovery_cli(subcommand_args, error_label, on_result, on_error, on_reopen)
                            end
                        end,
                        on_cancel = function()
                            on_error("GitHub authentication is required to " .. error_label)
                        end,
                    })
                end
                local stderr = crash.build_clean_text_from_raw(result.stderr)
                return on_error(stderr ~= "" and stderr or ("failed to " .. error_label))
            end
            local is_decoded, decoded = pcall(vim.json.decode, result.stdout or "")
            if not is_decoded or not vim.islist(decoded) then
                return on_error("failed to parse " .. error_label .. " response")
            end
            on_result(decoded)
        end)
    )
    if not is_started then
        on_error(crash.build_clean_text_from_raw(start_error))
    end
end

--- Lists the authenticated user profile and organizations via `jpr-review owners`.
function M.list_owners(on_result, on_error, on_reopen)
    return run_discovery_cli({ "owners" }, "list GitHub accounts", on_result, on_error, on_reopen)
end

--- Lists repositories for `owner` via `jpr-review repos --owner <owner>`.
function M.list_repos(owner, on_result, on_error, on_reopen)
    local subargs = { "repos" }
    if type(owner) == "string" and owner ~= "" then
        vim.list_extend(subargs, { "--owner", owner })
    end
    return run_discovery_cli(subargs, "list GitHub repositories", on_result, on_error, on_reopen)
end

local function create_owner_options(owners)
    local options = {}
    for _, owner in ipairs(owners) do
        if type(owner) == "table" and type(owner.login) == "string" and owner.login ~= "" then
            local is_user = owner.kind == "user"
            local display_name = type(owner.name) == "string" and vim.trim(owner.name) ~= "" and owner.name or nil
            local default_help = is_user and "Your personal GitHub repositories"
                or ("Repositories in the " .. owner.login .. " organization")
            options[#options + 1] = {
                value = owner.login,
                label = owner.login,
                badge = is_user and "[you]" or "[org]",
                help = display_name and (display_name .. " · " .. default_help) or default_help,
            }
        end
    end
    return options
end

local function build_repo_badge(repo)
    local tags = {}
    if repo.isPrivate == true then
        tags[#tags + 1] = "[private]"
    end
    if repo.isArchived == true then
        tags[#tags + 1] = "[archived]"
    end
    return #tags > 0 and table.concat(tags, " ") or nil
end

local function build_repo_help(repo)
    local description = type(repo.description) == "string" and vim.trim(repo.description) ~= "" and repo.description or nil
    local updated = "updated " .. format_updated_date(repo.updatedAt)
    return description and (description .. " · " .. updated) or updated
end

local function create_repo_options(repos)
    local options = {}
    for _, repo in ipairs(repos) do
        if type(repo) == "table" and type(repo.nameWithOwner) == "string" and repo.nameWithOwner ~= "" then
            options[#options + 1] = {
                value = repo.nameWithOwner,
                label = repo.nameWithOwner,
                badge = build_repo_badge(repo),
                help = build_repo_help(repo),
            }
        end
    end
    return options
end

local function create_repo_step(owner_count, on_reopen_for_owner)
    return {
        id = "repo",
        label = "Select Repository",
        help = "Choose the GitHub repository you want to inspect.",
        kind = "async_select",
        load = function(answers, _context, on_loaded)
            local selected_owner = answers.owner
            M.list_repos(selected_owner, function(repos)
                if #repos == 0 then
                    local back_hint = owner_count > 1 and " Press h to choose another account." or ""
                    local empty_message = ("No repositories found for %s.%s"):format(tostring(selected_owner), back_hint)
                    on_loaded({}, nil, empty_message)
                    return
                end
                on_loaded(create_repo_options(repos))
            end, function(error_message)
                on_loaded(nil, error_message)
            end, function()
                on_reopen_for_owner(selected_owner)
            end)
        end,
    }
end

local function open_owner_repo_wizard(owners, on_selected, preselected_owner)
    local owner_options = create_owner_options(owners)
    local reopen_at_owner = function(owner_login)
        open_owner_repo_wizard(owners, on_selected, owner_login)
    end
    local steps = {}
    local initial_answers = {}
    local start_step_id = nil
    if #owner_options > 1 then
        steps[#steps + 1] = {
            id = "owner",
            label = "Select Account or Organization",
            help = "Choose your personal profile or an organization to browse its repositories.",
            kind = "select",
            default = owner_options[1].value,
            options = owner_options,
        }
        if type(preselected_owner) == "string" and preselected_owner ~= "" then
            initial_answers.owner = preselected_owner
            start_step_id = "repo"
        end
    else
        initial_answers.owner = owner_options[1].value
    end
    steps[#steps + 1] = create_repo_step(#owner_options, reopen_at_owner)

    local command = {
        id = "pick-repo",
        label = "Select GitHub Repository",
        help = "Choose a GitHub repository to inspect before opening the command palette.",
        steps = steps,
        execute = function(answers)
            if type(answers.repo) == "string" and answers.repo ~= "" then
                on_selected(answers.repo)
            end
        end,
    }
    wizard.open_command(command, initial_answers, {}, { start_step_id = start_step_id })
end

--- Runs the GitHub owner -> repository picker wizard and invokes `on_selected("owner/name")`.
function M.pick(on_selected)
    local loader_command = {
        id = "pick-repo-loading",
        label = "Select GitHub Repository",
        help = "Loading GitHub accounts from gh...",
        steps = {
            {
                id = "owners_loader",
                label = "Loading GitHub Accounts",
                help = "Fetching your GitHub profile and organizations from gh.",
                kind = "async_select",
                load = function(_answers, _context, on_loaded)
                    M.list_owners(function(owners)
                        local owner_options = create_owner_options(owners)
                        if #owner_options == 0 then
                            on_loaded(nil, "No GitHub account found via gh.")
                            return
                        end
                        if not wizard.is_open() then
                            return
                        end
                        open_owner_repo_wizard(owners, on_selected, nil)
                    end, function(error_message)
                        on_loaded(nil, error_message)
                    end, function()
                        M.pick(on_selected)
                    end)
                end,
            },
        },
        execute = function() end,
    }
    wizard.open_command(loader_command, {}, {})
end

return M
