-- Centered, scrollable keyboard shortcuts cheatsheet modal (`:Jpr keys` and `?`).
local mouse = require("jpr.mouse")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-cheatsheet")
local DISABLED_LABEL = "(disabled)"
local TITLE_TEXT = " Jpr · Keyboard Shortcuts "
local FOOTER_TEXT = " [j/k] scroll  [q/Esc/?] close "

local active_state = nil

local function create_key_entry_from_binding(configured_key, description)
    local is_enabled = type(configured_key) == "string" and configured_key ~= ""
    return {
        key = is_enabled and configured_key or DISABLED_LABEL,
        desc = description,
        is_disabled = not is_enabled,
    }
end

local function create_diff_section_from_keys(keys)
    local configured = type(keys) == "table" and keys or {}
    return {
        title = "Diff & Stream Views",
        entries = {
            create_key_entry_from_binding(configured.comment, "New draft comment (Normal / Visual)"),
            create_key_entry_from_binding(configured.suggest_comment, "New code suggestion comment (Normal / Visual)"),
            create_key_entry_from_binding(configured.file_comment, "New file-level comment"),
            create_key_entry_from_binding(configured.full_diff, "Return to full branch diff view"),
            create_key_entry_from_binding(configured.toggle_viewed, "Toggle viewed for current file"),
            create_key_entry_from_binding(configured.thread_popup, "Open review thread popup"),
            create_key_entry_from_binding(configured.next_thread, "Next review thread"),
            create_key_entry_from_binding(configured.prev_thread, "Previous review thread"),
            { key = "<CR>", desc = "Open real file at cursor (stream)" },
            { key = "<2-LeftMouse>", desc = "Open real file or toggle closed fold (stream)" },
            { key = "v", desc = "Toggle viewed and jump to next unviewed (stream)" },
            { key = "]f / [f", desc = "Next / previous file (stream)" },
            { key = "]h / [h", desc = "Next / previous hunk (stream)" },
            { key = "?", desc = "Show keyboard shortcuts (stream)" },
        },
    }
end

local function create_comments_section()
    return {
        title = "Comments, Threads & Submit",
        entries = {
            { heading = "Compose" },
            { key = "<C-s>", desc = "Save comment (Normal / Insert)" },
            { key = "<C-g>", desc = "Flip destination: GitHub / local agent (Normal / Insert)" },
            { key = "<M-s>", desc = "Save comment to other destination (Normal / Insert)" },
            { key = "<C-g>s", desc = "Insert GitHub suggestion block (Insert)" },
            { key = "@ / <C-x><C-o>", desc = "Complete @mention (Insert)" },
            { key = "q / <Esc>", desc = "Cancel comment (Normal)" },
            { heading = "Thread Popup" },
            { key = "r", desc = "Reply to thread" },
            { key = "e / d", desc = "Edit / delete comment" },
            { key = "R", desc = "Resolve or unresolve thread" },
            { key = "+", desc = "Toggle GitHub reaction" },
            { key = "p / s", desc = "Promote local thread to GitHub / send to agent" },
            { key = "X", desc = "Retry failed comment" },
            { key = "q / <Esc>", desc = "Close thread popup" },
            { heading = "PR Conversation" },
            { key = "c", desc = "Add PR conversation comment" },
            { key = "r / e / d", desc = "Reply (local) / edit / delete comment" },
            { key = "p / s", desc = "Promote local thread to GitHub / send to agent" },
            { key = "+ / X", desc = "Toggle GitHub reaction / retry failed comment" },
            { key = "q / ?", desc = "Close conversation / show keyboard shortcuts" },
            { heading = "Submit Review Modal" },
            { key = "1 / 2 / 3", desc = "Select Comment / Approve / Request changes" },
            { key = "e", desc = "Edit review summary (<C-s> save, q/<Esc> cancel)" },
            { key = "<CR>", desc = "Jump to draft under cursor or submit review" },
            { key = "<C-s>", desc = "Submit review" },
            { key = "q / <Esc>", desc = "Close submit modal" },
        },
    }
end

local function create_session_and_agent_section_from_keys(keys)
    local configured = type(keys) == "table" and keys or {}
    return {
        title = "Review Session & Agent",
        entries = {
            create_key_entry_from_binding(configured.send_agent, "Send local threads to agent (confirms)"),
            create_key_entry_from_binding(configured.submit_review, "Submit GitHub review (confirms)"),
            create_key_entry_from_binding(configured.toggle_agent, "Toggle coding agent panel (hides without quitting)"),
            create_key_entry_from_binding(configured.toggle_panel, "Toggle or reopen diff sidebar panel"),
            { key = ":q / <C-q> / <M-q>", desc = "Hide agent terminal window without quitting" },
        },
    }
