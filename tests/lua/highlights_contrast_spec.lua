local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local contrast = require("jpr.highlights.contrast")

local function rgb_to_channels(rgb)
    return math.floor(rgb / 0x10000) % 256, math.floor(rgb / 0x100) % 256, rgb % 256
end

local function angular_diff_deg(hue_a, hue_b)
    local delta = math.abs(hue_a - hue_b) % (2 * math.pi)
    if delta > math.pi then
        delta = 2 * math.pi - delta
    end
    return math.deg(delta)
end

-- WCAG luminance and contrast ratio endpoints.
assert(contrast.relative_luminance(0x000000) == 0, "black luminance is 0")
assert(math.abs(contrast.relative_luminance(0xffffff) - 1) < 1e-6, "white luminance is 1")
assert(math.abs(contrast.contrast_ratio(0x000000, 0xffffff) - 21.0) < 0.01, "black/white ratio is 21:1")
assert(math.abs(contrast.contrast_ratio(0xffffff, 0x000000) - 21.0) < 0.01, "contrast ratio is symmetric")

-- OKLCH round-trip accuracy across dark, light, saturated, and neutral samples.
for _, sample_rgb in ipairs({ 0x000000, 0xffffff, 0x282c34, 0x98c379, 0xe06c75, 0x61afef, 0xc678dd, 0x116329 }) do
    local lightness, chroma, hue = contrast.rgb_to_oklch(sample_rgb)
    local round_tripped = contrast.oklch_to_rgb_clamped(lightness, chroma, hue)
    local sample_red, sample_green, sample_blue = rgb_to_channels(sample_rgb)
    local result_red, result_green, result_blue = rgb_to_channels(round_tripped)
    assert(
        math.abs(sample_red - result_red) <= 1
            and math.abs(sample_green - result_green) <= 1
            and math.abs(sample_blue - result_blue) <= 1,
        ("OKLCH round-trip drift for #%06x -> #%06x"):format(sample_rgb, round_tripped)
    )
end

-- Dark theme (onedark) contrast lifting, hue lock, chroma retention, and same-hue guard.
local onedark_bg = 0x282c34
local dark_add_bg = 0x2d4e3b
local dark_delete_bg = 0x5a3539
local dark_tokens = {
    { name = "Normal", rgb = 0xabb2bf, chromatic = false },
    { name = "Comment", rgb = 0x5c6370, chromatic = false },
    { name = "String", rgb = 0x98c379, chromatic = true },
    { name = "Error", rgb = 0xe06c75, chromatic = true },
    { name = "Keyword", rgb = 0xc678dd, chromatic = true },
    { name = "Func", rgb = 0x61afef, chromatic = true },
}

for _, token in ipairs(dark_tokens) do
    local fg_lightness, _, fg_hue = contrast.rgb_to_oklch(token.rgb)
    for label, diff_bg in pairs({ add = dark_add_bg, delete = dark_delete_bg }) do
        local adjusted = contrast.adjust_fg_for_diff_bg(token.rgb, onedark_bg, diff_bg, true)
        local original_ratio = contrast.contrast_ratio(token.rgb, diff_bg)
        local adjusted_ratio = contrast.contrast_ratio(adjusted, diff_bg)
        assert(adjusted_ratio > original_ratio, ("%s contrast must increase on %s"):format(token.name, label))
        local out_lightness, out_chroma, out_hue = contrast.rgb_to_oklch(adjusted)
        assert(out_lightness > fg_lightness, ("%s must lighten on dark %s"):format(token.name, label))
        if token.chromatic then
            assert(angular_diff_deg(fg_hue, out_hue) < 2.0, ("%s hue drifted on %s"):format(token.name, label))
            assert(out_chroma > 0.05, ("%s lost chroma on %s"):format(token.name, label))
        end
    end
end

-- White and near-white foregrounds on dark themes never lose contrast.
for _, bright_fg in ipairs({ 0xffffff, 0xf8f8f2 }) do
    for _, diff_bg in ipairs({ dark_add_bg, dark_delete_bg }) do
        local adjusted = contrast.adjust_fg_for_diff_bg(bright_fg, onedark_bg, diff_bg, true)
        assert(
            contrast.contrast_ratio(adjusted, diff_bg) >= contrast.contrast_ratio(bright_fg, diff_bg) - 1e-6,
            ("bright dark-theme fg #%06x must not lose contrast -> #%06x"):format(bright_fg, adjusted)
        )
    end
end

