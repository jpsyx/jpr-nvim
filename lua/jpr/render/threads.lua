-- Pure: turns ThreadPreview lists into sign + EOL extmarks, expanded virtual
-- lines, reaction pills, and popup buffer layouts. No windows or buffers here.
local one_line = require("jpr.render.panel").one_line

local M = {}

--- Maps GitHub GraphQL `ReactionContent` names to display emoji.
M.REACTION_EMOJI = {
    THUMBS_UP = "👍",
    THUMBS_DOWN = "👎",
    LAUGH = "😄",
    HOORAY = "🎉",
    CONFUSED = "😕",
    HEART = "❤️",
    ROCKET = "🚀",
    EYES = "👀",
}

--- Canonical display order for GitHub reaction pills.
M.REACTION_ORDER = {
    "THUMBS_UP",
    "THUMBS_DOWN",
    "LAUGH",
    "HOORAY",
    "CONFUSED",
    "HEART",
    "ROCKET",
    "EYES",
}

local SYNC_BADGE = {
    draft = "[draft]",
    queued = "[queued]",
    pending = "[sending]",
    failed = "[failed]",
}

--- Picks the highest-priority sign character and highlight group for `threads`
--- on the same line: failed > draft > open published > resolved.
function M.pick_sign(threads)
    local has_draft, has_open = false, false
    for _, thread in ipairs(threads or {}) do
        if thread.kind == "failed" then
            return "!", "JprThreadFailed"
        elseif thread.kind == "draft" then
            has_draft = true
        elseif thread.state ~= "resolved" then
            has_open = true
        end
    end
    if has_draft then
        return "✎", "JprThreadDraft"
    elseif has_open then
        return "💬", "JprThreadPublished"
    end
    return "✓", "JprThreadResolved"
end

--- Builds the compact end-of-line `virt_text` chunks for `threads` on one line.
function M.build_eol_chunks(threads)
    local first = threads and threads[1]
    if not first then
        return {}
    end
    local _, group = M.pick_sign(threads)
    local message_count = first.messageCount or #(first.messages or {})
    local extra_messages = message_count - 1
    local count_tag = extra_messages > 0 and (" (+%d)"):format(extra_messages) or ""
    local more_threads = #threads > 1 and (" [+%d threads]"):format(#threads - 1) or ""
    local state_tag = first.state == "resolved" and " [resolved]" or (first.outdated and " [outdated]" or "")
    local label = ("  @%s: %s%s%s%s"):format(
        one_line(first.firstAuthor or ""),
        one_line(first.snippet or ""),
        count_tag,
        state_tag,
        more_threads
    )
    return { { label, group } }
end

