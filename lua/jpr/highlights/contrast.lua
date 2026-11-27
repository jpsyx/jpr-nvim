-- Pure perceptual OKLCH and WCAG 2.1 color contrast math for lifting syntax
-- foreground legibility over green and red diff backgrounds.
local M = {}

local CHROMATIC_CHROMA_FLOOR = 0.025
local SAME_HUE_WINDOW_DEGREES = 50
local GAMUT_EPSILON = 1e-6
local GAMUT_BINARY_SEARCH_STEPS = 10
local DEFAULT_DARK_BG_LIGHTNESS = 0.25
local DEFAULT_LIGHT_BG_LIGHTNESS = 0.96

local function srgb_to_linear(channel_unit)
    if channel_unit <= 0.04045 then
        return channel_unit / 12.92
    end
    return ((channel_unit + 0.055) / 1.055) ^ 2.4
end

local function linear_to_srgb(linear_channel)
    local clamped = math.max(0, math.min(1, linear_channel))
    if clamped <= 0.0031308 then
        return 12.92 * clamped
    end
    return 1.055 * (clamped ^ (1 / 2.4)) - 0.055
end

local function signed_cbrt(value)
    if value >= 0 then
        return value ^ (1 / 3)
    end
    return -((-value) ^ (1 / 3))
end

local function rgb_to_linear_channels(rgb)
    local red = srgb_to_linear((math.floor(rgb / 0x10000) % 256) / 255)
    local green = srgb_to_linear((math.floor(rgb / 0x100) % 256) / 255)
    local blue = srgb_to_linear((rgb % 256) / 255)
    return red, green, blue
end

local function linear_channels_to_rgb(red, green, blue)
    local function encode_channel(linear_channel)
        return math.max(0, math.min(255, math.floor(linear_to_srgb(linear_channel) * 255 + 0.5)))
    end
    return encode_channel(red) * 0x10000 + encode_channel(green) * 0x100 + encode_channel(blue)
end

local function oklch_to_linear_channels(lightness, chroma, hue)
    local lab_a = chroma * math.cos(hue)
    local lab_b = chroma * math.sin(hue)
    local cone_l = (lightness + 0.3963377774 * lab_a + 0.2158037573 * lab_b) ^ 3
    local cone_m = (lightness - 0.1055613458 * lab_a - 0.0638541728 * lab_b) ^ 3
    local cone_s = (lightness - 0.0894841775 * lab_a - 1.2914855480 * lab_b) ^ 3
    local red = 4.0767416621 * cone_l - 3.3077115913 * cone_m + 0.2309699292 * cone_s
    local green = -1.2684380046 * cone_l + 2.6097574011 * cone_m - 0.3413193965 * cone_s
    local blue = -0.0041960863 * cone_l - 0.7034186147 * cone_m + 1.7076147010 * cone_s
    return red, green, blue
end

local function is_in_srgb_gamut(red, green, blue)
    return red >= -GAMUT_EPSILON
        and red <= 1 + GAMUT_EPSILON
        and green >= -GAMUT_EPSILON
        and green <= 1 + GAMUT_EPSILON
        and blue >= -GAMUT_EPSILON
        and blue <= 1 + GAMUT_EPSILON
end

local function compute_hue_proximity(hue_a, hue_b)
    local angular_delta = math.abs(hue_a - hue_b) % (2 * math.pi)
    if angular_delta > math.pi then
        angular_delta = 2 * math.pi - angular_delta
    end
    local degrees = math.deg(angular_delta)
    if degrees >= SAME_HUE_WINDOW_DEGREES then
        return 0
    end
    return 0.5 * (1 + math.cos(math.pi * degrees / SAME_HUE_WINDOW_DEGREES))
end

local function compute_target_lightness(fg_lightness, bg_lightness, bg_shift, same_hue, is_dark)
    local lift = bg_shift * 0.85 + 0.04 + 0.06 * same_hue
    local min_separation = 0.34 + 0.08 * same_hue
    if is_dark then
        local ceiling = math.max(0.96, fg_lightness)
        local headroom = math.max(0, 0.95 - fg_lightness)
        local lifted = fg_lightness + headroom * (1 - math.exp(-lift / math.max(0.08, headroom)))
        return math.min(ceiling, math.max(lifted, math.min(0.94, bg_lightness + min_separation)))
    end
    local floor = math.min(0.10, fg_lightness)
    local headroom = math.max(0, fg_lightness - 0.12)
    local darkened = fg_lightness - headroom * (1 - math.exp(-lift / math.max(0.08, headroom)))
    return math.max(floor, math.min(darkened, math.max(0.14, bg_lightness - min_separation)))
