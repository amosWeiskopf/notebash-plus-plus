-- the json tree: json viewer's side panel. json viewer is the most installed
-- notepad++ plugin (8.1 million downloads), so apparently eight million of us
-- need a diagram to understand our own data. i also need a diagram for my
-- life. nobody has made that plugin. plugins > json > show json tree, or
-- ctrl+alt+shift+j, opens the tree of the current json document on the
-- right. enter or a click on a node puts the caret on it. the window bar
-- shows the path of the selected node, users[3].name, and copy json path
-- copies the caret's path.
--
-- vim.json.decode forgets where everything was and doesn't keep key order,
-- so this file has its own tokenizer. it keeps flat arrays instead of a table
-- per node, walks nesting with its own stack (no recursion for somebody's
-- 100,000 brackets to blow up), and runs in slices so a big file doesn't
-- freeze typing. only expanded nodes become panel lines. a collapsed array of
-- 100,000 things is one line. i wish my problems collapsed like that.

local json_tree = {}
local api = vim.api
local helpers = require('notebashpp.helpers')

-- documents: per buffer, the last good tree, the first problem, the change
-- number it was built from, the build in progress and which nodes are open.
-- panel: the open panel, or nil. both live on the module table so a code
-- reload keeps them (live_code_reload.lua copies them over).
json_tree.documents = json_tree.documents or {}
json_tree.panel = json_tree.panel or nil

local PANEL_WIDTH = 40
local DEBOUNCE_MILLISECONDS = 300
-- one slice of tree building, then a breather for the keyboard. typing
-- comes first. i'd love that priority in an open-plan office.
local SLICE_NANOSECONDS = 15 * 1000 * 1000
local PAUSE_BETWEEN_SLICES_MILLISECONDS = 4
local DEFAULT_LIMIT_MEGABYTES = 20
-- positions pack line and byte column into one number: line * 2^26 + column.
-- doubles hold 53 bits, so a 64 mb file fits whichever way its lines are
-- shaped. the limit setting stops there too. even my numbers have a ceiling.
local POSITION_SCALE = 67108864
local LARGEST_LIMIT_MEGABYTES = 64
-- deeper than this, the indent stops growing. 100,000 levels of two spaces
-- each would be 200 kb of nothing per line. i already have plenty of nothing.
local DEEPEST_INDENT = 40

local KIND_OBJECT, KIND_ARRAY, KIND_STRING, KIND_NUMBER, KIND_TRUE, KIND_FALSE, KIND_NULL = 1, 2, 3, 4, 5, 6, 7

local QUOTE_BYTE, BACKSLASH_BYTE, SLASH_BYTE, STAR_BYTE = 34, 92, 47, 42
local COMMA_BYTE, COLON_BYTE = 44, 58
local OPEN_BRACE_BYTE, CLOSE_BRACE_BYTE, OPEN_BRACKET_BYTE, CLOSE_BRACKET_BYTE = 123, 125, 91, 93
local MINUS_BYTE, PLUS_BYTE, DOT_BYTE, ZERO_BYTE, ONE_BYTE, NINE_BYTE = 45, 43, 46, 48, 49, 57
local LOWER_E_BYTE, UPPER_E_BYTE, LOWER_U_BYTE = 101, 69, 117
local LOWER_T_BYTE, LOWER_F_BYTE, LOWER_N_BYTE = 116, 102, 110

-- the characters json lets you escape with a backslash, besides \u.
local ESCAPABLE_BYTES = { [34] = true, [92] = true, [47] = true, [98] = true, [102] = true, [110] = true, [114] = true, [116] = true }

-- what the tokenizer is waiting for next. a whole state machine of
-- expectations. i've been one of those since school.
local EXPECT_VALUE = 1
local EXPECT_VALUE_OR_CLOSE = 2
local EXPECT_KEY = 3
local EXPECT_KEY_OR_CLOSE = 4
local EXPECT_COLON = 5
local EXPECT_COMMA_OR_CLOSE = 6
local EXPECT_END = 7

---------------------------------------------------------------- display

