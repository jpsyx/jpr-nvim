-- User-facing `:Jpr` session actions (`sync`, `push`, `close`, `toggle`,
-- `stream`, `agent`, `send`, `prepass`) attached onto `jpr.session`.
local crash = require("jpr.session.crash")

local M = {}

local function jpr()
    return require("jpr")
end

local function run_with_current(session_mod, action)
    local session = session_mod.current()
    if not session then
        return jpr().error("no pull request is open in this tab")
    end
    return action(session)
end

local function sync_session(session_mod, session)
    if session.is_read_only then
        return session_mod.report_read_only(session)
    end
    if not session.client then
        return jpr().error(
            ("the review engine for PR #%d is not running; run :Jpr open %d"):format(session.number, session.number)
        )
    end
    session.client:request("sync", nil, function(sync_error, view)
        if sync_error then
            return jpr().error("sync failed: " .. crash.build_clean_text_from_raw(sync_error.message))
        end
        session_mod.show(session, view)
    end)
end

local function push_session(session_mod, session)
    session_mod.request(session, "push", nil, function(result)
        if type(result) == "table" and type(result.view) == "table" then
            session_mod.show(session, result.view)
        end
        local short_sha = crash.build_clean_text_from_raw(type(result) == "table" and result.headSha or ""):sub(1, 7)
        jpr().info(("pushed %s"):format(short_sha))
        local sync_error = type(result) == "table" and crash.build_clean_text_from_raw(result.syncError) or ""
        if sync_error ~= "" then
            jpr().warn("pushed, but GitHub resync failed: " .. sync_error)
        end
    end)
end

local function redraw_all_session_views(session_mod, mode)
    for _, session in pairs(session_mod.by_tab) do
        if session.client and not session.is_read_only then
            require("jpr.views.diff").redraw_all(session)
            require("jpr.views.stream").refresh(session, true)
        end
    end
    jpr().info(("%s view"):format(mode))
end

local function attach_agent_commands(session_mod)
    --- `:Jpr agent [claude|codex]`: toggles the interactive agent terminal panel
    --- for the current review, optionally selecting the provider when opening.
    function session_mod.agent_current(agent_kind)
        return run_with_current(session_mod, function(session)
            require("jpr.agent").toggle(session, agent_kind)
        end)
    end

    --- `:Jpr send`: sends unsent local review threads to the interactive agent panel.
    function session_mod.send_current()
        return run_with_current(session_mod, function(session)
            require("jpr.agent").send(session)
        end)
    end

    --- `:Jpr prepass`: sends a pre-pass review prompt to the interactive agent panel.
    function session_mod.prepass_current()
        return run_with_current(session_mod, function(session)
            require("jpr.agent").prepass(session)
        end)
    end
end

local function attach_view_commands(session_mod, forget)
    --- `:Jpr close`: stops the current tab's engine, closes the tab (unless it is
    --- the last one) and forgets the session.
    function session_mod.close_current()
        return run_with_current(session_mod, function(session)
            forget(session, true)
        end)
    end

    --- `:Jpr toggle`: flips every review between unified and split views, and
    --- remembers the choice.
    function session_mod.toggle_view()
        local mode = require("jpr.view_mode").toggle()
        redraw_all_session_views(session_mod, mode)
    end

    --- `:Jpr toggle <unified|split>`: sets the diff view mode and redraws active reviews.
    function session_mod.set_view_mode(mode)
        if mode ~= "unified" and mode ~= "split" then
            return jpr().error(("invalid diff view %q; expected unified or split"):format(tostring(mode)))
        end
        require("jpr.view_mode").set(mode)
        redraw_all_session_views(session_mod, mode)
    end

    --- `:Jpr stream`: shows the current review's stream beside the panel and
    --- focuses it.
    function session_mod.stream_current()
        return run_with_current(session_mod, function(session)
            require("jpr.views.stream").show(session, { focus = true })
        end)
    end
end

--- Attaches sync, push, close, view-toggle, stream, and coding-agent command
--- handlers onto `session_mod`, delegating teardown to `forget`.
function M.attach(session_mod, forget)
    --- Asks the engine to sync `session` with GitHub now; the panel, the stream
    --- and the diffs redraw from the answer, and a failure is reported to the
    --- user.
    function session_mod.sync(session)
        return sync_session(session_mod, session)
    end

    --- Pushes local commits on `HEAD` to `session`'s pull request branch and
    --- refreshes the session view.
    function session_mod.push(session)
        return push_session(session_mod, session)
    end

    --- `:Jpr sync`: syncs the current tab's session now.
    function session_mod.sync_current()
        return run_with_current(session_mod, session_mod.sync)
    end

    --- `:Jpr push`: pushes local `HEAD` commits for the current tab's review session.
    function session_mod.push_current()
        return run_with_current(session_mod, session_mod.push)
    end

    attach_view_commands(session_mod, forget)
    attach_agent_commands(session_mod)
end

return M
