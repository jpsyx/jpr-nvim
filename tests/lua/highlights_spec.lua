local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local jpr = require("jpr")
local highlights = require("jpr.highlights")

local function rgb_to_luminance(rgb)
    local red = math.floor(rgb / 0x10000) % 256
    local green = math.floor(rgb / 0x100) % 256
    local blue = rgb % 256
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue
end

-- rgb_to_cterm256: xterm-256 cube and greyscale quantization endpoints.
assert(highlights.rgb_to_cterm256(0x000000) == 16, "black maps to 16")
assert(highlights.rgb_to_cterm256(0xffffff) == 231, "white maps to 231")
assert(highlights.rgb_to_cterm256(0x00ff00) == 46, "pure green maps to 46")
assert(highlights.rgb_to_cterm256(0xff0000) == 196, "pure red maps to 196")
assert(highlights.rgb_to_cterm256(0x0000ff) == 21, "pure blue maps to 21")
local grey_index = highlights.rgb_to_cterm256(0x808080)
assert(grey_index == 244 or grey_index == 102, "mid-grey maps to neutral xterm-256 index")

-- blend_rgb: endpoints, midpoint, and clamping.
assert(highlights.blend_rgb(0x282c34, 0x3fb950, 0) == 0x282c34, "alpha 0 returns base")
assert(highlights.blend_rgb(0x282c34, 0x3fb950, 1) == 0x3fb950, "alpha 1 returns tint")
assert(highlights.blend_rgb(0x000000, 0xffffff, 0.5) == 0x808080, "midpoint rounds half up")
assert(highlights.blend_rgb(0x000000, 0xffffff, -0.5) == 0x000000, "clamps lower bound to 0")
assert(highlights.blend_rgb(0x000000, 0xffffff, 1.5) == 0xffffff, "clamps upper bound to 255")

-- is_dark_background: luminance threshold and bg_option fallback.
assert(highlights.is_dark_background(0x282c34, "light") == true, "dark RGB overrides light bg_option")
assert(highlights.is_dark_background(0xfafafa, "dark") == false, "light RGB overrides dark bg_option")
assert(highlights.is_dark_background(nil, "dark") == true, "nil RGB uses dark bg_option")
assert(highlights.is_dark_background(nil, "light") == false, "nil RGB uses light bg_option")
assert(highlights.is_dark_background(nil, nil) == true, "nil RGB defaults to dark")

-- create_diff_highlights: dark theme with explicit Normal.bg (onedark).
local onedark_bg = 0x282c34
local solid_bright_green = 0x98c379
local dark_groups = highlights.create_diff_highlights(onedark_bg, "dark")
for _, group_name in ipairs({ "JprDiffAdd", "JprDiffAddText", "JprDiffDelete", "JprDiffDeleteText" }) do
    local spec = dark_groups[group_name]
    assert(type(spec) == "table", group_name .. " spec exists")
    assert(type(spec.bg) == "number", group_name .. " has numeric bg")
    assert(spec.fg == nil, group_name .. " must not set fg")
end
assert(dark_groups.JprDiffAdd.bg == highlights.blend_rgb(onedark_bg, 0x3fb950, 0.24), "dark JprDiffAdd blend")
assert(dark_groups.JprDiffAdd.ctermbg == 22, "dark JprDiffAdd ctermbg is dark green 22")
assert(dark_groups.JprDiffAddText.bg == highlights.blend_rgb(onedark_bg, 0x3fb950, 0.38), "dark JprDiffAddText blend")
assert(dark_groups.JprDiffAddText.ctermbg == 28, "dark JprDiffAddText ctermbg is green 28")
assert(dark_groups.JprDiffDelete.bg == highlights.blend_rgb(onedark_bg, 0xf85149, 0.24), "dark JprDiffDelete blend")
assert(dark_groups.JprDiffDelete.ctermbg == 52, "dark JprDiffDelete ctermbg is dark red 52")
assert(dark_groups.JprDiffDeleteText.bg == highlights.blend_rgb(onedark_bg, 0xf85149, 0.38), "dark JprDiffDeleteText blend")
assert(dark_groups.JprDiffDeleteText.ctermbg == 88, "dark JprDiffDeleteText ctermbg is red 88")
local add_contrast = math.abs(rgb_to_luminance(dark_groups.JprDiffAdd.bg) - rgb_to_luminance(onedark_bg))
local solid_contrast = math.abs(rgb_to_luminance(solid_bright_green) - rgb_to_luminance(onedark_bg))
assert(add_contrast < solid_contrast * 0.25, "soft diff tint has much lower contrast than solid bright green")

-- create_diff_highlights: dark transparent fallback.
local dark_fallback = highlights.create_diff_highlights(nil, "dark")
assert(dark_fallback.JprDiffAdd.bg == 0x274932 and dark_fallback.JprDiffAdd.fg == nil, "dark fallback JprDiffAdd")
assert(dark_fallback.JprDiffAddText.bg == 0x2c5d37 and dark_fallback.JprDiffAddText.fg == nil, "dark fallback JprDiffAddText")
assert(dark_fallback.JprDiffDelete.bg == 0x542b2d and dark_fallback.JprDiffDelete.fg == nil, "dark fallback JprDiffDelete")
assert(dark_fallback.JprDiffDeleteText.bg == 0x723232 and dark_fallback.JprDiffDeleteText.fg == nil, "dark fallback JprDiffDeleteText")

