-- expand grows the selection to the next enclosing piece of syntax. shrink
-- goes back one step (i wanted this option for my life too). with a
-- tree-sitter parser, the steps are syntax nodes, plus the word, the inside
-- of quotes and the inside of brackets. without a parser: word, quoted text,
-- inside of brackets, brackets, line, paragraph, whole document. basically we
-- keep taking more until nothing is left.
--
-- ranges are { start_line, start_col, end_line, end_col }: lines 1-based,
-- columns 0-based bytes, end exclusive, as helpers.get_selection returns.

local syntax_selection = {}
local api = vim.api
local helpers = require('notebashpp.helpers')

-- how far bracket matching looks above & below the selection. hope has
-- limits.
local BRACKET_SEARCH_LINES = 2000
local BRACKET_PAIRS = { { '(', ')' }, { '[', ']' }, { '{', '}' } }
local QUOTE_CHARACTERS = { '"', "'", '`' }

-- what the last expand did: its buffer & change number, the selected range
-- and the previous ranges, newest last. buffer 0 means nothing was expanded
-- yet. i keep records of failure now. very professional.
local expansion_state = { buffer = 0, change_tick = -1, history = {}, current = {} }

local function new_range(start_line, start_col, end_line, end_col)
    return { start_line = start_line, start_col = start_col, end_line = end_line, end_col = end_col }
end

local function ranges_equal(first_range, second_range)
    return first_range.start_line == second_range.start_line
        and first_range.start_col == second_range.start_col
        and first_range.end_line == second_range.end_line
        and first_range.end_col == second_range.end_col
end

local function byte_offset(line_number, column)
    return api.nvim_buf_get_offset(0, line_number - 1) + column
end

local function range_size(range)
    return byte_offset(range.end_line, range.end_col) - byte_offset(range.start_line, range.start_col)
end

local function contains(outer_range, inner_range)
    return byte_offset(outer_range.start_line, outer_range.start_col) <= byte_offset(inner_range.start_line, inner_range.start_col)
        and byte_offset(outer_range.end_line, outer_range.end_col) >= byte_offset(inner_range.end_line, inner_range.end_col)
end

