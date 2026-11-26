local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local stream = require("jpr.render.stream")

local function create_cell(line, text, change, words)
    return { line = line, text = text, change = change, words = words or {} }
end
local x_word = { { start = 4, ["end"] = 5 } }
local rows = {
    { kind = "file", path = "a.rs", additions = 1, deletions = 1, viewed = "UNVIEWED", folded = false },
    { kind = "hunk", path = "a.rs", header = "@@ -1,2 +1,2 @@", target = 1 },
    { kind = "line", path = "a.rs", left = create_cell(1, "keep", "context"), right = create_cell(1, "keep", "context"), target = 1 },
    { kind = "line", path = "a.rs", left = create_cell(2, "x = 1", "removed", x_word), target = 2 },
    { kind = "line", path = "a.rs", right = create_cell(2, "x = 2", "added", x_word), target = 2 },
    { kind = "file", path = "b.rs", additions = 1, deletions = 0, viewed = "VIEWED", folded = true },
    { kind = "hunk", path = "b.rs", header = "@@ -0,0 +1,1 @@", target = 1 },
    { kind = "line", path = "b.rs", right = create_cell(1, "new", "added"), target = 1 },
    { kind = "file", path = "c.png", additions = 0, deletions = 0, viewed = "DISMISSED", folded = false },
    { kind = "note", path = "c.png", text = "binary file" },
}

