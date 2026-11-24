-- Section 8: live local anchor extmarks, updateLocalAnchors on :write, and vim.NIL split bounds.
local function find_update_by_id(updates, target_id)
    for _, item in ipairs(updates or {}) do
        if item.threadId == target_id then
            return item
        end
    end
    return nil
end

local function create_local_thread(thread_id, anchor, display_line, message_id, body)
    return {
        threadId = thread_id,
        origin = "local",
        kind = "local",
        anchor = anchor,
        displayLine = display_line,
        state = "open",
        outdated = false,
        messageCount = 1,
        firstAuthor = "reviewer",
        snippet = body,
        messages = {
            { id = message_id, author = "reviewer", body = body, viewerDidAuthor = true, reactions = {} },
        },
    }
end

local function create_local_anchor_fixtures()
    return {
        create_local_thread(
            "loc-1",
            { file = "README.md", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 },
            2,
            "loc-m-1",
            "local line note"
        ),
        create_local_thread(
            "loc-range",
            { file = "README.md", kind = "range", side = "RIGHT", start = 1, ["end"] = 3 },
            3,
            "loc-m-2",
            "local range note"
        ),
        create_local_thread(
            "loc-file",
            { file = "README.md", kind = "file", side = "RIGHT" },
            0,
            "loc-m-3",
            "local file note"
        ),
    }
end

local function create_eof_anchor_fixtures()
    return {
        create_local_thread(
            "loc-eof",
            { file = "README.md", kind = "line", side = "RIGHT", start = 5, ["end"] = 5 },
            5,
            "loc-m-eof",
            "eof"
        ),
        create_local_thread(
            "loc-range-eof",
            { file = "README.md", kind = "range", side = "RIGHT", start = 2, ["end"] = 5 },
            5,
            "loc-m-eof",
            "eof"
        ),
    }
end

