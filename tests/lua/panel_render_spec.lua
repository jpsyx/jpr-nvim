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
    viewedCount = 1,
    threadCount = 2,
    sync = { state = "synced", at = 100 },
}
local built = panel.build(view, 112)
assert(vim.deep_equal(built.lines, {
    "#7 Fix the widget",
    "viewed 1/3 · threads 2",
    "synced 12s ago",
    "",
    "✓ src/a.rs  +12 -3 [2]",
    "● src/b.rs  +1 -0",
    "  docs/x.md  +4 -4",
}), vim.inspect(built.lines))
assert(built.paths[5] == "src/a.rs" and built.paths[7] == "docs/x.md" and built.paths[4] == nil, vim.inspect(built.paths))

local function highlighted(result, group)
    local out = {}
    for _, hl in ipairs(result.highlights) do
        if hl.group == group then
            out[#out + 1] = result.lines[hl.line + 1]:sub(hl.col_start + 1, hl.col_end)
        end
    end
    return out
end
assert(vim.deep_equal(highlighted(built, "JprAdded"), { "+12", "+1", "+4" }), vim.inspect(highlighted(built, "JprAdded")))
assert(vim.deep_equal(highlighted(built, "JprRemoved"), { "-3", "-0", "-4" }), vim.inspect(highlighted(built, "JprRemoved")))
assert(vim.deep_equal(highlighted(built, "JprViewed"), { "✓" }), "viewed mark")
assert(vim.deep_equal(highlighted(built, "JprDismissed"), { "●" }), "dismissed mark")
assert(vim.deep_equal(highlighted(built, "JprTitle"), { "#7 Fix the widget" }), "title")

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
assert(multi_line.lines[5] == "  new line.md  +3 -1", multi_line.lines[5])
assert(multi_line.paths[5] == "new\nline.md", "the path keeps its real name for opening")
assert(vim.deep_equal(highlighted(multi_line, "JprAdded"), { "+3" }), vim.inspect(highlighted(multi_line, "JprAdded")))

print("panel_render_spec: ok")
