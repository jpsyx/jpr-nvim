local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local stream_view = require("jpr.views.stream")
local view_mode = require("jpr.view_mode")
local compose = require("jpr.comments.compose")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new", "tail", "end" }, worktree .. "/README.md")

local errors, infos = {}, {}
local original_error, original_info = jpr.error, jpr.info
jpr.error = function(message)
    errors[#errors + 1] = message
end
jpr.info = function(message)
    infos[#infos + 1] = message
end

session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "session syncs")

local original_client_request = review.client.request

local function find_compose_win()
    return helpers.find_floating_win("GitHub")
end

-- 1. compose.open_new (code anchor and PR anchor): floating window options, title, omnifunc, keymaps.
local line_anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 }
compose.open_new(review, line_anchor, { suggest = false })
local compose_win = find_compose_win()
assert(compose_win ~= nil and vim.api.nvim_win_is_valid(compose_win), "compose window opened")
local compose_buf = vim.api.nvim_win_get_buf(compose_win)
local code_window_config = vim.api.nvim_win_get_config(compose_win)
assert(code_window_config.relative == "editor", "compose window is floating over editor")
assert(
    vim.deep_equal(code_window_config.border, { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }),
    "compose window has rounded border: " .. vim.inspect(code_window_config.border)
)
assert(helpers.win_title(compose_win):find("[GitHub draft]", 1, true) ~= nil, helpers.win_title(compose_win))
assert(vim.bo[compose_buf].buftype == "nofile", "compose buftype is nofile")
assert(vim.bo[compose_buf].filetype == "markdown", "compose filetype is markdown")
assert(vim.bo[compose_buf].omnifunc == "v:lua.require'jpr.comments.mentions'.omnifunc", "compose sets omnifunc")

-- 2. Empty / whitespace <C-s> calls jpr.error without sending comment or closing; valid text sends comment + closes.
errors = {}
local comments_before = #helpers.read_requests(log, "comment")
vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { "   ", "\t" })
helpers.press_key("<C-s>")
assert(#errors == 1 and errors[1]:find("empty", 1, true) ~= nil, vim.inspect(errors))
assert(vim.api.nvim_win_is_valid(compose_win), "empty submit keeps compose window open")
assert(#helpers.read_requests(log, "comment") == comments_before, "empty submit sends no RPC")

vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, { "Looks good", "Second line" })
helpers.press_key("<C-s>")
assert(not vim.api.nvim_win_is_valid(compose_win), "<C-s> closes compose window")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "comment") == comments_before + 1
end), "comment RPC sent")
local sent_comment = helpers.read_requests(log, "comment")[comments_before + 1].params
assert(vim.deep_equal(sent_comment.anchor, line_anchor), vim.inspect(sent_comment))
assert(sent_comment.body == "Looks good\nSecond line", vim.inspect(sent_comment))
assert(sent_comment.origin == "github", vim.inspect(sent_comment))

-- PR conversation anchor title uses [GitHub comment] PR Conversation.
local pr_anchor = { kind = "pr", side = "RIGHT" }
compose.open_new(review, pr_anchor, { suggest = false })
local pr_compose_win = find_compose_win()
assert(pr_compose_win ~= nil, "PR compose window opened")
assert(helpers.win_title(pr_compose_win):find("[GitHub comment] PR Conversation", 1, true) ~= nil, helpers.win_title(pr_compose_win))

-- 3. q / <Esc> unmodified closes without confirm; modified invokes confirm; BufWipeout cleans up.
local original_confirm = vim.fn.confirm
local confirm_called = 0
vim.fn.confirm = function()
    confirm_called = confirm_called + 1
    return 2
end
helpers.press_key("q")
assert(confirm_called == 0, "unmodified q does not call confirm")
assert(not vim.api.nvim_win_is_valid(pr_compose_win), "unmodified q closes compose window")

