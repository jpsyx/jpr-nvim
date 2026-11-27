local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local comment_text = require("jpr.render.comment_text")
local threads = require("jpr.render.threads")

local function render_body(body)
    return comment_text.render_body(body)
end

assert(render_body("Overall looks clean!") == "Overall looks clean!", render_body("Overall looks clean!"))
assert(render_body("a < b and <https://example.com>") == "a < b and <https://example.com>", render_body("a < b and <https://example.com>"))
assert(render_body("rock &amp; roll") == "rock & roll", render_body("rock &amp; roll"))

local docs_link = '<a href="https://example.com/docs">the docs</a>'
assert(render_body(docs_link) == "[the docs](https://example.com/docs)", render_body(docs_link))

local avatar = '<a href="https://vercel.com/avandar-labs/avandar"><sup><img src="https://vercel.com/api/www/avatar?projectId=prj&teamId=team&s=32" width="16" height="16" align="middle" alt="" /></sup></a>'
assert(
    render_body(avatar) == "[image: avatar](https://vercel.com/avandar-labs/avandar)",
    render_body(avatar)
)

local clock = '<relative-time datetime="2026-11-23T19:55:08.198Z">Nov 23, 2026 7:55pm UTC</relative-time>'
assert(render_body(clock) == "Nov 23, 2026 7:55pm UTC", render_body(clock))

local picture = '<a href="https://vercel.com/vercel-agent/request-review?owner=AvandarLabs&repo=avandar&pr=330" rel="noreferrer"><picture><source media="(prefers-color-scheme: dark)" srcset="https://agents-vade-review.vercel.sh/request-review-dark.svg"><source media="(prefers-color-scheme: light)" srcset="https://agents-vade-review.vercel.sh/request-review-light.svg"><img src="https://agents-vade-review.vercel.sh/request-review-light.svg" alt="Request Review"></picture></a>'
assert(
    render_body(picture) == "[Request Review](https://vercel.com/vercel-agent/request-review?owner=AvandarLabs&repo=avandar&pr=330)",
    render_body(picture)
)

local rule = "above\n\n<hr/>\n\nbelow"
local rendered_rule = render_body(rule)
assert(rendered_rule:find("<hr", 1, true) == nil, rendered_rule)
assert(rendered_rule:find("---", 1, true) ~= nil, rendered_rule)
assert(rendered_rule:find("above", 1, true) ~= nil and rendered_rule:find("below", 1, true) ~= nil, rendered_rule)

local banner = '<!-- react-doctor:summary -->\n<a href="https://react.doctor"><img src="https://raw.githubusercontent.com/millionco/react-doctor/main/packages/website/public/react-doctor-og-banner.svg" alt="React Doctor" width="244" /></a>'
local rendered_banner = render_body(banner)
assert(rendered_banner:find("[React Doctor](https://react.doctor)", 1, true) ~= nil, rendered_banner)
assert(rendered_banner:find("<", 1, true) == nil, rendered_banner)
assert(rendered_banner:find("react-doctor:summary", 1, true) == nil, rendered_banner)

assert(render_body("![Ready](https://vercel.com/static/status/ready.svg)") == "*[Ready]*", render_body("![Ready](https://vercel.com/static/status/ready.svg)"))
assert(render_body("![](https://example.com/files/shot.png)") == "*[image: shot.png]*", render_body("![](https://example.com/files/shot.png)"))

local fenced = "see\n```html\n<img src=\"x\" alt=\"nope\">\n```\n"
local rendered_fence = render_body(fenced)
assert(rendered_fence:find('<img src="x" alt="nope">', 1, true) ~= nil, rendered_fence)
assert(render_body("use `<img alt=\"x\">` here") == "use `<img alt=\"x\">` here", render_body("use `<img alt=\"x\">` here"))

local layout = threads.create_message_layout()
threads.append_formatted_message(layout, { threadId = "T" }, {
    id = "M1",
    author = "alice",
    created = "2026-11-20T00:00:00Z",
    updated = "2026-11-20T00:00:00Z",
    body = '<a href="https://react.doctor">React Doctor</a> found issues.',
}, { box = true, width = 48, indent = 0 })
threads.append_formatted_message(layout, { threadId = "T" }, {
    id = "M2",
    author = "bob",
    created = "2026-11-20T01:00:00Z",
    updated = "2026-11-20T01:00:00Z",
    body = "Agreed.",
}, { box = true, width = 48, indent = 4 })

local boxed = table.concat(layout.lines, "\n")
assert(boxed:find("[React Doctor](https://react.doctor)", 1, true) ~= nil, boxed)
assert(boxed:find("<a ", 1, true) == nil, boxed)
assert(boxed:find("_", 1, true) ~= nil and boxed:find("|", 1, true) ~= nil, boxed)
local saw_reply = false
for _, line in ipairs(layout.lines) do
    assert(vim.fn.strdisplaywidth(line) <= 48, line .. " width " .. vim.fn.strdisplaywidth(line))
    if line:find("@alice", 1, true) then
        assert(line:sub(1, 1) == "|", "root comment box is not indented: " .. line)
    end
    if line:find("@bob", 1, true) then
        assert(line:sub(1, 4) == "    ", "reply box is indented: " .. line)
        saw_reply = true
    end
end
assert(saw_reply, boxed)
assert(layout.message_ranges[1].last >= layout.message_ranges[1].first + 2, vim.inspect(layout.message_ranges[1]))
assert(layout.message_ranges[2].first > layout.message_ranges[1].last, vim.inspect(layout.message_ranges))

local plain = threads.create_message_layout()
threads.append_formatted_message(plain, { threadId = "T" }, {
    id = "M",
    author = "bot",
    created = "c",
    updated = "c",
    body = '<a href="https://example.com">docs</a>',
})
assert(table.concat(plain.lines, "\n"):find("[docs](https://example.com)", 1, true) ~= nil, table.concat(plain.lines, "\n"))

local virt = threads.create_expanded_virt_lines_from_threads({
    {
        messages = {
            { author = "bot", body = '<a href="https://react.doctor">React Doctor</a>' },
        },
    },
}, false)
local virt_text = table.concat(vim.tbl_map(function(row)
    return row[1][1]
end, virt), "\n")
assert(virt_text:find("[React Doctor](https://react.doctor)", 1, true) ~= nil, virt_text)
assert(virt_text:find("<a ", 1, true) == nil, virt_text)

print("comment_text_spec: ok")