end

local function create_sections_from_config(config)
    local current_config = type(config) == "table" and config or {}
    return {
        {
            title = "PR Sidebar Panel",
            entries = {
                { key = "j / k", desc = "Move selection up / down" },
                { key = "h / <Left>", desc = "Collapse directory or jump to parent" },
                { key = "l / <Right>", desc = "Expand directory or step into first child" },
                { key = "<CR> / o", desc = "Open file or PR conversation (<CR> toggles dir)" },
                { key = "<LeftMouse>", desc = "Click file/conversation to open, or dir to toggle" },
                { key = "r", desc = "Rename or move file / directory" },
                { key = "a", desc = "Create file or directory" },
                { key = "v", desc = "Toggle file or directory viewed" },
                { key = "?", desc = "Show keyboard shortcuts" },
            },
        },
        create_diff_section_from_keys(current_config.keys),
        create_comments_section(),
        create_session_and_agent_section_from_keys(current_config.keys),
        {
            title = "Command Palette & Steppers",
            entries = {
                create_key_entry_from_binding(current_config.keys and current_config.keys.palette, "Open command palette (bare :Jpr)"),
                { key = ":Jpr", desc = "Open command palette" },
                { key = ":Jpr local [base]", desc = "Review current worktree (alias: :Jpr self)" },
                { key = ":Jpr keys", desc = "Show keyboard shortcuts" },
                { key = "Type (palette)", desc = "Fuzzy-filter commands by label or [id]" },
                { key = "<C-j> / <C-k>", desc = "Move palette selection down / up (Insert or Normal)" },
                { key = "<C-u>", desc = "Clear entire palette filter input" },
                { key = "j/k/<Down>/<Up>", desc = "Move selection (Normal / steppers)" },
                { key = "l/<Right>/<Tab>/<CR>", desc = "Confirm / next step" },
                { key = "h/<Left>/<S-Tab>", desc = "Back" },
                { key = "gg / G", desc = "First / last item (<Home> / <End>)" },
                { key = "<LeftMouse>", desc = "Click command, option, or footer hint (click outside to close)" },
                { key = "q / <Esc>", desc = "Close (<Esc> drops to Normal first in palette/text)" },
            },
        },
    }
end

local function measure_key_column_width(sections)
    local max_key_width = 18
    for _, section in ipairs(sections) do
        for _, entry in ipairs(section.entries) do
            if type(entry.key) == "string" then
                max_key_width = math.max(max_key_width, vim.fn.strdisplaywidth(entry.key))
            end
        end
    end
    return max_key_width
end