compose.open_new(review, line_anchor, { suggest = false })
local esc_compose_win = find_compose_win()
helpers.press_key("<Esc>")
assert(confirm_called == 0, "unmodified <Esc> does not call confirm")
assert(not vim.api.nvim_win_is_valid(esc_compose_win), "unmodified <Esc> closes compose window")

compose.open_new(review, line_anchor, { suggest = false })
local modified_win = find_compose_win()
local modified_buf = vim.api.nvim_win_get_buf(modified_win)
vim.api.nvim_buf_set_lines(modified_buf, 0, -1, false, { "unsaved edit" })
helpers.press_key("q")
assert(confirm_called == 1, "modified q calls confirm")
assert(vim.api.nvim_win_is_valid(modified_win), "cancel keeps compose window open")

vim.fn.confirm = function()
    confirm_called = confirm_called + 1
    return 1
end
helpers.press_key("q")
assert(confirm_called == 2 and not vim.api.nvim_win_is_valid(modified_win), "discard confirm closes compose window")
vim.fn.confirm = original_confirm

compose.open_new(review, line_anchor, { suggest = false })
local wipe_win = find_compose_win()
local wipe_buf = vim.api.nvim_win_get_buf(wipe_win)
vim.api.nvim_win_close(wipe_win, true)
assert(not vim.api.nvim_win_is_valid(wipe_win), "direct close closes compose window")
assert(not vim.api.nvim_buf_is_valid(wipe_buf), "closed compose buffer wiped")

-- 4. open_new(..., { suggest = true }) pre-populates suggestion fence from anchoredLines; <C-g>s inserts fence in insert mode.
compose.open_new(review, line_anchor, { suggest = true })
assert(vim.wait(3000, function()
    return find_compose_win() ~= nil
end), "suggest compose opens after anchoredLines")
local suggest_win = find_compose_win()
local suggest_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(suggest_win), 0, -1, false)
assert(table.concat(suggest_lines, "\n") == "```suggestion\nnew\n```", vim.inspect(suggest_lines))
compose.close(review)

compose.open_new(review, line_anchor, { suggest = false })
local fence_win = find_compose_win()
local fence_buf = vim.api.nvim_win_get_buf(fence_win)
vim.api.nvim_buf_set_lines(fence_buf, 0, -1, false, { "Try this:" })
vim.api.nvim_win_set_cursor(fence_win, { 1, 9 })
local anchored_before = #helpers.read_requests(log, "anchoredLines")
helpers.press_key("A<C-g>s<Esc>")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "anchoredLines") == anchored_before + 1
        and #vim.api.nvim_buf_get_lines(fence_buf, 0, -1, false) >= 4
end), "<C-g>s inserts suggestion fence at cursor")
local inserted = table.concat(vim.api.nvim_buf_get_lines(fence_buf, 0, -1, false), "\n")
assert(inserted == "Try this:\n```suggestion\nnew\n```", inserted)
compose.close(review)

-- 4b. Stale anchoredLines callback after compose closes does not reopen compose.
local pending_anchored_callback
review.client.request = function(client_self, method, params, callback)
    if method == "anchoredLines" then
        pending_anchored_callback = callback
        return
    end
    return original_client_request(client_self, method, params, callback)
end
compose.open_new(review, line_anchor, { suggest = true })
assert(pending_anchored_callback ~= nil, "anchoredLines callback captured")
compose.close(review)
pending_anchored_callback(nil, { text = "stale" })
assert(find_compose_win() == nil, "stale anchoredLines does not open compose window after close")
review.client.request = original_client_request

-- 5. open_reply uses [GitHub draft] Reply when draftCount > 0 else [GitHub reply] Reply, and <C-s> sends reply.
review.view.draftCount = 0
compose.open_reply(review, { threadId = "T1", anchor = line_anchor })
local reply_win_immediate = find_compose_win()
assert(helpers.win_title(reply_win_immediate):find("[GitHub reply] Reply", 1, true) ~= nil, helpers.win_title(reply_win_immediate))
compose.close(review)

