-- Highlight group definitions for jpr: semantic UI links, soft background-only
-- diff tints blended from the active colorscheme's Normal.bg, and lazy
-- OKLCH contrast-adjusted foreground companion groups.
local contrast = require("jpr.highlights.contrast")

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

local CONTRAST_PREFIX = {
    add = "JprDiffAddFg_",
    delete = "JprDiffDeleteFg_",
}

local KIND_TO_DIFF_GROUP = {
    add = "JprDiffAdd",
    delete = "JprDiffDelete",
}

local PRESERVED_STYLE_ATTRS = {
    "bold",
    "italic",
    "underline",
    "undercurl",
    "underdouble",
    "underdotted",
    "underdashed",
    "strikethrough",
    "sp",
    "blend",
    "standout",
    "nocombine",
}

local last_applied_diff_bg = {}
local contrast_cache = {}
local registered_derived = {}

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

--- Builds an injective, Neovim-safe companion highlight group name for
--- `source_group` under diff `kind` (`"add"` or `"delete"`).
function M.build_contrast_group_name(source_group, kind)
    local prefix = CONTRAST_PREFIX[kind]
    if not prefix or type(source_group) ~= "string" or source_group == "" then
        return nil
    end
    local encoded = source_group:gsub("([^%w])", function(character)
        return ("_%02x"):format(character:byte())
    end)
    return prefix .. encoded
end

local function resolve_active_diff_bg(kind, normal_bg)
    local diff_group = KIND_TO_DIFF_GROUP[kind]
    local active_diff = vim.api.nvim_get_hl(0, { name = diff_group, link = false })
    if type(active_diff.bg) == "number" then
        return active_diff.bg
    end
    local fallback = M.create_diff_highlights(normal_bg, vim.o.background)
    return fallback[diff_group].bg
end

local function create_theme_context()
    local normal_highlight = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local add_bg = resolve_active_diff_bg("add", normal_highlight.bg)
    local delete_bg = resolve_active_diff_bg("delete", normal_highlight.bg)
    return {
        normal_bg = normal_highlight.bg,
        diff_bg = { add = add_bg, delete = delete_bg },
        is_dark = {
            add = M.is_dark_background(add_bg, vim.o.background),
            delete = M.is_dark_background(delete_bg, vim.o.background),
        },
    }
end

local function apply_contrast_highlight(source_group, kind, derived_name, theme_context)
    local source_highlight = vim.api.nvim_get_hl(0, { name = source_group, link = false })
    if type(source_highlight.fg) ~= "number" or source_highlight.reverse == true then
        return false
    end
    local context = theme_context or create_theme_context()
    local spec = {
        fg = contrast.adjust_fg_for_diff_bg(
            source_highlight.fg,
            context.normal_bg,
            context.diff_bg[kind],
            context.is_dark[kind]
        ),
    }
    for _, attr in ipairs(PRESERVED_STYLE_ATTRS) do
        if source_highlight[attr] ~= nil then
            spec[attr] = source_highlight[attr]
        end
    end
    vim.api.nvim_set_hl(0, derived_name, spec)
    return true
end

--- Returns the lazily derived contrast-adjusted highlight group for
--- `source_group` on diff `kind` (`"add"` or `"delete"`), or `source_group`
--- unchanged when the source group has no numeric `fg` or sets `reverse = true`.
function M.get_contrast_group(source_group, kind)
    local derived_name = M.build_contrast_group_name(source_group, kind)
    if not derived_name then
        return source_group
    end
    local cached = contrast_cache[derived_name]
    if cached ~= nil then
        return cached or source_group
    end
    if apply_contrast_highlight(source_group, kind, derived_name, nil) then
        contrast_cache[derived_name] = derived_name
        registered_derived[derived_name] = { source = source_group, kind = kind }
        return derived_name
    end
    contrast_cache[derived_name] = false
    return source_group
end

--- Clears the in-memory contrast lookup cache and registered derived entries.
function M.reset_contrast_cache()
    contrast_cache = {}
    registered_derived = {}
end

local function refresh_contrast_highlights()
    contrast_cache = {}
    if next(registered_derived) == nil then
        return
    end
    local theme_context = create_theme_context()
    for derived_name, entry in pairs(registered_derived) do
        if apply_contrast_highlight(entry.source, entry.kind, derived_name, theme_context) then
            contrast_cache[derived_name] = derived_name
        else
            vim.api.nvim_set_hl(0, derived_name, { link = entry.source })
            contrast_cache[derived_name] = false
        end
    end
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
    refresh_contrast_highlights()
end

--- Defines jpr's semantic highlight links, soft background-only diff tints, and
--- refreshes any derived contrast foreground groups whenever the colorscheme changes.
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