local function append_line(layout, text, col_start, col_end, group)
    layout.lines[#layout.lines + 1] = text
    layout.width = math.max(layout.width, vim.fn.strdisplaywidth(text))
    if group and col_end > col_start then
        layout.highlights[#layout.highlights + 1] = {
            line = #layout.lines - 1,
            col_start = col_start,
            col_end = col_end,
            group = group,
        }
    end
end

local function append_section(layout, section, key_column_width)
    append_line(layout, section.title, 0, #section.title, "JprTitle")
    local has_subheadings = false
    for _, entry in ipairs(section.entries) do
        if entry.heading then
            has_subheadings = true
            local heading_line = "  " .. entry.heading
            append_line(layout, heading_line, 2, #heading_line, "JprAuthor")
        else
            local indent = has_subheadings and "    " or "  "
            local key_width = vim.fn.strdisplaywidth(entry.key)
            local padding = string.rep(" ", math.max(0, key_column_width - key_width))
            local row_text = indent .. entry.key .. padding .. "  " .. entry.desc
            local highlight_group = entry.is_disabled and "JprMuted" or "JprHunk"
            append_line(layout, row_text, #indent, #indent + #entry.key, highlight_group)
        end
    end
end

--- Creates the pure cheatsheet layout lines, highlight spans, and content width
--- from `config` (reading dynamic shortcuts from `config.keys`) for `:Jpr keys`
--- and `?`.
--- @param config table|nil
--- @return table { lines: string[], highlights: table[], width: integer }
function M.create_layout_from_config(config)
    local sections = create_sections_from_config(config)
    local key_column_width = measure_key_column_width(sections)
    local layout = { lines = {}, highlights = {}, width = 0 }
    for section_index, section in ipairs(sections) do
        if section_index > 1 then
            append_line(layout, "", 0, 0, nil)
        end
        append_section(layout, section, key_column_width)
    end
    return layout
end

local function create_window_geometry(layout)
    local max_width = math.max(20, vim.o.columns - 4)
    local width = math.min(math.max(48, layout.width + 2), max_width)
    local max_height = math.max(1, vim.o.lines - 4)
    local height = math.min(math.max(1, #layout.lines), max_height)
    local centered_row = math.floor((vim.o.lines - height) / 2) - 1
    local max_row = math.max(0, vim.o.lines - height - 2)
    return {
        relative = "editor",
        row = math.max(0, math.min(centered_row, max_row)),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        width = width,
        height = height,
    }
end

local function create_window_config(layout)
    local config = create_window_geometry(layout)
    config.style = "minimal"
    config.border = "rounded"
    config.title = TITLE_TEXT
    config.title_pos = "center"
    if vim.fn.has("nvim-0.10") == 1 then
        config.footer = FOOTER_TEXT
        config.footer_pos = "center"
    end
    return config
end

local function apply_layout_to_buffer(buf, layout)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, layout.lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    for _, highlight in ipairs(layout.highlights) do
        vim.api.nvim_buf_set_extmark(buf, namespace, highlight.line, highlight.col_start, {
            end_col = highlight.col_end,
            hl_group = highlight.group,
            strict = false,
        })
    end
end

local function handle_cheatsheet_click()
    local click = mouse.get_click()
    if not click then
        return
    end
    if not active_state or not mouse.is_click_in_window(click, active_state.win) then
        return M.close()
    end
    mouse.set_cursor_from_click(active_state.win, click)
end

local function bind_cheatsheet_keys(buf)
    local map_opts = { buffer = buf, nowait = true, silent = true, desc = "Close Jpr keyboard shortcuts" }
    for _, lhs in ipairs({ "q", "<Esc>", "?" }) do
        vim.keymap.set("n", lhs, M.close, map_opts)
    end
    vim.keymap.set("n", "<LeftMouse>", handle_cheatsheet_click, {
        buffer = buf,
        nowait = true,
        silent = true,
        desc = "Place cursor inside cheatsheet or click outside to close",
    })
end

local function register_cleanup_guards(state)
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = state.buf,
        once = true,
        callback = function()
            if active_state == state then
                active_state = nil
            end
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(state.win),
        once = true,
        callback = function()
            if active_state == state then
                active_state = nil
            end
        end,
    })
end

--- Returns whether the floating keyboard shortcuts cheatsheet is currently open.
--- @return boolean
function M.is_open()
    return active_state ~= nil
        and active_state.win ~= nil
        and active_state.buf ~= nil
        and vim.api.nvim_win_is_valid(active_state.win)
        and vim.api.nvim_buf_is_valid(active_state.buf)
end

--- Closes the floating keyboard shortcuts cheatsheet if it is open.
function M.close()
    local state = active_state
    active_state = nil
    if not state then
        return
    end
    if state.win and vim.api.nvim_win_is_valid(state.win) then
        pcall(vim.api.nvim_win_close, state.win, true)
    end
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
    end
end

--- Opens the centered floating keyboard shortcuts cheatsheet, or refreshes and
--- focuses the existing modal when already open. Invoked by `:Jpr keys`, the
--- Command Palette, and `?` in read-only Jpr UI buffers.
function M.open()
    local jpr = require("jpr")
    jpr.define_highlights()
    local layout = M.create_layout_from_config(jpr.config)

    if M.is_open() then
        apply_layout_to_buffer(active_state.buf, layout)
        pcall(vim.api.nvim_win_set_config, active_state.win, create_window_geometry(layout))
        pcall(vim.api.nvim_set_current_win, active_state.win)
        return
    end

    M.close()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "jpr-cheatsheet"
    apply_layout_to_buffer(buf, layout)

    local is_opened, window_or_error = pcall(vim.api.nvim_open_win, buf, true, create_window_config(layout))
    if not is_opened then
        if vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
        error(window_or_error)
    end

    vim.api.nvim_set_option_value("wrap", true, { win = window_or_error, scope = "local" })
    local state = { buf = buf, win = window_or_error }
    active_state = state
    register_cleanup_guards(state)
    bind_cheatsheet_keys(buf)
end

return M
