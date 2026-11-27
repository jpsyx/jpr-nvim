return function(context)
    local panel = require("jpr.render.panel")
    local view = context.view
    local highlighted = context.highlighted

assert(panel.age(5) == "5s ago" and panel.age(125) == "2m ago" and panel.age(7300) == "2h ago", "ages")


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


end
