-- Self-contained native Neovim LSP file rename and create operations.
local buffers = require("jpr.lsp_files.buffers")
local clients = require("jpr.lsp_files.clients")

local M = {}

local PROCEED_CHOICE = "Proceed with rename without full LSP import updates"
local CANCEL_CHOICE = "Cancel rename"

local function normalize_abs_path(path)
    local normalized = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
    if #normalized > 1 then
        normalized = normalized:gsub("/+$", "")
    end
    return normalized
end

local function invoke_done(on_done, is_ok, err_or_nil)
    if type(on_done) == "function" then
        on_done(is_ok, err_or_nil)
    end
end

local function is_same_fs_entry(stat_a, stat_b)
    return stat_a ~= nil and stat_b ~= nil and stat_a.dev == stat_b.dev and stat_a.ino == stat_b.ino
end

local function validate_rename_paths(old_abs, new_abs)
    if old_abs == new_abs then
        return nil, "Source and destination paths are identical"
    end
    local old_stat = vim.uv.fs_lstat(old_abs)
    if not old_stat then
        return nil, ("Source path does not exist: %s"):format(old_abs)
    end
    local is_directory = old_stat.type == "directory"
    if is_directory and new_abs:sub(1, #old_abs + 1) == old_abs .. "/" then
        return nil, "Cannot move a directory inside itself"
    end
    local new_stat = vim.uv.fs_lstat(new_abs)
    local is_case_only = false
    if new_stat ~= nil then
        if is_same_fs_entry(old_stat, new_stat) and old_abs:lower() == new_abs:lower() then
            is_case_only = true
        else
            return nil, ("Destination already exists: %s"):format(new_abs)
        end
    end
    return { is_directory = is_directory, is_case_only = is_case_only }, nil
end

local function perform_fs_rename(old_abs, new_abs, is_case_only)
    vim.fn.mkdir(vim.fs.dirname(new_abs), "p")
    if not is_case_only then
        local ok, rename_err = vim.uv.fs_rename(old_abs, new_abs)
        return ok ~= nil, rename_err
    end
    local temp_abs = ("%s.jpr-rename-tmp-%d"):format(old_abs, vim.uv.hrtime())
    local step1_ok, step1_err = vim.uv.fs_rename(old_abs, temp_abs)
    if not step1_ok then
        return false, step1_err
    end
    local step2_ok, step2_err = vim.uv.fs_rename(temp_abs, new_abs)
    if not step2_ok then
        vim.uv.fs_rename(temp_abs, old_abs)
        return false, step2_err
    end
    return true, nil
end

local function format_failures_summary(failures)
    local parts = {}
    for _, failure in ipairs(failures) do
        parts[#parts + 1] = ("%s (%s)"):format(failure.client_name, failure.reason)
    end
    return table.concat(parts, ", ")
end

local function complete_rename(state, on_done)
    local snapshot = buffers.create_dirty_snapshot()
    buffers.apply_collected_edits(state.collected_edits)
    local old_real = vim.uv.fs_realpath(state.old_abs)
    local moved_ok, move_err = perform_fs_rename(state.old_abs, state.new_abs, state.is_case_only)
    if not moved_ok then
        buffers.cleanup_temp_buffer(state.temp_buf)
        return invoke_done(on_done, false, tostring(move_err or "Failed to rename path"))
    end
    buffers.rename_open_buffers(state.old_abs, old_real, state.new_abs, state.is_directory)
    buffers.autosave_edited_buffers(snapshot)
    buffers.cleanup_temp_buffer(state.temp_buf)
    clients.notify_did_op(
        "didRename",
        "workspace/didRenameFiles",
        { state.old_abs, state.new_abs },
        state.is_directory,
        state.params
    )
    invoke_done(on_done, true, nil)
end

local function request_will_rename_edits(old_abs, new_abs, is_directory, params, options, jpr)
    local attach_timeout = options.attach_timeout_ms
    if attach_timeout == nil then
        attach_timeout = jpr.config.lsp_attach_timeout_ms or 3000
    end
    local op_timeout = options.timeout_ms or jpr.config.lsp_file_ops_timeout_ms or 30000
    local matching_clients, temp_buf = clients.ensure_rename_clients(old_abs, new_abs, is_directory, attach_timeout)
    if #matching_clients == 0 then
        return {}, {}, temp_buf
    end
    vim.api.nvim_echo({ { "jpr: Updating imports via LSP...", "JprMuted" } }, false, {})
    local collected_edits, failures = clients.collect_will_edits(matching_clients, "workspace/willRenameFiles", params, op_timeout)
    vim.api.nvim_echo({ { "" } }, false, {})
    return collected_edits, failures, temp_buf
end

--- Renames or moves `old_abs` to `new_abs` with native LSP `willRenameFiles`
--- / `didRenameFiles` support, case-only APFS handling, and open buffer sync.
function M.rename(old_abs_raw, new_abs_raw, opts, on_done)
    local options = opts or {}
    local jpr = require("jpr")
    local old_abs = normalize_abs_path(old_abs_raw)
    local new_abs = normalize_abs_path(new_abs_raw)
    local info, validate_err = validate_rename_paths(old_abs, new_abs)
    if not info then
        return invoke_done(on_done, false, validate_err)
    end
    local params = { files = { { oldUri = vim.uri_from_fname(old_abs), newUri = vim.uri_from_fname(new_abs) } } }
    local collected_edits, failures, temp_buf =
        request_will_rename_edits(old_abs, new_abs, info.is_directory, params, options, jpr)
    local state = {
        old_abs = old_abs,
        new_abs = new_abs,
        is_directory = info.is_directory,
        is_case_only = info.is_case_only,
        params = params,
        collected_edits = collected_edits,
        temp_buf = temp_buf,
    }
    if #failures == 0 then
        return complete_rename(state, on_done)
    end
    local summary = format_failures_summary(failures)
    jpr.warn(("LSP willRenameFiles failed for %s"):format(summary))
    vim.ui.select({ PROCEED_CHOICE, CANCEL_CHOICE }, { prompt = ("LSP error (%s):"):format(summary) }, function(choice)
        if choice ~= PROCEED_CHOICE then
            buffers.cleanup_temp_buffer(temp_buf)
            return invoke_done(on_done, false, "Rename cancelled by user")
        end
        complete_rename(state, on_done)
    end)
end

local function create_empty_file(target_abs)
    vim.fn.mkdir(vim.fs.dirname(target_abs), "p")
    local fd, open_err = vim.uv.fs_open(target_abs, "w", 438)
    if not fd then
        return false, tostring(open_err or "Failed to create file")
    end
    vim.uv.fs_close(fd)
    return true, nil
end

--- Creates a new file or directory at `target_abs`, invoking LSP
--- `willCreateFiles` and `didCreateFiles` for regular files.
function M.create(target_abs_raw, is_directory, opts, on_done)
    local options = opts or {}
    local jpr = require("jpr")
    local target_abs = normalize_abs_path(target_abs_raw)
    if vim.uv.fs_lstat(target_abs) ~= nil then
        return invoke_done(on_done, false, ("Destination already exists: %s"):format(target_abs))
    end
    if is_directory then
        vim.fn.mkdir(target_abs, "p")
        local created_stat = vim.uv.fs_stat(target_abs)
        if not created_stat or created_stat.type ~= "directory" then
            return invoke_done(on_done, false, ("Failed to create directory: %s"):format(target_abs))
        end
        return invoke_done(on_done, true, nil)
    end
    local op_timeout = options.timeout_ms or jpr.config.lsp_file_ops_timeout_ms or 30000
    local params = { files = { { uri = vim.uri_from_fname(target_abs) } } }
    local matching_clients = clients.find_matching_clients("willCreate", { target_abs }, false)
    local collected_edits, failures = clients.collect_will_edits(matching_clients, "workspace/willCreateFiles", params, op_timeout)
    if #failures > 0 then
        jpr.warn(("LSP willCreateFiles failed for %s; proceeding with file creation"):format(format_failures_summary(failures)))
    end
    local snapshot = buffers.create_dirty_snapshot()
    local created_ok, create_err = create_empty_file(target_abs)
    if not created_ok then
        return invoke_done(on_done, false, create_err)
    end
    buffers.apply_collected_edits(collected_edits)
    buffers.autosave_edited_buffers(snapshot)
    clients.notify_did_op("didCreate", "workspace/didCreateFiles", { target_abs }, false, params)
    invoke_done(on_done, true, nil)
end

return M
