local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local rpc = require("jpr.rpc")

local lines, pending = rpc.split_chunks("", { '{"a":1}', '{"b"' })
assert(vim.deep_equal(lines, { '{"a":1}' }) and pending == '{"b"', "a partial line waits")
lines, pending = rpc.split_chunks(pending, { ":2}", "" })
assert(vim.deep_equal(lines, { '{"b":2}' }) and pending == "", "the rest completes it")

assert(rpc.decode("not json") == nil, "invalid JSON decodes to nil")
assert(rpc.decode('{"id":1,"result":null}').id == 1, "valid JSON decodes")

local notifications, exited = {}, nil
local client = assert(rpc.start({ root .. "/tests/lua/fixtures/fake_engine.sh" }, {
    on_notification = function(method, params)
        notifications[#notifications + 1] = { method = method, params = params }
    end,
    on_exit = function(code)
        exited = code
    end,
}))

local init
client:request("initialize", { protocolVersion = rpc.PROTOCOL_VERSION }, function(err, result)
    init = { err = err, result = result }
end)
assert(vim.wait(2000, function()
    return init ~= nil
end), "initialize is answered")
assert(init.err == nil and init.result.protocolVersion == 1, vim.inspect(init))

local synced
client:request("sync", nil, function(err, result)
    synced = { err = err, result = result }
end)
assert(vim.wait(2000, function()
    return synced ~= nil
end), "sync is answered")
assert(synced.result.pr.number == 7, vim.inspect(synced))
assert(#notifications == 1 and notifications[1].method == "event", vim.inspect(notifications))
assert(notifications[1].params.type == "synced", "the event is a sync")

local unknown
client:request("frobnicate", nil, function(err)
    unknown = err
end)
assert(vim.wait(2000, function()
    return unknown ~= nil
end), "an unknown method is answered")
assert(unknown.code == -32601, vim.inspect(unknown))

local stopped
client:request("shutdown", nil, function()
    stopped = true
end)
assert(vim.wait(2000, function()
    return stopped and exited ~= nil
end), "shutdown ends the process")

local late
client:request("snapshot", nil, function(err)
    late = err
end)
assert(late and late.message:find("not running", 1, true), "requests after exit fail at once")

local missing, missing_err = rpc.start({ root .. "/tests/lua/fixtures/missing-engine" }, {})
assert(missing == nil and missing_err:find("could not start", 1, true), "a binary that is not executable is an error, not a raise")

-- A callback that raises does not swallow the messages after it in the same chunk.
local answered
local isolated = assert(rpc.start({ root .. "/tests/lua/fixtures/fake_engine.sh" }, {
    on_notification = function()
        error("a broken notification handler")
    end,
}))
isolated.callbacks[1] = function(_, result)
    answered = result
end
local raised, raise_err = pcall(isolated._on_stdout, isolated, {
    '{"jsonrpc":"2.0","method":"event","params":{"type":"syncFailed","message":"offline"}}',
    '{"jsonrpc":"2.0","id":1,"result":"after"}',
    "",
})
assert(answered == "after", "the reply after a failing notification still reaches its callback")
assert(not raised and tostring(raise_err):find("a broken notification handler", 1, true), "the failure is still raised: " .. tostring(raise_err))
isolated:stop()

print("rpc_spec: ok")
