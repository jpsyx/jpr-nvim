-- Plugin-local binary discovery and coding-agent terminal PATH construction.
local M = {}

--- Whether `is_windows` (or the host OS when nil) uses Windows executable conventions.
function M.is_windows_platform(is_windows)
    if type(is_windows) == "boolean" then
        return is_windows
    end
    return vim.fn.has("win32") == 1
end

--- Filename of the compiled review engine executable for the target platform.
function M.binary_filename(is_windows)
    if M.is_windows_platform(is_windows) then
        return "jpr-review.exe"
    end
    return "jpr-review"
end

--- Root directory of this `jpr-nvim` plugin checkout.
function M.plugin_root()
    -- Walk three parent directories up from `<root>/lua/jpr/binary.lua`.
    local source_path = debug.getinfo(1, "S").source:gsub("^@", "")
    return vim.fn.fnamemodify(source_path, ":p:h:h:h")
end

--- Default bundled release binary path inside `plugin_root` (or `M.plugin_root()`).
function M.default_binary_path(plugin_root, is_windows)
    local root_directory = (type(plugin_root) == "string" and plugin_root ~= "")
        and plugin_root
        or M.plugin_root()
    return root_directory .. "/target/release/" .. M.binary_filename(is_windows)
end

--- Active engine binary path or command from `config`, defaulting to the bundled release binary.
function M.get_binary_path_from_config(config, plugin_root)
    if type(config) == "table" and type(config.binary) == "string" and config.binary ~= "" then
        return config.binary
    end
    return M.default_binary_path(plugin_root)
end

--- Whether `binary_path` contains a forward or backward directory separator.
function M.has_path_separator(binary_path)
    if type(binary_path) ~= "string" then
        return false
    end
    return binary_path:find("/", 1, true) ~= nil or binary_path:find("\\", 1, true) ~= nil
end

--- Prepends `directory` to `current_path` unless `directory` is already the first PATH entry.
function M.build_path_from_directory(directory, current_path, is_windows)
    local separator = M.is_windows_platform(is_windows) and ";" or ":"
    local active_path = current_path ~= nil and tostring(current_path) or ""
    if type(directory) ~= "string" or directory == "" then
        return active_path
    end
    if active_path == directory or vim.startswith(active_path, directory .. separator) then
        return active_path
    end
    if active_path == "" then
        return directory
    end
    return directory .. separator .. active_path
end

--- Creates the environment table for `:Jpr agent` terminals, prepending the bundled
--- binary directory to `PATH` whenever `binary_path` is an executable file path.
function M.create_agent_env_from_session(binary_path, socket, pr_number, current_path)
    local active_path = current_path ~= nil and tostring(current_path) or (vim.env.PATH or "")
    local updated_path = active_path
    if M.has_path_separator(binary_path) and vim.fn.executable(binary_path) == 1 then
        local binary_directory = vim.fn.fnamemodify(binary_path, ":p:h")
        updated_path = M.build_path_from_directory(binary_directory, active_path)
    end
    local env = {
        JPR_SOCKET = tostring(socket or ""),
        PATH = updated_path,
    }
    if pr_number ~= nil then
        env.JPR_PR = tostring(pr_number)
    end
    return env
end

return M
