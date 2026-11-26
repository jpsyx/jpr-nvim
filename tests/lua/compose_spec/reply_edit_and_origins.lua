-- Compose specs: open_reply, open_edit, destination toggles, open_promote, and local-only lock.
return function(ctx)
    local compose = ctx.compose
    local helpers = ctx.helpers
    local log = ctx.log
    local review = ctx.review
    local line_anchor = ctx.line_anchor
    local find_compose_win = ctx.find_compose_win

    -- 5. open_reply uses [GitHub draft] Reply when draftCount > 0 else [GitHub reply] Reply, and <C-s> sends reply.
    -- Threads without messages fall back to the single reply float with no history pane.
    review.view.draftCount = 0
    compose.open_reply(review, { threadId = "T1", anchor = line_anchor })
    local reply_win_immediate = find_compose_win()
    assert(helpers.win_title(reply_win_immediate):find("[GitHub reply] Reply", 1, true) ~= nil, helpers.win_title(reply_win_immediate))
    assert(review.compose.history_win == nil and review.compose.history_buf == nil, "empty thread opens single reply float")
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

    ctx.captured.infos = {}
    compose.open_promote(review, {
        id = "loc-done",
        origin = "local",
        promotedTo = "PRRT_99",
        anchor = line_anchor,
        messages = { { id = "loc-m-done", body = "Already promoted" } },
    })
    assert(helpers.find_floating_win("Promote") == nil, "open_promote does not open window for already-promoted thread")
    assert(#ctx.captured.infos == 1 and ctx.captured.infos[1]:find("already promoted", 1, true) ~= nil, vim.inspect(ctx.captured.infos))

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

    -- 6e. Local-only files lock compose to origin="local", disable <C-g>/<M-s> flip, and show footer hint.
    local saved_files = review.view.files
    review.view.files = {
        { path = "README.md", additions = 2, deletions = 1, viewed = "UNVIEWED", threads = 1 },
        { path = "unpushed.lua", additions = 3, deletions = 0, viewed = "UNVIEWED", threads = 0, isLocalOnly = true },
    }
    review.compose_destination = "github"
    local local_only_anchor = { file = "unpushed.lua", kind = "line", side = "RIGHT", start = 1, ["end"] = 1 }
    compose.open_new(review, local_only_anchor, { suggest = false })
    local locked_win = helpers.find_floating_win("Local")
    assert(locked_win ~= nil and vim.api.nvim_win_is_valid(locked_win), "local-only compose opens in local mode")
    assert(helpers.win_title(locked_win):find("[Local → agent] unpushed.lua:1", 1, true) ~= nil, helpers.win_title(locked_win))
    local locked_config = vim.api.nvim_win_get_config(locked_win)
    local footer_text = type(locked_config.footer) == "string" and locked_config.footer
        or table.concat(vim.tbl_map(function(chunk)
            return type(chunk) == "table" and chunk[1] or tostring(chunk)
        end, locked_config.footer or {}), "")
    assert(footer_text:find("local only (unpushed file)", 1, true) ~= nil, "footer notes local only: " .. footer_text)
    helpers.press_key("<C-g>")
    assert(helpers.win_title(locked_win):find("[Local → agent] unpushed.lua:1", 1, true) ~= nil, "<C-g> cannot flip local-only compose")
    local locked_before = #helpers.read_requests(log, "comment")
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(locked_win), 0, -1, false, { "Local note on unpushed file" })
    helpers.press_key("<M-s>")
    assert(vim.api.nvim_win_is_valid(locked_win), "<M-s> does not submit to github for local-only file")
    assert(#helpers.read_requests(log, "comment") == locked_before, "<M-s> sends no RPC for local-only file")
    helpers.press_key("<C-s>")
    assert(vim.wait(3000, function()
        return #helpers.read_requests(log, "comment") == locked_before + 1
    end), "<C-s> submits local comment on local-only file")
    assert(helpers.read_requests(log, "comment")[locked_before + 1].params.origin == "local", "submitted origin is local")
    review.view.files = saved_files
    review.compose_destination = nil

    -- 6f. Docked two-pane reply modal: read-only thread history above reply box, pane switching, shared cancel/submit/wipeout, and small-terminal geometry.
    local reply_history = require("jpr.comments.reply_history")
    local small_geom = reply_history.compute_stacked_geometry(20, 80, 30)
    assert(small_geom.history_height >= 4 and small_geom.reply_height >= 4, vim.inspect(small_geom))
    assert(small_geom.history_row >= 1, vim.inspect(small_geom))
    assert(small_geom.reply_row == small_geom.history_row + small_geom.history_height + 2, vim.inspect(small_geom))
    assert(small_geom.reply_row + small_geom.reply_height + 2 <= 20, vim.inspect(small_geom))

    local long_tail_lines = {}
    for idx = 1, 24 do
        long_tail_lines[idx] = ("tail detail %d"):format(idx)
    end
    local thread_with_history = {
        threadId = "T_HIST",
        state = "open",
        anchor = line_anchor,
        messages = {
            {
                id = "M_H1",
                author = "alice",
                body = "Original question",
                created = "2026-11-20T00:00:00Z",
                updated = "2026-11-20T00:00:00Z",
                sync = "published",
                viewerDidAuthor = false,
                reactions = {},
            },
            {
                id = "M_H2",
                author = "bob",
                body = table.concat(long_tail_lines, "\n"),
                created = "2026-11-20T00:01:00Z",
                updated = "2026-11-20T00:01:00Z",
                sync = "published",
                viewerDidAuthor = false,
                reactions = {},
            },
        },
    }

    review.view.draftCount = 0
    compose.open_reply(review, thread_with_history)
    local docked_reply_win = review.compose.win
    local docked_reply_buf = review.compose.buf
    local history_win = review.compose.history_win
    local history_buf = review.compose.history_buf
    assert(docked_reply_win and vim.api.nvim_win_is_valid(docked_reply_win), "reply window opens")
    assert(history_win and vim.api.nvim_win_is_valid(history_win), "history window opens")
    assert(vim.api.nvim_get_current_win() == docked_reply_win, "focus starts in reply pane")
    assert(vim.bo[history_buf].modifiable == false, "history buffer is read-only")

    local history_lines = vim.api.nvim_buf_get_lines(history_buf, 0, -1, false)
    local history_text = table.concat(history_lines, "\n")
    assert(history_text:find("Original question", 1, true) ~= nil, history_text)
    assert(history_text:find("tail detail 1", 1, true) ~= nil, history_text)
    assert(history_text:find("[r]eply", 1, true) == nil, "history pane omits popup action footer")

    local history_cfg = vim.api.nvim_win_get_config(history_win)
    local reply_cfg = vim.api.nvim_win_get_config(docked_reply_win)
    assert(history_cfg.width == reply_cfg.width and history_cfg.col == reply_cfg.col, "panes share width and column")
    assert(history_cfg.row + history_cfg.height + 2 == reply_cfg.row, "reply pane docks directly below history pane")

    local bob_header_line = helpers.find_line_number(history_lines, "@bob")
    local history_topline = vim.api.nvim_win_call(history_win, function()
        return vim.fn.winsaveview().topline
    end)
    assert(vim.api.nvim_win_get_cursor(history_win)[1] == bob_header_line, "history cursor starts at last message")
    assert(history_topline == bob_header_line, "tall last comment in history snaps topline to last message start")

    -- Pane switching via <Tab> and <C-w>k / <C-w>j in Normal mode.
    helpers.press_key("<Tab>")
    assert(vim.api.nvim_get_current_win() == history_win, "<Tab> from reply focuses history pane")
    helpers.press_key("<Tab>")
    assert(vim.api.nvim_get_current_win() == docked_reply_win, "<Tab> from history focuses reply pane")
    helpers.press_key("<C-w>k")
    assert(vim.api.nvim_get_current_win() == history_win, "<C-w>k from reply focuses history pane")
    helpers.press_key("<C-w>j")
    assert(vim.api.nvim_get_current_win() == docked_reply_win, "<C-w>j from history focuses reply pane")

    -- Dirty-check cancel triggered from the history pane.
    vim.api.nvim_buf_set_lines(docked_reply_buf, 0, -1, false, { "Draft in progress" })
    helpers.press_key("<Tab>")
    assert(vim.api.nvim_get_current_win() == history_win)
    local original_confirm = vim.fn.confirm
    local confirm_calls = 0
    vim.fn.confirm = function()
        confirm_calls = confirm_calls + 1
        return 2
    end
    helpers.press_key("q")
    assert(confirm_calls == 1, "q in history pane checks dirty reply buffer")
    assert(vim.api.nvim_win_is_valid(docked_reply_win) and vim.api.nvim_win_is_valid(history_win), "Keep editing preserves both panes")

    vim.fn.confirm = function()
        confirm_calls = confirm_calls + 1
        return 1
    end
    helpers.press_key("<Esc>")
    vim.fn.confirm = original_confirm
    assert(confirm_calls == 2, "<Esc> in history pane prompts to discard")
    assert(not vim.api.nvim_win_is_valid(docked_reply_win) and not vim.api.nvim_win_is_valid(history_win), "Discard closes both panes")

    -- Submitting sends only reply buffer text and closes both panes.
    compose.open_reply(review, thread_with_history)
    local submit_reply_win = review.compose.win
    local submit_reply_buf = review.compose.buf
    local submit_history_win = review.compose.history_win
    local replies_before_docked = #helpers.read_requests(log, "reply")
    vim.api.nvim_buf_set_lines(submit_reply_buf, 0, -1, false, { "My reply" })
    helpers.press_key("<C-s>")
    assert(not vim.api.nvim_win_is_valid(submit_reply_win) and not vim.api.nvim_win_is_valid(submit_history_win), "<C-s> closes both panes")
    assert(vim.wait(3000, function()
        return #helpers.read_requests(log, "reply") == replies_before_docked + 1
    end), "docked reply RPC sent")
    local docked_sent = helpers.read_requests(log, "reply")[replies_before_docked + 1].params
    assert(docked_sent.threadId == "T_HIST" and docked_sent.body == "My reply", vim.inspect(docked_sent))

    -- Wiping either buffer tears down its companion with no orphan float.
    compose.open_reply(review, thread_with_history)
    local wipe_reply_win = review.compose.win
    local wipe_history_buf = review.compose.history_buf
    vim.api.nvim_buf_delete(wipe_history_buf, { force = true })
    assert(not vim.api.nvim_win_is_valid(wipe_reply_win), "deleting history buffer closes reply pane")

    compose.open_reply(review, thread_with_history)
    local wipe_reply_buf = review.compose.buf
    local wipe_history_win = review.compose.history_win
    vim.api.nvim_buf_delete(wipe_reply_buf, { force = true })
    assert(not vim.api.nvim_win_is_valid(wipe_history_win), "deleting reply buffer closes history pane")
end