-- keep the range inside the document. tree-sitter ends a block at column 0 of
-- a later line; move that end to the previous line's end so we don't swallow
-- the next line break. even this shit needs boundaries.
local function normalized(range)
    local last_line = helpers.count_lines()
    local result = vim.deepcopy(range)
    if result.end_line > last_line then
        result.end_line, result.end_col = last_line, #helpers.get_line_text(last_line)
    end
    if result.end_col == 0 and result.end_line > result.start_line then
        result.end_line = result.end_line - 1
        result.end_col = #helpers.get_line_text(result.end_line)
    end
    result.start_col = math.min(result.start_col, #helpers.get_line_text(result.start_line))
    result.end_col = math.min(result.end_col, #helpers.get_line_text(result.end_line))
    return result
end

------------------------------------------------------------- candidates

local function is_word_character(character)
    return character ~= '' and (character:match('[%w_]') ~= nil or character:byte() >= 128)
end

-- the word around a single-line range. my ambitions have shrunk.
local function word_candidate(range, candidates)
    if range.start_line ~= range.end_line then
        return
    end
    local line_text = helpers.get_line_text(range.start_line)
    local word_start, word_end = range.start_col, range.end_col
    while word_start > 0 and is_word_character(line_text:sub(word_start, word_start)) do
        word_start = word_start - 1
    end
    while word_end < #line_text and is_word_character(line_text:sub(word_end + 1, word_end + 1)) do
        word_end = word_end + 1
    end
    candidates[#candidates + 1] = new_range(range.start_line, word_start, range.start_line, word_end)
end

-- quoted text on the range's line: inside first, then quotes included. pair
-- quotes from the line start; a backslash escapes the next character. (i'd
-- love an escape that cheap.)
local function quote_candidates(range, candidates)
    if range.start_line ~= range.end_line then
        return
    end
    local line_text = helpers.get_line_text(range.start_line)
    for _, quote_character in ipairs(QUOTE_CHARACTERS) do
        local quote_columns = {}
        local index = 1
        while index <= #line_text do
            local character = line_text:sub(index, index)
            if character == '\\' then
                index = index + 1
            elseif character == quote_character then
                quote_columns[#quote_columns + 1] = index - 1
            end
            index = index + 1
        end
        for pair_index = 1, #quote_columns - 1, 2 do
            local open_column, close_column = quote_columns[pair_index], quote_columns[pair_index + 1]
            candidates[#candidates + 1] = new_range(range.start_line, open_column + 1, range.start_line, close_column)
            candidates[#candidates + 1] = new_range(range.start_line, open_column, range.start_line, close_column + 1)
        end
    end
end

-- innermost bracket pair of each kind around the range: inside & full pair.
-- search at most bracket_search_lines lines each way. i won't die looking.
local function bracket_candidates(range, candidates)
    local first_line = math.max(1, range.start_line - BRACKET_SEARCH_LINES)
    local last_line = math.min(helpers.count_lines(), range.end_line + BRACKET_SEARCH_LINES)
    local lines = helpers.get_lines_text(first_line, last_line)
    local text = table.concat(lines, '\n')
    -- each line's first-character index in text. accounting for crap.
    local line_starts = {}
    local next_start = 1
    for line_index, line_text in ipairs(lines) do
        line_starts[line_index] = next_start
        next_start = next_start + #line_text + 1
    end
    local function index_of(line_number, column)
        return line_starts[line_number - first_line + 1] + column
    end
    local function position_of(index)
        local line_index = #line_starts
        while line_index > 1 and line_starts[line_index] > index do
            line_index = line_index - 1
        end
        return first_line + line_index - 1, index - line_starts[line_index]
    end
    local range_start, range_end = index_of(range.start_line, range.start_col), index_of(range.end_line, range.end_col)
    for _, bracket_pair in ipairs(BRACKET_PAIRS) do
        local opening, closing = bracket_pair[1], bracket_pair[2]
        local search_from = range_start - 1
        while search_from >= 1 do
            -- nearest unmatched opening bracket before search_from. lonely
            -- bastard.
            local depth, opening_index = 0, nil
            for index = search_from, 1, -1 do
                local character = text:sub(index, index)
                if character == closing then
                    depth = depth + 1
                elseif character == opening then
                    if depth == 0 then
                        opening_index = index
                        break
                    end
                    depth = depth - 1
                end
            end
            if not opening_index then
                break
            end
            local closing_index = nil
            depth = 0
            for index = opening_index + 1, #text do
                local character = text:sub(index, index)
                if character == opening then
                    depth = depth + 1
                elseif character == closing then
                    if depth == 0 then
                        closing_index = index
                        break
                    end
                    depth = depth - 1
                end
            end
            if closing_index and closing_index >= range_end then
                local open_line, open_column = position_of(opening_index)
                local close_line, close_column = position_of(closing_index)
                candidates[#candidates + 1] = new_range(open_line, open_column + 1, close_line, close_column)
                candidates[#candidates + 1] = new_range(open_line, open_column, close_line, close_column + 1)
                break
            end
            search_from = opening_index - 1
        end
    end
end

local function line_candidate(range, candidates)
    candidates[#candidates + 1] = new_range(range.start_line, 0, range.end_line, #helpers.get_line_text(range.end_line))
end

-- the run of non-blank lines around the range. crap accumulates.
local function paragraph_candidate(range, candidates)
    local first_line, last_line = range.start_line, range.end_line
    while first_line > 1 and helpers.get_line_text(first_line - 1):match('%S') do
        first_line = first_line - 1
    end
    while last_line < helpers.count_lines() and helpers.get_line_text(last_line + 1):match('%S') do
        last_line = last_line + 1
    end
    candidates[#candidates + 1] = new_range(first_line, 0, last_line, #helpers.get_line_text(last_line))
end

local function document_candidate(candidates)
    local last_line = helpers.count_lines()
    candidates[#candidates + 1] = new_range(1, 0, last_line, #helpers.get_line_text(last_line))
end

-- return the document's tree-sitter parser, parsed, or nil if absent. get the
-- language from the filetype every time: neovim keeps the old buffer parser
-- after the filetype is cleared. i also retain useless parts of my past, but
-- nobody calls that a feature.
local function parser_for_buffer()
    local filetype = vim.bo.filetype
    local language = filetype ~= '' and vim.treesitter.language.get_lang(filetype) or nil
    if not language then
        return nil
    end
    local found, parser = pcall(vim.treesitter.get_parser, api.nvim_get_current_buf(), language, { error = false })
    if not found or not parser then
        return nil
    end
    local parsed = pcall(function()
        parser:parse(true)
    end)
    return parsed and parser or nil
end

-- every named syntax node around the range, from the innermost language (say,
-- markdown inline text) through its enclosing languages. even text has layers
-- of regret.
local function syntax_node_candidates(parser, range, candidates)
    local node_range = { range.start_line - 1, range.start_col, range.end_line - 1, range.end_col }
    local language_tree = parser:language_for_range(node_range)
    while language_tree do
        local node = language_tree:named_node_for_range(node_range, { ignore_injections = true })
        local outermost_node = nil
        while node do
            local start_row, start_col, end_row, end_col = node:range()
            candidates[#candidates + 1] = new_range(start_row + 1, start_col, end_row + 1, end_col)
            outermost_node = node
            node = node:parent()
        end
        if outermost_node then
            node_range = { outermost_node:range() }
        end
        language_tree = language_tree:parent()
    end
end

-- smallest candidate containing the range, strictly bigger. inflation wins
-- again.
local function next_larger_range(range)
    local candidates = {}
    word_candidate(range, candidates)
    quote_candidates(range, candidates)
    bracket_candidates(range, candidates)
    local parser = parser_for_buffer()
    if parser then
        syntax_node_candidates(parser, range, candidates)
    else
        line_candidate(range, candidates)
        paragraph_candidate(range, candidates)
    end
    document_candidate(candidates)
    local best_range, best_size = nil, math.huge
    local current_size = range_size(range)
    for _, candidate in ipairs(candidates) do
        candidate = normalized(candidate)
        local candidate_size = range_size(candidate)
        if candidate_size > current_size and candidate_size < best_size and contains(candidate, range) then
            best_range, best_size = candidate, candidate_size
        end
    end
    return best_range
end

------------------------------------------------------------- commands

-- the selection, or an empty range at the caret. i have nothing.
local function current_range()
    local selection = helpers.get_selection()
    if selection then
        return normalized(new_range(selection.start_line, selection.start_col, selection.end_line, selection.end_col))
    end
    local caret = helpers.get_caret()
    return new_range(caret[1], caret[2], caret[1], caret[2])
end

local function show_range(range)
    require('notebashpp.column_mode').clear()
    if range.start_line == range.end_line and range.start_col == range.end_col then
        helpers.move_caret_to({ range.start_line, range.start_col })
    else
        helpers.select_range({ range.start_line, range.start_col }, { range.end_line, range.end_col })
    end
end

-- state still applies if nothing was edited and the selection matches the
-- last step. if another press arrives before that step's selection keys run,
-- it still sees the range from before the step. basically i have to remember
-- the past because the present is late. (absolutely familiar.)
local function state_still_applies(range)
    if expansion_state.buffer ~= api.nvim_get_current_buf() or expansion_state.change_tick ~= api.nvim_buf_get_changedtick(0) then
        return false
    end
    local history = expansion_state.history
    return ranges_equal(range, expansion_state.current) or (history[#history] ~= nil and ranges_equal(range, history[#history]))
end

function syntax_selection.expand()
    local range = current_range()
    if state_still_applies(range) then
        range = expansion_state.current
    else
        expansion_state = { buffer = api.nvim_get_current_buf(), change_tick = -1, history = {}, current = range }
    end
    expansion_state.change_tick = api.nvim_buf_get_changedtick(0)
    local larger_range = next_larger_range(range)
    if not larger_range then
        return
    end
    table.insert(expansion_state.history, range)
    expansion_state.current = larger_range
    show_range(larger_range)
end

function syntax_selection.shrink()
    local range = current_range()
    if not state_still_applies(range) or #expansion_state.history == 0 then
        return
    end
    local smaller_range = table.remove(expansion_state.history)
    expansion_state.current = smaller_range
    show_range(smaller_range)
end

return syntax_selection