review.view.draftCount = 2
compose.open_reply(review, { threadId = "T1", anchor = line_anchor })
local reply_win = find_compose_win()
assert(helpers.win_title(reply_win):find("[GitHub draft] Reply", 1, true) ~= nil, helpers.win_title(reply_win))
local replies_before = #helpers.read_requests(log, "reply")
vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(reply_win), 0, -1, false, { "Reply text" })
helpers.press_key("<C-s>")
assert(not vim.api.nvim_win_is_valid(reply_win), "<C-s> closes reply compose window")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "reply") == replies_before + 1
end), "reply RPC sent")
local sent_reply = helpers.read_requests(log, "reply")[replies_before + 1].params
assert(sent_reply.threadId == "T1" and sent_reply.body == "Reply text", vim.inspect(sent_reply))

-- 6. open_edit pre-populates recoverableBody or body and <C-s> sends editMessage.
compose.open_edit(review, { id = "M1", sync = "failed", body = "remote body", recoverableBody = "local recovered" })
local edit_win = find_compose_win()
assert(helpers.win_title(edit_win):find("[Edit GitHub comment]", 1, true) ~= nil, helpers.win_title(edit_win))
local edit_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(edit_win), 0, -1, false)
assert(table.concat(edit_lines, "\n") == "local recovered", vim.inspect(edit_lines))
local edits_before = #helpers.read_requests(log, "editMessage")
helpers.press_key("<C-s>")
assert(not vim.api.nvim_win_is_valid(edit_win), "<C-s> closes edit compose window")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "editMessage") == edits_before + 1
end), "editMessage RPC sent")
local sent_edit = helpers.read_requests(log, "editMessage")[edits_before + 1].params
assert(sent_edit.messageId == "M1" and sent_edit.body == "local recovered", vim.inspect(sent_edit))

compose.open_edit(review, { id = "M2", sync = "published", body = "original body" })
local plain_edit_win = find_compose_win()
assert(table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(plain_edit_win), 0, -1, false), "\n") == "original body")
compose.close(review)

compose.open_edit(review, { id = "M2", sync = "published", body = "original body" }, { id = "T1", anchor = line_anchor })
local suggest_edit_win = find_compose_win()
local suggest_edit_buf = vim.api.nvim_win_get_buf(suggest_edit_win)
vim.api.nvim_win_set_cursor(suggest_edit_win, { 1, 13 })
local anchored_edit_before = #helpers.read_requests(log, "anchoredLines")
helpers.press_key("A<C-g>s<Esc>")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "anchoredLines") == anchored_edit_before + 1
        and #vim.api.nvim_buf_get_lines(suggest_edit_buf, 0, -1, false) >= 4
end), "<C-g>s inside open_edit inserts suggestion fence")
local edited_with_fence = table.concat(vim.api.nvim_buf_get_lines(suggest_edit_buf, 0, -1, false), "\n")
assert(edited_with_fence == "original body\n```suggestion\nnew\n```", edited_with_fence)
compose.close(review)

-- 6b. Destination toggle (<C-g> / <M-s>), sticky session.compose_destination, and <C-g>s insert fence.
review.compose_destination = nil
compose.open_new(review, line_anchor, { suggest = false })
local toggle_win = find_compose_win()
assert(helpers.win_title(toggle_win):find("[GitHub draft] README.md:2", 1, true) ~= nil, helpers.win_title(toggle_win))
helpers.press_key("<C-g>")
assert(helpers.win_title(toggle_win):find("[Local → agent] README.md:2", 1, true) ~= nil, helpers.win_title(toggle_win))
assert(review.compose_destination == "local", "compose_destination persisted as local")
local local_comments_before = #helpers.read_requests(log, "comment")
vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(toggle_win), 0, -1, false, { "Ask agent to check" })
helpers.press_key("<C-s>")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "comment") == local_comments_before + 1
end), "local comment RPC sent")
assert(helpers.read_requests(log, "comment")[local_comments_before + 1].params.origin == "local")

