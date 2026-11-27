-- Pure rendering of GitHub comment bodies: HTML and Markdown images become
-- readable text, and conversation messages can be drawn as ASCII boxes.
local wrap_text = require("jpr.tui.render").wrap_text

local M = {}

local NAMED_ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }
local VOID_TAGS = { img = true, source = true, br = true, hr = true }
local BLOCK_TAGS = {
    p = true,
    div = true,
    tr = true,
    li = true,
    summary = true,
    h1 = true,
    h2 = true,
    h3 = true,
    h4 = true,
    h5 = true,
    h6 = true,
    blockquote = true,
    figcaption = true,
    section = true,
    article = true,
    header = true,
    footer = true,
    table = true,
    thead = true,
    tbody = true,
    ul = true,
    ol = true,
    details = true,
    figure = true,
    center = true,
}

local function code_point_to_char(code, fallback)
    if not code or code < 0 or code > 0x10FFFF then
        return fallback
    end
    local ok, character = pcall(utf8.char, code)
    return ok and character or fallback
end

--- Decodes the named and numeric entities GitHub leaves in comment text.
function M.decode_entities(text)
    local decoded = tostring(text or ""):gsub("&#x(%x+);", function(hex)
        return code_point_to_char(tonumber(hex, 16), "&#x" .. hex .. ";")
    end)
    decoded = decoded:gsub("&#(%d+);", function(digits)
        return code_point_to_char(tonumber(digits), "&#" .. digits .. ";")
    end)
    return (decoded:gsub("&(%a+);", function(name)
        return NAMED_ENTITIES[name] or ("&" .. name .. ";")
    end))
end

local function read_attribute_value(source, index)
    local quote = source:sub(index, index)
    if quote == '"' or quote == "'" then
        local close_at = source:find(quote, index + 1, true)
        if not close_at then
            return source:sub(index + 1), #source + 1
        end
        return source:sub(index + 1, close_at - 1), close_at + 1
    end
    local value = source:match("^[^%s/]+", index) or ""
    return value, index + #value
end

local function attribute_value(attrs, wanted)
    local index = 1
    local source = attrs or ""
    while index <= #source do
        local start_name, end_name, name = source:find("([%a_:][%w%-%.:]*)", index)
        if not start_name then
            return nil
        end
        index = end_name + 1
        local separator = source:match("^%s*=%s*", index)
        if not separator then
            if name:lower() == wanted then
                return ""
            end
        else
            index = index + #separator
            local value, next_index = read_attribute_value(source, index)
            if name:lower() == wanted then
                return M.decode_entities(value)
            end
            index = next_index
        end
    end
    return nil
end

