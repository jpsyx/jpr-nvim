local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local commands_schema = require("jpr.commands.schema")

local aliases_ok, aliases_error = commands_schema.validate_command_aliases()
assert(aliases_ok == true, "command aliases are valid: " .. tostring(aliases_error))
assert(
    vim.deep_equal(commands_schema.list_command_aliases(), { { alias = "review", command_id = "open" } }),
    "review is the configured alias for open: " .. vim.inspect(commands_schema.list_command_aliases())
)
assert(commands_schema.resolve_command_id("review") == "open", "review resolves to open")
assert(commands_schema.resolve_command_id("open") == "open", "a canonical id resolves to itself")
assert(commands_schema.resolve_command_id("frobnicate") == nil, "an unknown name does not resolve")
assert(not vim.tbl_contains(commands_schema.list_command_ids(), "review"), "review is not a command id")

assert(jpr.parse_pr_arg("123") == 123, "a bare number")
assert(jpr.parse_pr_arg("#45") == 45, "a hash number")
assert(jpr.parse_pr_arg("https://github.com/octo/widgets/pull/678") == 678, "a pull request URL")
assert(jpr.parse_pr_arg("https://github.com/octo/widgets/pull/678/files") == 678, "a files URL")
assert(select(2, jpr.parse_pr_arg("123")) == nil, "a bare number names no repository")
local url_number, url_repo = jpr.parse_pr_arg("https://github.com/octo/gadgets/pull/12/files")
assert(url_number == 12 and url_repo == "octo/gadgets", "a URL names its repository: " .. tostring(url_repo))
assert(jpr.parse_pr_arg("abc") == nil, "not a number")
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
        { "open", "local", "sync", "toggle", "stream", "comment", "suggest", "expand", "conversation", "submit", "push", "agent", "send", "prepass", "close", "keys" }
    ),
    "all subcommands"
)
assert(vim.deep_equal(jpr.complete("k", "Jpr k"), { "keys" }), "filtered k subcommand")
assert(vim.deep_equal(jpr.complete("s", "Jpr s"), { "sync", "stream", "suggest", "submit", "send" }), "filtered s subcommands")
assert(vim.deep_equal(jpr.complete("p", "Jpr p"), { "push", "prepass" }), "filtered p subcommands")
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
assert(vim.deep_equal(jpr.complete("re", "Jpr re"), {}), "review alias is not offered by completion")
assert(vim.deep_equal(jpr.complete("r", "Jpr r"), {}), "review alias is not offered by a shorter prefix")

jpr.setup({ worktree_cmd = "wt pr {n}" })
assert(jpr.config.worktree_cmd == "wt pr {n}", "setup takes options")
assert(jpr.config.binary == nil, "setup keeps nil default binary so bundled target/release/jpr-review is used")
assert(jpr.binary_path() == root .. "/target/release/jpr-review", "binary_path resolves bundled release binary")
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
    "<Plug>(jpr-comment)",
    "<Plug>(jpr-suggest-comment)",
    "<Plug>(jpr-file-comment)",
    "<Plug>(jpr-thread-popup)",
    "<Plug>(jpr-next-thread)",
    "<Plug>(jpr-prev-thread)",
}) do
    assert(vim.fn.maparg(plug, "n", false, true).lhs == plug, plug .. " exists in normal mode")
end
for _, plug in ipairs({ "<Plug>(jpr-comment)", "<Plug>(jpr-suggest-comment)" }) do
    assert(vim.fn.maparg(plug, "x", false, true).lhs == plug, plug .. " exists in visual mode")
end

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
assert(buf_has_map(key_buf, "n", "gt"), "gt bound in n")
assert(buf_has_map(key_buf, "n", "]t"), "]t bound in n")
assert(buf_has_map(key_buf, "n", "[t"), "[t bound in n")
vim.api.nvim_buf_delete(key_buf, { force = true })
jpr.setup({})

