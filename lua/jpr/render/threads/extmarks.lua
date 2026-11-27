-- Pure gutter signs, EOL thread preview chunks, reaction pills, and expanded
-- inline virtual lines for review threads.
local comment_text = require("jpr.render.comment_text")
local one_line = require("jpr.render.panel").one_line

local M = {}

local SYNC_BADGE = {
    draft = "[draft]",
    queued = "[queued]",
    pending = "[sending]",
    failed = "[failed]",
}

--- Picks the highest-priority sign character and highlight group for `threads`
--- on the same line: failed > draft > open local > open published > resolved.
function M.pick_sign(threads_mod, threads)
    local has_draft, has_local, has_open = false, false, false
    for _, thread in ipairs(threads or {}) do
        if thread.kind == "failed" then
            return "!", "JprThreadFailed"
        elseif thread.kind == "draft" then
            has_draft = true
        elseif thread.state ~= "resolved" then
            if threads_mod.is_local_thread(thread) then
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
function M.create_eol_chunks_from_threads(threads_mod, threads)
    local first_thread = threads and threads[1]
    if not first_thread then
        return {}
    end
    local _, group = M.pick_sign(threads_mod, threads)
    local message_count = first_thread.messageCount or #(first_thread.messages or {})
    local extra_messages = message_count - 1
    local count_tag = extra_messages > 0 and (" (+%d)"):format(extra_messages) or ""
    local local_badge = threads_mod.build_local_badge_from_thread(first_thread)
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
function M.build_reactions_line(threads_mod, reactions)
    local parts = {}
    for _, reaction in ipairs(reactions or {}) do
        if (reaction.count or 0) > 0 then
            local emoji = one_line(threads_mod.REACTION_EMOJI[reaction.content] or reaction.content or "")
            local mine = reaction.viewerHasReacted and "*" or ""
            parts[#parts + 1] = ("%s %d%s"):format(emoji, reaction.count, mine)
        end
    end
    return table.concat(parts, "  ")
end

--- Creates `virt_lines` for inline expansion (`:Jpr expand`) of `threads`.
function M.create_expanded_virt_lines_from_threads(threads_mod, threads, is_above_first)
    local virt_lines = {}
    for _, thread in ipairs(threads or {}) do
        local _, group = M.pick_sign(threads_mod, { thread })
        local header_tag = is_above_first and "[file thread] " or ""
        local local_badge = threads_mod.build_local_badge_from_thread(thread)
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
            for body_line in (comment_text.render_body(message.body) .. "\n"):gmatch("(.-)\n") do
                virt_lines[#virt_lines + 1] = { { "  │   " .. body_line, "Normal" } }
            end
            local reaction_text = M.build_reactions_line(threads_mod, message.reactions)
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
function M.create_extmarks_from_threads(threads_mod, threads, line_count, opts)
    local is_expanded = opts and opts.expanded or false
    local grouped, ordered_lines = group_threads_by_line(threads, line_count)
    local marks = {}
    for _, display_line in ipairs(ordered_lines) do
        local bucket = grouped[display_line]
        local row = math.max(0, display_line - 1)
        local sign_text, sign_hl = M.pick_sign(threads_mod, bucket)
        if display_line == 0 then
            marks[#marks + 1] = {
                line = 0,
                col = 0,
                opts = {
                    virt_lines = M.create_expanded_virt_lines_from_threads(threads_mod, bucket, true),
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
                    virt_text = not is_expanded and M.create_eol_chunks_from_threads(threads_mod, bucket) or nil,
                    virt_text_pos = not is_expanded and "eol" or nil,
                },
            }
            if is_expanded then
                marks[#marks + 1] = {
                    line = row,
                    col = 0,
                    opts = { virt_lines = M.create_expanded_virt_lines_from_threads(threads_mod, bucket, false) },
                }
            end
        end
    end
    return marks
end

return M
