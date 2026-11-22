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

--- Canonical order of GitHub reaction choices in the reaction picker.
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

--- Whether `thread` is anchored to the base (`LEFT`) side of a code diff.
function M.is_left_thread(thread)
    return thread ~= nil
        and thread.anchor ~= nil
        and thread.anchor.kind ~= "file"
        and thread.anchor.side == "LEFT"
end

--- Splits `threads` into `{ left_threads, right_threads }` by diff side.
function M.partition_threads_by_side(threads)
    local left_threads, right_threads = {}, {}
    for _, thread in ipairs(threads or {}) do
        if M.is_left_thread(thread) then
            left_threads[#left_threads + 1] = thread
        else
            right_threads[#right_threads + 1] = thread
        end
    end
    return left_threads, right_threads
end

--- Whether `thread` is a local-only thread (created for the agent loop).
function M.is_local_thread(thread)
    return type(thread) == "table" and (thread.origin == "local" or thread.kind == "local")
end

--- Formats the agent delivery state and promotion badge for a local thread,
--- or returns `""` for non-local threads.
function M.build_local_badge_from_thread(thread)
    if not M.is_local_thread(thread) then
        return ""
    end
    local agent = type(thread.agent) == "table" and thread.agent or nil
    local badge = "[local]"
    if agent and agent.state == "unsent" then
        badge = "[local · unsent]"
    elseif agent and agent.state == "sent" then
        local round = type(agent.round) == "number" and agent.round or 1
        badge = ("[local · sent #%d]"):format(round)
    elseif agent and agent.state == "answered" then
        badge = "[local · answered]"
    end
    local is_promoted = thread.promotedTo ~= nil and thread.promotedTo ~= vim.NIL and thread.promotedTo ~= ""
    return is_promoted and (badge .. " [promoted]") or badge
end

--- Picks the highest-priority sign character and highlight group for `threads`
--- on the same line: failed > draft > open local > open published > resolved.
function M.pick_sign(threads)
    local has_draft, has_local, has_open = false, false, false
    for _, thread in ipairs(threads or {}) do
        if thread.kind == "failed" then
            return "!", "JprThreadFailed"
        elseif thread.kind == "draft" then
            has_draft = true
        elseif thread.state ~= "resolved" then
            if M.is_local_thread(thread) then
                has_local = true
            else
                has_open = true
            end
        end
    end
    if has_draft then
        return "✎", "JprThreadDraft"
    elseif has_local then
        return "◆", "JprThreadLocal"
    elseif has_open then
        return "💬", "JprThreadPublished"
    end
    return "✓", "JprThreadResolved"
end

--- Creates the compact end-of-line `virt_text` chunks for `threads` on one line.
function M.create_eol_chunks_from_threads(threads)
    local first_thread = threads and threads[1]
    if not first_thread then
        return {}
    end
    local _, group = M.pick_sign(threads)
    local message_count = first_thread.messageCount or #(first_thread.messages or {})
    local extra_messages = message_count - 1
    local count_tag = extra_messages > 0 and (" (+%d)"):format(extra_messages) or ""
    local local_badge = M.build_local_badge_from_thread(first_thread)
    local local_tag = local_badge ~= "" and (" " .. local_badge) or ""
    local more_threads = #threads > 1 and (" [+%d threads]"):format(#threads - 1) or ""
    local state_tag = first_thread.state == "resolved" and " [resolved]"
        or (first_thread.outdated and " [outdated]" or "")
    local label = ("  @%s: %s%s%s%s%s"):format(
        one_line(first_thread.firstAuthor or ""),
        one_line(first_thread.snippet or ""),
        count_tag,
        local_tag,
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

--- Creates `virt_lines` for inline expansion (`:Jpr expand`) of `threads`.
function M.create_expanded_virt_lines_from_threads(threads, is_above_first)
    local virt_lines = {}
    for _, thread in ipairs(threads or {}) do
        local _, group = M.pick_sign({ thread })
        local header_tag = is_above_first and "[file thread] " or ""
        local local_badge = M.build_local_badge_from_thread(thread)
        local local_tag = local_badge ~= "" and (" " .. local_badge) or ""
        local resolved_tag = thread.state == "resolved" and " [resolved]" or ""
        for index, message in ipairs(thread.messages or {}) do
            local badge = SYNC_BADGE[message.sync] and (" " .. SYNC_BADGE[message.sync]) or ""
            local prefix = index == 1 and header_tag or "  ↳ "
            local header = ("  │ %s@%s%s%s%s"):format(
                prefix,
                one_line(message.author or ""),
                badge,
                index == 1 and local_tag or "",
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
    local is_expanded = opts and opts.expanded or false
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
                    virt_lines = M.create_expanded_virt_lines_from_threads(bucket, true),
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
                    virt_text = not is_expanded and M.create_eol_chunks_from_threads(bucket) or nil,
                    virt_text_pos = not is_expanded and "eol" or nil,
                },
            }
            if is_expanded then
                marks[#marks + 1] = {
                    line = row,
                    col = 0,
                    opts = { virt_lines = M.create_expanded_virt_lines_from_threads(bucket, false) },
                }
            end
        end
    end
    return marks
end

--- Creates an empty `{ lines, highlights, message_ranges, add }` layout buffer.
function M.create_message_layout()
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
    return layout
end

--- Appends one formatted `message` (author, sync error, recovery banner, body,
--- reactions, and cursor range) from `thread` into `layout`.
function M.append_formatted_message(layout, thread, message)
    local start_line = #layout.lines + 1
    local badge = SYNC_BADGE[message.sync] and (" " .. SYNC_BADGE[message.sync]) or ""
    local edited_tag = (message.updated and message.updated ~= message.created) and " (edited)" or ""
    local author_line = ("@%s · %s%s%s"):format(
        one_line(message.author or ""),
        one_line(message.created or ""),
        edited_tag,
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
        thread_id = thread.threadId or thread.id,
        message_id = message.id,
        message = message,
        thread = thread,
    }
end

local function append_popup_thread_title(layout, thread)
    local status = thread.state == "resolved" and "Resolved" or "Open"
    local outdated_tag = thread.outdated and " · Outdated" or ""
    local title_prefix = ("Thread (%s%s)"):format(status, outdated_tag)
    local local_badge = M.build_local_badge_from_thread(thread)
    if local_badge == "" then
        return layout.add(title_prefix, "JprTitle")
    end
    local line = #layout.lines
    layout.add(title_prefix .. " " .. local_badge)
    layout.highlights[#layout.highlights + 1] = {
        line = line,
        col_start = 0,
        col_end = #title_prefix,
        group = "JprTitle",
    }
    layout.highlights[#layout.highlights + 1] = {
        line = line,
        col_start = #title_prefix + 1,
        col_end = #title_prefix + 1 + #local_badge,
        group = "JprThreadLocal",
    }
end

local function has_any_local_thread(threads)
    for _, thread in ipairs(threads or {}) do
        if M.is_local_thread(thread) then
            return true
        end
    end
    return false
end

--- Creates the lines, highlights, and cursor-to-message ranges for the thread popup.
function M.create_popup_layout_from_threads(threads)
    local layout = M.create_message_layout()
    for index, thread in ipairs(threads or {}) do
        if index > 1 then
            layout.add(string.rep("─", 48), "JprMuted")
        end
        append_popup_thread_title(layout, thread)
        for _, message in ipairs(thread.messages or {}) do
            M.append_formatted_message(layout, thread, message)
            layout.add("")
        end
    end
    local footer = has_any_local_thread(threads)
            and "[r]eply  [e]dit  [d]elete  [R]esolve  [+]react  [X]retry  [p]romote  [s]end  [q]uit"
        or "[r]eply  [e]dit  [d]elete  [R]esolve  [+]react  [X]retry  [q]uit"
    layout.add(footer, "JprMuted")
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