end

--- Returns the WCAG 2.1 relative luminance in `[0, 1]` for a 24-bit sRGB integer.
function M.relative_luminance(rgb)
    local red, green, blue = rgb_to_linear_channels(rgb)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue
end

--- Returns the symmetric WCAG 2.1 contrast ratio in `[1, 21]` between two
--- 24-bit sRGB integers.
function M.contrast_ratio(rgb_a, rgb_b)
    local luminance_a = M.relative_luminance(rgb_a)
    local luminance_b = M.relative_luminance(rgb_b)
    if luminance_a < luminance_b then
        luminance_a, luminance_b = luminance_b, luminance_a
    end
    return (luminance_a + 0.05) / (luminance_b + 0.05)
end

--- Converts a 24-bit sRGB integer to perceptual OKLCH `(lightness, chroma, hue)`
--- where `hue` is in radians `[-pi, pi]`.
function M.rgb_to_oklch(rgb)
    local red, green, blue = rgb_to_linear_channels(rgb)
    local cone_l = signed_cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
    local cone_m = signed_cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
    local cone_s = signed_cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
    local lightness = 0.2104542553 * cone_l + 0.7936177850 * cone_m - 0.0040720468 * cone_s
    local lab_a = 1.9779984951 * cone_l - 2.4285922050 * cone_m + 0.4505937099 * cone_s
    local lab_b = 0.0259040371 * cone_l + 0.7827717662 * cone_m - 0.8086757660 * cone_s
    return lightness, math.sqrt(lab_a * lab_a + lab_b * lab_b), math.atan2(lab_b, lab_a)
end

--- Converts OKLCH `(lightness, chroma, hue)` to a 24-bit sRGB integer while
--- locking `hue` and binary-searching `chroma` into the sRGB gamut when needed.
--- Returns `(rgb, clamped_chroma)`.
function M.oklch_to_rgb_clamped(lightness, chroma, hue)
    local red, green, blue = oklch_to_linear_channels(lightness, chroma, hue)
    if is_in_srgb_gamut(red, green, blue) then
        return linear_channels_to_rgb(red, green, blue), chroma
    end
    local low_chroma, high_chroma = 0, chroma
    for _ = 1, GAMUT_BINARY_SEARCH_STEPS do
        local mid_chroma = (low_chroma + high_chroma) * 0.5
        local mid_red, mid_green, mid_blue = oklch_to_linear_channels(lightness, mid_chroma, hue)
        if is_in_srgb_gamut(mid_red, mid_green, mid_blue) then
            low_chroma = mid_chroma
        else
            high_chroma = mid_chroma
        end
    end
    local final_red, final_green, final_blue = oklch_to_linear_channels(lightness, low_chroma, hue)
    return linear_channels_to_rgb(final_red, final_green, final_blue), low_chroma
end

--- Computes a contrast-adjusted 24-bit foreground sRGB color for `fg_rgb` drawn
--- over `diff_bg_rgb`, compensating for the lightness shift from `normal_bg_rgb`
--- (when known) and adding a smooth same-hue boost while keeping the token's
--- OKLCH hue locked.
function M.adjust_fg_for_diff_bg(fg_rgb, normal_bg_rgb, diff_bg_rgb, is_dark)
    local fg_lightness, fg_chroma, fg_hue = M.rgb_to_oklch(fg_rgb)
    local bg_lightness, bg_chroma, bg_hue = M.rgb_to_oklch(diff_bg_rgb)
    local original_background_lightness = type(normal_bg_rgb) == "number" and select(1, M.rgb_to_oklch(normal_bg_rgb))
        or (is_dark and DEFAULT_DARK_BG_LIGHTNESS or DEFAULT_LIGHT_BG_LIGHTNESS)
    local bg_shift = is_dark and math.max(0, bg_lightness - original_background_lightness)
        or math.max(0, original_background_lightness - bg_lightness)
    local is_both_chromatic = fg_chroma > CHROMATIC_CHROMA_FLOOR and bg_chroma > CHROMATIC_CHROMA_FLOOR
    local same_hue = is_both_chromatic and compute_hue_proximity(fg_hue, bg_hue) or 0
    local desired_lightness = compute_target_lightness(fg_lightness, bg_lightness, bg_shift, same_hue, is_dark)
    local adjusted_rgb = M.oklch_to_rgb_clamped(desired_lightness, fg_chroma, fg_hue)
    return adjusted_rgb
