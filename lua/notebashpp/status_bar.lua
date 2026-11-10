-- the notepad++ status bar: language | length : n  lines : n | ln : n  col :
-- n  pos : n | eol | encoding | ins i wanted my document reduced to numbers
-- at the bottom of the screen. basically a death certificate with absolutely
-- no promise of rest.

local status_bar = {}
local api = vim.api

-- the notepad++ language name for each neovim filetype. anything missing gets
-- its filetype with a capital letter and " file" appended. i'd love to have
-- an identity too. apparently a suffix is enough.
local LANGUAGE_DESCRIPTIONS = {
    [''] = 'Normal text file',
    text = 'Normal text file',
    c = 'C source file',
    cpp = 'C++ source file',
    cs = 'C# source file',
    css = 'Cascading Style Sheets File',
    go = 'Go source file',
    html = 'Hyper Text Markup Language file',
    java = 'Java source file',
    javascript = 'JavaScript file',
    typescript = 'TypeScript file',
    json = 'JSON file',
    lua = 'Lua source File',
    markdown = 'Markdown',
    php = 'PHP Hypertext Preprocessor file',
    python = 'Python file',
    ruby = 'Ruby file',
    rust = 'Rust file',
    sh = 'Unix script file',
    bash = 'Unix script file',
    sql = 'Structured Query Language file',
    xml = 'eXtensible Markup Language file',
    yaml = "YAML Ain't Markup Language",
    dosbatch = 'Batch file',
    ps1 = 'PowerShell file',
    ini = 'MS ini file',
    vim = 'Vim script file',
    toml = 'TOML file',
    csv = 'Normal text file',
    tsv = 'Normal text file',
}

-- neovim's fileformat names to notepad++ line ending names. same shit,
-- different paperwork.
local LINE_ENDING_NAMES = { dos = 'Windows (CR LF)', unix = 'Unix (LF)', mac = 'Macintosh (CR)' }

-- 1234567 becomes "1,234,567", commas every three digits from the right, as
-- in notepad++. i want my debt formatted this nicely. it won't stop the
-- bleeding, but apparently presentation matters.
local function group_thousands(number)
    local digits = tostring(number)
    local grouped = digits:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (grouped:gsub('^,', ''))
end

-- encoding names as notepad++ shows them. empty fileencoding uses 'encoding'.
-- utf-16 always says "bom": those are its only entries in notepad++'s
-- encoding menu. latin1 counts as ansi. unknown encodings keep their names.
-- basically everyone gets a label. i spent years getting nowhere for free.
local function encoding_label(buffer)
    local file_encoding = vim.bo[buffer].fileencoding
    if file_encoding == '' then
        file_encoding = vim.o.encoding
    end
    local has_bom = vim.bo[buffer].bomb
    if file_encoding == 'utf-8' then
        return has_bom and 'UTF-8-BOM' or 'UTF-8'
    elseif file_encoding == 'utf-16le' or file_encoding == 'ucs-2le' then
        return 'UTF-16 LE BOM'
    elseif file_encoding == 'utf-16' or file_encoding == 'ucs-2' then
        return 'UTF-16 BE BOM'
    elseif file_encoding == 'latin1' or file_encoding == 'cp1252' then
        return 'ANSI'
    elseif file_encoding == 'cp1255' then
        return 'Windows-1255'
    end
    return file_encoding
end

-- build the status line for the window being drawn; 'statusline' supplies
-- g:statusline_winid. length & pos count bytes as notepad++ sees them on
-- disk, so crlf counts two bytes per line end. col is the screen column,
-- 1-based. floats (menus, the find dialog, the ctrl+tab list) aren't
-- documents. keep describing the actual text in the window underneath. i
-- opened a dialog to escape my work and the damn numbers followed me.
-- apparently even avoidance needs better implementation.
-- side panels (the json tree) count as floating here: the status bar keeps
-- describing the document next to them. a panel has no length worth
-- reporting. neither do my weekends.
local function is_floating(window)
    return api.nvim_win_get_config(window).relative ~= '' or vim.b[api.nvim_win_get_buf(window)].notebashpp_panel ~= nil
