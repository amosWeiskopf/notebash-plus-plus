-- column mode: alt+shift+arrows, alt+drag, alt+shift+b.
--
-- a rectangle from anchor to caret, measured in display columns. typing,
-- backspace, delete, tab, cut, copy and paste affect every line at once,
-- copying scintilla's rectangular selection & multi-caret typing. basically i
-- can now fuck up several places simultaneously. columns past a line's end
-- are virtual space, filled with real spaces once text goes there. even
-- nothing eventually becomes my problem.

local column_mode = {}
local api = vim.api
local helpers = require('notebashpp.helpers')
local highlight_namespace = api.nvim_create_namespace('notebashpp_column')

-- the live rectangle, or nil when column mode is off. holds the buffer,
-- anchor and caret as { line, display column }, our last real cursor byte
-- position (expected_cursor), and whether we are mid-typing. i keep better
-- records of this crap than of my own life.
---@class notebashpp.column_rectangle
---@field buffer integer
---@field anchor integer[]
---@field caret integer[]
---@field expected_cursor? integer[]
---@field typing? boolean

---@type notebashpp.column_rectangle?
local rectangle = nil

-- the rectangle for code that only runs with column mode on. call it with
-- column mode off and get a clear error, instead of lua's nil-indexing
-- riddle. basically i want to know why i'm fucked, in plain english.
---@return notebashpp.column_rectangle
local function live_rectangle()
    return assert(rectangle, 'column mode is off')
end

-- the byte offset where `display_column` starts in `line_text`, plus spaces
-- needed if the line cannot reach it. tabs reach the next tabstop; wide
-- characters count wide. even empty space has accounting. i wanted a text
-- editor. apparently i wanted unpaid work.
local function byte_at_display_column(line_text, display_column)
    local tabstop = vim.bo.tabstop
    local current_column, byte_offset = 0, 0
    while byte_offset < #line_text do
        if current_column >= display_column then
            return byte_offset, 0
        end
        local lead_byte = line_text:byte(byte_offset + 1)
        local character_length = lead_byte >= 0xF0 and 4 or lead_byte >= 0xE0 and 3 or lead_byte >= 0xC0 and 2 or 1
        local character = line_text:sub(byte_offset + 1, byte_offset + character_length)
        local character_width = character == '\t' and (tabstop - current_column % tabstop) or vim.fn.strdisplaywidth(character)
        -- a wide character owns any column it straddles. rent is still due.
        if current_column + character_width > display_column then
            return byte_offset, 0
        end
        current_column = current_column + character_width
        byte_offset = byte_offset + character_length
    end
    return #line_text, display_column - current_column
end

local function display_column_of(line_text, byte_offset)
    return vim.fn.strdisplaywidth(line_text:sub(1, byte_offset))
end

-- multi-editing measures display columns the same way. same fucking hell.
column_mode.byte_at_display_column = byte_at_display_column

-- column mode is active only in its starting buffer. leave and you stop
-- counting. absolutely familiar.
function column_mode.active()
    return rectangle ~= nil and rectangle.buffer == api.nvim_get_current_buf()
end

-- top & bottom line, left & right display column, regardless of anchor and
-- caret order. at least this mess has boundaries.
local function rectangle_bounds()
    local current = live_rectangle()
    local top_line, bottom_line = math.min(current.anchor[1], current.caret[1]), math.max(current.anchor[1], current.caret[1])
    local left_column, right_column = math.min(current.anchor[2], current.caret[2]), math.max(current.anchor[2], current.caret[2])
    return top_line, bottom_line, left_column, right_column
end