end

--- Moves `rgb` toward white by `amount` of the remaining OKLab lightness.
--- `amount` 0.10 brightens by 10%. Hue stays locked. Zero or a non-number
--- returns `rgb` unchanged.
function M.brighten_background(rgb, amount)
    if type(rgb) ~= "number" then
        return rgb
    end
    local fraction = tonumber(amount) or 0
    if fraction <= 0 then
        return rgb
    end
    local lightness, chroma, hue = M.rgb_to_oklch(rgb)
    local brightened = math.min(1, lightness + fraction * (1 - lightness))
    return select(1, M.oklch_to_rgb_clamped(brightened, chroma, hue))
end

--- Searches OKLab lightness from `lightness` toward white or black until the
--- contrast against `background_rgb` reaches `target_ratio`.
local function contrast_along_lightness(lightness, chroma, hue, background_rgb, target_ratio, move_lighter)
    local near = lightness
    local extreme_lightness = move_lighter and 1 or 0
    local far = extreme_lightness
    local best_rgb = select(1, M.oklch_to_rgb_clamped(lightness, chroma, hue))
    local best_ratio = M.contrast_ratio(best_rgb, background_rgb)
    for _ = 1, 18 do
        local mid = (near + far) * 0.5
        local candidate = select(1, M.oklch_to_rgb_clamped(mid, chroma, hue))
        local ratio = M.contrast_ratio(candidate, background_rgb)
        if ratio >= target_ratio - 1e-4 then
            best_rgb, best_ratio, far = candidate, ratio, mid
        else
            near = mid
        end
    end
    local extreme = select(1, M.oklch_to_rgb_clamped(extreme_lightness, chroma, hue))
    local extreme_ratio = M.contrast_ratio(extreme, background_rgb)
    if extreme_ratio > best_ratio and best_ratio < target_ratio - 1e-3 then
        return extreme, extreme_ratio
    end
    return best_rgb, best_ratio
end

--- Raises the WCAG contrast of `foreground_rgb` against `background_rgb` by
--- `boost` (0.10 means 10%) by moving OKLab lightness away from the background
--- and locking hue. A color that cannot gain that much contrast moves as far
--- as the gamut allows. Zero or a non-number returns `foreground_rgb`.
function M.increase_contrast(foreground_rgb, background_rgb, boost)
    if type(foreground_rgb) ~= "number" or type(background_rgb) ~= "number" then
        return foreground_rgb
    end
    local fraction = tonumber(boost) or 0
    if fraction <= 0 then
        return foreground_rgb
    end
    local original_ratio = M.contrast_ratio(foreground_rgb, background_rgb)
    local target_ratio = math.min(21, original_ratio * (1 + fraction))
    if target_ratio <= original_ratio + 1e-4 then
        return foreground_rgb
    end
    local lightness, chroma, hue = M.rgb_to_oklch(foreground_rgb)
    local background_lightness = select(1, M.rgb_to_oklch(background_rgb))
    local prefer_lighter = lightness >= background_lightness
    local primary_rgb, primary_ratio =
        contrast_along_lightness(lightness, chroma, hue, background_rgb, target_ratio, prefer_lighter)
    if primary_ratio >= target_ratio - 1e-3 then
        return primary_rgb
    end
    local other_rgb, other_ratio =
        contrast_along_lightness(lightness, chroma, hue, background_rgb, target_ratio, not prefer_lighter)
    if other_ratio > primary_ratio then
        return other_rgb
    end
    return primary_rgb
end

return M
