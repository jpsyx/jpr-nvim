return function()
    local jpr = require("jpr")

local messages = {}
require("jpr.notify").set_listener(function(_, message, level)
    messages[#messages + 1] = { text = "jpr: " .. message, level = level }
end)
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

opened = {}
jpr.command({ "123" })
assert(opened.number == 123 and opened.repo == nil, ":Jpr 123 aliases :Jpr open 123: " .. vim.inspect(opened))

opened = {}
jpr.command({ "#456" })
assert(opened.number == 456 and opened.repo == nil, ":Jpr #456 aliases :Jpr open #456: " .. vim.inspect(opened))

opened = {}
jpr.command({ "https://github.com/octo/gadgets/pull/78" })
assert(opened.number == 78 and opened.repo == "octo/gadgets", ":Jpr <url> aliases :Jpr open <url>: " .. vim.inspect(opened))

local before_invalid_pr_id = #messages
jpr.command({ "0" })
assert(#messages == before_invalid_pr_id + 1 and messages[#messages].level == vim.log.levels.ERROR, ":Jpr 0 emits ERROR")
assert(messages[#messages].text:find("invalid pull request", 1, true) ~= nil, messages[#messages].text)

jpr.command({ "-7" })
assert(messages[#messages].level == vim.log.levels.ERROR, ":Jpr -7 emits ERROR")
assert(messages[#messages].text:find("invalid pull request", 1, true) ~= nil, messages[#messages].text)

jpr.command({ "3.14" })
assert(messages[#messages].level == vim.log.levels.ERROR, ":Jpr 3.14 emits ERROR")
assert(messages[#messages].text:find("invalid pull request", 1, true) ~= nil, messages[#messages].text)

jpr.command({ "123", "extra" })
assert(messages[#messages].level == vim.log.levels.ERROR, ":Jpr 123 extra emits ERROR")
assert(messages[#messages].text:find("too many arguments", 1, true) ~= nil, messages[#messages].text)
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
    summary_current = function()
        calls[#calls + 1] = { fn = "summary_current" }
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
jpr.command({ "summary" })
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
assert(calls[4].fn == "summary_current")
assert(calls[5].fn == "conversation_current")
assert(calls[6].fn == "submit_current")
assert(calls[7].fn == "push_current")
assert(calls[8].fn == "comment_current" and calls[8].opts.line1 == 1 and calls[8].opts.line2 == 2 and calls[8].opts.range == 2)
assert(calls[9].fn == "comment_current" and not calls[9].opts.suggest and not calls[9].opts.file)
assert(calls[10].fn == "comment_current" and calls[10].opts.suggest == true)
assert(calls[11].fn == "comment_current" and calls[11].opts.file == true)
assert(calls[12].fn == "popup_current")
assert(calls[13].fn == "jump_thread_current" and calls[13].step == 1)
assert(calls[14].fn == "jump_thread_current" and calls[14].step == -1)

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


end
