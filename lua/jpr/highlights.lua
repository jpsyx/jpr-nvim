-- Highlight group definitions for jpr: semantic UI links plus soft
-- background-only diff tints blended from the active colorscheme's Normal.bg.
local M = {}

local SEMANTIC_LINKS = {
    JprTitle = "Title",
    JprMuted = "Comment",
    JprViewed = "DiagnosticOk",
    JprDismissed = "DiagnosticWarn",
    JprModified = "Special",
    JprAdded = "Added",
    JprRemoved = "Removed",
    JprError = "DiagnosticError",
    JprDiffFiller = "NonText",
    JprHunk = "Special",
    JprFileHeader = "Title",
    JprThreadPublished = "DiagnosticInfo",
    JprThreadDraft = "DiagnosticWarn",
    JprThreadLocal = "DiagnosticHint",
    JprThreadFailed = "DiagnosticError",
    JprThreadResolved = "Comment",
    JprReactionActive = "DiagnosticOk",
    JprAuthor = "Identifier",
}

local DARK_TINTS = {
    add = 0x3fb950,
    delete = 0xf85149,
    add_alpha = 0.24,
    add_text_alpha = 0.38,
    delete_alpha = 0.24,
    delete_text_alpha = 0.38,
}

local LIGHT_TINTS = {
    add = 0x2ea043,
    delete = 0xcf222e,
    add_alpha = 0.24,
    add_text_alpha = 0.38,
    delete_alpha = 0.22,
    delete_text_alpha = 0.34,
}

local DARK_FALLBACK_DIFF_HIGHLIGHTS = {
    JprDiffAdd = { bg = 0x274932 },
    JprDiffAddText = { bg = 0x2c5d37 },
    JprDiffDelete = { bg = 0x542b2d },
    JprDiffDeleteText = { bg = 0x723232 },
}

local LIGHT_FALLBACK_DIFF_HIGHLIGHTS = {
    JprDiffAdd = { bg = 0xcde8d2 },
    JprDiffAddText = { bg = 0xb0dbb8 },
    JprDiffDelete = { bg = 0xf4ced1 },
    JprDiffDeleteText = { bg = 0xefb4b8 },
}

local last_applied_diff_bg = {}

local function rgb_to_channels(rgb)
    local red = math.floor(rgb / 0x10000) % 256
    local green = math.floor(rgb / 0x100) % 256
    local blue = rgb % 256
    return red, green, blue
end

local function clamp_channel(channel_value)
    return math.max(0, math.min(255, channel_value))
end

--- Blends 24-bit `base_rgb` toward `tint_rgb` by `alpha`, returning a 24-bit RGB
--- integer with each channel rounded and clamped to `[0, 255]`. Used to compute
--- subtle diff background tints against the active colorscheme.
function M.blend_rgb(base_rgb, tint_rgb, alpha)
    local base_red, base_green, base_blue = rgb_to_channels(base_rgb)
    local tint_red, tint_green, tint_blue = rgb_to_channels(tint_rgb)
    local base_weight = 1 - alpha
    local red = clamp_channel(math.floor(base_red * base_weight + tint_red * alpha + 0.5))
    local green = clamp_channel(math.floor(base_green * base_weight + tint_green * alpha + 0.5))
    local blue = clamp_channel(math.floor(base_blue * base_weight + tint_blue * alpha + 0.5))
    return red * 0x10000 + green * 0x100 + blue
end

--- Returns whether the active background should be treated as dark so diff
--- tints pick dark- or light-theme palettes, using `normal_bg` luminance when
--- available and falling back to `background_option` (`vim.o.background`).
function M.is_dark_background(normal_bg, background_option)
    if type(normal_bg) == "number" then
        local red, green, blue = rgb_to_channels(normal_bg)
        return (0.2126 * red + 0.7152 * green + 0.0722 * blue) < 128
    end
    return background_option ~= "light"
end

--- Creates background-only diff highlight specs (with no `fg`) blended onto
--- `normal_bg`, falling back to dark or light presets when `normal_bg` is nil
--- so syntax foreground colors remain legible across colorschemes.
function M.create_diff_highlights(normal_bg, background_option)
    local is_dark = M.is_dark_background(normal_bg, background_option)
    if type(normal_bg) ~= "number" then
        return vim.deepcopy(is_dark and DARK_FALLBACK_DIFF_HIGHLIGHTS or LIGHT_FALLBACK_DIFF_HIGHLIGHTS)
    end
    local tints = is_dark and DARK_TINTS or LIGHT_TINTS
    return {
        JprDiffAdd = { bg = M.blend_rgb(normal_bg, tints.add, tints.add_alpha) },
        JprDiffAddText = { bg = M.blend_rgb(normal_bg, tints.add, tints.add_text_alpha) },
        JprDiffDelete = { bg = M.blend_rgb(normal_bg, tints.delete, tints.delete_alpha) },
        JprDiffDeleteText = { bg = M.blend_rgb(normal_bg, tints.delete, tints.delete_text_alpha) },
    }
end

local function should_update_diff_highlight(group_name)
    local previous_bg = last_applied_diff_bg[group_name]
    if previous_bg == nil then
        return false
    end
    local existing_highlight = vim.api.nvim_get_hl(0, { name = group_name, link = true })
    return existing_highlight.link == nil and existing_highlight.fg == nil and existing_highlight.bg == previous_bg
end

local function apply_diff_highlights()
    local normal_highlight = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local diff_highlights = M.create_diff_highlights(normal_highlight.bg, vim.o.background)
    for group_name, spec in pairs(diff_highlights) do
        local is_managed = should_update_diff_highlight(group_name)
        vim.api.nvim_set_hl(0, group_name, { bg = spec.bg, default = not is_managed })
        local applied_highlight = vim.api.nvim_get_hl(0, { name = group_name, link = true })
        if applied_highlight.link == nil and applied_highlight.fg == nil and applied_highlight.bg == spec.bg then
            last_applied_diff_bg[group_name] = spec.bg
        else
            last_applied_diff_bg[group_name] = nil
        end
    end
end

--- Defines jpr's semantic highlight links and soft background-only diff tints,
--- refreshing them automatically whenever the colorscheme changes.
function M.define_highlights()
    for group_name, target in pairs(SEMANTIC_LINKS) do
        vim.api.nvim_set_hl(0, group_name, { link = target, default = true })
    end
    apply_diff_highlights()
    local group = vim.api.nvim_create_augroup("jpr-highlights", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = group,
        callback = function()
            M.define_highlights()
        end,
    })
end

return M
