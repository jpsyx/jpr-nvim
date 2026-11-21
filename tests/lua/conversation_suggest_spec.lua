local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local main_window = require("jpr.views.main_window")
local view_mode = require("jpr.view_mode")
local render_threads = require("jpr.render.threads")

view_mode.path = vim.fn.tempname()
local log = vim.fn.tempname()
vim.env.FAKE_ENGINE_LOG = log
jpr.setup({ binary = root .. "/tests/lua/fixtures/fake_engine.sh" })

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree, "p")
vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")
vim.fn.writefile({ "other" }, worktree .. "/OTHER.md")

local outside_file = vim.fn.tempname()
vim.fn.writefile({ "outside" }, outside_file)

local function read_requests(method_name)
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

local function read_bytes(path)
    local handle = assert(io.open(path, "rb"))
    local data = handle:read("*a")
    handle:close()
    return data
end

local function write_bytes(path, content)
    local handle = assert(io.open(path, "wb"))
    handle:write(content)
    handle:close()
end

local function press_key(lhs)
    local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    vim.api.nvim_feedkeys(keys, "xt", false)
end

local errors, infos = {}, {}
jpr.error = function(message)
    errors[#errors + 1] = message
end
jpr.info = function(message)
    infos[#infos + 1] = message
end

-- 0. Without an active session, conversation_current and suggest_current error cleanly.
session.conversation_current()
assert(#errors == 1 and errors[1]:find("no pull request", 1, true), vim.inspect(errors))
errors = {}
session.suggest_current()
assert(#errors == 1 and errors[1]:find("no pull request", 1, true), vim.inspect(errors))
errors = {}

-- Start session and sync with fake_engine.sh.
session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
local review = session.current()
assert(vim.wait(3000, function()
    return review.view.pr ~= nil
end), "the review syncs")

-- 1. :Jpr conversation clears any diff split first and opens jpr://conversation/7 in main_window.
local win = main_window.find(review)
view_mode.set("split")
main_window.edit(review, win, "README.md", 1)
assert(vim.wait(3000, function()
    return review.diff.splits[win] ~= nil and vim.api.nvim_win_is_valid(review.diff.splits[win].base_win)
end), "split diff opens base_win before conversation")
local base_win = review.diff.splits[win].base_win

local conversation = require("jpr.views.conversation")
session.conversation_current()

assert(review.diff.splits[win] == nil, "conversation clears diff split")
assert(not vim.api.nvim_win_is_valid(base_win), "diff base_win closed")

local conv_buf = vim.api.nvim_win_get_buf(win)
assert(vim.api.nvim_buf_get_name(conv_buf) == "jpr://conversation/7", vim.api.nvim_buf_get_name(conv_buf))
assert(vim.bo[conv_buf].buftype == "nofile", "conversation buftype is nofile")
assert(vim.bo[conv_buf].filetype == "markdown", "conversation filetype is markdown")
assert(vim.bo[conv_buf].modifiable == false, "conversation is read-only")

assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conv_buf, 0, -1, false), "\n")
    return text:find("Overall looks clean!", 1, true) ~= nil
end), "conversation loads PR comment")

local conv_text = table.concat(vim.api.nvim_buf_get_lines(conv_buf, 0, -1, false), "\n")
assert(conv_text:find("@alice", 1, true) ~= nil, "author header rendered: " .. conv_text)
assert(conv_text:find("nit: rename this", 1, true) == nil, "code threads excluded: " .. conv_text)

-- Opening conversation while split stream is active also clears stream's left window.
require("jpr.views.stream").show(review, { focus = true })
assert(vim.wait(3000, function()
    return review.stream and review.stream.left_win ~= nil and vim.api.nvim_win_is_valid(review.stream.left_win)
end), "split stream opens left_win")
local stream_left_win = review.stream.left_win
session.conversation_current()
assert(not vim.api.nvim_win_is_valid(stream_left_win), "conversation clears stream left_win")
assert(vim.api.nvim_win_get_buf(main_window.find(review)) == conv_buf, "reuses jpr://conversation/7")

