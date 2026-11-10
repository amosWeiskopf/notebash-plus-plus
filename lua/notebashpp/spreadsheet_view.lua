-- csv and tsv open as a spreadsheet: cells, a frozen header and row numbers,
-- like excel, for files of any size. a 5 gb csv opens at once; file_index.lua
-- counts in the background, making rows reachable as it goes. basically i can
-- open more work than i can survive.
--
-- only rows on screen live in the buffer. scrolling or changes redraw the
-- grid. edits sit beside the file until ctrl+s: changed cells in `edits`, row
-- order in `segments` (runs of original records plus added rows), column
-- order in `columns`. saving copies untouched runs byte for byte and rewrites
-- only changed rows. untouched quoting, line endings and number formats stay
-- exactly as they were. i want the damage limited to what i actually did (a
-- useful rule, discovered late).

local spreadsheet_view = {}
local api = vim.api
local file_index = require('notebashpp.file_index')
local helpers = require('notebashpp.helpers')
local json_lines = require('notebashpp.json_lines')

-- open sheets by buffer number, kept across live code reloads. apparently
-- even my state refuses to die.
spreadsheet_view.states = spreadsheet_view.states or {}
local states = spreadsheet_view.states

local namespace = api.nvim_create_namespace('notebashpp_spreadsheet')

local SAMPLE_RECORDS_FOR_WIDTHS = 1000
local NARROWEST_COLUMN = 3
local WIDEST_AUTOMATIC_COLUMN = 40
local NEW_COLUMN_WIDTH = 10
local SYNCHRONOUS_SAVE_BYTES = 256 * 1024 * 1024
local LARGEST_COPY_CELLS = 2000000
local QUICK_SEARCH_ROWS = 5000
-- a json lines file gets a column per key up to here. a log with more
-- distinct keys than this is not a table, it's a cry for help.
local MOST_KEY_COLUMNS = 1000
local ELLIPSIS = '…'
local LINE_BREAK_MARK = '¶'
local SEPARATOR = '│'

---------------------------------------------------------------------------
-- reading & writing csv text
---------------------------------------------------------------------------

