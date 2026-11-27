-- Floating markdown compose entrypoints for new comments, replies, edits,
-- promotions, and suggestion blocks (`<C-s>` submits, `q` / `<Esc>` cancels).
local editor = require("jpr.comments.compose.editor")

local M = {}

--- Closes the active floating compose buffer (and any docked history pane) for `session`.
M.close = editor.close

local function is_unlinked_local_session(session)
    return type(session) == "table" and session.mode == "local" and not (session.view and session.view.pr)
end

local function is_local_only_anchor(session, anchor)
    if type(anchor) ~= "table" or type(anchor.file) ~= "string" or anchor.file == "" then
        return false
    end
    local files = session and session.view and session.view.files or {}
    for _, file in ipairs(files) do
        if file.path == anchor.file then
            return file.isLocalOnly == true
        end
    end
    return false
end

local function submit_with_draft_recovery(session, method, params, reopen_fn)
    require("jpr.session").request(session, method, params, function() end, function(request_error)
        if not session.closing and require("jpr.auth").is_rpc_auth_error(request_error) then
            reopen_fn()
        end
    end)
end

local function prefill_suggested_comment(session, anchor, open_with_body)
    local request_id = editor.next_request_id(session)
    return require("jpr.session").request(session, "anchoredLines", { anchor = anchor }, function(result)
        if session.closing or session.compose_request_id ~= request_id then
            return
        end
        if session.tab ~= nil and not vim.api.nvim_tabpage_is_valid(session.tab) then
            return
        end
        open_with_body(("```suggestion\n%s\n```"):format((result and result.text) or ""))
    end)
end

--- Opens the floating compose buffer for a new comment at `anchor`, optionally
--- pre-filling a GitHub suggestion block on line or range anchors (`opts.suggest`).
function M.open_new(session, anchor, opts)
    if not session or session.closing then
        return
    end
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local open_opts = opts or {}
    local is_unlinked_local = is_unlinked_local_session(session)
    local is_local_only = is_local_only_anchor(session, anchor)
    local is_locked_local = is_unlinked_local or is_local_only
    local open_with_body
    open_with_body = function(initial_text, origin_override)
        local origin = is_locked_local and "local"
            or (origin_override or open_opts.initial_origin or session.compose_destination or "github")
        editor.open(session, {
            title = editor.build_title_from_anchor(anchor, origin),
            initial_text = initial_text,
            anchor = anchor,
            origin = origin,
            allow_destination_toggle = not is_locked_local,
            is_local_only = is_local_only,
            is_unlinked_local = is_unlinked_local,
            on_submit = function(body, submit_origin)
                submit_with_draft_recovery(session, "comment", {
                    anchor = anchor,
                    body = body,
                    origin = submit_origin,
                }, function()
                    open_with_body(body, submit_origin)
                end)
            end,
        })
    end
    if open_opts.suggest and (anchor.kind == "line" or anchor.kind == "range") then
        return prefill_suggested_comment(session, anchor, open_with_body)
    end
    open_with_body("")
end

--- Opens the floating compose buffer to reply to `thread`.
function M.open_reply(session, thread)
    if not session or session.closing then
        return
    end
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local is_local = thread.origin == "local" or thread.kind == "local"
    local badge = is_local and "[Local reply]" or "[GitHub reply]"
    if not is_local and session.view and (session.view.draftCount or 0) > 0 then
        badge = "[GitHub draft]"
    end
    local thread_id = thread.threadId or thread.id
    local open_reply_editor
    open_reply_editor = function(initial_text)
        editor.open(session, {
            title = badge .. " Reply",
            initial_text = initial_text,
            anchor = thread.anchor,
            history_thread = thread,
            allow_destination_toggle = false,
            on_submit = function(body)
                submit_with_draft_recovery(session, "reply", { threadId = thread_id, body = body }, function()
                    open_reply_editor(body)
                end)
            end,
        })
    end
    open_reply_editor("")
end

--- Opens the floating compose buffer to edit `message` (pre-populating
--- `recoverableBody` when present).
function M.open_edit(session, message, thread)
    if not session or session.closing then
        return
    end
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    local is_local = (thread ~= nil and (thread.origin == "local" or thread.kind == "local"))
        or message.sync == nil
        or message.sync == vim.NIL
    local title = is_local and "[Edit local comment]" or "[Edit GitHub comment]"
    local initial_text = (type(message.recoverableBody) == "string" and message.recoverableBody)
        or (type(message.body) == "string" and message.body)
        or ""
    local anchor = type(thread) == "table" and type(thread.anchor) == "table" and thread.anchor or nil
    local open_edit_editor
    open_edit_editor = function(body_text)
        editor.open(session, {
            title = title,
            initial_text = body_text,
            anchor = anchor,
            allow_destination_toggle = false,
            on_submit = function(body)
                submit_with_draft_recovery(session, "editMessage", { messageId = message.id, body = body }, function()
                    open_edit_editor(body)
                end)
            end,
        })
    end
    open_edit_editor(initial_text)
end

--- Opens the floating compose buffer to promote a local `thread`'s root
--- comment into a GitHub draft or PR comment.
function M.open_promote(session, thread)
    if not session or session.closing or not thread then
        return
    end
    if session.is_read_only then
        return require("jpr.session").report_read_only(session)
    end
    if type(thread.promotedTo) == "string" and thread.promotedTo ~= "" then
        return require("jpr").info("local thread was already promoted to " .. thread.promotedTo)
    end
    local thread_id = thread.threadId or thread.id
    local messages = type(thread.messages) == "table" and thread.messages or {}
    local first_message = messages[1]
    local raw_body = type(first_message) == "table" and first_message.body or ""
    local initial_text = type(raw_body) == "string" and raw_body or ""
    local open_promote_editor
    open_promote_editor = function(body_text)
        editor.open(session, {
            title = "[Promote → GitHub] " .. editor.build_location_from_anchor(thread.anchor),
            initial_text = body_text,
            anchor = thread.anchor,
            allow_destination_toggle = false,
            on_submit = function(body)
                submit_with_draft_recovery(session, "promoteThread", {
                    threadId = thread_id,
                    body = body,
                }, function()
                    open_promote_editor(body)
                end)
            end,
        })
    end
    open_promote_editor(initial_text)
end

return M
