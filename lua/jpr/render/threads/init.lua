-- Pure: turns ThreadPreview lists into sign + EOL extmarks, expanded virtual
-- lines, reaction pills, and popup buffer layouts. No windows or buffers here.
local extmarks = require("jpr.render.threads.extmarks")
local popup_layout = require("jpr.render.threads.popup_layout")

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

--- Picks the highest-priority sign character and highlight group for `threads`.
function M.pick_sign(threads)
    return extmarks.pick_sign(M, threads)
end

--- Creates the compact end-of-line `virt_text` chunks for `threads` on one line.
function M.create_eol_chunks_from_threads(threads)
    return extmarks.create_eol_chunks_from_threads(M, threads)
end

--- Formats non-empty reactions on a message as a single line (`👍 2*  👀 1`).
function M.build_reactions_line(reactions)
    return extmarks.build_reactions_line(M, reactions)
end

--- Creates `virt_lines` for inline expansion (`:Jpr expand`) of `threads`.
function M.create_expanded_virt_lines_from_threads(threads, is_above_first)
    return extmarks.create_expanded_virt_lines_from_threads(M, threads, is_above_first)
end

--- Turns `threads` on a file buffer (`line_count` lines) into extmark specs.
function M.create_extmarks_from_threads(threads, line_count, opts)
    return extmarks.create_extmarks_from_threads(M, threads, line_count, opts)
end

M.create_message_layout = popup_layout.create_message_layout

--- Appends one formatted `message` from `thread` into `layout`.
function M.append_formatted_message(layout, thread, message, opts)
    return popup_layout.append_formatted_message(M, layout, thread, message, opts)
end

--- Creates the lines, highlights, and cursor-to-message ranges for the thread popup.
function M.create_popup_layout_from_threads(threads, opts)
    return popup_layout.create_popup_layout_from_threads(M, threads, opts)
end

M.find_message_at_line = popup_layout.find_message_at_line

return M
