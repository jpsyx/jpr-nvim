-- Specs for inline anchored rename (r) and create (a) input UI, live path hints,
-- validation errors, LSP file ops wiring, and refreshWorktree RPC integration.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local session = require("jpr.session")
local panel_view = require("jpr.views.panel")
local panel_input = require("jpr.views.panel_input")
local stream_view = require("jpr.views.stream")
local view_mode = require("jpr.view_mode")

view_mode.path = vim.fn.tempname()
local engine_log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = engine_log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh", lsp_attach_timeout_ms = 0 })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree .. "/src", "p")
vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")
vim.fn.writefile({ "export const a = 1;" }, worktree .. "/src/alpha.ts")

session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.panel ~= nil and review.stream ~= nil and review.stream.layout ~= nil and stream_view.is_visible(review)
end), "review session starts with panel and stream")

local panel_win = review.panel.win
local panel_input_ns = vim.api.nvim_create_namespace("jpr-panel-input")

local function build_tree_view(files, tree)
    return {
        pr = review.view.pr,
        files = files,
        tree = tree,
        viewedCount = 0,
        threadCount = 0,
        draftCount = 0,
        conversationCount = 1,
        sync = { state = "synced", at = 1 },
    }
end

local initial_view = build_tree_view({
    { path = "README.md", additions = 2, deletions = 1, viewed = "UNVIEWED", threads = 0 },
    { path = "src/alpha.ts", additions = 1, deletions = 0, viewed = "UNVIEWED", threads = 0 },
}, {
    { depth = 0, name = "src" },
    { depth = 1, name = "alpha.ts", file = 1 },
    { depth = 0, name = "README.md", file = 0 },
})
review.view = initial_view
panel_view.render(review, initial_view)

local function find_panel_input_window()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "jpr-panel-input" then
            return win, buf
        end
    end
    return nil, nil
end

