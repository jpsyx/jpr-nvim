local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local view_mode = require("jpr.view_mode")
local threads_view = require("jpr.views.threads")

view_mode.path = vim.fn.tempname()
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new", "tail" }, worktree .. "/README.md")

local function has_buf_map(buf, mode, lhs)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        if mapping.lhs == lhs then
            return true
        end
    end
    return false
end

local thread_ns = vim.api.nvim_create_namespace("jpr-threads")
local function get_thread_marks(buf)
    return vim.api.nvim_buf_get_extmarks(buf, thread_ns, 0, -1, { details = true })
end

local function find_base_window(tab)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
        if name:find("jpr://base/7/README.md", 1, true) then
            return win
        end
    end
    return nil
end

session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "the review syncs")

local diff_view = require("jpr.views.diff")
local win = main_window.find(review)
vim.api.nvim_set_option_value("signcolumn", "no", { win = win, scope = "local" })
main_window.edit(review, win, "README.md", 1)
local buf = vim.api.nvim_win_get_buf(win)

-- 1. Unified diff draws thread sign + EOL preview on line 2 and binds buffer keys.
assert(vim.wait(3000, function()
    return #get_thread_marks(buf) > 0
end), "thread extmark is drawn on README.md")

local marks = get_thread_marks(buf)
assert(#marks == 1, "expected 1 compact thread mark, got " .. #marks)
assert(marks[1][2] == 1, "thread mark is on 0-based row 1 (displayLine 2): " .. marks[1][2])
assert(marks[1][4].sign_text == "💬", "expected published sign: " .. vim.inspect(marks[1][4]))
assert(marks[1][4].sign_hl_group == "JprThreadPublished", vim.inspect(marks[1][4]))
assert(marks[1][4].virt_text_pos == "eol", vim.inspect(marks[1][4]))
assert(marks[1][4].virt_text[1][1]:find("@alice: nit: rename this", 1, true), vim.inspect(marks[1][4]))
assert(vim.wo[win].signcolumn == "yes", "signcolumn is enabled on diff window with threads")

for _, lhs in ipairs({ "]t", "[t", "gc", "gC", "gf", "gt" }) do
    assert(has_buf_map(buf, "n", lhs), "expected buffer key " .. lhs .. " on diff buffer")
end

-- 2. ]t and [t move the cursor to the thread's line.
vim.api.nvim_set_current_win(win)
vim.api.nvim_win_set_cursor(win, { 1, 0 })
session.jump_thread_current(1)
assert(vim.api.nvim_win_get_cursor(win)[1] == 2, "jump_thread_current(1) moves to line 2")

vim.api.nvim_win_set_cursor(win, { 3, 0 })
session.jump_thread_current(-1)
assert(vim.api.nvim_win_get_cursor(win)[1] == 2, "jump_thread_current(-1) moves to line 2")

vim.api.nvim_win_set_cursor(win, { 1, 0 })
vim.api.nvim_feedkeys("]t", "xt", false)
assert(vim.api.nvim_win_get_cursor(win)[1] == 2, "]t keymap moves to line 2")

vim.api.nvim_win_set_cursor(win, { 3, 0 })
vim.api.nvim_feedkeys("[t", "xt", false)
assert(vim.api.nvim_win_get_cursor(win)[1] == 2, "[t keymap moves to line 2")

-- 3. :Jpr expand toggles session.threads_expanded between EOL preview and virt_lines.
assert(not review.threads_expanded, "threads start collapsed")
session.expand_current()
assert(review.threads_expanded == true, "expand_current flips threads_expanded to true")
assert(vim.wait(3000, function()
    local current = get_thread_marks(buf)
    return #current == 2 and (current[1][4].virt_lines ~= nil or current[2][4].virt_lines ~= nil)
end), "expanded thread draws virt_lines: " .. vim.inspect(get_thread_marks(buf)))

local expanded_marks = get_thread_marks(buf)
local virt_mark, sign_mark
for _, mark in ipairs(expanded_marks) do
    if mark[4].virt_lines then
        virt_mark = mark
    else
        sign_mark = mark
    end
end
assert(virt_mark and sign_mark, vim.inspect(expanded_marks))
assert(sign_mark[4].virt_text == nil, "expanded mode hides compact EOL virt_text")
local expanded_text = virt_mark[4].virt_lines[1][1][1] .. "\n" .. virt_mark[4].virt_lines[2][1][1]
assert(expanded_text:find("@alice", 1, true) and expanded_text:find("nit: rename this", 1, true), expanded_text)

session.expand_current()
assert(review.threads_expanded == false, "second expand_current collapses back")
assert(vim.wait(3000, function()
    local current = get_thread_marks(buf)
    return #current == 1 and current[1][4].virt_text ~= nil and current[1][4].virt_lines == nil
end), "collapsing restores compact EOL virt_text")

-- 4. Split mode places RIGHT threads on file buffer and LEFT threads on jpr://base/...
session.toggle_view()
assert(view_mode.get() == "split", "toggled to split")
assert(vim.wait(3000, function()
    return find_base_window(review.tab) ~= nil
end), "base window opens in split mode")

local base_win = find_base_window(review.tab)
local base_buf = vim.api.nvim_win_get_buf(base_win)
local initial_base_signcolumn = vim.api.nvim_get_option_value("signcolumn", { win = base_win, scope = "local" })
assert(vim.b[base_buf].jpr_base_path == "README.md", "base buffer records jpr_base_path")
for _, lhs in ipairs({ "]t", "[t", "gc", "gC", "gf", "gt" }) do
    assert(has_buf_map(base_buf, "n", lhs), "expected buffer key " .. lhs .. " on base buffer")
end
assert(#get_thread_marks(buf) == 1 and get_thread_marks(buf)[1][2] == 1, "RIGHT thread stays on file buffer")
assert(#get_thread_marks(base_buf) == 0, "no LEFT threads on base buffer for RIGHT-only fixture")

-- Inject a fileDiff response with both a LEFT thread (base line 1) and a RIGHT thread (head line 2)
-- and trigger threadsChanged notification to verify split routing, cursor/focus preservation, and signcolumn.
local orig_request = review.client.request
local left_thread = {
    threadId = "T_LEFT",
    anchor = { file = "README.md", kind = "line", side = "LEFT", start = 1, ["end"] = 1 },
    displayLine = 2,
    kind = "draft",
    state = "open",
    outdated = false,
    messageCount = 1,
    firstAuthor = "bob",
    snippet = "old base line comment",
    messages = {
        { id = "M_L", author = "bob", body = "old base line comment", sync = "draft" },
    },
}
local right_thread = {
    threadId = "T_RIGHT",
    anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 },
    displayLine = 2,
    kind = "published",
    state = "open",
    outdated = false,
    messageCount = 1,
    firstAuthor = "alice",
    snippet = "new head line comment",
    messages = {
        { id = "M_R", author = "alice", body = "new head line comment", sync = "published" },
    },
}
local mocked_threads = { left_thread, right_thread }
local file_diff_calls = 0
review.client.request = function(client_self, method, params, cb)
    if method == "fileDiff" then
        file_diff_calls = file_diff_calls + 1
        local response_threads = vim.deepcopy(mocked_threads)
        vim.schedule(function()
            cb(nil, {
                path = "README.md",
                binary = false,
                baseText = "hello\nold\n",
                added = {},
                removed = {},
                threads = response_threads,
            })
        end)
        return
    end
    return orig_request(client_self, method, params, cb)
end

local saved_base_win = base_win
vim.api.nvim_set_current_win(saved_base_win)
vim.api.nvim_win_set_cursor(saved_base_win, { 2, 0 })

local calls_before = file_diff_calls
session.on_notification(review, "event", { type = "threadsChanged", view = review.view })
assert(vim.wait(3000, function()
    return file_diff_calls > calls_before and #get_thread_marks(base_buf) == 1
end), "threadsChanged redraws split diff and places LEFT thread on base buffer")

assert(find_base_window(review.tab) == saved_base_win, "threadsChanged preserves split base_win handle")
assert(vim.api.nvim_get_current_win() == saved_base_win, "threadsChanged preserves focus on base_win")
assert(vim.api.nvim_win_get_cursor(saved_base_win)[1] == 2, "threadsChanged preserves cursor on base_win")

local base_marks = get_thread_marks(base_buf)
local file_marks = get_thread_marks(buf)
assert(#base_marks == 1 and base_marks[1][2] == 0, "LEFT thread drawn on base line 1 (row 0): " .. vim.inspect(base_marks))
assert(vim.trim(base_marks[1][4].sign_text) == "✎", "LEFT draft thread has draft sign: " .. vim.inspect(base_marks[1][4].sign_text))
assert(vim.wo[base_win].signcolumn == "yes", "base window enables signcolumn when LEFT threads exist")
assert(#file_marks == 1 and file_marks[1][2] == 1, "RIGHT thread drawn on head line 2 (row 1)")
assert(vim.wo[win].signcolumn == "yes", "file window enables signcolumn when RIGHT threads exist")

-- 5. :Jpr expand in split mode preserves base_win handle, focus, and cursor.
session.expand_current()
assert(review.threads_expanded == true, "expand_current toggles to expanded in split mode")
assert(find_base_window(review.tab) == saved_base_win, "expand preserves split base_win handle")
assert(vim.api.nvim_get_current_win() == saved_base_win, "expand preserves focus on base_win")
assert(vim.api.nvim_win_get_cursor(saved_base_win)[1] == 2, "expand preserves cursor on base_win")
assert(vim.wait(3000, function()
    local current = get_thread_marks(base_buf)
    return #current == 2 and (current[1][4].virt_lines ~= nil or current[2][4].virt_lines ~= nil)
end), "expand draws virt_lines on split base_buf")
session.expand_current()
assert(review.threads_expanded == false, "second expand_current collapses in split mode")
assert(vim.api.nvim_get_current_win() == saved_base_win, "collapse preserves focus on base_win")
assert(vim.api.nvim_win_get_cursor(saved_base_win)[1] == 2, "collapse preserves cursor on base_win")

assert(#threads_view.threads_at_cursor(review, base_buf, 1) == 1, "threads_at_cursor finds LEFT thread on base line 1")
assert(threads_view.threads_at_cursor(review, base_buf, 1)[1].threadId == "T_LEFT")
assert(#threads_view.threads_at_cursor(review, buf, 2) == 1, "threads_at_cursor finds RIGHT thread on head line 2")
assert(threads_view.threads_at_cursor(review, buf, 2)[1].threadId == "T_RIGHT")

vim.api.nvim_win_set_cursor(base_win, { 2, 0 })
session.jump_thread_current(-1)
assert(vim.api.nvim_win_get_cursor(base_win)[1] == 1, "[t in base window jumps to LEFT thread on line 1")

-- 6. Empty diff.threads via threadsChanged restores signcolumn to its prior value.
mocked_threads = {}
calls_before = file_diff_calls
session.on_notification(review, "event", { type = "threadsChanged", view = review.view })
assert(vim.wait(3000, function()
    return file_diff_calls > calls_before and #get_thread_marks(buf) == 0 and #get_thread_marks(base_buf) == 0
end), "threadsChanged clears thread marks when diff.threads is empty")
assert(
    vim.api.nvim_get_option_value("signcolumn", { win = win, scope = "local" }) == "no",
    "file window restores signcolumn when threads become empty"
)
assert(
    vim.api.nvim_get_option_value("signcolumn", { win = base_win, scope = "local" }) == initial_base_signcolumn,
    "base window restores signcolumn when threads become empty"
)

-- 7. Closing base_win manually + M.clear / session.close_current cleans session.buf_threads and restores signcolumn.
mocked_threads = { left_thread, right_thread }
calls_before = file_diff_calls
session.on_notification(review, "event", { type = "threadsChanged", view = review.view })
assert(vim.wait(3000, function()
    return file_diff_calls > calls_before and #get_thread_marks(base_buf) == 1
end), "threads restored before manual base_win close")
assert(vim.api.nvim_get_option_value("signcolumn", { win = win, scope = "local" }) == "yes")

vim.api.nvim_win_close(base_win, true)
assert(not vim.api.nvim_buf_is_valid(base_buf), "base_buf is wiped when base_win closes")
diff_view.clear(review, win)
assert(
    vim.api.nvim_get_option_value("signcolumn", { win = win, scope = "local" }) == "no",
    "M.clear restores file window signcolumn"
)
assert(next(review.buf_threads or {}) == nil, "M.clear removes both file and wiped base buffers from buf_threads")

diff_view.reconcile(review)
assert(vim.wait(3000, function()
    return find_base_window(review.tab) ~= nil
end), "reconcile re-opens split base window")
local reopened_base_win = find_base_window(review.tab)
local reopened_base_buf = vim.api.nvim_win_get_buf(reopened_base_win)
assert(vim.wait(3000, function()
    return #get_thread_marks(reopened_base_buf) == 1
end), "reopened base buffer draws thread")
vim.api.nvim_win_close(reopened_base_win, true)

review.client.request = orig_request

session.close_current()
assert(#get_thread_marks(buf) == 0, "closing session clears jpr-threads extmarks")
assert(next(review.buf_threads or {}) == nil, "closing session leaves buf_threads empty after manual base_win close")

print("threads_view_spec: ok")
