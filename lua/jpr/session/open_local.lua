-- `:Jpr local [base_ref]` probe, canonical worktree tab reuse, and local/PR dispatch.
local crash = require("jpr.session.crash")

local M = {}

local function jpr()
    return require("jpr")
end

local function canonical_path(path)
    if type(path) ~= "string" or path == "" then
        return ""
    end
    local resolved = vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
    return resolved:gsub("/+$", "")
end

local function build_local_probe_args(base_ref)
    local args = { jpr().binary_path(), "local" }
    if type(base_ref) == "string" and vim.trim(base_ref) ~= "" then
        vim.list_extend(args, { "--base", vim.trim(base_ref) })
    end
    return args
end

local function parse_local_output(stdout)
    local last_line
    for line in (stdout or ""):gmatch("[^\n]+") do
        if vim.trim(line) ~= "" then
            last_line = line
        end
    end
    if not last_line then
        return nil, "jpr-review local printed nothing"
    end
    local is_decoded, info = pcall(vim.json.decode, last_line)
    if not is_decoded or type(info) ~= "table" or type(info.worktree) ~= "string" then
        return nil, "unexpected local output: " .. last_line
    end
    if info.mode ~= "pr" and info.mode ~= "local" then
        return nil, "unexpected local mode: " .. tostring(info.mode)
    end
    return info
end

local function find_tab_for_worktree(session_mod, worktree)
    local target = canonical_path(worktree)
    for tab, existing in pairs(session_mod.by_tab) do
        if vim.api.nvim_tabpage_is_valid(tab) and canonical_path(existing.worktree) == target then
            return tab, existing
        end
    end
    return nil, nil
end

local function is_matching_session(existing, info)
    if info.mode == "pr" then
        return existing.number == info.number
    end
    local existing_base = (existing.view and existing.view.localContext and existing.view.localContext.baseRef)
        or existing.base_ref
    return existing.mode == "local" and existing_base == info.baseRef
end

local function build_mismatch_notice(existing, info)
    local current_label = existing.number and ("PR #" .. tostring(existing.number))
        or ("local review vs " .. tostring(existing.base_ref or "base"))
    local requested_label = info.mode == "pr" and ("PR #" .. tostring(info.number))
        or ("local review vs " .. tostring(info.baseRef or "base"))
    return ("this worktree is already open as %s (requested %s); run :Jpr close to switch"):format(
        current_label,
        requested_label
    )
end

local function handle_local_probe_result(session_mod, info)
    local existing_tab, existing_session = find_tab_for_worktree(session_mod, info.worktree)
    if existing_tab then
        vim.api.nvim_set_current_tabpage(existing_tab)
        if not is_matching_session(existing_session, info) then
            jpr().info(build_mismatch_notice(existing_session, info))
        end
        return
    end
    if info.mode == "pr" then
        return session_mod.start(info)
    end
    return session_mod.start_local(info)
end

local function open_local_worktree(session_mod, base_ref)
    local binary_path = jpr().binary_path()
    if vim.fn.executable(binary_path) ~= 1 then
        local clean_binary_path = crash.build_clean_text_from_raw(binary_path)
        return jpr().error(("jpr-review binary not found at %s; run :Lazy build jpr-nvim"):format(clean_binary_path))
    end
    local is_started, start_error = pcall(
        vim.system,
        build_local_probe_args(base_ref),
        { cwd = vim.fn.getcwd(), text = true },
        vim.schedule_wrap(function(result)
            if result.code ~= 0 then
                local stderr = crash.build_clean_text_from_raw(result.stderr)
                return jpr().error(stderr ~= "" and stderr or "failed to inspect current worktree")
            end
            local info, parse_error = parse_local_output(result.stdout)
            if not info then
                return jpr().error(parse_error)
            end
            handle_local_probe_result(session_mod, info)
        end)
    )
    if not is_started then
        local clean_error = crash.build_clean_text_from_raw(start_error)
        jpr().error(clean_error ~= "" and clean_error or "failed to inspect current worktree")
    end
end

local function start_local_session(info, hooks)
    jpr().define_highlights()
    hooks.setup_session_autocmds()
    vim.cmd("tabnew")
    local session = {
        mode = "local",
        tab = vim.api.nvim_get_current_tabpage(),
        placeholder_buf = vim.api.nvim_get_current_buf(),
        worktree = info.worktree,
        branch = info.branch,
        base_ref = info.baseRef,
        repo = info.repo,
        view = {
            localContext = {
                branch = info.branch,
                baseRef = info.baseRef,
                baseSha = info.baseSha,
                repo = info.repo,
            },
        },
    }
    local is_tcd_ok, tcd_error = pcall(vim.cmd.tcd, vim.fn.fnameescape(info.worktree))
    if not is_tcd_ok then
        hooks.forget(session)
        return jpr().error("could not enter worktree: " .. crash.build_clean_text_from_raw(tcd_error))
    end
    require("jpr.views.diff").attach(session)
    local is_opened, open_error = pcall(require("jpr.views.panel").open, session)
    if not is_opened then
        hooks.forget(session)
        return jpr().error("could not open the panel: " .. tostring(open_error))
    end
    hooks.spawn_engine(session)
end

--- Transitions an unlinked local `session` in-place when `pr` is linked.
function M.upgrade_local_session_to_pr(session, pr)
    session.mode = "pr"
    session.number = pr.number
    if type(pr.owner) == "string" and type(pr.repo) == "string" then
        session.repo = pr.owner .. "/" .. pr.repo
    end
    local title = type(pr.title) == "string" and pr.title or ""
    local suffix = title ~= "" and (": " .. crash.build_clean_text_from_raw(title)) or ""
    jpr().info(("Linked to PR #%d%s"):format(pr.number, suffix))
end

--- Attaches `:Jpr local [base_ref]` helpers and `start_local` onto `session_mod`.
function M.attach(session_mod, hooks)
    session_mod.local_probe_args = build_local_probe_args
    session_mod.parse_local_output = parse_local_output
    session_mod.handle_local_probe_result = function(info)
        return handle_local_probe_result(session_mod, info)
    end
    function session_mod.open_local(base_ref)
        return open_local_worktree(session_mod, base_ref)
    end
    function session_mod.start_local(info)
        return start_local_session(info, hooks)
    end
end

return M
