local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local view_mode = require("jpr.view_mode")
local threads_view = require("jpr.views.threads")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new", "tail" }, worktree .. "/README.md")

local thread_namespace = vim.api.nvim_create_namespace("jpr-threads")
local function get_thread_marks(buf)
    return vim.api.nvim_buf_get_extmarks(buf, thread_namespace, 0, -1, { details = true })
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
main_window.edit(review, win, "README.md", 1)
vim.api.nvim_set_option_value("signcolumn", "no", { win = win, scope = "local" })
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
assert(marks[1][4].virt_lines == nil, "threads start collapsed without virt_lines")
assert(marks[1][4].virt_text[1][1]:find("@alice: nit: rename this", 1, true), vim.inspect(marks[1][4]))
assert(vim.wo[win].signcolumn == "yes", "signcolumn is enabled on diff window with threads")

for _, lhs in ipairs({ "]t", "[t", "gc", "gC", "gf", "gt" }) do
    assert(helpers.has_buf_map(buf, "n", lhs), "expected buffer key " .. lhs .. " on diff buffer")
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
helpers.press_key("]t")
assert(vim.api.nvim_win_get_cursor(win)[1] == 2, "]t keymap moves to line 2")

vim.api.nvim_win_set_cursor(win, { 3, 0 })
helpers.press_key("[t")
assert(vim.api.nvim_win_get_cursor(win)[1] == 2, "[t keymap moves to line 2")

