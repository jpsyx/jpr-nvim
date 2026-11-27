-- Popup initial-scroll specs: short threads, tall threads with short trailing
-- comments, multi-line tall trailing comments, and line-wrapped trailing comments.
return function(context)
    local review = context.review
    local popup_module = require("jpr.comments.popup")

    local function build_numbered_body(prefix, num_lines)
        local body_lines = {}
        for idx = 1, num_lines do
            body_lines[idx] = ("%s %d"):format(prefix, idx)
        end
        return table.concat(body_lines, "\n")
    end

    local function win_topline(target_win)
        return vim.api.nvim_win_call(target_win, function()
            return vim.fn.winsaveview().topline
        end)
    end

    local function build_two_message_thread(first_body, second_body)
        return {
            threadId = "T_SCROLL",
            displayLine = 2,
            kind = "published",
            state = "open",
            outdated = false,
            messageCount = 2,
            firstAuthor = "alice",
            snippet = "first",
            messages = {
                {
                    id = "M_S1",
                    author = "alice",
                    body = first_body,
                    created = "2026-11-20T00:00:00Z",
                    updated = "2026-11-20T00:00:00Z",
                    sync = "published",
                    viewerDidAuthor = false,
                    reactions = {},
                },
                {
                    id = "M_S2",
                    author = "bob",
                    body = second_body,
                    created = "2026-11-20T00:01:00Z",
                    updated = "2026-11-20T00:01:00Z",
                    sync = "published",
                    viewerDidAuthor = false,
                    reactions = {},
                },
            },
        }
    end

    popup_module.open(review, { build_two_message_thread("short one", "short two") })
    local short_win = review.popup.win
    local short_last_first = review.popup.layout.message_ranges[2].first
    assert(vim.api.nvim_win_get_cursor(short_win)[1] == short_last_first, "short thread cursor starts on last comment")
    assert(win_topline(short_win) == 1, "short thread keeps topline at 1")
    popup_module.close(review)

    popup_module.open(review, { build_two_message_thread(build_numbered_body("old", 25), "latest line 1\nlatest line 2") })
    local tall_short_last_win = review.popup.win
    local tall_short_last_first = review.popup.layout.message_ranges[2].first
    local tall_short_topline = win_topline(tall_short_last_win)
    assert(vim.api.nvim_win_get_cursor(tall_short_last_win)[1] == tall_short_last_first, "tall thread cursor starts on last comment")
    assert(tall_short_topline > 1 and tall_short_topline <= tall_short_last_first, "tall thread scrolls to bottom while keeping last comment start visible")
    popup_module.close(review)

    popup_module.open(review, { build_two_message_thread("intro 1\nintro 2\nintro 3", build_numbered_body("long reply", 30)) })
    local tall_long_last_win = review.popup.win
    local tall_long_last_first = review.popup.layout.message_ranges[2].first
    assert(vim.api.nvim_win_get_cursor(tall_long_last_win)[1] == tall_long_last_first, "long last comment cursor starts on last comment")
    assert(win_topline(tall_long_last_win) == tall_long_last_first, "long last comment snaps topline to start of last comment")
    popup_module.close(review)

    popup_module.open(review, { build_two_message_thread("intro line", string.rep("wrappedword ", 220)) })
    local wrapped_win = review.popup.win
    local wrapped_last_first = review.popup.layout.message_ranges[2].first
    assert(vim.api.nvim_win_get_cursor(wrapped_win)[1] == wrapped_last_first, "wrapped last comment cursor starts on last comment")
    assert(win_topline(wrapped_win) == wrapped_last_first, "wrapped last comment exceeding popup height snaps topline to start of last comment")
    popup_module.close(review)
end
