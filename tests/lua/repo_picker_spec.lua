local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local helpers = dofile(root .. "/tests/lua/support/helpers.lua")
local auth = require("jpr.auth")
local jpr = require("jpr")
local session = require("jpr.session")
local wizard = require("jpr.tui.wizard")

local notifications = {}
require("jpr.notify").set_listener(function(_, message, level)
    notifications[#notifications + 1] = { text = "jpr: " .. message, level = level }
end)

local function has_notification(needle, level)
    for _, entry in ipairs(notifications) do
        if (level == nil or entry.level == level) and entry.text:find(needle, 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function with_non_git_env(system_handler, callback)
    local original_getcwd = vim.fn.getcwd
    local original_executable = vim.fn.executable
    local original_system = vim.system
    local original_prompt = auth.prompt_and_resume
    local original_open = session.open
    local original_list_prs = session.list_open_prs
    local non_git_dir = vim.fn.tempname()
    vim.fn.mkdir(non_git_dir, "p")

    vim.fn.getcwd = function() return non_git_dir end
    vim.fn.executable = function() return 1 end
    vim.system = system_handler
    notifications = {}
    wizard.close()
    auth.reset()

    local is_ok, err = pcall(callback, non_git_dir)

    wizard.close()
    auth.reset()
    vim.fn.getcwd = original_getcwd
    vim.fn.executable = original_executable
    vim.system = original_system
    auth.prompt_and_resume = original_prompt
    session.open = original_open
    session.list_open_prs = original_list_prs
    pcall(vim.fn.delete, non_git_dir, "rf")
    if not is_ok then
        error(err, 0)
    end
end

-- 1. Zero orgs (only personal profile) skips owner step and opens repo-scoped palette.
with_non_git_env(function(cmd, _opts, on_exit)
    vim.schedule(function()
        if cmd[2] == "owners" then
            on_exit({
                code = 0,
                stdout = vim.json.encode({ { login = "pablo", name = "Pablo", kind = "user" } }),
                stderr = "",
            })
        elseif cmd[2] == "repos" then
            on_exit({
                code = 0,
                stdout = vim.json.encode({
                    {
                        nameWithOwner = "pablo/notes",
                        description = "Personal notes",
                        isPrivate = true,
                        isArchived = false,
                        updatedAt = "2026-11-24T10:00:00Z",
                    },
                }),
                stderr = "",
            })
        elseif cmd[2] == "prs" then
            assert(vim.tbl_contains(cmd, "--repo") and vim.tbl_contains(cmd, "pablo/notes"), "prs receives picked --repo")
            on_exit({
                code = 0,
                stdout = vim.json.encode({
                    { number = 12, title = "Fix docs", author = "pablo", headRef = "docs", isDraft = false, updatedAt = "2026-11-24T10:00:00Z" },
                }),
                stderr = "",
            })
        end
    end)
end, function()
    local opened_call = nil
    session.open = function(number, repo)
        opened_call = { number = number, repo = repo }
    end

    jpr.command({})
    assert(
        vim.wait(2000, function()
            return wizard.is_open() and helpers.current_text():find("pablo/notes", 1, true) ~= nil
        end),
        "zero-org user skips owner picker directly to repo list: " .. tostring(wizard.is_open() and helpers.current_text())
    )
    local repo_text = helpers.current_text()
    assert(repo_text:find("[private]", 1, true) ~= nil, "shows [private] badge: " .. repo_text)
    assert(repo_text:find("Personal notes", 1, true) ~= nil, "shows repo description helper text")

    helpers.press_key("<CR>")
    assert(wizard.is_open(), "picking repo opens global command palette")
    local title = helpers.win_title(helpers.current_float_win())
    assert(title:find("pablo/notes", 1, true) ~= nil, "palette title includes chosen repo: " .. title)
    local palette_text = helpers.palette_results_text()
    assert(palette_text:find("[S-Tab] repos", 1, true) ~= nil, "palette footer hints [S-Tab] repos: " .. palette_text)

    -- Selecting Open Pull Request -> Pick from Open PRs opens PR #12 with repo = "pablo/notes".
    helpers.press_key("<CR>")
    helpers.press_key("<CR>")
    assert(
        vim.wait(2000, function()
            return wizard.is_open() and helpers.current_text():find("#12  Fix docs", 1, true) ~= nil
        end),
        "open PR list loaded for picked repo"
    )
    helpers.press_key("<CR>")
    assert(opened_call ~= nil and opened_call.number == 12 and opened_call.repo == "pablo/notes", "opened PR #12 in pablo/notes")
end)

-- 2. Multi-org picker lists [you] before [org], steps back on h from empty repos and repo-scoped palette, blocks :Jpr local outside git, and resolves manual PR numbers and URL overrides.
with_non_git_env(function(cmd, _opts, on_exit)
    vim.schedule(function()
        if cmd[2] == "owners" then
            on_exit({
                code = 0,
                stdout = vim.json.encode({
                    { login = "pablo", name = "Pablo", kind = "user" },
                    { login = "empty-org", name = "Empty Org", kind = "organization" },
                    { login = "acme", name = "Acme Corp", kind = "organization" },
                }),
                stderr = "",
            })
        elseif cmd[2] == "repos" then
            local owner = cmd[4]
            if owner == "empty-org" then
                on_exit({ code = 0, stdout = "[]", stderr = "" })
            else
                on_exit({
                    code = 0,
                    stdout = vim.json.encode({
                        {
                            nameWithOwner = "acme/widgets",
                            description = "Core widgets",
                            isPrivate = false,
                            isArchived = true,
                            updatedAt = "2026-11-20T00:00:00Z",
                        },
                    }),
                    stderr = "",
                })
            end
        end
    end)
end, function()
    local opened_call = nil
    session.open = function(number, repo)
        opened_call = { number = number, repo = repo }
    end

    jpr.command({})
    assert(
        vim.wait(2000, function()
            return wizard.is_open() and helpers.current_text():find("pablo  [you]", 1, true) ~= nil
        end),
        "multi-org user sees personal profile first with [you]"
    )
    local owner_text = helpers.current_text()
    assert(owner_text:find("empty-org  [org]", 1, true) ~= nil, "shows org with [org] badge")
    assert(owner_text:find("acme  [org]", 1, true) ~= nil, "shows second org")

    -- Pick empty-org -> empty state -> press h to return to owners.
    helpers.press_key("j<CR>")
    assert(
        vim.wait(2000, function()
            return wizard.is_open() and helpers.current_text():find("No repositories found for empty-org", 1, true) ~= nil
        end),
        "empty org renders helpful empty message"
    )
    helpers.press_key("h")
    assert(helpers.current_text():find("pablo  [you]", 1, true) ~= nil, "h returns from empty repo list to owner picker")

    -- Pick acme -> pick acme/widgets -> repo-scoped palette.
    helpers.press_key("j<CR>")
    assert(
        vim.wait(2000, function()
            return wizard.is_open() and helpers.current_text():find("acme/widgets  [archived]", 1, true) ~= nil
        end),
        "acme repos loaded with [archived] badge"
    )
    helpers.press_key("<CR>")
    assert(helpers.win_title(helpers.current_float_win()):find("acme/widgets", 1, true) ~= nil, "palette scoped to acme/widgets")

    -- Outside git repo without a session, repo-scoped palette hides [local] and session commands (only open + keys appear).
    local scoped_palette_text = helpers.palette_results_text()
    assert(scoped_palette_text:find("Open Pull Request  [open]", 1, true) ~= nil, "repo-scoped palette includes open")
    assert(scoped_palette_text:find("Keyboard Shortcuts  [keys]", 1, true) ~= nil, "repo-scoped palette includes keys")
    assert(scoped_palette_text:find("Review Current Worktree", 1, true) == nil, "repo-scoped palette hides local outside git repo")
    assert(scoped_palette_text:find("Sync with GitHub", 1, true) == nil, "repo-scoped palette hides session commands")
    wizard.close()

    -- Direct command execution guard for local outside git repo still notifies clear error.
    local local_spec = require("jpr.commands.schema").find_command_spec("local")
    local_spec.execute({ base_mode = "auto" }, { is_git_repo = false })
    assert(has_notification("local git checkout", vim.log.levels.ERROR), "local command errors clearly outside git repo")

    -- Pressing h from repo-scoped palette reopens the repository picker.
    jpr.command({})
    assert(vim.wait(2000, function() return wizard.is_open() and helpers.current_text():find("pablo  [you]", 1, true) ~= nil end))
    helpers.press_key("jj<CR>")
    assert(vim.wait(2000, function() return helpers.current_text():find("acme/widgets", 1, true) ~= nil end))
    helpers.press_key("<CR>")
    assert(helpers.win_title(helpers.current_float_win()):find("acme/widgets", 1, true) ~= nil, "palette opened for acme/widgets")
    helpers.press_key("h")
    assert(
        vim.wait(2000, function()
            return wizard.is_open() and helpers.current_text():find("pablo  [you]", 1, true) ~= nil
        end),
        "pressing h from repo-scoped palette returns to owner/repo picker"
    )
    -- Re-select acme/widgets and verify manual PR number inherits context.repo.
    helpers.press_key("jj<CR>")
    assert(vim.wait(2000, function() return helpers.current_text():find("acme/widgets", 1, true) ~= nil end))
    helpers.press_key("<CR>")
    helpers.press_key("<CR>j<CR>i42<CR>")
    assert(opened_call ~= nil and opened_call.number == 42 and opened_call.repo == "acme/widgets", "manual PR number inherits context.repo")

    -- Entering a full PR URL for another repo overrides context.repo.
    opened_call = nil
    jpr.command({})
    assert(vim.wait(2000, function() return wizard.is_open() and helpers.current_text():find("pablo  [you]", 1, true) ~= nil end))
    helpers.press_key("jj<CR>")
    assert(vim.wait(2000, function() return helpers.current_text():find("acme/widgets", 1, true) ~= nil end))
    helpers.press_key("<CR>")
    helpers.press_key("<CR>j<CR>ihttps://github.com/other/project/pull/99<CR>")
    assert(
        opened_call ~= nil and opened_call.number == 99 and opened_call.repo == "other/project",
        "manual PR URL overrides context.repo: " .. vim.inspect(opened_call)
    )
end)

-- 3. Auth error (exit code 3) during jpr-review owners prompts auth and resumes into repo picker and repo-scoped palette.
do
    local owner_attempts = 0
    with_non_git_env(function(cmd, _opts, on_exit)
        vim.schedule(function()
            if cmd[2] == "owners" then
                owner_attempts = owner_attempts + 1
                if owner_attempts == 1 then
                    on_exit({ code = 3, stdout = "", stderr = "gh auth login" })
                else
                    on_exit({
                        code = 0,
                        stdout = vim.json.encode({ { login = "pablo", name = "Pablo", kind = "user" } }),
                        stderr = "",
                    })
                end
            elseif cmd[2] == "repos" then
                on_exit({
                    code = 0,
                    stdout = vim.json.encode({
                        { nameWithOwner = "pablo/app", description = nil, isPrivate = false, isArchived = false, updatedAt = "2026-11-24T00:00:00Z" },
                    }),
                    stderr = "",
                })
            end
        end)
    end, function()
        local prompted = 0
        auth.prompt_and_resume = function(opts)
            prompted = prompted + 1
            opts.on_authenticated()
        end
        jpr.command({})
        assert(
            vim.wait(2000, function()
                return wizard.is_open() and helpers.current_text():find("pablo/app", 1, true) ~= nil
            end),
            "resumed repo picker after owners auth recovery"
        )
        assert(prompted == 1 and owner_attempts == 2, "auth prompted once and owners retried")
        helpers.press_key("<CR>")
        assert(
            helpers.win_title(helpers.current_float_win()):find("pablo/app", 1, true) ~= nil,
            "selecting resumed repo opens repo-scoped palette"
        )
    end)
end

-- 4. Bare :Jpr open outside a git repo runs repo picker first, then opens PR picker for chosen repo.
with_non_git_env(function(cmd, _opts, on_exit)
    vim.schedule(function()
        if cmd[2] == "owners" then
            on_exit({ code = 0, stdout = vim.json.encode({ { login = "pablo", kind = "user" } }), stderr = "" })
        elseif cmd[2] == "repos" then
            on_exit({
                code = 0,
                stdout = vim.json.encode({
                    { nameWithOwner = "pablo/tool", description = nil, isPrivate = false, isArchived = false, updatedAt = "2026-11-24T00:00:00Z" },
                }),
                stderr = "",
            })
        elseif cmd[2] == "prs" then
            assert(vim.tbl_contains(cmd, "pablo/tool"), "prs queried pablo/tool")
            on_exit({
                code = 0,
                stdout = vim.json.encode({
                    { number = 5, title = "Tool PR", author = "pablo", headRef = "main", isDraft = false, updatedAt = "2026-11-24T00:00:00Z" },
                }),
                stderr = "",
            })
        end
    end)
end, function()
    jpr.command({ "open" })
    assert(vim.wait(2000, function() return wizard.is_open() and helpers.current_text():find("pablo/tool", 1, true) ~= nil end), "bare :Jpr open runs repo picker")
    helpers.press_key("<CR>")
    assert(vim.wait(2000, function() return wizard.is_open() and helpers.current_text():find("#5  Tool PR", 1, true) ~= nil end), "after repo pick opens PR picker directly")
end)

print("repo_picker_spec: ok")