compose.open_new(review, line_anchor, { suggest = false })
local sticky_win = helpers.find_floating_win("Local")
assert(sticky_win ~= nil and vim.api.nvim_win_is_valid(sticky_win), "re-opened compose starts on [Local -> agent]")
assert(helpers.win_title(sticky_win):find("[Local → agent] README.md:2", 1, true) ~= nil, helpers.win_title(sticky_win))
local sticky_buf = vim.api.nvim_win_get_buf(sticky_win)
vim.api.nvim_buf_set_lines(sticky_buf, 0, -1, false, { "Keep sticky" })
local anchored_sticky_before = #helpers.read_requests(log, "anchoredLines")
helpers.press_key("A<C-g>s<Esc>")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "anchoredLines") == anchored_sticky_before + 1
        and #vim.api.nvim_buf_get_lines(sticky_buf, 0, -1, false) >= 4
end), "<C-g>s still inserts suggestion fence when destination toggle is enabled")
assert(review.compose_destination == "local", "<C-g>s does not flip compose_destination")
vim.api.nvim_buf_set_lines(sticky_buf, 0, -1, false, { "Send to alternate destination" })
helpers.press_key("<M-s>")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "comment") == local_comments_before + 2
end), "<M-s> sends comment to alternate destination")
assert(helpers.read_requests(log, "comment")[local_comments_before + 2].params.origin == "github")
assert(review.compose_destination == "local", "<M-s> keeps session.compose_destination unchanged")

-- Insert-mode standalone <C-g> flips destination without waiting for s.
compose.open_new(review, line_anchor, { suggest = false })
local insert_toggle_win = helpers.find_floating_win("Local")
assert(insert_toggle_win ~= nil, "sticky local compose opened for insert-mode toggle")
helpers.press_key("i<C-g><Esc>")
assert(helpers.win_title(insert_toggle_win):find("[GitHub draft] README.md:2", 1, true) ~= nil, helpers.win_title(insert_toggle_win))
assert(review.compose_destination == "github", "insert-mode <C-g> flips compose_destination back to github")
compose.close(review)

compose.open_new(review, { file = "README.md", kind = "file", side = "RIGHT" }, { initial_origin = "local" })
local local_file_win = helpers.find_floating_win("Local")
assert(helpers.win_title(local_file_win):find("[Local → agent] README.md", 1, true) ~= nil, helpers.win_title(local_file_win))
compose.close(review)

compose.open_new(review, { file = "README.md", kind = "range", side = "RIGHT", start = 1, ["end"] = 3 }, { initial_origin = "local" })
local local_range_win = helpers.find_floating_win("Local")
assert(helpers.win_title(local_range_win):find("[Local → agent] README.md:1-3", 1, true) ~= nil, helpers.win_title(local_range_win))
compose.close(review)
review.compose_destination = nil

-- 6c. open_promote pre-populates root body, sets [Promote -> GitHub] title, and sends promoteThread on <C-s>.
compose.open_promote(review, {
    id = "loc-1",
    origin = "local",
    anchor = line_anchor,
    messages = { { id = "loc-m-1", body = "Promote me" } },
})
local promote_win = helpers.find_floating_win("Promote")
assert(promote_win ~= nil and vim.api.nvim_win_is_valid(promote_win), "open_promote opens floating window")
assert(helpers.win_title(promote_win):find("[Promote → GitHub] README.md:2", 1, true) ~= nil, helpers.win_title(promote_win))
local promote_buf = vim.api.nvim_win_get_buf(promote_win)
assert(table.concat(vim.api.nvim_buf_get_lines(promote_buf, 0, -1, false), "\n") == "Promote me")
local promotes_before = #helpers.read_requests(log, "promoteThread")
helpers.press_key("<C-s>")
assert(not vim.api.nvim_win_is_valid(promote_win), "<C-s> closes promote compose window")
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "promoteThread") == promotes_before + 1
end), "promoteThread RPC sent")
local sent_promote = helpers.read_requests(log, "promoteThread")[promotes_before + 1].params
assert(sent_promote.threadId == "loc-1" and sent_promote.body == "Promote me", vim.inspect(sent_promote))

