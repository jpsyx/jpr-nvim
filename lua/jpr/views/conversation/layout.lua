-- Pure layout builder and buffer painter for the unified Diff summary and PR
-- conversation buffer.
local render = require("jpr.render.threads")

local M = {}

local namespace = vim.api.nvim_create_namespace("jpr-conversation")

local function filter_pr_threads(threads)
    return vim.tbl_filter(function(thread)
        return thread.anchor ~= nil and thread.anchor.kind == "pr"
    end, threads or {})
end

local function count_messages(threads)
    local num_messages = 0
    for _, thread in ipairs(threads) do
        num_messages = num_messages + #(thread.messages or {})
    end
    return num_messages
end

local function has_local_thread(threads)
    for _, thread in ipairs(threads or {}) do
        if render.is_local_thread(thread) then
            return true
        end
    end
    return false
end

local function highlight_local_badge(layout, range_index, badge)
    if badge == "" then
        return
    end
    local range = layout.message_ranges[range_index]
    for line_number = range.first, range.last do
        local column = layout.lines[line_number]:find(badge, 1, true)
        if column then
            layout.highlights[#layout.highlights + 1] = {
                line = line_number - 1,
                col_start = column - 1,
                col_end = column - 1 + #badge,
                group = "JprThreadLocal",
            }
            return
        end
    end
end

local function append_thread(layout, thread, width)
    local local_badge = render.build_local_badge_from_thread(thread)
    for index, message in ipairs(thread.messages or {}) do
        local range_index = #layout.message_ranges + 1
        render.append_formatted_message(layout, thread, message, {
            box = true,
            width = width,
            indent = index == 1 and 0 or 4,
            local_badge = index == 1 and local_badge or nil,
        })
        if index == 1 then
            highlight_local_badge(layout, range_index, local_badge)
        end
        layout.add("")
    end
end

local function build_diffstat_line_from_view(view)
    local files = (type(view) == "table" and type(view.files) == "table") and view.files or {}
    local total_additions = 0
    local total_deletions = 0
    for _, file in ipairs(files) do
        total_additions = total_additions + (tonumber(file.additions) or 0)
        total_deletions = total_deletions + (tonumber(file.deletions) or 0)
    end
    local file_word = #files == 1 and "file" or "files"
    local viewed_count = (type(view) == "table" and tonumber(view.viewedCount)) or 0
    return ("%d %s changed · +%d -%d · %d/%d viewed"):format(
        #files,
        file_word,
        total_additions,
        total_deletions,
        viewed_count,
        #files
    )
end

local function build_pr_metadata_line_from_pr(pr)
    local parts = {}
    if type(pr.author) == "string" and pr.author ~= "" then
        parts[#parts + 1] = "@" .. pr.author
    end
    local has_head = type(pr.headRef) == "string" and pr.headRef ~= ""
    local has_base = type(pr.baseRef) == "string" and pr.baseRef ~= ""
    if has_head and has_base then
        parts[#parts + 1] = ("%s -> %s"):format(pr.headRef, pr.baseRef)
    elseif has_head then
        parts[#parts + 1] = pr.headRef
    elseif has_base then
        parts[#parts + 1] = pr.baseRef
    end
    return #parts > 0 and table.concat(parts, " · ") or nil
end

local function append_pr_body_lines(layout, body)
    local normalized = tostring(body or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if vim.trim(normalized) == "" then
        layout.add("  (no PR description)", "JprMuted")
        return
    end
    for _, body_line in ipairs(vim.split(normalized, "\n", { plain = true })) do
        layout.add(body_line)
    end
end

local function append_diff_summary(layout, session, is_local)
    local view = type(session.view) == "table" and session.view or {}
    local pr = type(view.pr) == "table" and view.pr or nil
    local local_context = type(view.localContext) == "table" and view.localContext or nil
    if is_local then
        local branch = tostring((local_context and local_context.branch) or session.branch or "worktree")
        local base_ref = tostring((local_context and local_context.baseRef) or session.base_ref or "")
        local local_title = base_ref ~= "" and ("LOCAL %s vs %s"):format(branch, base_ref) or ("LOCAL %s"):format(branch)
        layout.add(local_title, "JprTitle")
        layout.add(build_diffstat_line_from_view(view), "JprMuted")
        layout.add("")
        layout.add("  (local worktree review; run :Jpr sync once a PR is open to load its description)", "JprMuted")
    else
        local pr_number = (pr and pr.number) or session.number or 0
        local pr_title = (pr and type(pr.title) == "string" and pr.title ~= "") and pr.title or "Diff summary"
        layout.add(("#%d %s"):format(pr_number, pr_title), "JprTitle")
        local metadata_line = pr and build_pr_metadata_line_from_pr(pr) or nil
        if metadata_line then
            layout.add(metadata_line, "JprMuted")
        end
        layout.add(build_diffstat_line_from_view(view), "JprMuted")
        layout.add("")
        append_pr_body_lines(layout, pr and pr.body or "")
    end
    layout.add("")
    layout.add("────────────────────────────────────────", "JprMuted")
    layout.add("")
end

--- Builds the lines, highlights, and message ranges for `session`'s PR conversation.
function M.create_layout_from_threads(session, threads, width)
    local pr_threads = filter_pr_threads(threads)
    local layout = render.create_message_layout()
    local is_local = session.mode == "local" and not (session.view and session.view.pr)
    append_diff_summary(layout, session, is_local)
    layout.conversation_start_line = #layout.lines + 1
    local title = is_local
            and ("Local Notes (%d comments)"):format(count_messages(pr_threads))
        or ("Conversation (%d comments)"):format(count_messages(pr_threads))
    layout.add(title, "JprTitle")
    layout.add("")
    if #pr_threads == 0 then
        local empty_hint = is_local and "  (no local notes yet; press c to add one)"
            or "  (no PR conversation comments yet; press c to post one)"
        layout.add(empty_hint, "JprMuted")
        layout.add("")
    else
        for _, thread in ipairs(pr_threads) do
            append_thread(layout, thread, width)
        end
    end
    local footer
    if is_local then
        footer = "[c]omment  [r]eply  [e]dit  [d]elete  [s]end  [q]uit"
    elseif has_local_thread(pr_threads) then
        footer = "[c]omment  [r]eply  [e]dit  [d]elete  [p]romote  [s]end  [+]react  [X]retry  [q]uit"
    else
        footer = "[c]omment  [e]dit  [d]elete  [+]react  [X]retry  [q]uit"
    end
    layout.add(footer, "JprMuted")
    return layout
end

--- Paints `layout` into `buf` and restores window cursors clamped to the new line count.
function M.paint_buffer(buf, layout)
    local cursors = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        cursors[win] = vim.api.nvim_win_get_cursor(win)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, layout.lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    for _, highlight in ipairs(layout.highlights) do
        vim.api.nvim_buf_set_extmark(buf, namespace, highlight.line, highlight.col_start, {
            end_col = highlight.col_end,
            hl_group = highlight.group,
            strict = false,
        })
    end
    for win, cursor in pairs(cursors) do
        local clamped_line = math.max(1, math.min(cursor[1], #layout.lines))
        pcall(vim.api.nvim_win_set_cursor, win, { clamped_line, cursor[2] })
    end
end

return M
