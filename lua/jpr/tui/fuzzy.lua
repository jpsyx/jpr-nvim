-- Pure deterministic subsequence fuzzy matcher for command palette filtering.
local M = {}

local BASE_MATCH_SCORE = 10
local CONSECUTIVE_BONUS = 15
local START_OF_TEXT_BONUS = 20
local WORD_BOUNDARY_BONUS = 12
local EXACT_ID_BONUS = 100

local function is_word_separator(byte_value)
    return byte_value == 32 or byte_value == 45 or byte_value == 95 or byte_value == 47
end

local function is_blank(text)
    return type(text) ~= "string" or text:match("%S") == nil
end

local function find_byte_index(haystack, target_byte, start_index, haystack_len)
    for candidate_index = start_index, haystack_len do
        if haystack:byte(candidate_index) == target_byte then
            return candidate_index
        end
    end
    return nil
end

local function compute_char_score(haystack, matched_index, previous_match_index)
    local delta = BASE_MATCH_SCORE
    if matched_index == 1 then
        return delta + START_OF_TEXT_BONUS
    end
    if previous_match_index ~= nil and matched_index == previous_match_index + 1 then
        return delta + CONSECUTIVE_BONUS
    end
    if is_word_separator(haystack:byte(matched_index - 1)) then
        delta = delta + WORD_BOUNDARY_BONUS
    end
    if previous_match_index ~= nil then
        delta = delta - (matched_index - previous_match_index - 1)
    end
    return delta
end

--- Scores how well `query` matches `candidate` as a case-insensitive subsequence.
--- Returns a positive integer score when matched, or `nil` when not matched.
--- @param query string|nil
--- @param candidate string|nil
--- @return integer|nil
function M.score_match(query, candidate)
    if is_blank(query) then
        return 0
    end
    if type(candidate) ~= "string" or candidate == "" then
        return nil
    end

    local needle = string.lower(query)
    local haystack = string.lower(candidate)
    local needle_len = #needle
    local haystack_len = #haystack
    if needle_len > haystack_len then
        return nil
    end

    local total_score = 0
    local search_start = 1
    local previous_match_index = nil

    for query_index = 1, needle_len do
        local matched_index = find_byte_index(haystack, needle:byte(query_index), search_start, haystack_len)
        if matched_index == nil then
            return nil
        end
        total_score = total_score + compute_char_score(haystack, matched_index, previous_match_index)
        previous_match_index = matched_index
        search_start = matched_index + 1
    end

    return math.max(1, total_score)
end

local function score_command(command, normalized_query)
    local label_score = M.score_match(normalized_query, command.label)
    local id_score = M.score_match(normalized_query, command.id)
    if id_score ~= nil and type(command.id) == "string" and string.lower(command.id) == normalized_query then
        id_score = id_score + EXACT_ID_BONUS
    end
    if label_score == nil then
        return id_score
    end
    if id_score == nil then
        return label_score
    end
    return math.max(label_score, id_score)
end

--- Filters and ranks `commands` against `query` by label and id.
--- Empty or whitespace-only queries return all commands in original schema order.
--- @param commands table[]
--- @param query string|nil
--- @return table[]
function M.filter_commands(commands, query)
    local source = type(commands) == "table" and commands or {}
    if is_blank(query) then
        local copy = {}
        for index, command in ipairs(source) do
            copy[index] = command
        end
        return copy
    end

    local normalized_query = string.lower(vim.trim(query))
    local scored = {}
    for index, command in ipairs(source) do
        local match_score = score_command(command, normalized_query)
        if match_score ~= nil then
            scored[#scored + 1] = {
                command = command,
                score = match_score,
                original_index = index,
            }
        end
    end

    table.sort(scored, function(left, right)
        if left.score ~= right.score then
            return left.score > right.score
        end
        return left.original_index < right.original_index
    end)

    local filtered = {}
    for index, entry in ipairs(scored) do
        filtered[index] = entry.command
    end
    return filtered
end

return M
