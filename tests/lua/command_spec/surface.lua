return function(root)
    local jpr = require("jpr")
    local commands_schema = require("jpr.commands.schema")

local aliases_ok, aliases_error = commands_schema.validate_command_aliases()
assert(aliases_ok == true, "command aliases are valid: " .. tostring(aliases_error))
assert(
    vim.deep_equal(
        commands_schema.list_command_aliases(),
        {
            { alias = "full", command_id = "stream" },
            { alias = "review", command_id = "open" },
            { alias = "self", command_id = "local" },
        }
    ),
    "full, review, and self are the configured aliases: " .. vim.inspect(commands_schema.list_command_aliases())
)
assert(commands_schema.canonicalize_command_id("full") == "stream", "full resolves to stream")
assert(commands_schema.canonicalize_command_id("review") == "open", "review resolves to open")
assert(commands_schema.canonicalize_command_id("self") == "local", "self resolves to local")
assert(commands_schema.canonicalize_command_id("open") == "open", "a canonical id resolves to itself")
assert(commands_schema.canonicalize_command_id("frobnicate") == nil, "an unknown name does not resolve")
assert(not vim.tbl_contains(commands_schema.list_command_ids(), "full"), "full is not a command id")
assert(not vim.tbl_contains(commands_schema.list_command_ids(), "review"), "review is not a command id")
assert(not vim.tbl_contains(commands_schema.list_command_ids(), "self"), "self is not a command id")

assert(jpr.parse_pr_arg("123") == 123, "a bare number")
assert(jpr.parse_pr_arg("#45") == 45, "a hash number")
assert(jpr.parse_pr_arg("https://github.com/octo/widgets/pull/678") == 678, "a pull request URL")
assert(jpr.parse_pr_arg("https://github.com/octo/widgets/pull/678/files") == 678, "a files URL")
assert(select(2, jpr.parse_pr_arg("123")) == nil, "a bare number names no repository")
local url_number, url_repo = jpr.parse_pr_arg("https://github.com/octo/gadgets/pull/12/files")
assert(url_number == 12 and url_repo == "octo/gadgets", "a URL names its repository: " .. tostring(url_repo))
assert(jpr.parse_pr_arg("abc") == nil, "not a number")
assert(jpr.parse_pr_arg("0") == nil, "zero is not a valid PR ID")
assert(jpr.parse_pr_arg("#0") == nil, "hash zero is not a valid PR ID")
assert(jpr.parse_pr_arg("-5") == nil, "negative number is not a valid PR ID")
assert(jpr.parse_pr_arg("3.14") == nil, "float is not a valid PR ID")
assert(jpr.parse_pr_arg(nil) == nil, "missing")

local cargo_toml = table.concat(vim.fn.readfile(root .. "/Cargo.toml"), "\n") .. "\n["
local workspace_package = cargo_toml:match("%[workspace%.package%](.-)\n%[")
local cargo_version = workspace_package and workspace_package:match('\nversion%s*=%s*"([^"]+)"')
assert(cargo_version ~= nil and cargo_version:match("^%d+%.%d+%.%d+$"), "Cargo.toml defines a semver workspace version")
assert(
    jpr.VERSION == cargo_version,
    ("jpr.VERSION (%s) must match Cargo.toml workspace version (%s)"):format(tostring(jpr.VERSION), tostring(cargo_version))
)

assert(
    vim.deep_equal(
        jpr.complete("", "Jpr "),
        { "open", "local", "sync", "toggle", "panel", "stream", "comment", "suggest", "expand", "summary", "conversation", "pr-comment", "submit", "push", "agent", "send", "prepass", "close", "keys" }
    ),
    "all subcommands"
)
assert(vim.deep_equal(jpr.complete("k", "Jpr k"), { "keys" }), "filtered k subcommand")
assert(vim.deep_equal(jpr.complete("s", "Jpr s"), { "sync", "stream", "suggest", "summary", "submit", "send" }), "filtered s subcommands")
assert(vim.deep_equal(jpr.complete("p", "Jpr p"), { "panel", "pr-comment", "push", "prepass" }), "filtered p subcommands")
assert(vim.deep_equal(jpr.complete("c", "Jpr c"), { "comment", "conversation", "close" }), "filtered c subcommands")
assert(vim.deep_equal(jpr.complete("", "Jpr open "), {}), "nothing after open subcommand")
assert(vim.deep_equal(jpr.complete("", "Jpr toggle "), { "unified", "split" }), "toggle argument completions")
assert(vim.deep_equal(jpr.complete("s", "Jpr toggle s"), { "split" }), "filtered toggle argument completion")
assert(vim.deep_equal(jpr.complete("", "Jpr comment "), { "line", "file", "suggest" }), "comment argument completions")
assert(vim.deep_equal(jpr.complete("", "Jpr agent "), { "claude", "codex" }), "agent argument completions")
assert(vim.deep_equal(jpr.complete("", "Jpr toggle split "), {}), "no completions after subcommand argument")
assert(vim.deep_equal(jpr.complete("", "1,2 Jpr toggle "), { "unified", "split" }), "spaced range toggle completions")
assert(vim.deep_equal(jpr.complete("s", "1,2 Jpr toggle s"), { "split" }), "spaced range filtered toggle completion")
assert(vim.deep_equal(jpr.complete("c", "'<,'> Jpr c"), { "comment", "conversation", "close" }), "spaced visual range subcommands")
assert(vim.deep_equal(jpr.complete("f", "Jpr f"), {}), "full alias is not offered by completion")
assert(vim.deep_equal(jpr.complete("re", "Jpr re"), {}), "review alias is not offered by completion")
assert(vim.deep_equal(jpr.complete("r", "Jpr r"), {}), "review alias is not offered by a shorter prefix")

