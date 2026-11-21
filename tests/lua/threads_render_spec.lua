local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local render = require("jpr.render.threads")

local draft_thread = {
    threadId = "T1",
    displayLine = 4,
    kind = "draft",
    state = "open",
    outdated = false,
    messageCount = 2,
    firstAuthor = "pablo",
    snippet = "consider splitting this helper",
    messages = {
        {
            id = "M1",
            author = "pablo",
            body = "consider splitting this helper",
            created = "2026-11-20T01:00:00Z",
            updated = "2026-11-20T01:00:00Z",
            sync = "draft",
            viewerDidAuthor = true,
            reactions = { { content = "THUMBS_UP", count = 2, viewerHasReacted = true } },
        },
        {
            id = "M2",
            author = "alice",
            body = "good catch\nwill do",
            created = "2026-11-20T01:05:00Z",
            updated = "2026-11-20T01:05:00Z",
            sync = "published",
            viewerDidAuthor = false,
            reactions = {},
        },
    },
}

local sign_text, sign_highlight = render.pick_sign({ draft_thread })
assert(sign_text == "✎" and sign_highlight == "JprThreadDraft", sign_text .. " " .. sign_highlight)

local resolved_thread = vim.tbl_extend("force", vim.deepcopy(draft_thread), { kind = "published", state = "resolved" })
local resolved_sign, resolved_highlight = render.pick_sign({ resolved_thread })
assert(resolved_sign == "✓" and resolved_highlight == "JprThreadResolved", resolved_sign .. " " .. resolved_highlight)

local failed_thread = vim.tbl_extend("force", vim.deepcopy(draft_thread), { kind = "failed" })
local failed_sign, failed_highlight = render.pick_sign({ resolved_thread, draft_thread, failed_thread })
assert(failed_sign == "!" and failed_highlight == "JprThreadFailed", failed_sign .. " " .. failed_highlight)

local open_published_thread = vim.tbl_extend("force", vim.deepcopy(draft_thread), { kind = "published", state = "open" })
local published_sign, published_highlight = render.pick_sign({ resolved_thread, open_published_thread })
assert(published_sign == "💬" and published_highlight == "JprThreadPublished", published_sign .. " " .. published_highlight)

local eol_chunks = render.create_eol_chunks_from_threads({ draft_thread })
assert(eol_chunks[1][1]:find("@pablo", 1, true) and eol_chunks[1][1]:find("(+1)", 1, true), vim.inspect(eol_chunks))

local missing_messages_thread = {
    threadId = "T_EMPTY",
    displayLine = 2,
    kind = "published",
    state = "open",
    firstAuthor = "bob",
    snippet = "no messages field",
}
local missing_messages_eol = render.create_eol_chunks_from_threads({ missing_messages_thread })
assert(missing_messages_eol[1][1]:find("@bob: no messages field", 1, true), vim.inspect(missing_messages_eol))

