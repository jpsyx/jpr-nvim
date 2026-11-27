-- Global, review-session, and tab-aware keymap binding helpers for `jpr`.
local M = {}

local bound_palette_key = "<leader>J"

local function bind_plug_key(buf, modes, lhs, plug, desc)
    if type(lhs) == "string" and lhs ~= "" then
        vim.keymap.set(
            modes,
            lhs,
            plug,
            { buffer = buf, remap = true, silent = true, nowait = true, desc = desc }
        )
    end
end

local function bind_tab_aware_key(buf, key_lhs, plug_rhs, desc)
    if type(key_lhs) ~= "string" or key_lhs == "" then
        return
    end
    vim.keymap.set("n", key_lhs, function()
        local session_module = package.loaded["jpr.session"]
        if session_module and session_module.current() ~= nil then
            return plug_rhs
        end
        return key_lhs
    end, { buffer = buf, expr = true, remap = true, silent = true, nowait = true, desc = desc })
end

--- Binds the configured global `<Plug>(jpr-palette)` shortcut (default `<leader>J`),
--- removing any previous plugin-owned palette mapping when changed or disabled.
function M.bind_global_keys(config)
    if type(bound_palette_key) == "string" and bound_palette_key ~= "" then
        local existing = vim.fn.maparg(bound_palette_key, "n", false, true)
        if existing and existing.rhs == "<Plug>(jpr-palette)" then
            pcall(vim.keymap.del, "n", bound_palette_key)
        end
    end
    bound_palette_key = nil
    local palette_key = config.keys and config.keys.palette
    if type(palette_key) == "string" and palette_key ~= "" then
        vim.keymap.set("n", palette_key, "<Plug>(jpr-palette)", {
            remap = true,
            silent = true,
            desc = "Open Jpr command palette",
        })
        bound_palette_key = palette_key
    end
end

--- Binds review-wide session keys (`comment`, `pr_comment`, `send_agent`,
--- `submit_review`, `toggle_agent`, `toggle_panel`) on `buf`, skipping any
--- entry set to `false` or empty.
function M.bind_session_keys(config, buf)
    local keys = config.keys or {}
    bind_plug_key(buf, "n", keys.comment, "<Plug>(jpr-comment)", "New comment for the current view")
    bind_plug_key(buf, "n", keys.pr_comment, "<Plug>(jpr-pr-comment)", "New standalone PR comment")
    bind_plug_key(buf, "n", keys.send_agent, "<Plug>(jpr-send-agent)", "Send local threads to coding agent")
    bind_plug_key(buf, "n", keys.submit_review, "<Plug>(jpr-submit-review)", "Open GitHub review submission modal")
    bind_plug_key(buf, "n", keys.toggle_agent, "<Plug>(jpr-toggle-agent)", "Toggle coding agent terminal panel")
    bind_plug_key(buf, "n", keys.toggle_panel, "<Plug>(jpr-toggle-panel)", "Toggle diff sidebar panel")
end

--- Binds configured comment, thread, and review session keys in buffer `buf`
--- to their `<Plug>(jpr-*)` mappings, skipping any entry set to `false`.
function M.bind_buffer_keys(config, buf)
    local keys = config.keys or {}
    bind_plug_key(buf, { "n", "x" }, keys.comment, "<Plug>(jpr-comment)", "New GitHub draft comment")
    bind_plug_key(buf, { "n", "x" }, keys.suggest_comment, "<Plug>(jpr-suggest-comment)", "New GitHub suggestion comment")
    bind_plug_key(buf, "n", keys.file_comment, "<Plug>(jpr-file-comment)", "New file-level GitHub comment")
    bind_plug_key(buf, "n", keys.full_diff, "<Plug>(jpr-full-diff)", "Switch to the full branch diff view")
    bind_plug_key(buf, "n", keys.toggle_viewed, "<Plug>(jpr-toggle-viewed)", "Toggle viewed for the current file")
    bind_plug_key(buf, "n", keys.thread_popup, "<Plug>(jpr-thread-popup)", "Open review thread popup")
    bind_plug_key(buf, "n", keys.next_thread, "<Plug>(jpr-next-thread)", "Next review thread")
    bind_plug_key(buf, "n", keys.prev_thread, "<Plug>(jpr-prev-thread)", "Previous review thread")
    M.bind_session_keys(config, buf)
end

--- Binds `keys.full_diff` on a non-changed worktree buffer `buf` with an expr guard.
function M.bind_tab_aware_full_diff_key(config, buf)
    bind_tab_aware_key(buf, config.keys and config.keys.full_diff, "<Plug>(jpr-full-diff)", "Switch to the full branch diff view")
end

--- Binds `keys.pr_comment` on a non-changed worktree buffer `buf` with an expr guard.
function M.bind_tab_aware_pr_comment_key(config, buf)
    bind_tab_aware_key(buf, config.keys and config.keys.pr_comment, "<Plug>(jpr-pr-comment)", "New standalone PR comment")
end

--- Binds `keys.toggle_panel` on a non-changed worktree buffer `buf` with an expr guard.
function M.bind_tab_aware_toggle_panel_key(config, buf)
    bind_tab_aware_key(buf, config.keys and config.keys.toggle_panel, "<Plug>(jpr-toggle-panel)", "Toggle diff sidebar panel")
end

return M
