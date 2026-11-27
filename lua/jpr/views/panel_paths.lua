-- Pure path resolution and validation for inline sidebar rename and create inputs.
local diff_view = require("jpr.views.diff")

local M = {}

local function strip_trailing_slashes(path)
    return (path:gsub("/+$", ""))
end

local function parent_dir_of(relative_path)
    local clean = strip_trailing_slashes(relative_path or "")
    local parent = clean:match("^(.+)/[^/]+$")
    return parent or ""
end

local function basename_of(relative_path)
    local clean = strip_trailing_slashes(relative_path or "")
    return clean:match("([^/]+)$") or clean
end

--- Builds the context table for an inline rename input from a sidebar `row`.
function M.create_rename_context_from_row(worktree, row)
    local target_path = strip_trailing_slashes(row.path or "")
    return {
        mode = "rename",
        worktree = worktree,
        current_dir = parent_dir_of(target_path),
        target_path = target_path,
        initial_text = basename_of(target_path),
        is_directory = row.kind == "dir",
    }
end

--- Builds the context table for an inline create input from a sidebar `row`.
function M.create_create_context_from_row(worktree, row)
    local current_dir = ""
    if row ~= nil and row.kind == "dir" then
        current_dir = strip_trailing_slashes(row.path or "")
    elseif row ~= nil and row.kind == "file" then
        current_dir = parent_dir_of(row.path or "")
    end
    return {
        mode = "create",
        worktree = worktree,
        current_dir = current_dir,
    }
end

local function detect_path_mode(body)
    if body:sub(1, 2) == "./" or body:sub(1, 3) == "../" or body == "." or body == ".." then
        return "current_dir"
    end
    if body:find("/", 1, true) ~= nil then
        return "project_root"
    end
    return "same_dir"
end

local function has_git_segment(relative_path)
    for _, segment in ipairs(vim.split(relative_path, "/", { plain = true, trimempty = true })) do
        if segment == ".git" then
            return true
        end
    end
    return false
end

local function normalize_segments(base_dir, body, mode)
    local stack = {}
    if mode ~= "project_root" and base_dir ~= "" then
        for _, segment in ipairs(vim.split(base_dir, "/", { plain = true, trimempty = true })) do
            stack[#stack + 1] = segment
        end
    end
    for _, segment in ipairs(vim.split(body, "/", { plain = true, trimempty = true })) do
        if segment == ".." then
            if #stack == 0 then
                return nil, "Path escapes the worktree root"
            end
            table.remove(stack)
        elseif segment == ".git" then
            return nil, "Path cannot target .git"
        elseif segment ~= "." then
            stack[#stack + 1] = segment
        end
    end
    if #stack == 0 then
        return nil, "Path cannot resolve to the worktree root"
    end
    return table.concat(stack, "/"), nil
end

local function build_hint_from_mode(mode, relative_path)
    if mode == "project_root" then
        return ("Path is relative to project root -> %s"):format(relative_path)
    end
    if mode == "current_dir" then
        return ("Path is relative to current directory -> %s"):format(relative_path)
    end
    return ("-> %s"):format(relative_path)
end

local function validate_raw_input(raw_input, context)
    local trimmed = vim.trim(raw_input or "")
    if trimmed == "" then
        return nil, "Path cannot be empty", "same_dir"
    end
    if trimmed:find("[%z\r\n]") ~= nil then
        return nil, "Path contains invalid control characters", "same_dir"
    end
    if trimmed:sub(1, 1) == "/" then
        return nil, "Absolute paths are not allowed", "project_root"
    end
    local has_trailing_slash = trimmed:sub(-1) == "/"
    if context.mode == "rename" and has_trailing_slash and not context.is_directory then
        return nil, "File rename target cannot end with '/'", detect_path_mode(strip_trailing_slashes(trimmed))
    end
    local body = strip_trailing_slashes(trimmed)
    local mode = detect_path_mode(body)
    if body == "" or body == "." or body == ".." then
        return nil, "Path cannot be empty, '.', or '..'", mode
    end
    local is_directory = context.mode == "create" and has_trailing_slash or (context.is_directory == true)
    return { body = body, mode = mode, is_directory = is_directory }, nil, mode
end

local function validate_rename_target(relative_path, context)
    if context.mode ~= "rename" or not context.target_path then
        return nil
    end
    local target = strip_trailing_slashes(context.target_path)
    if relative_path == target then
        return "Destination is the same as the current path"
    end
    if context.is_directory and relative_path:sub(1, #target + 1) == target .. "/" then
        return "Cannot move a directory inside itself"
    end
    return nil
end

--- Resolves `raw_input` against `context` (`mode`, `worktree`, `current_dir`,
--- optional `target_path` and `is_directory`), enforcing worktree boundaries.
function M.parse_input_from_context(raw_input, context)
    local parsed, input_err, err_mode = validate_raw_input(raw_input, context)
    if not parsed then
        return { ok = false, error = input_err, mode = err_mode }
    end
    local relative_path, segment_err = normalize_segments(context.current_dir or "", parsed.body, parsed.mode)
    if not relative_path then
        return { ok = false, error = segment_err, mode = parsed.mode }
    end
    local rename_err = validate_rename_target(relative_path, context)
    if rename_err then
        return { ok = false, error = rename_err, mode = parsed.mode }
    end
    local worktree_clean = strip_trailing_slashes(context.worktree or "")
    local absolute_path = worktree_clean .. "/" .. relative_path
    local verified_relative = diff_view.name_to_relative_path(worktree_clean, absolute_path)
    if not verified_relative then
        return { ok = false, error = "Path escapes the worktree root", mode = parsed.mode }
    end
    if has_git_segment(verified_relative) then
        return { ok = false, error = "Path cannot target .git", mode = parsed.mode }
    end
    return {
        ok = true,
        relative_path = relative_path,
        absolute_path = absolute_path,
        is_directory = parsed.is_directory,
        mode = parsed.mode,
        hint = build_hint_from_mode(parsed.mode, relative_path),
    }
end

return M
