-- The global diff view mode, "unified" or "split", remembered across Neovim
-- restarts. A frontend preference, so it lives here rather than in the engine.
local M = {}

local MODES = { unified = true, split = true }

--- Where the mode is remembered. Specs point it at a temporary file.
M.path = vim.fn.stdpath("state") .. "/jpr/view-mode"

local current_mode

--- The mode in effect: the remembered one, else `setup({ view = ... })`'s.
function M.get()
    if current_mode then
        return current_mode
    end
    local ok, lines = pcall(vim.fn.readfile, M.path)
    local saved_mode = ok and lines[1] or nil
    current_mode = MODES[saved_mode] and saved_mode or require("jpr").config.view
    return current_mode
end

--- Sets `mode` and remembers it for the next Neovim.
function M.set(mode)
    current_mode = mode
    vim.fn.mkdir(vim.fs.dirname(M.path), "p")
    pcall(vim.fn.writefile, { mode }, M.path)
end

--- Flips between unified and split, remembers it, and returns the new mode.
function M.toggle()
    local next_mode = M.get() == "split" and "unified" or "split"
    M.set(next_mode)
    return next_mode
end

--- Forgets the mode read so far, so the next `get` reads the file again.
function M.reset()
    current_mode = nil
end

return M