local dark_comment_add = contrast.adjust_fg_for_diff_bg(0x5c6370, onedark_bg, dark_add_bg, true)
local dark_normal_add = contrast.adjust_fg_for_diff_bg(0xabb2bf, onedark_bg, dark_add_bg, true)
assert(contrast.contrast_ratio(dark_comment_add, dark_add_bg) > 3.5, "dim comment lifts above 3.5:1 on dark add")
assert(
    contrast.relative_luminance(dark_comment_add) < contrast.relative_luminance(dark_normal_add),
    "comment stays quieter than Normal on dark add"
)

local green_on_add = contrast.adjust_fg_for_diff_bg(0x98c379, onedark_bg, dark_add_bg, true)
local green_on_delete = contrast.adjust_fg_for_diff_bg(0x98c379, onedark_bg, dark_delete_bg, true)
assert(
    select(1, contrast.rgb_to_oklch(green_on_add)) > select(1, contrast.rgb_to_oklch(green_on_delete)),
    "same-hue green string lifts higher on green add bg than red delete bg"
)

local red_on_add = contrast.adjust_fg_for_diff_bg(0xe06c75, onedark_bg, dark_add_bg, true)
local red_on_delete = contrast.adjust_fg_for_diff_bg(0xe06c75, onedark_bg, dark_delete_bg, true)
assert(
    select(1, contrast.rgb_to_oklch(red_on_delete)) > select(1, contrast.rgb_to_oklch(red_on_add)),
    "same-hue red error lifts higher on red delete bg than green add bg"
)

-- Light theme (github-light) darkens tokens to increase contrast and triggers same-hue guard.
local light_bg = 0xfafafa
local light_add_bg = 0xc9e5cf
local light_delete_bg = 0xf4ced1
for _, rgb in ipairs({ 0x24292f, 0x6e7781, 0x116329, 0xcf222e }) do
    local fg_lightness = select(1, contrast.rgb_to_oklch(rgb))
    for _, diff_bg in ipairs({ light_add_bg, light_delete_bg }) do
        local adjusted = contrast.adjust_fg_for_diff_bg(rgb, light_bg, diff_bg, false)
        assert(contrast.contrast_ratio(adjusted, diff_bg) > contrast.contrast_ratio(rgb, diff_bg), "light contrast increases")
        assert(select(1, contrast.rgb_to_oklch(adjusted)) < fg_lightness, "light theme darkens foreground")
    end
end
-- Black foreground on light themes never loses contrast.
for _, diff_bg in ipairs({ light_add_bg, light_delete_bg }) do
    local adjusted_black = contrast.adjust_fg_for_diff_bg(0x000000, light_bg, diff_bg, false)
    assert(
        contrast.contrast_ratio(adjusted_black, diff_bg) >= contrast.contrast_ratio(0x000000, diff_bg) - 1e-6,
        ("black light-theme fg must not lose contrast -> #%06x"):format(adjusted_black)
    )
end

local light_green_add = contrast.adjust_fg_for_diff_bg(0x116329, light_bg, light_add_bg, false)
local light_green_delete = contrast.adjust_fg_for_diff_bg(0x116329, light_bg, light_delete_bg, false)
assert(
    select(1, contrast.rgb_to_oklch(light_green_add)) < select(1, contrast.rgb_to_oklch(light_green_delete)),
    "light green string darkens more on light green add bg than red delete bg"
)

-- Nil Normal.bg fallback and extreme background boundaries remain valid 24-bit RGB without NaN.
for _, case in ipairs({
    { 0xabb2bf, nil, dark_add_bg, true },
    { 0x24292f, nil, light_add_bg, false },
    { 0x808080, 0x000000, 0x000000, true },
    { 0x808080, 0xffffff, 0xffffff, false },
}) do
    local adjusted = contrast.adjust_fg_for_diff_bg(case[1], case[2], case[3], case[4])
    assert(type(adjusted) == "number" and adjusted == adjusted, "adjusted RGB is not NaN")
    assert(adjusted >= 0 and adjusted <= 0xffffff and adjusted == math.floor(adjusted), "valid 24-bit integer RGB")
end

-- Lazy derived highlight cache, style preservation, overrides, and ColorScheme refresh.
local highlights = require("jpr.highlights")

local dot_name = highlights.build_contrast_group_name("@a.b", "add")
local underscore_name = highlights.build_contrast_group_name("@a_b", "add")
assert(dot_name ~= underscore_name, "derived group names are injective across punctuation")
assert(dot_name:match("^JprDiffAddFg_[%w_]+$") ~= nil, "add derived group matches JprDiffAddFg_ prefix")
assert(
    highlights.build_contrast_group_name("@a.b", "delete"):match("^JprDiffDeleteFg_[%w_]+$") ~= nil,
    "delete derived group matches JprDiffDeleteFg_ prefix"
)

