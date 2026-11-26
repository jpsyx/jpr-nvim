-- Specs for `:Jpr keys`, `jpr.views.cheatsheet`, and buffer-local `?` bindings.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")

local jpr = require("jpr")
local cheatsheet = require("jpr.views.cheatsheet")
local session = require("jpr.session")
local stream_view = require("jpr.views.stream")
local conversation_view = require("jpr.views.conversation")
local view_mode = require("jpr.view_mode")

local function join_layout_lines(layout)
    return table.concat(layout.lines, "\n")
end

local function find_highlight(layout, line_index, needle, expected_group)
    local line = layout.lines[line_index + 1] or ""
    local match_start = line:find(needle, 1, true)
    if not match_start then
        return false
    end
    local col_start = match_start - 1
    local col_end = col_start + #needle
    for _, highlight in ipairs(layout.highlights) do
        if
            highlight.line == line_index
            and highlight.col_start == col_start
            and highlight.col_end == col_end
            and highlight.group == expected_group
        then
            return true
        end
    end
    return false
end

local function find_line_index(lines, needle)
    for index, line in ipairs(lines) do
        if line:find(needle, 1, true) ~= nil then
            return index - 1
        end
    end
    return nil
end

local function count_cheatsheet_windows()
    local window_count = 0
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "jpr-cheatsheet" then
            window_count = window_count + 1
        end
    end
    return window_count
end

local function press_normal_key(lhs)
    local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    vim.api.nvim_feedkeys(keys, "xt", false)
end

local function buffer_has_normal_map(buf, lhs)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if mapping.lhs == lhs then
            return mapping
        end
    end
    return nil
end

local EXPECTED_DEFAULT_ITEMS = {
    "PR Sidebar Panel",
    "j / k",
    "h / <Left>",
    "l / <Right>",
    "<CR> / o",
    "Rename or move file / directory",
    "Create file or directory",
    "Toggle file viewed",
    "Show keyboard shortcuts",
    "Diff & Stream Views",
    "gc",
    "gC",
    "gf",
    "gt",
    "]t",
    "[t",
    "]f / [f",
    "]h / [h",
    "Comments, Threads & Submit",
    "<C-s>",
    "<C-g>",
    "<M-s>",
    "<C-g>s",
    "@ / <C-x><C-o>",
    "Resolve or unresolve thread",
    "1 / 2 / 3",
    "Review Session & Agent",
    "gS",
    "gs",
    "ga",
    "Hide agent terminal window without quitting",
    "Command Palette & Steppers",
    "<C-j> / <C-k>",
    "<C-u>",
    "<leader>J",
    ":Jpr",
    ":Jpr keys",
    "j/k/<Down>/<Up>",
    "l/<Right>/<Tab>/<CR>",
    "h/<Left>/<S-Tab>",
    "gg / G",
}

local function test_default_layout_contains_all_sections_and_real_keybindings()
    local layout = cheatsheet.create_layout_from_config(jpr.defaults)
    assert(type(layout) == "table" and type(layout.lines) == "table" and type(layout.highlights) == "table", "returns layout table")
    assert(type(layout.width) == "number" and layout.width > 0, "returns positive width")

    local text = join_layout_lines(layout)
    assert(not text:find("\226\128\148", 1, true), "cheatsheet must not contain em dashes")
    for _, expected in ipairs(EXPECTED_DEFAULT_ITEMS) do
        assert(text:find(expected, 1, true) ~= nil, "default layout missing: " .. expected)
    end

    local panel_header_line = find_line_index(layout.lines, "PR Sidebar Panel")
    assert(panel_header_line ~= nil and find_highlight(layout, panel_header_line, "PR Sidebar Panel", "JprTitle"), "section header uses JprTitle")

    local comment_line = find_line_index(layout.lines, "New draft comment")
    assert(comment_line ~= nil and find_highlight(layout, comment_line, "gc", "JprHunk"), "active key uses JprHunk")
end

