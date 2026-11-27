-- Pure progress bar and filter-pill rendering helpers for the PR sidebar panel.
local M = {}

local DEFAULT_PROGRESS_BAR_WIDTH = 16
local PROGRESS_FILLED_CELL = "█"
local PROGRESS_UNFILLED_CELL = "░"
local FILTER_PREFIX = "filter: "
local FILTER_ALL_PILL = "[u] all files"
local FILTER_UNVIEWED_PILL = "[u] unviewed only"

--- Creates visual progress bar text and byte-range metadata for reviewed or
--- processed counts, used by the PR sidebar panel and the live loading view.
--- @param viewed_count integer|nil
--- @param total_count integer|nil
--- @param bar_width integer|nil
--- @param unit_label string|nil Optional unit noun placed after the ratio (for example `"files"`).
--- @return table { text: string, filled_bytes: integer, unfilled_bytes: integer, counter_start: integer, is_complete: boolean }
function M.create_progress_bar_from_counts(viewed_count, total_count, bar_width, unit_label)
    local width = math.max(1, math.floor(tonumber(bar_width) or DEFAULT_PROGRESS_BAR_WIDTH))
    local safe_total = math.max(0, math.floor(tonumber(total_count) or 0))
    local clamped_viewed = math.max(0, math.min(math.floor(tonumber(viewed_count) or 0), safe_total))
    local percent = safe_total > 0 and math.floor((clamped_viewed * 100) / safe_total + 0.5) or 0
    local filled_cells = 0
    if safe_total > 0 then
        if clamped_viewed == safe_total then
            filled_cells = width
        elseif clamped_viewed > 0 then
            filled_cells = math.max(0, math.min(width, math.floor((clamped_viewed * width) / safe_total + 0.5)))
        end
    end
    local filled = PROGRESS_FILLED_CELL:rep(filled_cells)
    local unfilled = PROGRESS_UNFILLED_CELL:rep(width - filled_cells)
    local has_unit_label = type(unit_label) == "string" and unit_label ~= ""
    local counter = has_unit_label
            and ("%d/%d %s (%d%%)"):format(clamped_viewed, safe_total, unit_label, percent)
        or ("%d/%d (%d%%)"):format(clamped_viewed, safe_total, percent)
    local text = filled .. unfilled .. "  " .. counter
    return {
        text = text,
        filled_bytes = #filled,
        unfilled_bytes = #unfilled,
        counter_start = #filled + #unfilled + 2,
        is_complete = safe_total > 0 and clamped_viewed == safe_total,
    }
end

--- Appends the filled, unfilled, and counter highlight spans for `progress_bar`
--- on 0-based `line` starting at `col_offset`. Shared by the panel and loading
--- renderers so both color progress bars identically.
function M.append_progress_bar_highlights(highlights, line, col_offset, progress_bar)
    if progress_bar.filled_bytes > 0 then
        highlights[#highlights + 1] = {
            line = line,
            col_start = col_offset,
            col_end = col_offset + progress_bar.filled_bytes,
            group = "JprViewed",
        }
    end
    if progress_bar.unfilled_bytes > 0 then
        highlights[#highlights + 1] = {
            line = line,
            col_start = col_offset + progress_bar.filled_bytes,
            col_end = col_offset + progress_bar.filled_bytes + progress_bar.unfilled_bytes,
            group = "JprMuted",
        }
    end
    highlights[#highlights + 1] = {
        line = line,
        col_start = col_offset + progress_bar.counter_start,
        col_end = col_offset + #progress_bar.text,
        group = progress_bar.is_complete and "JprViewed" or "JprTitle",
    }
end

--- Appends the clickable unviewed-filter pill line to `content` and returns its 1-based line number.
function M.add_filter_pill_line(content, hide_viewed)
    local pill = hide_viewed and FILTER_UNVIEWED_PILL or FILTER_ALL_PILL
    local text = FILTER_PREFIX .. pill
    content.add_line(text)
    local line_index = #content.lines - 1
    if hide_viewed then
        content.highlights[#content.highlights + 1] = {
            line = line_index,
            col_start = 0,
            col_end = #FILTER_PREFIX,
            group = "JprMuted",
        }
        content.highlights[#content.highlights + 1] = {
            line = line_index,
            col_start = #FILTER_PREFIX,
            col_end = #text,
            group = "JprHunk",
        }
    else
        content.highlights[#content.highlights + 1] = {
            line = line_index,
            col_start = 0,
            col_end = #text,
            group = "JprMuted",
        }
    end
    return #content.lines
end

--- Appends the viewed-progress bar line and its highlights to `content`.
function M.add_progress_bar_line(content, view)
    local files = view.files or {}
    local progress_bar = M.create_progress_bar_from_counts(view.viewedCount or 0, #files)
    content.add_line(progress_bar.text)
    M.append_progress_bar_highlights(content.highlights, #content.lines - 1, 0, progress_bar)
end

return M
