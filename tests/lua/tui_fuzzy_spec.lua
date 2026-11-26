local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local fuzzy = require("jpr.tui.fuzzy")

local sample_commands = {
    { id = "open", label = "Open Pull Request", help = "Pick an open PR." },
    { id = "local", label = "Review Current Worktree", help = "Review local branch." },
    { id = "toggle", label = "Switch Diff View", help = "Toggle unified or split." },
    { id = "stream", label = "Open Stream View", help = "Continuous diff stream." },
    { id = "conversation", label = "Open PR Conversation", help = "Read PR comments." },
    { id = "keys", label = "Keyboard Shortcuts", help = "Show keyboard shortcuts." },
}

local function extract_ids(commands)
    local ids = {}
    for _, command in ipairs(commands) do
        ids[#ids + 1] = command.id
    end
    return ids
end

local function test_empty_and_whitespace_queries_preserve_original_order()
    local expected = { "open", "local", "toggle", "stream", "conversation", "keys" }
    assert(vim.deep_equal(extract_ids(fuzzy.filter_commands(sample_commands, nil)), expected), "nil query preserves order")
    assert(vim.deep_equal(extract_ids(fuzzy.filter_commands(sample_commands, "")), expected), "empty query preserves order")
    assert(vim.deep_equal(extract_ids(fuzzy.filter_commands(sample_commands, "   \t ")), expected), "whitespace query preserves order")
end

local function test_fuzzy_subsequence_matches_label_and_id_case_insensitively()
    local by_label = extract_ids(fuzzy.filter_commands(sample_commands, "sdiff"))
    assert(vim.deep_equal(by_label, { "toggle" }), "sdiff matches Switch Diff View: " .. vim.inspect(by_label))

    local by_id = extract_ids(fuzzy.filter_commands(sample_commands, "TOG"))
    assert(vim.deep_equal(by_id, { "toggle" }), "TOG matches toggle id: " .. vim.inspect(by_id))

    local by_initials = extract_ids(fuzzy.filter_commands(sample_commands, "rcw"))
    assert(vim.deep_equal(by_initials, { "local" }), "rcw matches Review Current Worktree: " .. vim.inspect(by_initials))
end

local function test_exact_id_and_prefix_matches_outrank_scattered_subsequences()
    local open_matches = extract_ids(fuzzy.filter_commands(sample_commands, "open"))
    assert(open_matches[1] == "open", "exact id match open ranks first: " .. vim.inspect(open_matches))
    assert(#open_matches == 3, "open matches open, stream, conversation: " .. vim.inspect(open_matches))

    local tight_score = fuzzy.score_match("diff", "Switch Diff View")
    local scattered_score = fuzzy.score_match("diff", "Draft In File Format")
    assert(tight_score ~= nil and scattered_score ~= nil, "both match diff")
    assert(tight_score > scattered_score, "consecutive word match outranks scattered subsequence")
end

local function test_ties_preserve_original_order_and_non_matches_return_empty()
    local tied_commands = {
        { id = "first", label = "Alpha One", help = "First." },
        { id = "second", label = "Alpha Two", help = "Second." },
    }
    local matched = extract_ids(fuzzy.filter_commands(tied_commands, "alpha"))
    assert(vim.deep_equal(matched, { "first", "second" }), "equal scores preserve original order")

    local none = fuzzy.filter_commands(sample_commands, "zzzz")
    assert(#none == 0, "non-matching query returns empty list")
    assert(fuzzy.score_match("xyz", "Open Pull Request") == nil, "non-matching score is nil")
end

test_empty_and_whitespace_queries_preserve_original_order()
test_fuzzy_subsequence_matches_label_and_id_case_insensitively()
test_exact_id_and_prefix_matches_outrank_scattered_subsequences()
test_ties_preserve_original_order_and_non_matches_return_empty()

print("tui_fuzzy_spec: ok")
