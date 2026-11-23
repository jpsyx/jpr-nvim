local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local render = require("jpr.tui.render")

local function collect_highlighted_texts(layout, group)
    local texts = {}
    for _, highlight in ipairs(layout.highlights) do
        if highlight.group == group then
            local line_text = layout.lines[highlight.line + 1] or ""
            texts[#texts + 1] = line_text:sub(highlight.col_start + 1, highlight.col_end)
        end
    end
    return texts
end

local function assert_no_em_dash(lines, label)
    local joined = table.concat(lines, "\n")
    assert(not joined:find("\226\128\148", 1, true), label .. ": must not contain em dash")
end

-- 1. wrap_text breaks on whitespace, hard-splits overlong words, and respects display width.
local wrapped = render.wrap_text("Pick an open pull request or enter a PR number.", 20)
assert(#wrapped >= 3, "long text wraps onto multiple lines: " .. vim.inspect(wrapped))
for _, wrapped_line in ipairs(wrapped) do
    assert(vim.fn.strdisplaywidth(wrapped_line) <= 20, "wrapped line exceeds width: " .. wrapped_line)
end

local hard_split = render.wrap_text("abcdefghij", 4)
assert(vim.deep_equal(hard_split, { "abcd", "efgh", "ij" }), "overlong word hard-splits: " .. vim.inspect(hard_split))

local utf8_split = render.wrap_text("αβγδεζ", 3)
assert(vim.deep_equal(utf8_split, { "αβγ", "δεζ" }), "UTF-8 overlong word splits on char boundaries: " .. vim.inspect(utf8_split))

local cjk_split = render.wrap_text("中文测试", 4)
assert(vim.deep_equal(cjk_split, { "中文", "测试" }), "double-width chars wrap by display width: " .. vim.inspect(cjk_split))

local cjk_tiny = render.wrap_text("中文", 1)
assert(vim.deep_equal(cjk_tiny, { "中", "文" }), "double-width char with max_width=1 makes forward progress")

-- 2. build_palette_layout renders labels, [id], hover-only helper text, session dimming, and wrapping.
local commands = {
    {
        id = "open",
        label = "Open Pull Request",
        help = "Pick an open pull request or enter a PR number to start reviewing.",
        requires_session = false,
    },
    {
        id = "sync",
        label = "Sync with GitHub",
        help = "Fetch the latest pull request commits and review threads.",
        requires_session = true,
    },
}

local palette_first = render.build_palette_layout(commands, 1, 44, { has_session = false })
assert_no_em_dash(palette_first.lines, "palette_first")
assert(palette_first.lines[1] == "▸ Open Pull Request  [open]", "selected command row: " .. tostring(palette_first.lines[1]))
assert(palette_first.cursor_line == 1, "cursor_line points to command 1")
assert(palette_first.item_for_line[1] == 1, "item_for_line maps command 1 primary line")

local joined_first = table.concat(palette_first.lines, "\n")
assert(joined_first:find("Pick an open pull request", 1, true) ~= nil, "selected command help appears")
assert(joined_first:find("Fetch the latest pull request", 1, true) == nil, "unselected command help MUST NOT appear")

-- Verify wrapped hover helper lines fit max_width and carry 4-space indent + item_for_line.
local sync_row_index
for line_index, line_text in ipairs(palette_first.lines) do
    if line_text == "  Sync with GitHub  [sync]" then
        sync_row_index = line_index
        break
    end
end
assert(sync_row_index ~= nil and sync_row_index > 2, "hover helper lines placed between command 1 and command 2")
for help_row = 2, sync_row_index - 1 do
    local help_line = palette_first.lines[help_row]
    assert(help_line:sub(1, 4) == "    ", "helper continuation indented by 4 spaces: " .. help_line)
    assert(vim.fn.strdisplaywidth(help_line) <= 44, "helper line fits max_width: " .. help_line)
    assert(palette_first.item_for_line[help_row] == 1, "helper line maps back to command 1")
end
assert(palette_first.item_for_line[sync_row_index] == 2, "item_for_line maps command 2 primary line")

-- Verify highlights: "▸ " in JprTitle, [open]/[sync] and Sync with GitHub (no session) in JprMuted.
assert(
    vim.deep_equal(collect_highlighted_texts(palette_first, "JprTitle"), { "▸ " }),
    "pointer highlighted in JprTitle: " .. vim.inspect(collect_highlighted_texts(palette_first, "JprTitle"))
)
local muted_first = collect_highlighted_texts(palette_first, "JprMuted")
assert(vim.tbl_contains(muted_first, "[open]"), "[open] muted")
assert(vim.tbl_contains(muted_first, "[sync]"), "[sync] muted")
assert(vim.tbl_contains(muted_first, "Sync with GitHub"), "requires_session label dimmed when has_session == false")
assert(
    palette_first.lines[#palette_first.lines] == "[j/k] move  [Enter/l] select  [q/Esc] close",
    "palette footer rendered"
)

-- Moving selected_index from 1 to 2 updates cursor_line and swaps hover helper text.
local palette_second = render.build_palette_layout(commands, 2, 80, { has_session = true })
assert(palette_second.lines[1] == "  Open Pull Request  [open]", "command 1 unselected")
assert(palette_second.lines[2] == "▸ Sync with GitHub  [sync]", "command 2 selected")
assert(palette_second.cursor_line == 2, "cursor_line moves to command 2")
local joined_second = table.concat(palette_second.lines, "\n")
assert(joined_second:find("Pick an open pull request", 1, true) == nil, "command 1 help removed on hover move")
assert(joined_second:find("Fetch the latest pull request", 1, true) ~= nil, "command 2 help shown on hover move")
local muted_second = collect_highlighted_texts(palette_second, "JprMuted")
assert(
    not vim.tbl_contains(muted_second, "Sync with GitHub"),
    "requires_session label not dimmed when has_session == true"
)

-- Empty command list handled safely without crashing.
local palette_empty = render.build_palette_layout({}, 1, 60, { has_session = false })
assert(#palette_empty.lines >= 3, "empty palette renders fallback and footer")
assert(palette_empty.cursor_line == 1, "empty palette sets safe cursor_line")

-- 3. build_step_layout renders header with dots, 1-sentence help, hover-only option help, and footers.
local active_steps = {
    {
        id = "source",
        label = "Pull Request Source",
        help = "Choose how to pick the pull request to review.",
        kind = "select",
        options = {
            {
                value = "list",
                label = "Pick from Open PRs",
                badge = "[list]",
                help = "Fetch open pull requests from GitHub.",
            },
            {
                value = "manual",
                label = "Enter PR Number or URL",
                badge = "[manual]",
                help = "Type a pull request number or link directly.",
            },
        },
    },
    {
        id = "pr",
        label = "Open Pull Requests",
        help = "Select a pull request from the repository.",
        kind = "async_select",
    },
}

local step_one = render.build_step_layout(commands[1], active_steps, 1, {
    selected_option_index = 1,
    can_return_to_palette = true,
}, 68)
assert_no_em_dash(step_one.lines, "step_one")
assert(
    step_one.lines[1] == "Step 1 of 2 · Pull Request Source  ● ○",
    "step 1 header with dots: " .. tostring(step_one.lines[1])
)
assert(step_one.lines[2] == "Choose how to pick the pull request to review.", "step 1 help line")
assert(step_one.lines[3] == "", "blank line after header")
assert(step_one.lines[4] == "▸ Pick from Open PRs  [list]", "selected option row: " .. tostring(step_one.lines[4]))
assert(step_one.cursor_line == 4, "cursor_line points to selected option")
assert(step_one.item_for_line[4] == 1 and step_one.item_for_line[5] == 1, "selected option and help map to option 1")
local step_one_joined = table.concat(step_one.lines, "\n")
assert(step_one_joined:find("Fetch open pull requests from GitHub.", 1, true) ~= nil, "selected option help shown")
assert(
    step_one_joined:find("Type a pull request number or link directly.", 1, true) == nil,
    "unselected option help hidden"
)
assert(
    step_one.lines[#step_one.lines] == "[j/k] move  [h] palette  [Enter/l] next  [q/Esc] close",
    "step 1 palette footer: " .. tostring(step_one.lines[#step_one.lines])
)
local step_one_titles = collect_highlighted_texts(step_one, "JprTitle")
assert(vim.tbl_contains(step_one_titles, "Step 1 of 2 · Pull Request Source"), "header title in JprTitle")
assert(vim.tbl_contains(step_one_titles, "●"), "active dot in JprTitle")
assert(vim.tbl_contains(step_one_titles, "▸ "), "option pointer in JprTitle")
local step_one_muted = collect_highlighted_texts(step_one, "JprMuted")
assert(vim.tbl_contains(step_one_muted, "○"), "inactive dot in JprMuted")
assert(vim.tbl_contains(step_one_muted, "[list]"), "option badge in JprMuted")

-- Loading state & validation error & step 2 final footer.
local step_two_loading = render.build_step_layout(commands[1], active_steps, 2, {
    is_loading = true,
    error_message = "Could not load pull requests.",
    can_return_to_palette = true,
}, 68)
assert(
    step_two_loading.lines[1] == "Step 2 of 2 · Open Pull Requests  ● ●",
    "step 2 header dots: " .. tostring(step_two_loading.lines[1])
)
local step_two_errors = collect_highlighted_texts(step_two_loading, "JprError")
assert(vim.tbl_contains(step_two_errors, "Could not load pull requests."), "error_message highlighted in JprError")
local step_two_joined = table.concat(step_two_loading.lines, "\n")
assert(step_two_joined:find("  Loading...", 1, true) ~= nil, "loading indicator rendered")
assert(
    step_two_loading.lines[#step_two_loading.lines] == "[j/k] move  [h] back  [Enter/l] run  [q/Esc] close",
    "final step footer: " .. tostring(step_two_loading.lines[#step_two_loading.lines])
)

-- Step 1 without palette omits [h] hint.
local step_direct_only = render.build_step_layout(commands[1], { active_steps[1] }, 1, {
    selected_option_index = 1,
    can_return_to_palette = false,
}, 68)
assert(
    step_direct_only.lines[#step_direct_only.lines] == "[j/k] move  [Enter/l] run  [q/Esc] close",
    "direct single-step footer omits back hint: " .. tostring(step_direct_only.lines[#step_direct_only.lines])
)

-- 4. build_text_step_virt_lines builds virt_lines for help, error, and separator.
local text_step = {
    id = "manual_pr",
    label = "Pull Request Number or URL",
    help = "Enter a PR number, #number, or GitHub URL.",
    kind = "text",
}
local virt_no_err = render.build_text_step_virt_lines(text_step, nil, 60)
assert(
    vim.deep_equal(virt_no_err, {
        { { "Enter a PR number, #number, or GitHub URL.", "JprMuted" } },
        { { "", "JprMuted" } },
    }),
    "virt_lines without error: " .. vim.inspect(virt_no_err)
)

local virt_with_err = render.build_text_step_virt_lines(text_step, "Invalid PR number.", 60)
assert(
    vim.deep_equal(virt_with_err, {
        { { "Enter a PR number, #number, or GitHub URL.", "JprMuted" } },
        { { "", "JprMuted" } },
        { { "Invalid PR number.", "JprError" } },
        { { "", "JprMuted" } },
    }),
    "virt_lines with error: " .. vim.inspect(virt_with_err)
)

-- 5. build_text_step_footer adapts to step position and palette availability.
assert(
    render.build_text_step_footer(1, 2, true) == "[Enter/Tab] next  [S-Tab] palette  [Esc] normal/cancel",
    "text footer step 1 with palette"
)
assert(
    render.build_text_step_footer(2, 2, true) == "[Enter/Tab] run  [S-Tab] back  [Esc] normal/cancel",
    "text footer final step > 1"
)
assert(
    render.build_text_step_footer(1, 1, false) == "[Enter/Tab] run  [Esc] normal/cancel",
    "text footer single direct step without palette"
)

-- 6. Edge cases: clamping, selected session-dimmed command, toggle step options, empty state, and option swap.
local clamped_high = render.build_palette_layout(commands, 99, 80, { has_session = false })
assert(clamped_high.cursor_line == 2, "out-of-range selected_index clamps to last command")
assert(
    vim.tbl_contains(collect_highlighted_texts(clamped_high, "JprMuted"), "Sync with GitHub"),
    "selected requires_session command also dims label when has_session == false"
)

local step_one_option_two = render.build_step_layout(commands[1], active_steps, 1, {
    selected_option_index = 2,
    can_return_to_palette = true,
}, 40)
-- At width 40, step.help (46 cols) wraps onto 2 lines (rows 2..3), blank row 4, option 1 on row 5, option 2 on row 6.
assert(step_one_option_two.lines[5] == "  Pick from Open PRs  [list]", "option 1 unselected")
assert(step_one_option_two.lines[6] == "▸ Enter PR Number or URL  [manual]", "option 2 selected")
assert(step_one_option_two.cursor_line == 6, "cursor_line moves to option 2")
assert(step_one_option_two.lines[7]:sub(1, 4) == "    ", "option 2 help indented")
assert(vim.fn.strdisplaywidth(step_one_option_two.lines[7]) <= 40, "option 2 help wraps within max_width")
local option_two_joined = table.concat(step_one_option_two.lines, "\n")
assert(option_two_joined:find("Fetch open pull requests", 1, true) == nil, "option 1 help hidden when option 2 hovered")
assert(option_two_joined:find("Type a pull request number", 1, true) ~= nil, "option 2 help shown when hovered")

local toggle_step = {
    id = "drafts",
    label = "Include Drafts",
    help = "Choose whether to include draft pull requests.",
    kind = "toggle",
    no_label = "No (default)",
    no_help = "Hide draft PRs.",
    yes_label = "Yes",
    yes_help = "Show draft PRs.",
}
local toggle_layout = render.build_step_layout(commands[1], { toggle_step }, 1, { selected_option_index = 2 }, 60)
assert(toggle_layout.lines[4] == "  No (default)", "toggle option 1 rendered")
assert(toggle_layout.lines[5] == "▸ Yes", "toggle option 2 selected")
assert(toggle_layout.lines[6] == "    Show draft PRs.", "toggle option 2 hover help rendered")
assert(
    table.concat(toggle_layout.lines, "\n"):find("Hide draft PRs.", 1, true) == nil,
    "toggle option 1 help hidden"
)

local empty_step_layout = render.build_step_layout(commands[1], active_steps, 2, {
    options = {},
    empty_message = "  No open pull requests found.",
}, 60)
assert(
    table.concat(empty_step_layout.lines, "\n"):find("  No open pull requests found.", 1, true) ~= nil,
    "custom empty_message rendered"
)

print("tui_render_spec: ok")