-- 2. Conversation keybindings: c opens compose with kind="pr", side="RIGHT".
local orig_open_new = require("jpr.comments.compose").open_new
local open_new_calls = {}
require("jpr.comments.compose").open_new = function(sess, anchor)
    open_new_calls[#open_new_calls + 1] = { sess = sess, anchor = anchor }
end
vim.api.nvim_set_current_win(main_window.find(review))
press_key("c")
require("jpr.comments.compose").open_new = orig_open_new
assert(#open_new_calls == 1, "c opens compose.open_new")
assert(vim.deep_equal(open_new_calls[1].anchor, { kind = "pr", side = "RIGHT" }), vim.inspect(open_new_calls[1].anchor))

-- Real compose c -> <C-s> sends comment with PR anchor.
local comments_before = #read_requests("comment")
press_key("c")
assert(review.compose ~= nil and vim.api.nvim_win_is_valid(review.compose.win), "real compose opens on c")
vim.api.nvim_buf_set_lines(review.compose.buf, 0, -1, false, { "Ship it!" })
press_key("<C-s>")
assert(vim.wait(3000, function()
    return #read_requests("comment") == comments_before + 1
end), "PR comment RPC sent")
local sent_pr_comment = read_requests("comment")[comments_before + 1].params
assert(sent_pr_comment.anchor.kind == "pr" and sent_pr_comment.body == "Ship it!", vim.inspect(sent_pr_comment))

-- 3. Multi-message PR threads: reactions, author checks on e/d, failed X, refresh visibility, q, close.
local pr_threads_fixture = {
    {
        id = "T_CODE",
        origin = "github",
        anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 },
        state = "open",
        outdated = false,
        messages = {
            {
                id = "M_CODE",
                author = "bob",
                body = "should not appear in conversation",
                created = "2026-11-20T00:00:00Z",
                updated = "2026-11-20T00:00:00Z",
                sync = "published",
                viewerDidAuthor = false,
                reactions = {},
            },
        },
    },
    {
        id = "T_PR_1",
        origin = "github",
        anchor = { kind = "pr", side = "RIGHT" },
        state = "open",
        outdated = false,
        messages = {
            {
                id = "M_PR_OTHER",
                author = "alice",
                body = "Thanks for the fix",
                created = "2026-11-20T00:00:00Z",
                updated = "2026-11-20T00:00:00Z",
                sync = "published",
                viewerDidAuthor = false,
                reactions = {
                    { content = "THUMBS_UP", count = 2, viewerHasReacted = true },
                },
            },
        },
    },
    {
        id = "T_PR_2",
        origin = "github",
        anchor = { kind = "pr", side = "RIGHT" },
        state = "open",
        outdated = false,
        messages = {
            {
                id = "M_PR_OWN",
                author = "pablo",
                body = "Offline follow-up",
                created = "2026-11-20T01:00:00Z",
                updated = "2026-11-20T01:00:00Z",
                sync = "failed",
                syncError = "rate limited",
                recoverableBody = "Recovered body",
                viewerDidAuthor = true,
                reactions = {},
            },
        },
    },
}

local orig_request = review.client.request
local threads_calls = 0
local pending_threads_cbs = {}
local hold_threads = false
review.client.request = function(client_self, method, params, cb)
    if method == "threads" then
        threads_calls = threads_calls + 1
        if hold_threads then
            pending_threads_cbs[#pending_threads_cbs + 1] = cb
            return
        end
        local copy = vim.deepcopy(pr_threads_fixture)
        vim.schedule(function()
            cb(nil, { threads = copy })
        end)
        return
    end
    return orig_request(client_self, method, params, cb)
end

conversation.refresh(review)
assert(vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(conv_buf, 0, -1, false), "\n")
    return text:find("Offline follow-up", 1, true) ~= nil
end), "refresh redraws visible conversation")

local rendered_text = table.concat(vim.api.nvim_buf_get_lines(conv_buf, 0, -1, false), "\n")
assert(rendered_text:find("should not appear in conversation", 1, true) == nil, rendered_text)
assert(rendered_text:find(render_threads.REACTION_EMOJI.THUMBS_UP .. " 2*", 1, true) ~= nil, "reactions rendered: " .. rendered_text)
assert(rendered_text:find("[failed]", 1, true) ~= nil, "failed badge rendered: " .. rendered_text)
assert(rendered_text:find("rate limited", 1, true) ~= nil, "syncError rendered: " .. rendered_text)

