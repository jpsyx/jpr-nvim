-- Unified single-flight GitHub CLI (`gh`) authentication recovery wrapper.
-- Intercepts CLI exit code 3, RPC -32001, and auth-required syncFailed events.
local modal = require("jpr.auth.modal")
local terminal = require("jpr.auth.terminal")

local M = {}

--- Exit code emitted by `jpr-review` when `gh` authentication is missing.
M.AUTH_EXIT_CODE = 3

--- JSON-RPC error code emitted by `jpr-review serve` when `gh` authentication is missing.
M.RPC_AUTH_REQUIRED = -32001

local RETRY_DETAIL = "GitHub authentication did not complete. Select Authenticate to try again or Cancel."

local active_modal = nil
local active_terminal = nil
local is_verifying = false
local is_background_suppressed = false
local has_failed_attempt = false
local origin_win = nil
local pending_queue = {}

local function jpr()
    return require("jpr")
end

--- Whether a `vim.system` result represents a `jpr-review` GitHub auth failure.
function M.is_cli_auth_error(result)
    return type(result) == "table" and result.code == M.AUTH_EXIT_CODE
end

--- Whether a JSON-RPC error object represents a GitHub authentication failure.
function M.is_rpc_auth_error(rpc_error)
    return type(rpc_error) == "table" and rpc_error.code == M.RPC_AUTH_REQUIRED
end

--- Whether an auth prompt modal, login terminal, or status verification is active.
function M.is_active()
    return active_modal ~= nil or active_terminal ~= nil or is_verifying
end

local function restore_origin_window()
    local target = origin_win
    origin_win = nil
    if target and vim.api.nvim_win_is_valid(target) then
        if vim.api.nvim_win_get_tabpage(target) == vim.api.nvim_get_current_tabpage() then
            pcall(vim.api.nvim_set_current_win, target)
        end
    end
end

local function enqueue_caller(entry)
    if type(entry.key) == "string" and entry.key ~= "" then
        for index, existing in ipairs(pending_queue) do
            if existing.key == entry.key then
                pending_queue[index] = entry
                return
            end
        end
    end
    pending_queue[#pending_queue + 1] = entry
end

local function drain_queue(is_authenticated, cancel_reason)
    local queued = pending_queue
    pending_queue = {}
    has_failed_attempt = false
    restore_origin_window()
    for _, entry in ipairs(queued) do
        if is_authenticated then
            if type(entry.on_authenticated) == "function" then
                entry.on_authenticated()
            end
        elseif type(entry.on_cancel) == "function" then
            entry.on_cancel(cancel_reason)
        end
    end
end

local show_prompt

local function verify_gh_auth_status()
    is_verifying = true
    local is_started = pcall(
        vim.system,
        { "gh", "auth", "status" },
        { text = true, timeout = 5000 },
        vim.schedule_wrap(function(result)
            if not is_verifying then
                return
            end
            is_verifying = false
            if type(result) == "table" and result.code == 0 then
                is_background_suppressed = false
                jpr().info("GitHub authentication complete; continuing...")
                drain_queue(true, nil)
                return
            end
            has_failed_attempt = true
            show_prompt(RETRY_DETAIL)
        end)
    )
    if not is_started then
        is_verifying = false
        has_failed_attempt = true
        show_prompt(RETRY_DETAIL)
    end
end

local function start_login_terminal()
    local state, start_error = terminal.open(function()
        active_terminal = nil
        verify_gh_auth_status()
    end)
    if not state then
        jpr().error(start_error or "could not start `gh auth login`")
        has_failed_attempt = true
        show_prompt(RETRY_DETAIL)
        return
    end
    active_terminal = state
end

show_prompt = function(detail_message)
    require("jpr.tui.wizard").close()
    active_modal = modal.open(detail_message, {
        on_authenticate = function()
            active_modal = nil
            start_login_terminal()
        end,
        on_cancel = function()
            active_modal = nil
            is_background_suppressed = true
            local reason = has_failed_attempt and "incomplete" or "declined"
            drain_queue(false, reason)
        end,
    })
end

--- Prompts the user to authenticate with `gh auth login` (deduplicated across
--- overlapping callers) and invokes `opts.on_authenticated()` once `gh auth status`
--- succeeds, or `opts.on_cancel(reason)` when declined, incomplete, or missing `gh`.
function M.prompt_and_resume(opts)
    local options = opts or {}
    if vim.fn.executable("gh") ~= 1 then
        jpr().error("gh (GitHub CLI) is required on PATH; install it from https://cli.github.com")
        if type(options.on_cancel) == "function" then
            options.on_cancel("missing_gh")
        end
        return
    end
    if options.is_background == true and is_background_suppressed then
        if type(options.on_cancel) == "function" then
            options.on_cancel("declined")
        end
        return
    end
    if options.is_background ~= true then
        is_background_suppressed = false
    end
    enqueue_caller({
        key = options.key,
        on_authenticated = options.on_authenticated,
        on_cancel = options.on_cancel,
    })
    if M.is_active() then
        return
    end
    local current_win = vim.api.nvim_get_current_win()
    origin_win = vim.api.nvim_win_is_valid(current_win) and current_win or nil
    show_prompt(options.detail)
end

--- Resets active auth modals, terminals, queued callbacks, and suppression flags (for tests).
function M.reset()
    is_verifying = false
    is_background_suppressed = false
    has_failed_attempt = false
    origin_win = nil
    pending_queue = {}
    if active_modal then
        local current_modal = active_modal
        active_modal = nil
        modal.close(current_modal)
    end
    if active_terminal then
        local current_terminal = active_terminal
        active_terminal = nil
        terminal.close(current_terminal)
    end
end

return M
