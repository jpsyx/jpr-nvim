local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
local repo_lua_prefix = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;"
package.path = repo_lua_prefix .. package.path

dofile(root .. "/plugin/jpr.lua")

local jpr = require("jpr")
local binary = require("jpr.binary")
local build = require("jpr.build")
local health = require("jpr.health")
local session = require("jpr.session")
local agent = require("jpr.agent")
local view_mode = require("jpr.view_mode")

local function write_executable_script(script_path, lines)
    vim.fn.mkdir(vim.fs.dirname(script_path), "p")
    vim.fn.writefile(lines, script_path)
    vim.uv.fs_chmod(script_path, tonumber("755", 8))
end

local function test_binary_path_helpers()
    assert(binary.plugin_root() == root, "plugin_root matches checkout root: " .. tostring(binary.plugin_root()))
    assert(binary.default_binary_path(root, false) == root .. "/target/release/jpr-review", "posix bundled binary path")
    assert(binary.default_binary_path(root, true) == root .. "/target/release/jpr-review.exe", "windows bundled binary path")
    assert(binary.default_binary_path(root) == root .. "/target/release/jpr-review", "default bundled binary path")
    assert(binary.get_binary_path_from_config({}, root) == root .. "/target/release/jpr-review", "empty config uses default path")
    assert(binary.get_binary_path_from_config({ binary = "" }, root) == root .. "/target/release/jpr-review", "blank binary uses default path")
    assert(binary.get_binary_path_from_config({ binary = "/custom/jpr-review" }, root) == "/custom/jpr-review", "custom binary override")
end

local function test_build_agent_env_from_session()
    local temp_directory = vim.fn.tempname()
    local fake_executable = temp_directory .. "/target/release/jpr-review"
    write_executable_script(fake_executable, { "#!/bin/sh", "exit 0" })
    local expected_directory = vim.fn.fnamemodify(fake_executable, ":p:h")

    local prepended_env = binary.build_agent_env_from_session(fake_executable, "/tmp/jpr.sock", 42, "/usr/bin:/bin")
    assert(prepended_env.JPR_SOCKET == "/tmp/jpr.sock", "preserves JPR_SOCKET")
    assert(prepended_env.JPR_PR == "42", "stringifies JPR_PR")
    assert(prepended_env.PATH == expected_directory .. ":/usr/bin:/bin", "prepends bundled binary directory: " .. tostring(prepended_env.PATH))

    local deduplicated_env = binary.build_agent_env_from_session(fake_executable, "/tmp/jpr.sock", 42, expected_directory .. ":/usr/bin:/bin")
    assert(deduplicated_env.PATH == expected_directory .. ":/usr/bin:/bin", "does not duplicate leading PATH directory")

    local prefix_env = binary.build_agent_env_from_session(fake_executable, "/tmp/jpr.sock", 42, expected_directory .. "-other:/usr/bin")
    assert(prefix_env.PATH == expected_directory .. ":" .. expected_directory .. "-other:/usr/bin", "distinguishes directory boundary on PATH")

    local bare_env = binary.build_agent_env_from_session("jpr-review", "/tmp/jpr.sock", 42, "/usr/bin:/bin")
    assert(bare_env.PATH == "/usr/bin:/bin", "leaves PATH unchanged for bare command name")

    local missing_env = binary.build_agent_env_from_session(temp_directory .. "/missing/jpr-review", "/tmp/jpr.sock", 42, "/usr/bin:/bin")
    assert(missing_env.PATH == "/usr/bin:/bin", "leaves PATH unchanged for non-executable path")
end

local function test_agent_terminal_finds_bundled_binary()
    view_mode.path = vim.fn.tempname()
    local temp_directory = vim.fn.tempname()
    local bundled_binary = temp_directory .. "/bundled/jpr-review"
    local worktree = temp_directory .. "/worktree"
    local probe_output_file = temp_directory .. "/found-jpr-review.txt"
    local probe_agent = temp_directory .. "/probe-agent.sh"
    vim.fn.mkdir(worktree, "p")
    vim.fn.writefile({ "hello" }, worktree .. "/README.md")
    write_executable_script(bundled_binary, vim.fn.readfile(root .. "/tests/lua/fixtures/fake_engine.sh"))
    write_executable_script(probe_agent, {
        "#!/bin/sh",
        "command -v jpr-review > " .. vim.fn.shellescape(probe_output_file),
    })

    jpr.setup({
        binary = bundled_binary,
        claude_cmd = probe_agent,
        agent = "claude",
    })
    session.start({ worktree = worktree, repo = "octo/widgets", number = 7 })
    local review = session.current()
    assert(vim.wait(3000, function()
        return review ~= nil and review.view.pr ~= nil
    end), "session synced with bundled fake engine")

    agent.ensure_open(review)
    assert(vim.wait(3000, function()
        return vim.fn.filereadable(probe_output_file) == 1 and #vim.fn.readfile(probe_output_file) >= 1
    end), "agent terminal wrote command -v jpr-review output")
    local found_binary = vim.trim(vim.fn.readfile(probe_output_file)[1])
    assert(
        vim.uv.fs_realpath(found_binary) == vim.uv.fs_realpath(bundled_binary),
        ("agent terminal found %s instead of %s"):format(found_binary, bundled_binary)
    )
    session.close_current()
    jpr.setup({})