local conv_win = main_window.find(review)
vim.api.nvim_set_current_win(conv_win)
local other_range = review.conversation.layout.message_ranges[1]
local own_range = review.conversation.layout.message_ranges[2]

-- On non-own message: e and d error, X informs, + sends toggleReaction.
vim.api.nvim_win_set_cursor(conv_win, { other_range.first, 0 })
errors = {}
press_key("e")
assert(#errors == 1 and errors[1]:find("own comments", 1, true), vim.inspect(errors))

errors = {}
local delete_before = #read_requests("deleteMessage")
press_key("d")
assert(#errors == 1 and errors[1]:find("own comments", 1, true), vim.inspect(errors))
assert(#read_requests("deleteMessage") == delete_before, "forbidden d sends no RPC")

infos = {}
local retry_before = #read_requests("retryMessage")
press_key("X")
assert(#infos == 1 and infos[1]:find("not in a failed state", 1, true), vim.inspect(infos))
assert(#read_requests("retryMessage") == retry_before, "non-failed X sends no RPC")

local orig_select = vim.ui.select
vim.ui.select = function(items, _, on_choice)
    assert(vim.deep_equal(items, render_threads.REACTION_ORDER), "reaction picker uses REACTION_ORDER")
    on_choice("ROCKET")
end
local react_before = #read_requests("toggleReaction")
press_key("+")
vim.ui.select = orig_select
assert(vim.wait(3000, function()
    return #read_requests("toggleReaction") == react_before + 1
end), "+ sends toggleReaction")
local sent_react = read_requests("toggleReaction")[react_before + 1].params
assert(sent_react.messageId == "M_PR_OTHER" and sent_react.content == "ROCKET", vim.inspect(sent_react))

-- On own failed message: e opens compose.open_edit, d confirms -> deleteMessage, X -> retryMessage.
vim.api.nvim_win_set_cursor(conv_win, { own_range.first, 0 })
local orig_open_edit = require("jpr.comments.compose").open_edit
local edit_calls = {}
require("jpr.comments.compose").open_edit = function(sess, msg)
    edit_calls[#edit_calls + 1] = { sess = sess, msg = msg }
end
press_key("e")
require("jpr.comments.compose").open_edit = orig_open_edit
assert(#edit_calls == 1 and edit_calls[1].msg.id == "M_PR_OWN", vim.inspect(edit_calls))

local orig_confirm = vim.fn.confirm
vim.fn.confirm = function()
    return 2
end
press_key("d")
assert(#read_requests("deleteMessage") == delete_before, "cancelled confirm sends no deleteMessage")

vim.fn.confirm = function()
    return 1
end
press_key("d")
vim.fn.confirm = orig_confirm
assert(vim.wait(3000, function()
    return #read_requests("deleteMessage") == delete_before + 1
end), "confirmed d sends deleteMessage")
assert(read_requests("deleteMessage")[delete_before + 1].params.messageId == "M_PR_OWN")

press_key("X")
assert(vim.wait(3000, function()
    return #read_requests("retryMessage") == retry_before + 1
end), "X on failed message sends retryMessage")
assert(read_requests("retryMessage")[retry_before + 1].params.messageId == "M_PR_OWN")

-- Stale threads request_id guard.
hold_threads = true
conversation.refresh(review)
conversation.refresh(review)
assert(#pending_threads_cbs == 2, "two in-flight threads requests captured")
hold_threads = false
pending_threads_cbs[1](nil, {
    threads = {
        {
            id = "T_STALE",
            anchor = { kind = "pr", side = "RIGHT" },
            state = "open",
            messages = { { id = "M_STALE", author = "ghost", body = "STALE_TEXT", created = "2026-11-20T00:00:00Z", updated = "2026-11-20T00:00:00Z" } },
        },
    },
})
assert(not table.concat(vim.api.nvim_buf_get_lines(conv_buf, 0, -1, false), "\n"):find("STALE_TEXT", 1, true),
    "stale request_id response is dropped")
pending_threads_cbs[2](nil, { threads = pr_threads_fixture })

-- M.refresh does NOT fetch or redraw when conversation buffer is hidden.
view_mode.set("unified")
main_window.edit(review, conv_win, "README.md", 1)
local calls_while_hidden = threads_calls
conversation.refresh(review)
assert(threads_calls == calls_while_hidden, "refresh does nothing while conversation is hidden")

-- Reopen, then q closes cleanly and wipes buffer; M.close also wipes buffer.
session.conversation_current()
local reopened_buf = review.conversation.buf
assert(vim.api.nvim_buf_is_valid(reopened_buf), "conversation reopened")
vim.api.nvim_set_current_win(main_window.find(review))
press_key("q")
assert(review.conversation == nil, "q clears session.conversation")
assert(not vim.api.nvim_buf_is_valid(reopened_buf), "q wipes conversation buffer")
assert(vim.api.nvim_win_is_valid(review.panel.win), "panel stays open after q")

session.conversation_current()
local close_buf = review.conversation.buf
conversation.close(review)
assert(review.conversation == nil, "close clears session.conversation")
assert(not vim.api.nvim_buf_is_valid(close_buf), "close wipes conversation buffer")

review.client.request = orig_request

-- 4. :Jpr suggest refuses non-changed and non-worktree buffers.
local main_win = main_window.find(review)
vim.api.nvim_set_current_win(main_win)
vim.cmd.edit(vim.fn.fnameescape(worktree .. "/OTHER.md"))
errors = {}
session.suggest_current()
assert(#errors == 1, "suggest refuses unchanged file in worktree")

vim.cmd.edit(vim.fn.fnameescape(outside_file))
errors = {}
session.suggest_current()
assert(#errors == 1, "suggest refuses file outside worktree")

-- 5. :Jpr suggest on unsaved buffer edit (modified = true):
--    sends suggestFromEdit, replaces buffer with revertedText, clears modified when matching disk,
--    and does NOT rewrite disk.
main_window.edit(review, main_win, "README.md", 1)
local readme_buf = vim.api.nvim_win_get_buf(main_win)
assert(vim.wait(3000, function()
    return review.diff.applied[main_win] ~= nil
end), "diff applied on README.md")

vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "hello", "better" })
vim.bo[readme_buf].modified = true
vim.api.nvim_win_set_cursor(main_win, { 2, 0 })

local writefile_calls = 0
local orig_writefile = vim.fn.writefile
vim.fn.writefile = function(...)
    writefile_calls = writefile_calls + 1
    return orig_writefile(...)
end

local suggest_before = #read_requests("suggestFromEdit")
session.suggest_current()
assert(vim.wait(3000, function()
    return #read_requests("suggestFromEdit") == suggest_before + 1
        and vim.bo[readme_buf].modified == false
end), "unsaved single-hunk suggest reverts buffer and clears modified")
vim.fn.writefile = orig_writefile

local sent_suggest = read_requests("suggestFromEdit")[suggest_before + 1].params
assert(sent_suggest.path == "README.md", vim.inspect(sent_suggest))
assert(sent_suggest.editedText == "hello\nbetter\n", vim.inspect(sent_suggest))
assert(sent_suggest.cursorLine == 2, vim.inspect(sent_suggest))
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(readme_buf, 0, -1, false), { "hello", "new" }))
assert(writefile_calls == 0, "did not unnecessarily rewrite disk when buffer already had modified=true")

-- 6. :Jpr suggest on saved buffer edit (modified = false): writes revertedText back to disk and keeps modified = false.
vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "hello", "saved_edit" })
vim.cmd("silent write")
assert(vim.bo[readme_buf].modified == false, "saved edit has modified = false")
assert(read_bytes(worktree .. "/README.md") == "hello\nsaved_edit\n")
vim.api.nvim_win_set_cursor(main_win, { 2, 0 })

session.suggest_current()
assert(vim.wait(3000, function()
    return read_bytes(worktree .. "/README.md") == "hello\nnew\n"
end), "saved edit writes revertedText back to disk")
assert(vim.bo[readme_buf].modified == false, "saved edit keeps modified = false")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(readme_buf, 0, -1, false), { "hello", "new" }))

-- 7. Two unsaved edits: reverting hunk 1 preserves hunk 2 and keeps modified = true.
write_bytes(worktree .. "/README.md", "line1\nline2\nline3\n")
vim.cmd("silent edit!")
vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "edit1", "line2", "edit3" })
vim.bo[readme_buf].modified = true
vim.api.nvim_win_set_cursor(main_win, { 1, 0 })

review.client.request = function(client_self, method, params, cb)
    if method == "suggestFromEdit" then
        vim.schedule(function()
            cb(nil, {
                suggested = {
                    anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 1, ["end"] = 1 },
                    suggestionBody = "```suggestion\nedit1\n```",
                    revertedText = "line1\nline2\nedit3\n",
                },
            })
        end)
        return
    end
    return orig_request(client_self, method, params, cb)
