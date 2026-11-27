local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local panel = require("jpr.render.panel")


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

local function highlighted(result, group)
    local texts = {}
    for _, highlight in ipairs(result.highlights) do
        if highlight.group == group then
            texts[#texts + 1] = result.lines[highlight.line + 1]:sub(highlight.col_start + 1, highlight.col_end)
        end
    end
    return texts
end

local context = {
    view = view,
    highlighted = highlighted,
}

dofile(root .. "/tests/lua/panel_render_spec/header_and_badges.lua")(context)
dofile(root .. "/tests/lua/panel_render_spec/tree_and_filter.lua")(context)

print("panel_render_spec: ok")
