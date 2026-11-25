-- Buffer snapshot, WorkspaceEdit application, autosave, and open-buffer path
-- updates for `jpr.lsp_files`.
local clients = require("jpr.lsp_files.clients")

local M = {}

--- Captures modified state and changedtick for every currently valid file buffer
--- before applying LSP `WorkspaceEdit`s.
function M.create_dirty_snapshot()
    local snapshot = { pre_dirty = {}, pre_tick = {} }
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" then
            snapshot.pre_dirty[buf] = vim.bo[buf].modified == true
            if vim.api.nvim_buf_is_loaded(buf) then
                snapshot.pre_tick[buf] = vim.api.nvim_buf_get_changedtick(buf)
            end
        end
    end
    return snapshot
end

--- Applies every `{ client, edit }` entry collected from `workspace/will*Files`.
function M.apply_collected_edits(collected_edits)
    for _, entry in ipairs(collected_edits) do
        vim.lsp.util.apply_workspace_edit(entry.edit, entry.client.offset_encoding or "utf-16")
    end
end

--- Autosaves buffers modified by LSP `WorkspaceEdit`s that were clean prior to
--- the edit, and warns about any pre-dirty buffers that were also edited.
function M.autosave_edited_buffers(snapshot)
    local jpr = require("jpr")
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
            local prev_tick = snapshot.pre_tick[buf]
            local curr_tick = vim.api.nvim_buf_get_changedtick(buf)
            local was_edited = prev_tick == nil or curr_tick ~= prev_tick
            if was_edited and vim.bo[buf].modified then
                if snapshot.pre_dirty[buf] then
                    local name = vim.api.nvim_buf_get_name(buf)
                    jpr.warn(("Buffer %s had unsaved changes before LSP edits; save manually."):format(name))
                else
                    vim.api.nvim_buf_call(buf, function()
                        pcall(vim.cmd, "silent update")
                    end)
                end
            end
        end
    end
end

local function compute_renamed_target(buf_norm, old_abs, old_real, new_abs, is_directory)
    if not is_directory then
        if buf_norm == old_abs or (old_real ~= nil and buf_norm == old_real) then
            return new_abs
        end
        return nil
    end
    local old_prefix = old_abs .. "/"
    if buf_norm:sub(1, #old_prefix) == old_prefix then
        return new_abs .. "/" .. buf_norm:sub(#old_prefix + 1)
    end
    if old_real ~= nil then
        local real_prefix = old_real .. "/"
        if buf_norm:sub(1, #real_prefix) == real_prefix then
            return new_abs .. "/" .. buf_norm:sub(#real_prefix + 1)
        end
    end
    return nil
end

local function clear_unloaded_target_buffer(target_path, exclude_buf)
    local target_norm = clients.normalize_path(target_path)
    for _, other_buf in ipairs(vim.api.nvim_list_bufs()) do
        if
            other_buf ~= exclude_buf
            and vim.api.nvim_buf_is_valid(other_buf)
            and not vim.api.nvim_buf_is_loaded(other_buf)
            and not vim.bo[other_buf].modified
        then
            local other_name = vim.api.nvim_buf_get_name(other_buf)
            if other_name ~= "" and clients.normalize_path(other_name) == target_norm then
                pcall(vim.api.nvim_buf_delete, other_buf, { force = true })
            end
        end
    end
end

--- Updates open Neovim buffer names after `old_abs` moves to `new_abs` (exact
--- file match or strict directory prefix match with `/` boundary).
function M.rename_open_buffers(old_abs, old_real, new_abs, is_directory)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" then
            local buf_name = vim.api.nvim_buf_get_name(buf)
            if buf_name ~= "" then
                local buf_norm = clients.normalize_path(buf_name)
                local target_path = compute_renamed_target(buf_norm, old_abs, old_real, new_abs, is_directory)
                if target_path ~= nil then
                    local was_modified = vim.bo[buf].modified == true
                    clear_unloaded_target_buffer(target_path, buf)
                    local renamed_ok = pcall(vim.api.nvim_buf_set_name, buf, target_path)
                    if renamed_ok and not was_modified and vim.api.nvim_buf_is_loaded(buf) then
                        vim.api.nvim_buf_call(buf, function()
                            pcall(vim.cmd, "silent edit!")
                        end)
                    end
                end
            end
        end
    end
end

--- Removes a temporary cold-start buffer if it is still valid and unmodified.
function M.cleanup_temp_buffer(temp_buf)
    if temp_buf and vim.api.nvim_buf_is_valid(temp_buf) and not vim.bo[temp_buf].modified then
        pcall(vim.api.nvim_buf_delete, temp_buf, { force = true })
    end
end

return M