end

session.suggest_current()
assert(vim.wait(3000, function()
    local lines = vim.api.nvim_buf_get_lines(readme_buf, 0, -1, false)
    return lines[1] == "line1"
end), "hunk 1 reverted")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(readme_buf, 0, -1, false), { "line1", "line2", "edit3" }),
    "hunk 2 preserved")
assert(vim.bo[readme_buf].modified == true, "remaining unsaved hunk keeps modified = true")
assert(read_bytes(worktree .. "/README.md") == "line1\nline2\nline3\n", "disk untouched for unsaved multi-hunk")

-- 8. Trailing newline preservation: file WITHOUT trailing newline (saved and unsaved).
write_bytes(worktree .. "/README.md", "alpha\nbeta")
vim.cmd("silent edit!")
assert(vim.bo[readme_buf].eol == false, "loaded noeol file has eol = false")
vim.bo[readme_buf].fixeol = false
vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "alpha", "gamma" })
vim.cmd("silent write")
assert(read_bytes(worktree .. "/README.md") == "alpha\ngamma", "disk written without trailing newline")
vim.api.nvim_win_set_cursor(main_win, { 2, 0 })

local seen_edited_noeol
review.client.request = function(client_self, method, params, cb)
    if method == "suggestFromEdit" then
        seen_edited_noeol = params.editedText
        vim.schedule(function()
            cb(nil, {
                suggested = {
                    anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 },
                    suggestionBody = "```suggestion\ngamma\n```",
                    revertedText = "alpha\nbeta",
                },
            })
        end)
        return
    end
    return orig_request(client_self, method, params, cb)
