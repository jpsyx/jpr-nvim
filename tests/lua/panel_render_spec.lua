local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local panel = require("jpr.render.panel")

assert(panel.age(5) == "5s ago" and panel.age(125) == "2m ago" and panel.age(7300) == "2h ago", "ages")

local view = {
    pr = { number = 7, title = "Fix the widget" },
    files = {
        { path = "src/a.rs", additions = 12, deletions = 3, viewed = "VIEWED", threads = 2 },
        { path = "src/b.rs", additions = 1, deletions = 0, viewed = "DISMISSED", threads = 0 },
        { path = "docs/x.md", additions = 4, deletions = 4, viewed = "UNVIEWED", threads = 0 },
    },
    tree = {
        { depth = 0, name = "docs" },
        { depth = 1, name = "x.md", file = 2 },
        { depth = 0, name = "src" },
        { depth = 1, name = "a.rs", file = 0 },
        { depth = 1, name = "b.rs", file = 1 },
    },
    viewedCount = 1,
    threadCount = 2,
    draftCount = 1,
    conversationCount = 2,
    queuedCount = 0,
    sync = { state = "synced", at = 100 },
}
local built = panel.build(view, 112)
assert(vim.deep_equal(built.lines, {
    "#7 Fix the widget",
    "█████░░░░░░░░░░░  1/3 (33%)",
    "viewed 1/3 · threads 2 · drafts 1",
    "synced 12s ago",
    "filter: [u] all files",
    "",
    "  📄 Diff summary",
    "  💬 Conversation [2]",
    "▾ docs/",
    "    x.md  +4 -4",
    "▾ src/",
    "  ✓ a.rs  +12 -3 [2]",
    "  ● b.rs  +1 -0",
}), vim.inspect(built.lines))
assert(built.filter_line == 5, tostring(built.filter_line))
assert(built.summary_line == 7, tostring(built.summary_line))
assert(built.conversation_line == 8, tostring(built.conversation_line))
assert(built.paths[10] == "docs/x.md" and built.paths[12] == "src/a.rs" and built.paths[13] == "src/b.rs", vim.inspect(built.paths))
assert(built.paths[5] == nil and built.paths[7] == nil and built.paths[8] == nil and built.paths[9] == nil and built.paths[11] == nil, "filter, summary, conversation and directories open nothing")
assert(vim.deep_equal(built.selectable_lines, { 7, 8, 9, 10, 11, 12, 13 }), vim.inspect(built.selectable_lines))
assert(built.rows[5] == nil, "filter pill line is not a tree row")
assert(vim.deep_equal(built.rows[7], { kind = "summary" }), vim.inspect(built.rows[7]))
assert(vim.deep_equal(built.rows[8], { kind = "conversation" }), vim.inspect(built.rows[8]))
assert(
    vim.deep_equal(built.rows[11], { kind = "dir", path = "src", depth = 0, parent_dir = nil, is_collapsed = false }),
    vim.inspect(built.rows[11])
)
assert(
    vim.deep_equal(built.rows[12], { kind = "file", path = "src/a.rs", depth = 1, parent_dir = "src" }),
    vim.inspect(built.rows[12])
)