vim.o.background = "dark"
vim.api.nvim_set_hl(0, "Normal", { bg = onedark_bg, fg = 0xabb2bf })
vim.api.nvim_set_hl(0, "@string", { fg = 0x98c379, italic = true, bold = true })
vim.api.nvim_set_hl(0, "TestBgOnly", { bg = 0x334455 })
vim.api.nvim_set_hl(0, "TestReversed", { fg = 0xabb2bf, reverse = true })
vim.api.nvim_set_hl(0, "TestTransient", { fg = 0x61afef })
highlights.define_highlights()

local derived_string_add = highlights.get_contrast_group("@string", "add")
assert(derived_string_add == highlights.build_contrast_group_name("@string", "add"), "derives @string add group")
assert(highlights.get_contrast_group("@string", "add") == derived_string_add, "returns cached derived group")
local derived_spec = vim.api.nvim_get_hl(0, { name = derived_string_add, link = false })
local active_add_bg = vim.api.nvim_get_hl(0, { name = "JprDiffAdd", link = false }).bg
assert(derived_spec.bg == nil, "derived contrast group leaves bg unset")
assert(derived_spec.italic == true and derived_spec.bold == true, "derived contrast group preserves text styles")
assert(
    contrast.contrast_ratio(derived_spec.fg, active_add_bg) > contrast.contrast_ratio(0x98c379, active_add_bg),
    "derived @string has higher contrast on active JprDiffAdd.bg"
)

assert(highlights.get_contrast_group("TestBgOnly", "add") == "TestBgOnly", "skips bg-only groups")
assert(highlights.get_contrast_group("TestReversed", "add") == "TestReversed", "skips reversed groups")

-- Transparent Normal with fg = nil returns "Normal" without error.
vim.api.nvim_set_hl(0, "Normal", { bg = onedark_bg })
highlights.define_highlights()
assert(highlights.get_contrast_group("Normal", "add") == "Normal", "transparent Normal.fg returns Normal safely")

-- Custom user override on JprDiffAdd is respected when computing contrast.
vim.api.nvim_set_hl(0, "Normal", { bg = onedark_bg, fg = 0xabb2bf })
vim.api.nvim_set_hl(0, "JprDiffAdd", { bg = 0x3a6e4c })
highlights.define_highlights()
local custom_derived = highlights.get_contrast_group("TestTransient", "add")
local custom_spec = vim.api.nvim_get_hl(0, { name = custom_derived, link = false })
local expected_custom_fg = contrast.adjust_fg_for_diff_bg(0x61afef, onedark_bg, 0x3a6e4c, true)
assert(custom_spec.fg == expected_custom_fg, "uses active custom JprDiffAdd.bg override")

-- ColorScheme refresh updates registered derived groups in place and relinks groups that lose fg.
vim.api.nvim_set_hl(0, "JprDiffAdd", {})
vim.o.background = "light"
vim.api.nvim_set_hl(0, "Normal", { bg = light_bg, fg = 0x24292f })
vim.api.nvim_set_hl(0, "@string", { fg = 0x116329 })
vim.api.nvim_set_hl(0, "TestTransient", { bg = 0xeeeeee })
vim.api.nvim_exec_autocmds("ColorScheme", {})

local refreshed_string = vim.api.nvim_get_hl(0, { name = derived_string_add, link = false })
assert(refreshed_string.bg == nil, "refreshed derived group keeps bg unset")
assert(
    select(1, contrast.rgb_to_oklch(refreshed_string.fg)) < select(1, contrast.rgb_to_oklch(0x116329)),
    "ColorScheme refresh darkens derived @string for light theme"
)
local relinked_transient = vim.api.nvim_get_hl(0, { name = custom_derived, link = true })
assert(relinked_transient.link == "TestTransient", "derived group relinks to source when fg is lost")

-- Subsequent ColorScheme restoring fg recomputes the previously relinked derived group.
vim.api.nvim_set_hl(0, "TestTransient", { fg = 0x0550ae })
vim.api.nvim_exec_autocmds("ColorScheme", {})
local restored_transient_link = vim.api.nvim_get_hl(0, { name = custom_derived, link = true })
local restored_transient = vim.api.nvim_get_hl(0, { name = custom_derived, link = false })
assert(restored_transient_link.link == nil and type(restored_transient.fg) == "number", "recomputes derived group when fg returns")
assert(
    select(1, contrast.rgb_to_oklch(restored_transient.fg)) < select(1, contrast.rgb_to_oklch(0x0550ae)),
    "restored group receives contrast adjustment for active theme"
)

print("highlights_contrast_spec: ok")
