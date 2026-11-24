local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local panel_paths = require("jpr.views.panel_paths")

local worktree = vim.fn.tempname()
vim.fn.mkdir(worktree .. "/src/api", "p")
vim.fn.mkdir(worktree .. "/docs/x", "p")

local outside_dir = vim.fn.tempname()
vim.fn.mkdir(outside_dir, "p")
vim.uv.fs_symlink(outside_dir, worktree .. "/escape_link")

-- create_rename_context_from_row
local file_ctx = panel_paths.create_rename_context_from_row(worktree, { kind = "file", path = "src/api/foo.ts" })
assert(file_ctx.mode == "rename", "rename mode expected")
assert(file_ctx.worktree == worktree, "worktree preserved")
assert(file_ctx.current_dir == "src/api", "file parent dir")
assert(file_ctx.target_path == "src/api/foo.ts", "file target path")
assert(file_ctx.initial_text == "foo.ts", "file initial text is basename")
assert(file_ctx.is_directory == false, "file is not directory")

local root_file_ctx = panel_paths.create_rename_context_from_row(worktree, { kind = "file", path = "README.md" })
assert(root_file_ctx.current_dir == "", "root file has empty current_dir")
assert(root_file_ctx.initial_text == "README.md", "root file initial text")

local joined_dir_ctx = panel_paths.create_rename_context_from_row(worktree, { kind = "dir", path = "docs/x" })
assert(joined_dir_ctx.current_dir == "docs", "joined lone-child dir parent is docs")
assert(joined_dir_ctx.target_path == "docs/x", "joined lone-child target is docs/x")
assert(joined_dir_ctx.initial_text == "x", "joined lone-child initial text is x")
assert(joined_dir_ctx.is_directory == true, "joined dir is_directory")

local top_dir_ctx = panel_paths.create_rename_context_from_row(worktree, { kind = "dir", path = "src" })
assert(top_dir_ctx.current_dir == "", "top-level dir has empty current_dir")
assert(top_dir_ctx.initial_text == "src", "top-level dir initial text")
assert(top_dir_ctx.is_directory == true, "top-level dir is_directory")

-- create_create_context_from_row
local create_from_dir = panel_paths.create_create_context_from_row(worktree, { kind = "dir", path = "src/api" })
assert(create_from_dir.mode == "create", "create mode expected")
assert(create_from_dir.current_dir == "src/api", "create under dir uses dir path")

local create_from_file = panel_paths.create_create_context_from_row(worktree, { kind = "file", path = "src/api/foo.ts" })
assert(create_from_file.current_dir == "src/api", "create under file uses parent dir")

local create_from_root_file = panel_paths.create_create_context_from_row(worktree, { kind = "file", path = "README.md" })
assert(create_from_root_file.current_dir == "", "create under root file uses empty current_dir")

local create_from_conv = panel_paths.create_create_context_from_row(worktree, { kind = "conversation" })
assert(create_from_conv.current_dir == "", "create under conversation uses worktree root")

-- resolve_input_from_context: plain filename in current_dir
local plain_res = panel_paths.resolve_input_from_context("helper.ts", {
    mode = "create",
    worktree = worktree,
    current_dir = "src/api",
})
assert(plain_res.ok == true, "plain filename should succeed")
assert(plain_res.mode == "same_dir", "plain filename mode is same_dir")
assert(plain_res.relative_path == "src/api/helper.ts", "plain filename resolves in current_dir")
assert(plain_res.absolute_path == worktree .. "/src/api/helper.ts", "plain filename absolute_path")
assert(plain_res.is_directory == false, "plain filename is not directory")
assert(plain_res.hint:find("src/api/helper.ts", 1, true) ~= nil, "plain filename hint previews target")

-- resolve_input_from_context: path with slash -> project_root
local root_rel_res = panel_paths.resolve_input_from_context("some/new/path/module.ts", {
    mode = "rename",
    worktree = worktree,
    current_dir = "src/api",
    target_path = "src/api/foo.ts",
    is_directory = false,
})
assert(root_rel_res.ok == true, "slash path should succeed")
assert(root_rel_res.mode == "project_root", "slash path mode is project_root")
assert(root_rel_res.relative_path == "some/new/path/module.ts", "slash path resolves from project root")
assert(
    root_rel_res.hint:find("Path is relative to project root", 1, true) ~= nil,
    "project_root hint mentions project root"
)

-- resolve_input_from_context: ../ relative to current_dir
local parent_rel_res = panel_paths.resolve_input_from_context("../shared/util.ts", {
    mode = "rename",
    worktree = worktree,
    current_dir = "src/api",
    target_path = "src/api/foo.ts",
    is_directory = false,
})
assert(parent_rel_res.ok == true, "../ path should succeed")
assert(parent_rel_res.mode == "current_dir", "../ path mode is current_dir")
assert(parent_rel_res.relative_path == "src/shared/util.ts", "../ path resolves from current_dir")
assert(
    parent_rel_res.hint:find("Path is relative to current directory", 1, true) ~= nil,
    "current_dir hint mentions current directory"
)

-- resolve_input_from_context: ./ relative to current_dir
local dot_rel_res = panel_paths.resolve_input_from_context("./local.ts", {
    mode = "create",
    worktree = worktree,
    current_dir = "src/api",
})
assert(dot_rel_res.ok == true, "./ path should succeed")
assert(dot_rel_res.mode == "current_dir", "./ path mode is current_dir")
assert(dot_rel_res.relative_path == "src/api/local.ts", "./ path resolves from current_dir")