end

session.suggest_current()
assert(vim.wait(3000, function()
    return read_bytes(worktree .. "/README.md") == "alpha\nbeta"
end), "reverted noeol file written without trailing newline")
assert(seen_edited_noeol == "alpha\ngamma", "editedText respected eol=false: " .. vim.inspect(seen_edited_noeol))
assert(vim.bo[readme_buf].eol == false, "buffer keeps eol = false")
assert(vim.bo[readme_buf].modified == false, "noeol saved revert keeps modified = false")

-- Also unsaved noeol matching disk clears modified without touching disk.
vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "alpha", "unsaved" })
vim.bo[readme_buf].modified = true
session.suggest_current()
assert(vim.wait(3000, function()
    return vim.bo[readme_buf].modified == false
end), "unsaved noeol revert matching disk clears modified")
assert(read_bytes(worktree .. "/README.md") == "alpha\nbeta")

-- Split mode suggest redraws threads without tearing down the split.
review.client.request = orig_request
write_bytes(worktree .. "/README.md", "hello\nnew\n")
vim.cmd("silent edit!")
view_mode.set("split")
require("jpr.views.diff").redraw_all(review)
assert(vim.wait(3000, function()
    return review.diff.splits[main_win] ~= nil and vim.api.nvim_win_is_valid(review.diff.splits[main_win].base_win)
end), "split diff active for suggest")
local split_base_win = review.diff.splits[main_win].base_win
vim.api.nvim_set_current_win(main_win)
vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "hello", "better" })
vim.bo[readme_buf].modified = true
vim.api.nvim_win_set_cursor(main_win, { 2, 0 })
local file_diffs_before_split_suggest = #read_requests("fileDiff")
session.suggest_current()
assert(vim.wait(3000, function()
    return vim.bo[readme_buf].modified == false and #read_requests("fileDiff") > file_diffs_before_split_suggest
end), "split mode suggest reverts buffer and redraws threads")
assert(vim.api.nvim_win_is_valid(split_base_win), "split base_win stays open")
view_mode.set("unified")