local messages = {}
vim.notify = function(message, level)
    messages[#messages + 1] = { text = message, level = level }
end
jpr.command({ "frobnicate" })
assert(messages[1].level == vim.log.levels.ERROR, "an unknown subcommand is an error")
assert(messages[1].text:find("unknown subcommand", 1, true), messages[1].text)
jpr.command({ "open", "abc" })
assert(messages[2].level == vim.log.levels.ERROR, "open with invalid arg emits ERROR")
assert(messages[2].text:find("invalid pull request", 1, true), "open with invalid arg mentions invalid pull request: " .. messages[2].text)
jpr.warn("watch out")
assert(messages[3].level == vim.log.levels.WARN, "jpr.warn emits WARN level")
assert(messages[3].text == "jpr: watch out", messages[3].text)

local opened = {}
package.loaded["jpr.session"] = {
    open = function(number, repo)
        opened = { number = number, repo = repo }
    end,
}
jpr.command({ "open", "https://github.com/octo/gadgets/pull/12" })
assert(opened.number == 12 and opened.repo == "octo/gadgets", ":Jpr open passes the URL's repository on: " .. vim.inspect(opened))
opened = {}
jpr.command({ "review", "123" })
assert(opened.number == 123 and opened.repo == nil, ":Jpr review 123 opens pull request 123: " .. vim.inspect(opened))
opened = {}
jpr.command({ "review", "#45" })
assert(opened.number == 45 and opened.repo == nil, ":Jpr review #45 opens pull request 45: " .. vim.inspect(opened))
opened = {}
jpr.command({ "review", "https://github.com/octo/gadgets/pull/9/files" })
assert(opened.number == 9 and opened.repo == "octo/gadgets", ":Jpr review passes the URL's repository on: " .. vim.inspect(opened))
local review_message_count = #messages
jpr.command({ "review", "abc" })
assert(messages[review_message_count + 1].level == vim.log.levels.ERROR, "review with an invalid arg emits ERROR")
assert(
    messages[review_message_count + 1].text:find("invalid pull request", 1, true),
    "review with an invalid arg matches open: " .. messages[review_message_count + 1].text
)
jpr.command({ "review", "1", "extra" })
assert(
    messages[review_message_count + 2].text:find("too many arguments", 1, true),
    "review rejects extra arguments: " .. messages[review_message_count + 2].text
)
package.loaded["jpr.session"] = nil

local calls = {}
package.loaded["jpr.session"] = {
    toggle_view = function()
        calls[#calls + 1] = { fn = "toggle_view" }
    end,
    comment_current = function(opts)
        calls[#calls + 1] = { fn = "comment_current", opts = opts }
    end,
    suggest_current = function()
        calls[#calls + 1] = { fn = "suggest_current" }
    end,
    expand_current = function()
        calls[#calls + 1] = { fn = "expand_current" }
    end,
    conversation_current = function()
        calls[#calls + 1] = { fn = "conversation_current" }
    end,
    submit_current = function()
        calls[#calls + 1] = { fn = "submit_current" }
    end,
    push_current = function()
        calls[#calls + 1] = { fn = "push_current" }
    end,
    popup_current = function()
        calls[#calls + 1] = { fn = "popup_current" }
    end,
    jump_thread_current = function(step)
        calls[#calls + 1] = { fn = "jump_thread_current", step = step }
    end,
}

jpr.command({ "toggle" })
jpr.command({ "suggest" })
jpr.command({ "expand" })
jpr.command({ "conversation" })
jpr.command({ "submit" })
jpr.command({ "push" })

local range_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, range_buf)
vim.api.nvim_buf_set_lines(range_buf, 0, -1, false, { "one", "two", "three", "four", "five" })
vim.cmd("1,2Jpr comment")

jpr.action("comment")
jpr.action("suggest_comment")
jpr.action("file_comment")
jpr.action("thread_popup")
jpr.action("next_thread")
jpr.action("prev_thread")

assert(calls[1].fn == "toggle_view")
assert(calls[2].fn == "suggest_current")
assert(calls[3].fn == "expand_current")
assert(calls[4].fn == "conversation_current")
assert(calls[5].fn == "submit_current")
assert(calls[6].fn == "push_current")
assert(calls[7].fn == "comment_current" and calls[7].opts.line1 == 1 and calls[7].opts.line2 == 2 and calls[7].opts.range == 2)
assert(calls[8].fn == "comment_current" and not calls[8].opts.suggest and not calls[8].opts.file)
assert(calls[9].fn == "comment_current" and calls[9].opts.suggest == true)
assert(calls[10].fn == "comment_current" and calls[10].opts.file == true)
assert(calls[11].fn == "popup_current")
assert(calls[12].fn == "jump_thread_current" and calls[12].step == 1)
assert(calls[13].fn == "jump_thread_current" and calls[13].step == -1)

jpr.bind_buffer_keys(range_buf)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys("gc", "xt", false)
local normal_comment = calls[#calls]
assert(
    normal_comment.fn == "comment_current"
        and normal_comment.opts.line1 == nil
        and not normal_comment.opts.suggest
        and vim.fn.mode(1) == "n",
    "normal gc: " .. vim.inspect(normal_comment)
)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys("gC", "xt", false)
local normal_suggest = calls[#calls]
assert(
    normal_suggest.fn == "comment_current"
        and normal_suggest.opts.line1 == nil
        and normal_suggest.opts.suggest == true
        and vim.fn.mode(1) == "n",
    "normal gC: " .. vim.inspect(normal_suggest)
)

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys("Vjjgc", "xt", false)
local visual_comment = calls[#calls]
assert(
    visual_comment.fn == "comment_current"
        and visual_comment.opts.line1 == 1
        and visual_comment.opts.line2 == 3
        and visual_comment.opts.range == 2
        and not visual_comment.opts.suggest
        and vim.fn.mode(1) == "n",
    "visual Vjjgc: " .. vim.inspect(visual_comment) .. " mode=" .. vim.fn.mode(1)
)

vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_feedkeys("VjjgC", "xt", false)
local visual_suggest = calls[#calls]
assert(
    visual_suggest.fn == "comment_current"
        and visual_suggest.opts.line1 == 2
        and visual_suggest.opts.line2 == 4
        and visual_suggest.opts.range == 2
        and visual_suggest.opts.suggest == true
        and vim.fn.mode(1) == "n",
    "visual VjjgC: " .. vim.inspect(visual_suggest) .. " mode=" .. vim.fn.mode(1)
)

vim.api.nvim_win_set_cursor(0, { 4, 0 })
vim.api.nvim_feedkeys("Vkk", "xt", false)
vim.api.nvim_feedkeys("gc", "xt", false)
local reverse_visual = calls[#calls]
assert(
    reverse_visual.fn == "comment_current"
        and reverse_visual.opts.line1 == 2
        and reverse_visual.opts.line2 == 4
        and reverse_visual.opts.range == 2
        and not reverse_visual.opts.suggest
        and vim.fn.mode(1) == "n",
    "reverse visual Vkk gc: " .. vim.inspect(reverse_visual) .. " mode=" .. vim.fn.mode(1)
)

vim.cmd("1,2Jpr comment line")
local ranged_line = calls[#calls]
assert(
    ranged_line.fn == "comment_current"
        and ranged_line.opts.line1 == 1
        and ranged_line.opts.line2 == 2
        and ranged_line.opts.range == 2
        and not ranged_line.opts.suggest
        and not ranged_line.opts.file,
    "1,2Jpr comment line preserves range: " .. vim.inspect(ranged_line)
)

vim.cmd("1,2Jpr comment suggest")
local ranged_suggest = calls[#calls]
assert(
    ranged_suggest.fn == "comment_current"
        and ranged_suggest.opts.line1 == 1
        and ranged_suggest.opts.line2 == 2
        and ranged_suggest.opts.range == 2
        and ranged_suggest.opts.suggest == true,
    "1,2Jpr comment suggest preserves range: " .. vim.inspect(ranged_suggest)
)

local extra_before = #messages
jpr.command({ "toggle", "split", "extra" })
assert(#messages == extra_before + 1 and messages[#messages].level == vim.log.levels.ERROR, "extra arg on toggle errors")
assert(messages[#messages].text:find("too many arguments", 1, true) ~= nil, messages[#messages].text)

local zero_arg_before = #messages
jpr.command({ "sync", "unexpected" })
assert(#messages == zero_arg_before + 1 and messages[#messages].level == vim.log.levels.ERROR, "arg on sync errors")
assert(messages[#messages].text:find("does not accept arguments", 1, true) ~= nil, messages[#messages].text)

vim.api.nvim_buf_delete(range_buf, { force = true })
package.loaded["jpr.session"] = nil

print("command_spec: ok")
