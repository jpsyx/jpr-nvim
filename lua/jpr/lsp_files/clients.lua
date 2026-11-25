-- LSP client discovery, capability/glob filtering, cold-start attach, and
-- workspace fileOperations requests for `jpr.lsp_files`.
local M = {}

--- Normalizes `path` to an absolute path without trailing slashes (except `/`).
function M.normalize_path(path)
    local normalized = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
    if #normalized > 1 then
        normalized = normalized:gsub("/+$", "")
    end
    return normalized
end

local function resolve_realpath_or_parent(path)
    local direct = vim.uv.fs_realpath(path)
    if direct then
        return M.normalize_path(direct)
    end
    local current = path
    local suffix_parts = {}
    while true do
        local parent = vim.fs.dirname(current)
        if not parent or parent == current then
            return nil
        end
        suffix_parts[#suffix_parts + 1] = vim.fs.basename(current)
        local parent_real = vim.uv.fs_realpath(parent)
        if parent_real then
            local resolved = M.normalize_path(parent_real)
            for idx = #suffix_parts, 1, -1 do
                resolved = resolved .. "/" .. suffix_parts[idx]
            end
            return resolved
        end
        current = parent
    end
end

local function is_path_under_root(path, root)
    if path == root or path:sub(1, #root + 1) == root .. "/" then
        return true
    end
    local real_path = resolve_realpath_or_parent(path)
    local real_root = vim.uv.fs_realpath(root)
    if real_path and real_root then
        local norm_root = M.normalize_path(real_root)
        return real_path == norm_root or real_path:sub(1, #norm_root + 1) == norm_root .. "/"
    end
    return false
end

local function collect_client_roots(client)
    local roots = {}
    if type(client.workspace_folders) == "table" then
        for _, folder in ipairs(client.workspace_folders) do
            if type(folder) == "table" and type(folder.uri) == "string" then
                roots[#roots + 1] = M.normalize_path(vim.uri_to_fname(folder.uri))
            end
        end
    end
    local config_root = client.config and client.config.root_dir
    if type(config_root) == "string" and config_root ~= "" then
        roots[#roots + 1] = M.normalize_path(config_root)
    elseif type(client.root_dir) == "string" and client.root_dir ~= "" then
        roots[#roots + 1] = M.normalize_path(client.root_dir)
    end
    return roots
end

local function client_covers_any_path(client, paths)
    local roots = collect_client_roots(client)
    if #roots == 0 then
        return true
    end
    for _, root in ipairs(roots) do
        for _, path in ipairs(paths) do
            if is_path_under_root(path, root) then
                return true
            end
        end
    end
    return false
end

local function matches_glob_filter(filter, path, is_directory)
    if type(filter) ~= "table" then
        return true
    end
    if filter.scheme and filter.scheme ~= "file" then
        return false
    end
    local pattern = filter.pattern
    if type(pattern) ~= "table" then
        return true
    end
    if pattern.matches == "file" and is_directory then
        return false
    end
    if pattern.matches == "folder" and not is_directory then
        return false
    end
    if type(pattern.glob) ~= "string" then
        return true
    end
    local ignore_case = type(pattern.options) == "table" and pattern.options.ignoreCase == true
    local glob_text = ignore_case and pattern.glob:lower() or pattern.glob
    local target_text = ignore_case and path:lower() or path
    local ok, matcher = pcall(vim.glob.to_lpeg, glob_text)
    if not ok or not matcher then
        return true
    end
    return matcher:match(target_text) ~= nil
end

local function registration_matches(registration, paths, is_directory)
    if not registration then
        return false
    end
    if type(registration) ~= "table" or type(registration.filters) ~= "table" or #registration.filters == 0 then
        return true
    end
    for _, filter in ipairs(registration.filters) do
        for _, path in ipairs(paths) do
            if matches_glob_filter(filter, path, is_directory) then
                return true
            end
        end
    end
    return false
end

--- Finds active LSP clients supporting `op_name` (`willRename`, `didRename`,
--- `willCreate`, `didCreate`) whose root and filters cover `paths`.
function M.find_matching_clients(op_name, paths, is_directory)
    local matches = {}
    for _, client in ipairs(vim.lsp.get_clients()) do
        local caps = client.server_capabilities
        local file_ops = caps and caps.workspace and caps.workspace.fileOperations
        local registration = file_ops and file_ops[op_name]
        if registration_matches(registration, paths, is_directory) and client_covers_any_path(client, paths) then
            matches[#matches + 1] = client
        end
    end
    return matches
end

local function find_loaded_buffer_for_path(abs_path)
    local target = M.normalize_path(abs_path)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
            local name = vim.api.nvim_buf_get_name(buf)
            if name ~= "" and M.normalize_path(name) == target then
                return buf
            end
        end
    end
    return nil
end

--- Loads `old_abs` into a temporary unlisted buffer and waits up to
--- `attach_timeout_ms` for a `willRename`-capable LSP client to attach.
--- Returns `(matching_clients, temp_buf_or_nil)`.
function M.ensure_rename_clients(old_abs, new_abs, is_directory, attach_timeout_ms)
    local paths = { old_abs, new_abs }
    local clients = M.find_matching_clients("willRename", paths, is_directory)
    if #clients > 0 or is_directory or (attach_timeout_ms or 0) <= 0 then
        return clients, nil
    end
    local existing_buf = find_loaded_buffer_for_path(old_abs)
    local temp_buf = nil
    if not existing_buf then
        temp_buf = vim.fn.bufadd(old_abs)
        vim.bo[temp_buf].buflisted = false
        pcall(vim.fn.bufload, temp_buf)
    end
    vim.api.nvim_echo({ { "jpr: Waiting for LSP to attach...", "JprMuted" } }, false, {})
    vim.wait(attach_timeout_ms, function()
        clients = M.find_matching_clients("willRename", paths, false)
        return #clients > 0
    end, 50)
    vim.api.nvim_echo({ { "" } }, false, {})
    return clients, temp_buf
end

local function format_lsp_error(err)
    if type(err) == "table" then
        return tostring(err.message or err.code or "LSP error")
    end
    return tostring(err or "unknown error")
end

--- Sends a synchronous `workspace/will*Files` request to every client in
--- `clients`, returning `(collected_edits, failures)` without applying edits.
function M.collect_will_edits(clients, method, params, timeout_ms)
    local collected_edits = {}
    local failures = {}
    for _, client in ipairs(clients) do
        local response, sync_err = client:request_sync(method, params, timeout_ms)
        local client_name = client.name or tostring(client.id)
        if not response then
            failures[#failures + 1] = { client_name = client_name, reason = format_lsp_error(sync_err or "timeout") }
        elseif response.err or response.error then
            failures[#failures + 1] = {
                client_name = client_name,
                reason = format_lsp_error(response.err or response.error),
            }
        elseif type(response.result) == "table" then
            collected_edits[#collected_edits + 1] = { client = client, edit = response.result }
        end
    end
    return collected_edits, failures
end

--- Sends a `workspace/did*Files` notification to all clients matching `op_name`.
function M.notify_did_op(op_name, method, paths, is_directory, params)
    for _, client in ipairs(M.find_matching_clients(op_name, paths, is_directory)) do
        pcall(function()
            client:notify(method, params)
        end)
    end
end

return M
