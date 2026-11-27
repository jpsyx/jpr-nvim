-- Centralized in-progress toast tracking for engine JSON-RPC requests.
-- GitHub-bound operations appear immediately (delay_ms = 0); fast local ops
-- wait 150 ms so instant actions never flicker.
local notify = require("jpr.notify")

local M = {}

local IMMEDIATE_MS = 0
local DELAYED_MS = 150

local METHOD_SPECS = {
    submitReview = { label = "Submitting review to GitHub...", delay_ms = IMMEDIATE_MS },
    sync = { label = "Syncing with GitHub...", delay_ms = IMMEDIATE_MS },
    push = { label = "Pushing commits to GitHub...", delay_ms = IMMEDIATE_MS },
    submitPreview = { label = "Loading review summary...", delay_ms = IMMEDIATE_MS },
    promoteThread = { label = "Promoting comment to GitHub...", delay_ms = IMMEDIATE_MS },
    suggestFromEdit = { label = "Creating suggestion on GitHub...", delay_ms = IMMEDIATE_MS },
    reply = { label = "Posting reply...", delay_ms = IMMEDIATE_MS },
    editMessage = { label = "Updating comment...", delay_ms = IMMEDIATE_MS },
    deleteMessage = { label = "Deleting comment...", delay_ms = IMMEDIATE_MS },
    setResolved = { label = "Updating thread status...", delay_ms = IMMEDIATE_MS },
    toggleReaction = { label = "Updating reaction...", delay_ms = IMMEDIATE_MS },
    retryMessage = { label = "Retrying comment on GitHub...", delay_ms = IMMEDIATE_MS },
    setViewed = { label = "Updating viewed state...", delay_ms = DELAYED_MS },
    fileDiff = { label = "Loading diff...", delay_ms = DELAYED_MS },
    stream = { label = "Computing full branch diff...", delay_ms = DELAYED_MS },
    threads = { label = "Loading review threads...", delay_ms = DELAYED_MS },
    mentions = { label = "Loading mention candidates...", delay_ms = DELAYED_MS },
    anchoredLines = { label = "Reading anchored lines...", delay_ms = DELAYED_MS },
    prepareAgentLaunch = { label = "Preparing coding agent...", delay_ms = DELAYED_MS },
    prepareSend = { label = "Preparing agent prompt...", delay_ms = DELAYED_MS },
    confirmSend = { label = "Recording agent dispatch...", delay_ms = DELAYED_MS },
    preparePrepass = { label = "Preparing pre-pass review...", delay_ms = DELAYED_MS },
    prepareConflictResolution = { label = "Preparing conflict resolution...", delay_ms = DELAYED_MS },
    refreshWorktree = { label = "Refreshing worktree...", delay_ms = DELAYED_MS },
    setCollapsed = { label = "Updating directory state...", delay_ms = DELAYED_MS },
}

--- Returns `{ label, delay_ms }` for RPC `method` and `params`, or nil when
--- the method should not show a progress toast (such as `initialize` or `shutdown`).
function M.get_spec_from_request(method, params)
    if method == "comment" then
        local is_local = type(params) == "table" and params.origin == "local"
        return {
            label = is_local and "Saving local comment..." or "Posting comment to GitHub...",
            delay_ms = is_local and DELAYED_MS or IMMEDIATE_MS,
        }
    end
    if method == "fileDiff" and type(params) == "table" and type(params.path) == "string" and params.path ~= "" then
        return {
            label = ("Loading diff for %s..."):format(params.path),
            delay_ms = DELAYED_MS,
        }
    end
    local spec = METHOD_SPECS[method]
    if not spec then
        return nil
    end
    return { label = spec.label, delay_ms = spec.delay_ms }
end

--- Starts tracking an in-progress toast on `session` for `method` and `params`.
--- Returns a wrapped handle that automatically unregisters itself on completion.
function M.start(session, method, params, opts)
    local options = opts or {}
    if options.silent == true then
        return nil
    end
    local spec = M.get_spec_from_request(method, params)
    if not spec then
        return nil
    end
    local label = type(options.progress_label) == "string" and options.progress_label or spec.label
    local delay_ms = type(options.delay_ms) == "number" and options.delay_ms or spec.delay_ms
    local raw_handle = notify.progress(label, { delay_ms = delay_ms })
    session.active_progress = session.active_progress or {}
    local wrapped
    local function untrack()
        if session.active_progress then
            session.active_progress[wrapped] = nil
        end
    end
    wrapped = {
        update = function(_, next_message)
            raw_handle:update(next_message)
        end,
        succeed = function(_, success_message)
            untrack()
            raw_handle:succeed(success_message)
        end,
        fail = function(_, error_message)
            untrack()
            raw_handle:fail(error_message)
        end,
        cancel = function()
            untrack()
            raw_handle:cancel()
        end,
    }
    session.active_progress[wrapped] = true
    return wrapped
end

--- Cancels every active progress toast associated with `session`.
function M.cancel_all(session)
    if type(session) ~= "table" then
        return
    end
    if session.stream_progress_handle then
        session.stream_progress_handle:cancel()
        session.stream_progress_handle = nil
    end
    local active = session.active_progress
    if type(active) ~= "table" then
        return
    end
    local handles = {}
    for handle in pairs(active) do
        handles[#handles + 1] = handle
    end
    for _, handle in ipairs(handles) do
        handle:cancel()
    end
end

return M
