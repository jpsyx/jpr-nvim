-- `:checkhealth jpr` diagnostics for Neovim version, bundled engine binary, and external tools.
local crash = require("jpr.session.crash")

local M = {}

local function check_neovim_version()
    if vim.fn.has("nvim-0.11") == 1 then
        local version = vim.version()
        vim.health.ok(("Neovim %d.%d.%d"):format(version.major, version.minor, version.patch))
        return
    end
    vim.health.error("Neovim >= 0.11 is required")
end

local function parse_version_from_stdout(stdout)
    local trimmed = vim.trim(stdout or "")
    if trimmed == "" then
        return nil
    end
    return trimmed:match("^jpr%-review%s+(%S+)") or trimmed:match("(%S+)$")
end

local function check_engine_binary()
    local jpr = require("jpr")
    local binary_path = jpr.binary_path()
    local clean_binary_path = crash.build_clean_text_from_raw(binary_path)
    if vim.fn.executable(binary_path) ~= 1 then
        vim.health.error(("jpr-review binary not found at %s; run :Lazy build jpr-nvim"):format(clean_binary_path))
        return
    end
    local is_spawned, system_handle = pcall(vim.system, { binary_path, "--version" }, { text = true, timeout = 3000 })
    local result = is_spawned and system_handle:wait() or nil
    local raw_version = (result and result.code == 0) and parse_version_from_stdout(result.stdout) or nil
    local engine_version = raw_version and crash.build_clean_text_from_raw(raw_version) or ""
    if engine_version == "" then
        vim.health.error(("failed to query %s --version; run :Lazy build jpr-nvim"):format(clean_binary_path))
        return
    end
    if engine_version ~= jpr.VERSION then
        vim.health.error(
            ("version mismatch: plugin is %s and %s is %s; run :Lazy build jpr-nvim"):format(
                jpr.VERSION,
                clean_binary_path,
                engine_version
            )
        )
        return
    end
    vim.health.ok(("jpr-review %s (%s)"):format(engine_version, clean_binary_path))
end

local function check_external_tools()
    if vim.fn.executable("git") == 1 then
        vim.health.ok("git found: " .. vim.fn.exepath("git"))
    else
        vim.health.error("git is required on PATH")
    end
    if vim.fn.executable("gh") ~= 1 then
        vim.health.error("gh (GitHub CLI) is required on PATH")
    else
        vim.health.ok("gh found: " .. vim.fn.exepath("gh"))
        local is_auth_spawned, auth_handle = pcall(vim.system, { "gh", "auth", "status" }, { text = true, timeout = 3000 })
        local auth_result = is_auth_spawned and auth_handle:wait() or nil
        if auth_result and auth_result.code == 0 then
            vim.health.ok("gh is authenticated")
        else
            vim.health.warn("gh auth status failed; run `gh auth login` before opening pull requests")
        end
    end
    local cargo_path = require("jpr.build").find_cargo_executable()
    if cargo_path then
        vim.health.ok("cargo found: " .. cargo_path)
    else
        vim.health.warn("cargo not found; install Rust from https://rustup.rs before running :Lazy build jpr-nvim")
    end
end

--- Runs `:checkhealth jpr` checks and reports status through `vim.health`.
function M.check()
    vim.health.start("jpr")
    check_neovim_version()
    check_engine_binary()
    check_external_tools()
end

return M
