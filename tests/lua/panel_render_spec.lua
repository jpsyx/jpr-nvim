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
    "viewed 1/3 · threads 2 · drafts 1",
    "synced 12s ago",
    "",
    "  💬 Conversation [2]",
    "docs/",
    "    x.md  +4 -4",
    "src/",
    "  ✓ a.rs  +12 -3 [2]",
    "  ● b.rs  +1 -0",
}), vim.inspect(built.lines))
assert(built.conversation_line == 5, tostring(built.conversation_line))
assert(built.paths[7] == "docs/x.md" and built.paths[9] == "src/a.rs" and built.paths[10] == "src/b.rs", vim.inspect(built.paths))
assert(built.paths[5] == nil and built.paths[6] == nil and built.paths[8] == nil, "conversation and directories open nothing")

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
assert(vim.deep_equal(highlighted(built, "JprViewed"), { "✓" }), "viewed mark")
assert(vim.deep_equal(highlighted(built, "JprDismissed"), { "●" }), "dismissed mark")
assert(vim.deep_equal(highlighted(built, "JprTitle"), { "#7 Fix the widget", "  💬 Conversation [2]" }), "title and conversation")
assert(
    vim.deep_equal(highlighted(built, "JprMuted"), { "viewed 1/3 · threads 2 · drafts 1", "synced 12s ago", "docs/", "src/" }),
    vim.inspect(highlighted(built, "JprMuted"))
)
local queued = panel.build({ files = {}, queuedCount = 2 }, 0)
assert(queued.lines[2] == "viewed 0/0 · threads 0 · 2 waiting for GitHub", queued.lines[2])
local zero_counts = panel.build({ files = {}, draftCount = 0, conversationCount = 0 }, 0)
assert(zero_counts.lines[2] == "viewed 0/0 · threads 0", zero_counts.lines[2])
assert(zero_counts.lines[5] == "  💬 Conversation", zero_counts.lines[5])
assert(zero_counts.conversation_line == 5, tostring(zero_counts.conversation_line))

local failed = panel.build({ files = {}, sync = { state = "failed", at = 1, message = "offline" } }, 2)
assert(failed.lines[1] == "Loading pull request…", failed.lines[1])
assert(failed.lines[3] == "sync failed: offline", failed.lines[3])
assert(vim.deep_equal(highlighted(failed, "JprError"), { "sync failed: offline" }), "failure is an error")
assert(panel.build({}, 0).lines[3] == "not synced yet", "a fresh view")

-- gh's errors and git's file names can hold newlines; every line stays one line.
local multi_line = panel.build({
    pr = { number = 7, title = "Two\nlines" },
    files = { { path = "new\nline.md", additions = 3, deletions = 1, viewed = "UNVIEWED", threads = 0 } },
    sync = { state = "failed", at = 1, message = "error connecting\r\n  check your connection\n" },
}, 2)
assert(multi_line.lines[1] == "#7 Two lines", multi_line.lines[1])
assert(multi_line.lines[3] == "sync failed: error connecting check your connection", multi_line.lines[3])
assert(multi_line.lines[6] == "  new line.md  +3 -1", multi_line.lines[6])
assert(multi_line.paths[6] == "new\nline.md", "the path keeps its real name for opening")
assert(vim.deep_equal(highlighted(multi_line, "JprAdded"), { "+3" }), vim.inspect(highlighted(multi_line, "JprAdded")))

print("panel_render_spec: ok")