--- Formats non-empty reactions on a message as a single line (`👍 2*  👀 1`).
function M.build_reactions_line(reactions)
    local parts = {}
    for _, reaction in ipairs(reactions or {}) do
        if (reaction.count or 0) > 0 then
            local emoji = one_line(M.REACTION_EMOJI[reaction.content] or reaction.content or "")
            local mine = reaction.viewerHasReacted and "*" or ""
            parts[#parts + 1] = ("%s %d%s"):format(emoji, reaction.count, mine)
        end
    end
    return table.concat(parts, "  ")
end

--- Builds `virt_lines` for inline expansion (`:Jpr expand`) of `threads`.
function M.build_expanded_virt_lines(threads, above_first)
    local virt_lines = {}
    for _, thread in ipairs(threads or {}) do
        local _, group = M.pick_sign({ thread })
        local header_tag = above_first and "[file thread] " or ""
        local resolved_tag = thread.state == "resolved" and " [resolved]" or ""
        for index, message in ipairs(thread.messages or {}) do
            local badge = SYNC_BADGE[message.sync] and (" " .. SYNC_BADGE[message.sync]) or ""
            local prefix = index == 1 and header_tag or "  ↳ "
            local header = ("  │ %s@%s%s%s"):format(
                prefix,
                one_line(message.author or ""),
                badge,
                index == 1 and resolved_tag or ""
            )
            virt_lines[#virt_lines + 1] = { { header, group } }
            for body_line in (tostring(message.body or "") .. "\n"):gmatch("(.-)\n") do
                virt_lines[#virt_lines + 1] = { { "  │   " .. body_line:gsub("\r$", ""), "Normal" } }
            end
            local reaction_text = M.build_reactions_line(message.reactions)
            if reaction_text ~= "" then
                virt_lines[#virt_lines + 1] = { { "  │   " .. reaction_text, "JprReactionActive" } }
            end
        end
    end
    return virt_lines
end

local function group_threads_by_line(threads, line_count)
    local grouped, ordered_lines = {}, {}
    for _, thread in ipairs(threads or {}) do
        local target = math.min(math.max(0, thread.displayLine or 1), math.max(1, line_count))
        if not grouped[target] then
            grouped[target] = {}
            ordered_lines[#ordered_lines + 1] = target
        end
        grouped[target][#grouped[target] + 1] = thread
    end
    table.sort(ordered_lines)
    return grouped, ordered_lines
end

--- Turns `threads` on a file buffer (`line_count` lines) into extmark specs.
function M.create_extmarks_from_threads(threads, line_count, opts)
    local expanded = opts and opts.expanded or false
    local grouped, ordered_lines = group_threads_by_line(threads, line_count)
    local marks = {}
    for _, display_line in ipairs(ordered_lines) do
        local bucket = grouped[display_line]
        local row = math.max(0, display_line - 1)
        local sign_text, sign_hl = M.pick_sign(bucket)
        if display_line == 0 then
            marks[#marks + 1] = {
                line = 0,
                col = 0,
                opts = {
                    virt_lines = M.build_expanded_virt_lines(bucket, true),
                    virt_lines_above = true,
                },
            }
        else
            marks[#marks + 1] = {
                line = row,
                col = 0,
                opts = {
                    sign_text = sign_text,
                    sign_hl_group = sign_hl,
                    virt_text = not expanded and M.build_eol_chunks(bucket) or nil,
                    virt_text_pos = not expanded and "eol" or nil,
                },
            }
            if expanded then
                marks[#marks + 1] = {
                    line = row,
                    col = 0,
                    opts = { virt_lines = M.build_expanded_virt_lines(bucket, false) },
                }
            end
        end
    end
    return marks
end

local function append_popup_message(layout, thread, message)
    local start_line = #layout.lines + 1
    local badge = SYNC_BADGE[message.sync] and (" " .. SYNC_BADGE[message.sync]) or ""
    local updated = (message.updated and message.updated ~= message.created) and " (edited)" or ""
    local author_line = ("@%s · %s%s%s"):format(
        one_line(message.author or ""),
        one_line(message.created or ""),
        updated,
        badge
    )
    layout.add(author_line, "JprAuthor")
    if message.syncError then
        layout.add("  error: " .. one_line(message.syncError), "JprError")
    end
    if message.recoverableBody then
        layout.add("  [concurrent edit on GitHub won; press e to recover your offline text]", "JprThreadDraft")
    end
    for body_line in (tostring(message.body or "") .. "\n"):gmatch("(.-)\n") do
        layout.add("  " .. body_line:gsub("\r$", ""))
    end
    local reaction_text = M.build_reactions_line(message.reactions)
    if reaction_text ~= "" then
        layout.add("  " .. reaction_text, "JprReactionActive")
    end
    layout.message_ranges[#layout.message_ranges + 1] = {
        first = start_line,
        last = #layout.lines,
        thread_id = thread.threadId,
        message_id = message.id,
        message = message,
        thread = thread,
    }
end

--- Builds the lines, highlights, and cursor-to-message ranges for the thread popup.
function M.build_popup(threads)
    local layout = { lines = {}, highlights = {}, message_ranges = {} }
    function layout.add(text, group)
        layout.lines[#layout.lines + 1] = text
        if group then
            layout.highlights[#layout.highlights + 1] = {
                line = #layout.lines - 1,
                col_start = 0,
                col_end = #text,
                group = group,
            }
        end
    end
    for index, thread in ipairs(threads or {}) do
        if index > 1 then
            layout.add(string.rep("─", 48), "JprMuted")
        end
        local status = thread.state == "resolved" and "Resolved" or "Open"
        local outdated = thread.outdated and " · Outdated" or ""
        layout.add(("Thread (%s%s)"):format(status, outdated), "JprTitle")
        for _, message in ipairs(thread.messages or {}) do
            append_popup_message(layout, thread, message)
            layout.add("")
        end
    end
    layout.add("[r]eply  [e]dit  [d]elete  [R]esolve  [+]react  [X]retry  [q]uit", "JprMuted")
    return layout
end

--- Finds the message range containing 1-based `cursor_line`, or the nearest preceding range
--- (returning the first range before the first message, or nil if empty).
function M.find_message_at_line(popup_layout, cursor_line)
    local ranges = (popup_layout and popup_layout.message_ranges) or {}
    if #ranges == 0 then
        return nil
    end
    if not cursor_line or cursor_line < ranges[1].first then
        return ranges[1]
    end
    local matched = ranges[1]
    for _, entry in ipairs(ranges) do
        if cursor_line < entry.first then
            return matched
        end
        if cursor_line <= entry.last then
            return entry
        end
        matched = entry
    end
    return matched
end

return M