-- create_diff_highlights: light theme with explicit Normal.bg and nil fallback.
local light_bg = 0xfafafa
local light_groups = highlights.create_diff_highlights(light_bg, "light")
assert(light_groups.JprDiffAdd.bg == highlights.blend_rgb(light_bg, 0x2ea043, 0.24), "light JprDiffAdd blend")
assert(light_groups.JprDiffAddText.bg == highlights.blend_rgb(light_bg, 0x2ea043, 0.38), "light JprDiffAddText blend")
assert(light_groups.JprDiffDelete.bg == highlights.blend_rgb(light_bg, 0xcf222e, 0.22), "light JprDiffDelete blend")
assert(light_groups.JprDiffDeleteText.bg == highlights.blend_rgb(light_bg, 0xcf222e, 0.34), "light JprDiffDeleteText blend")
assert(light_groups.JprDiffAdd.fg == nil and light_groups.JprDiffDelete.fg == nil, "light groups set no fg")

local light_fallback = highlights.create_diff_highlights(nil, "light")
assert(light_fallback.JprDiffAdd.bg == 0xcde8d2 and light_fallback.JprDiffAdd.fg == nil, "light fallback JprDiffAdd")
assert(light_fallback.JprDiffAddText.bg == 0xb0dbb8 and light_fallback.JprDiffAddText.fg == nil, "light fallback JprDiffAddText")
assert(light_fallback.JprDiffDelete.bg == 0xf4ced1 and light_fallback.JprDiffDelete.fg == nil, "light fallback JprDiffDelete")
assert(light_fallback.JprDiffDeleteText.bg == 0xefb4b8 and light_fallback.JprDiffDeleteText.fg == nil, "light fallback JprDiffDeleteText")

-- define_highlights in headless Neovim with onedark Normal colors.
vim.o.background = "dark"
vim.api.nvim_set_hl(0, "Normal", { bg = onedark_bg, fg = 0xabb2bf })
jpr.define_highlights()

for _, group_name in ipairs({ "JprDiffAdd", "JprDiffAddText", "JprDiffDelete", "JprDiffDeleteText" }) do
    local raw_highlight = vim.api.nvim_get_hl(0, { name = group_name, link = true })
    assert(raw_highlight.link == nil, group_name .. " is not linked to DiffAdd/DiffText/DiffDelete")
    assert(raw_highlight.fg == nil and raw_highlight.ctermfg == nil, group_name .. " leaves fg and ctermfg unset so syntax colors show through")
    assert(raw_highlight.bg == dark_groups[group_name].bg, group_name .. " bg matches blended dark tint")
    assert(raw_highlight.ctermbg == dark_groups[group_name].ctermbg, group_name .. " ctermbg matches dark 256-color tint")
end

local title_highlight = vim.api.nvim_get_hl(0, { name = "JprTitle", link = true })
assert(title_highlight.link == "Title", "semantic JprTitle remains linked")
local local_thread_highlight = vim.api.nvim_get_hl(0, { name = "JprThreadLocal", link = true })
assert(local_thread_highlight.link == "DiagnosticHint", "semantic JprThreadLocal remains linked")

-- ColorScheme autocmd updates JprDiffAdd when Normal.bg changes.
local autocmds = vim.api.nvim_get_autocmds({ group = "jpr-highlights", event = "ColorScheme" })
assert(#autocmds == 1, "jpr-highlights ColorScheme autocmd is registered once")

vim.o.background = "light"
vim.api.nvim_set_hl(0, "Normal", { bg = light_bg, fg = 0x24292f })
vim.api.nvim_exec_autocmds("ColorScheme", {})
local updated_add = vim.api.nvim_get_hl(0, { name = "JprDiffAdd", link = true })
assert(updated_add.bg == light_groups.JprDiffAdd.bg, "ColorScheme recalculates JprDiffAdd for new Normal.bg")
assert(updated_add.ctermbg == 194, "ColorScheme switches JprDiffAdd ctermbg to light green 194")
assert(updated_add.fg == nil and updated_add.ctermfg == nil and updated_add.link == nil, "updated JprDiffAdd remains background-only")

-- User overrides are preserved across define_highlights calls (both bg and ctermbg).
vim.api.nvim_set_hl(0, "JprDiffAdd", { bg = 0x112233, ctermbg = 23 })
jpr.define_highlights()
local custom_add = vim.api.nvim_get_hl(0, { name = "JprDiffAdd", link = true })
assert(custom_add.bg == 0x112233 and custom_add.ctermbg == 23, "user custom JprDiffAdd bg and ctermbg are preserved")

print("highlights_spec: ok")
