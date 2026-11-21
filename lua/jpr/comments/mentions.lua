-- `@mention` completion backed by the engine's `mentions` list: works via
-- `<C-x><C-o>` (`omnifunc`) everywhere and registers an optional `nvim-cmp`
-- source (`jpr_mentions`) when `cmp` is loaded.
local M = {}

local active_candidates = {}
local candidates_by_buf = {}

--- Finds the 0-based byte index of `@` before the cursor on `line_to_cursor`,
--- or -1 when the cursor is not completing a mention.
function M.find_start(line_to_cursor)
    local text = line_to_cursor or ""
    local start_idx = text:find("@[%w_%-]*$")
    if not start_idx then
        return -1
    end
    return start_idx - 1
end

local function create_completion_item(candidate)
    local menu = "[repo]"
    if candidate.isParticipant then
        menu = "[PR]"
    end
    return {
        word = "@" .. candidate.login,
        abbr = "@" .. candidate.login,
        menu = menu,
        icase = 1,
    }
end

--- Builds completion items matching `base` (such as `"@pa"` or `"@"`),
--- keeping PR participants ahead of other assignable repository users.
function M.complete_items(candidates, base)
    local query = (base or ""):gsub("^@", ""):lower()
    local participants, others = {}, {}
    for _, candidate in ipairs(candidates or {}) do
        if type(candidate.login) == "string" and candidate.login:lower():find(query, 1, true) == 1 then
            local entry = create_completion_item(candidate)
            if candidate.isParticipant then
                participants[#participants + 1] = entry
            else
                others[#others + 1] = entry
            end
        end
    end
    vim.list_extend(participants, others)
    return participants
end

--- Global omnifunc entry point (`v:lua.require'jpr.comments.mentions'.omnifunc`).
function M.omnifunc(findstart, base)
    if findstart == 1 then
        local col = vim.api.nvim_win_get_cursor(0)[2]
        local line = vim.api.nvim_get_current_line():sub(1, col)
        return M.find_start(line)
    end
    local buf = vim.api.nvim_get_current_buf()
    local candidates = candidates_by_buf[buf] or active_candidates
    return M.complete_items(candidates, base)
end

local cmp_registered = false

local function build_cmp_items(before)
    local start_col = M.find_start(before)
    if start_col < 0 then
        return {}
    end
    local prefix = before:sub(start_col + 1)
    local buf = vim.api.nvim_get_current_buf()
    local candidates = candidates_by_buf[buf] or active_candidates
    local out = {}
    for index, item in ipairs(M.complete_items(candidates, prefix)) do
        out[#out + 1] = {
            label = item.word,
            sortText = ("%04d"):format(index),
            detail = item.menu,
        }
    end
    return out
end

local function maybe_register_cmp()
    if cmp_registered then
        return
    end
    local ok, cmp = pcall(require, "cmp")
    if not ok or type(cmp.register_source) ~= "function" then
        return
    end
    cmp_registered = true
    cmp.register_source("jpr_mentions", {
        is_available = function()
            return vim.b.jpr_compose == true
        end,
        get_trigger_characters = function()
            return { "@" }
        end,
        complete = function(_, params, callback)
            local before = params.context.cursor_before_line or ""
            callback({ items = build_cmp_items(before), isIncomplete = false })
        end,
    })
end

--- Attaches `@mention` completion to compose buffer `buf` for `session`.
function M.attach(session, buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    vim.b[buf].jpr_compose = true
    vim.bo[buf].omnifunc = "v:lua.require'jpr.comments.mentions'.omnifunc"
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            candidates_by_buf[buf] = nil
        end,
    })
    maybe_register_cmp()
    if not session or session.closing or not session.client then
        return
    end
    require("jpr.session").request(session, "mentions", nil, function(res)
        if session.closing or not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        local candidates = (res and res.candidates) or {}
        candidates_by_buf[buf] = candidates
        active_candidates = candidates
    end, function() end)
end

return M
