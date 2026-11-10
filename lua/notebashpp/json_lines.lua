-- one line of a json lines file (.jsonl, .ndjson), taken apart without
-- losing a byte. vim.json.decode forgets key order and turns
-- 12345678901234567890 into 1.2345678901235e+19, so this tokenizer only
-- notes where each top-level key's value starts and ends. an edit swaps that
-- span and leaves every other byte alone. i want a record of my mistakes
-- that nobody rounds off.
--
-- everything here is linear in the line's length and never recurses: nesting
-- is tracked in a plain list, strings are skipped with string.find, and a
-- line of a million [ costs a million steps, not a stack overflow. nul bytes
-- and broken utf-8 are just bytes to it. hostile input gets the same cold
-- indifference i get from everything else.

local json_lines = {}

local QUOTE_BYTE, BACKSLASH_BYTE = 34, 92
local OPEN_BRACE_BYTE, CLOSE_BRACE_BYTE = 123, 125
local OPEN_BRACKET_BYTE, CLOSE_BRACKET_BYTE = 91, 93
local COMMA_BYTE, COLON_BYTE, MINUS_BYTE = 44, 58, 45

-- the escapes json allows after a backslash, and what they stand for. u is
-- handled apart, with its four hex digits.
local SIMPLE_ESCAPES = {
    [34] = '"',
    [92] = '\\',
    [47] = '/',
    [98] = '\b',
    [102] = '\f',
    [110] = '\n',
    [114] = '\r',
    [116] = '\t',
}

-- position of the first non-whitespace byte at or after `position`, or one
-- past the end. json whitespace is space, tab, line feed & carriage return.
local function skip_whitespace(text, position)
    return text:find('[^ \t\n\r]', position) or #text + 1
end

-- `position` holds a quote. return the position after the closing quote, or
-- nil if the string is broken: unclosed, a raw control character inside, or
-- a bad escape. one find per escape or per string. even my strings come with
-- conditions.
local function skip_string(text, position)
    local scan = position + 1
    while true do
        local special = text:find('[%z\1-\31"\\]', scan)
        if not special then
            return nil
        end
        local special_byte = text:byte(special)
        if special_byte == QUOTE_BYTE then
            return special + 1
        end
        if special_byte ~= BACKSLASH_BYTE then
            return nil
        end
        local escaped = text:byte(special + 1)
        if escaped == 117 then
            if not text:find('^%x%x%x%x', special + 2) then
                return nil
            end
            scan = special + 6
        elseif escaped and SIMPLE_ESCAPES[escaped] then
            scan = special + 2
        else
            return nil
        end
    end
end

-- position after a json number starting at `position`, or nil. leading
-- zeros, a bare dot or an empty exponent are refused, as json refuses them.
-- the only standards anybody here still keeps.
local function skip_number(text, position)
    local scan = position
    if text:byte(scan) == MINUS_BYTE then
        scan = scan + 1
    end
    local first_digit = text:byte(scan)
    if first_digit == 48 then
        scan = scan + 1
    elseif first_digit and first_digit >= 49 and first_digit <= 57 then
        scan = text:find('%D', scan + 1) or #text + 1
    else
        return nil
    end
    if text:byte(scan) == 46 then
        local after_fraction = text:find('%D', scan + 1) or #text + 1
        if after_fraction == scan + 1 then
            return nil
        end
        scan = after_fraction
    end
    local exponent_mark = text:byte(scan)
    if exponent_mark == 101 or exponent_mark == 69 then
        scan = scan + 1
        local sign = text:byte(scan)
        if sign == 43 or sign == MINUS_BYTE then
            scan = scan + 1
        end
        local after_exponent = text:find('%D', scan) or #text + 1
        if after_exponent == scan then
            return nil
        end
        scan = after_exponent
    end
    return scan
end

local LITERALS = { [116] = 'true', [102] = 'false', [110] = 'null' }

-- position just after the json value starting at `position` (no whitespace
-- skipped before it), or nil if it isn't one. nesting lives in a list of the
-- closing brackets still owed, so depth costs memory, never stack. i owe
-- things too. nobody keeps a list that tidy for me.
local function skip_value(text, position)
    local owed_closers = {}
    local depth = 0
    -- 'value', 'value_or_close' (just after a [), 'key', 'key_or_close'
    -- (just after a {), or 'after_value'.
    local expecting = 'value'
    while true do
        if expecting ~= 'value' or depth > 0 then
            position = skip_whitespace(text, position)
        end
        local current_byte = text:byte(position)
        if not current_byte then
            return nil
        end
        if expecting == 'after_value' then
            if current_byte == COMMA_BYTE then
                expecting = owed_closers[depth] == CLOSE_BRACE_BYTE and 'key' or 'value'
                position = position + 1
            elseif current_byte == owed_closers[depth] then
                owed_closers[depth] = nil
                depth = depth - 1
                position = position + 1
                if depth == 0 then
                    return position
                end
            else
                return nil
            end
        elseif expecting == 'key' or expecting == 'key_or_close' then
            if expecting == 'key_or_close' and current_byte == CLOSE_BRACE_BYTE then
                owed_closers[depth] = nil
                depth = depth - 1
                position = position + 1
                if depth == 0 then
                    return position
                end
                expecting = 'after_value'
            elseif current_byte == QUOTE_BYTE then
                position = skip_string(text, position)
                if not position then
                    return nil
                end
                position = skip_whitespace(text, position)
                if text:byte(position) ~= COLON_BYTE then
                    return nil
                end
                position = skip_whitespace(text, position + 1)
                expecting = 'value'
            else
                return nil
            end
        else
            local value_end
            if expecting == 'value_or_close' and current_byte == CLOSE_BRACKET_BYTE then
                owed_closers[depth] = nil
                depth = depth - 1
                position = position + 1
                if depth == 0 then
                    return position
                end
                expecting = 'after_value'
            elseif current_byte == OPEN_BRACE_BYTE then
                depth = depth + 1
                owed_closers[depth] = CLOSE_BRACE_BYTE
                position = position + 1
                expecting = 'key_or_close'
            elseif current_byte == OPEN_BRACKET_BYTE then
                depth = depth + 1
                owed_closers[depth] = CLOSE_BRACKET_BYTE
                position = position + 1
                expecting = 'value_or_close'
            else
                if current_byte == QUOTE_BYTE then
                    value_end = skip_string(text, position)
                elseif LITERALS[current_byte] then
                    local literal = LITERALS[current_byte]
                    value_end = text:sub(position, position + #literal - 1) == literal and position + #literal or nil
                else
                    value_end = skip_number(text, position)
                end
                if not value_end then
                    return nil
                end
                if depth == 0 then
                    return value_end
                end
                position = value_end
                expecting = 'after_value'
            end
        end
    end
end

-- true if all of `text`, give or take surrounding whitespace, is one json
-- value. i'd settle for being one coherent anything.
function json_lines.is_json_value(text)
    local first = skip_whitespace(text, 1)
    if first > #text then
        return false
    end
    local value_end = skip_value(text, first)
    return value_end ~= nil and skip_whitespace(text, value_end) > #text
end

local function utf8_character(code_point)
    if code_point < 128 then
        return string.char(code_point)
    elseif code_point < 2048 then
        return string.char(192 + math.floor(code_point / 64), 128 + code_point % 64)
    elseif code_point < 65536 then
        return string.char(224 + math.floor(code_point / 4096), 128 + math.floor(code_point / 64) % 64, 128 + code_point % 64)
    end
    return string.char(
        240 + math.floor(code_point / 262144),
        128 + math.floor(code_point / 4096) % 64,
        128 + math.floor(code_point / 64) % 64,
        128 + code_point % 64
    )
end

-- the text of the json string from the quote at `first` to the quote at
-- `last`, escapes undone. call only on spans skip_string accepted. a lone
-- surrogate half becomes the replacement character, the unicode way of
-- saying "something was here once".
function json_lines.decode_string(text, first, last)
    local content_first = first + 1
    local backslash = text:find('\\', content_first, true)
    if not backslash or backslash >= last then
        return text:sub(content_first, last - 1)
    end
    local pieces, scan = {}, content_first
    while backslash and backslash < last do
        pieces[#pieces + 1] = text:sub(scan, backslash - 1)
        local escaped = text:byte(backslash + 1)
        if escaped == 117 then
            local code_point = tonumber(text:sub(backslash + 2, backslash + 5), 16) or 65533
            scan = backslash + 6
            if code_point >= 55296 and code_point <= 56319 and text:sub(scan, scan + 1) == '\\u' then
                local low_half = tonumber(text:sub(scan + 2, scan + 5), 16)
                if low_half and low_half >= 56320 and low_half <= 57343 then
                    code_point = 65536 + (code_point - 55296) * 1024 + (low_half - 56320)
                    scan = scan + 6
                end
            end
            if code_point >= 55296 and code_point <= 57343 then
                code_point = 65533
            end
            pieces[#pieces + 1] = utf8_character(code_point)
        else
            pieces[#pieces + 1] = SIMPLE_ESCAPES[escaped] or ''
            scan = backslash + 2
        end
        backslash = text:find('\\', scan, true)
    end
    pieces[#pieces + 1] = text:sub(scan, last - 1)
    return table.concat(pieces)
end

-- the json value in text[first..last] without whitespace outside its
-- strings: {"a": [1, 2]} shows as {"a":[1,2]}. strings are copied whole.
-- compact, like my flat.
function json_lines.compact(text, first, last)
    local pieces, scan = {}, first
    while scan <= last do
        local quote = text:find('"', scan, true)
        if not quote or quote > last then
            pieces[#pieces + 1] = (text:sub(scan, last):gsub('[ \t\n\r]+', ''))
            break
        end
        pieces[#pieces + 1] = (text:sub(scan, quote - 1):gsub('[ \t\n\r]+', ''))
        local string_end = skip_string(text, quote) or last + 1
        pieces[#pieces + 1] = text:sub(quote, string_end - 1)
        scan = string_end
    end
    return table.concat(pieces)
end

local QUOTED_CHARACTERS = {
    ['"'] = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

-- `text` as a json string literal. bytes from 128 up go through untouched,
-- broken utf-8 included: i don't fix what i didn't break.
function json_lines.quote(text)
    return '"'
        .. text:gsub('[%z\1-\31"\\]', function(character)
            return QUOTED_CHARACTERS[character] or ('\\u%04x'):format(character:byte())
        end)
        .. '"'
end

-- take one line apart. returns { kind = 'object', members = { ... } } for a
-- json object, where each member has key (decoded), key_first, key_last,
-- value_first & value_last (byte positions, inclusive), plus close_position
-- for the }. { kind = 'blank' } for a line of nothing but whitespace.
-- { kind = 'other' } for anything else: an array, a number, broken json.
-- people are sorted with less care than this.
function json_lines.parse_line(text)
    local position = skip_whitespace(text, 1)
    if position > #text then
        return { kind = 'blank' }
    end
    if text:byte(position) ~= OPEN_BRACE_BYTE then
        return { kind = 'other' }
    end
    local members = {}
    local parsed = { kind = 'object', members = members }
    position = skip_whitespace(text, position + 1)
    if text:byte(position) == CLOSE_BRACE_BYTE then
        parsed.close_position = position
    else
        while true do
            if text:byte(position) ~= QUOTE_BYTE then
                return { kind = 'other' }
            end
            local key_end = skip_string(text, position)
            if not key_end then
                return { kind = 'other' }
            end
            local member = { key_first = position, key_last = key_end - 1, key = json_lines.decode_string(text, position, key_end - 1) }
            position = skip_whitespace(text, key_end)
            if text:byte(position) ~= COLON_BYTE then
                return { kind = 'other' }
            end
            position = skip_whitespace(text, position + 1)
            local value_end = skip_value(text, position)
            if not value_end then
                return { kind = 'other' }
            end
            member.value_first, member.value_last = position, value_end - 1
            members[#members + 1] = member
            position = skip_whitespace(text, value_end)
            local separator = text:byte(position)
            if separator == COMMA_BYTE then
                position = skip_whitespace(text, position + 1)
            elseif separator == CLOSE_BRACE_BYTE then
                parsed.close_position = position
                break
            else
                return { kind = 'other' }
            end
        end
    end
    if skip_whitespace(text, parsed.close_position + 1) <= #text then
        return { kind = 'other' }
    end
    return parsed
end

-- a member's value as cell text: strings unquoted, numbers, true, false &
-- null as written, objects & arrays as compact json. a string that would
-- read back as something else ("12", "true", "" or "[1]") keeps its quotes,
-- so typing it back in, copying or duplicating it never turns it into a
-- number. i've been mistaken for something else all my life. not on my watch.
function json_lines.cell_text(text, member)
    local first, last = member.value_first, member.value_last
    local first_byte = text:byte(first)
    if first_byte == QUOTE_BYTE then
        local decoded = json_lines.decode_string(text, first, last)
        if decoded == '' or json_lines.is_json_value(decoded) then
            return text:sub(first, last)
        end
        return decoded
    end
    if first_byte == OPEN_BRACE_BYTE or first_byte == OPEN_BRACKET_BYTE then
        return json_lines.compact(text, first, last)
    end
    return text:sub(first, last)
end

-- the json to write for what somebody typed into a cell: nil for an empty
-- cell (the key goes), the text itself (trimmed) if it is json, otherwise
-- the text as a string. typing 12 gives a number, "12" a string, abc a
-- string. the rules are simple. following them is where i usually fail.
function json_lines.value_for_text(cell_text)
    if cell_text == '' then
        return nil
    end
    if json_lines.is_json_value(cell_text) then
        local first = skip_whitespace(cell_text, 1)
        local last = #cell_text
        while cell_text:find('^[ \t\n\r]', last) do
            last = last - 1
        end
        return cell_text:sub(first, last)
    end
    return json_lines.quote(cell_text)
end

-- `text` (a line parse_line called an object) with `changes` applied. each
-- change is { key = name, value = json text, or nil to remove the key }. a
-- changed key keeps its place; its last copy gets the new value (as every
-- json reader shows the last copy). a removed key loses every copy, plus one
-- comma. new keys go after the last member, spaced like the line's first
-- member. every byte nobody asked about stays as it was. i wish my own
-- changes were this contained.
function json_lines.rewrite_object(text, parsed, changes)
    local members = parsed.members
    local last_copy = {}
    for member_number, member in ipairs(members) do
        last_copy[member.key] = member_number
    end
    local replaced, removed, added = {}, {}, {}
    for _, change in ipairs(changes) do
        local member_number = last_copy[change.key]
        if member_number and change.value ~= nil then
            replaced[member_number] = change.value
        elseif member_number then
            for other_number, member in ipairs(members) do
                if member.key == change.key then
                    removed[other_number] = true
                end
            end
        elseif change.value ~= nil then
            added[#added + 1] = change
        end
    end
    local colon_text, comma_text = ':', ','
    if members[1] then
        colon_text = text:sub(members[1].key_last + 1, members[1].value_first - 1)
    end
    if members[2] then
        comma_text = text:sub(members[1].value_last + 1, members[2].key_first - 1)
    elseif colon_text:find(' $') then
        comma_text = ', '
    end
    local pieces = {}
    if members[1] then
        pieces[1] = text:sub(1, members[1].key_first - 1)
    else
        pieces[1] = text:sub(1, parsed.close_position - 1)
    end
    local previous_kept
    for member_number, member in ipairs(members) do
        if not removed[member_number] then
            if previous_kept then
                pieces[#pieces + 1] = text:sub(members[previous_kept].value_last + 1, members[previous_kept + 1].key_first - 1)
            end
            pieces[#pieces + 1] = text:sub(member.key_first, member.value_first - 1)
            pieces[#pieces + 1] = replaced[member_number] or text:sub(member.value_first, member.value_last)
            previous_kept = member_number
        end
    end
    for _, change in ipairs(added) do
        if previous_kept or #pieces > 1 then
            pieces[#pieces + 1] = comma_text
        end
        pieces[#pieces + 1] = json_lines.quote(change.key) .. colon_text .. change.value
    end
    if members[1] then
        pieces[#pieces + 1] = text:sub(members[#members].value_last + 1)
    else
        pieces[#pieces + 1] = text:sub(parsed.close_position)
    end
    return table.concat(pieces)
end

-- a new object from `changes`, in their order, for a blank line or an added
-- row. {} when nothing is left in it. an empty box. relatable.
function json_lines.build_object(changes)
    local pieces = {}
    for _, change in ipairs(changes) do
        if change.value ~= nil then
            pieces[#pieces + 1] = json_lines.quote(change.key) .. ':' .. change.value
        end
    end
    return '{' .. table.concat(pieces, ',') .. '}'
end

return json_lines