local function test_live_local_anchor_updates(context)
    context.session.toggle_view()
    assert(context.view_mode.get() == "unified", "switched back to unified mode")
    local fixtures = create_local_anchor_fixtures()
    context.mock_state.threads = {
        fixtures[1],
        fixtures[2],
        fixtures[3],
        context.mock_state.left_thread,
        context.mock_state.right_thread,
    }
    local calls_before = context.mock_state.file_diff_calls
    context.session.on_notification(context.review, "event", { type = "threadsChanged", view = context.review.view })
    assert(vim.wait(3000, function()
        return context.mock_state.file_diff_calls > calls_before
            and #context.threads_view.threads_at_cursor(context.review, context.buf, 2) >= 2
    end), "unified buffer draws local and github threads")

    vim.api.nvim_set_current_win(context.win)
    local updates_before = #context.helpers.read_requests(context.log, "updateLocalAnchors")
    vim.cmd("silent write")
    vim.wait(100, function()
        return false
    end)
    assert(#context.helpers.read_requests(context.log, "updateLocalAnchors") == updates_before, "no updateLocalAnchors sent when lines did not shift")

    vim.api.nvim_buf_set_lines(context.buf, 0, 0, false, { "top 1", "top 2" })
    vim.cmd("silent write")
    assert(vim.wait(3000, function()
        return #context.helpers.read_requests(context.log, "updateLocalAnchors") == updates_before + 1
    end), "updateLocalAnchors sent when local anchors shifted on :write")
    local sent_params = context.helpers.read_requests(context.log, "updateLocalAnchors")[updates_before + 1].params
    assert(sent_params.path == "README.md", vim.inspect(sent_params))
    assert(#sent_params.updates == 2, "only RIGHT line/range local threads emitted: " .. vim.inspect(sent_params.updates))
    assert(vim.deep_equal(find_update_by_id(sent_params.updates, "loc-1"), { threadId = "loc-1", start = 4, ["end"] = 4 }))
    assert(vim.deep_equal(find_update_by_id(sent_params.updates, "loc-range"), { threadId = "loc-range", start = 3, ["end"] = 5 }))
end

local function test_github_only_does_not_emit_anchor_updates(context)
    context.mock_state.threads = { context.mock_state.right_thread }
    local calls_before = context.mock_state.file_diff_calls
    context.session.on_notification(context.review, "event", { type = "threadsChanged", view = context.review.view })
    assert(vim.wait(3000, function()
        return context.mock_state.file_diff_calls > calls_before
            and #context.threads_view.threads_at_cursor(context.review, context.buf, 2) == 1
    end), "github-only thread redrawn")
    local github_only_before = #context.helpers.read_requests(context.log, "updateLocalAnchors")
    vim.api.nvim_buf_set_lines(context.buf, 0, 0, false, { "top 3", "top 4" })
    vim.cmd("silent write")
    vim.wait(100, function()
        return false
    end)
    assert(#context.helpers.read_requests(context.log, "updateLocalAnchors") == github_only_before, "non-local threads never emit updateLocalAnchors")
end

local function test_eof_deletion_and_clamping(context)
    vim.api.nvim_buf_set_lines(context.buf, 0, -1, false, { "L1", "L2", "L3", "L4", "L5" })
    context.mock_state.threads = create_eof_anchor_fixtures()
    local calls_before = context.mock_state.file_diff_calls
    context.session.on_notification(context.review, "event", { type = "threadsChanged", view = context.review.view })
    assert(vim.wait(3000, function()
        return context.mock_state.file_diff_calls > calls_before
            and #context.threads_view.threads_at_cursor(context.review, context.buf, 5) == 2
    end), "EOF threads drawn on 5-line buffer")
    local updates_before = #context.helpers.read_requests(context.log, "updateLocalAnchors")
    vim.api.nvim_buf_set_lines(context.buf, 3, 5, false, {})
    vim.cmd("silent write")
    assert(vim.wait(3000, function()
        return #context.helpers.read_requests(context.log, "updateLocalAnchors") == updates_before + 1
    end), "clamped range updateLocalAnchors sent on EOF deletion")
    local sent_updates = context.helpers.read_requests(context.log, "updateLocalAnchors")[updates_before + 1].params.updates
    assert(#sent_updates == 1, "deleted EOF line thread is skipped: " .. vim.inspect(sent_updates))
    assert(vim.deep_equal(sent_updates[1], { threadId = "loc-range-eof", start = 2, ["end"] = 3 }))
end

local function test_update_error_still_refreshes(context)
    local fixtures = create_local_anchor_fixtures()
    context.mock_state.threads = { fixtures[1] }
    local calls_before = context.mock_state.file_diff_calls
    context.session.on_notification(context.review, "event", { type = "threadsChanged", view = context.review.view })
    assert(vim.wait(3000, function()
        return context.mock_state.file_diff_calls > calls_before
            and #context.threads_view.threads_at_cursor(context.review, context.buf, 2) == 1
    end), "local thread drawn before error write test")

    local base_request = context.review.client.request
    local anchor_errors = 0
    local original_error = context.jpr.error
    context.jpr.error = function() end
    context.review.client.request = function(client_self, method, params, callback)
        if method == "updateLocalAnchors" then
            anchor_errors = anchor_errors + 1
            vim.schedule(function()
                callback({ code = -32000, message = "simulated anchor error" }, nil)
            end)
            return
        end
        return base_request(client_self, method, params, callback)
    end

    local diff_calls_before = context.mock_state.file_diff_calls
    vim.api.nvim_buf_set_lines(context.buf, 0, 0, false, { "err top" })
    vim.cmd("silent write")
    assert(vim.wait(3000, function()
        return anchor_errors == 1 and context.mock_state.file_diff_calls > diff_calls_before
    end), "refresh_buffer still runs via on_error when updateLocalAnchors fails")
    context.jpr.error = original_error
    context.review.client.request = base_request
end

local function test_split_nil_anchor_bounds(context)
    local split_base_buf = vim.api.nvim_create_buf(false, true)
    local split_head_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(split_base_buf, 0, -1, false, { "base 1", "base 2", "base 3" })
    vim.api.nvim_buf_set_lines(split_head_buf, 0, -1, false, { "head 1", "head 2", "head 3" })
    context.threads_view.draw_split(context.review, split_base_buf, split_head_buf, {
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
    local nil_marks = context.get_thread_marks(split_base_buf)
    assert(#nil_marks == 2, "expected 2 marks with vim.NIL anchor bounds: " .. vim.inspect(nil_marks))
    assert(nil_marks[1][2] == 0 and nil_marks[2][2] == 1, "expected lines 1 and 2: " .. vim.inspect(nil_marks))
    vim.api.nvim_buf_delete(split_base_buf, { force = true })
    vim.api.nvim_buf_delete(split_head_buf, { force = true })
end

return function(context)
    test_live_local_anchor_updates(context)
    test_github_only_does_not_emit_anchor_updates(context)
    test_eof_deletion_and_clamping(context)
    test_update_error_still_refreshes(context)
    test_split_nil_anchor_bounds(context)
end