local unified = stream.create_layout_from_stream({ mode = "unified", rows = rows })
local column = unified.columns[1]
assert(#unified.columns == 1, "one column")
assert(vim.deep_equal(column.lines, {
    "▾   a.rs  +1 -1",
    "@@ -1,2 +1,2 @@",
    "    1     1   keep",
    "    2       - x = 1",
    "          2 + x = 2",
    "▸ ✓ b.rs  +1 -0",
    "@@ -0,0 +1,1 @@",
    "          1 + new",
    "▾ ● c.png  +0 -0",
    "  binary file",
}), vim.inspect(column.lines))
assert(column.line_groups[1] == "JprFileHeader" and column.line_groups[2] == "JprHunk", "headers")
assert(column.line_groups[3] == nil, "context is not colored")
assert(column.line_groups[4] == "JprDiffDelete" and column.line_groups[5] == "JprDiffAdd", "changes")
assert(column.line_groups[10] == "JprMuted", "notes are muted")
assert(vim.deep_equal(column.highlights, {
    { line = 3, col_start = 18, col_end = 19, group = "JprDiffDeleteText" },
    { line = 4, col_start = 18, col_end = 19, group = "JprDiffAddText" },
}), vim.inspect(column.highlights))
assert(vim.deep_equal(unified.targets[4], { path = "a.rs", line = 2 }), "a removed line leads to its place")
assert(vim.deep_equal(unified.targets[6], { path = "b.rs", line = 1 }), "a header leads to the top")
assert(unified.targets[10] == nil, "a note leads nowhere")
assert(vim.deep_equal(unified.hunks, { 2, 7 }), vim.inspect(unified.hunks))
assert(vim.deep_equal(unified.folds, { { first = 6, last = 8 } }), "a viewed file folds starting at its header line")
assert(#unified.files == 3 and unified.files[2].line == 6 and unified.files[2].viewed == "VIEWED", vim.inspect(unified.files))

local note_only_folded = stream.create_layout_from_stream({
    mode = "unified",
    rows = {
        { kind = "file", path = "logo.png", additions = 0, deletions = 0, viewed = "VIEWED", folded = true },
        { kind = "note", path = "logo.png", text = "binary file" },
        { kind = "file", path = "empty.rs", additions = 0, deletions = 0, viewed = "VIEWED", folded = true },
    },
})
assert(
    vim.deep_equal(note_only_folded.folds, { { first = 1, last = 2 } }),
    "a 1-line note folds with its header, while a header-only file needs no fold: " .. vim.inspect(note_only_folded.folds)
)

local split = stream.create_layout_from_stream({
    mode = "split",
    rows = {
        rows[1],
        rows[2],
        rows[3],
        { kind = "line", path = "a.rs", left = create_cell(2, "x = 1", "removed", x_word), right = create_cell(2, "x = 2", "added", x_word), target = 2 },
        { kind = "line", path = "a.rs", right = create_cell(3, "y", "added"), target = 3 },
    },
})
assert(#split.columns == 2, "two columns")
assert(vim.deep_equal(split.columns[1].lines, { "▾   a.rs  +1 -1", "@@ -1,2 +1,2 @@", "    1   keep", "    2 - x = 1", "" }), vim.inspect(split.columns[1].lines))
assert(vim.deep_equal(split.columns[2].lines, { "▾   a.rs  +1 -1", "@@ -1,2 +1,2 @@", "    1   keep", "    2 + x = 2", "    3 + y" }), vim.inspect(split.columns[2].lines))
assert(split.columns[1].line_groups[5] == "JprDiffFiller", "filler keeps the columns aligned")
assert(split.columns[2].highlights[1].col_start == 12, "the split gutter is 8 bytes")
assert(vim.deep_equal(column.code_rows, {
    { line = 2, path = "a.rs", gutter_length = 14, text = "keep", change = "context", left_line = 1, right_line = 1, hunk_index = 1 },
    { line = 3, path = "a.rs", gutter_length = 14, text = "x = 1", change = "removed", left_line = 2, hunk_index = 1 },
    { line = 4, path = "a.rs", gutter_length = 14, text = "x = 2", change = "added", right_line = 2, hunk_index = 1 },
    { line = 7, path = "b.rs", gutter_length = 14, text = "new", change = "added", right_line = 1, hunk_index = 1 },
}), "unified code_rows excludes headers, hunks, and notes: " .. vim.inspect(column.code_rows))
assert(vim.deep_equal(split.columns[1].code_rows, {
    { line = 2, path = "a.rs", gutter_length = 8, text = "keep", change = "context", left_line = 1, hunk_index = 1 },
    { line = 3, path = "a.rs", gutter_length = 8, text = "x = 1", change = "removed", left_line = 2, hunk_index = 1 },
}), "split left code_rows excludes filler: " .. vim.inspect(split.columns[1].code_rows))
assert(vim.deep_equal(split.columns[2].code_rows, {
    { line = 2, path = "a.rs", gutter_length = 8, text = "keep", change = "context", right_line = 1, hunk_index = 1 },
    { line = 3, path = "a.rs", gutter_length = 8, text = "x = 2", change = "added", right_line = 2, hunk_index = 1 },
    { line = 4, path = "a.rs", gutter_length = 8, text = "y", change = "added", right_line = 3, hunk_index = 1 },
}), "split right code_rows includes all right-side code lines: " .. vim.inspect(split.columns[2].code_rows))

assert(stream.find_file_at_line(unified, 5).path == "a.rs" and stream.find_file_at_line(unified, 6).path == "b.rs", "find_file_at_line")
assert(stream.find_next_unviewed_file(unified, 1).path == "c.png", "a viewed file is skipped and a dismissed one is not")
assert(stream.find_next_unviewed_file(unified, 9).path == "a.rs", "wraps around to earlier unviewed file when none remain after")
assert(stream.find_next_unviewed_file(note_only_folded, 1) == nil, "nil when every file is viewed")
assert(stream.find_adjacent_line({ 2, 7 }, 2, 1) == 7 and stream.find_adjacent_line({ 2, 7 }, 7, 1) == nil, "next")
assert(stream.find_adjacent_line({ 2, 7 }, 7, -1) == 2 and stream.find_adjacent_line({ 2, 7 }, 2, -1) == nil, "previous")

local view = {
    pr = { headSha = "h", baseSha = "b" },
    threadCount = 1,
    draftCount = 0,
    queuedCount = 0,
    files = { { path = "a.rs", additions = 1, deletions = 1, viewed = "UNVIEWED", threads = 1 } },
}
local key = stream.build_key_from_view(view)
assert(stream.build_key_from_view(view) == key, "the same view, the same key")
view.files[1].viewed = "VIEWED"
assert(stream.build_key_from_view(view) ~= key, "a viewed change changes the key")

local thread_key_base = stream.build_key_from_view(view)
local with_more_threads = vim.deepcopy(view)
with_more_threads.threadCount = 2
assert(stream.build_key_from_view(with_more_threads) ~= thread_key_base, "threadCount changes key")

local with_drafts = vim.deepcopy(view)
with_drafts.draftCount = 1
assert(stream.build_key_from_view(with_drafts) ~= thread_key_base, "draftCount changes key")

local with_queued = vim.deepcopy(view)
with_queued.queuedCount = 1
assert(stream.build_key_from_view(with_queued) ~= thread_key_base, "queuedCount changes key")

local with_file_threads = vim.deepcopy(view)
with_file_threads.files[1].threads = 3
assert(stream.build_key_from_view(with_file_threads) ~= thread_key_base, "file.threads changes key")

local with_local_unsent = vim.deepcopy(view)
with_local_unsent.localUnsentCount = 2
assert(stream.build_key_from_view(with_local_unsent) ~= thread_key_base, "localUnsentCount changes key")

local with_nil_local_unsent = vim.deepcopy(view)
with_nil_local_unsent.localUnsentCount = vim.NIL
assert(stream.build_key_from_view(with_nil_local_unsent) == thread_key_base, "vim.NIL localUnsentCount matches 0")

local file_thread = {
    threadId = "T_FILE",
    anchor = { file = "a.rs", kind = "file", side = "RIGHT" },
    displayLine = 0,
    kind = "draft",
    state = "open",
    outdated = false,
    messageCount = 1,
    firstAuthor = "bob",
    snippet = "file note",
    messages = {
        {
            id = "M_FILE",
            author = "bob",
            body = "file note\nsecond line",
            sync = "draft",
            reactions = { { content = "THUMBS_UP", count = 1, viewerHasReacted = true } },
        },
    },
}
local left_thread = {
    threadId = "T_LEFT",
    anchor = { file = "a.rs", kind = "line", side = "LEFT", start = 2, ["end"] = 2 },
    displayLine = 2,
    kind = "failed",
    state = "open",
    outdated = false,
    messageCount = 1,
    firstAuthor = "carol",
    snippet = "old line issue",
    messages = {
        { id = "M_LEFT", author = "carol", body = "old line issue", sync = "failed" },
    },
}
local right_thread = {
    threadId = "T_RIGHT",
    anchor = { file = "a.rs", kind = "line", side = "RIGHT", start = 2, ["end"] = 2 },
    displayLine = 2,
    kind = "published",
    state = "open",
    outdated = false,
    messageCount = 1,
    firstAuthor = "alice",
    snippet = "new line nit",
    messages = {
        { id = "M_RIGHT", author = "alice", body = "new line nit", sync = "published" },
    },
}
local threaded_unified_rows = {
    { kind = "file", path = "a.rs", additions = 1, deletions = 1, viewed = "UNVIEWED", folded = false },
    { kind = "thread", path = "a.rs", thread = file_thread, target = 1 },
    { kind = "hunk", path = "a.rs", header = "@@ -1,2 +1,2 @@", target = 1 },
    { kind = "line", path = "a.rs", left = create_cell(1, "keep", "context"), right = create_cell(1, "keep", "context"), target = 1 },
    { kind = "line", path = "a.rs", left = create_cell(2, "x = 1", "removed", x_word), target = 2, threads = { left_thread } },
    { kind = "line", path = "a.rs", right = create_cell(2, "x = 2", "added", x_word), target = 2, threads = { right_thread } },
}

local compact_unified = stream.create_layout_from_stream({ mode = "unified", rows = threaded_unified_rows }, { expanded = false })
local compact_col = compact_unified.columns[1]
assert(compact_col.lines[2] == "  ✎ @bob: file note", vim.inspect(compact_col.lines))
assert(compact_col.line_groups[2] == "JprThreadDraft", vim.inspect(compact_col.line_groups))
assert(vim.deep_equal(compact_unified.thread_lines, { 2, 5, 6 }), vim.inspect(compact_unified.thread_lines))
assert(compact_unified.threads_by_line[2][1].threadId == "T_FILE", vim.inspect(compact_unified.threads_by_line))
assert(compact_unified.threads_by_line[5][1].threadId == "T_LEFT", vim.inspect(compact_unified.threads_by_line))
assert(compact_unified.threads_by_line[6][1].threadId == "T_RIGHT", vim.inspect(compact_unified.threads_by_line))
assert(#compact_col.eol_marks == 2, vim.inspect(compact_col.eol_marks))
assert(compact_col.eol_marks[1].line == 4 and compact_col.eol_marks[1].chunks[1][1]:find("@carol: old line issue", 1, true), vim.inspect(compact_col.eol_marks[1]))
assert(compact_col.eol_marks[2].line == 5 and compact_col.eol_marks[2].chunks[1][1]:find("@alice: new line nit", 1, true), vim.inspect(compact_col.eol_marks[2]))

assert(vim.deep_equal(compact_unified.anchors[2], { file = "a.rs", kind = "file", side = "RIGHT" }), vim.inspect(compact_unified.anchors[2]))
assert(vim.deep_equal(compact_unified.anchors[4], { file = "a.rs", side = "RIGHT", left_line = 1, right_line = 1 }), vim.inspect(compact_unified.anchors[4]))
assert(vim.deep_equal(compact_unified.anchors[5], { file = "a.rs", side = "LEFT", left_line = 2 }), vim.inspect(compact_unified.anchors[5]))
assert(vim.deep_equal(compact_unified.anchors[6], { file = "a.rs", side = "RIGHT", right_line = 2 }), vim.inspect(compact_unified.anchors[6]))

local expanded_unified = stream.create_layout_from_stream({ mode = "unified", rows = threaded_unified_rows }, { expanded = true })
local expanded_col = expanded_unified.columns[1]
assert(#(expanded_col.eol_marks or {}) == 0, "expanded mode hides eol marks")
assert(#expanded_col.lines > #compact_col.lines, "expanded mode emits full message lines")
local joined_expanded = table.concat(expanded_col.lines, "\n")
assert(joined_expanded:find("  │ @bob [draft]", 1, true), joined_expanded)
assert(joined_expanded:find("  │   file note", 1, true), joined_expanded)
assert(joined_expanded:find("  │   second line", 1, true), joined_expanded)
assert(joined_expanded:find("  │   👍 1*", 1, true), joined_expanded)
assert(joined_expanded:find("  │ @carol [failed]", 1, true), joined_expanded)
assert(joined_expanded:find("  │ @alice", 1, true), joined_expanded)

local threaded_split_rows = {
    { kind = "file", path = "a.rs", additions = 1, deletions = 1, viewed = "UNVIEWED", folded = false },
    { kind = "thread", path = "a.rs", thread = file_thread, target = 1 },
    { kind = "hunk", path = "a.rs", header = "@@ -1,2 +1,2 @@", target = 1 },
    { kind = "line", path = "a.rs", left = create_cell(1, "keep", "context"), right = create_cell(1, "keep", "context"), target = 1 },
    {
        kind = "line",
        path = "a.rs",
        left = create_cell(2, "x = 1", "removed", x_word),
        right = create_cell(2, "x = 2", "added", x_word),
        target = 2,
        threads = { left_thread, right_thread },
    },
}
local compact_split = stream.create_layout_from_stream({ mode = "split", rows = threaded_split_rows }, { expanded = false })
assert(#compact_split.columns[1].lines == #compact_split.columns[2].lines, "compact split stays aligned")
assert(#compact_split.columns[1].eol_marks == 1, vim.inspect(compact_split.columns[1].eol_marks))
assert(compact_split.columns[1].eol_marks[1].line == 4 and compact_split.columns[1].eol_marks[1].chunks[1][1]:find("@carol: old line issue", 1, true), vim.inspect(compact_split.columns[1].eol_marks))
assert(#compact_split.columns[2].eol_marks == 1, vim.inspect(compact_split.columns[2].eol_marks))
assert(compact_split.columns[2].eol_marks[1].line == 4 and compact_split.columns[2].eol_marks[1].chunks[1][1]:find("@alice: new line nit", 1, true), vim.inspect(compact_split.columns[2].eol_marks))

local right_only_compact_split = stream.create_layout_from_stream({
    mode = "split",
    rows = {
        { kind = "file", path = "a.rs", additions = 1, deletions = 0, viewed = "UNVIEWED", folded = false },
        { kind = "hunk", path = "a.rs", header = "@@ -1,1 +1,1 @@", target = 1 },
        { kind = "line", path = "a.rs", left = create_cell(1, "keep", "context"), right = create_cell(1, "keep", "context"), target = 1, threads = { right_thread } },
    },
}, { expanded = false })
assert(#right_only_compact_split.columns[1].eol_marks == 0, "left column has no eol_marks when only RIGHT threads exist")
assert(#right_only_compact_split.columns[2].eol_marks == 1, "right column gets eol_marks for RIGHT threads")

local expanded_split = stream.create_layout_from_stream({ mode = "split", rows = threaded_split_rows }, { expanded = true })
local left_split, right_split = expanded_split.columns[1], expanded_split.columns[2]
assert(#left_split.lines == #right_split.lines, "expanded split keeps identical line counts for scrollbind")
-- File thread expands in right column (lines 3..6), so left column has JprDiffFiller lines there.
assert(right_split.lines[3]:find("  │ @bob [draft]", 1, true), vim.inspect(right_split.lines))
assert(left_split.lines[3] == "" and left_split.line_groups[3] == "JprDiffFiller", vim.inspect(left_split.line_groups))
-- Line 2 has both a LEFT thread and a RIGHT thread; left has carol, right has alice.
local left_joined = table.concat(left_split.lines, "\n")
local right_joined = table.concat(right_split.lines, "\n")
assert(left_joined:find("  │ @carol [failed]", 1, true), left_joined)
assert(not left_joined:find("@alice", 1, true), left_joined)
assert(right_joined:find("  │ @alice", 1, true), right_joined)
assert(not right_joined:find("@carol", 1, true), right_joined)

-- Single-sided thread on a split line pads the opposite column with JprDiffFiller.
local right_only_split = stream.create_layout_from_stream({
    mode = "split",
    rows = {
        { kind = "file", path = "a.rs", additions = 1, deletions = 0, viewed = "UNVIEWED", folded = false },
        { kind = "hunk", path = "a.rs", header = "@@ -1,1 +1,1 @@", target = 1 },
        { kind = "line", path = "a.rs", left = create_cell(1, "keep", "context"), right = create_cell(1, "keep", "context"), target = 1, threads = { right_thread } },
    },
}, { expanded = true })
assert(#right_only_split.columns[1].lines == #right_only_split.columns[2].lines, "single-sided split padded")
assert(right_only_split.columns[1].lines[4] == "" and right_only_split.columns[1].line_groups[4] == "JprDiffFiller", vim.inspect(right_only_split.columns[1]))
assert(right_only_split.columns[2].lines[4]:find("  │ @alice", 1, true), vim.inspect(right_only_split.columns[2]))

local local_file_thread = {
    threadId = "loc-file",
    origin = "local",
    anchor = { file = "a.rs", kind = "file", side = "RIGHT" },
    displayLine = 0,
    kind = "local",
    state = "open",
    outdated = false,
    messageCount = 1,
    firstAuthor = "pablo",
    snippet = "add doc comment",
    agent = { state = "unsent" },
    messages = { { id = "lm-f", author = "pablo", body = "add doc comment" } },
}
local local_stream = stream.create_layout_from_stream({
    mode = "unified",
    rows = {
        { kind = "file", path = "a.rs", additions = 1, deletions = 0, viewed = "UNVIEWED", folded = false },
        { kind = "thread", path = "a.rs", thread = local_file_thread, target = 1 },
    },
}, { expanded = false })
assert(local_stream.columns[1].lines[2] == "  ◆ @pablo: add doc comment [local · unsent]", vim.inspect(local_stream.columns[1].lines))
assert(local_stream.columns[1].line_groups[2] == "JprThreadLocal", vim.inspect(local_stream.columns[1].line_groups))

print("stream_render_spec: ok")
