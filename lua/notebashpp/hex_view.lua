-- view in hex, like the hex-editor plugin (2.2 million downloads). apparently
-- staring at text wasn't enough suffering for us. the document's bytes get
-- their own tab, laid out as xxd does it:
--
--     00000000: 6865 6c6c 6f2c 2077 6f72 6c64 0d0a      hello, world..
--
-- edit the hex digits; ctrl+s puts the bytes back into the document and saves
-- it. view in hex again returns to text. i want closure too, but this is what
-- i built instead. these are the bytes the file gets on disk, with its
-- encoding and line endings.

local hex_view = {}
local api = vim.api
local helpers = require('notebashpp.helpers')

local BYTES_PER_LINE = 16
local LARGEST_FILE = 8 * 1024 * 1024

local LINE_ENDINGS = { dos = '\r\n', unix = '\n', mac = '\r' }

-- the document's bytes as saving would write them. dressed for burial.
local function document_bytes(buffer)
    local line_ending = LINE_ENDINGS[vim.bo[buffer].fileformat] or '\n'
    local text = table.concat(api.nvim_buf_get_lines(buffer, 0, -1, false), line_ending)
    if vim.bo[buffer].endofline or vim.bo[buffer].fixendofline then
        text = text .. line_ending
    end
    local encoding = vim.bo[buffer].fileencoding
    if encoding ~= '' and encoding ~= 'utf-8' then
        text = vim.iconv(text, 'utf-8', encoding) or text
    end
    if vim.bo[buffer].bomb and (encoding == '' or encoding == 'utf-8') then
        text = '\239\187\191' .. text
    end
    return text
end

local function hex_lines(bytes)
    local lines = {}
    for offset = 0, #bytes - 1, BYTES_PER_LINE do
        local chunk = bytes:sub(offset + 1, offset + BYTES_PER_LINE)
        local hex_groups = {}
        for pair_start = 1, #chunk, 2 do
            hex_groups[#hex_groups + 1] = chunk:sub(pair_start, pair_start + 1):gsub('.', function(byte)
                return ('%02x'):format(byte:byte())
            end)
        end
        local hex_text = table.concat(hex_groups, ' ')
        local readable = chunk:gsub('[^\32-\126]', '.')
        lines[#lines + 1] = ('%08x: %-39s  %s'):format(offset, hex_text, readable)
    end
    if #lines == 0 then
        lines[1] = ('%08x: '):format(0)
    end
    return lines
end

-- read bytes from the hex buffer. ignore the readable column on the right;
-- only hex digits count. being readable gets you absolutely nothing here.
local function bytes_from_hex(lines)
    local pieces = {}
    for line_number, line in ipairs(lines) do
        local hex_part = line:match('^%x+:%s*(.-)%s%s') or line:match('^%x+:%s*(.*)$') or ''
        local digits = hex_part:gsub('%s', '')
        if digits:find('%X') or #digits % 2 == 1 then
            return nil, ('line %d has something that is not a pair of hex digits'):format(line_number)
        end
        pieces[#pieces + 1] = digits:gsub('%x%x', function(pair)
            return string.char(tonumber(pair, 16))
        end)
    end
    return table.concat(pieces)
end

-- put bytes back as document text, reversing document_bytes. at least this
-- shit is reversible.
local function apply_bytes(buffer, bytes)
    local encoding = vim.bo[buffer].fileencoding
    if bytes:sub(1, 3) == '\239\187\191' and (encoding == '' or encoding == 'utf-8') then
        bytes = bytes:sub(4)
    end
    if encoding ~= '' and encoding ~= 'utf-8' then
        bytes = vim.iconv(bytes, encoding, 'utf-8') or bytes
    end
    local line_ending = LINE_ENDINGS[vim.bo[buffer].fileformat] or '\n'
    if bytes:sub(-#line_ending) == line_ending then
        bytes = bytes:sub(1, -#line_ending - 1)
        vim.bo[buffer].endofline = true
    else
        vim.bo[buffer].endofline = false
    end
    api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(bytes, line_ending, { plain = true }))
end

-- write the hex buffer's bytes into its document. broken hex returns false
-- and changes nothing. i'd love my bad decisions to be this considerate.
local function commit(hex_buffer)
    local source_buffer = vim.b[hex_buffer].notebashpp_hex_source
    if not source_buffer or not api.nvim_buf_is_valid(source_buffer) then
        helpers.warn('The document behind this hex view is closed.')
        return false
    end
    local bytes, problem = bytes_from_hex(api.nvim_buf_get_lines(hex_buffer, 0, -1, false))
    if not bytes then
        helpers.warn('Hex not applied: ' .. problem)
        return false
    end
    apply_bytes(source_buffer, bytes)
    vim.bo[hex_buffer].modified = false
    return true
end

local function open_hex(source_buffer)
    local bytes = document_bytes(source_buffer)
    if #bytes > LARGEST_FILE then
        return helpers.warn(('View in HEX handles files up to %d MB.'):format(LARGEST_FILE / 1024 / 1024))
    end
    local hex_buffer = api.nvim_create_buf(true, false)
    vim.bo[hex_buffer].buftype = 'acwrite'
    vim.bo[hex_buffer].bufhidden = 'wipe'
    vim.bo[hex_buffer].swapfile = false
    vim.b[hex_buffer].notebashpp_hex_source = source_buffer
    local source_name = api.nvim_buf_get_name(source_buffer)
    api.nvim_buf_set_name(hex_buffer, (source_name ~= '' and source_name or require('notebashpp.document_tabs').name(source_buffer)) .. ' [Hex]')
    api.nvim_buf_set_lines(hex_buffer, 0, -1, false, hex_lines(bytes))
    vim.bo[hex_buffer].modified = false
    -- ctrl+s: put bytes back into the document, then save it. basically
    -- keeping the damage safe.
    api.nvim_create_autocmd('BufWriteCmd', {
        buffer = hex_buffer,
        callback = function()
            if commit(hex_buffer) then
                require('notebashpp.file_commands').save(source_buffer)
            end
        end,
    })
    api.nvim_set_current_buf(hex_buffer)
end

-- plugins > hex-editor > view in hex: open the hex tab, or return from it to
-- the document, keeping hex edits (unsaved). back to familiar misery, with
-- whatever damage you brought home.
function hex_view.toggle()
    local buffer = api.nvim_get_current_buf()
    local source_buffer = vim.b[buffer].notebashpp_hex_source
    if not source_buffer then
        return open_hex(buffer)
    end
    if vim.bo[buffer].modified and not commit(buffer) then
        return
    end
    if api.nvim_buf_is_valid(source_buffer) then
        api.nvim_set_current_buf(source_buffer)
    end
    pcall(api.nvim_buf_delete, buffer, { force = true })
end

return hex_view
