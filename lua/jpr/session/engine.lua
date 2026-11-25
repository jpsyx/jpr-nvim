-- Engine process spawning, protocol/version handshake, and read-only fallback.
local crash = require("jpr.session.crash")
local rpc = require("jpr.rpc")

local M = {}

local function jpr()
    return require("jpr")
end

local function build_serve_args_from_session(session)
    if session.mode == "local" then
        local args = { jpr().binary_path(), "serve", "--local" }
        if type(session.base_ref) == "string" and session.base_ref ~= "" then
            vim.list_extend(args, { "--base", session.base_ref })
        end
        return args
    end
    return {
        jpr().binary_path(),
        "serve",
        "--pr",
        tostring(session.number),
        "--repo",
        session.repo,
    }
end

local function fail_handshake(session, client, error_message, forget)
    if session.has_restarted and session.ready then
        session.client = nil
        client:stop()
        local log_path = crash.append_crash_log(session.number, "handshake", error_message, session.branch)
        return crash.transition_to_read_only(session, "handshake", log_path, error_message)
    end
    forget(session)
    return jpr().error(error_message)
end

local function build_handshake_error_from_result(result)
    if type(result) ~= "table" or type(result.protocolVersion) ~= "number" then
        return "invalid handshake response: missing protocolVersion"
    end
    local binary_label = crash.build_clean_text_from_raw(jpr().binary_path())
    if result.protocolVersion ~= rpc.PROTOCOL_VERSION then
        return ("protocol mismatch: the plugin speaks %d and %s speaks %d; run :Lazy build jpr-nvim"):format(
            rpc.PROTOCOL_VERSION,
            binary_label,
            result.protocolVersion
        )
    end
    if type(result.version) ~= "string" or result.version == "" then
        return ("invalid handshake response from %s: missing engine version"):format(binary_label)
    end
    if result.version ~= "test" and result.version ~= jpr().VERSION then
        return ("version mismatch: plugin is %s and %s is %s; run :Lazy build jpr-nvim"):format(
            jpr().VERSION,
            binary_label,
            crash.build_clean_text_from_raw(result.version)
        )
    end
    return nil
end

local function handshake(session_mod, session, client, forget)
    local params = { protocolVersion = rpc.PROTOCOL_VERSION, client = "jpr.nvim" }
    client:request("initialize", params, function(init_error, result)
        if session.closing or session.client ~= client then
            return
        end
        if init_error then
            if client.exited then
                return
            end
            local clean_message = crash.build_clean_text_from_raw(init_error.message)
            return fail_handshake(session, client, "could not start the review engine: " .. clean_message, forget)
        end
        local handshake_error = build_handshake_error_from_result(result)
        if handshake_error then
            return fail_handshake(session, client, handshake_error, forget)
        end
        session.ready = true
        if session.loading then
            require("jpr.views.loading").update(session, { stage = 3 })
        end
        client:request("snapshot", nil, function(_, view)
            if session.closing or session.client ~= client then
                return
            end
            if view then
                session_mod.show(session, view)
            end
        end)
        if session.mode ~= "local" then
            session_mod.sync(session)
        end
    end)
end

--- Spawns `jpr-review serve` for `session`, registers it in `session_mod.by_tab`,
--- and runs the protocol/version handshake.
function M.spawn(session_mod, session, forget)
    local spawned_client
    local client, spawn_error = rpc.start(build_serve_args_from_session(session), {
        cwd = session.worktree,
        on_notification = function(method, params)
            if session.closing or session.client ~= spawned_client then
                return
            end
            session_mod.on_notification(session, method, params)
        end,
        on_exit = function(code, stderr)
            session_mod.on_exit(session, code, stderr, spawned_client)
        end,
    })
    if not client then
        if not session.has_restarted then
            forget(session)
            local clean_spawn_error = crash.build_clean_text_from_raw(spawn_error)
            jpr().error(clean_spawn_error ~= "" and clean_spawn_error or "could not start the review engine")
        end
        return false
    end
    spawned_client = client
    session.client = client
    session_mod.by_tab[session.tab] = session
    handshake(session_mod, session, client, forget)
    return true
end

return M