-- open_promote safely handles empty messages and vim.NIL anchor/promotedTo fields, and guards already-promoted threads.
compose.open_promote(review, {
    id = "loc-empty",
    origin = "local",
    promotedTo = vim.NIL,
    anchor = { kind = "pr", side = "RIGHT", file = vim.NIL, start = vim.NIL, ["end"] = vim.NIL },
    messages = {},
})
local promote_pr_win = helpers.find_floating_win("Promote")
assert(helpers.win_title(promote_pr_win):find("[Promote → GitHub] PR Conversation", 1, true) ~= nil, helpers.win_title(promote_pr_win))
assert(table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(promote_pr_win), 0, -1, false), "\n") == "")
compose.close(review)

infos = {}
compose.open_promote(review, {
    id = "loc-done",
    origin = "local",
    promotedTo = "PRRT_99",
    anchor = line_anchor,
    messages = { { id = "loc-m-done", body = "Already promoted" } },
})
assert(helpers.find_floating_win("Promote") == nil, "open_promote does not open window for already-promoted thread")
assert(#infos == 1 and infos[1]:find("already promoted", 1, true) ~= nil, vim.inspect(infos))

-- 6d. open_reply / open_edit titles for local threads and messages.
review.view.draftCount = 2
compose.open_reply(review, { threadId = "loc-1", origin = "local", anchor = line_anchor })
local local_reply_win = helpers.find_floating_win("Local reply")
assert(local_reply_win ~= nil and helpers.win_title(local_reply_win):find("[Local reply] Reply", 1, true) ~= nil)
compose.close(review)

compose.open_edit(review, { id = "loc-m-1", body = "local edit" })
local local_edit_win = helpers.find_floating_win("Edit local comment")
assert(local_edit_win ~= nil and helpers.win_title(local_edit_win):find("[Edit local comment]", 1, true) ~= nil)
compose.close(review)

compose.open_edit(review, { id = "loc-m-2", sync = vim.NIL, body = "nil sync edit" })
local local_nil_edit_win = helpers.find_floating_win("Edit local comment")
assert(local_nil_edit_win ~= nil and helpers.win_title(local_nil_edit_win):find("[Edit local comment]", 1, true) ~= nil)
compose.close(review)

-- 7. session.comment_current end-to-end anchor resolution via real compose window and comment RPCs.
local function comment_and_submit(opts)
    local before = #helpers.read_requests(log, "comment")
    session.comment_current(opts)
    local active_win = find_compose_win()
    assert(active_win ~= nil and vim.api.nvim_win_is_valid(active_win), "comment_current opened compose window")
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(active_win), 0, -1, false, { "Anchor check" })
    helpers.press_key("<C-s>")
    assert(vim.wait(3000, function()
        return #helpers.read_requests(log, "comment") == before + 1
    end), "submitted comment RPC from comment_current")
    return helpers.read_requests(log, "comment")[before + 1].params.anchor
end

-- Unrelated scratch buffer reports error without opening compose.
local win = main_window.find(review)
vim.api.nvim_set_current_win(win)
local unrelated_buf = vim.api.nvim_create_buf(false, true)
local unrelated_win = vim.api.nvim_open_win(unrelated_buf, true, { relative = "editor", row = 1, col = 1, width = 40, height = 5 })
errors = {}
session.comment_current()
assert(#errors == 1, "unrelated buffer notifies error")
vim.api.nvim_win_close(unrelated_win, true)
vim.api.nvim_buf_delete(unrelated_buf, { force = true })
assert(find_compose_win() == nil, "unrelated buffer opens no compose window")

-- Diff buffer: line, suggest, range, reversed range, file, and split base_buf.
main_window.edit(review, win, "README.md", 1)
assert(vim.wait(3000, function()
    return #helpers.read_requests(log, "fileDiff") >= 1
end), "diff requested for README.md")

vim.api.nvim_set_current_win(win)
vim.api.nvim_win_set_cursor(win, { 2, 0 })
assert(vim.deep_equal(comment_and_submit(), { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 }))

session.comment_current({ suggest = true })
assert(vim.wait(3000, function()
    return find_compose_win() ~= nil
end), "comment_current({ suggest = true }) opens compose with suggestion fence")
local suggest_from_cmd_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(find_compose_win()), 0, -1, false)
assert(suggest_from_cmd_lines[1] == "```suggestion", vim.inspect(suggest_from_cmd_lines))
compose.close(review)

