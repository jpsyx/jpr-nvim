-- Pure choice of which comment gc, gf, gC, or the PR shortcut opens.
local M = {}

local function has_file(location)
    return type(location.file_path) == "string" and location.file_path ~= ""
end

--- Returns the comment kind for `request` at `location`, or nil and an error.
--- `request` is `"versatile"` (gc), `"file"` (gf), `"suggest"` (gC), or `"pr"`.
--- Versatile gc stays a line comment whenever the cursor is on a diff line.
--- It opens a file comment or a standalone PR comment only when that is the
--- only comment the location can take.
--- @param location table|nil
--- @param request string|nil
--- @return string|nil
--- @return string|nil
function M.resolve_comment_kind(location, request)
    local loc = type(location) == "table" and location or {}
    if request == "pr" then
        return "pr"
    end
    if request == "suggest" then
        if loc.is_on_diff_line == true then
            return "line"
        end
        return nil, "cannot anchor a suggestion on this line"
    end
    if request == "file" then
        if has_file(loc) then
            return "file"
        end
        return nil, "move to a changed file to add a file-level comment"
    end
    if loc.is_on_diff_line == true then
        return "line"
    end
    if has_file(loc) then
        return "file"
    end
    if loc.is_pr_surface == true then
        return "pr"
    end
    return nil, "move to a changed file, Diff summary, or Conversation to comment"
end

return M