local marks = render.create_extmarks_from_threads({ draft_thread }, 10, { expanded = false })
assert(#marks == 1 and marks[1].line == 3 and marks[1].opts.sign_text == "✎", vim.inspect(marks))

local expanded_marks = render.create_extmarks_from_threads({ draft_thread }, 10, { expanded = true })
assert(#expanded_marks == 2 and expanded_marks[2].opts.virt_lines ~= nil, vim.inspect(expanded_marks))

local file_level_thread = vim.tbl_extend("force", vim.deepcopy(draft_thread), { threadId = "T_FILE", displayLine = 0 })
local file_marks = render.create_extmarks_from_threads({ file_level_thread }, 10, { expanded = false })
assert(
    #file_marks == 1 and file_marks[1].line == 0 and file_marks[1].opts.virt_lines_above == true and file_marks[1].opts.virt_lines ~= nil,
    vim.inspect(file_marks)
)
assert(file_marks[1].opts.virt_lines[1][1][1]:find("[file thread]", 1, true) ~= nil, vim.inspect(file_marks))

local popup = render.create_popup_layout_from_threads({ draft_thread })
assert(#popup.message_ranges == 2, vim.inspect(popup))
assert(popup.message_ranges[1].message_id == "M1" and popup.message_ranges[2].message_id == "M2", vim.inspect(popup))
assert(table.concat(popup.lines, "\n"):find("👍 2*", 1, true) ~= nil, vim.inspect(popup.lines))

local first_range = popup.message_ranges[1]
local second_range = popup.message_ranges[2]
assert(render.find_message_at_line(popup, first_range.first).message_id == "M1", "first line maps to M1")
assert(render.find_message_at_line(popup, second_range.last).message_id == "M2", "last line of M2 maps to M2")
assert(render.find_message_at_line(popup, #popup.lines).message_id == "M2", "footer line falls back to last message")

-- Empty threads, nil threads, and empty messages guards.
local empty_sign, empty_highlight = render.pick_sign({})
assert(empty_sign == "✓" and empty_highlight == "JprThreadResolved", empty_sign .. " " .. empty_highlight)
local nil_sign, nil_highlight = render.pick_sign(nil)
assert(nil_sign == "✓" and nil_highlight == "JprThreadResolved", nil_sign .. " " .. nil_highlight)

local empty_eol_chunks = render.create_eol_chunks_from_threads({})
assert(#empty_eol_chunks == 0, vim.inspect(empty_eol_chunks))
local nil_eol_chunks = render.create_eol_chunks_from_threads(nil)
assert(#nil_eol_chunks == 0, vim.inspect(nil_eol_chunks))

assert(#render.create_expanded_virt_lines_from_threads({}, false) == 0, "empty threads -> no virt_lines")
assert(#render.create_expanded_virt_lines_from_threads(nil, false) == 0, "nil threads -> no virt_lines")
local empty_messages_thread = { threadId = "T_NO_MSG", displayLine = 1, kind = "draft", state = "open", messages = {} }
assert(#render.create_expanded_virt_lines_from_threads({ empty_messages_thread }, false) == 0, "empty messages -> no virt_lines")

local empty_popup = render.create_popup_layout_from_threads({})
assert(#empty_popup.message_ranges == 0 and #empty_popup.lines == 1, vim.inspect(empty_popup))
local nil_popup = render.create_popup_layout_from_threads(nil)
assert(#nil_popup.message_ranges == 0 and #nil_popup.lines == 1, vim.inspect(nil_popup))
local empty_messages_popup = render.create_popup_layout_from_threads({ empty_messages_thread })
assert(#empty_messages_popup.message_ranges == 0 and #empty_messages_popup.lines == 2, vim.inspect(empty_messages_popup))

-- Empty buffer (line_count = 0): displayLine = 0 stays above line 0, displayLine = 3 clamps to line 0.
local empty_buffer_file = render.create_extmarks_from_threads({ file_level_thread }, 0, { expanded = false })
assert(
    #empty_buffer_file == 1 and empty_buffer_file[1].line == 0 and empty_buffer_file[1].opts.virt_lines_above == true,
    vim.inspect(empty_buffer_file)
)
local empty_buffer_line3 = render.create_extmarks_from_threads({ draft_thread }, 0, { expanded = false })
assert(#empty_buffer_line3 == 1 and empty_buffer_line3[1].line == 0 and empty_buffer_line3[1].opts.sign_text == "✎", vim.inspect(empty_buffer_line3))

-- Untrusted multi-line firstAuthor, author, snippet, syncError, and reaction content never leak newlines into single lines.
local untrusted_thread = {
    threadId = "T_UNTRUSTED",
    displayLine = 2,
    kind = "failed",
    state = "open",
    firstAuthor = "bad\nauthor",
    snippet = "line one\nline two",
    messages = {
        {
            id = "M_BAD",
            author = "evil\r\nuser",
            body = "hello",
            created = "2026-11-20T01:00:00Z",
            updated = "2026-11-20T01:00:00Z",
            sync = "failed",
            syncError = "boom\nretry later",
            reactions = { { content = "CUSTOM\nEMOJI", count = 1, viewerHasReacted = false } },
        },
    },
}
local untrusted_eol = render.create_eol_chunks_from_threads({ untrusted_thread })
assert(not untrusted_eol[1][1]:find("[\r\n]"), vim.inspect(untrusted_eol))
assert(untrusted_eol[1][1]:find("@bad author: line one line two", 1, true), vim.inspect(untrusted_eol))

local untrusted_virt_lines = render.create_expanded_virt_lines_from_threads({ untrusted_thread }, false)
for _, virt_line in ipairs(untrusted_virt_lines) do
    assert(not virt_line[1][1]:find("[\r\n]"), vim.inspect(virt_line))
end
assert(untrusted_virt_lines[1][1][1]:find("@evil user", 1, true), vim.inspect(untrusted_virt_lines))

local untrusted_popup = render.create_popup_layout_from_threads({ untrusted_thread })
for _, line in ipairs(untrusted_popup.lines) do
    assert(not line:find("[\r\n]"), vim.inspect(line))
end
local joined_untrusted = table.concat(untrusted_popup.lines, "\n")
assert(joined_untrusted:find("@evil user", 1, true) ~= nil, joined_untrusted)
assert(joined_untrusted:find("error: boom retry later", 1, true) ~= nil, joined_untrusted)
assert(joined_untrusted:find("CUSTOM EMOJI 1", 1, true) ~= nil, joined_untrusted)

-- find_message_at_line: empty ranges and 2-thread popup behavior.
assert(render.find_message_at_line({ message_ranges = {} }, 1) == nil, "empty message_ranges returns nil")
assert(render.find_message_at_line(nil, 1) == nil, "nil popup_layout returns nil")

local second_thread = {
    threadId = "T2",
    displayLine = 4,
    kind = "published",
    state = "open",
    messages = {
        {
            id = "M3",
            author = "carol",
            body = "second thread",
            created = "2026-11-20T02:00:00Z",
            updated = "2026-11-20T02:00:00Z",
            sync = "published",
        },
    },
}
local two_popup = render.create_popup_layout_from_threads({ draft_thread, second_thread })
assert(#two_popup.message_ranges == 3, vim.inspect(two_popup.message_ranges))
local range_m1 = two_popup.message_ranges[1]
local range_m2 = two_popup.message_ranges[2]
local range_m3 = two_popup.message_ranges[3]
assert(render.find_message_at_line(two_popup, 1).message_id == "M1", "Thread 1 header line maps to M1")
assert(render.find_message_at_line(two_popup, range_m1.last + 1).message_id == "M1", "inter-message gap in Thread 1 maps to M1")
assert(render.find_message_at_line(two_popup, range_m2.last + 1).message_id == "M2", "gap after Thread 1 maps to M2")
assert(render.find_message_at_line(two_popup, range_m3.first).message_id == "M3", "Thread 2 message maps to M3")
assert(render.find_message_at_line(two_popup, #two_popup.lines).message_id == "M3", "footer maps to last message M3")

print("threads_render_spec: ok")
