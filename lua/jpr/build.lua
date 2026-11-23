-- Release binary builder invoked by root `build.lua` during lazy.nvim install and update.
local binary = require("jpr.binary")

local M = {}

local function find_executable_in_path(executable_name, path_value, separator)
    if type(path_value) ~= "string" or path_value == "" then
        return nil
    end
    for _, directory in ipairs(vim.split(path_value, separator, { plain = true })) do
        if directory ~= "" then
            local candidate = directory .. "/" .. executable_name
            if vim.fn.executable(candidate) == 1 then
                return candidate
            end
        end
    end
    return nil
end

local function get_home_directory(home_dir)
    if type(home_dir) == "string" and home_dir ~= "" then
        return home_dir
    end
    if type(vim.env.HOME) == "string" and vim.env.HOME ~= "" then
        return vim.env.HOME
    end
    return vim.uv.os_homedir()
end

--- Finds an executable `cargo` binary across `env_map.PATH`, `CARGO_HOME/bin`,
--- and `<home_dir>/.cargo/bin` so GUI Neovim sessions without shell PATH still build.
function M.find_cargo_executable(env_map, home_dir)
    local is_windows = binary.is_windows_platform()
    local cargo_name = is_windows and "cargo.exe" or "cargo"
    local separator = is_windows and ";" or ":"
    local active_env = type(env_map) == "table"
        and env_map
        or { PATH = vim.env.PATH or "", CARGO_HOME = vim.env.CARGO_HOME }

    local path_match = find_executable_in_path(cargo_name, active_env.PATH, separator)
    if path_match then
        return path_match
    end
    if env_map == nil and active_env.PATH ~= "" then
        local system_cargo = vim.fn.exepath("cargo")
        if system_cargo ~= "" then
            return system_cargo
        end
    end
    if type(active_env.CARGO_HOME) == "string" and active_env.CARGO_HOME ~= "" then
        local cargo_home_candidate = active_env.CARGO_HOME .. "/bin/" .. cargo_name
        if vim.fn.executable(cargo_home_candidate) == 1 then
            return cargo_home_candidate
        end
    end
    local target_home = get_home_directory(home_dir)
    if type(target_home) == "string" and target_home ~= "" then
        local home_candidate = target_home .. "/.cargo/bin/" .. cargo_name
        if vim.fn.executable(home_candidate) == 1 then
            return home_candidate
        end
    end
    return nil
end

local function build_cargo_env_from_executable(cargo_path, env_map)
    local cargo_directory = vim.fn.fnamemodify(cargo_path, ":p:h")
    local base_path = (type(env_map) == "table" and env_map.PATH ~= nil)
        and tostring(env_map.PATH)
        or (vim.env.PATH or "")
    local cargo_env = { PATH = binary.build_path_from_directory(cargo_directory, base_path) }
    if type(env_map) == "table" then
        for key, value in pairs(env_map) do
            if key ~= "PATH" and value ~= nil then
                cargo_env[key] = tostring(value)
            end
        end
    end
    return cargo_env
end

local function format_build_output_suffix(result)
    local detail = vim.trim(result.stderr or "")
    if detail == "" then
        detail = vim.trim(result.stdout or "")
    end
    return detail ~= "" and ("\n" .. detail) or ""
end

--- Compiles `target/release/jpr-review` inside `plugin_root` without changing
--- Neovim's global working directory, yielding progress when inside a coroutine.
function M.build_release_binary(plugin_root, options)
    local root_directory = (type(plugin_root) == "string" and plugin_root ~= "")
        and plugin_root
        or binary.plugin_root()
    local active_options = type(options) == "table" and options or {}
    local cargo_path = M.find_cargo_executable(active_options.env, active_options.home_dir)
    if not cargo_path then
        error(
            "jpr-nvim: cargo executable not found. Install a Rust toolchain from https://rustup.rs and run :Lazy build jpr-nvim",
            0
        )
    end
    local running_thread, is_main_thread = coroutine.running()
    if running_thread ~= nil and not is_main_thread then
        coroutine.yield("Building jpr-review (cargo build --release)...")
    end
    local cargo_env = build_cargo_env_from_executable(cargo_path, active_options.env)
    local command = { cargo_path, "build", "--release", "-p", "jpr-review" }
    local result = vim.system(command, { cwd = root_directory, env = cargo_env, text = true }):wait()
    if result.code ~= 0 then
        error(
            ("jpr-nvim: cargo build --release -p jpr-review failed (exit %s); check your Rust toolchain (https://rustup.rs) and run :Lazy build jpr-nvim%s"):format(
                tostring(result.code),
                format_build_output_suffix(result)
            ),
            0
        )
    end
    local expected_binary = binary.default_binary_path(root_directory)
    if vim.fn.executable(expected_binary) ~= 1 then
        error(
            ("jpr-nvim: cargo build finished without producing an executable at %s; run :Lazy build jpr-nvim%s"):format(
                expected_binary,
                format_build_output_suffix(result)
            ),
            0
        )
    end
    return expected_binary
end

return M