-- 9. Stale changedtick guard: editing buffer while suggestFromEdit is in flight drops callback.
local pending_suggest_cb
review.client.request = function(client_self, method, params, cb)
    if method == "suggestFromEdit" then
        pending_suggest_cb = cb
        return
    end
    return orig_request(client_self, method, params, cb)
end
vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "alpha", "first_edit" })
session.suggest_current()
assert(pending_suggest_cb ~= nil, "captured in-flight suggestFromEdit")
vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "alpha", "newer_edit" })
pending_suggest_cb(nil, {
    suggested = {
        anchor = { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 },
        suggestionBody = "```suggestion\nfirst_edit\n```",
        revertedText = "alpha\nbeta",
    },
})
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(readme_buf, 0, -1, false), { "alpha", "newer_edit" }),
    "stale changedtick callback does not overwrite newer buffer edits")

review.client.request = orig_request

-- 10. Visible stream window: :Jpr suggest on a saved edit invokes stream.refresh(session, true)
--     and refreshes the stream buffer with the reverted disk content.
view_mode.set("unified")
vim.bo[readme_buf].modified = false
write_bytes(worktree .. "/README.md", "hello\nsaved_edit\n")
local stream_view = require("jpr.views.stream")
review.client.request = function(client_self, method, params, cb)
    if method == "stream" then
        local disk_lines = vim.split(read_bytes(worktree .. "/README.md"):gsub("\n$", ""), "\n", { plain = true })
        local second_line = disk_lines[2] or ""
        vim.schedule(function()
            cb(nil, {
                mode = "unified",
                rows = {
                    { kind = "file", path = "README.md", additions = 1, deletions = 0, viewed = "UNVIEWED", folded = false },
                    { kind = "hunk", path = "README.md", header = "@@ -1,2 +1,2 @@", target = 1 },
                    {
                        kind = "line",
                        path = "README.md",
                        left = nil,
                        right = { line = 2, text = second_line, change = "added", words = {} },
                        target = 2,
                    },
                },
            })
        end)
        return
    end
    return orig_request(client_self, method, params, cb)
end

stream_view.show(review, { focus = true })
assert(vim.wait(3000, function()
    if not stream_view.is_visible(review) then
        return false
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(review.stream.buffers.main, 0, -1, false), "\n")
    return text:find("saved_edit", 1, true) ~= nil
end), "stream initially shows saved_edit from disk")

vim.cmd("vsplit " .. vim.fn.fnameescape(worktree .. "/README.md"))
local edit_win = vim.api.nvim_get_current_win()
local edit_buf = vim.api.nvim_win_get_buf(edit_win)
vim.cmd("silent edit!")
assert(vim.bo[edit_buf].modified == false, "saved edit buffer starts unmodified")
vim.api.nvim_win_set_cursor(edit_win, { 2, 0 })

local stream_refresh_calls = {}
local orig_stream_refresh = stream_view.refresh
stream_view.refresh = function(sess, force)
    stream_refresh_calls[#stream_refresh_calls + 1] = {
        sess = sess,
        force = force,
        disk = read_bytes(worktree .. "/README.md"),
    }
    return orig_stream_refresh(sess, force)
end

session.suggest_current()
assert(vim.wait(3000, function()
    if read_bytes(worktree .. "/README.md") ~= "hello\nnew\n" then
        return false
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(review.stream.buffers.main, 0, -1, false), "\n")
    return text:find("new", 1, true) ~= nil and text:find("saved_edit", 1, true) == nil
end), "suggest refreshes visible stream buffer with reverted disk content")

stream_view.refresh = orig_stream_refresh
local saw_post_revert_refresh = false
for _, call in ipairs(stream_refresh_calls) do
    if call.sess == review and call.force == true and call.disk == "hello\nnew\n" then
        saw_post_revert_refresh = true
    end
end
assert(saw_post_revert_refresh,
    "suggest called stream.refresh(session, true) after reverting disk: " .. vim.inspect(stream_refresh_calls))

review.client.request = orig_request
session.close_current()
print("conversation_suggest_spec: ok")