local function highlighted(result, group)
    local texts = {}
    for _, highlight in ipairs(result.highlights) do
        if highlight.group == group then
            texts[#texts + 1] = result.lines[highlight.line + 1]:sub(highlight.col_start + 1, highlight.col_end)
        end
    end
    return texts
end
assert(vim.deep_equal(highlighted(built, "JprAdded"), { "+4", "+12", "+1" }), vim.inspect(highlighted(built, "JprAdded")))
assert(vim.deep_equal(highlighted(built, "JprRemoved"), { "-4", "-3", "-0" }), vim.inspect(highlighted(built, "JprRemoved")))
assert(vim.deep_equal(highlighted(built, "JprViewed"), { "█████", "✓" }), vim.inspect(highlighted(built, "JprViewed")))
assert(vim.deep_equal(highlighted(built, "JprDismissed"), { "●" }), "dismissed mark")
assert(
    vim.deep_equal(highlighted(built, "JprTitle"), { "#7 Fix the widget", "1/3 (33%)", "  📄 Diff summary", "  💬 Conversation [2]" }),
    vim.inspect(highlighted(built, "JprTitle"))
)
assert(
    vim.deep_equal(
        highlighted(built, "JprMuted"),
        { "░░░░░░░░░░░", "viewed 1/3 · threads 2 · drafts 1", "synced 12s ago", "filter: [u] all files", "▾ docs/", "▾ src/" }
    ),
    vim.inspect(highlighted(built, "JprMuted"))
)

-- Progress bar helper: 0 files, 0%, partial, 100%, clamping, custom width, and unit label.
local bar_zero_files = panel.create_progress_bar_from_counts(0, 0)
assert(bar_zero_files.text == "░░░░░░░░░░░░░░░░  0/0 (0%)", vim.inspect(bar_zero_files))
assert(bar_zero_files.filled_bytes == 0 and bar_zero_files.unfilled_bytes == 48, vim.inspect(bar_zero_files))
assert(bar_zero_files.counter_start == 50 and bar_zero_files.is_complete == false, vim.inspect(bar_zero_files))

local bar_zero_viewed = panel.create_progress_bar_from_counts(0, 5)
assert(bar_zero_viewed.text == "░░░░░░░░░░░░░░░░  0/5 (0%)", vim.inspect(bar_zero_viewed))
assert(bar_zero_viewed.filled_bytes == 0 and bar_zero_viewed.unfilled_bytes == 48, vim.inspect(bar_zero_viewed))
assert(bar_zero_viewed.is_complete == false, vim.inspect(bar_zero_viewed))

local bar_partial = panel.create_progress_bar_from_counts(8, 20)
assert(bar_partial.text == "██████░░░░░░░░░░  8/20 (40%)", vim.inspect(bar_partial))
assert(bar_partial.filled_bytes == 18 and bar_partial.unfilled_bytes == 30, vim.inspect(bar_partial))
assert(bar_partial.counter_start == 50 and bar_partial.is_complete == false, vim.inspect(bar_partial))

local bar_complete = panel.create_progress_bar_from_counts(4, 4)
assert(bar_complete.text == "████████████████  4/4 (100%)", vim.inspect(bar_complete))
assert(bar_complete.filled_bytes == 48 and bar_complete.unfilled_bytes == 0, vim.inspect(bar_complete))
assert(bar_complete.counter_start == 50 and bar_complete.is_complete == true, vim.inspect(bar_complete))

local bar_clamped_high = panel.create_progress_bar_from_counts(9, 4)
assert(bar_clamped_high.text == "████████████████  4/4 (100%)" and bar_clamped_high.is_complete == true, vim.inspect(bar_clamped_high))

local bar_clamped_low = panel.create_progress_bar_from_counts(-3, 4)
assert(bar_clamped_low.text == "░░░░░░░░░░░░░░░░  0/4 (0%)" and bar_clamped_low.is_complete == false, vim.inspect(bar_clamped_low))

local bar_custom_width = panel.create_progress_bar_from_counts(2, 4, 8)
assert(bar_custom_width.text == "████░░░░  2/4 (50%)", vim.inspect(bar_custom_width))
assert(bar_custom_width.filled_bytes == 12 and bar_custom_width.unfilled_bytes == 12 and bar_custom_width.counter_start == 26)

local bar_with_unit = panel.create_progress_bar_from_counts(8, 20, 20, "files")
assert(bar_with_unit.text == "████████░░░░░░░░░░░░  8/20 files (40%)", vim.inspect(bar_with_unit))
assert(bar_with_unit.counter_start == 62 and bar_with_unit.is_complete == false, vim.inspect(bar_with_unit))

-- Completed panel highlights both the filled bar and the counter with JprViewed.
local complete_view = vim.tbl_deep_extend("force", vim.deepcopy(view), { viewedCount = 3 })
local complete_built = panel.build(complete_view, 112)
assert(complete_built.lines[2] == "████████████████  3/3 (100%)", complete_built.lines[2])
local complete_viewed_highlights = highlighted(complete_built, "JprViewed")
assert(vim.tbl_contains(complete_viewed_highlights, "████████████████"), vim.inspect(complete_viewed_highlights))
assert(vim.tbl_contains(complete_viewed_highlights, "3/3 (100%)"), vim.inspect(complete_viewed_highlights))
assert(not vim.tbl_contains(highlighted(complete_built, "JprTitle"), "3/3 (100%)"), "completed counter uses JprViewed, not JprTitle")

local queued = panel.build({ files = {}, queuedCount = 2 }, 0)
assert(queued.lines[3] == "viewed 0/0 · threads 0 · 2 waiting for GitHub", queued.lines[3])
local zero_counts = panel.build({ files = {}, draftCount = 0, conversationCount = 0 }, 0)
assert(zero_counts.lines[2] == "░░░░░░░░░░░░░░░░  0/0 (0%)", zero_counts.lines[2])
assert(zero_counts.lines[3] == "viewed 0/0 · threads 0", zero_counts.lines[3])
assert(zero_counts.lines[5] == "filter: [u] all files", zero_counts.lines[5])
assert(zero_counts.lines[7] == "  📄 Diff summary", zero_counts.lines[7])
assert(zero_counts.summary_line == 7, tostring(zero_counts.summary_line))
assert(zero_counts.lines[8] == "  💬 Conversation", zero_counts.lines[8])
assert(zero_counts.conversation_line == 8, tostring(zero_counts.conversation_line))
assert(
    panel.build_counts_text({
        viewedCount = 1,
        files = { {}, {} },
        threadCount = 3,
        draftCount = 1,
        localUnsentCount = 2,
        queuedCount = 0,
    }) == "viewed 1/2 · threads 3 · drafts 1 · local unsent 2",
    "localUnsentCount > 0 appends local unsent segment"
)
assert(
    panel.build_counts_text({
        viewedCount = 1,
        files = { {}, {} },
        threadCount = 3,
        draftCount = 1,
        localUnsentCount = 0,
        queuedCount = 0,
    }) == "viewed 1/2 · threads 3 · drafts 1",
    "localUnsentCount = 0 omits local unsent segment"
)
assert(
    panel.build_counts_text({
        viewedCount = 1,
        files = { {}, {} },
        threadCount = 3,
        draftCount = 1,
        localUnsentCount = vim.NIL,
        queuedCount = 0,
    }) == "viewed 1/2 · threads 3 · drafts 1",
    "localUnsentCount = vim.NIL omits local unsent segment"
)

local failed = panel.build({ files = {}, sync = { state = "failed", at = 1, message = "offline" } }, 2)
assert(failed.lines[1] == "Loading pull request…", failed.lines[1])
assert(failed.lines[4] == "sync failed: offline", failed.lines[4])
assert(vim.deep_equal(highlighted(failed, "JprError"), { "sync failed: offline" }), "failure is an error")
assert(panel.build({}, 0).lines[4] == "not synced yet", "a fresh view")

-- gh's errors and git's file names can hold newlines; every line stays one line.
local multi_line = panel.build({
    pr = { number = 7, title = "Two\nlines" },
    files = { { path = "new\nline.md", additions = 3, deletions = 1, viewed = "UNVIEWED", threads = 0 } },
    sync = { state = "failed", at = 1, message = "error connecting\r\n  check your connection\n" },
}, 2)
assert(multi_line.lines[1] == "#7 Two lines", multi_line.lines[1])
assert(multi_line.lines[4] == "sync failed: error connecting check your connection", multi_line.lines[4])
assert(multi_line.lines[9] == "  new line.md  +3 -1", multi_line.lines[9])
assert(multi_line.paths[9] == "new\nline.md", "the path keeps its real name for opening")
assert(vim.deep_equal(highlighted(multi_line, "JprAdded"), { "+3" }), vim.inspect(highlighted(multi_line, "JprAdded")))

-- Clean worktreeStatus keeps line 3 and summary/conversation lines unchanged.
local clean_status_view = vim.tbl_deep_extend("force", vim.deepcopy(view), {
    worktreeStatus = { isDirty = false, ahead = 0, behind = 0 },
})
local clean_built = panel.build(clean_status_view, 112)
assert(panel.build_worktree_badge_from_view(view) == nil, "nil worktreeStatus produces nil badge")
assert(panel.build_worktree_badge_from_view(clean_status_view) == nil, "clean worktreeStatus produces nil badge")
assert(clean_built.lines[3] == "viewed 1/3 · threads 2 · drafts 1", clean_built.lines[3])
assert(clean_built.summary_line == 7 and clean_built.conversation_line == 8, tostring(clean_built.conversation_line))

-- Dirty, ahead/behind, and read-only badges prepend cleanly to line 3 without shifting summary/conversation lines.
local dirty_view = vim.tbl_deep_extend("force", vim.deepcopy(view), {
    worktreeStatus = { isDirty = true, ahead = 2, behind = 0 },
})
local dirty_built = panel.build(dirty_view, 112)
assert(dirty_built.lines[3] == "dirty · ↑2 ↓0 · viewed 1/3 · threads 2 · drafts 1", dirty_built.lines[3])
assert(dirty_built.summary_line == 7 and dirty_built.conversation_line == 8, tostring(dirty_built.conversation_line))

local diverged_view = vim.tbl_deep_extend("force", vim.deepcopy(view), {
    worktreeStatus = { isDirty = false, ahead = 1, behind = 2 },
})
assert(
    panel.build_counts_text(diverged_view) == "↑1 ↓2 · viewed 1/3 · threads 2 · drafts 1",
    panel.build_counts_text(diverged_view)
)

local readonly_only_view = vim.tbl_deep_extend("force", vim.deepcopy(view), {
    isReadOnly = true,
})
assert(
    panel.build_counts_text(readonly_only_view) == "[read-only] · viewed 1/3 · threads 2 · drafts 1",
    panel.build_counts_text(readonly_only_view)
)

local readonly_dirty_view = vim.tbl_deep_extend("force", vim.deepcopy(view), {
    isReadOnly = true,
    worktreeStatus = { isDirty = true, ahead = 1, behind = 0 },
})
assert(
    panel.build_counts_text(readonly_dirty_view) == "[read-only] · dirty · ↑1 ↓0 · viewed 1/3 · threads 2 · drafts 1",
    panel.build_counts_text(readonly_dirty_view)
)

-- File row modified prefix, JprModified UTF-8 byte offsets, and local/GitHub thread badges.
assert(panel.build_threads_badge_from_file({ threads = 2, localThreads = 0 }) == "[2]", "github-only threads badge")
assert(panel.build_threads_badge_from_file({ threads = 3, localThreads = 1 }) == "[2 · 1L]", "mixed threads badge")
assert(panel.build_threads_badge_from_file({ threads = 1, localThreads = 1 }) == "[1L]", "local-only threads badge")
assert(panel.build_threads_badge_from_file({ threads = 0, localThreads = 0 }) == nil, "zero threads omits badge")

local badges_built = panel.build({
    pr = { number = 7, title = "Fix the widget" },
    files = {
        { path = "src/a.rs", additions = 12, deletions = 3, viewed = "VIEWED", isModified = true, threads = 3, localThreads = 1 },
        { path = "src/b.rs", additions = 1, deletions = 0, viewed = "UNVIEWED", isModified = false, threads = 1, localThreads = 1 },
        { path = "src/c.rs", additions = 4, deletions = 4, viewed = "UNVIEWED", isModified = false, threads = 2, localThreads = 0 },
        { path = "src/d.rs", additions = 0, deletions = 1, viewed = "UNVIEWED", isModified = false, threads = 0, localThreads = 0 },
    },
    tree = {
        { depth = 0, name = "src" },
        { depth = 1, name = "a.rs", file = 0 },
        { depth = 1, name = "b.rs", file = 1 },
        { depth = 1, name = "c.rs", file = 2 },
        { depth = 1, name = "d.rs", file = 3 },
    },
    sync = { state = "synced", at = 100 },
}, 110)

assert(badges_built.lines[10] == "  ✓ ✎ a.rs  +12 -3 [2 · 1L]", badges_built.lines[10])
assert(badges_built.lines[11] == "    b.rs  +1 -0 [1L]", badges_built.lines[11])
assert(badges_built.lines[12] == "    c.rs  +4 -4 [2]", badges_built.lines[12])
assert(badges_built.lines[13] == "    d.rs  +0 -1", badges_built.lines[13])
assert(vim.deep_equal(highlighted(badges_built, "JprModified"), { "✎" }), vim.inspect(highlighted(badges_built, "JprModified")))
assert(vim.deep_equal(highlighted(badges_built, "JprAdded"), { "+12", "+1", "+4", "+0" }), vim.inspect(highlighted(badges_built, "JprAdded")))
assert(vim.deep_equal(highlighted(badges_built, "JprRemoved"), { "-3", "-0", "-4", "-1" }), vim.inspect(highlighted(badges_built, "JprRemoved")))

local modified_spans = {}
for _, highlight in ipairs(badges_built.highlights) do
    if highlight.group == "JprModified" then
        modified_spans[#modified_spans + 1] = highlight
    end
end
assert(#modified_spans == 1, "one JprModified span")
-- "  " (2 bytes) + "✓" (3 bytes) + " " (1 byte) = col_start 6; "✎" is 3 UTF-8 bytes -> col_end 9.
assert(
    modified_spans[1].line == 9 and modified_spans[1].col_start == 6 and modified_spans[1].col_end == 9,
    vim.inspect(modified_spans[1])
)

-- Collapsible directories: collapsed dir shows count and omits descendants.
local collapsed = panel.build(view, 112, { collapsed_dirs = { src = true } })
assert(vim.deep_equal(collapsed.lines, {
    "#7 Fix the widget",
    "█████░░░░░░░░░░░  1/3 (33%)",
    "viewed 1/3 · threads 2 · drafts 1",
    "synced 12s ago",
    "filter: [u] all files",
    "",
    "  📄 Diff summary",
    "  💬 Conversation [2]",
    "▾ docs/",
    "    x.md  +4 -4",
    "▸ src/ (1/2)",
}), vim.inspect(collapsed.lines))
assert(collapsed.paths[11] == nil and collapsed.paths[12] == nil and collapsed.paths[13] == nil, vim.inspect(collapsed.paths))
assert(collapsed.rows[12] == nil and collapsed.rows[13] == nil, "collapsed descendants omitted from rows")
assert(
    vim.deep_equal(collapsed.rows[11], { kind = "dir", path = "src", depth = 0, parent_dir = nil, is_collapsed = true }),
    vim.inspect(collapsed.rows[11])
)
assert(vim.deep_equal(collapsed.selectable_lines, { 7, 8, 9, 10, 11 }), vim.inspect(collapsed.selectable_lines))

-- Lone-child joined directories carry canonical path and parent_dir, and isLocalOnly renders [local] in JprThreadLocal.
local joined_and_local = panel.build({
    pr = { number = 7, title = "Fix the widget" },
    files = {
        { path = "docs/x/a.md", additions = 2, deletions = 0, viewed = "UNVIEWED", threads = 0, isLocalOnly = true },
        { path = "docs/x/sub/b.md", additions = 1, deletions = 0, viewed = "UNVIEWED", threads = 1, localThreads = 1, isLocalOnly = true },
    },
    tree = {
        { depth = 0, name = "docs/x" },
        { depth = 1, name = "a.md", file = 0 },
        { depth = 1, name = "sub" },
        { depth = 2, name = "b.md", file = 1 },
    },
    sync = { state = "synced", at = 100 },
}, 110)
assert(joined_and_local.lines[9] == "▾ docs/x/", joined_and_local.lines[9])
assert(joined_and_local.lines[10] == "    a.md  +2 -0 [local]", joined_and_local.lines[10])
assert(joined_and_local.lines[11] == "  ▾ sub/", joined_and_local.lines[11])
assert(joined_and_local.lines[12] == "      b.md  +1 -0 [1L] [local]", joined_and_local.lines[12])
assert(
    vim.deep_equal(joined_and_local.rows[9], { kind = "dir", path = "docs/x", depth = 0, parent_dir = nil, is_collapsed = false }),
    vim.inspect(joined_and_local.rows[9])
)
assert(
    vim.deep_equal(joined_and_local.rows[11], { kind = "dir", path = "docs/x/sub", depth = 1, parent_dir = "docs/x", is_collapsed = false }),
    vim.inspect(joined_and_local.rows[11])
)
assert(
    vim.deep_equal(joined_and_local.rows[12], { kind = "file", path = "docs/x/sub/b.md", depth = 2, parent_dir = "docs/x/sub" }),
    vim.inspect(joined_and_local.rows[12])
)
assert(
    vim.deep_equal(highlighted(joined_and_local, "JprThreadLocal"), { "[local]", "[local]" }),
    vim.inspect(highlighted(joined_and_local, "JprThreadLocal"))
)

local dir_files = {
    { path = "src/a.rs", additions = 1, deletions = 0, viewed = "VIEWED" },
    { path = "src/sub/b.rs", additions = 2, deletions = 1, viewed = "UNVIEWED" },
    { path = "src/sub/deep/c.rs", additions = 1, deletions = 0, viewed = "DISMISSED" },
    { path = "src_other/d.rs", additions = 1, deletions = 0, viewed = "UNVIEWED" },
    { path = "docs/x/y.md", additions = 1, deletions = 0, viewed = "VIEWED" },
}
local src_toggle = panel.collect_directory_toggle_from_files(dir_files, "src")
assert(
    src_toggle ~= nil
        and src_toggle.viewed == true
        and vim.deep_equal(src_toggle.paths, { "src/a.rs", "src/sub/b.rs", "src/sub/deep/c.rs" }),
    "mixed dir marks all nested descendants viewed without prefix collision: " .. vim.inspect(src_toggle)
)
local docs_toggle = panel.collect_directory_toggle_from_files(dir_files, "docs/x")
assert(
    docs_toggle ~= nil
        and docs_toggle.viewed == false
        and vim.deep_equal(docs_toggle.paths, { "docs/x/y.md" }),
    "all-viewed joined dir unmarks descendants: " .. vim.inspect(docs_toggle)
)
assert(panel.collect_directory_toggle_from_files(dir_files, "missing") == nil, "empty dir returns nil")

local nav_view = {
    files = {
        { path = "README.md", additions = 1, deletions = 0, viewed = "UNVIEWED" },
        { path = "src/a.rs", additions = 1, deletions = 0, viewed = "VIEWED" },
        { path = "src/b.rs", additions = 1, deletions = 0, viewed = "DISMISSED" },
    },
    tree = {
        { depth = 0, name = "src" },
        { depth = 1, name = "a.rs", file = 1 },
        { depth = 1, name = "b.rs", file = 2 },
        { depth = 0, name = "README.md", file = 0 },
    },
}
assert(panel.find_next_unviewed_path(nav_view, "src/a.rs") == "src/b.rs", "next unviewed follows tree order and treats DISMISSED as unviewed")
assert(panel.find_next_unviewed_path(nav_view, "README.md") == "src/b.rs", "wraps around from last tree entry to earlier unviewed file")
local all_viewed_view = {
    files = { { path = "README.md", viewed = "VIEWED" }, { path = "src/a.rs", viewed = "VIEWED" } },
    tree = { { depth = 0, name = "src" }, { depth = 1, name = "a.rs", file = 1 }, { depth = 0, name = "README.md", file = 0 } },
}
assert(panel.find_next_unviewed_path(all_viewed_view, "src/a.rs") == nil, "nil when every file is viewed")

-- Directory checks are recursive. A parent stays unchecked while any nested
-- file is unviewed, and a collapsed directory shows viewed/total. DISMISSED
-- does not count as viewed. A complete directory keeps its check when collapsed.
local function create_nested_view(lib_b_viewed)
    return {
        pr = { number = 1, title = "Nested" },
        files = {
            { path = "src/a.rs", additions = 1, deletions = 0, viewed = "VIEWED" },
            { path = "src/lib/b.rs", additions = 1, deletions = 0, viewed = lib_b_viewed },
            { path = "src/lib/c.rs", additions = 1, deletions = 0, viewed = "VIEWED" },
        },
        tree = {
            { depth = 0, name = "src" },
            { depth = 1, name = "a.rs", file = 0 },
            { depth = 1, name = "lib" },
            { depth = 2, name = "b.rs", file = 1 },
            { depth = 2, name = "c.rs", file = 2 },
        },
        viewedCount = lib_b_viewed == "VIEWED" and 3 or 2,
        sync = { state = "synced", at = 100 },
    }
end

local function viewed_marks_on_line(result, line_number)
    local marks = {}
    for _, highlight in ipairs(result.highlights) do
        if highlight.group == "JprViewed" and highlight.line == line_number - 1 then
            marks[#marks + 1] = result.lines[line_number]:sub(highlight.col_start + 1, highlight.col_end)
        end
    end
    return marks
end

local nested_partial = panel.build(create_nested_view("UNVIEWED"), 100, { collapsed_dirs = { ["src/lib"] = true } })
assert(nested_partial.lines[9] == "▾ src/", "expanded parent stays unchecked while a nested file is unviewed: " .. nested_partial.lines[9])
assert(nested_partial.lines[11] == "  ▸ lib/ (1/2)", "collapsed child counts nested files: " .. tostring(nested_partial.lines[11]))
assert(nested_partial.lines[12] == nil, "collapsed child omits its files")

local nested_dismissed = panel.build(create_nested_view("DISMISSED"), 100, { collapsed_dirs = { src = true } })
assert(nested_dismissed.lines[9] == "▸ src/ (2/3)", "DISMISSED nested file keeps the parent incomplete: " .. nested_dismissed.lines[9])

local nested_complete = panel.build(create_nested_view("VIEWED"), 100)
assert(nested_complete.lines[9] == "▾ ✓ src/", "expanded parent shows a check when every nested file is viewed: " .. nested_complete.lines[9])
assert(nested_complete.lines[11] == "  ▾ ✓ lib/", "expanded child shows a check: " .. tostring(nested_complete.lines[11]))
assert(vim.deep_equal(viewed_marks_on_line(nested_complete, 9), { "✓" }), vim.inspect(viewed_marks_on_line(nested_complete, 9)))
assert(vim.deep_equal(viewed_marks_on_line(nested_complete, 11), { "✓" }), vim.inspect(viewed_marks_on_line(nested_complete, 11)))

local nested_collapsed = panel.build(create_nested_view("VIEWED"), 100, { collapsed_dirs = { src = true } })
assert(nested_collapsed.lines[9] == "▸ ✓ src/", "collapsed complete directory keeps its check: " .. nested_collapsed.lines[9])
assert(vim.deep_equal(viewed_marks_on_line(nested_collapsed, 9), { "✓" }), vim.inspect(viewed_marks_on_line(nested_collapsed, 9)))
assert(nested_collapsed.lines[10] == nil, "collapsed complete directory omits descendants")

-- A long PR title wraps inside the sidebar width, and the header shows the PR
-- branch plus a distinct session checkout branch.
local long_title = "Added deterministic linting for several rules and removed them from non-deterministic reviews"
local wrapped = panel.build({
    pr = {
        number = 330,
        title = long_title,
        headRef = "feat/oxlint-phase3",
        baseRef = "develop",
    },
    files = {},
    sync = { state = "never" },
}, 0, { width = 44, checkout_branch = "pr-330" })
for index, line in ipairs(wrapped.lines) do
    assert(vim.fn.strdisplaywidth(line) <= 44, ("line %d wider than the sidebar: %s"):format(index, line))
end
assert(wrapped.lines[1] ~= "#330 " .. long_title, "long title is not one overflowing line")
local wrapped_text = table.concat(wrapped.lines, "\n")
assert(wrapped_text:find("#330", 1, true) ~= nil, wrapped_text)
assert(wrapped_text:find("non-deterministic reviews", 1, true) ~= nil, wrapped_text)
assert(wrapped_text:find("feat/oxlint-phase3 -> develop", 1, true) ~= nil, wrapped_text)
assert(wrapped_text:find("checkout pr-330", 1, true) ~= nil, wrapped_text)
assert(wrapped.summary_line > 6, "branch lines sit above Diff summary")

local reused = panel.build({
    pr = { number = 330, title = "Short", headRef = "feat/oxlint-phase3", baseRef = "develop" },
    files = {},
    sync = { state = "never" },
}, 0, { width = 44, checkout_branch = "feat/oxlint-phase3" })
local reused_text = table.concat(reused.lines, "\n")
assert(reused_text:find("feat/oxlint-phase3 -> develop", 1, true) ~= nil, reused_text)
assert(reused_text:find("checkout ", 1, true) == nil, "reused PR branch is not repeated: " .. reused_text)
assert(vim.fn.strdisplaywidth(reused.lines[1]) <= 44, reused.lines[1])

local unwrapped = panel.build({
    pr = { number = 7, title = long_title },
    files = {},
}, 0)
assert(unwrapped.lines[1] == "#7 " .. long_title, "callers without a width keep one title line")

-- hide_viewed keeps files that still need review and drops files already VIEWED.
local unviewed_only = panel.build(view, 112, { hide_viewed = true })
assert(vim.deep_equal(unviewed_only.lines, {
    "#7 Fix the widget",
    "█████░░░░░░░░░░░  1/3 (33%)",
    "viewed 1/3 · threads 2 · drafts 1",
    "synced 12s ago",
    "filter: [u] unviewed only",
    "",
    "  📄 Diff summary",
    "  💬 Conversation [2]",
    "▾ docs/",
    "    x.md  +4 -4",
    "▾ src/",
    "  ● b.rs  +1 -0",
}), vim.inspect(unviewed_only.lines))
assert(unviewed_only.filter_line == 5, tostring(unviewed_only.filter_line))
assert(vim.deep_equal(highlighted(unviewed_only, "JprHunk"), { "[u] unviewed only" }), vim.inspect(highlighted(unviewed_only, "JprHunk")))
assert(unviewed_only.paths[10] == "docs/x.md" and unviewed_only.paths[12] == "src/b.rs", vim.inspect(unviewed_only.paths))
assert(unviewed_only.paths[11] == nil, "the src directory opens nothing")
local unviewed_paths = {}
for _, path in pairs(unviewed_only.paths) do
    unviewed_paths[#unviewed_paths + 1] = path
end
table.sort(unviewed_paths)
assert(vim.deep_equal(unviewed_paths, { "docs/x.md", "src/b.rs" }), vim.inspect(unviewed_paths))

-- A fully reviewed tree says so instead of drawing an empty file list.
local all_viewed = vim.deepcopy(view)
for _, file in ipairs(all_viewed.files) do
    file.viewed = "VIEWED"
end
all_viewed.viewedCount = #all_viewed.files
local reviewed = panel.build(all_viewed, 112, { hide_viewed = true })
assert(reviewed.lines[#reviewed.lines] == "  all files viewed", vim.inspect(reviewed.lines))
local reviewed_paths = {}
for _, path in pairs(reviewed.paths) do
    reviewed_paths[#reviewed_paths + 1] = path
end
assert(#reviewed_paths == 0, vim.inspect(reviewed_paths))
assert(reviewed.summary_line ~= nil and reviewed.conversation_line ~= nil, "summary and conversation stay")

-- A directory stays only when some descendant still needs review.
local nested = {
    pr = { number = 7, title = "Fix the widget" },
    files = {
        { path = "lib/done.rs", additions = 1, deletions = 0, viewed = "VIEWED", threads = 0 },
        { path = "src/core/a.rs", additions = 2, deletions = 0, viewed = "UNVIEWED", threads = 0 },
        { path = "src/old/b.rs", additions = 1, deletions = 0, viewed = "VIEWED", threads = 0 },
    },
    tree = {
        { depth = 0, name = "lib" },
        { depth = 1, name = "done.rs", file = 0 },
        { depth = 0, name = "src" },
        { depth = 1, name = "core" },
        { depth = 2, name = "a.rs", file = 1 },
        { depth = 1, name = "old" },
        { depth = 2, name = "b.rs", file = 2 },
    },
    viewedCount = 2,
    threadCount = 0,
    sync = { state = "synced", at = 112 },
}
local nested_built = panel.build(nested, 112, { hide_viewed = true })
local nested_text = table.concat(nested_built.lines, "\n")
assert(nested_text:find("lib/", 1, true) == nil, nested_text)
assert(nested_text:find("done.rs", 1, true) == nil, nested_text)
assert(nested_text:find("old/", 1, true) == nil, nested_text)
assert(nested_text:find("b.rs", 1, true) == nil, nested_text)
assert(nested_text:find("▾ src/", 1, true) ~= nil, nested_text)
assert(nested_text:find("▾ core/", 1, true) ~= nil, nested_text)
assert(nested_text:find("a.rs", 1, true) ~= nil, nested_text)

local collapsed_unviewed = panel.build(view, 112, { hide_viewed = true, collapsed_dirs = { src = true, docs = true } })
assert(collapsed_unviewed.lines[9] == "▸ docs/ (0/1)", vim.inspect(collapsed_unviewed.lines))
assert(collapsed_unviewed.lines[10] == "▸ src/ (1/2)", vim.inspect(collapsed_unviewed.lines))
assert(collapsed_unviewed.lines[11] == nil, "collapsed filter hides the files under those directories")

print("panel_render_spec: ok")
