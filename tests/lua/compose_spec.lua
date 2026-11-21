local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local stream_view = require("jpr.views.stream")
local view_mode = require("jpr.view_mode")
local mentions = require("jpr.comments.mentions")
local compose = require("jpr.comments.compose")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new", "tail", "end" }, worktree .. "/README.md")

local function read_logged_requests(method_name)
    if vim.fn.filereadable(log) == 0 then
        return {}
    end
    local matches = {}
    for _, line in ipairs(vim.fn.readfile(log)) do
        local ok, decoded = pcall(vim.json.decode, line)
        if ok and type(decoded) == "table" and decoded.method == method_name then
            matches[#matches + 1] = decoded
        end
    end
    return matches
end

local function win_title(win)
    local title = vim.api.nvim_win_get_config(win).title
    if type(title) == "string" then
        return title
    end
    if type(title) == "table" then
        local parts = {}
        for _, chunk in ipairs(title) do
            parts[#parts + 1] = chunk[1]
        end
        return table.concat(parts)
    end
    return ""
end

local function press_key(lhs)
    local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    vim.api.nvim_feedkeys(keys, "xt", false)
end

-- 1. Pure @mention helpers: find_start and complete_items.
assert(mentions.find_start("hello @pa") == 6, "find_start returns 0-based @ offset")
assert(mentions.find_start("@pa") == 0, "find_start at column 0")
assert(mentions.find_start("hello ") == -1, "find_start returns -1 when not in mention")
assert(mentions.find_start("hello @pa world") == -1, "find_start returns -1 after space")

local mixed_candidates = {
    { login = "paula", isParticipant = false },
    { login = "pablo", isParticipant = true },
    { login = "Patrick", isParticipant = true },
    { login = "bob", isParticipant = false },
}
local matched = mentions.complete_items(mixed_candidates, "@PA")
assert(vim.deep_equal(matched, {
    { word = "@pablo", abbr = "@pablo", menu = "[PR]", icase = 1 },
    { word = "@Patrick", abbr = "@Patrick", menu = "[PR]", icase = 1 },
    { word = "@paula", abbr = "@paula", menu = "[repo]", icase = 1 },
}), "complete_items keeps participants first and matches case-insensitively: " .. vim.inspect(matched))

local single_matched = mentions.complete_items({ { login = "pablo", isParticipant = true } }, "@pa")
assert(vim.deep_equal(single_matched, {
    { word = "@pablo", abbr = "@pablo", menu = "[PR]", icase = 1 },
}), "complete_items matches exact expected item shape")

-- Capture jpr.error / jpr.info notifications.
local errors, infos = {}, {}
local orig_error, orig_info = jpr.error, jpr.info
jpr.error = function(msg)
    errors[#errors + 1] = msg
end
jpr.info = function(msg)
    infos[#infos + 1] = msg
end

-- Start session with fake_engine.sh.
session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "session syncs")

-- 2. mentions.attach + mentions.omnifunc(1, "") and mentions.omnifunc(0, "@a").
local om_buf = vim.api.nvim_create_buf(false, true)
local om_win = vim.api.nvim_open_win(om_buf, true, { relative = "editor", row = 1, col = 1, width = 40, height = 5 })
vim.api.nvim_buf_set_lines(om_buf, 0, -1, false, { "hello @a" })
vim.api.nvim_win_set_cursor(om_win, { 1, 7 })
mentions.attach(review, om_buf)
assert(vim.bo[om_buf].omnifunc == "v:lua.require'jpr.comments.mentions'.omnifunc", "omnifunc wired")
assert(vim.wait(3000, function()
    local items = mentions.omnifunc(0, "@a")
    return #items == 1 and items[1].word == "@alice"
end), "mentions.omnifunc(0, '@a') returns synced candidates after attach")
vim.api.nvim_buf_set_lines(om_buf, 0, -1, false, { "hello @" })
local start_col
vim.keymap.set("i", "<F2>", function()
    start_col = mentions.omnifunc(1, "")
end, { buffer = om_buf })
press_key("A<F2><Esc>")
assert(start_col == 6, "mentions.omnifunc(1, '') returns @ column: " .. tostring(start_col))
vim.api.nvim_win_close(om_win, true)
vim.api.nvim_buf_delete(om_buf, { force = true })

-- 2b. mentions.attach ignores stale/closing callbacks without erroring.
local pending_mentions_cb
local orig_client_request = review.client.request
review.client.request = function(client_self, method, params, cb)
    if method == "mentions" then
        pending_mentions_cb = cb
        return
    end
    return orig_client_request(client_self, method, params, cb)
end
local stale_om_buf = vim.api.nvim_create_buf(false, true)
mentions.attach(review, stale_om_buf)
vim.api.nvim_buf_delete(stale_om_buf, { force = true })
pending_mentions_cb(nil, { candidates = { { login = "ghost", isParticipant = false } } })
assert(#mentions.omnifunc(0, "@g") == 0, "wiped buffer mentions callback does not clobber active candidates")
review.client.request = orig_client_request

-- 3. compose.open_new (code anchor and PR anchor): floating window options, title, omnifunc, keymaps.
local line_anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 }
compose.open_new(review, line_anchor, { suggest = false })
assert(review.compose ~= nil and vim.api.nvim_win_is_valid(review.compose.win), "compose window opened")
local code_cfg = vim.api.nvim_win_get_config(review.compose.win)
assert(code_cfg.relative == "editor", "compose window is floating over editor")
assert(code_cfg.border ~= nil, "compose window has border")
assert(win_title(review.compose.win):find("[GitHub draft]", 1, true) ~= nil, win_title(review.compose.win))
assert(vim.bo[review.compose.buf].buftype == "nofile", "compose buftype is nofile")
assert(vim.bo[review.compose.buf].filetype == "markdown", "compose filetype is markdown")
assert(vim.bo[review.compose.buf].omnifunc == "v:lua.require'jpr.comments.mentions'.omnifunc", "compose sets omnifunc")

-- 4. Empty / whitespace <C-s> calls jpr.error without sending comment or closing; valid text sends comment + closes.
errors = {}
local comments_before = #read_logged_requests("comment")
vim.api.nvim_buf_set_lines(review.compose.buf, 0, -1, false, { "   ", "\t" })
press_key("<C-s>")
assert(#errors == 1 and errors[1]:find("empty", 1, true) ~= nil, vim.inspect(errors))
assert(review.compose ~= nil and vim.api.nvim_win_is_valid(review.compose.win), "empty submit keeps compose open")
assert(#read_logged_requests("comment") == comments_before, "empty submit sends no RPC")

vim.api.nvim_buf_set_lines(review.compose.buf, 0, -1, false, { "Looks good", "Second line" })
press_key("<C-s>")
assert(review.compose == nil, "<C-s> closes compose")
assert(vim.wait(3000, function()
    return #read_logged_requests("comment") == comments_before + 1
end), "comment RPC sent")
local sent_comment = read_logged_requests("comment")[comments_before + 1].params
assert(vim.deep_equal(sent_comment.anchor, line_anchor), vim.inspect(sent_comment))
assert(sent_comment.body == "Looks good\nSecond line", vim.inspect(sent_comment))

-- PR conversation anchor title uses [GitHub comment] PR Conversation.
local pr_anchor = { kind = "pr", side = "RIGHT" }
compose.open_new(review, pr_anchor, { suggest = false })
assert(win_title(review.compose.win):find("[GitHub comment] PR Conversation", 1, true) ~= nil, win_title(review.compose.win))

-- 5. q / <Esc> unmodified closes without confirm; modified invokes confirm; BufWipeout clears session.compose.
local orig_confirm = vim.fn.confirm
local confirm_called = 0
vim.fn.confirm = function()
    confirm_called = confirm_called + 1
    return 2
end
press_key("q")
assert(confirm_called == 0, "unmodified q does not call confirm")
assert(review.compose == nil, "unmodified q closes compose")

compose.open_new(review, line_anchor, { suggest = false })
press_key("<Esc>")
assert(confirm_called == 0, "unmodified <Esc> does not call confirm")
assert(review.compose == nil, "unmodified <Esc> closes compose")

compose.open_new(review, line_anchor, { suggest = false })
vim.api.nvim_buf_set_lines(review.compose.buf, 0, -1, false, { "unsaved edit" })
press_key("q")
assert(confirm_called == 1, "modified q calls confirm")
assert(review.compose ~= nil and vim.api.nvim_win_is_valid(review.compose.win), "cancel keeps compose open")

vim.fn.confirm = function()
    confirm_called = confirm_called + 1
    return 1
end
press_key("q")
assert(confirm_called == 2 and review.compose == nil, "discard confirm closes compose")
vim.fn.confirm = orig_confirm

compose.open_new(review, line_anchor, { suggest = false })
local wipe_win, wipe_buf = review.compose.win, review.compose.buf
vim.api.nvim_win_close(wipe_win, true)
assert(review.compose == nil, "BufWipeout clears session.compose")
assert(not vim.api.nvim_buf_is_valid(wipe_buf), "closed compose buffer wiped")

-- 6. open_new(..., { suggest = true }) pre-populates suggestion fence from anchoredLines; <C-g>s inserts fence in insert mode.
compose.open_new(review, line_anchor, { suggest = true })
assert(vim.wait(3000, function()
    return review.compose ~= nil and vim.api.nvim_win_is_valid(review.compose.win)
end), "suggest compose opens after anchoredLines")
local suggest_lines = vim.api.nvim_buf_get_lines(review.compose.buf, 0, -1, false)
assert(table.concat(suggest_lines, "\n") == "```suggestion\nnew\n```", vim.inspect(suggest_lines))
compose.close(review)

compose.open_new(review, line_anchor, { suggest = false })
vim.api.nvim_buf_set_lines(review.compose.buf, 0, -1, false, { "Try this:" })
vim.api.nvim_win_set_cursor(review.compose.win, { 1, 9 })
local anchored_before = #read_logged_requests("anchoredLines")
press_key("A<C-g>s<Esc>")
assert(vim.wait(3000, function()
    return #read_logged_requests("anchoredLines") == anchored_before + 1
        and #vim.api.nvim_buf_get_lines(review.compose.buf, 0, -1, false) >= 4
end), "<C-g>s inserts suggestion fence at cursor")
local inserted = table.concat(vim.api.nvim_buf_get_lines(review.compose.buf, 0, -1, false), "\n")
assert(inserted == "Try this:\n```suggestion\nnew\n```", inserted)
compose.close(review)

-- 6b. Stale anchoredLines callback after compose closes does not reopen compose.
local pending_anchored_cb
review.client.request = function(client_self, method, params, cb)
    if method == "anchoredLines" then
        pending_anchored_cb = cb
        return
    end
    return orig_client_request(client_self, method, params, cb)
end
compose.open_new(review, line_anchor, { suggest = true })
assert(pending_anchored_cb ~= nil, "anchoredLines callback captured")
compose.close(review)
pending_anchored_cb(nil, { text = "stale" })
assert(review.compose == nil, "stale anchoredLines does not open compose after close")
review.client.request = orig_client_request

-- 7. open_reply uses [GitHub draft] Reply when draftCount > 0 else [GitHub reply] Reply, and <C-s> sends reply.
review.view.draftCount = 0
compose.open_reply(review, { threadId = "T1", anchor = line_anchor })
assert(win_title(review.compose.win):find("[GitHub reply] Reply", 1, true) ~= nil, win_title(review.compose.win))
compose.close(review)

review.view.draftCount = 2
compose.open_reply(review, { threadId = "T1", anchor = line_anchor })
assert(win_title(review.compose.win):find("[GitHub draft] Reply", 1, true) ~= nil, win_title(review.compose.win))
local replies_before = #read_logged_requests("reply")
vim.api.nvim_buf_set_lines(review.compose.buf, 0, -1, false, { "Reply text" })
press_key("<C-s>")
assert(review.compose == nil, "<C-s> closes reply compose")
assert(vim.wait(3000, function()
    return #read_logged_requests("reply") == replies_before + 1
end), "reply RPC sent")
local sent_reply = read_logged_requests("reply")[replies_before + 1].params
assert(sent_reply.threadId == "T1" and sent_reply.body == "Reply text", vim.inspect(sent_reply))

-- 8. open_edit pre-populates recoverableBody or body and <C-s> sends editMessage.
compose.open_edit(review, { id = "M1", body = "remote body", recoverableBody = "local recovered" })
local edit_lines = vim.api.nvim_buf_get_lines(review.compose.buf, 0, -1, false)
assert(table.concat(edit_lines, "\n") == "local recovered", vim.inspect(edit_lines))
local edits_before = #read_logged_requests("editMessage")
press_key("<C-s>")
assert(review.compose == nil, "<C-s> closes edit compose")
assert(vim.wait(3000, function()
    return #read_logged_requests("editMessage") == edits_before + 1
end), "editMessage RPC sent")
local sent_edit = read_logged_requests("editMessage")[edits_before + 1].params
assert(sent_edit.messageId == "M1" and sent_edit.body == "local recovered", vim.inspect(sent_edit))

compose.open_edit(review, { id = "M2", body = "original body" })
assert(table.concat(vim.api.nvim_buf_get_lines(review.compose.buf, 0, -1, false), "\n") == "original body")
compose.close(review)

-- 9. session.comment_current anchor resolution in diff, base_buf, stream, and invalid buffers.
local captured_anchor, captured_suggest
local orig_open_new = compose.open_new
compose.open_new = function(sess, anchor, opts)
    captured_anchor = anchor
    captured_suggest = opts and opts.suggest or false
end

-- Unrelated scratch buffer reports error.
local win = main_window.find(review)
vim.api.nvim_set_current_win(win)
local unrelated_buf = vim.api.nvim_create_buf(false, true)
local unrelated_win = vim.api.nvim_open_win(unrelated_buf, true, { relative = "editor", row = 1, col = 1, width = 40, height = 5 })
errors = {}
session.comment_current()
assert(#errors == 1, "unrelated buffer notifies error")
vim.api.nvim_win_close(unrelated_win, true)
vim.api.nvim_buf_delete(unrelated_buf, { force = true })

-- Diff buffer: line, range, reversed range, file, suggest, and base_buf.
main_window.edit(review, win, "README.md", 1)
local diff_buf = vim.api.nvim_win_get_buf(win)
assert(vim.wait(3000, function()
    return review.diff.applied[win] ~= nil and review.diff.applied[win].buf == diff_buf
end), "diff applied to README.md")

vim.api.nvim_set_current_win(win)
vim.api.nvim_win_set_cursor(win, { 2, 0 })
captured_anchor = nil
session.comment_current()
assert(vim.deep_equal(captured_anchor, { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 }),
    "diff normal line: " .. vim.inspect(captured_anchor))

captured_anchor = nil
captured_suggest = nil
session.comment_current({ suggest = true })
assert(captured_suggest == true and captured_anchor.kind == "line", "suggest = true forwarded to compose.open_new")

captured_anchor = nil
session.comment_current({ line1 = 1, line2 = 3, range = 2 })
assert(vim.deep_equal(captured_anchor, { file = "README.md", kind = "range", side = "RIGHT", start = 1, ["end"] = 3 }),
    "diff range: " .. vim.inspect(captured_anchor))

captured_anchor = nil
session.comment_current({ line1 = 4, line2 = 2, range = 2 })
assert(vim.deep_equal(captured_anchor, { file = "README.md", kind = "range", side = "RIGHT", start = 2, ["end"] = 4 }),
    "diff reversed range normalized: " .. vim.inspect(captured_anchor))

captured_anchor = nil
session.comment_current({ file = true })
assert(vim.deep_equal(captured_anchor, { file = "README.md", kind = "file", side = "RIGHT" }),
    "diff file comment: " .. vim.inspect(captured_anchor))

-- Switch to split view to get a real base_buf (jpr_base_path).
session.toggle_view()
assert(vim.wait(3000, function()
    return review.diff.splits[win] ~= nil and vim.api.nvim_win_is_valid(review.diff.splits[win].base_win)
end), "split mode opens base_win")
local base_win = review.diff.splits[win].base_win
vim.api.nvim_set_current_win(base_win)
vim.api.nvim_win_set_cursor(base_win, { 2, 0 })
captured_anchor = nil
session.comment_current()
assert(vim.deep_equal(captured_anchor, { file = "README.md", kind = "line", side = "LEFT", start = 2, ["end"] = 2 }),
    "base_buf resolves side LEFT: " .. vim.inspect(captured_anchor))

-- Stream buffer: line, range, file = true, header error, mixed-side range error.
session.toggle_view() -- back to unified
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
        {
            kind = "line",
            path = "README.md",
            left = { line = 2, text = "old", change = "removed", words = {} },
            target = 2,
        },
        {
            kind = "line",
            path = "README.md",
            right = { line = 2, text = "new", change = "added", words = {} },
            target = 2,
        },
        {
            kind = "line",
            path = "README.md",
            right = { line = 3, text = "tail", change = "added", words = {} },
            target = 3,
        },
    },
}, { focus = true })

local stream_win = vim.fn.win_findbuf(review.stream.buffers.main)[1]
vim.api.nvim_set_current_win(stream_win)

-- Stream line on LEFT-only row (line 4).
vim.api.nvim_win_set_cursor(stream_win, { 4, 0 })
captured_anchor = nil
session.comment_current()
assert(vim.deep_equal(captured_anchor, { file = "README.md", kind = "line", side = "LEFT", start = 2, ["end"] = 2 }),
    "stream LEFT line: " .. vim.inspect(captured_anchor))

-- Stream range on RIGHT rows (lines 5..6).
captured_anchor = nil
session.comment_current({ line1 = 5, line2 = 6, range = 2 })
assert(vim.deep_equal(captured_anchor, { file = "README.md", kind = "range", side = "RIGHT", start = 2, ["end"] = 3 }),
    "stream RIGHT range: " .. vim.inspect(captured_anchor))

-- Stream file = true (gf) anywhere inside file section.
captured_anchor = nil
session.comment_current({ file = true })
assert(vim.deep_equal(captured_anchor, { file = "README.md", kind = "file", side = "RIGHT" }),
    "stream file comment: " .. vim.inspect(captured_anchor))

-- Stream header row (line 1 or 2) reports error.
errors = {}
captured_anchor = nil
vim.api.nvim_win_set_cursor(stream_win, { 2, 0 })
session.comment_current()
assert(captured_anchor == nil and #errors == 1, "stream hunk header notifies error")

-- Stream mixed-side range (lines 4..5) reports error.
errors = {}
captured_anchor = nil
session.comment_current({ line1 = 4, line2 = 5, range = 2 })
assert(captured_anchor == nil and #errors == 1, "stream mixed-side range notifies error")

compose.open_new = orig_open_new
jpr.error = orig_error
jpr.info = orig_info
session.close_current()

print("compose_spec: ok")
