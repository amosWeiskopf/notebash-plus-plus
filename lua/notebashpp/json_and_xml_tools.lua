-- json & xml: format, minify, check. after compare, the three most installed
-- notepad++ plugins are json viewer (8.1 million downloads), xml tools (7.6
-- million) and json tools (2.8 million). apparently we all need help putting
-- spaces in shit. these cover the everyday work in plain lua, with nothing to
-- install. each command uses the selection, or the whole document when
-- nothing is selected.
--
-- json formatting keeps key order, numbers and string escapes exactly as
-- written. neovim's json functions would reorder the keys, so here they only
-- check validity. i want formatting, please. i have enough things in my life
-- rearranging themselves without my permission.

local json_and_xml_tools = {}
local api = vim.api
local helpers = require('notebashpp.helpers')

-- use the selected lines, or the whole document. return the text & a function
-- to replace it in one undo step. i'd love the same option for my life
-- (apparently the api is unavailable).
local function target_text()
    local first_line, last_line = 1, api.nvim_buf_line_count(0)
    if helpers.get_selection() then
        first_line, last_line = helpers.selected_line_range()
    end
    local text = table.concat(api.nvim_buf_get_lines(0, first_line - 1, last_line, false), '\n')
    local function replace_with(new_text)
        api.nvim_buf_set_lines(0, first_line - 1, last_line, false, vim.split(new_text, '\n', { plain = true }))
        pcall(api.nvim_win_set_cursor, 0, { first_line, 0 })
    end
    return text, replace_with, first_line
end

-- one indent level: a tab or shiftwidth spaces, per document. local crap.
local function indent_unit()
    if vim.bo.expandtab then
        return string.rep(' ', vim.fn.shiftwidth())
    end
    return '\t'
end

-- "line 3, column 7" from a 1-based byte offset; text starts at first_line in
-- the document. exact coordinates for another failure.
local function position_name(text, byte_offset, first_line)
    local before = text:sub(1, math.max(0, byte_offset - 1))
    local _, newline_count = before:gsub('\n', '')
    -- anchored, or lua retries the match from every byte and a 100 kb line
    -- takes 18 seconds. i know about wasting time on the same mistake.
    local column = #before - (before:match('^.*\n()') or 1) + 2
    return ('line %d, column %d'):format(first_line + newline_count, column)
end

---------------------------------------------------------------- json