end

local function test_find_cargo_executable()
    local temp_directory = vim.fn.tempname()
    local path_bin = temp_directory .. "/path-bin"
    local cargo_home = temp_directory .. "/cargo-home"
    local home_directory = temp_directory .. "/home"
    local empty_home = temp_directory .. "/empty-home"
    vim.fn.mkdir(empty_home, "p")
    write_executable_script(path_bin .. "/cargo", { "#!/bin/sh", "exit 0" })
    write_executable_script(cargo_home .. "/bin/cargo", { "#!/bin/sh", "exit 0" })
    write_executable_script(home_directory .. "/.cargo/bin/cargo", { "#!/bin/sh", "exit 0" })

    local from_path = build.find_cargo_executable({ PATH = "/nonexistent:" .. path_bin, CARGO_HOME = cargo_home }, home_directory)
    assert(from_path == path_bin .. "/cargo", "finds cargo on PATH first: " .. tostring(from_path))

    local from_cargo_home = build.find_cargo_executable({ PATH = "", CARGO_HOME = cargo_home }, home_directory)
    assert(from_cargo_home == cargo_home .. "/bin/cargo", "falls back to CARGO_HOME/bin/cargo: " .. tostring(from_cargo_home))

    local from_home_directory = build.find_cargo_executable({ PATH = "" }, home_directory)
    assert(from_home_directory == home_directory .. "/.cargo/bin/cargo", "falls back to HOME/.cargo/bin/cargo: " .. tostring(from_home_directory))

    local missing_cargo = build.find_cargo_executable({ PATH = "" }, empty_home)
    assert(missing_cargo == nil, "returns nil when cargo is absent everywhere")
end

local function create_temp_plugin_checkout()
    local temp_directory = vim.fn.tempname()
    local plugin_directory = temp_directory .. "/jpr-nvim"
    vim.fn.mkdir(plugin_directory .. "/lua/jpr", "p")
    vim.fn.writefile(vim.fn.readfile(root .. "/build.lua"), plugin_directory .. "/build.lua")
    vim.fn.writefile(vim.fn.readfile(root .. "/lua/jpr/build.lua"), plugin_directory .. "/lua/jpr/build.lua")
    vim.fn.writefile(vim.fn.readfile(root .. "/lua/jpr/binary.lua"), plugin_directory .. "/lua/jpr/binary.lua")
    return temp_directory, plugin_directory
end

local function create_fake_cargo(cargo_bin_directory, cargo_log)
    write_executable_script(cargo_bin_directory .. "/cargo", {
        "#!/bin/sh",
        "printf '%s|%s|%s\\n' \"$PWD\" \"$*\" \"$PATH\" >> " .. vim.fn.shellescape(cargo_log),
        "if [ \"$FAKE_CARGO_MODE\" = \"fail\" ]; then",
        "  echo 'error[E0001]: broken rust build' >&2",
        "  exit 101",
        "fi",
        "if [ \"$FAKE_CARGO_MODE\" = \"nobin\" ]; then",
        "  exit 0",
        "fi",
        "/bin/mkdir -p \"$PWD/target/release\"",
        "printf '#!/bin/sh\\necho jpr-review 0.5.0\\n' > \"$PWD/target/release/jpr-review\"",
        "/bin/chmod +x \"$PWD/target/release/jpr-review\"",
    })
end

local function with_temporary_env(overrides, callback)
    local saved = {
        PATH = vim.env.PATH,
        CARGO_HOME = vim.env.CARGO_HOME,
        HOME = vim.env.HOME,
        FAKE_CARGO_MODE = vim.env.FAKE_CARGO_MODE,
    }
    for key, value in pairs(overrides) do
        vim.env[key] = value ~= false and value or nil
    end
    local is_ok, result = pcall(callback)
    for key, value in pairs(saved) do
        vim.env[key] = value
    end
    if not is_ok then
        error(result, 0)
    end
    return result