jpr.setup({ worktree_cmd = "wt pr {n}" })
assert(jpr.config.worktree_cmd == "wt pr {n}", "setup takes options")
assert(jpr.config.binary == nil, "setup keeps nil default binary so bundled target/release/jpr-review is used")
assert(jpr.binary_path() == root .. "/target/release/jpr-review", "binary_path resolves bundled release binary")
assert(jpr.config.keys.palette == "<leader>J", "setup keeps default palette key")
assert(jpr.config.keys.comment == "gc", "setup keeps default keys")
jpr.setup({ binary = "/tmp/custom" })
assert(jpr.binary_path() == "/tmp/custom", "binary_path honors explicit setup override")
jpr.setup({})

for _, group in ipairs({
    "JprModified",
    "JprThreadPublished",
    "JprThreadDraft",
    "JprThreadFailed",
    "JprThreadResolved",
    "JprReactionActive",
    "JprAuthor",
}) do
    assert(vim.fn.hlexists(group) == 1, group .. " highlight group exists")
end

dofile(root .. "/plugin/jpr.lua")
local jpr_command = vim.api.nvim_get_commands({})["Jpr"]
assert(jpr_command ~= nil, ":Jpr exists")
assert(jpr_command.nargs == "*", ":Jpr accepts zero or more arguments: " .. tostring(jpr_command.nargs))

for _, plug in ipairs({
    "<Plug>(jpr-palette)",
    "<Plug>(jpr-comment)",
    "<Plug>(jpr-suggest-comment)",
    "<Plug>(jpr-file-comment)",
    "<Plug>(jpr-pr-comment)",
    "<Plug>(jpr-full-diff)",
    "<Plug>(jpr-toggle-viewed)",
    "<Plug>(jpr-thread-popup)",
    "<Plug>(jpr-next-thread)",
    "<Plug>(jpr-prev-thread)",
}) do
    assert(vim.fn.maparg(plug, "n", false, true).lhs == plug, plug .. " exists in normal mode")
end
assert(vim.fn.maparg("<Plug>(jpr-toggle-viewed)", "x", false, true).lhs == nil, "toggle-viewed is Normal-mode only")
for _, plug in ipairs({ "<Plug>(jpr-comment)", "<Plug>(jpr-suggest-comment)" }) do
    assert(vim.fn.maparg(plug, "x", false, true).lhs == plug, plug .. " exists in visual mode")
end

assert(
    vim.fn.maparg("<leader>J", "n", false, true).rhs == "<Plug>(jpr-palette)",
    "plugin/jpr.lua binds default <leader>J to <Plug>(jpr-palette)"
)
jpr.setup({ keys = { palette = false } })
assert(vim.fn.maparg("<leader>J", "n", false, true).lhs == nil, "disabling palette key removes default <leader>J")
assert(
    vim.fn.maparg("<Plug>(jpr-palette)", "n", false, true).lhs == "<Plug>(jpr-palette)",
    "<Plug>(jpr-palette) remains defined when palette key is disabled"
)
jpr.setup({ keys = { palette = "<leader>gj" } })
assert(
    vim.fn.maparg("<leader>gj", "n", false, true).rhs == "<Plug>(jpr-palette)",
    "custom palette key binds to <Plug>(jpr-palette)"
)
assert(vim.fn.maparg("<leader>J", "n", false, true).lhs == nil, "old default palette key stays unbound")
jpr.setup({})
assert(
    vim.fn.maparg("<leader>J", "n", false, true).rhs == "<Plug>(jpr-palette)",
    "default setup restores <leader>J mapping"
)
assert(vim.fn.maparg("<leader>gj", "n", false, true).lhs == nil, "previous custom palette key is cleaned up")

jpr.setup({ keys = { comment = false } })
local key_buf = vim.api.nvim_create_buf(false, true)
jpr.bind_buffer_keys(key_buf)
local function buf_map(buf, mode, lhs)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        if mapping.lhs == lhs then
            return mapping
        end
    end
    return nil
end
local function buf_has_map(buf, mode, lhs)
    return buf_map(buf, mode, lhs) ~= nil
end
assert(not buf_has_map(key_buf, "n", "gc") and not buf_has_map(key_buf, "x", "gc"), "disabled comment key is skipped")
assert(vim.fn.maparg("<Plug>(jpr-comment)", "n", false, true).lhs == "<Plug>(jpr-comment)", "<Plug>(jpr-comment) remains defined")
assert(buf_has_map(key_buf, "n", "gC") and buf_has_map(key_buf, "x", "gC"), "gC bound in n and x")
assert(buf_map(key_buf, "n", "gC").nowait == 1, "buffer keys use nowait")
assert(buf_has_map(key_buf, "n", "gf"), "gf bound in n")
assert(buf_has_map(key_buf, "n", "gF"), "gF bound in n")
assert(buf_has_map(key_buf, "n", "gv") and not buf_has_map(key_buf, "x", "gv"), "gv bound in n only")
assert(buf_has_map(key_buf, "n", "gt"), "gt bound in n")
assert(buf_has_map(key_buf, "n", "]t"), "]t bound in n")
assert(buf_has_map(key_buf, "n", "[t"), "[t bound in n")
assert(buf_has_map(key_buf, "n", "gp"), "gp bound to standalone PR comment")
assert(buf_has_map(key_buf, "n", "gP"), "gP bound to panel toggle")
vim.api.nvim_buf_delete(key_buf, { force = true })
jpr.setup({})


end