end

local function document_window(window)
    if not is_floating(window) then
        return window
    end
    local previous_window = vim.fn.win_getid(vim.fn.winnr('#'))
    if previous_window ~= 0 and not is_floating(previous_window) then
        return previous_window
    end
    for _, candidate in ipairs(api.nvim_tabpage_list_wins(0)) do
        if not is_floating(candidate) then
            return candidate
        end
    end
    return window
end

-- words in the document, counted by neovim's wordcount() as runs of non-blank
-- characters. notepad++ refused this (issue 1136, 52 votes). basically we can
-- count words, but apparently hope is too fucking expensive. count once per
-- change, never per redraw; skip past 20 mb so a huge log doesn't pay for the
-- count on every keystroke. i'm already wasting my life.
local word_count_cache = {}
local function word_count(buffer, byte_count)
    if byte_count > 20 * 1024 * 1024 then
        return nil
    end
    local change_number = vim.b[buffer].changedtick
    local cached = word_count_cache[buffer]
    if cached and cached.change_number == change_number then
        return cached.words
    end
    local words = api.nvim_buf_call(buffer, function()
        return vim.fn.wordcount().words
    end)
    word_count_cache[buffer] = { change_number = change_number, words = words }
    return words
end

function status_bar.render()
    local window = document_window(vim.g.statusline_winid or api.nvim_get_current_win())
    local buffer = api.nvim_win_get_buf(window)
    local filetype = vim.bo[buffer].filetype
    local language = LANGUAGE_DESCRIPTIONS[filetype] or (filetype:gsub('^%l', string.upper) .. ' file')
    local line_count = api.nvim_buf_line_count(buffer)
    local byte_count = api.nvim_buf_get_offset(buffer, line_count)
    local line_ending_bytes = vim.bo[buffer].fileformat == 'dos' and 2 or 1
    -- count actual line ends, like notepad++. the last line gets one only if
    -- 'endofline' says so. i want at least this accounting to be honest. my
    -- remaining years can keep their fraudulent estimate.
    -- nvim_buf_get_offset already counts one byte per line end it would
    -- write, so take those out before adding the real ones back. the old
    -- math came up one short on every new file, which is also how my
    -- paychecks work.
    local writes_last_line_end = vim.bo[buffer].endofline or (vim.bo[buffer].fixendofline and not vim.bo[buffer].binary)
    local line_end_count = line_count - 1 + (writes_last_line_end and 1 or 0)
    local length = math.max(0, byte_count - line_end_count) + line_end_count * line_ending_bytes
    local cursor = api.nvim_win_get_cursor(window)
    -- headless startup can report row 0 before the first window settles.
    -- row 0 isn't a line. it's where i keep my expectations.
    cursor[1] = math.max(1, math.min(cursor[1], line_count))
    local cursor_line_text = api.nvim_buf_get_lines(buffer, cursor[1] - 1, cursor[1], false)[1] or ''
    local column = vim.fn.strdisplaywidth(cursor_line_text:sub(1, cursor[2])) + 1
    local byte_offset = api.nvim_buf_get_offset(buffer, cursor[1] - 1) + (line_ending_bytes - 1) * (cursor[1] - 1) + cursor[2]
    local position_text
    local mode = vim.fn.mode()
    -- while selecting, replace pos with "sel : characters | lines", like
    -- notepad++. count characters, not bytes, plus one per line break for
    -- crlf. even a line break gets to count for more. what the hell am i
    -- doing.
    if window == api.nvim_get_current_win() and (mode == 'v' or mode == 's' or mode == 'V' or mode == 'S') then
        local selection = require('notebashpp.helpers').get_selection()
        if selection then
            local selected_text = table.concat(require('notebashpp.helpers').get_text_in_range(selection), '\n')
            local character_count = vim.fn.strchars(selected_text) + (line_ending_bytes - 1) * (selection.end_line - selection.start_line)
            position_text = ('Ln : %d    Col : %d    Sel : %s | %d'):format(
                cursor[1],
                column,
                group_thousands(character_count),
                selection.end_line - selection.start_line + 1
            )
        end
    end
    if not position_text then
        position_text = ('Ln : %d    Col : %d    Pos : %s'):format(cursor[1], column, group_thousands(byte_offset + 1))
    end
    -- ovr in replace mode, ins otherwise. insert is the default. i can
    -- overwrite text. the years spent on this crap are permanent.
    local typing_mode = (mode == 'R' or vim.fn.mode(1) == 'Rv') and 'OVR' or 'INS'
    local recording_badge = require('notebashpp.macros').recording() and '%#ErrorMsg# Recording %*' or ''
    local right_to_left_badge = vim.wo[window].rightleft and ' RTL ' or ''
    local line_ending_name = LINE_ENDING_NAMES[vim.bo[buffer].fileformat] or vim.bo[buffer].fileformat
    local words = word_count(buffer, byte_count)
    local length_field = ('  length : %s    lines : %s  '):format(group_thousands(length), group_thousands(line_count))
    if words then
        length_field = ('  length : %s    lines : %s    words : %s  '):format(group_thousands(length), group_thousands(line_count), group_thousands(words))
    end
    local encoding_text = encoding_label(buffer)
    -- 'statusline' runs this text through %{%...%}, so a lone % in a buffer
    -- option is a format item, and %{} in one is code. a modeline once set
    -- fileencoding to %{v:lua.os.execute(...)} and it ran on open. double
    -- every %. strangers' files get the same trust my family gives me.
    language = language:gsub('%%', '%%%%')
    line_ending_name = line_ending_name:gsub('%%', '%%%%')
    encoding_text = encoding_text:gsub('%%', '%%%%')
    -- a spreadsheet or large file view reports its whole file, not just the
    -- lines on screen. hiding the rest doesn't make the shit go away.
    local special_status = require('notebashpp.special_views').status(buffer)
    if special_status then
        language = special_status.language
        position_text = special_status.position
        length_field = special_status.length
        line_ending_name = special_status.line_ending or line_ending_name
        encoding_text = special_status.encoding or encoding_text
        typing_mode = special_status.language:find('read%-only') and 'R/O' or typing_mode
    end
    -- the full notepad++ status bar needs about 110 columns. on narrow
    -- screens, drop length first, shorten the line ending name, then squeeze
    -- the spaces in the position. encoding & ins stay to the end. i spent my
    -- finite life deciding which numbers deserve to survive. please at least
    -- leave enough room to read your work.
    local function assemble(show_length, short_line_ending, compact_position)
        local shown_position = compact_position and position_text:gsub(' : ', ':'):gsub('    ', ' ') or position_text
        local shown_line_ending = short_line_ending and (line_ending_name:match('%((.-)%)') or line_ending_name) or line_ending_name
        return {
            ' ',
            language,
            '%=',
            recording_badge,
            show_length and length_field or '  ',
            '│ ',
            shown_position,
            '  ',
            '│ ',
            shown_line_ending,
            '  ',
            '│ ',
            encoding_text,
            '  ',
            '│ ',
            right_to_left_badge,
            typing_mode,
            ' ',
        }
    end
    local function plain_width(parts)
        local text = table.concat(parts):gsub('%%%%', '%%'):gsub('%%#[^#]*#', ''):gsub('%%%*', ''):gsub('%%=', '')
        return vim.fn.strdisplaywidth(text)
    end
    local parts
    for _, attempt in ipairs({ { true, false, false }, { false, false, false }, { false, true, false }, { false, true, true } }) do
        parts = assemble(attempt[1], attempt[2], attempt[3])
        if plain_width(parts) <= vim.o.columns then
            break
        end
    end
    return table.concat(parts)
end

function status_bar.setup()
    vim.o.statusline = '%{%v:lua.require("notebashpp.status_bar").render()%}'
end

return status_bar