-- split one record into values and each field's exact bytes. an opening quote
-- runs to its closing quote; two quotes mean one. keep anything between the
-- closing quote and next delimiter, as excel does. even the crap gets custody
-- of its original bytes.
---@return string[] values, string[] raw_fields
local function split_fields(record, delimiter)
    local values, raw_fields = {}, {}
    local position, length = 1, #record
    while true do
        local field_start = position
        if record:byte(position) == 34 then
            local pieces = {}
            local scan_position = position + 1
            while true do
                local quote_position = record:find('"', scan_position, true)
                if not quote_position then
                    pieces[#pieces + 1] = record:sub(scan_position)
                    position = length + 1
                    break
                end
                pieces[#pieces + 1] = record:sub(scan_position, quote_position - 1)
                if record:byte(quote_position + 1) == 34 then
                    pieces[#pieces + 1] = '"'
                    scan_position = quote_position + 2
                else
                    position = quote_position + 1
                    break
                end
            end
            local delimiter_position = record:find(delimiter, position, true)
            local field_end = delimiter_position and delimiter_position - 1 or length
            if field_end >= position then
                pieces[#pieces + 1] = record:sub(position, field_end)
            end
            values[#values + 1] = table.concat(pieces)
            raw_fields[#raw_fields + 1] = record:sub(field_start, field_end)
            if not delimiter_position then
                break
            end
            position = delimiter_position + 1
        else
            local delimiter_position = record:find(delimiter, position, true)
            local field_end = delimiter_position and delimiter_position - 1 or length
            local raw_field = record:sub(position, field_end)
            values[#values + 1] = raw_field
            raw_fields[#raw_fields + 1] = raw_field
            if not delimiter_position then
                break
            end
            position = delimiter_position + 1
        end
    end
    return values, raw_fields
end
spreadsheet_view.split_fields = split_fields

-- quote only when needed, as excel writes csv. enough paperwork in hell.
local function quote_field(value, delimiter)
    if value:find('["\r\n]') or value:find(delimiter, 1, true) then
        return '"' .. value:gsub('"', '""') .. '"'
    end
    return value
end

-- split spreadsheet clipboard text into rows of values: tab separated, quoted
-- for tabs, quotes or line breaks inside values. even shit has boundaries.
local function split_tab_separated(text)
    local rows = {}
    local position, length = 1, #text
    local record_start = 1
    local inside_quotes = false
    while position <= length do
        local character = text:byte(position)
        if inside_quotes then
            if character == 34 then
                if text:byte(position + 1) == 34 then
                    position = position + 1
                else
                    inside_quotes = false
                end
            end
        elseif character == 34 and (position == record_start or text:byte(position - 1) == 9) then
            inside_quotes = true
        elseif character == 10 then
            local record = text:sub(record_start, position - 1):gsub('\r$', '')
            rows[#rows + 1] = (split_fields(record, '\t'))
            record_start = position + 1
        end
        position = position + 1
    end
    if record_start <= length then
        local record = text:sub(record_start):gsub('\r$', '')
        rows[#rows + 1] = (split_fields(record, '\t'))
    end
    return rows
end

local function is_valid_utf8(text)
    local position, length = 1, #text
    while position <= length do
        local next_high = text:find('[\128-\255]', position)
        if not next_high then
            return true
        end
        local first = text:byte(next_high)
        local sequence_length = first >= 240 and first <= 244 and 4 or first >= 224 and 3 or first >= 194 and first <= 223 and 2 or 0
        if sequence_length == 0 or first > 244 then
            return false
        end
        if next_high + sequence_length - 1 > length then
            -- sample ends mid-character. shit happens mid-life too.
            return true
        end
        for continuation = next_high + 1, next_high + sequence_length - 1 do
            local byte = text:byte(continuation)
            if byte < 128 or byte > 191 then
                return false
            end
        end
        position = next_high + sequence_length
    end
    return true
end

-- detect separator, line ending, byte order mark & encoding from the first 64
-- kb. .tsv and .tab use tabs. for .csv, pick comma, semicolon, tab or pipe by
-- which has a consistent count on most first lines (european excel writes
-- semicolons). i wanted a separator. now i'm investigating a damn crime
-- scene.
local function detect_format(path)
    local file = io.open(path, 'rb')
    local sample = file and file:read(65536) or ''
    if file then
        file:close()
    end
    local format = { bom = sample:sub(1, 3) == '\239\187\191' }
    if format.bom then
        sample = sample:sub(4)
    end
    format.line_ending = sample:find('\r\n', 1, true) and '\r\n' or '\n'
    local extension = (path:match('%.([^./\\]+)$') or ''):lower()
    if extension == 'tsv' or extension == 'tab' then
        format.delimiter = '\t'
    else
        local sample_lines = vim.split(sample:gsub('"[^"]*"', ''), '\n', { plain = true })
        if #sample_lines > 1 then
            table.remove(sample_lines)
        end
        local best_delimiter, best_score = ',', -1
        for _, candidate in ipairs({ ',', ';', '\t', '|' }) do
            local first_count = select(2, (sample_lines[1] or ''):gsub(vim.pesc(candidate), ''))
            local score = 0
            if first_count > 0 then
                for line_number = 1, math.min(#sample_lines, 20) do
                    if select(2, sample_lines[line_number]:gsub(vim.pesc(candidate), '')) == first_count then
                        score = score + 1
                    end
                end
            end
            if score > best_score then
                best_delimiter, best_score = candidate, score
            end
        end
        format.delimiter = best_delimiter
    end
    format.encoding = 'utf-8'
    if not is_valid_utf8(sample) then
        -- use the first 8-bit encoding listed in 'fileencodings', as neovim
        -- would read it. inherit the family crap.
        format.encoding = 'latin1'
        for encoding in vim.o.fileencodings:gmatch('[^,]+') do
            if encoding ~= 'ucs-bom' and encoding ~= 'utf-8' and encoding ~= 'default' then
                format.encoding = encoding
                break
            end
        end
    end
    return format
end

local JSON_LINES_EXTENSIONS = { jsonl = true, ndjson = true }

-- json lines are utf-8 by definition (rfc 8259 says so, and i'm not
-- arguing with an rfc at my age). only the byte order mark & line ending
-- need looking at.
local function detect_json_lines_format(path)
    local file = io.open(path, 'rb')
    local sample = file and file:read(65536) or ''
    if file then
        file:close()
    end
    return {
        bom = sample:sub(1, 3) == '\239\187\191',
        line_ending = sample:find('\r\n', 1, true) and '\r\n' or '\n',
        delimiter = ',',
        encoding = 'utf-8',
    }
end

local function to_display_encoding(state, text)
    if state.encoding == 'utf-8' then
        return text
    end
    return vim.iconv(text, state.encoding, 'utf-8') or text
end

-- nil when `text` has characters the file's encoding can't hold. writing the
-- utf-8 bytes into a latin1 file anyway is how mojibake is born. i refuse to
-- father anything else.
local function to_file_encoding(state, text)
    if state.encoding == 'utf-8' then
        return text
    end
    -- iconv swaps what it can't convert for a stand-in character. converting
    -- back shows the swap. lies are easier to spot in reverse, ask my bank.
    local converted = vim.iconv(text, 'utf-8', state.encoding)
    if not converted or vim.iconv(converted, state.encoding, 'utf-8') ~= text then
        return nil
    end
    return converted
end

---------------------------------------------------------------------------
-- rows, columns & cells
---------------------------------------------------------------------------

---@class notebashpp.sheet_segment
---@field first? integer first record of a run of the file's records
---@field last? integer last record of the run; nil means to the end
---@field refs? (integer|table)[] single rows

-- a segment is { first = n, last = m }: file records n to m; last nil means
-- through the end, still being counted. or { refs = { ... } }: single rows,
-- each a record number or a table for an added row. basically a filing system
-- for time i'll never get back.
local function segment_length(state, segment)
    if segment.refs then
        return #segment.refs
    end
    local last = segment.last or (state.index.record_count - 1)
    return math.max(0, last - segment.first + 1)
end

local function segment_starts(state, segments)
    if segments == state.segments and state.segment_starts then
        return state.segment_starts
    end
    local starts, row_number = {}, 0
    for segment_number, segment in ipairs(segments) do
        starts[segment_number] = row_number
        if segment_number < #segments then
            row_number = row_number + segment_length(state, segment)
        end
    end
    if segments == state.segments then
        state.segment_starts = starts
    end
    return starts
end

local function count_rows(state, segments)
    segments = segments or state.segments
    if #segments == 0 then
        return 0
    end
    local starts = segment_starts(state, segments)
    return starts[#segments] + segment_length(state, segments[#segments])
end

-- find the segment & offset for data row `row_number` (0-based). where the
-- hell am i, exactly.
local function locate_row(state, segments, row_number)
    local starts = segment_starts(state, segments)
    local low, high = 1, #segments
    if high == 0 then
        return nil
    end
    while low < high do
        local middle = math.floor((low + high + 1) / 2)
        if starts[middle] <= row_number then
            low = middle
        else
            high = middle - 1
        end
    end
    local offset = row_number - starts[low]
    if offset < 0 or offset >= segment_length(state, segments[low]) then
        return nil
    end
    return low, offset
end

-- row `row_number` shows a record number or a new row's table. row -1 is the
-- header, if present. even this shit has a head.
local function row_ref(state, row_number)
    if row_number == -1 then
        return state.header_ref
    end
    local segment_number, offset = locate_row(state, state.segments, row_number)
    if not segment_number then
        return nil
    end
    local segment = state.segments[segment_number]
    if segment.refs then
        return segment.refs[offset + 1]
    end
    return segment.first + offset
end

-- copy `segments`, cutting so a segment starts at `row_number`. return the
-- copy & that segment's position; at the end, one past it. i keep making room
-- for nothing.
---@param segments notebashpp.sheet_segment[]
---@return notebashpp.sheet_segment[], integer
local function split_segments_at(state, segments, row_number)
    local copy = vim.list_slice(segments)
    local total = count_rows(state, copy)
    if row_number >= total then
        return copy, #copy + 1
    end
    local segment_number, offset = locate_row(state, copy, row_number)
    if not segment_number then
        return copy, #copy + 1
    end
    if offset == 0 then
        return copy, segment_number
    end
    local segment = copy[segment_number]
    local left, right
    if segment.refs then
        left = { refs = vim.list_slice(segment.refs, 1, offset) }
        right = { refs = vim.list_slice(segment.refs, offset + 1) }
    else
        left = { first = segment.first, last = segment.first + offset - 1 }
        right = { first = segment.first + offset, last = segment.last }
    end
    copy[segment_number] = left
    table.insert(copy, segment_number + 1, right)
    return copy, segment_number + 1
end

local function remove_rows(state, segments, first_row, last_row)
    local cut_at_first, first_position = split_segments_at(state, segments, first_row)
    local cut_at_last, end_position = split_segments_at(state, cut_at_first, last_row + 1)
    local kept = {}
    for segment_number, segment in ipairs(cut_at_last) do
        if segment_number < first_position or segment_number >= end_position then
            kept[#kept + 1] = segment
        end
    end
    return kept
end

local function insert_refs(state, segments, row_number, refs)
    local copy, position = split_segments_at(state, segments, row_number)
    table.insert(copy, position, { refs = refs })
    return copy
end

local function display_text(value)
    if value:find('%c') then
        value = value:gsub('\r\n', LINE_BREAK_MARK):gsub('[\r\n]', LINE_BREAK_MARK):gsub('\t', ' '):gsub('%c', '?')
    end
    return value
end

local PARSED_RECORDS_KEPT = 20000
-- and at most this many bytes of row text, so 20,000 rows of a megabyte
-- each don't move in. my flat has the same policy about relatives.
local PARSED_BYTES_KEPT = 48 * 1024 * 1024

local function automatic_width(text)
    return math.max(NARROWEST_COLUMN, math.min(WIDEST_AUTOMATIC_COLUMN, api.nvim_strwidth(display_text(text))))
end

-- json lines columns are keys. every key gets a positive column id the
-- first time anybody names it, the file or me. state.discovered marks the
-- ones some line of the file has; only the others can be deleted. a key the
-- file owns is not mine to take away. a landlord explained that concept to
-- me once, slowly.
local function register_key(state, key)
    local column_id = state.key_ids[key]
    if column_id == nil then
        state.key_column_count = state.key_column_count + 1
        column_id = state.key_column_count
        state.key_ids[key], state.key_names[column_id] = column_id, key
    end
    return column_id
end

-- a key read from the file. new keys join at the right end, so the caret's
-- column never moves under it. returns the column id, or nil past the column
-- limit. at the right end is also where i sit at family dinners.
local function discover_key(state, key, value_text)
    local column_id = state.key_ids[key]
    if column_id == nil and state.key_column_count >= MOST_KEY_COLUMNS then
        if not state.warned_about_keys then
            state.warned_about_keys = true
            vim.schedule(function()
                helpers.warn(
                    ('This file has more than %d different keys; the rest are not shown as columns. Open it as text to see them.'):format(MOST_KEY_COLUMNS)
                )
            end)
        end
        return nil
    end
    column_id = register_key(state, key)
    if not state.discovered[column_id] then
        state.discovered[column_id] = true
        if not vim.tbl_contains(state.columns, column_id) then
            -- the nameless stand-in column drawn before any key turned up
            -- makes way for the first real one. it was only ever a
            -- placeholder. i know the feeling.
            local columns = vim.list_slice(state.columns)
            if #columns == 1 and columns[1] < 0 and state.key_names[columns[1]] == nil then
                columns = {}
            end
            columns[#columns + 1] = column_id
            state.columns = columns
            state.widths[column_id] = state.widths[column_id] or math.max(automatic_width(key), automatic_width(value_text))
        end
    end
    return column_id
end

local function remember_parsed(state, record_number, entry, byte_count)
    state.parsed_count = state.parsed_count + 1
    state.parsed_bytes = (state.parsed_bytes or 0) + byte_count
    if state.parsed_count > PARSED_RECORDS_KEPT or state.parsed_bytes > PARSED_BYTES_KEPT then
        state.parsed, state.parsed_count, state.parsed_bytes = {}, 1, byte_count
    end
    state.parsed[record_number] = entry
end

-- cache record values (display encoding) & raw fields. hoard the damn past.
-- a json lines entry keeps the line's text & its parse instead of raw fields:
-- the edit rewrites spans of that text.
local function parsed_record(state, record_number)
    local cached = state.parsed[record_number]
    if cached then
        return cached
    end
    local text, was_cut = state.index:record(record_number)
    if not text then
        return nil
    end
    if record_number == 0 and state.bom then
        text = text:gsub('^\239\187\191', '')
    end
    if state.json_lines then
        local parsed = json_lines.parse_line(text)
        local json_entry = { text = text, parsed = parsed, values = {}, cut = was_cut }
        if parsed.kind == 'object' then
            for _, member in ipairs(parsed.members) do
                local value_text = json_lines.cell_text(text, member)
                local column_id = discover_key(state, member.key, value_text)
                if column_id then
                    json_entry.values[column_id] = value_text
                end
            end
        end
        remember_parsed(state, record_number, json_entry, #text)
        return json_entry
    end
    local values, raw_fields = split_fields(text, state.delimiter)
    if state.encoding ~= 'utf-8' then
        for value_number, value in ipairs(values) do
            values[value_number] = to_display_encoding(state, value)
        end
    end
    local entry = { values = values, raw_fields = raw_fields, cut = was_cut }
    remember_parsed(state, record_number, entry, #text)
    -- a row wider than all previous rows adds columns at the end. more crap
    -- to own.
    if #values > state.widest_record then
        local columns = vim.list_slice(state.columns)
        for column_id = state.widest_record + 1, #values do
            columns[#columns + 1] = column_id
            local width = api.nvim_strwidth(display_text(values[column_id]))
            state.widths[column_id] = state.widths[column_id] or math.max(NARROWEST_COLUMN, math.min(WIDEST_AUTOMATIC_COLUMN, width))
        end
        state.widest_record = #values
        state.columns = columns
    end
    return entry
end

-- the file record behind a row: its number, the record a duplicated row was
-- copied from, or nil for a row i added. everyone's a copy of somebody.
local function record_of_ref(ref)
    if type(ref) == 'number' then
        return ref
    end
    if type(ref) == 'table' then
        return ref.copy_of
    end
    return nil
end

local function json_entry_of(state, ref)
    local record_number = record_of_ref(ref)
    return record_number and parsed_record(state, record_number) or nil
end

-- a line that isn't a json object has no keys. its whole text sits in the
-- first column, edits to it under the pseudo column 'raw'. not every line
-- gets to be what it was supposed to be.
local function json_cell_value(state, ref, column_id)
    local row_edits = state.edits[ref]
    local entry = json_entry_of(state, ref)
    if entry and entry.parsed.kind == 'other' then
        if column_id ~= state.columns[1] then
            return '', false
        end
        if row_edits and row_edits.raw ~= nil then
            return row_edits.raw, true
        end
        return entry.text, false
    end
    if row_edits and row_edits[column_id] ~= nil then
        return row_edits[column_id], true
    end
    return entry and entry.values[column_id] or '', false
end

-- cell value & whether i changed it here. evidence.
local function cell_value(state, ref, column_id)
    if ref == nil or column_id == nil then
        return '', false
    end
    if state.json_lines then
        return json_cell_value(state, ref, column_id)
    end
    local row_edits = state.edits[ref]
    if row_edits and row_edits[column_id] ~= nil then
        return row_edits[column_id], true
    end
    if type(ref) == 'number' and column_id > 0 then
        local entry = parsed_record(state, ref)
        return entry and entry.values[column_id] or '', false
    end
    return '', false
end

local function column_letters(position)
    local letters = ''
    while position > 0 do
        local remainder = (position - 1) % 26
        letters = string.char(65 + remainder) .. letters
        position = math.floor((position - 1) / 26)
    end
    return letters
end

local function header_text(state, column_position)
    if state.columns[column_position] == nil then
        return ''
    end
    if state.json_lines then
        return state.key_names[state.columns[column_position]] or ''
    end
    if state.header_ref ~= nil then
        return (cell_value(state, state.header_ref, state.columns[column_position]))
    end
    return column_letters(column_position)
end

local function looks_numeric(value)
    return value:find('^%s*[%-+]?[%d,]*%.?%d+%%?%s*$') ~= nil
end

-- cut or pad `text` to exactly `width` screen cells. forced to fit.
local function fit(text, width, align_right)
    local text_width = api.nvim_strwidth(text)
    if text_width > width then
        local byte_limit = width * 4 + 4
        if #text > byte_limit then
            text = text:sub(1, byte_limit + vim.str_utf_start(text, byte_limit + 1))
        end
        local characters = vim.fn.strchars(text)
        text = vim.fn.strcharpart(text, 0, math.min(characters, width))
        while api.nvim_strwidth(text) > width - 1 and text ~= '' do
            text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
        end
        text = text .. ELLIPSIS
        text_width = api.nvim_strwidth(text)
    end
    local padding = string.rep(' ', width - text_width)
    return align_right and padding .. text or text .. padding
end

-- widths from the header & first 1000 rows. judge the crap early.
local function measure_widths(state)
    local sample_end = math.min(state.index.record_count, SAMPLE_RECORDS_FOR_WIDTHS) - 1
    local widths = {}
    for record_number = 0, sample_end do
        local entry = parsed_record(state, record_number)
        if entry then
            for column_id, value in pairs(entry.values) do
                local width = api.nvim_strwidth(display_text(value))
                if width > (widths[column_id] or 0) then
                    widths[column_id] = width
                end
            end
        end
    end
    -- a key's name is its header, so it counts toward the width too.
    if state.json_lines then
        for _, column_id in ipairs(state.columns) do
            local key = state.key_names[column_id]
            if key then
                widths[column_id] = math.max(widths[column_id] or 0, api.nvim_strwidth(display_text(key)))
            end
        end
    end
    for column_id, width in pairs(widths) do
        if not state.width_set_by_user[column_id] then
            state.widths[column_id] = math.max(NARROWEST_COLUMN, math.min(WIDEST_AUTOMATIC_COLUMN, width))
        end
    end
    state.widths_measured = state.index.complete or state.index.record_count >= SAMPLE_RECORDS_FOR_WIDTHS
end

---------------------------------------------------------------------------
-- drawing
---------------------------------------------------------------------------

local function window_for(state)
    local current_window = api.nvim_get_current_win()
    if api.nvim_win_get_buf(current_window) == state.buffer then
        return current_window
    end
    local window = vim.fn.bufwinid(state.buffer)
    return window ~= -1 and window or nil
end

local function first_row(state)
    return state.header_ref ~= nil and -1 or 0
end

-- a json lines file with no keys yet (empty, or only lines that aren't
-- objects) still needs one column to show anything in. it has no key until
-- somebody names it. a column waiting for a name. aren't we all.
local function ensure_json_column(state)
    if state.json_lines and #state.columns == 0 then
        local column_id = state.next_new_column_id
        state.next_new_column_id = column_id - 1
        state.columns = { column_id }
        state.widths[column_id] = NEW_COLUMN_WIDTH
    end
end

-- the key a cell may be edited under: its column's id, 'raw' for the text of
-- a line that isn't an object (first column only), or nil if the cell can't
-- take an edit (a column with no key, the other cells of such a line).
local function json_edit_column(state, ref, column_id)
    local entry = json_entry_of(state, ref)
    if entry and entry.parsed.kind == 'other' then
        return column_id == state.columns[1] and 'raw' or nil
    end
    if column_id == nil or state.key_names[column_id] == nil then
        return nil
    end
    return column_id
end

local function selection_bounds(state)
    if not state.anchor then
        return nil
    end
    return {
        first_row = math.min(state.anchor.row, state.cursor_row),
        last_row = math.max(state.anchor.row, state.cursor_row),
        first_column = math.min(state.anchor.column, state.cursor_column),
        last_column = math.max(state.anchor.column, state.cursor_column),
    }
end

local function clamp_cursor(state)
    local total_rows = count_rows(state)
    -- a position requested before counting reaches it waits for its row: on
    -- opening, after saving or from a restored session. basically my
    -- retirement plan, except this might actually arrive.
    local pending = state.pending_position
    if pending then
        if total_rows > pending.row or state.index.complete then
            state.cursor_row, state.cursor_column = math.min(pending.row, math.max(total_rows - 1, 0)), pending.column
            state.top_row, state.first_column = math.min(pending.top_row, math.max(total_rows - 1, 0)), pending.first_column
            state.pending_position = nil
        else
            return
        end
    end
    state.cursor_row = math.max(first_row(state), math.min(state.cursor_row, math.max(total_rows - 1, first_row(state))))
    state.cursor_column = math.max(1, math.min(state.cursor_column, math.max(#state.columns, 1)))
end

local function apply_window_options(window)
    for option_name, value in pairs({
        wrap = false,
        number = false,
        relativenumber = false,
        signcolumn = 'no',
        foldcolumn = '0',
        statuscolumn = '',
        list = false,
        spell = false,
        cursorline = true,
        scrolloff = 0,
        sidescrolloff = 0,
        conceallevel = 0,
    }) do
        api.nvim_set_option_value(option_name, value, { scope = 'local', win = window })
    end
end

-- draw the visible grid into the buffer; put the caret on the current cell. i
-- want at least one thing to know where it belongs.
function spreadsheet_view.render(state)
    local window = window_for(state)
    if not window or not api.nvim_buf_is_valid(state.buffer) then
        return
    end
    if not state.widths_measured then
        measure_widths(state)
    end
    ensure_json_column(state)
    clamp_cursor(state)
    local window_width = api.nvim_win_get_width(window)
    local data_height = math.max(1, api.nvim_win_get_height(window) - 1)
    local total_rows = count_rows(state)
    if state.cursor_row >= 0 then
        if state.cursor_row < state.top_row then
            state.top_row = state.cursor_row
        elseif state.cursor_row >= state.top_row + data_height then
            state.top_row = state.cursor_row - data_height + 1
        end
    end
    state.top_row = math.max(0, math.min(state.top_row, math.max(0, total_rows - data_height)))
    local gutter_width = math.max(3, #tostring(math.max(total_rows, 1))) + 1
    -- scroll sideways to show the whole current column. more damn exposure.
    if state.cursor_column < state.first_column then
        state.first_column = state.cursor_column
    end
    -- walk left from the current column while columns still fit. the old way
    -- summed every column again for each step right: 100,000 columns took six
    -- seconds to press end. i've wasted time more creatively, but not often.
    local fitting_first, fitting_width = state.cursor_column, gutter_width + 1 + (state.widths[state.columns[state.cursor_column]] or NEW_COLUMN_WIDTH) + 3
    while fitting_first > state.first_column do
        local wider = fitting_width + (state.widths[state.columns[fitting_first - 1]] or NEW_COLUMN_WIDTH) + 3
        if wider > window_width then
            break
        end
        fitting_first, fitting_width = fitting_first - 1, wider
    end
    state.first_column = math.max(state.first_column, fitting_first)
    state.first_column = math.max(1, math.min(state.first_column, math.max(#state.columns, 1)))

    -- columns grow for visible rows, never shrink, up to 40. my expenses,
    -- capped. only columns that fit on screen are measured; the rest wait
    -- their turn, like everything else in my life.
    local visible_refs = {}
    for line_offset = 0, data_height - 1 do
        local row_number = state.top_row + line_offset
        if row_number >= total_rows then
            break
        end
        visible_refs[#visible_refs + 1] = row_ref(state, row_number)
    end
    local visible_positions = {}
    local column_starts = {}
    local display_column = gutter_width + 1
    for position = state.first_column, #state.columns do
        if display_column >= window_width then
            break
        end
        local column_id = state.columns[position]
        if not state.width_set_by_user[column_id] then
            for _, ref in ipairs(visible_refs) do
                local value = cell_value(state, ref, column_id)
                if #value > (state.widths[column_id] or 0) or value:find('[\128-\255]') then
                    local width = math.min(WIDEST_AUTOMATIC_COLUMN, api.nvim_strwidth(display_text(value)))
                    if width > (state.widths[column_id] or 0) then
                        state.widths[column_id] = width
                    end
                end
            end
        end
        visible_positions[#visible_positions + 1] = position
        column_starts[position] = display_column
        display_column = display_column + (state.widths[column_id] or NEW_COLUMN_WIDTH) + 3
    end

    local selection = selection_bounds(state)
    local lines, highlights, cell_bytes = {}, {}, {}
    local function add_line(row_number, ref)
        local line_number = #lines + 1
        local parts, byte_length = {}, 0
        local function append(text)
            parts[#parts + 1] = text
            byte_length = byte_length + #text
        end
        local row_entry
        if state.json_lines then
            row_entry = row_number ~= -1 and json_entry_of(state, ref) or nil
        else
            row_entry = type(ref) == 'number' and parsed_record(state, ref) or nil
        end
        -- a json lines line that isn't an object gets a ! after its row
        -- number: visible without colour. the shame of it, legible in
        -- monochrome.
        local is_not_object = row_entry ~= nil and row_entry.parsed ~= nil and row_entry.parsed.kind == 'other'
        local gutter_text
        if row_number == -1 then
            gutter_text = string.rep(' ', gutter_width)
        else
            gutter_text = fit(tostring(row_number + 1), gutter_width - 1, true) .. (is_not_object and '!' or ' ')
        end
        append(gutter_text)
        highlights[#highlights + 1] = {
            line_number,
            0,
            byte_length,
            row_number == -1 and 'NotebashSheetHeader' or is_not_object and 'NotebashSheetInvalid' or 'NotebashSheetRowNumber',
        }
        cell_bytes[line_number] = {}
        for _, position in ipairs(visible_positions) do
            local column_id = state.columns[position]
            local width = state.widths[column_id] or NEW_COLUMN_WIDTH
            local text, edited
            if row_number == -1 then
                text, edited = header_text(state, position), false
                if state.header_ref ~= nil then
                    edited = select(2, cell_value(state, state.header_ref, column_id))
                end
            else
                text, edited = cell_value(state, ref, column_id)
            end
            text = display_text(text)
            local cell_start = byte_length
            append(' ')
            local content_start = byte_length
            append(fit(text, width, row_number ~= -1 and looks_numeric(text)))
            local content_end = byte_length
            append(' ')
            local cell_end = byte_length
            append(SEPARATOR)
            highlights[#highlights + 1] = { line_number, cell_end, byte_length, 'NotebashSheetGrid' }
            cell_bytes[line_number][position] = { content_start, content_end }
            local is_current = row_number == state.cursor_row and position == state.cursor_column
            local is_selected = selection
                and row_number >= selection.first_row
                and row_number <= selection.last_row
                and position >= selection.first_column
                and position <= selection.last_column
            if is_current then
                highlights[#highlights + 1] = { line_number, cell_start, cell_end, 'NotebashSheetCurrent' }
            elseif is_selected then
                highlights[#highlights + 1] = { line_number, cell_start, cell_end, 'NotebashSheetSelection' }
            elseif row_number == -1 then
                highlights[#highlights + 1] = { line_number, cell_start, cell_end, 'NotebashSheetHeader' }
            end
            if edited then
                highlights[#highlights + 1] = { line_number, content_start, content_end, 'NotebashSheetEdited' }
            elseif is_not_object and position == 1 then
                highlights[#highlights + 1] = { line_number, content_start, content_end, 'NotebashSheetInvalid' }
            end
        end
        if row_entry and row_entry.cut then
            highlights[#highlights + 1] = { line_number, 0, #gutter_text, 'NotebashSheetEdited' }
        end
        lines[line_number] = table.concat(parts)
    end

    add_line(-1, state.header_ref)
    for line_offset = 0, data_height - 1 do
        local row_number = state.top_row + line_offset
        if row_number >= total_rows then
            break
        end
        add_line(row_number, row_ref(state, row_number))
    end

    state.layout = {
        window = window,
        gutter_width = gutter_width,
        column_starts = column_starts,
        visible_positions = visible_positions,
        cell_bytes = cell_bytes,
        data_height = data_height,
    }
    local buffer = state.buffer
    vim.bo[buffer].modifiable = true
    api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].modifiable = false
    vim.bo[buffer].modified = state.undo_steps[#state.undo_steps] ~= state.saved_step
    api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
    for _, highlight in ipairs(highlights) do
        if highlight[3] > highlight[2] then
            api.nvim_buf_set_extmark(buffer, namespace, highlight[1] - 1, highlight[2], {
                end_col = highlight[3],
                hl_group = highlight[4],
                priority = highlight[4] == 'NotebashSheetCurrent' and 200 or 150,
            })
        end
    end
    -- caret at the start of the current cell's text. afraid to commit.
    local caret_line = state.cursor_row == -1 and 1 or state.cursor_row - state.top_row + 2
    local caret_bytes = cell_bytes[caret_line] and cell_bytes[caret_line][state.cursor_column]
    local caret = { math.min(caret_line, #lines), caret_bytes and caret_bytes[1] or 0 }
    state.placed_caret = caret
    pcall(api.nvim_win_set_cursor, window, caret)
    if vim.bo[buffer].modified ~= state.shown_modified then
        state.shown_modified = vim.bo[buffer].modified
        vim.cmd('redrawtabline')
    end
    vim.cmd('redrawstatus')
end

local function render_soon(state)
    if state.render_scheduled then
        return
    end
    state.render_scheduled = true
    vim.schedule(function()
        state.render_scheduled = false
        if states[state.buffer] == state then
            spreadsheet_view.render(state)
        end
    end)
end

---------------------------------------------------------------------------
-- undo
---------------------------------------------------------------------------

local function layout_snapshot(state)
    return { segments = state.segments, columns = state.columns, header_ref = state.header_ref == nil and vim.NIL or state.header_ref }
end

-- keys found in the file after a snapshot was taken go back at the right
-- end. undo takes back what i did, not what the file told me since.
local function append_discovered_columns(state)
    local present, missing = {}, {}
    for _, column_id in ipairs(state.columns) do
        present[column_id] = true
    end
    for column_id in pairs(state.discovered) do
        if not present[column_id] then
            missing[#missing + 1] = column_id
        end
    end
    if #missing > 0 then
        table.sort(missing)
        local columns = vim.list_slice(state.columns)
        vim.list_extend(columns, missing)
        state.columns = columns
    end
end

local function restore_layout(state, snapshot)
    state.segments, state.columns = snapshot.segments, snapshot.columns
    if state.json_lines then
        append_discovered_columns(state)
    end
    -- vim.nil (json null) means "no header row" in a snapshot. absence needs
    -- id.
    state.header_ref = snapshot.header_ref ~= vim.NIL and snapshot.header_ref or nil
    state.segment_starts = nil
end

local function apply_cell_changes(state, changes, use_new_values)
    local first, last, step = 1, #changes, 1
    if not use_new_values then
        first, last, step = #changes, 1, -1
    end
    for change_number = first, last, step do
        local change = changes[change_number]
        local value = use_new_values and change.new or change.old
        local row_edits = state.edits[change.ref]
        if not row_edits then
            row_edits = {}
            state.edits[change.ref] = row_edits
        end
        row_edits[change.column_id] = value
        if next(row_edits) == nil then
            state.edits[change.ref] = nil
        end
    end
end

-- one undoable step: cell changes and/or new row or column layout. regret,
-- packaged.
local function commit_step(state, step)
    step.cursor_before = step.cursor_before or { state.cursor_row, state.cursor_column }
    if step.cells then
        apply_cell_changes(state, step.cells, true)
    end
    if step.layout_after then
        restore_layout(state, step.layout_after)
    end
    table.insert(state.undo_steps, step)
    state.redo_steps = {}
    render_soon(state)
end

local function editing_blocked(state)
    if state.saving then
        helpers.warn('Saving, one moment.')
        return true
    end
    return false
end

function spreadsheet_view.undo(state)
    local step = table.remove(state.undo_steps)
    if not step or editing_blocked(state) then
        if step then
            table.insert(state.undo_steps, step)
        end
        return
    end
    if step.layout_before then
        restore_layout(state, step.layout_before)
    end
    if step.cells then
        apply_cell_changes(state, step.cells, false)
    end
    table.insert(state.redo_steps, step)
    state.cursor_row, state.cursor_column = step.cursor_before[1], step.cursor_before[2]
    state.anchor = nil
    render_soon(state)
end

function spreadsheet_view.redo(state)
    local step = table.remove(state.redo_steps)
    if not step or editing_blocked(state) then
        if step then
            table.insert(state.redo_steps, step)
        end
        return
    end
    if step.cells then
        apply_cell_changes(state, step.cells, true)
    end
    if step.layout_after then
        restore_layout(state, step.layout_after)
    end
    table.insert(state.undo_steps, step)
    if step.cursor_after then
        state.cursor_row, state.cursor_column = step.cursor_after[1], step.cursor_after[2]
    end
    state.anchor = nil
    render_soon(state)
end

-- nil when the cell can't take the edit (json lines only). callers drop
-- nils. rejection, handled gracefully for once.
local function change_for(state, ref, column_id, new_value)
    if state.json_lines then
        column_id = json_edit_column(state, ref, column_id)
        if column_id == nil then
            return nil
        end
    end
    local row_edits = state.edits[ref]
    return { ref = ref, column_id = column_id, old = row_edits and row_edits[column_id], new = new_value }
end

---------------------------------------------------------------------------
-- moving around
---------------------------------------------------------------------------

local function move_to(state, row_number, column_position, extend_selection)
    -- a user move cancels the position waiting for counting. impatience wins
    -- again.
    state.pending_position = nil
    if extend_selection then
        state.anchor = state.anchor or { row = state.cursor_row, column = state.cursor_column }
    else
        state.anchor = nil
    end
    state.cursor_row, state.cursor_column = row_number, column_position
    clamp_cursor(state)
    spreadsheet_view.render(state)
end

-- ctrl+end while counting: go to the last row counted so far, then to the
-- real last row when counting ends. even the end comes in fucking
-- instalments.
local function wait_for_last_row(state, column_position)
    if state.index.complete then
        return
    end
    state.pending_position = { row = math.huge, column = column_position, top_row = math.huge, first_column = state.first_column }
    helpers.notify(('Counting rows (%d%%); going to the last one when done.'):format(state.index:percent_done()))
end

local function page_rows(state)
    return math.max(1, (state.layout and state.layout.data_height or 20) - 1)
end

local function last_row(state)
    return math.max(first_row(state), count_rows(state) - 1)
end

---------------------------------------------------------------------------
-- editing a cell
---------------------------------------------------------------------------

local function current_ref(state)
    return row_ref(state, state.cursor_row)
end

local function row_is_cut(state, ref)
    local record_number = record_of_ref(ref)
    if record_number == nil then
        return false
    end
    local entry = parsed_record(state, record_number)
    return entry ~= nil and entry.cut == true
end

-- ask for the key of a new json lines column. nil if cancelled or taken;
-- a taken key also returns its column id. names are hard. i named a plant
-- once and it died within the week.
local function ask_for_key(state)
    local key = helpers.ask('Key for this column: ', '')
    if key == '' then
        return nil
    end
    if state.key_ids[key] ~= nil then
        helpers.warn(('There is already a column for the key "%s".'):format(key))
        return nil, state.key_ids[key]
    end
    return key
end

-- json lines checks before a cell editor opens. false stops it. a column
-- with no key yet gets one first. bureaucracy, but for a good cause.
local function json_cell_editable(state, ref)
    ensure_json_column(state)
    local column_id = state.columns[state.cursor_column]
    local entry = json_entry_of(state, ref)
    if entry and entry.parsed.kind == 'other' then
        if state.cursor_column ~= 1 then
            helpers.warn('This line is not a JSON object, so it has no keys. Its text is in the first column.')
            return false
        end
        return true
    end
    if state.key_names[column_id] == nil then
        local key = ask_for_key(state)
        if not key then
            return false
        end
        state.key_ids[key], state.key_names[column_id] = column_id, key
    end
    return true
end

local function finish_editing(state, keep_text, then_move)
    local editor = state.editor
    if not editor then
        return
    end
    state.editor = nil
    local text
    if keep_text and api.nvim_buf_is_valid(editor.buffer) then
        text = table.concat(api.nvim_buf_get_lines(editor.buffer, 0, -1, false), editor.line_break)
    end
    if api.nvim_win_is_valid(editor.window) then
        api.nvim_win_close(editor.window, true)
    end
    vim.cmd.stopinsert()
    if api.nvim_win_is_valid(editor.grid_window) then
        api.nvim_set_current_win(editor.grid_window)
    end
    if text ~= nil and text ~= editor.original then
        -- typing in the empty row below the last adds a row. crap breeds.
        local ref = editor.ref == nil and {} or editor.ref
        local change = change_for(state, ref, editor.column_id, text)
        if change and editor.ref == nil then
            commit_step(state, {
                layout_before = layout_snapshot(state),
                layout_after = {
                    segments = insert_refs(state, state.segments, count_rows(state), { ref }),
                    columns = state.columns,
                    header_ref = layout_snapshot(state).header_ref,
                },
                cells = { change },
                cursor_before = { editor.row, editor.column },
            })
        elseif change then
            commit_step(state, { cells = { change }, cursor_before = { editor.row, editor.column } })
        end
    end
    if then_move then
        then_move()
    end
    spreadsheet_view.render(state)
end

-- open a small editor over the current cell. `initial_text` replaces the
-- value (typing over it); nil edits it (f2, double click). a tiny room where
-- i can make the damage personal.
function spreadsheet_view.edit_cell(state, initial_text)
    if editing_blocked(state) or state.editor then
        return
    end
    if #state.columns == 0 and not state.json_lines then
        state.columns, state.widest_record = { 1 }, math.max(state.widest_record, 1)
        state.widths[1] = state.widths[1] or NEW_COLUMN_WIDTH
    end
    local ref = current_ref(state)
    if state.cursor_row == -1 and ref == nil then
        return helpers.warn('This file has no header row. Turn it on in Plugins > Spreadsheet.')
    end
    if row_is_cut(state, ref) then
        return helpers.warn('This row is longer than 1 MB. Open the file as text to edit it.')
    end
    if state.json_lines and not json_cell_editable(state, ref) then
        return
    end
    spreadsheet_view.render(state)
    local layout = state.layout
    local column_id = state.columns[state.cursor_column]
    local original = (cell_value(state, ref, column_id))
    local text = initial_text or original
    local line_break = text:find('\r\n', 1, true) and '\r\n' or '\n'
    local lines = vim.split(text, line_break, { plain = true })
    local grid_window = layout.window
    local caret_line = state.cursor_row == -1 and 1 or state.cursor_row - state.top_row + 2
    local column_start = layout.column_starts[state.cursor_column] or (layout.gutter_width + 1)
    local window_width = api.nvim_win_get_width(grid_window)
    local widest_line = 0
    for _, line in ipairs(lines) do
        widest_line = math.max(widest_line, api.nvim_strwidth(line))
    end
    local editor_column = math.max(0, column_start - 1)
    local editor_width = math.max((state.widths[column_id] or NEW_COLUMN_WIDTH) + 2, widest_line + 2, 12)
    if editor_column + editor_width > window_width then
        editor_width = math.min(editor_width, window_width)
        editor_column = math.max(0, window_width - editor_width)
    end
    local screen_rows = 0
    for _, line in ipairs(lines) do
        screen_rows = screen_rows + math.max(1, math.ceil(api.nvim_strwidth(line) / editor_width))
    end
    local editor_height = math.max(1, math.min(screen_rows, 10, api.nvim_win_get_height(grid_window) - caret_line + 1))
    local editor_buffer = api.nvim_create_buf(false, true)
    vim.bo[editor_buffer].bufhidden = 'wipe'
    api.nvim_buf_set_lines(editor_buffer, 0, -1, false, lines)
    local editor_window = api.nvim_open_win(editor_buffer, true, {
        relative = 'win',
        win = grid_window,
        row = caret_line - 1,
        col = editor_column,
        width = editor_width,
        height = editor_height,
        style = 'minimal',
        zindex = 60,
    })
    vim.wo[editor_window].wrap = true
    vim.wo[editor_window].winhighlight = 'Normal:NotebashSheetEditor,NormalFloat:NotebashSheetEditor'
    state.editor = {
        buffer = editor_buffer,
        window = editor_window,
        grid_window = grid_window,
        ref = ref,
        column_id = column_id,
        row = state.cursor_row,
        column = state.cursor_column,
        original = original,
        line_break = line_break,
    }
    api.nvim_win_set_cursor(editor_window, { #lines, #lines[#lines] })
    vim.cmd.startinsert({ bang = true })

    local function map(keys, action)
        vim.keymap.set({ 'i', 'n', 's', 'x' }, keys, action, { buffer = editor_buffer, nowait = true, silent = true })
    end
    local function move_after(row_step, column_step)
        return function()
            finish_editing(state, true, function()
                local next_row = state.cursor_row + row_step
                if row_step > 0 and state.cursor_row == -1 then
                    next_row = 0
                end
                state.cursor_row = next_row
                state.cursor_column = math.max(1, math.min(#state.columns, state.cursor_column + column_step))
                state.anchor = nil
            end)
        end
    end
    map('<CR>', move_after(1, 0))
    map('<S-CR>', move_after(-1, 0))
    map('<Tab>', move_after(0, 1))
    map('<S-Tab>', move_after(0, -1))
    map('<Esc>', function()
        finish_editing(state, false)
    end)
    -- alt+enter adds a line break inside the cell, as in excel. a smaller
    -- prison.
    map('<M-CR>', function()
        local cursor = api.nvim_win_get_cursor(0)
        local line = api.nvim_get_current_line()
        api.nvim_buf_set_lines(0, cursor[1] - 1, cursor[1], false, { line:sub(1, cursor[2]), line:sub(cursor[2] + 1) })
        api.nvim_win_set_cursor(0, { cursor[1] + 1, 0 })
        local window_config = api.nvim_win_get_config(0)
        if window_config.height < 10 then
            api.nvim_win_set_height(0, window_config.height + 1)
        end
    end)
    map('<C-s>', function()
        finish_editing(state, true)
        spreadsheet_view.save(state)
    end)
    api.nvim_create_autocmd('WinLeave', {
        buffer = editor_buffer,
        once = true,
        callback = function()
            vim.schedule(function()
                if state.editor and state.editor.buffer == editor_buffer then
                    finish_editing(state, true)
                end
            end)
        end,
    })
end

local function set_cells(state, changes, cursor_after)
    if #changes == 0 then
        return
    end
    commit_step(state, { cells = changes, cursor_after = cursor_after })
end

---------------------------------------------------------------------------
-- rows & columns
---------------------------------------------------------------------------

local function selected_rows(state)
    local selection = selection_bounds(state)
    local first, last = state.cursor_row, state.cursor_row
    if selection then
        first, last = selection.first_row, selection.last_row
    end
    return math.max(first, 0), math.max(last, 0)
end

local function selected_columns(state)
    local selection = selection_bounds(state)
    if selection then
        return selection.first_column, selection.last_column
    end
    return state.cursor_column, state.cursor_column
end

local function refs_between(state, first, last)
    local refs = {}
    for row_number = first, last do
        refs[#refs + 1] = row_ref(state, row_number)
    end
    return refs
end

local function need_complete_index(state, what)
    if not state.index.complete then
        helpers.warn(('Still counting rows (%d%%). %s works once counting is done.'):format(state.index:percent_done(), what))
        return false
    end
    return true
end

local function change_layout(state, new_layout, cursor_after)
    if editing_blocked(state) then
        return
    end
    commit_step(state, {
        layout_before = layout_snapshot(state),
        layout_after = vim.tbl_extend('force', layout_snapshot(state), new_layout),
        cursor_after = cursor_after,
    })
    if cursor_after then
        state.cursor_row, state.cursor_column = cursor_after[1], cursor_after[2]
    end
    state.anchor = nil
end

function spreadsheet_view.insert_rows(state, below)
    if
        count_rows(state) > 0
        and state.cursor_row >= 0
        and below
        and state.cursor_row == count_rows(state) - 1
        and not need_complete_index(state, 'Adding rows at the end')
    then
        return
    end
    local first, last = selected_rows(state)
    local count = last - first + 1
    local refs = {}
    for _ = 1, count do
        refs[#refs + 1] = {}
    end
    local at = below and last + 1 or first
    if state.cursor_row == -1 then
        at = 0
    end
    change_layout(state, { segments = insert_refs(state, state.segments, at, refs) }, { at, state.cursor_column })
end

function spreadsheet_view.delete_rows(state)
    if state.cursor_row == -1 and not state.anchor then
        return helpers.warn('The header row stays. Turn it off in Plugins > Spreadsheet to delete it as a row.')
    end
    local first, last = selected_rows(state)
    if count_rows(state) == 0 then
        return
    end
    change_layout(state, { segments = remove_rows(state, state.segments, first, last) }, { first, state.cursor_column })
end

function spreadsheet_view.duplicate_rows(state)
    local first, last = selected_rows(state)
    local copies = {}
    local changes = {}
    for _, ref in ipairs(refs_between(state, first, last)) do
        if state.json_lines then
            -- a json lines copy points at the line it copies & takes over
            -- only its edits, so saving writes the line's own bytes again,
            -- key order & number spellings & all. a perfect copy. my parents
            -- tried that once and look how it went.
            local copy = { copy_of = record_of_ref(ref) }
            copies[#copies + 1] = copy
            for column_id, value in pairs(state.edits[ref] or {}) do
                changes[#changes + 1] = { ref = copy, column_id = column_id, new = value }
            end
        else
            local copy = {}
            copies[#copies + 1] = copy
            for _, column_id in ipairs(state.columns) do
                local value = cell_value(state, ref, column_id)
                if value ~= '' then
                    changes[#changes + 1] = change_for(state, copy, column_id, value)
                end
            end
        end
    end
    if editing_blocked(state) then
        return
    end
    commit_step(state, {
        layout_before = layout_snapshot(state),
        layout_after = vim.tbl_extend('force', layout_snapshot(state), { segments = insert_refs(state, state.segments, last + 1, copies) }),
        cells = changes,
        cursor_after = { last + 1, state.cursor_column },
    })
    state.cursor_row = last + 1
    state.anchor = nil
end

function spreadsheet_view.move_rows(state, direction)
    local first, last = selected_rows(state)
    if state.cursor_row < 0 or (direction < 0 and first == 0) or (direction > 0 and last >= count_rows(state) - 1) then
        return
    end
    local moved = refs_between(state, first, last)
    local without = remove_rows(state, state.segments, first, last)
    local new_segments = insert_refs(state, without, first + direction, moved)
    local anchor = state.anchor
    change_layout(state, { segments = new_segments }, { state.cursor_row + direction, state.cursor_column })
    if anchor then
        state.anchor = { row = anchor.row + direction, column = anchor.column }
    end
end

-- moving columns rewrites every row on save, and a row over 1 mb can't be
-- rewritten without reading it whole. say so now, not after an hour of work.
-- early bad news is the only kind i'd thank anybody for.
local function column_changes_refused(state)
    if not state.json_lines and next(state.index.long_records) ~= nil then
        helpers.warn('This file has rows longer than 1 MB, so its columns cannot be inserted or deleted. Open it as text to do that.')
        return true
    end
    return false
end

function spreadsheet_view.insert_column(state, to_the_right)
    if column_changes_refused(state) then
        return
    end
    local first, last = selected_columns(state)
    local position = to_the_right and last + 1 or first
    local columns = vim.list_slice(state.columns)
    local column_id
    if state.json_lines then
        -- a json lines column is a key, so it needs a name. typing in it
        -- adds the key to that line only.
        local key, existing_column = ask_for_key(state)
        if not key then
            local existing_position = existing_column and vim.fn.index(state.columns, existing_column) or -1
            if existing_position >= 0 then
                move_to(state, state.cursor_row, existing_position + 1, false)
            end
            return
        end
        column_id = register_key(state, key)
        state.widths[column_id] = math.max(NEW_COLUMN_WIDTH, automatic_width(key))
    else
        column_id = state.next_new_column_id
        state.next_new_column_id = column_id - 1
        state.widths[column_id] = NEW_COLUMN_WIDTH
    end
    table.insert(columns, math.min(position, #columns + 1), column_id)
    change_layout(state, { columns = columns }, { state.cursor_row, position })
end

function spreadsheet_view.delete_columns(state)
    if column_changes_refused(state) then
        return
    end
    local first, last = selected_columns(state)
    if #state.columns <= last - first + 1 then
        return helpers.warn('A spreadsheet keeps at least one column.')
    end
    -- a key some line of the file has stays: deleting it would mean
    -- rewriting every line that has it. only columns i added and never
    -- filled from the file can go.
    if state.json_lines then
        for position = first, last do
            local column_id = state.columns[position]
            if state.discovered[column_id] then
                return helpers.warn(
                    ('The key "%s" is in the file, so its column stays. Delete its cells one by one, or open the file as text.'):format(
                        state.key_names[column_id]
                    )
                )
            end
        end
    end
    local columns = {}
    for position, column_id in ipairs(state.columns) do
        if position < first or position > last then
            columns[#columns + 1] = column_id
        end
    end
    change_layout(state, { columns = columns }, { state.cursor_row, math.min(first, #columns) })
end

function spreadsheet_view.toggle_header(state)
    if state.json_lines then
        return helpers.warn('A JSON Lines file has no header row: the header shows its keys.')
    end
    if state.header_ref ~= nil then
        change_layout(state, { header_ref = vim.NIL, segments = insert_refs(state, state.segments, 0, { state.header_ref }) }, { 0, state.cursor_column })
    else
        if count_rows(state) == 0 then
            return
        end
        local new_header = row_ref(state, 0)
        change_layout(state, { header_ref = new_header, segments = remove_rows(state, state.segments, 0, 0) }, { -1, state.cursor_column })
    end
    -- header text changes widths. titles cost space.
    state.widths_measured = false
end

-- widen or narrow the current column by `step` characters. rented space.
function spreadsheet_view.resize_column(state, step)
    local column_id = state.columns[state.cursor_column]
    if not column_id then
        return
    end
    state.widths[column_id] = math.max(1, math.min(200, (state.widths[column_id] or NEW_COLUMN_WIDTH) + step))
    state.width_set_by_user[column_id] = true
    spreadsheet_view.render(state)
end

---------------------------------------------------------------------------
-- clipboard
---------------------------------------------------------------------------

local function selection_or_cell(state)
    return selection_bounds(state)
        or {
            first_row = state.cursor_row,
            last_row = state.cursor_row,
            first_column = state.cursor_column,
            last_column = state.cursor_column,
        }
end

local function tab_separated_value(value)
    if value:find('[\t\r\n"]') then
        return '"' .. value:gsub('"', '""') .. '"'
    end
    return value
end

function spreadsheet_view.copy(state)
    local bounds = selection_or_cell(state)
    local cell_count = (bounds.last_row - bounds.first_row + 1) * (bounds.last_column - bounds.first_column + 1)
    if cell_count > LARGEST_COPY_CELLS then
        helpers.warn(('That is %s cells. Copy works up to %s at a time.'):format(cell_count, LARGEST_COPY_CELLS))
        return false
    end
    local lines = {}
    for row_number = bounds.first_row, bounds.last_row do
        local ref = row_ref(state, row_number)
        local values = {}
        for position = bounds.first_column, bounds.last_column do
            local value = row_number == -1 and header_text(state, position) or cell_value(state, ref, state.columns[position])
            values[#values + 1] = tab_separated_value(value)
        end
        lines[#lines + 1] = table.concat(values, '\t')
    end
    require('notebashpp.clipboard').set(lines, 'v')
    return true
end

function spreadsheet_view.clear_cells(state)
    if editing_blocked(state) then
        return
    end
    local bounds = selection_or_cell(state)
    local cell_count = (bounds.last_row - bounds.first_row + 1) * (bounds.last_column - bounds.first_column + 1)
    if cell_count > LARGEST_COPY_CELLS then
        return helpers.warn(('That is %s cells. Delete works up to %s at a time.'):format(cell_count, LARGEST_COPY_CELLS))
    end
    local changes = {}
    for row_number = bounds.first_row, bounds.last_row do
        local ref = row_ref(state, row_number)
        if ref ~= nil and not row_is_cut(state, ref) then
            for position = bounds.first_column, bounds.last_column do
                local column_id = state.columns[position]
                if cell_value(state, ref, column_id) ~= '' then
                    changes[#changes + 1] = change_for(state, ref, column_id, '')
                end
            end
        end
    end
    set_cells(state, changes)
end

function spreadsheet_view.cut(state)
    if spreadsheet_view.copy(state) then
        spreadsheet_view.clear_cells(state)
    end
end

-- paste tab separated text at the current cell. one value fills the whole
-- selection; a block adds rows & columns as needed. i can multiply my
-- mistakes super fast now. phenomenal.
function spreadsheet_view.paste(state)
    if editing_blocked(state) then
        return
    end
    local clipboard_lines = require('notebashpp.clipboard').get()
    local text = table.concat(clipboard_lines, '\n')
    local rows = split_tab_separated(text)
    if #rows == 0 then
        return
    end
    local layout_before = layout_snapshot(state)
    local segments, columns = state.segments, state.columns
    local bounds = selection_or_cell(state)
    local changes = {}
    local start_row = math.max(bounds.first_row, first_row(state))
    if #rows == 1 and #rows[1] == 1 and state.anchor then
        for row_number = bounds.first_row, bounds.last_row do
            local ref = row_ref(state, row_number)
            if ref ~= nil and not row_is_cut(state, ref) then
                for position = bounds.first_column, bounds.last_column do
                    changes[#changes + 1] = change_for(state, ref, columns[position], rows[1][1])
                end
            end
        end
    else
        local widest = 0
        for _, values in ipairs(rows) do
            widest = math.max(widest, #values)
        end
        local needed_columns = bounds.first_column + widest - 1 - #columns
        if needed_columns > 0 and state.json_lines then
            return helpers.warn('That is wider than the columns to the right. Insert columns for the keys first (Plugins > Spreadsheet > Insert Column Right).')
        end
        if needed_columns > 0 then
            columns = vim.list_slice(columns)
            for _ = 1, needed_columns do
                local column_id = state.next_new_column_id
                state.next_new_column_id = column_id - 1
                state.widths[column_id] = NEW_COLUMN_WIDTH
                columns[#columns + 1] = column_id
            end
        end
        local needed_rows = start_row + #rows - count_rows(state)
        if needed_rows > 0 then
            if not need_complete_index(state, 'Pasting past the last row') then
                return
            end
            local refs = {}
            for _ = 1, needed_rows do
                refs[#refs + 1] = {}
            end
            segments = insert_refs(state, segments, count_rows(state), refs)
        end
        local saved_segments, saved_columns = state.segments, state.columns
        state.segments, state.columns, state.segment_starts = segments, columns, nil
        for row_offset, values in ipairs(rows) do
            local row_number = start_row + row_offset - 1
            local ref = row_ref(state, row_number)
            if ref ~= nil and not row_is_cut(state, ref) then
                for value_offset, value in ipairs(values) do
                    changes[#changes + 1] = change_for(state, ref, columns[bounds.first_column + value_offset - 1], value)
                end
            end
        end
        state.segments, state.columns, state.segment_starts = saved_segments, saved_columns, nil
    end
    commit_step(state, {
        layout_before = layout_before,
        layout_after = { segments = segments, columns = columns, header_ref = layout_snapshot(state).header_ref },
        cells = changes,
    })
end

---------------------------------------------------------------------------
-- find & go to
---------------------------------------------------------------------------

local function cell_matches(state, ref, column_position, lowered_needle, row_number)
    local value = row_number == -1 and header_text(state, column_position) or cell_value(state, ref, state.columns[column_position])
    return value:lower():find(lowered_needle, 1, true) ~= nil
end

-- data row for record `record_number`; nil if deleted or the header.
-- disappeared, or promoted. same shit.
local function row_of_record(state, record_number)
    for segment_number, segment in ipairs(state.segments) do
        local starts = segment_starts(state, state.segments)
        if segment.refs then
            for position, ref in ipairs(segment.refs) do
                if ref == record_number then
                    return starts[segment_number] + position - 1
                end
            end
        elseif record_number >= segment.first and (segment.last == nil or record_number <= segment.last) then
            local row_number = starts[segment_number] + record_number - segment.first
            if row_number < count_rows(state) then
                return row_number
            end
        end
    end
    return nil
end

local function show_found(state, row_number, column_position)
    state.anchor = nil
    state.cursor_row, state.cursor_column = row_number, column_position
    state.top_row = math.max(0, row_number - 3)
    spreadsheet_view.render(state)
end

-- find the next cell containing `needle`, ignoring case. check the next few
-- thousand rows cell by cell, including edits & added rows; beyond that,
-- search the file itself in the background. i want answers without personally
-- inspecting all my failures.
function spreadsheet_view.find_next(state, backwards)
    local needle = state.last_search
    if not needle or needle == '' then
        return spreadsheet_view.find(state)
    end
    local lowered = needle:lower()
    local total_rows = count_rows(state)
    local row_number, position = state.cursor_row, state.cursor_column
    local step = backwards and -1 or 1
    for _ = 1, QUICK_SEARCH_ROWS do
        local ref = row_ref(state, row_number)
        local start_position = row_number == state.cursor_row and position + step or (backwards and #state.columns or 1)
        local stop_position = backwards and 1 or #state.columns
        for column_position = start_position, stop_position, step do
            if ref ~= nil and cell_matches(state, ref, column_position, lowered, row_number) then
                return show_found(state, row_number, column_position)
            end
        end
        row_number = row_number + step
        if row_number >= total_rows or row_number < first_row(state) then
            if total_rows <= QUICK_SEARCH_ROWS then
                row_number = backwards and total_rows - 1 or first_row(state)
            else
                break
            end
        end
        if row_number == state.cursor_row and total_rows <= QUICK_SEARCH_ROWS then
            break
        end
    end
    if total_rows <= QUICK_SEARCH_ROWS then
        return helpers.notify(('Cannot find "%s".'):format(needle))
    end
    if backwards then
        return helpers.notify(('"%s" is not in the %s rows above. Search down with F3.'):format(needle, QUICK_SEARCH_ROWS))
    end
    -- search the file from the record after the checked rows. more damn hay.
    local start_ref = row_ref(state, math.min(total_rows - 1, state.cursor_row + QUICK_SEARCH_ROWS))
    local start_offset = type(start_ref) == 'number' and state.index:record_offset(start_ref + 1) or 0
    local file_needle = to_file_encoding(state, needle) or needle
    local searched_from = start_offset
    local function on_found(offset)
        if states[state.buffer] ~= state then
            return
        end
        state.cancel_search = nil
        if not offset then
            return helpers.notify(('Cannot find "%s".'):format(needle))
        end
        if not state.index.complete and offset >= state.index.indexed_bytes then
            -- counting hasn't reached the hit; retry shortly. hope on a
            -- timer.
            vim.defer_fn(function()
                on_found(offset)
            end, 200)
            return
        end
        local record_number = state.index:record_at_offset(offset)
        local found_row = row_of_record(state, record_number)
        if found_row then
            local ref = row_ref(state, found_row)
            for column_position = 1, #state.columns do
                if cell_matches(state, ref, column_position, lowered, found_row) then
                    return show_found(state, found_row, column_position)
                end
            end
        end
        -- deleted row, header or match across quoting: continue after it.
        -- another damn false hope.
        local next_offset = state.index:record_offset(record_number + 1)
        if next_offset == searched_from then
            return helpers.notify(('Cannot find "%s".'):format(needle))
        end
        state.cancel_search = state.index:search(file_needle, next_offset, true, on_found)
    end
    helpers.notify(('Searching %s for "%s"...'):format(vim.fs.basename(state.path), needle))
    state.cancel_search = state.index:search(file_needle, start_offset, true, on_found)
end

function spreadsheet_view.find(state)
    local needle = helpers.ask('Find: ', state.last_search or '')
    if needle == '' then
        return
    end
    state.last_search = needle
    spreadsheet_view.find_next(state, false)
end

function spreadsheet_view.go_to_row(state)
    local total_rows = count_rows(state)
    local suffix = state.index.complete and '' or ' so far'
    local answer = helpers.ask(('Go to row (1 to %d%s): '):format(total_rows, suffix), tostring(math.max(state.cursor_row, 0) + 1))
    local row_number = tonumber(answer)
    if row_number then
        move_to(state, math.floor(row_number) - 1, state.cursor_column, false)
    end
end

---------------------------------------------------------------------------
-- saving
---------------------------------------------------------------------------

-- write the saved file from a plan. large files use a worker thread; small
-- ones run directly, so no upvalues and no vim api beyond vim.uv, which
-- worker threads get too. apparently even my mistakes need a production
-- schedule. plan lines: "c first last" copies old file bytes [first, last);
-- "l length ending" writes the next `length` bytes of `literal_text`, one
-- finished row, then that row's line break (1 lf, 2 cr lf, 0 the file's);
-- "r first last" rewrites records in bytes [first, last) with columns
-- reordered. write inter-row line breaks lazily, so the file ends with a line
-- break exactly when the old file did. i want the ending respected. nobody
-- asked for a damn sequel.
--
-- the old bytes come from the descriptor the index opened, so another program
-- renaming a new version over the file mid-edit can't feed me its offsets.
-- every write is checked and the file is synced before the caller renames it.
-- a full disk once made this report success over half a file. i know the
-- feeling of a full disk lying about how it's doing.
local function write_planned_file(input_descriptor, output_descriptor, plan_text, literal_text, packed_settings)
    local uv = vim.uv
    local settings_text, column_text = packed_settings:match('^([^|]*)|(.*)$')
    local settings = {}
    for number in settings_text:gmatch('%-?%d+') do
        settings[#settings + 1] = tonumber(number)
    end
    local delimiter = string.char(settings[1])
    local file_line_ending = settings[2] == 2 and '\r\n' or '\n'
    local final_line_break = settings[3] == 1
    local widest_record = settings[4] or 0
    local column_map = {}
    for number in column_text:gmatch('%-?%d+') do
        column_map[#column_map + 1] = tonumber(number)
    end
    local failure
    local output_offset = 0
    local function write_now(text)
        local position = 1
        while not failure and position <= #text do
            local piece = position == 1 and text or text:sub(position)
            local written, write_error = uv.fs_write(output_descriptor, piece, output_offset)
            if type(written) ~= 'number' or written <= 0 then
                failure = 'the disk refused the write (' .. tostring(write_error or 'nothing written') .. ')'
                return
            end
            output_offset = output_offset + written
            position = position + written
        end
    end
    -- false, or the line break owed before the next write.
    ---@type string|false
    local pending_line_break = false
    local function write(text)
        if text == '' or failure then
            return
        end
        if pending_line_break then
            write_now(pending_line_break)
            pending_line_break = false
        end
        write_now(text)
    end
    local function read(offset, length)
        local pieces, got = {}, 0
        while got < length do
            local data, read_error = uv.fs_read(input_descriptor, length - got, offset + got)
            if type(data) ~= 'string' or data == '' then
                failure = failure or ('the file could not be read (' .. tostring(read_error or 'it got shorter') .. ')')
                return nil
            end
            pieces[#pieces + 1] = data
            got = got + #data
        end
        return table.concat(pieces)
    end
    local function split_raw_fields(record)
        local fields = {}
        local position, length = 1, #record
        while true do
            local field_start = position
            if record:byte(position) == 34 then
                local scan_position = position + 1
                while true do
                    local quote_position = record:find('"', scan_position, true)
                    if not quote_position then
                        position = length + 1
                        break
                    end
                    if record:byte(quote_position + 1) == 34 then
                        scan_position = quote_position + 2
                    else
                        position = quote_position + 1
                        break
                    end
                end
            end
            local delimiter_position = record:find(delimiter, position, true)
            local field_end = delimiter_position and delimiter_position - 1 or length
            fields[#fields + 1] = record:sub(field_start, field_end)
            if not delimiter_position then
                break
            end
            position = delimiter_position + 1
        end
        return fields
    end
    -- fields past the widest row i ever looked at stay, after the mapped
    -- columns. a row nobody scrolled to still owns its extra fields. somebody
    -- should own something around here.
    local function emit(record)
        local had_carriage_return = record:byte(-1) == 13
        if had_carriage_return then
            record = record:sub(1, -2)
        end
        local fields = split_raw_fields(record)
        local reordered = {}
        for map_position, column_id in ipairs(column_map) do
            reordered[map_position] = column_id > 0 and fields[column_id] or ''
        end
        for extra_field = widest_record + 1, #fields do
            reordered[#reordered + 1] = fields[extra_field]
        end
        write(table.concat(reordered, delimiter))
        pending_line_break = had_carriage_return and '\r\n' or '\n'
    end
    -- rewrite every finished record in `data`; return the unfinished rest. on
    -- the last piece the rest is the file's last record. a record is under 1
    -- mb here (longer ones refuse column changes), so the rest stays small.
    local function rewrite_records(data, is_last_piece)
        local position, record_start, length = 1, 1, #data
        local inside_quotes = false
        while position <= length do
            local byte = data:byte(position)
            if inside_quotes then
                if byte == 34 then
                    if data:byte(position + 1) == 34 then
                        position = position + 1
                    else
                        inside_quotes = false
                    end
                end
            elseif byte == 34 then
                local before = position > 1 and data:byte(position - 1) or 10
                if position == record_start or before == settings[1] or before == 10 or before == 13 then
                    inside_quotes = true
                end
            elseif byte == 10 then
                emit(data:sub(record_start, position - 1))
                record_start = position + 1
            end
            position = position + 1
        end
        if record_start > length then
            return ''
        end
        if is_last_piece then
            emit(data:sub(record_start))
            return ''
        end
        return data:sub(record_start)
    end
    local piece_bytes = 4 * 1024 * 1024
    local literal_position = 1
    for kind, first_text, second_text in plan_text:gmatch('(%a) (%d+) ?(%d*)\n') do
        if failure then
            break
        end
        local first = tonumber(first_text)
        if kind == 'l' then
            write(literal_text:sub(literal_position, literal_position + first - 1))
            literal_position = literal_position + first
            local ending_code = tonumber(second_text) or 0
            pending_line_break = ending_code == 2 and '\r\n' or ending_code == 1 and '\n' or file_line_ending
        elseif kind == 'c' then
            local last = tonumber(second_text)
            local offset = first
            local last_piece
            while offset < last and not failure do
                local piece = read(offset, math.min(piece_bytes, last - offset))
                if not piece then
                    break
                end
                write(piece)
                offset = offset + #piece
                last_piece = piece
            end
            if last_piece then
                pending_line_break = last_piece:sub(-1) ~= '\n' and file_line_ending or false
            end
        elseif kind == 'r' then
            local last = tonumber(second_text)
            local offset = first
            local unfinished = ''
            while offset < last and not failure do
                local piece = read(offset, math.min(piece_bytes, last - offset))
                if not piece then
                    break
                end
                offset = offset + #piece
                unfinished = rewrite_records(unfinished .. piece, offset >= last)
            end
        end
    end
    if pending_line_break and final_line_break then
        write_now(pending_line_break)
    end
    if not failure then
        local synced, sync_error = uv.fs_fsync(output_descriptor)
        if not synced then
            failure = 'the disk refused the write (' .. tostring(sync_error) .. ')'
        end
    end
    collectgarbage()
    return failure or 'ok'
end

-- one json lines row as file bytes. an object line keeps every byte but the
-- values of edited keys (and the keys added or removed). a line that isn't
-- an object is written as it was, or as its edited text. a blank line
-- nobody gave a value stays blank. leave the rest of the file's life alone;
-- it's had enough interference.
local function serialize_json_row(state, ref)
    local entry = json_entry_of(state, ref)
    local row_edits = state.edits[ref] or {}
    local text
    if entry and entry.parsed.kind == 'other' then
        text = row_edits.raw ~= nil and row_edits.raw or entry.text
    else
        local changes, gives_a_value = {}, false
        for _, column_id in ipairs(state.columns) do
            local typed = row_edits[column_id]
            local key = state.key_names[column_id]
            if typed ~= nil and key ~= nil then
                local value = json_lines.value_for_text(typed)
                changes[#changes + 1] = { key = key, value = value }
                gives_a_value = gives_a_value or value ~= nil
            end
        end
        if entry and entry.parsed.kind == 'object' then
            text = json_lines.rewrite_object(entry.text, entry.parsed, changes)
        elseif entry and not gives_a_value then
            text = entry.text
        else
            text = json_lines.build_object(changes)
        end
    end
    if ref == 0 and state.bom then
        text = '\239\187\191' .. text
    end
    return text
end

-- one row as file bytes; unchanged fields keep exact bytes. spare the
-- innocent.
local function serialize_row(state, ref)
    if state.json_lines then
        return serialize_json_row(state, ref)
    end
    local entry = type(ref) == 'number' and parsed_record(state, ref) or nil
    local fields = {}
    for position, column_id in ipairs(state.columns) do
        local row_edits = state.edits[ref]
        local edited_value = row_edits and row_edits[column_id]
        if edited_value ~= nil then
            local file_value = to_file_encoding(state, edited_value)
            if not file_value then
                error(('"%s" cannot be written in %s, the encoding of this file'):format(edited_value, state.encoding), 0)
            end
            fields[position] = quote_field(file_value, state.delimiter)
        elseif entry and column_id > 0 then
            fields[position] = entry.raw_fields[column_id] or ''
        else
            fields[position] = ''
        end
    end
    -- unchanged layout keeps trailing empty fields as in the file. preserve
    -- the void.
    local text = table.concat(fields, state.delimiter)
    if ref == 0 and state.bom then
        text = '\239\187\191' .. text
    end
    return text
end

local function columns_unchanged(state)
    -- json lines columns are only a view of the keys; their order never
    -- touches the file.
    if state.json_lines then
        return true
    end
    for position, column_id in ipairs(state.columns) do
        if column_id ~= position then
            return false
        end
    end
    return #state.columns >= state.widest_record
end

-- plan for write_planned_file: copy untouched record runs, or rewrite them in
-- the thread if columns moved. changed & new rows come from here. my damage
-- has a return address.
local function build_save_plan(state)
    local plan, literals = {}, {}
    local index = state.index
    local keep_columns = columns_unchanged(state)
    -- a rewritten row keeps its own line break: one lf row in a cr lf file
    -- stays lf. new rows take the file's. consistency, the one thing i can
    -- still offer.
    local function line_ending_code(ref)
        if type(ref) ~= 'number' then
            return 0
        end
        if select(3, index:record(ref)) then
            return 2
        end
        if index.unterminated_last_record and ref == index.record_count - 1 then
            return 0
        end
        return 1
    end
    local function add_literal(ref)
        local text = serialize_row(state, ref)
        literals[#literals + 1] = text
        plan[#plan + 1] = ('l %d %d\n'):format(#text, line_ending_code(ref))
    end
    local function add_record_run(first, last)
        if last < first then
            return
        end
        local first_offset, end_offset = index:record_offset(first), index:record_offset(last + 1)
        if keep_columns then
            plan[#plan + 1] = ('c %d %d\n'):format(first_offset, end_offset)
            return
        end
        -- the thread reads the run 4 mb at a time. ration the misery.
        plan[#plan + 1] = ('r %d %d\n'):format(first_offset, end_offset)
    end
    -- a row over 1 mb (an unclosed quote can make one of a gigabyte) would
    -- have to be read whole to move its columns. refuse instead of eating all
    -- the memory. i know what it's like to be consumed by one bad decision.
    if not keep_columns and next(index.long_records) ~= nil then
        error('this file has rows longer than 1 MB, so its columns cannot be inserted or deleted. Undo the column change, or open the file as text', 0)
    end
    local edited_records = {}
    for ref in pairs(state.edits) do
        if type(ref) == 'number' then
            edited_records[#edited_records + 1] = ref
        end
    end
    table.sort(edited_records)
    local function add_ref(ref)
        if type(ref) == 'number' and not state.edits[ref] and keep_columns then
            add_record_run(ref, ref)
        elseif type(ref) == 'table' and ref.copy_of and not state.edits[ref] and not (ref.copy_of == 0 and state.bom) then
            -- an untouched copy of a line is that line's bytes again, even a
            -- line too long to show.
            add_record_run(ref.copy_of, ref.copy_of)
        else
            add_literal(ref)
        end
    end
    if state.header_ref ~= nil then
        add_ref(state.header_ref)
    end
    for _, segment in ipairs(state.segments) do
        if segment.refs then
            for _, ref in ipairs(segment.refs) do
                add_ref(ref)
            end
        else
            local run_start = segment.first
            local run_end = segment.last or (index.record_count - 1)
            -- edited records in this run become literals. my mistakes,
            -- verbatim.
            local low, high = 1, #edited_records
            while low <= high do
                local middle = math.floor((low + high) / 2)
                if edited_records[middle] < run_start then
                    low = middle + 1
                else
                    high = middle - 1
                end
            end
            local edited_position = low
            while edited_records[edited_position] and edited_records[edited_position] <= run_end do
                local edited_record = edited_records[edited_position]
                add_record_run(run_start, edited_record - 1)
                add_literal(edited_record)
                run_start = edited_record + 1
                edited_position = edited_position + 1
            end
            add_record_run(run_start, run_end)
        end
    end
    local column_map = {}
    for position, column_id in ipairs(state.columns) do
        column_map[position] = column_id
    end
    local settings = ('%d,%d,%d,%d|%s'):format(
        state.delimiter:byte(),
        state.line_ending == '\r\n' and 2 or 1,
        (index.unterminated_last_record and index.size > 0) and 0 or 1,
        state.widest_record,
        table.concat(column_map, ',')
    )
    return table.concat(plan), table.concat(literals), settings
end

-- make the file the save is written into, beside the real file (a symlink's
-- target, so the link survives): a random name, created only if nothing is
-- there yet (a planted symlink with my name on it gets refused), with the old
-- file's permissions & owner from the start. a hard linked file is refused:
-- renaming over it would cut it off from its other names. some families you
-- don't split up.
---@return table? output, string? problem
local function create_output_file(target_path)
    local uv = vim.uv
    local real_target = uv.fs_realpath(target_path) or target_path
    local target_stat = uv.fs_stat(real_target)
    if target_stat and target_stat.type ~= 'file' then
        return nil, vim.fs.basename(target_path) .. ' is not a regular file'
    end
    if target_stat and target_stat.nlink > 1 then
        return nil,
            ('%s has %d hard links, and saving would cut them off. Use File > Save As, or open the file as text'):format(
                vim.fs.basename(target_path),
                target_stat.nlink
            )
    end
    local mode = target_stat and target_stat.mode % 4096 or 438
    local last_problem
    for _ = 1, 8 do
        local random_bytes = uv.random(8)
        if type(random_bytes) ~= 'string' then
            return nil, 'no random numbers available'
        end
        local suffix = random_bytes:gsub('.', function(character)
            return ('%02x'):format(character:byte())
        end)
        local output_path = ('%s.%s.saving'):format(real_target, suffix)
        local descriptor, open_problem, error_name = uv.fs_open(output_path, 'wx', mode)
        if descriptor then
            if target_stat then
                uv.fs_fchmod(descriptor, mode)
                -- only root can give a file away. a failure here leaves the
                -- file mine, like everything else nobody wanted.
                uv.fs_fchown(descriptor, target_stat.uid, target_stat.gid)
            end
            return { descriptor = descriptor, path = output_path, target = real_target }
        end
        last_problem = open_problem
        if error_name ~= 'EEXIST' then
            break
        end
    end
    return nil, last_problem
end

-- json lines columns by key, in screen order, with widths: what survives a
-- reload, a save or a session. column ids are handed out in the order keys
-- turn up, which differs every time. names last longer than numbers. not
-- mine, obviously, but in general.
local function json_column_layout(state)
    local layout = {}
    for _, column_id in ipairs(state.columns) do
        local key = state.key_names[column_id]
        if key then
            layout[#layout + 1] = {
                key = key,
                discovered = state.discovered[column_id] == true,
                width = state.widths[column_id],
                width_set_by_user = state.width_set_by_user[column_id] == true,
            }
        end
    end
    return layout
end

local function apply_json_column_layout(state, layout)
    local columns = {}
    for _, column in ipairs(layout) do
        if type(column) == 'table' and type(column.key) == 'string' then
            local column_id = register_key(state, column.key)
            if not vim.tbl_contains(columns, column_id) then
                columns[#columns + 1] = column_id
            end
            state.discovered[column_id] = state.discovered[column_id] or column.discovered == true or nil
            if type(column.width) == 'number' then
                state.widths[column_id] = column.width
            end
            if column.width_set_by_user == true then
                state.width_set_by_user[column_id] = true
            end
        end
    end
    state.columns = columns
    append_discovered_columns(state)
end

local function after_save(state, target_path, result, output, on_done)
    state.saving = false
    local closed, close_problem = vim.uv.fs_close(output.descriptor)
    if result == 'ok' and not closed then
        result = 'the disk refused the write (' .. tostring(close_problem) .. ')'
    end
    if result == 'ok' then
        local renamed, rename_problem = vim.uv.fs_rename(output.path, output.target)
        if not renamed then
            result = tostring(rename_problem)
        end
    end
    if result ~= 'ok' then
        vim.uv.fs_unlink(output.path)
        helpers.warn(('Save failed, the file on disk is unchanged: %s'):format(result))
    end
    -- the document was closed while the thread wrote. let the index go now
    -- that nothing reads through its descriptor any more.
    if state.stop_when_saved or not api.nvim_buf_is_valid(state.buffer) then
        state.index:stop()
        return on_done and on_done(result == 'ok')
    end
    if result ~= 'ok' then
        return on_done and on_done(false)
    end
    -- reread the saved file, keeping the screen position. same hell, fresh
    -- sheets.
    local keep_position = { row = state.cursor_row, column = state.cursor_column, top_row = state.top_row, first_column = state.first_column }
    local keep_widths, keep_width_set_by_user = state.widths, state.width_set_by_user
    local keep_json_columns = state.json_lines and json_column_layout(state)
    if target_path ~= state.path then
        api.nvim_buf_set_name(state.buffer, target_path)
        state.path = target_path
    end
    spreadsheet_view.load(state.buffer, target_path, state)
    state.pending_position = keep_position
    if state.json_lines and keep_json_columns then
        apply_json_column_layout(state, keep_json_columns)
    elseif not state.json_lines then
        state.widths, state.width_set_by_user = keep_widths, keep_width_set_by_user
    end
    spreadsheet_view.render(state)
    if on_done then
        on_done(true)
    end
end

-- save to `target_path`, defaulting to the sheet's own file. up to 256 mb
-- writes before returning; bigger files use a thread. i outsourced the
-- waiting. still getting old.
function spreadsheet_view.save(state, target_path, on_done)
    target_path = target_path or state.path
    if state.saving then
        return helpers.warn('Already saving.')
    end
    if not state.index.complete then
        -- wait for counting, then save. age meanwhile.
        helpers.notify(('Counting rows (%d%%); saving when done.'):format(state.index:percent_done()))
        state.save_when_counted = { target_path, on_done }
        return
    end
    local function refuse(problem)
        helpers.warn(('Not saved: %s.'):format(problem))
        return on_done and on_done(false)
    end
    -- every untouched row is copied from the file as it was when opened. if
    -- another program wrote into that file since, the copies would be half
    -- its version & half mine. that's not a file, that's a custody battle.
    if state.index:changed_in_place() then
        return refuse(
            vim.fs.basename(state.path)
                .. ' was changed on disk by another program while it was open here. Reload it (File > Reload from Disk) and make the changes again'
        )
    end
    -- replaced by a new file under the same name: the old one is still
    -- readable through the index, so overwriting with my version is safe if
    -- that's what i want.
    if (vim.uv.fs_realpath(target_path) or target_path) == (vim.uv.fs_realpath(state.path) or state.path) and state.index:changed_on_disk() then
        local choice = vim.fn.confirm(vim.fs.basename(state.path) .. ' changed on disk after it was opened. Overwrite it?', '&Yes\n&No', 2, 'Warning')
        if choice ~= 1 then
            return on_done and on_done(false)
        end
    end
    local planned, plan_text, literal_text, settings = pcall(build_save_plan, state)
    if not planned then
        return refuse(tostring(plan_text))
    end
    local output, output_problem = create_output_file(target_path)
    if not output then
        return refuse(tostring(output_problem))
    end
    state.saving = true
    local exiting = vim.v.exiting ~= nil and vim.v.exiting ~= vim.NIL
    if state.index.size <= SYNCHRONOUS_SAVE_BYTES or exiting then
        local result = write_planned_file(state.index.descriptor, output.descriptor, plan_text, literal_text, settings)
        after_save(state, target_path, result, output, on_done)
        return
    end
    helpers.notify(('Saving %s...'):format(vim.fs.basename(target_path)))
    vim.cmd('redrawstatus')
    local work = vim.uv.new_work(write_planned_file, function(result)
        vim.schedule(function()
            after_save(state, target_path, result, output, on_done)
            if result == 'ok' then
                helpers.notify(('Saved %s.'):format(vim.fs.basename(target_path)))
            end
        end)
    end)
    work:queue(state.index.descriptor, output.descriptor, plan_text, literal_text, settings)
end

---------------------------------------------------------------------------
-- opening
---------------------------------------------------------------------------

local function on_index_progress(state)
    if states[state.buffer] ~= state then
        return
    end
    if not state.widths_measured then
        state.widths_measured = false
    end
    if state.save_when_counted and state.index.complete then
        local pending = state.save_when_counted
        state.save_when_counted = nil
        spreadsheet_view.save(state, pending[1], pending[2])
    end
    render_soon(state)
end

-- (re)read into `state` or a new state, dropping unsaved edits. amnesia is a
-- feature (?)
function spreadsheet_view.load(buffer, path, state)
    if state and state.index then
        state.index:stop()
    end
    if state and state.cancel_search then
        state.cancel_search()
    end
    local extension = (path:match('%.([^./\\]+)$') or ''):lower()
    local is_json_lines = JSON_LINES_EXTENSIONS[extension] == true
    local format = is_json_lines and detect_json_lines_format(path) or detect_format(path)
    state = state or {}
    local fresh = {
        buffer = buffer,
        path = path,
        delimiter = format.delimiter,
        line_ending = format.line_ending,
        bom = format.bom,
        encoding = format.encoding,
        -- json lines has no header record: the header row shows the keys,
        -- and every line is a data row, starting with record 0.
        header_ref = not is_json_lines and 0 or nil,
        segments = { { first = is_json_lines and 0 or 1 } },
        json_lines = is_json_lines,
        key_ids = {},
        key_names = {},
        discovered = {},
        key_column_count = 0,
        columns = {},
        widths = {},
        width_set_by_user = {},
        widest_record = 0,
        edits = {},
        parsed = {},
        parsed_count = 0,
        parsed_bytes = 0,
        next_new_column_id = -1,
        top_row = 0,
        first_column = 1,
        cursor_row = 0,
        cursor_column = 1,
        undo_steps = {},
        redo_steps = {},
        saved_step = nil,
        widths_measured = false,
        saving = false,
        pending_position = { row = 0, column = 1, top_row = 0, first_column = 1 },
    }
    for key in pairs(state) do
        state[key] = nil
    end
    for key, value in pairs(fresh) do
        state[key] = value
    end
    -- a json lines record is one line, quotes or not: a line break inside
    -- a json string is written \n, so a raw one ends the record.
    local index, problem = file_index.open(path, {
        quote_aware = not is_json_lines,
        delimiter = format.delimiter,
        on_progress = function()
            on_index_progress(state)
        end,
    })
    if not index then
        error(problem)
    end
    state.index = index
    states[buffer] = state
    index:start()
    return state
end

-- grid keys. typed characters start editing the cell on any keyboard layout;
-- see setup()'s on_key handler. i accept mistakes in every layout. absolutely
-- inclusive damage.
local function set_grid_keys(buffer)
    local function map(keys, action)
        vim.keymap.set({ 'n', 'x', 's' }, keys, function()
            local state = states[buffer]
            if state then
                if state.typed_ahead then
                    table.insert(state.typed_ahead, api.nvim_replace_termcodes(keys, true, false, true))
                    return
                end
                if vim.fn.mode() ~= 'n' then
                    vim.cmd('normal! \27')
                end
                action(state)
            end
        end, { buffer = buffer, nowait = true, silent = true })
    end
    local function step(row_step, column_step, extend)
        return function(state)
            move_to(state, state.cursor_row + row_step, state.cursor_column + column_step, extend)
        end
    end
    for _, extend in ipairs({ false, true }) do
        local shift = extend and 'S-' or ''
        map('<' .. shift .. 'Up>', step(-1, 0, extend))
        map('<' .. shift .. 'Down>', step(1, 0, extend))
        map('<' .. shift .. 'Left>', step(0, -1, extend))
        map('<' .. shift .. 'Right>', step(0, 1, extend))
        map('<' .. shift .. 'PageUp>', function(state)
            move_to(state, state.cursor_row - page_rows(state), state.cursor_column, extend)
        end)
        map('<' .. shift .. 'PageDown>', function(state)
            move_to(state, state.cursor_row + page_rows(state), state.cursor_column, extend)
        end)
        map('<' .. shift .. 'Home>', function(state)
            move_to(state, state.cursor_row, 1, extend)
        end)
        map('<' .. shift .. 'End>', function(state)
            move_to(state, state.cursor_row, #state.columns, extend)
        end)
        map('<C-' .. shift .. 'Home>', function(state)
            move_to(state, first_row(state), 1, extend)
        end)
        map('<C-' .. shift .. 'End>', function(state)
            move_to(state, last_row(state), #state.columns, extend)
            wait_for_last_row(state, #state.columns)
        end)
        map('<C-' .. shift .. 'Up>', function(state)
            move_to(state, first_row(state), state.cursor_column, extend)
        end)
        map('<C-' .. shift .. 'Down>', function(state)
            move_to(state, last_row(state), state.cursor_column, extend)
            wait_for_last_row(state, state.cursor_column)
        end)
        map('<C-' .. shift .. 'Left>', function(state)
            move_to(state, state.cursor_row, 1, extend)
        end)
        map('<C-' .. shift .. 'Right>', function(state)
            move_to(state, state.cursor_row, #state.columns, extend)
        end)
    end
    map('<Tab>', step(0, 1, false))
    map('<S-Tab>', step(0, -1, false))
    map('<CR>', step(1, 0, false))
    map('<S-CR>', step(-1, 0, false))
    map('<Esc>', function(state)
        move_to(state, state.cursor_row, state.cursor_column, false)
    end)
    map('<C-a>', function(state)
        state.anchor = { row = first_row(state), column = 1 }
        state.cursor_row, state.cursor_column = last_row(state), #state.columns
        spreadsheet_view.render(state)
    end)
    map('<F2>', function(state)
        spreadsheet_view.edit_cell(state, nil)
    end)
    map('<BS>', function(state)
        spreadsheet_view.edit_cell(state, '')
    end)
    map('<Del>', spreadsheet_view.clear_cells)
    map('<C-c>', spreadsheet_view.copy)
    map('<C-Insert>', spreadsheet_view.copy)
    map('<C-x>', spreadsheet_view.cut)
    map('<S-Del>', spreadsheet_view.cut)
    map('<C-v>', spreadsheet_view.paste)
    map('<S-Insert>', spreadsheet_view.paste)
    map('<C-z>', spreadsheet_view.undo)
    map('<M-BS>', spreadsheet_view.undo)
    map('<C-y>', spreadsheet_view.redo)
    map('<C-S-z>', spreadsheet_view.redo)
    map('<C-d>', spreadsheet_view.duplicate_rows)
    map('<C-l>', spreadsheet_view.delete_rows)
    map('<C-S-l>', spreadsheet_view.delete_rows)
    map('<C-S-Up>', function(state)
        spreadsheet_view.move_rows(state, -1)
    end)
    map('<C-S-Down>', function(state)
        spreadsheet_view.move_rows(state, 1)
    end)
    map('<C-CR>', function(state)
        spreadsheet_view.insert_rows(state, true)
    end)
    map('<C-M-Right>', function(state)
        spreadsheet_view.resize_column(state, 2)
    end)
    map('<C-M-Left>', function(state)
        spreadsheet_view.resize_column(state, -2)
    end)
    map('<C-f>', spreadsheet_view.find)
    map('<F3>', function(state)
        spreadsheet_view.find_next(state, false)
    end)
    map('<S-F3>', function(state)
        spreadsheet_view.find_next(state, true)
    end)
    map('<C-g>', spreadsheet_view.go_to_row)
    map('<C-h>', function()
        helpers.warn('Replace works on text. Use Plugins > Spreadsheet > View as Text.')
    end)
    -- mouse: click picks a cell; shift+click or drag selects; double click
    -- edits. wheel scrolls rows, shift+wheel columns. so many ways to point
    -- at the same damn problem.
    local function cell_under_mouse(state)
        local mouse = vim.fn.getmousepos()
        local layout = state.layout
        if not layout or mouse.winid ~= layout.window or mouse.line == 0 then
            return nil
        end
        local row_number = mouse.line == 1 and -1 or state.top_row + mouse.line - 2
        if row_number == -1 and state.header_ref == nil then
            row_number = state.top_row
        end
        local column_position = layout.visible_positions[1] or 1
        for _, position in ipairs(layout.visible_positions) do
            if layout.column_starts[position] <= mouse.wincol then
                column_position = position
            end
        end
        return row_number, column_position
    end
    map('<LeftMouse>', function(state)
        local row_number, column_position = cell_under_mouse(state)
        if row_number then
            move_to(state, row_number, column_position, false)
        end
    end)
    map('<S-LeftMouse>', function(state)
        local row_number, column_position = cell_under_mouse(state)
        if row_number then
            move_to(state, row_number, column_position, true)
        end
    end)
    map('<LeftDrag>', function(state)
        local row_number, column_position = cell_under_mouse(state)
        if row_number then
            move_to(state, row_number, column_position, true)
        end
    end)
    map('<LeftRelease>', function() end)
    map('<2-LeftMouse>', function(state)
        local row_number, column_position = cell_under_mouse(state)
        if row_number then
            move_to(state, row_number, column_position, false)
            spreadsheet_view.edit_cell(state, nil)
        end
    end)
    map('<ScrollWheelDown>', function(state)
        state.top_row = state.top_row + 3
        state.cursor_row = math.max(state.cursor_row, state.top_row)
        spreadsheet_view.render(state)
    end)
    map('<ScrollWheelUp>', function(state)
        state.top_row = math.max(0, state.top_row - 3)
        local bottom = state.top_row + page_rows(state)
        if state.cursor_row > bottom then
            state.cursor_row = bottom
        end
        spreadsheet_view.render(state)
    end)
    for _, keys in ipairs({ '<S-ScrollWheelDown>', '<ScrollWheelRight>' }) do
        map(keys, function(state)
            move_to(state, state.cursor_row, state.cursor_column + 1, false)
        end)
    end
    for _, keys in ipairs({ '<S-ScrollWheelUp>', '<ScrollWheelLeft>' }) do
        map(keys, function(state)
            move_to(state, state.cursor_row, state.cursor_column - 1, false)
        end)
    end
end

-- open `path` in `buffer` as a spreadsheet, from its bufreadcmd. neovim never
-- reads the file itself. i don't trust the bastard with unsupervised reading.
function spreadsheet_view.open(buffer, path)
    local existing = states[buffer]
    local ok, problem = pcall(spreadsheet_view.load, buffer, path, existing)
    if not ok then
        vim.bo[buffer].buftype = 'nofile'
        api.nvim_buf_set_lines(buffer, 0, -1, false, { 'Cannot open ' .. path .. ': ' .. tostring(problem) })
        vim.bo[buffer].modifiable = false
        return
    end
    local state = states[buffer]
    vim.b[buffer].notebashpp_special_view = 'spreadsheet_view'
    vim.bo[buffer].buftype = 'acwrite'
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].undolevels = -1
    vim.bo[buffer].modeline = false
    vim.bo[buffer].filetype = 'notebashpp_spreadsheet'
    vim.bo[buffer].modifiable = false
    if existing then
        render_soon(state)
        return
    end
    set_grid_keys(buffer)
    local augroup = api.nvim_create_augroup('notebashpp_spreadsheet_' .. buffer, { clear = true })
    api.nvim_create_autocmd('BufWriteCmd', {
        group = augroup,
        buffer = buffer,
        callback = function(event)
            local target = vim.fn.fnamemodify(event.match, ':p')
            spreadsheet_view.save(states[buffer], target)
        end,
    })
    -- insert mode inherited from a text document makes every key a refused
    -- edit here. rejection without even sending a cv.
    api.nvim_create_autocmd('BufEnter', {
        group = augroup,
        buffer = buffer,
        callback = function()
            vim.cmd.stopinsert()
        end,
    })
    api.nvim_create_autocmd('BufWinEnter', {
        group = augroup,
        buffer = buffer,
        callback = function()
            apply_window_options(api.nvim_get_current_win())
            render_soon(states[buffer])
        end,
    })
    -- follow clicks or another module's caret moves to a cell. dragged into
    -- this.
    api.nvim_create_autocmd('CursorMoved', {
        group = augroup,
        buffer = buffer,
        callback = function()
            local current = states[buffer]
            if not current or not current.layout then
                return
            end
            local caret = api.nvim_win_get_cursor(0)
            local placed = current.placed_caret
            if placed and placed[1] == caret[1] and placed[2] == caret[2] then
                return
            end
            local row_number = caret[1] == 1 and first_row(current) or current.top_row + caret[1] - 2
            local column_position = current.cursor_column
            for position, bytes in pairs(current.layout.cell_bytes[caret[1]] or {}) do
                if caret[2] >= bytes[1] - 1 and caret[2] <= bytes[2] + 1 then
                    column_position = position
                end
            end
            move_to(current, row_number, column_position, false)
        end,
    })
    api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
        group = augroup,
        buffer = buffer,
        callback = function()
            local current = states[buffer]
            if current then
                -- a save in progress still reads through the index's
                -- descriptor; after_save closes it. closing it now could hand
                -- its number to some other file mid-copy.
                if current.saving then
                    current.stop_when_saved = true
                else
                    current.index:stop()
                end
                if current.cancel_search then
                    current.cancel_search()
                end
            end
            states[buffer] = nil
            pcall(api.nvim_del_augroup_by_id, augroup)
        end,
    })
    local window = vim.fn.bufwinid(buffer)
    if window ~= -1 then
        apply_window_options(window)
    end
    render_soon(state)
end

-- status bar fields for the current spreadsheet. a tiny failure report.
function spreadsheet_view.status(buffer)
    local state = states[buffer]
    if not state then
        return nil
    end
    local function thousands(number)
        local text = tostring(number)
        local grouped = text:reverse():gsub('(%d%d%d)', '%1,'):reverse()
        return (grouped:gsub('^,', ''))
    end
    local total_rows = count_rows(state)
    local counting = state.index.complete and '' or ('  counting %d%%'):format(state.index:percent_done())
    local column_name = header_text(state, state.cursor_column)
    local row_text = state.cursor_row == -1 and 'header' or thousands(state.cursor_row + 1)
    local position = ('Row : %s of %s    Col : %d%s'):format(
        row_text,
        thousands(total_rows),
        state.cursor_column,
        column_name ~= '' and (' (' .. display_text(column_name) .. ')') or ''
    )
    local selection = selection_bounds(state)
    if selection then
        position = ('Sel : %s x %s    '):format(
            thousands(selection.last_row - math.max(selection.first_row, 0) + 1),
            thousands(selection.last_column - selection.first_column + 1)
        ) .. position
    end
    local kind = state.delimiter == '\t' and 'TSV' or state.delimiter == ',' and 'CSV' or ('CSV (' .. state.delimiter .. ')')
    if state.json_lines then
        kind = 'JSON Lines'
        local entry = state.cursor_row >= 0 and json_entry_of(state, row_ref(state, state.cursor_row)) or nil
        if entry and entry.parsed.kind == 'other' then
            position = position .. '    not a JSON object'
        end
    end
    return {
        language = kind .. ' spreadsheet' .. (state.saving and '  saving...' or ''),
        position = position .. counting,
        length = ('  size : %s    columns : %d  '):format(thousands(state.index.size), #state.columns),
        line_ending = state.line_ending == '\r\n' and 'Windows (CR LF)' or 'Unix (LF)',
        encoding = state.encoding == 'utf-8' and (state.bom and 'UTF-8-BOM' or 'UTF-8') or state.encoding,
    }
end

---------------------------------------------------------------------------
-- session restore
---------------------------------------------------------------------------

-- unsaved changes as json values. added rows get ids ("new1") so segments,
-- edits & header can reference them. even my unfinished crap gets an identity
-- before i do.
local function serialize_changes(state)
    local new_row_ids, new_row_count = {}, 0
    local copies = {}
    local function saved_ref(ref)
        if type(ref) == 'number' then
            return ref
        end
        if not new_row_ids[ref] then
            new_row_count = new_row_count + 1
            new_row_ids[ref] = 'new' .. new_row_count
            if ref.copy_of then
                copies[new_row_ids[ref]] = ref.copy_of
            end
        end
        return new_row_ids[ref]
    end
    local segments = {}
    for _, segment in ipairs(state.segments) do
        if segment.refs then
            local refs = {}
            for position, ref in ipairs(segment.refs) do
                refs[position] = saved_ref(ref)
            end
            segments[#segments + 1] = { refs = refs }
        else
            segments[#segments + 1] = { first = segment.first, last = segment.last }
        end
    end
    -- json lines edits are saved by key: column ids get handed out in a
    -- different order every time the file is opened.
    local edits = {}
    for ref, row_edits in pairs(state.edits) do
        for column_id, value in pairs(row_edits) do
            local column = column_id
            if state.json_lines then
                column = column_id == 'raw' and { raw = true } or { key = state.key_names[column_id] }
            end
            edits[#edits + 1] = { saved_ref(ref), column, value }
        end
    end
    return {
        segments = segments,
        edits = edits,
        copies = copies,
        json_columns = state.json_lines and json_column_layout(state) or nil,
        columns = vim.list_slice(state.columns),
        header = state.header_ref ~= nil and saved_ref(state.header_ref) or false,
        next_new_column_id = state.next_new_column_id,
        widest_record = state.widest_record,
    }
end

local function apply_saved_changes(state, changes)
    local new_rows = {}
    local function live_ref(saved)
        if type(saved) == 'number' then
            return saved
        end
        new_rows[saved] = new_rows[saved] or {}
        return new_rows[saved]
    end
    local segments = {}
    for _, segment in ipairs(changes.segments or {}) do
        if segment.refs then
            local refs = {}
            for position, saved in ipairs(segment.refs) do
                refs[position] = live_ref(saved)
            end
            segments[#segments + 1] = { refs = refs }
        else
            segments[#segments + 1] = { first = segment.first, last = segment.last }
        end
    end
    for saved, record_number in pairs(type(changes.copies) == 'table' and changes.copies or {}) do
        if type(record_number) == 'number' then
            local copy = live_ref(saved)
            if type(copy) == 'table' then
                copy.copy_of = record_number
            end
        end
    end
    state.segments, state.segment_starts = segments, nil
    state.edits = {}
    for _, edit in ipairs(changes.edits or {}) do
        local ref = live_ref(edit[1])
        local column_id = edit[2]
        if state.json_lines then
            local column = type(column_id) == 'table' and column_id or {}
            column_id = column.raw and 'raw' or type(column.key) == 'string' and register_key(state, column.key) or nil
        end
        if column_id ~= nil then
            state.edits[ref] = state.edits[ref] or {}
            state.edits[ref][column_id] = edit[3]
        end
    end
    if state.json_lines then
        apply_json_column_layout(state, type(changes.json_columns) == 'table' and changes.json_columns or {})
    else
        state.columns = changes.columns or state.columns
    end
    for _, column_id in ipairs(state.columns) do
        if column_id < 0 then
            state.widths[column_id] = state.widths[column_id] or NEW_COLUMN_WIDTH
        end
    end
    state.header_ref = changes.header ~= false and live_ref(changes.header) or nil
    state.next_new_column_id = changes.next_new_column_id or state.next_new_column_id
    state.widest_record = math.max(state.widest_record, changes.widest_record or 0)
    -- one undo step represents restored changes so the tab marks them
    -- unsaved. i want my regrets labelled.
    state.undo_steps = { { cursor_before = { state.cursor_row, state.cursor_column } } }
    state.redo_steps = {}
end

-- session keeps the screen position & unsaved changes, with the file size and
-- time they were made against. basically an alibi for whatever shit i wake up
-- to.
function spreadsheet_view.session_state(buffer)
    local state = states[buffer]
    if not state then
        return nil
    end
    local position = state.pending_position
    -- a jump to the end has no row number until counting finishes. so much
    -- for getting out of this shit.
    if not position or position.row == math.huge then
        position = { row = state.cursor_row, column = state.cursor_column, top_row = state.top_row, first_column = state.first_column }
    end
    local saved = { position = position }
    if vim.bo[buffer].modified then
        saved.changes = serialize_changes(state)
        saved.file_size = state.index.size
        saved.file_time = state.index.modification_time
    end
    return saved
end

function spreadsheet_view.restore_session_state(saved, document)
    if not document.path or vim.fn.filereadable(document.path) == 0 then
        return nil
    end
    local buffer = vim.fn.bufadd(document.path)
    vim.bo[buffer].buflisted = true
    vim.fn.bufload(buffer)
    local state = states[buffer]
    if not state or type(saved) ~= 'table' then
        return buffer
    end
    if type(saved.position) == 'table' and saved.position.row then
        state.pending_position = saved.position
    end
    if type(saved.changes) == 'table' then
        if saved.file_size == state.index.size and saved.file_time == state.index.modification_time then
            apply_saved_changes(state, saved.changes)
        else
            helpers.warn(('%s changed on disk, so its unsaved spreadsheet edits from last time were not put back.'):format(vim.fs.basename(document.path)))
        end
    end
    render_soon(state)
    return buffer
end

function spreadsheet_view.current_state()
    return states[api.nvim_get_current_buf()]
end

-- a cell's text as the grid shows it before cutting it to width, and the
-- header names. the tests read the sheet through these. somebody has to
-- check my work; it may as well be a robot.
function spreadsheet_view.cell_at(state, row_number, column_position)
    return (cell_value(state, row_ref(state, row_number), state.columns[column_position]))
end

function spreadsheet_view.column_names(state)
    local names = {}
    for position = 1, #state.columns do
        names[position] = header_text(state, position)
    end
    return names
end

-- run a menu's spreadsheet action on the current document. local damage.
function spreadsheet_view.run(action_name, ...)
    local state = spreadsheet_view.current_state()
    if not state then
        return helpers.warn('This works in a spreadsheet: open a .csv, .tsv or .jsonl file.')
    end
    return spreadsheet_view[action_name](state, ...)
end

function spreadsheet_view._unload()
    if spreadsheet_view.key_listener then
        vim.on_key(nil, spreadsheet_view.key_listener)
        spreadsheet_view.key_listener = nil
    end
end

function spreadsheet_view.setup()
    local highlight_links = {
        NotebashSheetEditor = 'NotebashDlgField',
        NotebashSheetInvalid = 'DiagnosticError',
    }
    for group_name, target in pairs(highlight_links) do
        if vim.tbl_isempty(api.nvim_get_hl(0, { name = group_name })) then
            api.nvim_set_hl(0, group_name, { link = target, default = true })
        end
    end
    -- a typed character starts editing the current grid cell with it, on any
    -- keyboard layout. on_key sees it before mappings; returning an empty
    -- string swallows it. even the editor eats its damn feelings.
    spreadsheet_view._unload()
    spreadsheet_view.key_listener = vim.on_key(function(_, typed)
        if not typed or typed == '' then
            return
        end
        local state = states[api.nvim_get_current_buf()]
        if not state or state.editor or api.nvim_get_mode().mode ~= 'n' then
            return
        end
        local first_byte = typed:byte(1)
        local is_character = (first_byte >= 32 and first_byte < 127 and #typed == 1)
            or (first_byte >= 194 and first_byte <= 244 and vim.fn.strchars(typed) == 1)
        if not is_character then
            return
        end
        -- while the cell editor opens, later keys wait in one queue: letters
        -- here, tab & enter in the grid key handler. replay them into the
        -- editor in order, even with fast typing. i want my mistakes in the
        -- order i made them. the court was very clear.
        if state.typed_ahead then
            table.insert(state.typed_ahead, typed)
            return ''
        end
        state.typed_ahead = { typed }
        vim.schedule(function()
            local queue = state.typed_ahead
            state.typed_ahead = nil
            if queue and states[state.buffer] == state and api.nvim_get_current_buf() == state.buffer then
                spreadsheet_view.edit_cell(state, queue[1])
                if #queue > 1 and state.editor then
                    api.nvim_feedkeys(table.concat(queue, '', 2), 'mt', false)
                end
            end
        end)
        return ''
    end)
    local augroup = api.nvim_create_augroup('notebashpp_spreadsheet', { clear = true })
    api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
        group = augroup,
        callback = function()
            for _, state in pairs(states) do
                render_soon(state)
            end
        end,
    })
    -- quitting waits for the background save. can't even leave this shit
    -- unfinished.
    api.nvim_create_autocmd('VimLeavePre', {
        group = augroup,
        callback = function()
            for _, state in pairs(states) do
                if state.saving or state.save_when_counted then
                    vim.wait(600000, function()
                        return not state.saving and not state.save_when_counted
                    end, 50)
                end
            end
        end,
    })
end

return spreadsheet_view
