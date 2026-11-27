-- Pure boxed and plain message layout builders for thread popups and
-- conversation views.
local comment_text = require("jpr.render.comment_text")
local one_line = require("jpr.render.panel").one_line

local M = {}

local SYNC_BADGE = {
    draft = "[draft]",
    queued = "[queued]",
    pending = "[sending]",
    failed = "[failed]",
}

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

local function build_author_line(message, local_badge)
    local badge = SYNC_BADGE[message.sync] and (" " .. SYNC_BADGE[message.sync]) or ""
    local edited_tag = (message.updated and message.updated ~= message.created) and " (edited)" or ""
    local author_line = ("@%s · %s%s%s"):format(
        one_line(message.author or ""),
        one_line(message.created or ""),
        edited_tag,
        badge
    )
    if type(local_badge) == "string" and local_badge ~= "" then
        author_line = author_line .. " " .. local_badge
    end
    return author_line
end

local function append_plain_message(threads_mod, layout, message)
    layout.add(build_author_line(message), "JprAuthor")
    if message.syncError then
        layout.add("  error: " .. one_line(message.syncError), "JprError")
    end
    if message.recoverableBody then
        layout.add("  [concurrent edit on GitHub won; press e to recover your offline text]", "JprThreadDraft")
    end
    local body = comment_text.render_body(message.body)
    if body == "" then
        layout.add("  ")
    else
        for body_line in (body .. "\n"):gmatch("(.-)\n") do
            layout.add("  " .. body_line)
        end
    end
    local reaction_text = threads_mod.build_reactions_line(message.reactions)
    if reaction_text ~= "" then
        layout.add("  " .. reaction_text, "JprReactionActive")
    end
end

local function message_segments(threads_mod, message, local_badge)
    local segments = { { text = build_author_line(message, local_badge), group = "JprAuthor" } }
    if message.syncError then
        segments[#segments + 1] = { text = "error: " .. one_line(message.syncError), group = "JprError" }
    end
    if message.recoverableBody then
        segments[#segments + 1] = {
            text = "[concurrent edit on GitHub won; press e to recover your offline text]",
            group = "JprThreadDraft",
        }
    end
    segments[#segments + 1] = { text = comment_text.render_body(message.body), group = nil }
    local reaction_text = threads_mod.build_reactions_line(message.reactions)
    if reaction_text ~= "" then
        segments[#segments + 1] = { text = reaction_text, group = "JprReactionActive" }
    end
    return segments
end

local function append_boxed_message(threads_mod, layout, message, opts)
    local box_lines = comment_text.build_box_lines(
        message_segments(threads_mod, message, opts.local_badge),
        opts.width,
        opts.indent
    )
    for _, row in ipairs(box_lines) do
        layout.add(row.text, row.group)
    end
end

--- Appends one formatted `message` from `thread` into `layout`.
function M.append_formatted_message(threads_mod, layout, thread, message, opts)
    local start_line = #layout.lines + 1
    if type(opts) == "table" and opts.box then
        append_boxed_message(threads_mod, layout, message, opts)
    else
        append_plain_message(threads_mod, layout, message)
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

local function append_popup_thread_title(threads_mod, layout, thread)
    local status = thread.state == "resolved" and "Resolved" or "Open"
    local outdated_tag = thread.outdated and " · Outdated" or ""
    local title_prefix = ("Thread (%s%s)"):format(status, outdated_tag)
    local local_badge = threads_mod.build_local_badge_from_thread(thread)
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

local function has_any_local_thread(threads_mod, threads)
    for _, thread in ipairs(threads or {}) do
        if threads_mod.is_local_thread(thread) then
            return true
        end
    end
    return false
end

--- Creates the lines, highlights, and cursor-to-message ranges for the thread popup.
function M.create_popup_layout_from_threads(threads_mod, threads, opts)
    local layout = M.create_message_layout()
    for index, thread in ipairs(threads or {}) do
        if index > 1 then
            layout.add(string.rep("─", 48), "JprMuted")
        end
        append_popup_thread_title(threads_mod, layout, thread)
        for _, message in ipairs(thread.messages or {}) do
            M.append_formatted_message(threads_mod, layout, thread, message)
            layout.add("")
        end
    end
    local include_footer = not opts or opts.include_footer ~= false
    if include_footer then
        local footer = has_any_local_thread(threads_mod, threads)
                and "[r]eply  [e]dit  [d]elete  [R]esolve  [+]react  [X]retry  [p]romote  [s]end  [q]uit"
            or "[r]eply  [e]dit  [d]elete  [R]esolve  [+]react  [X]retry  [q]uit"
        layout.add(footer, "JprMuted")
    end
    return layout
end

--- Finds the message range containing 1-based `cursor_line`, or the nearest preceding range.
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
