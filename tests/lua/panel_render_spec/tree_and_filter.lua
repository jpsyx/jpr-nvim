return function(context)
    local panel = require("jpr.render.panel")
    local view = context.view
    local highlighted = context.highlighted

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

-- Expanding a parent keeps collapsed subdirs collapsed and expanded subdirs expanded.
local independent_view = {
    pr = { number = 7, title = "Subdirs" },
    files = {
        { path = "apps/cli/a.rs", additions = 1, deletions = 0, viewed = "UNVIEWED", threads = 0 },
        { path = "apps/other/b.rs", additions = 1, deletions = 0, viewed = "UNVIEWED", threads = 0 },
    },
    tree = {
        { depth = 0, name = "apps" },
        { depth = 1, name = "cli" },
        { depth = 2, name = "a.rs", file = 0 },
        { depth = 1, name = "other" },
        { depth = 2, name = "b.rs", file = 1 },
    },
    viewedCount = 0,
    threadCount = 0,
    sync = { state = "synced", at = 112 },
}
local parent_collapsed = panel.build(independent_view, 112, { collapsed_dirs = { apps = true, ["apps/other"] = true } })
assert(parent_collapsed.lines[9] == "▸ apps/ (0/2)" and parent_collapsed.lines[10] == nil, vim.inspect(parent_collapsed.lines))
local parent_expanded = panel.build(independent_view, 112, { collapsed_dirs = { ["apps/other"] = true } })
assert(parent_expanded.lines[9] == "▾ apps/", vim.inspect(parent_expanded.lines))
assert(parent_expanded.lines[10] == "  ▾ cli/", vim.inspect(parent_expanded.lines))
assert(parent_expanded.lines[11] == "      a.rs  +1 -0", vim.inspect(parent_expanded.lines))
assert(parent_expanded.lines[12] == "  ▸ other/ (0/1)", vim.inspect(parent_expanded.lines))
assert(parent_expanded.lines[13] == nil, "collapsed sibling subdir stays collapsed after parent expands")

-- A lone-child joined directory stays collapsed when an intermediate prefix is in collapsed_dirs.
local joined_collapsed = panel.build({
    pr = { number = 7, title = "Joined" },
    files = {
        { path = "docs/x/y.md", additions = 1, deletions = 0, viewed = "UNVIEWED", threads = 0 },
    },
    tree = {
        { depth = 0, name = "docs/x" },
        { depth = 1, name = "y.md", file = 0 },
    },
    viewedCount = 0,
    threadCount = 0,
    sync = { state = "synced", at = 112 },
}, 112, { collapsed_dirs = { docs = true } })
assert(joined_collapsed.lines[9] == "▸ docs/x/ (0/1)", vim.inspect(joined_collapsed.lines))
assert(joined_collapsed.lines[10] == nil, "joined directory hides descendants when a prefix segment is collapsed")
assert(joined_collapsed.rows[9].is_collapsed == true, vim.inspect(joined_collapsed.rows[9]))


end