local function test_custom_and_disabled_keys_render_dynamically()
    local custom_config = {
        keys = {
            comment = "<leader>c",
            suggest_comment = "gS",
            file_comment = false,
            thread_popup = nil,
            next_thread = "]n",
            prev_thread = "[n",
            send_agent = "<leader>s",
            submit_review = false,
            toggle_agent = "gA",
        },
    }
    local layout = cheatsheet.create_layout_from_config(custom_config)
    local text = join_layout_lines(layout)

    assert(text:find("<leader>c", 1, true) ~= nil, "custom comment key rendered")
    assert(text:find("gS", 1, true) ~= nil, "custom suggest_comment key rendered")
    assert(text:find("]n", 1, true) ~= nil, "custom next_thread key rendered")
    assert(text:find("[n", 1, true) ~= nil, "custom prev_thread key rendered")
    assert(text:find("<leader>s", 1, true) ~= nil, "custom send_agent key rendered")
    assert(text:find("gA", 1, true) ~= nil, "custom toggle_agent key rendered")
    local submit_line = find_line_index(layout.lines, "Submit GitHub review")
    assert(submit_line ~= nil and layout.lines[submit_line + 1]:find("(disabled)", 1, true) ~= nil, "disabled submit_review renders (disabled)")
    assert(find_highlight(layout, submit_line, "(disabled)", "JprMuted"), "disabled submit_review uses JprMuted")

    local comment_line = find_line_index(layout.lines, "New draft comment")
    assert(comment_line ~= nil and find_highlight(layout, comment_line, "<leader>c", "JprHunk"), "custom key uses JprHunk")

    local file_comment_line = find_line_index(layout.lines, "New file-level comment")
    assert(file_comment_line ~= nil and layout.lines[file_comment_line + 1]:find("(disabled)", 1, true) ~= nil, "false key renders (disabled)")
    assert(find_highlight(layout, file_comment_line, "(disabled)", "JprMuted"), "false disabled key uses JprMuted")

    local popup_line = find_line_index(layout.lines, "Open review thread popup")
    assert(popup_line ~= nil and layout.lines[popup_line + 1]:find("(disabled)", 1, true) ~= nil, "nil key renders (disabled)")
    assert(find_highlight(layout, popup_line, "(disabled)", "JprMuted"), "nil disabled key uses JprMuted")
end

local function test_open_idempotency_window_properties_and_close_keys()
    jpr.setup({})
    assert(cheatsheet.is_open() == false, "closed initially")

    cheatsheet.open()
    assert(cheatsheet.is_open() == true, "open() sets is_open() to true")
    assert(count_cheatsheet_windows() == 1, "opens exactly one cheatsheet window")

    local first_win = vim.api.nvim_get_current_win()
    local first_buf = vim.api.nvim_win_get_buf(first_win)
    local win_config = vim.api.nvim_win_get_config(first_win)
    assert(win_config.relative == "editor", "cheatsheet floats relative to editor")
    assert(vim.bo[first_buf].filetype == "jpr-cheatsheet", "filetype is jpr-cheatsheet")
    assert(vim.bo[first_buf].modifiable == false, "buffer is non-modifiable")
    assert(vim.bo[first_buf].bufhidden == "wipe", "bufhidden is wipe")

    local title_text = type(win_config.title) == "table" and win_config.title[1][1] or tostring(win_config.title or "")
    assert(title_text:find("Jpr · Keyboard Shortcuts", 1, true) ~= nil, "window title set: " .. title_text)
    if vim.fn.has("nvim-0.10") == 1 then
        local footer_text = type(win_config.footer) == "table" and win_config.footer[1][1] or tostring(win_config.footer or "")
        assert(footer_text:find("[j/k] scroll", 1, true) ~= nil, "window footer set: " .. footer_text)
    end

    -- Calling open() again after changing config refreshes the existing modal without duplicating windows.
    jpr.setup({ keys = { comment = "<leader>k" } })
    cheatsheet.open()
    assert(cheatsheet.is_open() == true, "second open() keeps modal open")
    assert(count_cheatsheet_windows() == 1, "second open() does not create duplicate window")
    assert(vim.api.nvim_get_current_win() == first_win, "second open() focuses existing window")
    local refreshed_text = table.concat(vim.api.nvim_buf_get_lines(first_buf, 0, -1, false), "\n")
    assert(refreshed_text:find("<leader>k", 1, true) ~= nil, "second open() refreshes buffer with updated config")
    jpr.setup({})

    for _, close_key in ipairs({ "q", "<Esc>", "?" }) do
        cheatsheet.open()
        assert(cheatsheet.is_open() == true, "opened before closing with " .. close_key)
        press_normal_key(close_key)
        assert(cheatsheet.is_open() == false, close_key .. " closes cheatsheet")
        assert(count_cheatsheet_windows() == 0, "no cheatsheet windows remain after " .. close_key)
    end
