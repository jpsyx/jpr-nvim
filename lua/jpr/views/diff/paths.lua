-- Worktree-relative path resolution and changed-file buffer lookup (`jpr.views.diff`).
local M = {}

--- `path` with every symlink, `.` and `..` resolved, even when its last parts
--- do not exist (a file the pull request deletes). Nil when some part of it
--- exists but does not resolve (a dangling or looping symlink), since a
--- write there would land wherever the link points.
local function path_to_real_path(path)
    local resolved_path = vim.uv.fs_realpath(path)
    if resolved_path then
        return resolved_path
    end
    if vim.uv.fs_lstat(path) then
        return nil
    end
    local parent = vim.fs.dirname(path)
    if parent == path then
        return path
    end
    local real_parent = path_to_real_path(parent)
    if not real_parent then
        return nil
    end
    local name = vim.fs.basename(path)
    if name == ".." then
        return vim.fs.dirname(real_parent)
    elseif name == "." then
        return real_parent
    end
    return vim.fs.joinpath(real_parent, name)
end

--- Attaches `name_to_relative_path` and `buffer_to_changed_path` onto `diff_mod`.
function M.attach(diff_mod)
    --- `name`'s path relative to `worktree`, or nil when it is not inside it or
    --- does not resolve.
    function diff_mod.name_to_relative_path(worktree, name)
        if name == "" then
            return nil
        end
        local root = path_to_real_path((vim.fn.fnamemodify(worktree, ":p"):gsub("/+$", "")))
        local full_path = path_to_real_path(vim.fn.fnamemodify(name, ":p"))
        if not root or not full_path or full_path:sub(1, #root + 1) ~= root .. "/" then
            return nil
        end
        return full_path:sub(#root + 2)
    end

    --- The changed file `buf` shows, as its path in the pull request, or nil.
    function diff_mod.buffer_to_changed_path(session, buf)
        if vim.bo[buf].buftype ~= "" then
            return nil
        end
        local path = diff_mod.name_to_relative_path(session.worktree, vim.api.nvim_buf_get_name(buf))
        for _, file in ipairs((session.view and session.view.files) or {}) do
            if file.path == path then
                return path
            end
        end
        return nil
    end
end

return M