-- paint with extmarks: highlight real text, draw the rectangle's overhang
-- past short lines as virtual spaces. i am carefully colouring nothing while
-- my remaining years go to shit. looks quite nice though.
local function render()
    local current = live_rectangle()
    api.nvim_buf_clear_namespace(current.buffer, highlight_namespace, 0, -1)
    local top_line, bottom_line, left_column, right_column = rectangle_bounds()
    for line_number = top_line, bottom_line do
        local line_text = helpers.get_line_text(line_number, current.buffer)
        local left_byte, left_padding = byte_at_display_column(line_text, left_column)
        local right_byte, right_padding = byte_at_display_column(line_text, right_column)
        if right_column > left_column then
            if right_byte > left_byte then
                api.nvim_buf_set_extmark(
                    current.buffer,
                    highlight_namespace,
                    line_number - 1,
                    left_byte,
                    { end_col = right_byte, hl_group = 'NotebashColumn', priority = 300 }
                )
            end
            -- past the line's end: the whole rectangle width if the line ends
            -- before its left edge, only the overhang if it ends inside.
            -- measure the absence. apparently i needed another fucking task.
            local virtual_width = right_padding - left_padding
            if left_padding > 0 then
                virtual_width = right_column - left_column
            elseif right_padding > 0 then
                virtual_width = right_padding
            end
            if virtual_width > 0 then
                api.nvim_buf_set_extmark(current.buffer, highlight_namespace, line_number - 1, 0, {
                    virt_text = { { string.rep(' ', virtual_width), 'NotebashColumn' } },
                    virt_text_win_col = (left_padding > 0) and left_column or display_column_of(line_text, #line_text),
                    priority = 300,
                })
            end
        elseif line_number ~= current.caret[1] then
            -- zero width: a thin fake caret on every line except the caret's
            -- own (that one already has the real cursor). highlight one
            -- character, or one virtual space past the end. even my
            -- substitutes are empty.
            if left_padding == 0 and left_byte < #line_text then
                local character_length = #(vim.fn.strcharpart(line_text:sub(left_byte + 1), 0, 1))
                api.nvim_buf_set_extmark(
                    current.buffer,
                    highlight_namespace,
                    line_number - 1,
                    left_byte,
                    { end_col = left_byte + character_length, hl_group = 'NotebashColumn', priority = 300 }
                )
            else
                api.nvim_buf_set_extmark(current.buffer, highlight_namespace, line_number - 1, 0, {
                    virt_text = { { ' ', 'NotebashColumn' } },
                    virt_text_win_col = left_column,
                    priority = 300,
                })
            end
        end
    end
end

-- put the real cursor at the rectangle's caret; remember its position so
-- cursormoved can distinguish our moves from somebody else's. from selection
-- or normal mode, use keys and finish in insert. already in insert:
-- nvim_win_set_cursor is enough. i track a cursor this carefully and still
-- have absolutely no idea where i'm going.
local function place()
    local current = live_rectangle()
    local line_text = helpers.get_line_text(current.caret[1])
    local caret_byte = byte_at_display_column(line_text, current.caret[2])
    current.expected_cursor = { current.caret[1], caret_byte }
    if helpers.is_selecting() or vim.fn.mode() == 'n' then
        helpers.feed_keys(('<C-\\><C-n><Cmd>call cursor(%d,%d)<CR>i'):format(current.caret[1], caret_byte + 1))
    else
        api.nvim_win_set_cursor(0, current.expected_cursor)
    end
end

function column_mode._unload()
    column_mode.clear()
end

-- end column mode: clear highlighting with pcall (the buffer may already be
-- gone), then forget the rectangle. grief on a budget.
function column_mode.clear()
    if rectangle then
        pcall(api.nvim_buf_clear_namespace, rectangle.buffer, highlight_namespace, 0, -1)
    end
    rectangle = nil
end

-- zero-width rectangle, anchor & caret at the caret. ambition: zero.
local function start_rectangle_at_caret()
    local caret = helpers.get_caret()
    local line_text = helpers.get_line_text(caret[1])
    local display_column = display_column_of(line_text, math.min(caret[2], #line_text))
    rectangle = { buffer = api.nvim_get_current_buf(), anchor = { caret[1], display_column }, caret = { caret[1], display_column } }
    return rectangle
end

-- select a rectangle between two byte positions.
function column_mode.select(anchor_position, caret_position)
    rectangle = {
        buffer = api.nvim_get_current_buf(),
        anchor = { anchor_position[1], display_column_of(helpers.get_line_text(anchor_position[1]), anchor_position[2]) },
        caret = { caret_position[1], display_column_of(helpers.get_line_text(caret_position[1]), caret_position[2]) },
    }
    render()
    place()
end

-- the current buffer's live rectangle: { anchor, caret }, each { line,
-- display column }, or nil when column mode is off here. session restore uses
-- this and select_display_columns() to bring a rectangle back. basically
-- resurrection, wasted on this shit instead of someone i miss.
function column_mode.corners()
    if not column_mode.active() then
        return nil
    end
    local current = live_rectangle()
    return { anchor = { current.anchor[1], current.anchor[2] }, caret = { current.caret[1], current.caret[2] } }
end

-- select a rectangle between two { line, display column } corners. display
-- columns can go past a line's end (virtual space); byte positions cannot
-- express that. my retirement savings also live in imaginary space.
function column_mode.select_display_columns(anchor, caret)
    local last_line = helpers.count_lines()
    local function clamped(corner)
        return { math.max(1, math.min(corner[1], last_line)), math.max(0, corner[2]) }
    end
    rectangle = { buffer = api.nvim_get_current_buf(), anchor = clamped(anchor), caret = clamped(caret) }
    render()
    place()
end

-- alt+shift+arrow and friends move the rectangle's caret one step. right has
-- no limit; virtual space goes as far as you like. finally an unlimited
-- supply of fuck all. home uses the usual smart home (indent, then column 0),
-- measured in display columns.
function column_mode.extend(direction)
    if not column_mode.active() then
        require('notebashpp.multi_editing').clear()
        local selection = helpers.get_selection()
        local started = start_rectangle_at_caret()
        if selection then
            -- use the stream selection's anchor, as scintilla does. inherit
            -- the crap.
            local visual_start = vim.fn.getpos('v')
            started.anchor = { visual_start[2], display_column_of(helpers.get_line_text(visual_start[2]), visual_start[3] - 1) }
        end
    end
    local current = live_rectangle()
    current.typing = false
    local last_line = helpers.count_lines()
    local page_height = math.max(1, api.nvim_win_get_height(0) - 1)
    local caret = current.caret
    if direction == 'up' then
        caret[1] = math.max(1, caret[1] - 1)
    elseif direction == 'down' then
        caret[1] = math.min(last_line, caret[1] + 1)
    elseif direction == 'left' then
        caret[2] = math.max(0, caret[2] - 1)
    elseif direction == 'right' then
        caret[2] = caret[2] + 1
    elseif direction == 'page_up' then
        caret[1] = math.max(1, caret[1] - page_height)
    elseif direction == 'page_down' then
        caret[1] = math.min(last_line, caret[1] + page_height)
    elseif direction == 'home' then
        local line_text = helpers.get_line_text(caret[1])
        local indent = #(line_text:match('^[ \t]*'))
        local indent_column = display_column_of(line_text, indent)
        caret[2] = (caret[2] == indent_column) and 0 or indent_column
    elseif direction == 'end' then
        caret[2] = display_column_of(helpers.get_line_text(caret[1]), #helpers.get_line_text(caret[1]))
    end
    render()
    place()
end

-- rewrite each rectangle line with rewrite_line(line_text, left_byte,
-- right_byte, left_padding), which returns the new line. keep all lines in
-- one undo step. while typing, undojoin also joins each keystroke to the
-- last, so one ctrl+z undoes the whole typing run. i want this for my life.
-- apparently only the shit i type qualifies.
local function rewrite_rectangle_lines(rewrite_line)
    local current = live_rectangle()
    local top_line, bottom_line, left_column, right_column = rectangle_bounds()
    local lines = helpers.get_lines_text(top_line, bottom_line)
    for line_index, line_text in ipairs(lines) do
        local left_byte, left_padding = byte_at_display_column(line_text, left_column)
        local right_byte = byte_at_display_column(line_text, right_column)
        lines[line_index] = rewrite_line(line_text, left_byte, right_byte, left_padding)
    end
    if current.typing then
        pcall(vim.api.nvim_command, 'undojoin')
    end
    api.nvim_buf_set_lines(0, top_line - 1, bottom_line, false, lines)
end

-- insert typed text on every line at the caret column, replacing the
-- rectangle's contents; pad short lines with spaces to reach it. then shrink
-- to zero width just after the new text. all that work and i'm back to
-- nothing, slightly further to the right.
function column_mode.insert(text)
    local current = live_rectangle()
    local _, _, left_column = rectangle_bounds()
    rewrite_rectangle_lines(function(line_text, left_byte, right_byte, left_padding)
        return line_text:sub(1, left_byte) .. string.rep(' ', left_padding) .. text .. line_text:sub(right_byte + 1)
    end)
    local text_width = vim.fn.strdisplaywidth(text)
    current.anchor[2] = left_column + text_width
    current.caret[2] = left_column + text_width
    current.typing = true
    render()
    place()
end

-- direction -1: backspace. +1: delete. a nonzero-width rectangle loses its
-- contents; zero width deletes one character per line before or after the
-- caret column. destruction is super easy to parallelize.
function column_mode.delete(direction)
    local current = live_rectangle()
    local _, _, left_column, right_column = rectangle_bounds()
    if right_column > left_column then
        rewrite_rectangle_lines(function(line_text, left_byte, right_byte)
            return line_text:sub(1, left_byte) .. line_text:sub(right_byte + 1)
        end)
        current.anchor[2], current.caret[2] = left_column, left_column
    elseif direction < 0 then
        if left_column == 0 then
            return
        end
        -- measure the preceding character's width on the caret's own line.
        -- every other line steps back that many columns, whatever is there.
        -- lines that do not reach the column stay untouched. i would love the
        -- same courtesy when i have absolutely nothing left to give.
        local caret_line_text = helpers.get_line_text(current.caret[1])
        local caret_byte = byte_at_display_column(caret_line_text, left_column)
        local previous_width = 1
        if caret_byte > 0 then
            local text_before_caret = caret_line_text:sub(1, caret_byte)
            local last_character = vim.fn.strcharpart(text_before_caret, vim.fn.strchars(text_before_caret) - 1)
            previous_width = math.max(1, display_column_of(caret_line_text, caret_byte) - display_column_of(caret_line_text, caret_byte - #last_character))
        end
        local target_column = left_column - previous_width
        rewrite_rectangle_lines(function(line_text, left_byte, _, left_padding)
            if left_padding > 0 then
                return line_text
            end
            local target_byte = byte_at_display_column(line_text, target_column)
            return line_text:sub(1, target_byte) .. line_text:sub(left_byte + 1)
        end)
        current.anchor[2], current.caret[2] = target_column, target_column
    else
        rewrite_rectangle_lines(function(line_text, left_byte)
            if left_byte >= #line_text then
                return line_text
            end
            local character_length = #(vim.fn.strcharpart(line_text:sub(left_byte + 1), 0, 1))
            return line_text:sub(1, left_byte) .. line_text:sub(left_byte + 1 + character_length)
        end)
    end
    current.typing = true
    render()
    place()
end

-- rectangle text, one string per line. lines too short to reach it return an
-- empty string. basically my answer to 'how is life?'
function column_mode.text()
    local top_line, bottom_line, left_column, right_column = rectangle_bounds()
    local rectangle_text = {}
    for line_number = top_line, bottom_line do
        local line_text = helpers.get_line_text(line_number)
        local left_byte = byte_at_display_column(line_text, left_column)
        local right_byte = byte_at_display_column(line_text, right_column)
        rectangle_text[#rectangle_text + 1] = line_text:sub(left_byte + 1, right_byte)
    end
    return rectangle_text
end

-- each rectangle line as { line, left byte, right byte }, kept inside the
-- line's text (no virtual space), plus the caret's line and whether the caret
-- is on the rectangle's right edge. edit > column mode to carets turns these
-- into carets. i spent actual, non-refundable life on this.
function column_mode.line_ranges()
    local current = live_rectangle()
    local top_line, bottom_line, left_column, right_column = rectangle_bounds()
    local line_ranges = {}
    for line_number = top_line, bottom_line do
        local line_text = helpers.get_line_text(line_number, current.buffer)
        local left_byte = byte_at_display_column(line_text, left_column)
        local right_byte = byte_at_display_column(line_text, right_column)
        line_ranges[#line_ranges + 1] = { line_number, left_byte, right_byte }
    end
    return line_ranges, current.caret[1], current.caret[2] >= current.anchor[2]
end

-- copy as block ('b'); paste returns a rectangle. crap keeps its shape.
function column_mode.copy()
    require('notebashpp.clipboard').set(column_mode.text(), 'b')
end

function column_mode.cut()
    column_mode.copy()
    column_mode.delete(1)
end

-- paste one line of plain text onto every rectangle line, like typing.
-- anything else pastes as a rectangle, its top-left at our top-left, then
-- ends column mode. even this shit knows when to leave.
function column_mode.paste()
    local lines, clipboard_kind = require('notebashpp.clipboard').get()
    if clipboard_kind ~= 'b' and #lines == 1 then
        local _, _, left_column, right_column = rectangle_bounds()
        if right_column > left_column then
            column_mode.delete(1)
        end
        column_mode.insert(lines[1])
        return
    end
    local top_line, _, left_column, right_column = rectangle_bounds()
    if right_column > left_column then
        column_mode.delete(1)
    end
    local line_text = helpers.get_line_text(top_line)
    local left_byte = byte_at_display_column(line_text, left_column)
    column_mode.clear()
    column_mode.paste_block(lines, { top_line, left_byte }, left_column)
    helpers.move_caret_to({ top_line, byte_at_display_column(helpers.get_line_text(top_line), left_column) })
end

-- paste `lines` as a rectangle at byte position `top_left`, or at
-- `display_column` when supplied. append empty lines if the block runs past
-- the buffer's end; pad short lines with spaces to align every row. i keep
-- making room for crap. a transferable life skill.
function column_mode.paste_block(lines, top_left, display_column)
    display_column = display_column or display_column_of(helpers.get_line_text(top_left[1]), top_left[2])
    local last_line = helpers.count_lines()
    if top_left[1] + #lines - 1 > last_line then
        local extra_lines = {}
        for _ = 1, top_left[1] + #lines - 1 - last_line do
            extra_lines[#extra_lines + 1] = ''
        end
        api.nvim_buf_set_lines(0, last_line, last_line, false, extra_lines)
    end
    local target_lines = helpers.get_lines_text(top_left[1], top_left[1] + #lines - 1)
    for line_index, line_text in ipairs(target_lines) do
        local insert_byte, padding = byte_at_display_column(line_text, display_column)
        target_lines[line_index] = line_text:sub(1, insert_byte) .. string.rep(' ', padding) .. lines[line_index] .. line_text:sub(insert_byte + 1)
    end
    api.nvim_buf_set_lines(0, top_left[1] - 1, top_left[1] - 1 + #target_lines, false, target_lines)
end

-- run convert on each line's rectangle text. used for case conversion, so i
-- can shout at words when shouting at my life achieves fuck all.
function column_mode.map_text(convert)
    rewrite_rectangle_lines(function(line_text, left_byte, right_byte)
        return line_text:sub(1, left_byte) .. convert(line_text:sub(left_byte + 1, right_byte)) .. line_text:sub(right_byte + 1)
    end)
    render()
end

-- any other motion ends column mode and proceeds from the caret. wipe
-- highlights from every buffer later through vim.schedule, after the calling
-- expr mapping finishes. even forgetting this damn thing requires an
-- appointment.
function column_mode.motion_keys(motion_name, extend)
    rectangle = nil
    vim.schedule(function()
        for _, buffer in ipairs(api.nvim_list_bufs()) do
            pcall(api.nvim_buf_clear_namespace, buffer, highlight_namespace, 0, -1)
        end
    end)
    return require('notebashpp.caret_movement').keys(motion_name, extend)
end

-- whole numbers only, like notepad++'s column editor, within 2^53 so lua
-- still counts them exactly. tonumber() alone also accepts 1e309 (infinity).
-- halving infinity until it reaches zero would loop forever. basically my
-- retirement plan, except this shit will still be running after i'm dead. i
-- want to leave something behind (preferably something that terminates).
local function whole_number(text)
    local number = text and text:match('^%s*([-+]?%d+)%s*$') and tonumber(text)
    if number and math.abs(number) <= 2 ^ 53 then
        return number
    end
end

-- edit > column editor (alt+c): insert text or numbers at the caret column on
-- rectangle lines, or from the caret line to end of file without a rectangle.
-- numbers use notepad++'s initial number, increase by, repeat, format and
-- leading options. the dialog is a row of input() prompts. this is what my
-- unpaid life can afford.
function column_mode.editor()
    local first_line, last_line, insert_column
    if column_mode.active() then
        local top_line, bottom_line, left_column = rectangle_bounds()
        first_line, last_line, insert_column = top_line, bottom_line, left_column
    else
        local caret = helpers.get_caret()
        first_line, last_line = caret[1], helpers.count_lines()
        insert_column = display_column_of(helpers.get_line_text(caret[1]), caret[2])
    end
    local text = helpers.ask('Column Editor - text to insert (empty for numbers): ')
    local values = {}
    if text ~= '' then
        for line_index = 1, last_line - first_line + 1 do
            values[line_index] = text
        end
    else
        local initial_number = whole_number(helpers.ask('Initial number: ', '1'))
        if not initial_number then
            return
        end
        local increment = whole_number(helpers.ask('Increase by: ', '1')) or 1
        local repeat_count = math.max(1, whole_number(helpers.ask('Repeat: ', '1')) or 1)
        local number_format = helpers.ask('Format (dec, hex, oct, bin): ', 'dec')
        local leading = helpers.ask('Leading (none, zeros, spaces): ', 'none')
        local formatted_numbers = {}
        local current_number = initial_number
        for line_index = 1, last_line - first_line + 1 do
            local formatted
            if number_format == 'hex' then
                formatted = ('%X'):format(current_number)
            elseif number_format == 'oct' then
                formatted = ('%o'):format(current_number)
            elseif number_format == 'bin' then
                -- lua has no binary format, so divide by two until nothing
                -- remains. basically retirement planning, with a loop i can
                -- actually finish.
                local binary_digits, remaining = {}, math.floor(math.abs(current_number))
                repeat
                    table.insert(binary_digits, 1, tostring(remaining % 2))
                    remaining = math.floor(remaining / 2)
                until remaining == 0
                formatted = (current_number < 0 and '-' or '') .. table.concat(binary_digits)
            else
                formatted = tostring(current_number)
            end
            formatted_numbers[line_index] = formatted
            -- repeat each number repeat_count times before increasing. shit
            -- persists.
            if line_index % repeat_count == 0 then
                current_number = current_number + increment
            end
        end
        -- pad to the widest number: zeros or spaces before, or spaces after
        -- when leading is none. text right of the column stays aligned. my
        -- life is falling apart but the fucking numbers look excellent.
        local widest = 0
        for _, formatted in ipairs(formatted_numbers) do
            widest = math.max(widest, #formatted)
        end
        for line_index, formatted in ipairs(formatted_numbers) do
            local padding = widest - #formatted
            if leading == 'zeros' then
                values[line_index] = string.rep('0', padding) .. formatted
            elseif leading == 'spaces' then
                values[line_index] = string.rep(' ', padding) .. formatted
            else
                values[line_index] = formatted .. string.rep(' ', padding)
            end
        end
    end
    local lines = helpers.get_lines_text(first_line, last_line)
    for line_index, line_text in ipairs(lines) do
        local insert_byte, padding = byte_at_display_column(line_text, insert_column)
        lines[line_index] = line_text:sub(1, insert_byte) .. string.rep(' ', padding) .. values[line_index] .. line_text:sub(insert_byte + 1)
    end
    api.nvim_buf_set_lines(0, first_line - 1, last_line, false, lines)
    column_mode.clear()
end

-- alt+drag: press starts a rectangle at the mouse; drag moves its caret.
-- column is screen position minus gutter (textoff), allowing virtual space
-- past the line's end. ignore clicks outside any text. i want to select
-- nothing, but apparently there is a proper place to do that. even the void
-- has petty fucking rules.
function column_mode.mouse(drag)
    local mouse_position = vim.fn.getmousepos()
    if mouse_position.winid == 0 or mouse_position.line == 0 then
        return
    end
    if mouse_position.winid ~= api.nvim_get_current_win() then
        api.nvim_set_current_win(mouse_position.winid)
    end
    local display_column = math.max(0, mouse_position.wincol - 1 - vim.fn.getwininfo(mouse_position.winid)[1].textoff)
    require('notebashpp.multi_editing').clear()
    if not drag or not column_mode.active() then
        rectangle = { buffer = api.nvim_get_current_buf(), anchor = { mouse_position.line, display_column }, caret = { mouse_position.line, display_column } }
    else
        live_rectangle().caret = { mouse_position.line, display_column }
    end
    render()
    place()
end

function column_mode.setup()
    local augroup = api.nvim_create_augroup('notebashpp_column', { clear = true })
    -- typed characters go to every rectangle line. empty v:char here and
    -- insert next tick: insertcharpre cannot change the buffer. i am allowed
    -- to want things, provided i wait. familiar crap.
    api.nvim_create_autocmd('InsertCharPre', {
        group = augroup,
        callback = function()
            if not column_mode.active() then
                return
            end
            local typed_character = vim.v.char
            vim.v.char = ''
            vim.schedule(function()
                if column_mode.active() then
                    column_mode.insert(typed_character)
                end
            end)
        end,
    })
    -- cursor moved somewhere we did not put it: something else took over, so
    -- end column mode. losing control is my most reliable feature.
    api.nvim_create_autocmd({ 'CursorMovedI', 'CursorMoved' }, {
        group = augroup,
        callback = function()
            if not rectangle then
                return
            end
            if not column_mode.active() then
                return column_mode.clear()
            end
            local caret = helpers.get_caret()
            if rectangle.expected_cursor and (caret[1] ~= rectangle.expected_cursor[1] or caret[2] ~= rectangle.expected_cursor[2]) then
                column_mode.clear()
            end
        end,
    })
    -- leaving buffer or window ends column mode too. good riddance.
    api.nvim_create_autocmd({ 'BufLeave', 'WinLeave' }, {
        group = augroup,
        callback = function()
            column_mode.clear()
        end,
    })
end

return column_mode
