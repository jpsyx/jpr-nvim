local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

dofile(root .. "/plugin/jpr.lua")
local helpers = dofile(root .. "/tests/lua/support/helpers.lua")

local jpr = require("jpr")
local session = require("jpr.session")
local view_mode = require("jpr.view_mode")
local agent = require("jpr.agent")

local function read_bytes(path)
    local file_descriptor = vim.uv.fs_open(path, "r", 438)
    if not file_descriptor then
        return ""
    end
    local stat = vim.uv.fs_fstat(file_descriptor)
    local data = stat and stat.size > 0 and vim.uv.fs_read(file_descriptor, stat.size, 0) or ""
    vim.uv.fs_close(file_descriptor)
    return data or ""
end

local function create_fake_agent_script(script_path, metadata_log, capture_file)
    local lines = {
        "#!/bin/sh",
        "printf '%s\\n' \"$PWD|$JPR_SOCKET|$JPR_PR|$*\" >> " .. vim.fn.shellescape(metadata_log),
        "printf '\\033[?2004h'",
        "stty raw -echo 2>/dev/null || true",
        "exec cat > " .. vim.fn.shellescape(capture_file),
    }
    vim.fn.writefile(lines, script_path)
    vim.uv.fs_chmod(script_path, 493)
end


local function setup_session_environment()
    view_mode.path = vim.fn.tempname()
    local engine_log = vim.fn.tempname()
    local metadata_log = vim.fn.tempname()
    local capture_file = vim.fn.tempname()
    local worktree = vim.fn.tempname()
    vim.fn.mkdir(worktree, "p")
    vim.fn.writefile({ "hello", "new" }, worktree .. "/README.md")
    local fake_agent = worktree .. "/fake-agent.sh"
    create_fake_agent_script(fake_agent, metadata_log, capture_file)

    vim.env.FAKE_ENGINE_LOG = engine_log
    jpr.setup({
        binary = root .. "/tests/lua/fixtures/fake_engine.sh",
        claude_cmd = fake_agent,
        codex_cmd = fake_agent,
        agent = "claude",
        agent_width = 50,
        agent_load_toggleterm = false,
        agent_submit_delay_ms = 20,
        agent_ready_settle_ms = 10,
        agent_ready_timeout_ms = 200,
    })

    local errors = {}
    jpr.error = function(message)
        errors[#errors + 1] = message
    end
    jpr.info = function() end

    session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
    local review = session.current()
    assert(vim.wait(3000, function()
        return review.view.pr ~= nil
    end), "session syncs")

    return {
        review = review,
        worktree = worktree,
        engine_log = engine_log,
        metadata_log = metadata_log,
        capture_file = capture_file,
        errors = errors,
    }
end


local context = setup_session_environment()
context.helpers = helpers
context.read_bytes = read_bytes

dofile(root .. "/tests/lua/agent_spec/launch_and_send.lua")(context)
dofile(root .. "/tests/lua/agent_spec/lifecycle.lua")(context)

print("agent_spec: ok")
