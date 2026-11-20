-- Newline-delimited JSON-RPC client for the jpr-review engine (docs/protocol.md).
local M = {}

M.PROTOCOL_VERSION = 1

--- Splits job output into complete lines. `data` follows jobstart's on_stdout
--- contract: the first item continues the pending partial line, and the last
--- item is the new partial line ("" right after a newline).
function M.split_chunks(pending, data)
    local lines = {}
    local current = pending .. (data[1] or "")
    for i = 2, #data do
        lines[#lines + 1] = current
        current = data[i]
    end
    return lines, current
end

--- Decodes one line into a message, or nil and an error.
function M.decode(line)
    local ok, message = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not ok or type(message) ~= "table" then
        return nil, "invalid JSON from the engine: " .. line
    end
    return message
end

local Client = {}
Client.__index = Client

--- Starts `cmd` and returns a client, or nil and an error.
--- opts: cwd, on_notification(method, params), on_exit(code, stderr).
function M.start(cmd, opts)
    local self = setmetatable({ next_id = 1, callbacks = {}, pending = "", stderr = {}, opts = opts or {} }, Client)
    -- jobstart raises, rather than returning -1, when cmd[1] is not executable.
    local ok, job = pcall(vim.fn.jobstart, cmd, {
        cwd = self.opts.cwd,
        on_stdout = function(_, data)
            self:_on_stdout(data)
        end,
        on_stderr = function(_, data)
            for _, line in ipairs(data) do
                if line ~= "" then
                    self.stderr[#self.stderr + 1] = line
                end
            end
        end,
        on_exit = function(_, code)
            self:_on_exit(code)
        end,
    })
    if not ok or job <= 0 then
        return nil, "could not start " .. cmd[1]
    end
    self.job = job
    return self
end

--- Dispatches every complete line. A callback that raises does not stop the
--- lines after it; the first failure is raised once they have all run.
function Client:_on_stdout(data)
    local lines, first_err
    lines, self.pending = M.split_chunks(self.pending, data)
    for _, line in ipairs(lines) do
        if line ~= "" then
            local ok, err = pcall(self._dispatch, self, line)
            first_err = first_err or (not ok and err) or nil
        end
    end
    if first_err then
        error(first_err, 0)
    end
end

function Client:_dispatch(line)
    local message, err = M.decode(line)
    if not message then
        if self.opts.on_notification then
            self.opts.on_notification("protocolError", { message = err })
        end
        return
    end
    if message.id ~= nil and message.method == nil then
        local callback = self.callbacks[message.id]
        self.callbacks[message.id] = nil
        if callback then
            if message.error then
                callback(message.error, nil)
            else
                callback(nil, message.result)
            end
        end
    elseif message.method and self.opts.on_notification then
        self.opts.on_notification(message.method, message.params)
    end
end

function Client:_on_exit(code)
    self.exited = true
    for id, callback in pairs(self.callbacks) do
        self.callbacks[id] = nil
        callback({ code = -1, message = ("the engine exited (%d)"):format(code) }, nil)
    end
    if self.opts.on_exit then
        self.opts.on_exit(code, table.concat(self.stderr, "\n"))
    end
end

--- Sends `method` with `params`; `callback(err, result)` runs on the answer.
function Client:request(method, params, callback)
    if self.exited then
        return callback({ code = -1, message = "the engine is not running" }, nil)
    end
    local id = self.next_id
    self.next_id = id + 1
    self.callbacks[id] = callback
    local payload = vim.json.encode({ jsonrpc = "2.0", id = id, method = method, params = params or vim.empty_dict() })
    -- A closed channel raises; drop the callback so it cannot fire twice later.
    local ok, sent = pcall(vim.fn.chansend, self.job, payload .. "\n")
    if not ok or sent == 0 then
        self.callbacks[id] = nil
        callback({ code = -1, message = "could not write to the engine" }, nil)
    end
end

function Client:stop()
    if not self.exited then
        vim.fn.jobstop(self.job)
    end
end

return M