-- split json into strings (escapes kept as typed), punctuation, and the rest
-- (numbers, true, false, null), unchanged. i can at least keep these small
-- bastards intact.
local function json_tokens(text)
    local tokens, position = {}, 1
    while position <= #text do
        local character = text:sub(position, position)
        if character:match('%s') then
            position = position + 1
        elseif character == '"' then
            local closing = position + 1
            while closing <= #text do
                local next_character = text:sub(closing, closing)
                if next_character == '\\' then
                    closing = closing + 2
                elseif next_character == '"' then
                    break
                else
                    closing = closing + 1
                end
            end
            tokens[#tokens + 1] = text:sub(position, closing)
            position = closing + 1
        elseif character:match('[{}%[%]:,]') then
            tokens[#tokens + 1] = character
            position = position + 1
        else
            local value = text:match('^[^%s{}%[%]:,"]+', position)
            tokens[#tokens + 1] = value
            position = position + #value
        end
    end
    return tokens
end

-- json parser token names in words. misery, translated.
local TOKEN_WORDS = {
    T_COMMA = '","',
    T_COLON = '":"',
    T_OBJ_BEGIN = '"{"',
    T_OBJ_END = '"}"',
    T_ARR_BEGIN = '"["',
    T_ARR_END = '"]"',
    T_STRING = 'a string',
    T_INTEGER = 'a number',
    T_NUMBER = 'a number',
    T_BOOLEAN = 'true or false',
    T_NULL = 'null',
    T_END = 'the end of the text',
    T_ERROR = 'text that is not json',
}

-- valid json: nil. otherwise "line n, column m: what is wrong". basically a
-- failure with an address.
local function json_problem(text, first_line)
    local decoded_ok, error_message = pcall(vim.json.decode, text)
    if decoded_ok then
        return nil
    end
    local offset = tonumber(tostring(error_message):match('at character (%d+)'))
    local reason = tostring(error_message):gsub('^.-:%d+: ', ''):gsub(' at character %d+', ''):gsub('T_[%u_]+', TOKEN_WORDS)
    return offset and (position_name(text, offset, first_line) .. ': ' .. reason) or reason
end

local function format_json(text, pretty)
    local unit = indent_unit()
    local pieces, depth = {}, 0
    local tokens = json_tokens(text)
    for index, token in ipairs(tokens) do
        local next_token = tokens[index + 1]
        if token == '{' or token == '[' then
            pieces[#pieces + 1] = token
            local closer = token == '{' and '}' or ']'
            if pretty and next_token ~= closer then
                depth = depth + 1
                pieces[#pieces + 1] = '\n' .. string.rep(unit, depth)
            end
        elseif token == '}' or token == ']' then
            local opener = token == '}' and '{' or '['
            if pretty and tokens[index - 1] ~= opener then
                depth = depth - 1
                pieces[#pieces + 1] = '\n' .. string.rep(unit, depth)
            end
            pieces[#pieces + 1] = token
        elseif token == ',' then
            pieces[#pieces + 1] = pretty and (',\n' .. string.rep(unit, depth)) or ','
        elseif token == ':' then
            pieces[#pieces + 1] = pretty and ': ' or ':'
        else
            pieces[#pieces + 1] = token
        end
    end
    return table.concat(pieces)
end

local function json_command(pretty)
    local text, replace_with, first_line = target_text()
    local problem = json_problem(text, first_line)
    if problem then
        return helpers.warn('JSON is not valid, nothing changed: ' .. problem)
    end
    replace_with(format_json(text, pretty))
end

function json_and_xml_tools.format_json()
    json_command(true)
end

function json_and_xml_tools.minify_json()
    json_command(false)
end

function json_and_xml_tools.check_json()
    local text, _, first_line = target_text()
    local problem = json_problem(text, first_line)
    helpers.notify(problem and ('JSON is not valid: ' .. problem) or 'JSON is valid.', problem and vim.log.levels.WARN or nil)
end

----------------------------------------------------------------- xml

-- split xml into { kind, text, start } nodes. kinds: 'open', 'close', 'empty'
-- (<a/>), 'text', 'other' (comments, cdata, <?...?>, <!doctype>). keep them
-- exactly as written. a tag that never closes returns nil & a problem. even
-- xml gets closure or a formal complaint. i'm still waiting for either.
local function xml_nodes(text)
    local nodes, position = {}, 1
    local function add(kind, node_text, start)
        nodes[#nodes + 1] = { kind = kind, text = node_text, start = start }
    end
    while position <= #text do
        if text:sub(position, position) ~= '<' then
            local next_tag = text:find('<', position, true) or (#text + 1)
            add('text', text:sub(position, next_tag - 1), position)
            position = next_tag
        else
            local closing_text, kind
            if text:sub(position, position + 3) == '<!--' then
                closing_text, kind = '-->', 'other'
            elseif text:sub(position, position + 8) == '<![CDATA[' then
                closing_text, kind = ']]>', 'other'
            elseif text:sub(position, position + 1) == '<?' then
                closing_text, kind = '?>', 'other'
            end
            local tag_end
            if closing_text then
                local found = text:find(closing_text, position, true)
                tag_end = found and (found + #closing_text - 1)
            else
                -- a tag ends at the first > outside quotes; doctype [ ... ]
                -- can hold more > inside. because one exit wasn't enough for
                -- this bastard.
                local quote, bracket_depth, scan = nil, 0, position + 1
                while scan <= #text do
                    local scanned = text:sub(scan, scan)
                    if quote then
                        if scanned == quote then
                            quote = nil
                        end
                    elseif scanned == '"' or scanned == "'" then
                        quote = scanned
                    elseif scanned == '[' then
                        bracket_depth = bracket_depth + 1
                    elseif scanned == ']' then
                        bracket_depth = bracket_depth - 1
                    elseif scanned == '>' and bracket_depth <= 0 then
                        tag_end = scan
                        break
                    end
                    scan = scan + 1
                end
                local tag_text = tag_end and text:sub(position, tag_end) or ''
                if tag_text:match('^<!') then
                    kind = 'other'
                elseif tag_text:match('^</') then
                    kind = 'close'
                elseif tag_text:match('/>$') then
                    kind = 'empty'
                else
                    kind = 'open'
                end
            end
            if not tag_end then
                return nil, position
            end
            add(kind, text:sub(position, tag_end), position)
            position = tag_end + 1
        end
    end
    return nodes
end

local function tag_name(tag_text)
    return tag_text:match('^</?([^%s/>]+)')
end

-- well formed: nil. otherwise where & what. failure needs paperwork.
local function xml_problem(text, first_line)
    local nodes, unclosed_at = xml_nodes(text)
    if not nodes then
        return position_name(text, unclosed_at, first_line) .. ': this tag is never closed'
    end
    local open_stack = {}
    local root_count = 0
    for _, node in ipairs(nodes) do
        if node.kind == 'open' then
            if #open_stack == 0 then
                root_count = root_count + 1
            end
            open_stack[#open_stack + 1] = node
        elseif node.kind == 'empty' and #open_stack == 0 then
            root_count = root_count + 1
        elseif node.kind == 'close' then
            local expected = table.remove(open_stack)
            if not expected then
                return position_name(text, node.start, first_line) .. ': ' .. node.text .. ' closes nothing'
            end
            if tag_name(expected.text) ~= tag_name(node.text) then
                return position_name(text, node.start, first_line)
                    .. (': %s closes <%s> from %s'):format(node.text, tag_name(expected.text), position_name(text, expected.start, first_line))
            end
        elseif node.kind == 'text' and #open_stack == 0 and vim.trim(node.text) ~= '' then
            return position_name(text, node.start, first_line) .. ': text outside the root element'
        end
    end
    if #open_stack > 0 then
        local unclosed = open_stack[#open_stack]
        return position_name(text, unclosed.start, first_line) .. (': <%s> is never closed'):format(tag_name(unclosed.text))
    end
    if root_count > 1 then
        return 'more than one root element'
    end
    return nil
end

-- pretty: one tag per line, depth-indented. text-only elements stay on one
-- line (<name>text</name>). linearized: remove whitespace between tags. keep
-- text inside elements, trimming only its ends. basically we tidy the edges
-- and leave the internal damage alone. (i have been doing this for years.)
-- indentation grows with depth, so 15,000 nested tags in 105 kb became a
-- 225 mb buffer. past this depth, refuse. some structures should not be
-- encouraged. i was one.
local MAXIMUM_XML_DEPTH = 1000

local function format_xml(nodes, pretty)
    local unit = indent_unit()
    local lines, depth = {}, 0
    local index = 1
    while index <= #nodes do
        local node = nodes[index]
        local trimmed = vim.trim(node.text)
        if node.kind == 'text' then
            if trimmed ~= '' then
                lines[#lines + 1] = string.rep(unit, depth) .. trimmed
            end
        elseif node.kind == 'open' then
            local text_node, close_node = nodes[index + 1], nodes[index + 2]
            local holds_only_text = text_node
                and text_node.kind == 'text'
                and close_node
                and close_node.kind == 'close'
                and tag_name(close_node.text) == tag_name(node.text)
            local holds_nothing = text_node and text_node.kind == 'close' and tag_name(text_node.text) == tag_name(node.text)
            if holds_only_text then
                -- keep the element's text value exactly, spaces & all, unless
                -- it is entirely whitespace. emptiness gets deleted. i should
                -- be worried.
                local value = vim.trim(text_node.text) == '' and '' or text_node.text
                lines[#lines + 1] = string.rep(unit, depth) .. node.text .. value .. close_node.text
                index = index + 2
            elseif holds_nothing then
                lines[#lines + 1] = string.rep(unit, depth) .. node.text .. text_node.text
                index = index + 1
            else
                lines[#lines + 1] = string.rep(unit, depth) .. node.text
                depth = depth + 1
                if depth > MAXIMUM_XML_DEPTH then
                    return nil
                end
            end
        elseif node.kind == 'close' then
            depth = math.max(0, depth - 1)
            lines[#lines + 1] = string.rep(unit, depth) .. node.text
        else
            lines[#lines + 1] = string.rep(unit, depth) .. node.text
        end
        index = index + 1
    end
    if pretty then
        return table.concat(lines, '\n')
    end
    for line_index, line in ipairs(lines) do
        lines[line_index] = vim.trim(line)
    end
    return table.concat(lines)
end

local function xml_command(pretty)
    local text, replace_with, first_line = target_text()
    local problem = xml_problem(text, first_line)
    if problem then
        return helpers.warn('XML is not well formed, nothing changed: ' .. problem)
    end
    local formatted = format_xml(assert(xml_nodes(text), 'checked above'), pretty)
    if not formatted then
        return helpers.warn(('XML is nested deeper than %d levels, nothing changed.'):format(MAXIMUM_XML_DEPTH))
    end
    replace_with(formatted)
end

function json_and_xml_tools.format_xml()
    xml_command(true)
end

function json_and_xml_tools.linearize_xml()
    xml_command(false)
end

function json_and_xml_tools.check_xml()
    local text, _, first_line = target_text()
    local problem = xml_problem(text, first_line)
    helpers.notify(problem and ('XML is not well formed: ' .. problem) or 'XML is well formed.', problem and vim.log.levels.WARN or nil)
end

return json_and_xml_tools