end

local function run_build_chunk_in_cold_coroutine(build_file_path)
    local saved_package_path = package.path
    local saved_build = package.loaded["jpr.build"]
    local saved_binary = package.loaded["jpr.binary"]
    package.path = saved_package_path:gsub(vim.pesc(repo_lua_prefix), "")
    package.loaded["jpr.build"] = nil
    package.loaded["jpr.binary"] = nil

    local yielded_messages = {}
    local build_chunk = assert(loadfile(build_file_path))
    local build_thread = coroutine.create(build_chunk)
    local is_ok, failure
    while coroutine.status(build_thread) ~= "dead" do
        local resume_ok, yielded_value = coroutine.resume(build_thread)
        if not resume_ok then
            is_ok, failure = false, yielded_value
            break
        end
        if yielded_value ~= nil then
            yielded_messages[#yielded_messages + 1] = yielded_value
        end
        is_ok = true
    end

    package.path = saved_package_path
    package.loaded["jpr.build"] = saved_build
    package.loaded["jpr.binary"] = saved_binary
    assert(is_ok, "build coroutine failed: " .. tostring(failure))
    return yielded_messages
end

local function test_root_build_lua_coroutine_and_cwd()
    local temp_directory, plugin_directory = create_temp_plugin_checkout()
    local cargo_bin_directory = temp_directory .. "/cargo-bin"
    local cargo_log = temp_directory .. "/cargo.log"
    local outside_cwd = temp_directory .. "/outside-cwd"
    vim.fn.mkdir(outside_cwd, "p")
    create_fake_cargo(cargo_bin_directory, cargo_log)

    local original_cwd = vim.fn.getcwd()
    vim.cmd.cd(vim.fn.fnameescape(outside_cwd))
    local cwd_before_build = vim.fn.getcwd()
    local yielded_messages = with_temporary_env({
        PATH = "/usr/bin:/bin",
        CARGO_HOME = false,
        HOME = temp_directory .. "/fake-home",
        FAKE_CARGO_MODE = "ok",
    }, function()
        write_executable_script(temp_directory .. "/fake-home/.cargo/bin/cargo", vim.fn.readfile(cargo_bin_directory .. "/cargo"))
        return run_build_chunk_in_cold_coroutine(plugin_directory .. "/build.lua")
    end)
    local cwd_after_build = vim.fn.getcwd()
    vim.cmd.cd(vim.fn.fnameescape(original_cwd))

    assert(cwd_after_build == cwd_before_build, "build.lua must not mutate global cwd")
    assert(#yielded_messages >= 1 and tostring(yielded_messages[1]):find("cargo build --release", 1, true) ~= nil, "yields coroutine progress")
    assert(vim.fn.executable(plugin_directory .. "/target/release/jpr-review") == 1, "compiled binary exists and is executable")
    local log_line = vim.fn.readfile(cargo_log)[1]
    local expected_plugin_real = vim.uv.fs_realpath(plugin_directory) or plugin_directory
    assert(log_line:find(expected_plugin_real .. "|build --release -p jpr-review|", 1, true) == 1, "cargo invocation: " .. log_line)
    assert(log_line:find(".cargo/bin", 1, true) ~= nil, "prepends cargo bin directory to PATH for rustc: " .. log_line)
end

local function test_root_build_lua_error_cases()
    local temp_directory, plugin_directory = create_temp_plugin_checkout()
    local cargo_bin_directory = temp_directory .. "/cargo-bin"
    local cargo_log = temp_directory .. "/cargo.log"
    local empty_home = temp_directory .. "/empty-home"
    vim.fn.mkdir(empty_home, "p")
    create_fake_cargo(cargo_bin_directory, cargo_log)
    local build_chunk = assert(loadfile(plugin_directory .. "/build.lua"))

    local missing_ok, missing_error = pcall(with_temporary_env, {
        PATH = temp_directory .. "/empty-bin",
        CARGO_HOME = false,
        HOME = empty_home,
    }, build_chunk)
    assert(not missing_ok, "missing cargo must error")
    assert(tostring(missing_error):find("https://rustup.rs", 1, true) ~= nil, "missing cargo mentions rustup.rs: " .. tostring(missing_error))
    assert(tostring(missing_error):find(":Lazy build jpr-nvim", 1, true) ~= nil, "missing cargo mentions :Lazy build jpr-nvim: " .. tostring(missing_error))

    local fail_ok, fail_error = pcall(with_temporary_env, {
        PATH = cargo_bin_directory .. ":/usr/bin:/bin",
        CARGO_HOME = false,
        HOME = empty_home,
        FAKE_CARGO_MODE = "fail",
    }, build_chunk)
    assert(not fail_ok, "non-zero cargo exit must error")
    assert(tostring(fail_error):find("error[E0001]: broken rust build", 1, true) ~= nil, "includes cargo stderr: " .. tostring(fail_error))
    assert(tostring(fail_error):find(":Lazy build jpr-nvim", 1, true) ~= nil, "failed cargo mentions :Lazy build jpr-nvim: " .. tostring(fail_error))

    local nobin_ok, nobin_error = pcall(with_temporary_env, {
        PATH = cargo_bin_directory .. ":/usr/bin:/bin",
        CARGO_HOME = false,
        HOME = empty_home,
        FAKE_CARGO_MODE = "nobin",
    }, build_chunk)
    assert(not nobin_ok, "missing output binary must error")
    assert(tostring(nobin_error):find(":Lazy build jpr-nvim", 1, true) ~= nil, "missing output mentions :Lazy build jpr-nvim: " .. tostring(nobin_error))
end

local function run_health_check_with_stubs(binary_path)
    local report = { starts = {}, oks = {}, warns = {}, errors = {} }
    local original_health = vim.health
    vim.health = {
        start = function(name)
            report.starts[#report.starts + 1] = name
        end,
        ok = function(message)
            report.oks[#report.oks + 1] = message
        end,
        warn = function(message)
            report.warns[#report.warns + 1] = message
        end,
        error = function(message)
            report.errors[#report.errors + 1] = message
        end,
    }
    jpr.setup({ binary = binary_path })
    local is_ok, check_error = pcall(health.check)
    vim.health = original_health
    jpr.setup({})
    assert(is_ok, "health.check failed unexpectedly: " .. tostring(check_error))
    return report
end

local function test_health_check()
    local temp_directory = vim.fn.tempname()
    local tools_bin = temp_directory .. "/tools-bin"
    local matching_binary = temp_directory .. "/jpr-review-ok"
    local mismatched_binary = temp_directory .. "/jpr-review-old"
    write_executable_script(tools_bin .. "/git", { "#!/bin/sh", "exit 0" })
    write_executable_script(tools_bin .. "/gh", { "#!/bin/sh", "exit 0" })
    write_executable_script(tools_bin .. "/cargo", { "#!/bin/sh", "exit 0" })
    write_executable_script(matching_binary, { "#!/bin/sh", "echo 'jpr-review " .. jpr.VERSION .. "'" })
    write_executable_script(mismatched_binary, { "#!/bin/sh", "echo 'jpr-review 0.1.0'" })

    with_temporary_env({ PATH = tools_bin .. ":/usr/bin:/bin" }, function()
        local healthy = run_health_check_with_stubs(matching_binary)
        assert(healthy.starts[1] == "jpr", "health check starts jpr section")
        assert(#healthy.errors == 0, "healthy report has zero errors: " .. vim.inspect(healthy.errors))
        assert(table.concat(healthy.oks, "\n"):find("jpr-review " .. jpr.VERSION, 1, true) ~= nil, "reports matching jpr-review version")

        local missing = run_health_check_with_stubs(temp_directory .. "/does-not-exist")
        assert(#missing.errors >= 1, "missing binary records health error")
        assert(table.concat(missing.errors, "\n"):find(":Lazy build jpr-nvim", 1, true) ~= nil, "missing binary health error mentions :Lazy build jpr-nvim")

        local mismatched = run_health_check_with_stubs(mismatched_binary)
        assert(#mismatched.errors >= 1, "mismatched binary records health error")
        local mismatch_text = table.concat(mismatched.errors, "\n")
        assert(mismatch_text:find("0.1.0", 1, true) ~= nil and mismatch_text:find(":Lazy build jpr-nvim", 1, true) ~= nil, "mismatch error text: " .. mismatch_text)
    end)
end

test_binary_path_helpers()
test_build_agent_env_from_session()
test_agent_terminal_finds_bundled_binary()
test_find_cargo_executable()
test_root_build_lua_coroutine_and_cwd()
test_root_build_lua_error_cases()
test_health_check()

print("build_and_binary_spec: ok")