local function clean_label(text)
    return (tostring(text or ""):gsub("[%[%]\r\n]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function filename_from_url(url)
    local path = tostring(url or ""):gsub("%?.*", ""):gsub("#.*", "")
    local name = path:match("([^/]+)$") or ""
    if name == "" or name == "." then
        return ""
    end
    return name
end

local function image_placeholder(attrs)
    local alt = attribute_value(attrs, "alt")
    if alt and alt ~= "" then
        return "*[" .. clean_label(alt) .. "]*"
    end
    local filename = filename_from_url(attribute_value(attrs, "src") or "")
    if filename == "" then
        return "*[image]*"
    end
    return "*[image: " .. filename .. "]*"
end

local function render_anchor(attrs, inner)
    local href = attribute_value(attrs, "href") or ""
    local compact = vim.trim(tostring(inner or "")):gsub("%s+", " ")
    local image_label = compact:match("^%*%[(.*)%]%*$")
    local text = image_label and clean_label(image_label) or clean_label(inner)
    if href == "" then
        return text
    end
    if text == "" then
        text = href
    end
    return "[" .. text .. "](" .. href:gsub("[%s\r\n]", "") .. ")"
end

local function wrap_marker(inner, marker)
    if vim.trim(inner) == "" then
        return ""
    end
    return marker .. inner .. marker
end

local function render_code(inner)
    if inner:find("\n", 1, true) or inner:find("`", 1, true) then
        return inner
    end
    return "`" .. inner .. "`"
end

local function render_void(name, attrs)
    if name == "img" then
        return image_placeholder(attrs)
    end
    if name == "br" then
        return "\n"
    end
    if name == "hr" then
        return "\n---\n"
    end
    return ""
end

local function render_media(name, inner)
    local label = vim.trim(inner)
    if label ~= "" then
        return label
    end
    return "*[" .. name .. "]*"
end

local function render_paired(name, attrs, inner)
    if name == "a" then
        return render_anchor(attrs, inner)
    end
    if name == "strong" or name == "b" then
        return wrap_marker(inner, "**")
    end
    if name == "em" or name == "i" then
        return wrap_marker(inner, "*")
    end
    if name == "code" or name == "kbd" then
        return render_code(inner)
    end
    if name == "pre" then
        return "\n" .. inner .. "\n"
    end
    if name == "del" or name == "s" then
        return wrap_marker(inner, "~~")
    end
    if name == "td" or name == "th" then
        return inner .. " "
    end
    if name == "video" or name == "audio" or name == "iframe" or name == "svg" then
        return render_media(name, inner)
    end
    if BLOCK_TAGS[name] then
        return "\n" .. inner .. "\n"
    end
    return inner
end

local function replace_void_tags(text)
    local changed = false
    local updated = text:gsub("(<([%a][%w-]*)([^<>]-)%s*/?>)", function(full, name, attrs)
        if not VOID_TAGS[name:lower()] then
            return full
        end
        changed = true
        return render_void(name:lower(), attrs)
    end)
    return updated, changed
end

local function replace_paired_tags(text)
    local changed = false
    local updated = text:gsub("<([%a][%w-]*)([^<>]-)%s*>([^<]-)</%1>", function(name, attrs, inner)
        changed = true
        return render_paired(name:lower(), attrs, inner)
    end)
    return updated, changed
end

local function stash_region(slots, chunk)
    slots[#slots + 1] = chunk
    return "\1" .. tostring(#slots) .. "\1"
end

local function next_code_span(text, index)
    local fence = text:find("```", index, true)
    local tick = text:find("`", index, true)
    if fence and (not tick or fence <= tick) then
        return fence, "fence"
    end
    if tick then
        return tick, "tick"
    end
    return nil, nil
end

local function consume_code_span(text, kind, start_at, slots)
    if kind == "fence" then
        local close_at = text:find("```", start_at + 3, true)
        if not close_at then
            return stash_region(slots, text:sub(start_at)), nil
        end
        return stash_region(slots, text:sub(start_at, close_at + 2)), close_at + 3
    end
    local close_at = text:find("`", start_at + 1, true)
    local newline = text:find("\n", start_at + 1, true)
    if close_at and (not newline or close_at < newline) then
        return stash_region(slots, text:sub(start_at, close_at)), close_at + 1
    end
    return "`", start_at + 1
end

local function protect_regions(text)
    local slots = {}
    local parts = {}
    local index = 1
    while index <= #text do
        local next_at, kind = next_code_span(text, index)
        if not next_at then
            parts[#parts + 1] = text:sub(index)
            break
        end
        if next_at > index then
            parts[#parts + 1] = text:sub(index, next_at - 1)
        end
        local piece, next_index = consume_code_span(text, kind, next_at, slots)
        parts[#parts + 1] = piece
        if not next_index then
            break
        end
        index = next_index
    end
    return table.concat(parts), slots
end

local function restore_regions(text, slots)
    return (text:gsub("\1(%d+)\1", function(number)
        return slots[tonumber(number)] or ""
    end))
end

local function strip_comments(text)
    local parts = {}
    local index = 1
    while true do
        local start_at = text:find("<!--", index, true)
        if not start_at then
            parts[#parts + 1] = text:sub(index)
            break
        end
        if start_at > index then
            parts[#parts + 1] = text:sub(index, start_at - 1)
        end
        local close_at = text:find("-->", start_at + 4, true)
        if not close_at then
            break
        end
        index = close_at + 3
    end
    return table.concat(parts)
end

local function convert_markup(text)
    local current = strip_comments(text)
    for _ = 1, 40 do
        local without_void, void_changed = replace_void_tags(current)
        local without_paired, paired_changed = replace_paired_tags(without_void)
        current = without_paired
        if not void_changed and not paired_changed then
            break
        end
    end
    return (current:gsub("!%[(.-)%]%(([^%)]+)%)", function(alt, url)
        if alt ~= "" then
            return "*[" .. clean_label(alt) .. "]*"
        end
        local filename = filename_from_url(url)
        if filename == "" then
            return "*[image]*"
        end
        return "*[image: " .. filename .. "]*"
    end))
end

--- Turns `body` into plain text with Markdown links and italic image labels.
function M.render_body(body)
    local source = tostring(body or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    local protected, slots = protect_regions(source)
    local converted = M.decode_entities(convert_markup(protected))
    converted = converted:gsub("[ \t]+\n", "\n"):gsub("\n\n\n+", "\n\n")
    converted = converted:gsub("^%s+", ""):gsub("%s+$", "")
    return restore_regions(converted, slots)
end

local function pad_display(text, width)
    local gap = width - vim.fn.strdisplaywidth(text)
    if gap <= 0 then
        return text
    end
    return text .. string.rep(" ", gap)
end

local function append_segment_rows(rows, segment, inner)
    local body = tostring(segment.text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if segment.group == nil and vim.trim(body) == "" then
        return
    end
    for line in (body .. "\n"):gmatch("(.-)\n") do
        local pieces = { line }
        if line ~= "" and vim.fn.strdisplaywidth(line) > inner then
            pieces = wrap_text(line, inner)
        end
        for _, piece in ipairs(pieces) do
            rows[#rows + 1] = { text = piece, group = segment.group }
        end
    end
end

--- Draws `segments` (`{ text, group }`) inside an ASCII box.
--- `total_width` is the window width and `indent` is the reply indent.
function M.build_box_lines(segments, total_width, indent)
    local pad = math.max(0, math.floor(tonumber(indent) or 0))
    local limit = math.max(pad + 12, math.floor(tonumber(total_width) or 72))
    local inner = math.max(8, limit - pad - 2)
    local prefix = string.rep(" ", pad)
    local rows = {}
    for _, segment in ipairs(segments or {}) do
        append_segment_rows(rows, segment, inner)
    end
    if #rows == 0 then
        rows[1] = { text = "", group = nil }
    end
    local lines = { { text = prefix .. " " .. string.rep("_", inner) .. " ", group = "JprMuted" } }
    for _, row in ipairs(rows) do
        lines[#lines + 1] = { text = prefix .. "|" .. pad_display(row.text, inner) .. "|", group = row.group }
    end
    lines[#lines + 1] = { text = prefix .. "|" .. string.rep("_", inner) .. "|", group = "JprMuted" }
    return lines
end

return M
