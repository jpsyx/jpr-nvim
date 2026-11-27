-- Pure command argv parsing, Claude transcript lookup, cold-start CLI prompt
-- construction, Claude Vim-mode detection, and prompt preview extraction.
local M = {}

--- Maximum prompt byte length passed directly as a cold-start Claude CLI arg.
M.MAX_CLI_PROMPT_BYTES = 32768

local function split_shell_tokens(input)
    local tokens = {}
    local current = {}
    local active_quote = nil
    local index = 1
    while index <= #input do
        local character = input:sub(index, index)
        if active_quote then
            if character == active_quote then
                active_quote = nil
            else
                current[#current + 1] = character
            end
        elseif character == "'" or character == '"' then
            active_quote = character
        elseif character:match("%s") then
            if #current > 0 then
                tokens[#tokens + 1] = table.concat(current)
                current = {}
            end
        else
            current[#current + 1] = character
        end
        index = index + 1
    end
    if #current > 0 then
        tokens[#tokens + 1] = table.concat(current)
    end
    return tokens
end

--- Parses `command_spec` (string with optional flags/quotes, or string array)
--- into an argv list, falling back to `{ fallback }` when blank or missing.
function M.parse_command_argv(command_spec, fallback)
    local default_command = tostring(fallback or "claude")
    if type(command_spec) == "table" then
        local argv = {}
        for _, item in ipairs(command_spec) do
            if type(item) == "string" and item ~= "" then
                argv[#argv + 1] = item
            end
        end
        if #argv > 0 then
            return argv
        end
        return { default_command }
    end
    if type(command_spec) == "string" then
        local trimmed = vim.trim(command_spec)
        if trimmed ~= "" then
            local parsed = split_shell_tokens(trimmed)
            if #parsed > 0 then
                return parsed
            end
        end
    end
    return { default_command }
end

--- Builds the Claude Code project directory slug for `worktree`.
function M.build_claude_project_slug_from_worktree(worktree)
    local slug = tostring(worktree or ""):gsub("[^%w%-]", "-")
    return slug
end

--- Whether a Claude Code transcript file already exists for `worktree` and
--- `session_id` under `home_directory` (defaulting to the current user's home).
function M.has_claude_transcript(worktree, session_id, home_directory)
    if type(session_id) ~= "string" or session_id == "" then
        return false
    end
    local target_home_directory = (type(home_directory) == "string" and home_directory ~= "")
        and home_directory
        or vim.uv.os_homedir()
    if type(target_home_directory) ~= "string" or target_home_directory == "" then
        return false
    end
    local slug = M.build_claude_project_slug_from_worktree(worktree)
    local transcript_path = target_home_directory .. "/.claude/projects/" .. slug .. "/" .. session_id .. ".jsonl"
    return vim.uv.fs_stat(transcript_path) ~= nil
end

--- Whether a cold-start launch for `kind` may pass `prompt` directly via CLI
--- `-- <prompt>` rather than bracketed PTY paste.
function M.can_use_cli_initial_prompt(kind, prompt)
    return kind == "claude"
        and type(prompt) == "string"
        and prompt ~= ""
        and #prompt <= M.MAX_CLI_PROMPT_BYTES
end

local function append_list(target, extra)
    for _, item in ipairs(extra) do
        target[#target + 1] = item
    end
    return target
end

local function argv_contains_flag(argv, flag)
    local equals_prefix = flag .. "="
    for _, token in ipairs(argv) do
        if token == flag or token:sub(1, #equals_prefix) == equals_prefix then
            return true
        end
    end
    return false
end

local function trimmed_config_string(config, key)
    local value = config[key]
    if type(value) ~= "string" then
        return nil
    end
    local trimmed = vim.trim(value)
    if trimmed == "" then
        return nil
    end
    return trimmed
end

--- Appends configured Claude `--model` and `--effort` when `argv` does not
--- already set that flag. Explicit tokens in `claude_cmd` win.
local function append_configured_claude_flags(argv, config)
    local model = trimmed_config_string(config, "claude_model")
    if model and not argv_contains_flag(argv, "--model") then
        append_list(argv, { "--model", model })
    end
    local effort = trimmed_config_string(config, "claude_effort")
    if effort and not argv_contains_flag(argv, "--effort") then
        append_list(argv, { "--effort", effort })
    end
    return argv
end

--- Creates the terminal argv for launching or resuming the configured agent CLI
--- from `config`, `worktree`, `launch_plan`, and optional `initial_prompt`.
function M.create_launch_argv_from_plan(config, worktree, launch_plan, home_directory, initial_prompt)
    local plan = type(launch_plan) == "table" and launch_plan or {}
    local active_config = type(config) == "table" and config or {}
    local kind = (type(plan.kind) == "string" and plan.kind ~= "") and plan.kind or active_config.agent or "claude"
    local has_session_id = type(plan.sessionId) == "string" and plan.sessionId ~= ""
    local is_resume = plan.isResume == true
    if kind == "codex" then
        local argv = M.parse_command_argv(active_config.codex_cmd, "codex")
        if is_resume and has_session_id then
            return append_list(argv, { "resume", plan.sessionId })
        end
        return argv
    end
    local argv = M.parse_command_argv(active_config.claude_cmd, "claude")
    append_configured_claude_flags(argv, active_config)
    if has_session_id then
        if is_resume and M.has_claude_transcript(worktree, plan.sessionId, home_directory) then
            append_list(argv, { "--resume", plan.sessionId })
        else
            append_list(argv, { "--session-id", plan.sessionId })
        end
    end
    if M.can_use_cli_initial_prompt(kind, initial_prompt) then
        append_list(argv, { "--", initial_prompt })
    end
    return argv
end

local function read_file_bytes(path)
    local file_descriptor = vim.uv.fs_open(path, "r", 438)
    if not file_descriptor then
        return nil
    end
    local stat = vim.uv.fs_fstat(file_descriptor)
    local data = stat and stat.size > 0 and vim.uv.fs_read(file_descriptor, stat.size, 0) or ""
    vim.uv.fs_close(file_descriptor)
    return data
end

local function build_claude_settings_path(home_directory, claude_config_dir)
    if type(claude_config_dir) == "string" and claude_config_dir ~= "" then
        return claude_config_dir .. "/settings.json"
    end
    local env_dir = claude_config_dir == nil and vim.env.CLAUDE_CONFIG_DIR or nil
    if type(env_dir) == "string" and env_dir ~= "" then
        return env_dir .. "/settings.json"
    end
    local target_home = (type(home_directory) == "string" and home_directory ~= "")
        and home_directory
        or vim.uv.os_homedir()
    if type(target_home) ~= "string" or target_home == "" then
        return nil
    end
    return target_home .. "/.claude/settings.json"
end

--- Whether Claude Code's settings file enables `"editorMode": "vim"`.
function M.is_claude_vim_mode_enabled(home_directory, claude_config_dir)
    local settings_path = build_claude_settings_path(home_directory, claude_config_dir)
    if not settings_path then
        return false
    end
    local raw = read_file_bytes(settings_path)
    if type(raw) ~= "string" or raw == "" then
        return false
    end
    local ok, decoded = pcall(vim.json.decode, raw)
    return ok and type(decoded) == "table" and decoded.editorMode == "vim"
end

--- Extracts compact anchor preview labels from a numbered send `prompt`,
--- capped at `max_items` (default 5) with a trailing remainder line.
function M.extract_prompt_preview_items(prompt, max_items)
    if type(prompt) ~= "string" or prompt == "" then
        return {}
    end
    local limit = (type(max_items) == "number" and max_items > 0) and max_items or 5
    local all_items = {}
    for line in (prompt .. "\n"):gmatch("(.-)\n") do
        local label = line:match("^%d+%. %[[^%]]+%] (.+)$")
        if label and vim.trim(label) ~= "" then
            all_items[#all_items + 1] = vim.trim(label)
        end
    end
    if #all_items <= limit then
        return all_items
    end
    local trimmed = {}
    for index = 1, limit do
        trimmed[index] = all_items[index]
    end
    trimmed[#trimmed + 1] = ("... and %d more"):format(#all_items - limit)
    return trimmed
end

return M