assert(vim.deep_equal(
    comment_and_submit({ line1 = 1, line2 = 3, range = 2 }),
    { file = "README.md", kind = "range", side = "RIGHT", start = 1, ["end"] = 3 }
))
assert(vim.deep_equal(
    comment_and_submit({ line1 = 4, line2 = 2, range = 2 }),
    { file = "README.md", kind = "range", side = "RIGHT", start = 2, ["end"] = 4 }
))
assert(vim.deep_equal(
    comment_and_submit({ file = true }),
    { file = "README.md", kind = "file", side = "RIGHT" }
))

-- Switch to split view to comment on base_buf (LEFT side).
session.toggle_view()
local base_win
assert(vim.wait(3000, function()
    for _, candidate_win in ipairs(vim.api.nvim_tabpage_list_wins(review.tab)) do
        if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(candidate_win)):find("jpr://base/7/README.md", 1, true) then
            base_win = candidate_win
            return true
        end
    end
    return false
end), "split mode opens base_win")
vim.api.nvim_set_current_win(base_win)
vim.api.nvim_win_set_cursor(base_win, { 2, 0 })
assert(vim.deep_equal(comment_and_submit(), { file = "README.md", kind = "line", side = "LEFT", start = 2, ["end"] = 2 }))

-- Stream buffer: line, range, file = true, header error, mixed-side range error.
session.toggle_view()
stream_view.draw(review, {
    mode = "unified",
    rows = {
        { kind = "file", path = "README.md", additions = 1, deletions = 1, viewed = "UNVIEWED", folded = false },
        { kind = "hunk", path = "README.md", header = "@@ -1,3 +1,3 @@", target = 1 },
        {
            kind = "line",
            path = "README.md",
            left = { line = 1, text = "hello", change = "context", words = {} },
            right = { line = 1, text = "hello", change = "context", words = {} },
            target = 1,
        },
        { kind = "line", path = "README.md", left = { line = 2, text = "old", change = "removed", words = {} }, target = 2 },
        { kind = "line", path = "README.md", right = { line = 2, text = "new", change = "added", words = {} }, target = 2 },
        { kind = "line", path = "README.md", right = { line = 3, text = "tail", change = "added", words = {} }, target = 3 },
    },
}, { focus = true })

local stream_win = vim.fn.win_findbuf(review.stream.buffers.main)[1]
vim.api.nvim_set_current_win(stream_win)
vim.api.nvim_win_set_cursor(stream_win, { 4, 0 })
assert(vim.deep_equal(comment_and_submit(), { file = "README.md", kind = "line", side = "LEFT", start = 2, ["end"] = 2 }))
assert(vim.deep_equal(
    comment_and_submit({ line1 = 5, line2 = 6, range = 2 }),
    { file = "README.md", kind = "range", side = "RIGHT", start = 2, ["end"] = 3 }
))
assert(vim.deep_equal(
    comment_and_submit({ file = true }),
    { file = "README.md", kind = "file", side = "RIGHT" }
))

errors = {}
vim.api.nvim_win_set_cursor(stream_win, { 2, 0 })
session.comment_current()
assert(find_compose_win() == nil and #errors == 1, "stream hunk header notifies error")

errors = {}
session.comment_current({ line1 = 4, line2 = 5, range = 2 })
assert(find_compose_win() == nil and #errors == 1, "stream mixed-side range notifies error")

jpr.error = original_error
jpr.info = original_info
session.close_current()

print("compose_spec: ok")
