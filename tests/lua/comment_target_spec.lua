-- Pure comment-target choice for gc, gf, gC, and the standalone PR comment.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local target = require("jpr.comments.target")

local function assert_kind(location, request, expected)
    local kind, error_message = target.classify_comment_kind(location, request)
    assert(kind == expected, ("%s at %s -> %s (%s)"):format(request, vim.inspect(location), tostring(kind), tostring(error_message)))
    assert(error_message == nil, "successful choice has no error: " .. tostring(error_message))
end

local function assert_error(location, request)
    local kind, error_message = target.classify_comment_kind(location, request)
    assert(kind == nil and type(error_message) == "string" and error_message ~= "", vim.inspect({ kind, error_message }))
end

assert_kind({ is_on_diff_line = true, file_path = "src/a.rs" }, "versatile", "line")
assert_kind({ file_path = "src/a.rs" }, "versatile", "file")
assert_kind({ is_pr_surface = true }, "versatile", "pr")
assert_kind({ is_on_diff_line = true, file_path = "README.md", is_pr_surface = true }, "versatile", "line")
assert_error({}, "versatile")
assert_error({ is_on_diff_line = false }, "versatile")

assert_kind({ file_path = "src/a.rs" }, "file", "file")
assert_kind({ is_on_diff_line = true, file_path = "src/a.rs" }, "file", "file")
assert_error({ is_pr_surface = true }, "file")
assert_error({}, "file")

assert_kind({ is_on_diff_line = true, file_path = "src/a.rs" }, "suggest", "line")
assert_error({ file_path = "src/a.rs" }, "suggest")
assert_error({ is_pr_surface = true }, "suggest")

assert_kind({ is_on_diff_line = true, file_path = "src/a.rs" }, "pr", "pr")
assert_kind({}, "pr", "pr")

print("comment_target_spec: ok")