local function read_virt_lines(buf)
    local marks = vim.api.nvim_buf_get_extmarks(buf, panel_input_ns, 0, -1, { details = true })
    local rendered = {}
    for _, mark in ipairs(marks) do
        local details = mark[4]
        if details and type(details.virt_lines) == "table" then
            for _, vline in ipairs(details.virt_lines) do
                local parts = {}
                local groups = {}
                for _, chunk in ipairs(vline) do
                    parts[#parts + 1] = chunk[1]
                    groups[#groups + 1] = chunk[2]
                end
                rendered[#rendered + 1] = { text = table.concat(parts, ""), groups = groups }
            end
        end
    end
    return rendered
end

local function press_panel_key(lhs, line)
    vim.api.nvim_set_current_win(panel_win)
    vim.api.nvim_win_set_cursor(panel_win, { line, 0 })
    local map = vim.fn.maparg(lhs, "n", false, true)
    assert(type(map) == "table" and type(map.callback) == "function", "panel must bind " .. lhs)
    map.callback()
end

local function set_input_text(buf, text)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
end

local function trigger_input_map(buf, mode, lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        if map.lhs == lhs and type(map.callback) == "function" then
            map.callback()
            return
        end
    end
    error(("missing %s map for %s on jpr-panel-input"):format(mode, lhs))
end

local function find_line_for_path(path)
    for line, row in pairs(review.panel.rows) do
        if row.path == path then
            return line
        end
    end
    return nil
end

-- 1. Pressing r on Conversation is a no-op (does not open float).
press_panel_key("r", review.panel.conversation_line)
assert(find_panel_input_window() == nil, "r on Conversation must not open float")

-- 2. Pressing r on a file row opens jpr-panel-input anchored directly below the row, prefilled with basename.
local alpha_line = find_line_for_path("src/alpha.ts")
assert(alpha_line ~= nil, "src/alpha.ts row present in panel")
press_panel_key("r", alpha_line)
local input_win, input_buf = find_panel_input_window()
assert(input_win ~= nil and input_buf ~= nil, "r on file opens jpr-panel-input float")
local win_cfg = vim.api.nvim_win_get_config(input_win)
assert(win_cfg.relative == "win", "float is relative to win: " .. tostring(win_cfg.relative))
assert(win_cfg.win == panel_win, "float anchors to panel.win")
local topline = vim.api.nvim_win_call(panel_win, function()
    return vim.fn.line("w0")
end)
assert(win_cfg.row == (alpha_line - topline) + 1, "float anchors directly below hovered row: " .. tostring(win_cfg.row))
assert(vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] == "alpha.ts", "rename input prefilled with basename")

-- 3. Typing "some/new/module.ts" updates virtual hint line immediately to include project root notice.
set_input_text(input_buf, "some/new/module.ts")
local root_hints = read_virt_lines(input_buf)
assert(
    #root_hints >= 1 and root_hints[1].text:find("Path is relative to project root", 1, true) ~= nil,
    "project root hint rendered: " .. vim.inspect(root_hints)
)

-- 4. Typing "../sibling.ts" updates virtual hint line immediately to include current directory notice.
set_input_text(input_buf, "../sibling.ts")
local dir_hints = read_virt_lines(input_buf)
assert(
    #dir_hints >= 1 and dir_hints[1].text:find("Path is relative to current directory", 1, true) ~= nil,
    "current directory hint rendered: " .. vim.inspect(dir_hints)
)

-- 5. Submitting invalid escaping path ("../../escape.ts") keeps float open and renders JprError virtual line.
set_input_text(input_buf, "../../escape.ts")
trigger_input_map(input_buf, "n", "<CR>")
assert(panel_input.is_open() == true, "invalid path keeps float open")
assert(find_panel_input_window() == input_win, "float window remains open on invalid submit")
local err_hints = read_virt_lines(input_buf)
assert(
    #err_hints >= 1 and err_hints[1].groups[1] == "JprError",
    "invalid path renders JprError virtual line: " .. vim.inspect(err_hints)
)

-- 6. Pressing q or <Esc> cancels and closes float cleanly without touching disk.
trigger_input_map(input_buf, "n", "q")
assert(panel_input.is_open() == false, "q closes float")
assert(find_panel_input_window() == nil, "no float window remains after q")
assert(vim.uv.fs_stat(worktree .. "/src/alpha.ts") ~= nil, "cancelled rename leaves file untouched")

press_panel_key("r", alpha_line)
local esc_win, esc_buf = find_panel_input_window()
assert(esc_win ~= nil, "float reopens on r")
trigger_input_map(esc_buf, "n", "<Esc>")
assert(panel_input.is_open() == false and find_panel_input_window() == nil, "<Esc> closes float cleanly")

-- 7. Submitting valid rename runs lsp_files.rename and sends refreshWorktree RPC with renames, updating sidebar.
local original_client_request = review.client.request
local refresh_calls = {}
review.client.request = function(self, method, params, callback)
    if method == "refreshWorktree" then
        refresh_calls[#refresh_calls + 1] = params
        return original_client_request(self, method, params, function(err, _)
            if err then
                return callback(err, nil)
            end
            if type(params) == "table" and type(params.renames) == "table" and #params.renames > 0 then
                local new_path = params.renames[1].newPath
                return callback(nil, build_tree_view({
                    { path = "README.md", additions = 2, deletions = 1, viewed = "UNVIEWED", threads = 0 },
                    { path = new_path, additions = 1, deletions = 0, viewed = "UNVIEWED", threads = 0, isLocalOnly = true },
                }, {
                    { depth = 0, name = "src" },
                    { depth = 1, name = vim.fs.basename(new_path), file = 1 },
                    { depth = 0, name = "README.md", file = 0 },
                }))
            end
            return callback(nil, review.view)
        end)
    end
    return original_client_request(self, method, params, callback)
end

press_panel_key("r", alpha_line)
local _, rename_buf = find_panel_input_window()
set_input_text(rename_buf, "beta.ts")
trigger_input_map(rename_buf, "n", "<CR>")
assert(vim.wait(3000, function()
    return find_line_for_path("src/beta.ts") ~= nil
end), "sidebar updates with renamed path src/beta.ts")
assert(vim.uv.fs_stat(worktree .. "/src/alpha.ts") == nil, "old file moved away")
assert(vim.uv.fs_stat(worktree .. "/src/beta.ts") ~= nil, "new file exists at src/beta.ts")
assert(#refresh_calls == 1, "refreshWorktree called once after rename")
assert(
    type(refresh_calls[1].renames) == "table"
        and refresh_calls[1].renames[1].oldPath == "src/alpha.ts"
        and refresh_calls[1].renames[1].newPath == "src/beta.ts",
    "refreshWorktree receives exact renames payload: " .. vim.inspect(refresh_calls[1])
)
local log_lines = vim.fn.readfile(engine_log)
local logged_rename_rpc = vim.tbl_filter(function(line)
    return line:find('"method":"refreshWorktree"', 1, true) ~= nil and line:find('"newPath":"src/beta.ts"', 1, true) ~= nil
end, log_lines)
assert(#logged_rename_rpc >= 1, "engine received JSON-RPC refreshWorktree with newPath")

-- 8. Pressing a and submitting "src/nested/fresh.ts" creates file with intermediate dirs, sends refreshWorktree ({}), and opens in main_window.
press_panel_key("a", review.panel.conversation_line)
local _, create_buf = find_panel_input_window()
assert(create_buf ~= nil, "a opens jpr-panel-input float")
set_input_text(create_buf, "src/nested/fresh.ts")
trigger_input_map(create_buf, "n", "<CR>")
assert(vim.wait(3000, function()
    return #refresh_calls >= 2
end), "refreshWorktree called after file creation")
assert(vim.uv.fs_stat(worktree .. "/src/nested/fresh.ts") ~= nil, "created nested file on disk")
assert(
    vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == vim.fn.resolve(worktree .. "/src/nested/fresh.ts"),
    "newly created file opens in main_window: " .. vim.api.nvim_buf_get_name(0)
)
assert(vim.api.nvim_get_current_win() ~= panel_win, "main_window is focused after create")

-- 9. Pressing a with "src/empty_dir/" creates directory and notifies cleanly.
local infos = {}
local original_info = jpr.info
jpr.info = function(msg)
    infos[#infos + 1] = msg
end
press_panel_key("a", review.panel.conversation_line)
local _, dir_buf = find_panel_input_window()
set_input_text(dir_buf, "src/empty_dir/")
trigger_input_map(dir_buf, "n", "<CR>")
assert(vim.wait(3000, function()
    return #refresh_calls >= 3
end), "refreshWorktree called after directory creation")
jpr.info = original_info
local dir_stat = vim.uv.fs_stat(worktree .. "/src/empty_dir")
assert(dir_stat ~= nil and dir_stat.type == "directory", "created directory src/empty_dir")
assert(
    #infos >= 1 and infos[#infos]:find("src/empty_dir", 1, true) ~= nil,
    "notifies cleanly after directory creation: " .. vim.inspect(infos)
)

-- 10. Bottom-of-window flip anchors above hovered row using anchor = "SW" without occluding it.
local readme_line = find_line_for_path("README.md")
assert(readme_line ~= nil, "README.md row present in panel")
local original_height = vim.api.nvim_win_get_height(panel_win)
vim.api.nvim_win_set_height(panel_win, readme_line)
press_panel_key("r", readme_line)
local flip_win = find_panel_input_window()
assert(flip_win ~= nil, "r opens float near bottom of panel")
local flip_cfg = vim.api.nvim_win_get_config(flip_win)
local flip_topline = vim.api.nvim_win_call(panel_win, function()
    return vim.fn.line("w0")
end)
assert(flip_cfg.anchor == "SW", "bottom-of-window float flips to SW anchor: " .. tostring(flip_cfg.anchor))
assert(flip_cfg.row == (readme_line - flip_topline), "SW float places bottom edge above hovered row: " .. tostring(flip_cfg.row))
panel_input.close(true)
vim.api.nvim_win_set_height(panel_win, original_height)

-- 11. Read-only session blocks both r and a without opening the float.
review.is_read_only = true
press_panel_key("r", readme_line)
assert(find_panel_input_window() == nil, "read-only session blocks r")
press_panel_key("a", readme_line)
assert(find_panel_input_window() == nil, "read-only session blocks a")
review.is_read_only = false

session.close_current()
print("panel_input_spec: ok")