-- control characters shown as escapes. a nul byte reaches lua as a newline
-- (that's how neovim stores it in a line), hence \0 for byte 10.
local CONTROL_NAMES = { [8] = '\\b', [9] = '\\t', [10] = '\\0', [12] = '\\f', [13] = '\\r' }

-- length of the utf-8 character starting at `position`, or nil if the bytes
-- there aren't one. overlong forms and surrogates count as broken. strict
-- about other people's bytes, lenient about my own failures. classic.
local function utf8_length(text, position)
    local lead = text:byte(position)
    local length, second_low, second_high
    if lead >= 0xC2 and lead <= 0xDF then
        length, second_low, second_high = 2, 0x80, 0xBF
    elseif lead >= 0xE0 and lead <= 0xEF then
        length = 3
        second_low = lead == 0xE0 and 0xA0 or 0x80
        second_high = lead == 0xED and 0x9F or 0xBF
    elseif lead >= 0xF0 and lead <= 0xF4 then
        length = 4
        second_low = lead == 0xF0 and 0x90 or 0x80
        second_high = lead == 0xF4 and 0x8F or 0xBF
    else
        return nil
    end
    local second = text:byte(position + 1)
    if not second or second < second_low or second > second_high then
        return nil
    end
    for offset = 2, length - 1 do
        local continuation = text:byte(position + offset)
        if not continuation or continuation < 0x80 or continuation > 0xBF then
            return nil
        end
    end
    return length
end

-- text that is safe in a panel line: control characters and broken utf-8 as
-- escapes, at most `cell_budget` screen cells, "..." when cut. `more` says
-- the caller already cut the text short. only the first few hundred bytes
-- are ever looked at, so a 10 mb string costs as much as a short one. i
-- wish the same discount applied to long meetings.
local function sanitize(raw, cell_budget, more)
    cell_budget = math.max(4, cell_budget)
    local byte_budget = cell_budget * 4 + 16
    if #raw > byte_budget then
        raw = raw:sub(1, byte_budget)
        more = true
    end
    local pieces, cells = {}, 0
    local last_fitting_piece, last_fitting_cells = 0, 0
    local position, length = 1, #raw
    local overflowed = false
    while position <= length do
        local byte = raw:byte(position)
        local piece, piece_bytes, piece_cells
        if byte >= 0x20 and byte < 0x7F then
            piece, piece_bytes, piece_cells = string.char(byte), 1, 1
        elseif byte < 0x20 or byte == 0x7F then
            piece = CONTROL_NAMES[byte] or ('\\x%02x'):format(byte)
            piece_bytes, piece_cells = 1, #piece
        else
            local character_length = utf8_length(raw, position)
            if character_length then
                piece = raw:sub(position, position + character_length - 1)
                piece_bytes, piece_cells = character_length, vim.fn.strdisplaywidth(piece)
            else
                piece = ('\\x%02x'):format(byte)
                piece_bytes, piece_cells = 1, 4
            end
        end
        if cells + piece_cells > cell_budget then
            overflowed = true
            break
        end
        pieces[#pieces + 1] = piece
        cells = cells + piece_cells
        if cells <= cell_budget - 3 then
            last_fitting_piece, last_fitting_cells = #pieces, cells
        end
        position = position + piece_bytes
    end
    if overflowed or more then
        if not overflowed and cells + 3 <= cell_budget then
            return table.concat(pieces) .. '...', cells + 3
        end
        return table.concat(pieces, '', 1, last_fitting_piece) .. '...', last_fitting_cells + 3
    end
    return table.concat(pieces), cells
end

-- word-wrap a message to the panel width, with the tree's one-space
-- margin. the panel doesn't wrap by itself, because wrapped tree lines look
-- like a ransom note.
local function wrapped_lines(text, width)
    local lines, current = {}, ''
    for word in text:gmatch('%S+') do
        if current ~= '' and vim.fn.strdisplaywidth(current .. ' ' .. word) > width - 2 then
            lines[#lines + 1] = ' ' .. current
            current = word
        else
            current = current == '' and word or (current .. ' ' .. word)
        end
    end
    if current ~= '' then
        lines[#lines + 1] = ' ' .. current
    end
    return lines
end

---------------------------------------------------------------- tokenizer

-- column of the closing quote of the string starting at `column`, or nil,
-- the column of the problem and what it is. json strings never span lines,
-- so one line is all we need. `pause` lets a 10 mb string of escapes give
-- the keyboard a turn halfway through.
local function string_end(text, column, pause)
    local position = column + 1
    local steps = 0
    while true do
        local special = text:find('["\\%z\1-\31]', position)
        if not special then
            return nil, column, 'this string is not closed on its line'
        end
        local byte = text:byte(special)
        if byte == QUOTE_BYTE then
            return special
        end
        if byte ~= BACKSLASH_BYTE then
            return nil, special, 'a control character inside a string (write it as an escape such as \\t)'
        end
        local escaped = text:byte(special + 1)
        if escaped == LOWER_U_BYTE then
            if not text:find('^%x%x%x%x', special + 2) then
                return nil, special, 'a \\u escape needs four hex digits'
            end
            position = special + 6
        elseif escaped and ESCAPABLE_BYTES[escaped] then
            position = special + 2
        else
            return nil, special, 'a backslash that does not start a JSON escape'
        end
        steps = steps + 1
        if pause and steps >= 4096 then
            steps = 0
            pause()
        end
    end
end

-- last column of the json number starting at `column`, or nil if it isn't
-- one. json is fussy: no leading zeros, no lone dot, no plus sign up front.
-- my bank is less fussy about what it calls a number.
local function number_end(text, column)
    local position = column
    if text:byte(position) == MINUS_BYTE then
        position = position + 1
    end
    local first = text:byte(position)
    if first == ZERO_BYTE then
        position = position + 1
    elseif first and first >= ONE_BYTE and first <= NINE_BYTE then
        position = text:find('[^0-9]', position + 1) or (#text + 1)
    else
        return nil
    end
    if text:byte(position) == DOT_BYTE then
        local after = text:find('[^0-9]', position + 1) or (#text + 1)
        if after == position + 1 then
            return nil
        end
        position = after
    end
    local exponent = text:byte(position)
    if exponent == LOWER_E_BYTE or exponent == UPPER_E_BYTE then
        position = position + 1
        local sign = text:byte(position)
        if sign == PLUS_BYTE or sign == MINUS_BYTE then
            position = position + 1
        end
        local after = text:find('[^0-9]', position) or (#text + 1)
        if after == position then
            return nil
        end
        position = after
    end
    return position - 1
end

-- what the parser found, in words, for an error message. a 10 mb run of
-- digits gets quoted by its first 24 bytes. nobody needs the rest. i speak
-- from experience as the rest.
local function found_text(text, column)
    local byte = text:byte(column)
    if not byte then
        return 'the end of the line'
    end
    local word_end = select(2, text:find('^[A-Za-z0-9_.+-]+', column))
    if word_end then
        return '"' .. sanitize(text:sub(column, math.min(word_end, column + 24)), 20, word_end > column + 24) .. '"'
    end
    if byte == QUOTE_BYTE then
        return 'a string'
    end
    if byte > 0x20 and byte < 0x7F then
        return '"' .. string.char(byte) .. '"'
    end
    return ('a character JSON does not allow (byte 0x%02x)'):format(byte)
end

local function expected_text(state, container_kind)
    if state == EXPECT_VALUE then
        return 'a value'
    elseif state == EXPECT_VALUE_OR_CLOSE then
        return 'a value or "]"'
    elseif state == EXPECT_KEY then
        return 'a key in double quotes'
    elseif state == EXPECT_KEY_OR_CLOSE then
        return 'a key in double quotes or "}"'
    elseif state == EXPECT_COLON then
        return '":"'
    elseif state == EXPECT_COMMA_OR_CLOSE then
        return container_kind == KIND_OBJECT and '"," or "}"' or '"," or "]"'
    end
    return 'the end of the document'
end

-- parse json text given as lines. returns the tree, or nil and the first
-- problem { line, column, message } (column in bytes, 1-based).
-- options.comments allows // and /* */ comments and trailing commas (jsonc).
-- pause, when given, is called every so often and may yield the coroutine
-- running this. the tree is flat arrays indexed by node number, nodes in
-- document order, node 1 the top value:
--   kind     object, array, string, number, true, false or null (1 to 7)
--   parent   the containing node, 0 for the top value
--   start    packed position of the node's first byte: its key if it has one
--   value    packed position of the value (the opening bracket of a container)
--   finish   packed position of the value's last byte
--   last     the last node inside this one (itself for a scalar)
--   size     how many members or items a container has
--   index    position among its parent's children, from 0
-- one table per node would be prettier and cost three times the memory. i
-- chose ugly and cheap. it's a lifestyle.
function json_tree.parse(lines, options, pause)
    options = options or {}
    local allow_comments = options.comments == true
    local kind, parent, start, value, finish, last, size, index = {}, {}, {}, {}, {}, {}, {}, {}
    local count = 0
    local stack, depth = {}, 0
    local state = EXPECT_VALUE
    local pending_key = nil
    local in_block_comment, comment_line, comment_column = false, 0, 0
    local work = 0

    local function problem(line_number, column, message)
        return nil, { line = line_number, column = column, message = message }
    end

    -- a new node at `position`, owning the key that is waiting for it, if
    -- any, and counted in its parent. scalars bring their last byte along;
    -- a container gets its own when it closes. everybody gets a number.
    -- it's like the post office.
    local function add_node(node_kind, position, finish_position)
        count = count + 1
        local owner = stack[depth]
        kind[count] = node_kind
        parent[count] = owner or 0
        start[count] = pending_key or position
        value[count] = position
        size[count] = 0
        if owner then
            index[count] = size[owner]
            size[owner] = size[owner] + 1
        else
            index[count] = 0
        end
        pending_key = nil
        if finish_position then
            finish[count] = finish_position
            last[count] = count
            state = depth == 0 and EXPECT_END or EXPECT_COMMA_OR_CLOSE
        end
        return count
    end

    for line_number = 1, #lines do
        local text = lines[line_number]
        local line_base = line_number * POSITION_SCALE
        local column = 1
        while true do
            work = work + 1
            if pause and work >= 1024 then
                work = 0
                pause()
            end
            if in_block_comment then
                local close_at = text:find('*/', column, true)
                if not close_at then
                    break
                end
                in_block_comment = false
                column = close_at + 2
            end
            column = text:find('[^ \t\r]', column)
            if not column then
                break
            end
            local byte = text:byte(column)
            if byte == SLASH_BYTE then
                if not allow_comments then
                    return problem(line_number, column, 'a comment, and plain JSON has none (set the language to JSONC to allow them)')
                end
                local next_byte = text:byte(column + 1)
                if next_byte == SLASH_BYTE then
                    break
                elseif next_byte == STAR_BYTE then
                    in_block_comment, comment_line, comment_column = true, line_number, column
                    column = column + 2
                else
                    return problem(line_number, column, 'a "/" that does not start a comment')
                end
            elseif byte == OPEN_BRACE_BYTE or byte == OPEN_BRACKET_BYTE then
                if state ~= EXPECT_VALUE and state ~= EXPECT_VALUE_OR_CLOSE then
                    return problem(line_number, column, ('expected %s, found %s'):format(expected_text(state, kind[stack[depth]]), found_text(text, column)))
                end
                local node = add_node(byte == OPEN_BRACE_BYTE and KIND_OBJECT or KIND_ARRAY, line_base + column)
                depth = depth + 1
                stack[depth] = node
                state = byte == OPEN_BRACE_BYTE and EXPECT_KEY_OR_CLOSE or EXPECT_VALUE_OR_CLOSE
                column = column + 1
            elseif byte == CLOSE_BRACE_BYTE or byte == CLOSE_BRACKET_BYTE then
                local owner = stack[depth]
                local closing_kind = byte == CLOSE_BRACE_BYTE and KIND_OBJECT or KIND_ARRAY
                local closes_here = owner ~= nil
                    and kind[owner] == closing_kind
                    and (
                        state == EXPECT_COMMA_OR_CLOSE
                        or (closing_kind == KIND_OBJECT and state == EXPECT_KEY_OR_CLOSE)
                        or (closing_kind == KIND_ARRAY and state == EXPECT_VALUE_OR_CLOSE)
                    )
                if not closes_here then
                    return problem(line_number, column, ('expected %s, found %s'):format(expected_text(state, kind[owner]), found_text(text, column)))
                end
                finish[owner] = line_base + column
                last[owner] = count
                stack[depth] = nil
                depth = depth - 1
                state = depth == 0 and EXPECT_END or EXPECT_COMMA_OR_CLOSE
                column = column + 1
            elseif byte == COMMA_BYTE then
                if state ~= EXPECT_COMMA_OR_CLOSE then
                    return problem(line_number, column, ('expected %s, found ","'):format(expected_text(state, kind[stack[depth]])))
                end
                if kind[stack[depth]] == KIND_OBJECT then
                    state = allow_comments and EXPECT_KEY_OR_CLOSE or EXPECT_KEY
                else
                    state = allow_comments and EXPECT_VALUE_OR_CLOSE or EXPECT_VALUE
                end
                column = column + 1
            elseif byte == COLON_BYTE then
                if state ~= EXPECT_COLON then
                    return problem(line_number, column, ('expected %s, found ":"'):format(expected_text(state, kind[stack[depth]])))
                end
                state = EXPECT_VALUE
                column = column + 1
            elseif byte == QUOTE_BYTE then
                local closing_column, problem_column, message = string_end(text, column, pause)
                if not closing_column then
                    return problem(line_number, problem_column, message)
                end
                if state == EXPECT_KEY or state == EXPECT_KEY_OR_CLOSE then
                    pending_key = line_base + column
                    state = EXPECT_COLON
                elseif state == EXPECT_VALUE or state == EXPECT_VALUE_OR_CLOSE then
                    add_node(KIND_STRING, line_base + column, line_base + closing_column)
                else
                    return problem(line_number, column, ('expected %s, found a string'):format(expected_text(state, kind[stack[depth]])))
                end
                column = closing_column + 1
            else
                local token_kind, token_end
                if byte == LOWER_T_BYTE and text:sub(column, column + 3) == 'true' then
                    token_kind, token_end = KIND_TRUE, column + 3
                elseif byte == LOWER_F_BYTE and text:sub(column, column + 4) == 'false' then
                    token_kind, token_end = KIND_FALSE, column + 4
                elseif byte == LOWER_N_BYTE and text:sub(column, column + 3) == 'null' then
                    token_kind, token_end = KIND_NULL, column + 3
                else
                    token_end = number_end(text, column)
                    token_kind = token_end and KIND_NUMBER
                end
                -- "truex" or "12abc": a value glued to more letters. even
                -- the tokens here have attachment problems.
                if token_end and text:find('^[A-Za-z0-9_.+-]', token_end + 1) then
                    token_end = nil
                end
                if not token_end then
                    local expected = (state == EXPECT_VALUE or state == EXPECT_VALUE_OR_CLOSE) and 'a value' or expected_text(state, kind[stack[depth]])
                    return problem(line_number, column, ('expected %s, found %s'):format(expected, found_text(text, column)))
                end
                if state ~= EXPECT_VALUE and state ~= EXPECT_VALUE_OR_CLOSE then
                    return problem(line_number, column, ('expected %s, found %s'):format(expected_text(state, kind[stack[depth]]), found_text(text, column)))
                end
                add_node(token_kind, line_base + column, line_base + token_end)
                column = token_end + 1
            end
        end
    end
    if in_block_comment then
        return problem(comment_line, comment_column, 'this comment is never closed')
    end
    if depth > 0 then
        local unclosed = stack[depth]
        local position = value[unclosed]
        local bracket = kind[unclosed] == KIND_OBJECT and '{' or '['
        return problem(math.floor(position / POSITION_SCALE), position % POSITION_SCALE, ('this "%s" is never closed'):format(bracket))
    end
    if count == 0 then
        return nil, { message = 'The document is empty.' }
    end
    return {
        lines = lines,
        count = count,
        kind = kind,
        parent = parent,
        start = start,
        value = value,
        finish = finish,
        last = last,
        size = size,
        index = index,
    }
end

---------------------------------------------------------------- tree queries

local function line_of(position)
    return math.floor(position / POSITION_SCALE)
end

local function column_of(position)
    return position % POSITION_SCALE
end

-- the key token of a member, quotes included, as typed in the document.
local function raw_key(tree, node)
    local position = tree.start[node]
    local text = tree.lines[line_of(position)]
    local column = column_of(position)
    return text:sub(column, (string_end(text, column)))
end

-- a child's name inside its parent: its index in an array, its key token in
-- an object. the open/closed memory is keyed by these.
local function component_of(tree, node)
    if tree.kind[tree.parent[node]] == KIND_ARRAY then
        return tree.index[node]
    end
    return raw_key(tree, node)
end

-- the deepest node containing the packed position, or nil outside the top
-- value. binary search for the last node starting at or before it (nodes
-- are in document order), then climb until one still contains it. the
-- caret right after a value still counts as on it, the way people type.
local function node_at(tree, position)
    local start, finish, parent = tree.start, tree.finish, tree.parent
    local low, high, found = 1, tree.count, 0
    while low <= high do
        local middle = math.floor((low + high) / 2)
        if start[middle] <= position then
            found = middle
            low = middle + 1
        else
            high = middle - 1
        end
    end
    local node = found
    while node > 0 and finish[node] + 1 < position do
        node = parent[node]
    end
    return node > 0 and node or nil
end

-- users[3].name: plain identifier keys after a dot, anything else as
-- ["odd key"] with its escapes as typed, array items as [3]. built with one
-- concat, so 100,000 levels cost 100,000 pieces and not a quadratic pile of
-- copies. i've wasted enough of my life on quadratic piles.
function json_tree.path_of(tree, node)
    local pieces = {}
    while node and node > 0 and tree.parent[node] > 0 do
        local owner = tree.parent[node]
        if tree.kind[owner] == KIND_ARRAY then
            pieces[#pieces + 1] = '[' .. tree.index[node] .. ']'
        else
            local key = raw_key(tree, node)
            local key_text = key:sub(2, -2)
            if key_text:find('^[A-Za-z_$][A-Za-z0-9_$]*$') then
                pieces[#pieces + 1] = '.' .. key_text
            else
                pieces[#pieces + 1] = '[' .. key .. ']'
            end
        end
        node = owner
    end
    local count = #pieces
    for position = 1, math.floor(count / 2) do
        pieces[position], pieces[count - position + 1] = pieces[count - position + 1], pieces[position]
    end
    return (table.concat(pieces):gsub('^%.', ''))
end

---------------------------------------------------------------- documents

local function user_limit_bytes()
    local megabytes = tonumber(require('notebashpp.user_settings').get('json_tree_megabytes')) or DEFAULT_LIMIT_MEGABYTES
    return math.max(0, math.min(megabytes, LARGEST_LIMIT_MEGABYTES)) * 1024 * 1024
end

-- comments and trailing commas for jsonc. a language chosen by hand wins
-- over the file name: json means strict json, even in settings.jsonc.
local function is_jsonc(buffer)
    local filetype = vim.bo[buffer].filetype
    if filetype == 'json' or filetype == 'jsonc' then
        return filetype == 'jsonc'
    end
    return api.nvim_buf_get_name(buffer):lower():match('%.jsonc$') ~= nil
end

local function is_json(buffer)
    local filetype = vim.bo[buffer].filetype
    if filetype == 'json' or filetype == 'jsonc' then
        return true
    end
    local name = api.nvim_buf_get_name(buffer):lower()
    return name:match('%.json$') ~= nil or name:match('%.jsonc$') ~= nil
end

local function megabytes_text(bytes)
    return ('%.1f MB'):format(bytes / 1024 / 1024)
end

-- why a buffer gets no tree, as panel text, or nil if it gets one. the large
-- file view only holds what's on screen, so it can't have a tree either.
local function refusal(buffer)
    if not api.nvim_buf_is_valid(buffer) or not is_json(buffer) then
        return 'This document is not JSON. The tree shows .json files and documents whose language is JSON or JSONC.'
    end
    local limit = user_limit_bytes()
    local size
    if vim.b[buffer].notebashpp_special_view == 'large_file_view' then
        local stat = vim.uv.fs_stat(api.nvim_buf_get_name(buffer))
        size = stat and stat.size or (limit + 1)
    elseif vim.b[buffer].notebashpp_special_view then
        return 'This document is not JSON. The tree shows .json files and documents whose language is JSON or JSONC.'
    else
        size = api.nvim_buf_get_offset(buffer, api.nvim_buf_line_count(buffer))
    end
    if size > limit then
        return ('This document is %s, too large for the JSON tree. The limit is %d MB (json_tree_megabytes in user.lua).'):format(
            megabytes_text(size),
            math.floor(limit / 1024 / 1024)
        )
    end
    return nil
end

local function document_for(buffer)
    local document = json_tree.documents[buffer]
    if not document then
        -- the top value starts open, everything under it closed.
        document = { open_nodes = { open = true, children = {} } }
        json_tree.documents[buffer] = document
    end
    return document
end

-- the problem's column the way the status bar counts it: characters, with
-- tabs expanded to the document's tabstop. counted by hand, because
-- strdisplaywidth also counts the 'showbreak' of a wrapped 500 kb line,
-- which moved a column by 50,000. i've been off by more, but not in writing.
local function problem_display_column(buffer, lines, found_problem)
    if not found_problem.line then
        return nil
    end
    local text = lines[found_problem.line] or ''
    local prefix = text:sub(1, math.max(0, found_problem.column - 1))
    if not prefix:find('[\t\128-\255]') then
        return #prefix + 1
    end
    local tabstop = math.max(1, vim.bo[buffer].tabstop)
    local cells = 0
    for segment, tab in prefix:gmatch('([^\t]*)(\t?)') do
        -- one cell per character: count the bytes that start one.
        cells = cells + #segment - select(2, segment:gsub('[\128-\191]', ''))
        if tab ~= '' then
            cells = cells + tabstop - cells % tabstop
        end
    end
    return cells + 1
end

local function finish_build(buffer, document, tick, lines, tree, found_problem)
    document.build = nil
    document.tick = tick
    if tree then
        document.tree = tree
        document.problem = nil
    else
        found_problem.display_column = problem_display_column(buffer, lines, found_problem)
        document.problem = found_problem
    end
end

local function cancel_build(document)
    if document.build then
        document.build.cancelled = true
        document.build = nil
    end
end

-- build the tree in slices of 15 ms. the first slice runs right away, so a
-- small document is done before this returns. `on_done` runs when it is.
local function start_build(buffer, document, on_done)
    cancel_build(document)
    local tick = api.nvim_buf_get_changedtick(buffer)
    local lines = api.nvim_buf_get_lines(buffer, 0, -1, false)
    local options = { comments = is_jsonc(buffer) }
    local build = { tick = tick, deadline = 0 }
    local function pause()
        if vim.uv.hrtime() > build.deadline then
            coroutine.yield()
        end
    end
    build.thread = coroutine.create(function()
        return json_tree.parse(lines, options, pause)
    end)
    document.build = build
    local function step()
        if build.cancelled or not api.nvim_buf_is_valid(buffer) then
            return
        end
        build.deadline = vim.uv.hrtime() + SLICE_NANOSECONDS
        local resumed, tree, found_problem = coroutine.resume(build.thread)
        if not resumed then
            -- a bug of mine, not a problem in the document. say so plainly.
            finish_build(buffer, document, tick, lines, nil, { message = 'The tree could not be built: ' .. tostring(tree) })
        elseif coroutine.status(build.thread) ~= 'dead' then
            vim.defer_fn(step, PAUSE_BETWEEN_SLICES_MILLISECONDS)
            return
        else
            finish_build(buffer, document, tick, lines, tree, found_problem)
        end
        if on_done then
            on_done()
        end
    end
    step()
end

-- the document's tree right now, built without slices if it is out of date.
-- for copy json path with the panel closed, and for tests. nil and a reason
-- if the buffer gets no tree.
local function current_document(buffer)
    local reason = refusal(buffer)
    if reason then
        return nil, reason
    end
    local document = document_for(buffer)
    local tick = api.nvim_buf_get_changedtick(buffer)
    if document.tick ~= tick then
        cancel_build(document)
        local lines = api.nvim_buf_get_lines(buffer, 0, -1, false)
        local tree, found_problem = json_tree.parse(lines, { comments = is_jsonc(buffer) })
        finish_build(buffer, document, tick, lines, tree, found_problem)
        -- that may have replaced the panel's own build, so let the panel
        -- show what this one found.
        local panel = json_tree.panel
        if panel and panel.source_buffer == buffer then
            vim.schedule(function()
                require('notebashpp.json_tree').refresh()
            end)
        end
    end
    return document
end

---------------------------------------------------------------- open nodes

-- the open/closed record for a node: a trie keyed by path components, so it
-- survives a rebuild wherever the path still exists. `create` makes the
-- missing steps. otherwise nil means closed and never touched.
local function open_record(document, tree, node, create)
    local components = {}
    local current = node
    while tree.parent[current] > 0 do
        components[#components + 1] = component_of(tree, current)
        current = tree.parent[current]
    end
    local record = document.open_nodes
    for position = #components, 1, -1 do
        local child = record.children[components[position]]
        if not child then
            if not create then
                return nil
            end
            child = { open = false, children = {} }
            record.children[components[position]] = child
        end
        record = child
    end
    return record
end

-- open every container around `node`. true if anything changed. walks the
-- path once, so 100,000 levels cost 100,000 steps. i've climbed worse ladders
-- to get nowhere.
local function open_ancestors(document, tree, node)
    local components = {}
    local current = node
    while tree.parent[current] > 0 do
        components[#components + 1] = component_of(tree, current)
        current = tree.parent[current]
    end
    local record = document.open_nodes
    local changed = not record.open
    record.open = true
    for position = #components, 2, -1 do
        local child = record.children[components[position]]
        if not child then
            child = { open = false, children = {} }
            record.children[components[position]] = child
        end
        if not child.open then
            child.open = true
            changed = true
        end
        record = child
    end
    return changed
end

---------------------------------------------------------------- panel lines

-- one space of margin, then two per level. the margin lines the tree up
-- with the path in the window bar. i gave a sidebar breathing room. i'd
-- like some.
local INDENTS = {}
local function indent_for(depth)
    local levels = math.min(depth, DEEPEST_INDENT)
    local indent = INDENTS[levels]
    if not indent then
        indent = ' ' .. string.rep('  ', levels)
        INDENTS[levels] = indent
    end
    return indent
end

local VALUE_GROUPS = {
    [KIND_STRING] = 'NotebashJsonTreeString',
    [KIND_NUMBER] = 'NotebashJsonTreeNumber',
    [KIND_TRUE] = 'NotebashJsonTreeLiteral',
    [KIND_FALSE] = 'NotebashJsonTreeLiteral',
    [KIND_NULL] = 'NotebashJsonTreeLiteral',
}

-- one node as a panel line, and where its parts are for the colours:
-- "   - users [12]", "     name: "dana"". label and value are cut to the
-- panel width, so a 10 mb value costs a few hundred bytes of looking.
local function node_line(tree, node, depth, is_open, width, document_name)
    local kind = tree.kind[node]
    local indent = indent_for(depth)
    local is_container = kind == KIND_OBJECT or kind == KIND_ARRAY
    local expander = '  '
    if is_container and tree.size[node] > 0 then
        expander = is_open and '- ' or '+ '
    end
    local text_budget = math.max(16, width - #indent - 3)
    local label
    if node == 1 then
        label = sanitize(document_name, math.floor(text_budget / 2))
    elseif tree.kind[tree.parent[node]] == KIND_ARRAY then
        label = '[' .. tree.index[node] .. ']'
    else
        local key = raw_key(tree, node)
        label = sanitize(key:sub(2, -2), math.floor(text_budget * 2 / 3))
    end
    local before_value = indent .. expander .. label
    local value_text, separator
    if is_container then
        separator = ' '
        value_text = kind == KIND_OBJECT and ('{' .. tree.size[node] .. '}') or ('[' .. tree.size[node] .. ']')
    else
        separator = ': '
        local value_budget = math.max(6, text_budget - vim.fn.strdisplaywidth(label) - 2)
        local position, finish = tree.value[node], tree.finish[node]
        local text = tree.lines[line_of(position)]
        local first_column, last_column = column_of(position), column_of(finish)
        local byte_budget = value_budget * 4 + 16
        if kind == KIND_STRING then
            local inner_last = math.min(last_column - 1, first_column + byte_budget)
            local shown = sanitize(text:sub(first_column + 1, inner_last), value_budget - 2, inner_last < last_column - 1)
            value_text = '"' .. shown .. '"'
        else
            local shown_last = math.min(last_column, first_column + byte_budget)
            value_text = sanitize(text:sub(first_column, shown_last), value_budget, shown_last < last_column)
        end
    end
    local line = before_value .. separator .. value_text
    local meta = {
        node = node,
        expander = #indent,
        label_start = #indent + 2,
        label_end = #before_value,
        value_start = #before_value + #separator,
        value_end = #line,
        value_group = is_container and 'NotebashJsonTreeSize' or VALUE_GROUPS[kind],
        expandable = is_container and tree.size[node] > 0,
        is_open = is_open,
    }
    return line, meta
end

-- the visible nodes, top to bottom, with an explicit stack: open nodes show
-- their children, closed ones don't. the work is the number of lines shown,
-- not the size of the document.
local function tree_panel_lines(document, tree, width, document_name, lines, metas, node_lines)
    local stack_nodes, stack_depths, stack_records = { 1 }, { 0 }, { document.open_nodes }
    local top = 1
    local last, kind = tree.last, tree.kind
    while top > 0 do
        local node, depth, record = stack_nodes[top], stack_depths[top], stack_records[top]
        stack_nodes[top], stack_depths[top], stack_records[top] = nil, nil, nil
        top = top - 1
        local is_container = kind[node] == KIND_OBJECT or kind[node] == KIND_ARRAY
        local is_open = is_container and record ~= nil and record.open == true and tree.size[node] > 0
        local line, meta = node_line(tree, node, depth, is_open, width, document_name)
        lines[#lines + 1] = line
        metas[#lines] = meta
        node_lines[node] = #lines
        if is_open then
            local children = {}
            local child = node + 1
            while child <= last[node] do
                children[#children + 1] = child
                child = last[child] + 1
            end
            for position = #children, 1, -1 do
                local child_node = children[position]
                top = top + 1
                stack_nodes[top] = child_node
                stack_depths[top] = depth + 1
                stack_records[top] = record.children[component_of(tree, child_node)]
            end
        end
    end
end

---------------------------------------------------------------- the panel

local namespace = api.nvim_create_namespace('notebashpp_json_tree')
local augroup_name = 'notebashpp_json_tree'

local function panel_is_valid(panel)
    return panel ~= nil and api.nvim_win_is_valid(panel.window) and api.nvim_buf_is_valid(panel.buffer)
end

function json_tree.is_open()
    return panel_is_valid(json_tree.panel)
end

local function is_floating(window)
    return api.nvim_win_get_config(window).relative ~= ''
end

-- a window showing a document: not floating, not this panel, listed buffer.
local function is_document_window(window)
    local panel = json_tree.panel
    if not api.nvim_win_is_valid(window) or is_floating(window) or (panel and window == panel.window) then
        return false
    end
    return vim.bo[api.nvim_win_get_buf(window)].buflisted
end

local function any_document_window()
    for _, window in ipairs(api.nvim_tabpage_list_wins(0)) do
        if is_document_window(window) then
            return window
        end
    end
end

local function panel_width(panel)
    return api.nvim_win_get_width(panel.window)
end

-- the colours, drawn only for lines on screen by a decoration provider. a
-- 100,000-line tree pays for the forty lines you can see. i'd love to pay
-- only for the days i can see.
api.nvim_set_decoration_provider(namespace, {
    on_win = function(_, _, buffer)
        local panel = json_tree.panel
        return panel ~= nil and buffer == panel.buffer
    end,
    on_line = function(_, _, buffer, row)
        local panel = json_tree.panel
        if not panel or buffer ~= panel.buffer then
            return
        end
        local line_number = row + 1
        local problem_length = panel.problem_lengths and panel.problem_lengths[line_number]
        if problem_length then
            api.nvim_buf_set_extmark(buffer, namespace, row, 0, { end_col = problem_length, hl_group = 'NotebashJsonTreeError', ephemeral = true })
            return
        end
        local meta = panel.line_metas[line_number]
        if not meta then
            return
        end
        if panel.stale then
            api.nvim_buf_set_extmark(buffer, namespace, row, 0, { end_col = meta.value_end, hl_group = 'NotebashJsonTreeStale', ephemeral = true })
            return
        end
        if meta.expandable then
            api.nvim_buf_set_extmark(
                buffer,
                namespace,
                row,
                meta.expander,
                { end_col = meta.expander + 1, hl_group = 'NotebashJsonTreeExpander', ephemeral = true }
            )
        end
        if meta.label_end > meta.label_start then
            api.nvim_buf_set_extmark(buffer, namespace, row, meta.label_start, { end_col = meta.label_end, hl_group = 'NotebashJsonTreeKey', ephemeral = true })
        end
        if meta.value_end > meta.value_start then
            api.nvim_buf_set_extmark(buffer, namespace, row, meta.value_start, { end_col = meta.value_end, hl_group = meta.value_group, ephemeral = true })
        end
    end,
})

-- the window bar: the path of the node under the panel's cursor, which
-- follows the caret. text goes in literally: control characters escaped,
-- every % doubled, so a key called %{system('rm')} stays a key. i've been
-- burned by worse strings than that. mostly from banks.
local function update_header()
    local panel = json_tree.panel
    if not panel_is_valid(panel) then
        return
    end
    local document = json_tree.documents[panel.source_buffer]
    local header = ''
    if panel.message then
        header = 'JSON tree'
    elseif document and document.build and not document.tree then
        header = 'Building the tree...'
    elseif document and document.tree then
        local cursor_line = api.nvim_win_get_cursor(panel.window)[1]
        local meta = panel.line_metas[cursor_line]
        if meta then
            local path = json_tree.path_of(document.tree, meta.node)
            header = path == '' and '(top level)' or path
        end
        if document.build then
            header = 'Updating... ' .. header
        end
    end
    local budget = math.max(8, panel_width(panel) - 2)
    -- a long path shows its end, the part that tells you where you are. the
    -- beginning is always the same. that's also true of my mornings.
    local tail = header:sub(-(budget * 4 + 16)):gsub('^[\128-\191]+', '')
    local shown, cells = sanitize(tail, #tail * 4 + 4)
    if cells > budget then
        shown = '...' .. vim.fn.strcharpart(shown, vim.fn.strchars(shown) - (budget - 3))
    end
    vim.wo[panel.window].winbar = ' ' .. shown:gsub('%%', '%%%%')
end

-- redraw the panel's lines for the source document, keeping its scroll.
local function render()
    local panel = json_tree.panel
    if not panel_is_valid(panel) then
        return
    end
    local width = panel_width(panel)
    panel.rendered_width = width
    local lines, metas, node_lines = {}, {}, {}
    panel.problem_lengths = nil
    panel.stale = false
    local document = json_tree.documents[panel.source_buffer]
    if panel.message then
        vim.list_extend(lines, wrapped_lines(panel.message, width))
    elseif document then
        if document.problem then
            local found_problem = document.problem
            local problem_text = found_problem.message
            if found_problem.line then
                problem_text = ('Line %d, column %d: %s.'):format(
                    found_problem.line,
                    found_problem.display_column or found_problem.column,
                    found_problem.message
                )
            end
            vim.list_extend(lines, wrapped_lines(sanitize(problem_text, 400), width))
            panel.problem_lengths = {}
            for line_number, line in ipairs(lines) do
                panel.problem_lengths[line_number] = #line
            end
            panel.stale = document.tree ~= nil
            if document.tree then
                lines[#lines + 1] = ''
            end
        end
        if document.tree then
            local name = require('notebashpp.document_tabs').name(panel.source_buffer)
            tree_panel_lines(document, document.tree, width, name, lines, metas, node_lines)
        elseif document.build then
            lines[#lines + 1] = 'Building the tree...'
        end
    end
    panel.line_metas = metas
    panel.node_lines = node_lines
    local view = api.nvim_win_call(panel.window, vim.fn.winsaveview)
    vim.bo[panel.buffer].modifiable = true
    api.nvim_buf_set_lines(panel.buffer, 0, -1, false, lines)
    vim.bo[panel.buffer].modifiable = false
    vim.bo[panel.buffer].modified = false
    api.nvim_win_call(panel.window, function()
        vim.fn.winrestview(view)
    end)
    update_header()
end

-- put the panel's cursor on a node's line, or on its nearest visible
-- ancestor's.
local function select_node(node)
    local panel = json_tree.panel
    local document = json_tree.documents[panel.source_buffer]
    local tree = document and document.tree
    if not tree or not node then
        return
    end
    local line = panel.node_lines[node]
    while not line and node > 0 do
        node = tree.parent[node]
        line = panel.node_lines[node]
    end
    if line then
        local meta = panel.line_metas[line]
        api.nvim_win_set_cursor(panel.window, { line, meta and meta.label_start or 0 })
    end
    update_header()
end

-- select the node under the document's caret. with `open`, also open its
-- ancestors so it's visible. the caret moved there, so it gets to see.
local function follow_caret(open)
    local panel = json_tree.panel
    if not panel_is_valid(panel) or panel.message then
        return
    end
    local document = json_tree.documents[panel.source_buffer]
    local tree = document and document.tree
    local window = panel.source_window
    if not tree or not api.nvim_win_is_valid(window) or api.nvim_win_get_buf(window) ~= panel.source_buffer then
        return update_header()
    end
    local caret = api.nvim_win_get_cursor(window)
    local node = node_at(tree, caret[1] * POSITION_SCALE + caret[2] + 1) or 1
    local is_current = document.tick == api.nvim_buf_get_changedtick(panel.source_buffer)
    if open and is_current and not panel.stale and open_ancestors(document, tree, node) then
        render()
    end
    select_node(node)
end

-- show the panel's document again: refuse it, rebuild its tree if it
-- changed, or just redraw.
local function refresh()
    local panel = json_tree.panel
    if not panel_is_valid(panel) then
        return
    end
    local buffer = panel.source_buffer
    panel.message = refusal(buffer)
    if panel.message then
        local document = json_tree.documents[buffer]
        if document then
            -- too large now: let the old tree go. it's twenty megabytes of
            -- memory i'd rather spend on regret.
            cancel_build(document)
            document.tree, document.tick, document.problem = nil, nil, nil
        end
        return render()
    end
    local document = document_for(buffer)
    local tick = api.nvim_buf_get_changedtick(buffer)
    local build_is_current = document.build and document.build.tick == tick
    if document.tick == tick or build_is_current then
        render()
        return follow_caret(false)
    end
    start_build(buffer, document, function()
        local current_panel = json_tree.panel
        if panel_is_valid(current_panel) and current_panel.source_buffer == buffer then
            render()
            follow_caret(true)
        end
    end)
    if document.build then
        render()
    end
end

local function refresh_soon()
    local panel = json_tree.panel
    if not panel or not panel.timer then
        return
    end
    panel.timer:stop()
    panel.timer:start(
        DEBOUNCE_MILLISECONDS,
        0,
        vim.schedule_wrap(function()
            require('notebashpp.json_tree').refresh()
        end)
    )
end

-- the panel follows the document in `window`.
local function follow_window(window)
    local panel = json_tree.panel
    local buffer = api.nvim_win_get_buf(window)
    if panel.source_window == window and panel.source_buffer == buffer then
        return
    end
    panel.source_window = window
    panel.source_buffer = buffer
    -- one tree in memory at a time. the others rebuild when you come back.
    -- i also only hold one grudge at a time. it's about capacity.
    for other_buffer, document in pairs(json_tree.documents) do
        if other_buffer ~= buffer then
            cancel_build(document)
            document.tree, document.tick, document.problem = nil, nil, nil
        end
    end
    refresh()
    follow_caret(true)
end

local PANEL_WINDOW_OPTIONS = {
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    foldcolumn = '0',
    foldenable = false,
    statuscolumn = '',
    colorcolumn = '',
    cursorline = true,
    cursorcolumn = false,
    wrap = false,
    list = false,
    spell = false,
    winfixwidth = true,
    sidescrolloff = 0,
    fillchars = 'eob: ',
    winhighlight = 'Normal:NotebashJsonTree,NormalNC:NotebashJsonTree,CursorLine:NotebashJsonTreeCurrent,'
        .. 'WinBar:NotebashJsonTreeHeader,WinBarNC:NotebashJsonTreeHeader,EndOfBuffer:NotebashJsonTree',
}

local function apply_window_options(window)
    for option_name, option_value in pairs(PANEL_WINDOW_OPTIONS) do
        vim.wo[window][0][option_name] = option_value
    end
end

---------------------------------------------------------------- actions

local function panel_tree_and_meta(line_number)
    local panel = json_tree.panel
    local document = json_tree.documents[panel.source_buffer]
    local meta = panel.line_metas[line_number or api.nvim_win_get_cursor(panel.window)[1]]
    return document and document.tree, meta, document
end

-- put the caret on the node in the document and go there. a stale tree may
-- point past the end now; clamp. i've pointed past the end of things before.
local function jump_to(node)
    local panel = json_tree.panel
    local tree = panel_tree_and_meta()
    if not tree or not node then
        return
    end
    local window = panel.source_window
    if not api.nvim_win_is_valid(window) or api.nvim_win_get_buf(window) ~= panel.source_buffer then
        return
    end
    local position = tree.start[node]
    local line_number = math.max(1, math.min(line_of(position), api.nvim_buf_line_count(panel.source_buffer)))
    local line_text = api.nvim_buf_get_lines(panel.source_buffer, line_number - 1, line_number, false)[1] or ''
    local column = math.max(0, math.min(column_of(position) - 1, #line_text))
    api.nvim_set_current_win(window)
    api.nvim_win_set_cursor(window, { line_number, column })
end

local function set_open(node, is_open)
    local tree, _, document = panel_tree_and_meta()
    if not tree or not document then
        return
    end
    local record = open_record(document, tree, node, true)
    if not record or record.open == is_open then
        return
    end
    record.open = is_open
    render()
    select_node(node)
end

local actions = {}

function actions.jump()
    local _, meta = panel_tree_and_meta()
    if meta then
        jump_to(meta.node)
    end
end

function actions.toggle()
    local _, meta = panel_tree_and_meta()
    if meta and meta.expandable then
        set_open(meta.node, not meta.is_open)
    end
end

-- right: open, or step into the first child. left: close, or step out to
-- the parent. windows tree views have done this since 1995. i've been
-- stepping out to the parent since about then too.
function actions.right()
    local _, meta = panel_tree_and_meta()
    if not meta or not meta.expandable then
        return
    end
    if not meta.is_open then
        return set_open(meta.node, true)
    end
    select_node(meta.node + 1)
end

function actions.left()
    local tree, meta = panel_tree_and_meta()
    if not meta or not tree then
        return
    end
    if meta.expandable and meta.is_open then
        return set_open(meta.node, false)
    end
    if tree.parent[meta.node] > 0 then
        select_node(tree.parent[meta.node])
    end
end

function actions.open()
    local _, meta = panel_tree_and_meta()
    if meta and meta.expandable then
        set_open(meta.node, true)
    end
end

function actions.close_node()
    local _, meta = panel_tree_and_meta()
    if meta and meta.expandable then
        set_open(meta.node, false)
    end
end

-- a click on + or - opens or closes, a click anywhere else on a node jumps
-- to it. runs on the button's release: the press already moved focus here.
function actions.click()
    local panel = json_tree.panel
    local mouse = vim.fn.getmousepos()
    if mouse.winid ~= panel.window or mouse.line < 1 then
        return
    end
    api.nvim_set_current_win(panel.window)
    api.nvim_win_set_cursor(panel.window, { mouse.line, 0 })
    local _, meta = panel_tree_and_meta(mouse.line)
    if not meta then
        return
    end
    local clicked_column = mouse.column - 1
    if meta.expandable and clicked_column >= meta.expander and clicked_column < meta.expander + 2 then
        return set_open(meta.node, not meta.is_open)
    end
    jump_to(meta.node)
end

function actions.copy_path()
    local tree, meta = panel_tree_and_meta()
    if tree and meta then
        json_tree.copy_text_path(json_tree.path_of(tree, meta.node))
    end
end

function actions.close_panel()
    json_tree.close()
end

function actions.cursor_moved()
    update_header()
end

-- run a panel action through the current module, so a code reload's new
-- code answers the old panel's keys.
function json_tree.panel_action(action_name)
    local panel = json_tree.panel
    if not panel_is_valid(panel) then
        return
    end
    actions[action_name]()
end

local PANEL_KEYS = {
    { '<CR>', 'jump' },
    { '<kEnter>', 'jump' },
    { '<2-LeftMouse>', 'toggle' },
    { '<Space>', 'toggle' },
    { '<Right>', 'right' },
    { '<Left>', 'left' },
    { '+', 'open' },
    { '<kPlus>', 'open' },
    { '-', 'close_node' },
    { '<kMinus>', 'close_node' },
    { '<C-c>', 'copy_path' },
    { '<C-Insert>', 'copy_path' },
    { '<Esc>', 'close_panel' },
}

local function set_panel_keys(buffer)
    local function map(modes, keys, action)
        vim.keymap.set(modes, keys, action, { buffer = buffer, nowait = true, silent = true })
    end
    -- letters and punctuation would run neovim's normal-mode commands here
    -- (dd, p, u, :). they do nothing. i'd love an off switch like that for
    -- the voice in my head that runs commands.
    for byte = 33, 126 do
        local character = string.char(byte)
        map('n', character == '<' and '<lt>' or character, '<Nop>')
    end
    for _, key in ipairs({ '<BS>', '<Del>', '<Insert>' }) do
        map('n', key, '<Nop>')
    end
    for _, key_and_action in ipairs(PANEL_KEYS) do
        local action_name = key_and_action[2]
        map('n', key_and_action[1], function()
            require('notebashpp.json_tree').panel_action(action_name)
        end)
    end
    map({ 'n', 'i' }, '<LeftRelease>', function()
        require('notebashpp.json_tree').panel_action('click')
    end)
end

local function set_autocmds(panel)
    local augroup = api.nvim_create_augroup(augroup_name, { clear = true })
    local function module()
        return require('notebashpp.json_tree')
    end
    api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
        group = augroup,
        callback = function()
            module().on_enter()
        end,
    })
    api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
        group = augroup,
        callback = function(event)
            local current_panel = module().panel
            if current_panel and event.buf == current_panel.source_buffer then
                refresh_soon()
            end
        end,
    })
    api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
        group = augroup,
        callback = function(event)
            local current_panel = module().panel
            if current_panel and event.buf == current_panel.source_buffer and api.nvim_get_current_win() == current_panel.source_window then
                module().follow_caret(true)
            end
        end,
    })
    api.nvim_create_autocmd('CursorMoved', {
        group = augroup,
        buffer = panel.buffer,
        callback = function()
            module().panel_action('cursor_moved')
        end,
    })
    -- the panel keeps out of typing: entering it always leaves insert mode.
    api.nvim_create_autocmd('BufEnter', {
        group = augroup,
        buffer = panel.buffer,
        callback = function()
            vim.cmd.stopinsert()
        end,
    })
    api.nvim_create_autocmd('BufWinEnter', {
        group = augroup,
        callback = function()
            module().on_buffer_in_window()
        end,
    })
    api.nvim_create_autocmd({ 'FileType', 'BufFilePost' }, {
        group = augroup,
        callback = function(event)
            local current_panel = module().panel
            if current_panel and event.buf == current_panel.source_buffer then
                -- another language can mean comments are allowed now. same
                -- text, new rules. like moving countries.
                local document = module().documents[event.buf]
                if document then
                    document.tick = nil
                end
                vim.schedule(module().refresh)
            end
        end,
    })
    api.nvim_create_autocmd('WinClosed', {
        group = augroup,
        callback = function(event)
            module().on_window_closed(tonumber(event.match))
        end,
    })
    api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
        group = augroup,
        callback = function()
            local current_panel = module().panel
            if panel_is_valid(current_panel) and panel_width(current_panel) ~= current_panel.rendered_width then
                module().refresh()
            end
        end,
    })
end

-- a wiped buffer's open/closed record goes with it, panel open or not.
api.nvim_create_autocmd('BufWipeout', {
    group = api.nvim_create_augroup('notebashpp_json_tree_documents', { clear = true }),
    callback = function(event)
        require('notebashpp.json_tree').documents[event.buf] = nil
    end,
})

-- focus moved: if it landed on a document, the panel shows that document.
function json_tree.on_enter()
    local panel = json_tree.panel
    if not panel_is_valid(panel) then
        return
    end
    local window = api.nvim_get_current_win()
    if is_document_window(window) then
        follow_window(window)
    end
end

-- a document switched into the panel's window (ctrl+tab from the panel, a
-- file opened while it had focus) goes back where documents live, and the
-- panel gets its window back. the panel is not a tab. some boundaries hold.
function json_tree.on_buffer_in_window()
    local panel = json_tree.panel
    if not panel or api.nvim_get_current_win() ~= panel.window then
        return
    end
    local intruder = api.nvim_get_current_buf()
    if intruder == panel.buffer then
        return
    end
    vim.schedule(function()
        local current_panel = json_tree.panel
        if not current_panel or not api.nvim_win_is_valid(current_panel.window) or not api.nvim_buf_is_valid(current_panel.buffer) then
            return
        end
        if api.nvim_win_get_buf(current_panel.window) == intruder then
            api.nvim_win_set_buf(current_panel.window, current_panel.buffer)
            apply_window_options(current_panel.window)
            render()
        end
        local target = api.nvim_win_is_valid(current_panel.source_window) and current_panel.source_window or any_document_window()
        if target and api.nvim_buf_is_valid(intruder) then
            api.nvim_win_set_buf(target, intruder)
            api.nvim_set_current_win(target)
            json_tree.on_enter()
        end
    end)
end

-- the panel's window closed some other way, or its document's did.
function json_tree.on_window_closed(window)
    local panel = json_tree.panel
    if not panel then
        return
    end
    if window == panel.window then
        vim.schedule(json_tree.close)
    elseif window == panel.source_window then
        vim.schedule(function()
            local current_panel = json_tree.panel
            if not panel_is_valid(current_panel) then
                return
            end
            local replacement = any_document_window()
            if replacement then
                follow_window(replacement)
            else
                -- only the panel is left. neovim always needs one window,
                -- and the panel shouldn't be it.
                json_tree.close()
            end
        end)
    end
end

function json_tree.refresh()
    refresh()
end

function json_tree.follow_caret(open)
    follow_caret(open)
end

function json_tree.open()
    if json_tree.is_open() then
        return
    end
    json_tree.close()
    local source_window = api.nvim_get_current_win()
    if not is_document_window(source_window) then
        source_window = any_document_window()
        if not source_window then
            return helpers.warn('Open a document first.')
        end
    end
    local buffer = api.nvim_create_buf(false, true)
    vim.bo[buffer].bufhidden = 'hide'
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].undolevels = -1
    vim.bo[buffer].modifiable = false
    vim.b[buffer].notebashpp_panel = 'json_tree'
    local width = math.max(20, math.min(PANEL_WIDTH, math.floor(vim.o.columns / 2)))
    local window = api.nvim_open_win(buffer, false, { split = 'right', win = -1, width = width })
    apply_window_options(window)
    api.nvim_win_call(window, function()
        vim.bo[buffer].filetype = 'notebashpp_json_tree'
    end)
    local panel = {
        buffer = buffer,
        window = window,
        source_window = source_window,
        source_buffer = api.nvim_win_get_buf(source_window),
        line_metas = {},
        node_lines = {},
        timer = vim.uv.new_timer(),
    }
    json_tree.panel = panel
    set_panel_keys(buffer)
    set_autocmds(panel)
    refresh()
    follow_caret(true)
end

function json_tree.close()
    local panel = json_tree.panel
    if not panel then
        return
    end
    json_tree.panel = nil
    pcall(api.nvim_del_augroup_by_name, augroup_name)
    if panel.timer then
        panel.timer:stop()
        panel.timer:close()
    end
    local was_current = api.nvim_get_current_win() == panel.window
    local other_windows = 0
    for _, window in ipairs(api.nvim_tabpage_list_wins(0)) do
        if window ~= panel.window and not is_floating(window) then
            other_windows = other_windows + 1
        end
    end
    if api.nvim_win_is_valid(panel.window) and other_windows > 0 then
        api.nvim_win_close(panel.window, true)
    end
    if api.nvim_buf_is_valid(panel.buffer) and other_windows > 0 then
        pcall(api.nvim_buf_delete, panel.buffer, { force = true })
    end
    if was_current and api.nvim_win_is_valid(panel.source_window) then
        api.nvim_set_current_win(panel.source_window)
    end
    -- keep which nodes were open, drop the trees: they can be big, and a
    -- closed panel has no use for them. memory is cheap, but so am i.
    for _, document in pairs(json_tree.documents) do
        cancel_build(document)
        document.tree, document.tick, document.problem = nil, nil, nil
    end
end

-- plugins > json > show json tree, ctrl+alt+shift+j.
function json_tree.toggle()
    if json_tree.is_open() then
        return json_tree.close()
    end
    json_tree.open()
end

function json_tree.copy_text_path(path)
    if path == '' then
        return helpers.warn('JSON path: the caret is on the whole document, not inside a key or an array item.')
    end
    require('notebashpp.clipboard').set({ path }, 'v')
    helpers.notify('Copied JSON path ' .. sanitize(path, 60))
end

-- plugins > json > copy json path: the path of the node under the caret.
function json_tree.copy_path()
    local buffer = api.nvim_get_current_buf()
    local panel = json_tree.panel
    if panel and api.nvim_get_current_win() == panel.window then
        return actions.copy_path()
    end
    local document, reason = current_document(buffer)
    if not document then
        return helpers.warn(reason)
    end
    if not document.tree then
        return helpers.warn('JSON path: the document is not valid JSON. ' .. (document.problem and document.problem.message or ''))
    end
    local caret = api.nvim_win_get_cursor(0)
    local node = node_at(document.tree, caret[1] * POSITION_SCALE + caret[2] + 1)
    json_tree.copy_text_path(node and json_tree.path_of(document.tree, node) or '')
end

-- the panel's lines, for tests. the robot reads them so i don't have to.
function json_tree.panel_lines()
    local panel = json_tree.panel
    if not panel_is_valid(panel) then
        return nil
    end
    return api.nvim_buf_get_lines(panel.buffer, 0, -1, false)
end

return json_tree