-- 3. :Jpr expand toggles between compact EOL preview and inline virt_lines.
session.expand_current()
assert(vim.wait(3000, function()
    local current_marks = get_thread_marks(buf)
    return #current_marks == 2 and (current_marks[1][4].virt_lines ~= nil or current_marks[2][4].virt_lines ~= nil)
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
assert(vim.wait(3000, function()
    local current_marks = get_thread_marks(buf)
    return #current_marks == 1 and current_marks[1][4].virt_text ~= nil and current_marks[1][4].virt_lines == nil
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
    assert(helpers.has_buf_map(base_buf, "n", lhs), "expected buffer key " .. lhs .. " on base buffer")
end
assert(#get_thread_marks(buf) == 1 and get_thread_marks(buf)[1][2] == 1, "RIGHT thread stays on file buffer")
assert(#get_thread_marks(base_buf) == 0, "no LEFT threads on base buffer for RIGHT-only fixture")

-- Inject a fileDiff response with both a LEFT thread (base line 1) and a RIGHT thread (head line 2)
-- and trigger threadsChanged notification to verify split routing, cursor/focus preservation, and signcolumn.
local original_request = review.client.request
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
review.client.request = function(client_self, method, params, callback)
    if method == "fileDiff" then
        file_diff_calls = file_diff_calls + 1
        local response_threads = vim.deepcopy(mocked_threads)
        vim.schedule(function()
            callback(nil, {
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
    return original_request(client_self, method, params, callback)
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
assert(find_base_window(review.tab) == saved_base_win, "expand preserves split base_win handle")
assert(vim.api.nvim_get_current_win() == saved_base_win, "expand preserves focus on base_win")
assert(vim.api.nvim_win_get_cursor(saved_base_win)[1] == 2, "expand preserves cursor on base_win")
assert(vim.wait(3000, function()
    local current_marks = get_thread_marks(base_buf)
    return #current_marks == 2 and (current_marks[1][4].virt_lines ~= nil or current_marks[2][4].virt_lines ~= nil)
end), "expand draws virt_lines on split base_buf")
session.expand_current()
assert(vim.wait(3000, function()
    local current_marks = get_thread_marks(base_buf)
    return #current_marks == 1 and current_marks[1][4].virt_text ~= nil and current_marks[1][4].virt_lines == nil
end), "second expand_current collapses virt_lines in split mode")
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

-- 7. Closing base_win manually + M.clear / session.close_current cleans thread lookup and restores signcolumn.
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
assert(#threads_view.threads_at_cursor(review, buf, 2) == 0, "M.clear clears file buffer threads")
assert(#threads_view.threads_at_cursor(review, base_buf, 1) == 0, "M.clear clears wiped base buffer threads")

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

-- 8. Live local anchor extmarks track line shifts and send updateLocalAnchors on :write.
local function find_update_by_id(updates, target_id)
    for _, item in ipairs(updates or {}) do
        if item.threadId == target_id then
            return item
        end
    end
    return nil
end

local function build_local_anchor_fixtures()
    return {
        {
            threadId = "loc-1",
            origin = "local",
            kind = "local",
            anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 },
            displayLine = 2,
            state = "open",
            outdated = false,
            messageCount = 1,
            firstAuthor = "reviewer",
            snippet = "local line note",
            messages = { { id = "loc-m-1", author = "reviewer", body = "local line note", viewerDidAuthor = true, reactions = {} } },
        },
        {
            threadId = "loc-range",
            origin = "local",
            kind = "local",
            anchor = { file = "README.md", kind = "range", side = "RIGHT", start = 1, ["end"] = 3 },
            displayLine = 3,
            state = "open",
            outdated = false,
            messageCount = 1,
            firstAuthor = "reviewer",
            snippet = "local range note",
            messages = { { id = "loc-m-2", author = "reviewer", body = "local range note", viewerDidAuthor = true, reactions = {} } },
        },
        {
            threadId = "loc-file",
            origin = "local",
            kind = "local",
            anchor = { file = "README.md", kind = "file", side = "RIGHT" },
            displayLine = 0,
            state = "open",
            outdated = false,
            messageCount = 1,
            firstAuthor = "reviewer",
            snippet = "local file note",
            messages = { { id = "loc-m-3", author = "reviewer", body = "local file note", viewerDidAuthor = true, reactions = {} } },
        },
    }
end

local function test_live_local_anchor_updates()
    session.toggle_view()
    assert(view_mode.get() == "unified", "switched back to unified mode")
    local fixtures = build_local_anchor_fixtures()
    mocked_threads = { fixtures[1], fixtures[2], fixtures[3], left_thread, right_thread }
    calls_before = file_diff_calls
    session.on_notification(review, "event", { type = "threadsChanged", view = review.view })
    assert(vim.wait(3000, function()
        return file_diff_calls > calls_before and #threads_view.threads_at_cursor(review, buf, 2) >= 2
    end), "unified buffer draws local and github threads")

    vim.api.nvim_set_current_win(win)
    local updates_before = #helpers.read_requests(log, "updateLocalAnchors")
    vim.cmd("silent write")
    vim.wait(100, function() return false end)
    assert(#helpers.read_requests(log, "updateLocalAnchors") == updates_before, "no updateLocalAnchors sent when lines did not shift")

    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "top 1", "top 2" })
    vim.cmd("silent write")
    assert(vim.wait(3000, function()
        return #helpers.read_requests(log, "updateLocalAnchors") == updates_before + 1
    end), "updateLocalAnchors sent when local anchors shifted on :write")
    local sent_params = helpers.read_requests(log, "updateLocalAnchors")[updates_before + 1].params
    assert(sent_params.path == "README.md", vim.inspect(sent_params))
    assert(#sent_params.updates == 2, "only RIGHT line/range local threads emitted: " .. vim.inspect(sent_params.updates))
    assert(vim.deep_equal(find_update_by_id(sent_params.updates, "loc-1"), { threadId = "loc-1", start = 4, ["end"] = 4 }))
    assert(vim.deep_equal(find_update_by_id(sent_params.updates, "loc-range"), { threadId = "loc-range", start = 3, ["end"] = 5 }))
end

local function test_github_only_does_not_emit_anchor_updates()
    mocked_threads = { right_thread }
    calls_before = file_diff_calls
    session.on_notification(review, "event", { type = "threadsChanged", view = review.view })
    assert(vim.wait(3000, function()
        return file_diff_calls > calls_before and #threads_view.threads_at_cursor(review, buf, 2) == 1
    end), "github-only thread redrawn")
    local github_only_before = #helpers.read_requests(log, "updateLocalAnchors")
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "top 3", "top 4" })
    vim.cmd("silent write")
    vim.wait(100, function() return false end)
    assert(#helpers.read_requests(log, "updateLocalAnchors") == github_only_before, "non-local threads never emit updateLocalAnchors")
end

local function build_eof_anchor_fixtures()
    local message = { id = "loc-m-eof", author = "reviewer", body = "eof", viewerDidAuthor = true, reactions = {} }
    return {
        {
            threadId = "loc-eof",
            origin = "local",
            kind = "local",
            anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 5, ["end"] = 5 },
            displayLine = 5,
            state = "open",
            outdated = false,
            messageCount = 1,
            firstAuthor = "reviewer",
            snippet = "eof",
            messages = { message },
        },
        {
            threadId = "loc-range-eof",
            origin = "local",
            kind = "local",
            anchor = { file = "README.md", kind = "range", side = "RIGHT", start = 2, ["end"] = 5 },
            displayLine = 5,
            state = "open",
            outdated = false,
            messageCount = 1,
            firstAuthor = "reviewer",
            snippet = "eof",
            messages = { message },
        },
    }
end

local function test_eof_deletion_and_clamping()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "L1", "L2", "L3", "L4", "L5" })
    mocked_threads = build_eof_anchor_fixtures()
    calls_before = file_diff_calls
    session.on_notification(review, "event", { type = "threadsChanged", view = review.view })
    assert(vim.wait(3000, function()
        return file_diff_calls > calls_before and #threads_view.threads_at_cursor(review, buf, 5) == 2
    end), "EOF threads drawn on 5-line buffer")
    local updates_before = #helpers.read_requests(log, "updateLocalAnchors")
    vim.api.nvim_buf_set_lines(buf, 3, 5, false, {})
    vim.cmd("silent write")
    assert(vim.wait(3000, function()
        return #helpers.read_requests(log, "updateLocalAnchors") == updates_before + 1
    end), "clamped range updateLocalAnchors sent on EOF deletion")
    local sent_updates = helpers.read_requests(log, "updateLocalAnchors")[updates_before + 1].params.updates
    assert(#sent_updates == 1, "deleted EOF line thread is skipped: " .. vim.inspect(sent_updates))
    assert(vim.deep_equal(sent_updates[1], { threadId = "loc-range-eof", start = 2, ["end"] = 3 }))
end

local function test_update_error_still_refreshes()
    local fixtures = build_local_anchor_fixtures()
    mocked_threads = { fixtures[1] }
    calls_before = file_diff_calls
    session.on_notification(review, "event", { type = "threadsChanged", view = review.view })
    assert(vim.wait(3000, function()
        return file_diff_calls > calls_before and #threads_view.threads_at_cursor(review, buf, 2) == 1
    end), "local thread drawn before error write test")

    local base_request = review.client.request
    local anchor_errors = 0
    local original_error = jpr.error
    jpr.error = function() end
    review.client.request = function(client_self, method, params, callback)
        if method == "updateLocalAnchors" then
            anchor_errors = anchor_errors + 1
            vim.schedule(function()
                callback({ code = -32000, message = "simulated anchor error" }, nil)
            end)
            return
        end
        return base_request(client_self, method, params, callback)
    end

    local diff_calls_before = file_diff_calls
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "err top" })
    vim.cmd("silent write")
    assert(vim.wait(3000, function()
        return anchor_errors == 1 and file_diff_calls > diff_calls_before
    end), "refresh_buffer still runs via on_error when updateLocalAnchors fails")
    jpr.error = original_error
    review.client.request = base_request
end

test_live_local_anchor_updates()
test_github_only_does_not_emit_anchor_updates()
test_eof_deletion_and_clamping()
test_update_error_still_refreshes()

local function test_split_nil_anchor_bounds()
    local split_base_buf = vim.api.nvim_create_buf(false, true)
    local split_head_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(split_base_buf, 0, -1, false, { "base 1", "base 2", "base 3" })
    vim.api.nvim_buf_set_lines(split_head_buf, 0, -1, false, { "head 1", "head 2", "head 3" })
    threads_view.draw_split(review, split_base_buf, split_head_buf, {
        threads = {
            {
                threadId = "T_NIL_BOTH",
                origin = "github",
                anchor = { file = "README.md", kind = "line", side = "LEFT", start = vim.NIL, ["end"] = vim.NIL },
                displayLine = 0,
                kind = "published",
                state = "open",
                outdated = false,
                messageCount = 1,
                firstAuthor = "bob",
                snippet = "nil both",
                messages = { { id = "M_NB", author = "bob", body = "nil both", sync = "published" } },
            },
            {
                threadId = "T_NIL_END",
                origin = "github",
                anchor = { file = "README.md", kind = "line", side = "LEFT", start = 2, ["end"] = vim.NIL },
                displayLine = 2,
                kind = "published",
                state = "open",
                outdated = false,
                messageCount = 1,
                firstAuthor = "bob",
                snippet = "nil end",
                messages = { { id = "M_NE", author = "bob", body = "nil end", sync = "published" } },
            },
        },
    })
    local nil_marks = get_thread_marks(split_base_buf)
    assert(#nil_marks == 2, "expected 2 marks with vim.NIL anchor bounds: " .. vim.inspect(nil_marks))
    assert(nil_marks[1][2] == 0 and nil_marks[2][2] == 1, "expected lines 1 and 2: " .. vim.inspect(nil_marks))
    vim.api.nvim_buf_delete(split_base_buf, { force = true })
    vim.api.nvim_buf_delete(split_head_buf, { force = true })
end

test_split_nil_anchor_bounds()

review.client.request = original_request

session.close_current()
assert(#get_thread_marks(buf) == 0, "closing session clears jpr-threads extmarks")
assert(#threads_view.threads_at_cursor(review, buf, 2) == 0, "closing session clears file buffer threads")

print("threads_view_spec: ok")