end

local function test_palette_launches_keyboard_shortcuts_command()
    local helpers = dofile(root .. "/tests/lua/support/helpers.lua")
    local wizard = require("jpr.tui.wizard")
    jpr.command({})
    assert(wizard.is_open() == true, "bare :Jpr opens palette")
    press_normal_key("G")
    local palette_text = helpers.palette_results_text()
    assert(palette_text:find("▸ Keyboard Shortcuts  [keys]", 1, true) ~= nil, "keys command highlighted in palette: " .. palette_text)
    assert(palette_text:find("Show all keyboard shortcuts", 1, true) ~= nil, "keys hover help visible")
    press_normal_key("<CR>")
    assert(wizard.is_open() == false, "palette closes on confirm")
    assert(cheatsheet.is_open() == true, "confirming keys in palette opens cheatsheet")
    cheatsheet.close()
end

local function test_jpr_keys_command_opens_cheatsheet_without_session_and_rejects_extra_args()
    assert(session.current() == nil, "no active session before :Jpr keys")
    jpr.command({ "keys" })
    assert(cheatsheet.is_open() == true, ":Jpr keys opens cheatsheet without an active session")
    cheatsheet.close()
    assert(cheatsheet.is_open() == false, "cheatsheet closes after :Jpr keys")

    local recorded_errors = {}
    local original_error = jpr.error
    jpr.error = function(message)
        recorded_errors[#recorded_errors + 1] = message
    end
    jpr.command({ "keys", "extra" })
    jpr.error = original_error
    assert(cheatsheet.is_open() == false, ":Jpr keys extra does not open cheatsheet")
    assert(
        #recorded_errors == 1 and recorded_errors[1] == ":Jpr keys does not accept arguments",
        "expected exact error message, got: " .. vim.inspect(recorded_errors)
    )
end

local function assert_buffer_question_mark_opens_cheatsheet(buf, win, label)
    local mapping = buffer_has_normal_map(buf, "?")
    assert(mapping ~= nil and mapping.desc == "Show Jpr keyboard shortcuts", label .. " maps ?")
    vim.api.nvim_set_current_win(win)
    press_normal_key("?")
    assert(cheatsheet.is_open() == true, "? in " .. label .. " opens cheatsheet")
    press_normal_key("?")
    assert(cheatsheet.is_open() == false, "? in cheatsheet closes it after " .. label)
end

local function test_question_mark_opens_cheatsheet_in_ui_buffers_only()
    local source_buf = vim.api.nvim_create_buf(false, true)
    jpr.bind_buffer_keys(source_buf)
    assert(buffer_has_normal_map(source_buf, "?") == nil, "editable source buffers must not override ?")
    vim.api.nvim_buf_delete(source_buf, { force = true })

    view_mode.path = vim.fn.tempname()
    vim.env.FAKE_ENGINE_LOG = vim.fn.tempname()
    jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })
    local worktree = vim.fn.tempname()
    vim.fn.mkdir(worktree, "p")
    vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")

    session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
    local review = session.current()
    assert(vim.wait(3000, function()
        return review.panel ~= nil and review.stream ~= nil and review.stream.layout ~= nil and stream_view.is_visible(review)
    end), "review session starts with panel and stream")

    assert_buffer_question_mark_opens_cheatsheet(review.panel.buf, review.panel.win, "panel")

    local stream_buf = review.stream.buffers.main
    assert_buffer_question_mark_opens_cheatsheet(stream_buf, vim.fn.win_findbuf(stream_buf)[1], "stream")

    conversation_view.show(review)
    local conversation_buf = review.conversation.buf
    assert_buffer_question_mark_opens_cheatsheet(conversation_buf, vim.fn.win_findbuf(conversation_buf)[1], "conversation")

    session.close_current()
    jpr.setup({})
end

test_default_layout_contains_all_sections_and_real_keybindings()
test_custom_and_disabled_keys_render_dynamically()
test_open_idempotency_window_properties_and_close_keys()
test_palette_launches_keyboard_shortcuts_command()
test_jpr_keys_command_opens_cheatsheet_without_session_and_rejects_extra_args()
test_question_mark_opens_cheatsheet_in_ui_buffers_only()

print("cheatsheet_spec: ok")