-- resolve_input_from_context: create trailing slash -> directory
local dir_create_res = panel_paths.resolve_input_from_context("src/newdir/", {
    mode = "create",
    worktree = worktree,
    current_dir = "src/api",
})
assert(dir_create_res.ok == true, "trailing slash dir create should succeed")
assert(dir_create_res.is_directory == true, "trailing slash marks is_directory")
assert(dir_create_res.relative_path == "src/newdir", "trailing slash stripped from relative_path")
assert(dir_create_res.mode == "project_root", "src/newdir/ uses project_root mode")

local child_dir_res = panel_paths.resolve_input_from_context("sub/", {
    mode = "create",
    worktree = worktree,
    current_dir = "src/api",
})
assert(child_dir_res.ok == true, "plain trailing slash dir create should succeed")
assert(child_dir_res.is_directory == true, "plain trailing slash marks is_directory")
assert(child_dir_res.mode == "same_dir", "plain trailing slash uses same_dir mode")
assert(child_dir_res.relative_path == "src/api/sub", "plain trailing slash creates child dir")

-- resolve_input_from_context: rename trailing slash on directory vs file
local dir_rename_slash = panel_paths.resolve_input_from_context("src/v2/api/", {
    mode = "rename",
    worktree = worktree,
    current_dir = "src",
    target_path = "src/api",
    is_directory = true,
})
assert(dir_rename_slash.ok == true, "trailing slash allowed when renaming a directory")
assert(dir_rename_slash.relative_path == "src/v2/api", "trailing slash stripped on dir rename")
assert(dir_rename_slash.is_directory == true, "dir rename keeps is_directory = true")

local file_rename_slash = panel_paths.resolve_input_from_context("bar.ts/", {
    mode = "rename",
    worktree = worktree,
    current_dir = "src/api",
    target_path = "src/api/foo.ts",
    is_directory = false,
})
assert(file_rename_slash.ok == false, "trailing slash rejected when renaming a file")

-- Rejections: escaping worktree, leading /, .git, empty, ".", "..", control chars
local escape_res = panel_paths.resolve_input_from_context("../../../etc/passwd", {
    mode = "create",
    worktree = worktree,
    current_dir = "src/api",
})
assert(escape_res.ok == false, "escaping worktree via .. must fail")
assert(escape_res.error:find("escapes", 1, true) ~= nil, "escape error mentions escaping worktree")

local leading_slash_res = panel_paths.resolve_input_from_context("/etc/passwd", {
    mode = "create",
    worktree = worktree,
    current_dir = "src/api",
})
assert(leading_slash_res.ok == false, "leading slash must fail")

local git_res = panel_paths.resolve_input_from_context(".git/config", {
    mode = "create",
    worktree = worktree,
    current_dir = "",
})
assert(git_res.ok == false, ".git/config must fail")

local nested_git_res = panel_paths.resolve_input_from_context("src/.git/hooks", {
    mode = "create",
    worktree = worktree,
    current_dir = "",
})
assert(nested_git_res.ok == false, "nested .git component must fail")

local empty_res = panel_paths.resolve_input_from_context("   ", {
    mode = "create",
    worktree = worktree,
    current_dir = "src",
})
assert(empty_res.ok == false, "empty input must fail")

local dot_res = panel_paths.resolve_input_from_context(".", {
    mode = "create",
    worktree = worktree,
    current_dir = "src",
})
assert(dot_res.ok == false, "dot input must fail")

local dotdot_res = panel_paths.resolve_input_from_context("..", {
    mode = "create",
    worktree = worktree,
    current_dir = "src",
})
assert(dotdot_res.ok == false, "dotdot input must fail")

local newline_res = panel_paths.resolve_input_from_context("foo\nbar.ts", {
    mode = "create",
    worktree = worktree,
    current_dir = "src",
})
assert(newline_res.ok == false, "newline in path must fail")

-- Rejection: renaming a directory into itself
local into_self_res = panel_paths.resolve_input_from_context("src/api/sub", {
    mode = "rename",
    worktree = worktree,
    current_dir = "src",
    target_path = "src/api",
    is_directory = true,
})
assert(into_self_res.ok == false, "renaming directory into itself must fail")

local into_self_rel = panel_paths.resolve_input_from_context("./api/sub", {
    mode = "rename",
    worktree = worktree,
    current_dir = "src",
    target_path = "src/api",
    is_directory = true,
})
assert(into_self_rel.ok == false, "renaming directory into itself via ./ must fail")

-- Rejection: no-op same path
local noop_res = panel_paths.resolve_input_from_context("foo.ts", {
    mode = "rename",
    worktree = worktree,
    current_dir = "src/api",
    target_path = "src/api/foo.ts",
    is_directory = false,
})
assert(noop_res.ok == false, "no-op same path must fail")

-- Rejection: symlink escaping worktree
local symlink_escape_res = panel_paths.resolve_input_from_context("escape_link/evil.ts", {
    mode = "create",
    worktree = worktree,
    current_dir = "",
})
assert(symlink_escape_res.ok == false, "symlink escaping worktree must fail")

vim.fn.delete(worktree, "rf")
vim.fn.delete(outside_dir, "rf")

print("panel_paths_spec: ok")
