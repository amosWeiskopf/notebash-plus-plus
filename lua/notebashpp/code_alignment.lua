-- line up =, : or any text across lines, like the code alignment plugin (1
-- million downloads. apparently i need company while wasting my life).
--
--     width = 10          width      = 10
--     height_max = 4      height_max = 4
--
-- use the selected lines, or the block around the caret: the lines above and
-- below it that hold the same delimiter. text inside quotes is never a
-- delimiter. i'd love my own boundaries to be this clear.

local code_alignment = {}
local api = vim.api
local helpers = require('notebashpp.helpers')

-- characters before = that make one operator: += -= *= /= %= .= &= |= ^= :=
-- ?= and friends. even this crap has friends.
local COMPOUND_PREFIX = '[%+%-%*/%%%.&|%^:%?~]'

-- 1-based byte position where the delimiter starts in line, or nil. kind is
-- 'equals', 'colon' or plain text to find. basically a search with a very
-- small chance of finding meaning.
local function delimiter_position(line, kind)
    local quote = nil
    local position = 1
    while position <= #line do
        local character = line:sub(position, position)
        if quote then
            if character == '\\' then
                position = position + 1
            elseif character == quote then
                quote = nil
            end
        elseif character == '"' or character == "'" or character == '`' then
            quote = character
        elseif kind == 'equals' and character == '=' then
            local previous, following = line:sub(position - 1, position - 1), line:sub(position + 1, position + 1)
            -- skip comparisons and arrows: == != <= >= => =~ (enough shit
            -- here).
            if following ~= '=' and following ~= '>' and following ~= '~' and previous ~= '=' and previous ~= '!' and previous ~= '<' and previous ~= '>' then
                local start = position
                while start > 1 and line:sub(start - 1, start - 1):match(COMPOUND_PREFIX) do
                    start = start - 1
                end
                return start
            end
        elseif kind == 'colon' and character == ':' then
            if line:sub(position + 1, position + 1) ~= ':' and line:sub(position - 1, position - 1) ~= ':' then
                return position
            end
        elseif kind ~= 'equals' and kind ~= 'colon' and line:sub(position, position + #kind - 1) == kind then
            return position
        end
        position = position + 1
    end
    return nil
end

-- align the selection, or the run of lines around the caret holding the
-- delimiter. i want some order before i die. this will have to do.
local function target_line_range(kind)
    if helpers.get_selection() then
        return helpers.selected_line_range()
    end
    local caret_line = helpers.get_caret()[1]
    local function has_delimiter(line_number)
        return delimiter_position(helpers.get_line_text(line_number), kind) ~= nil
    end
    if not has_delimiter(caret_line) then
        return nil
    end
    local first_line, last_line = caret_line, caret_line
    while first_line > 1 and has_delimiter(first_line - 1) do
        first_line = first_line - 1
    end
    while last_line < helpers.count_lines() and has_delimiter(last_line + 1) do
        last_line = last_line + 1
    end
    return first_line, last_line
end

---@param kind string 'equals', 'colon', or the text to align on
function code_alignment.align(kind)
    local first_line, last_line = target_line_range(kind)
    if not first_line or not last_line then
        return helpers.notify('Nothing to align here.')
    end
    local lines = api.nvim_buf_get_lines(0, first_line - 1, last_line, false)
    -- line up the = signs; compound prefixes (the + of +=) sit left of the
    -- column. even my fucking whitespace needs room for its baggage.
    local split_lines, widest = {}, 0
    for line_index, line in ipairs(lines) do
        local position = delimiter_position(line, kind)
        if position then
            local left_part = line:sub(1, position - 1):gsub('%s+$', '')
            local right_part = line:sub(position)
            local prefix_width = kind == 'equals' and #(right_part:match('^(.-)=') or '') or 0
            split_lines[line_index] = { left = left_part, right = right_part, prefix_width = prefix_width }
            widest = math.max(widest, vim.fn.strdisplaywidth(left_part) + prefix_width)
        end
    end
    for line_index, parts in pairs(split_lines) do
        local padding = widest - vim.fn.strdisplaywidth(parts.left) - parts.prefix_width + 1
        lines[line_index] = parts.left .. string.rep(' ', padding) .. parts.right
    end
    api.nvim_buf_set_lines(0, first_line - 1, last_line, false, lines)
end

function code_alignment.align_by_text()
    local delimiter = helpers.ask('Align by text: ')
    if delimiter ~= '' then
        code_alignment.align(delimiter)
    end
end

return code_alignment
