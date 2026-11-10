-- caret movement by scintilla's rules: word & paragraph jumps, smart home,
-- shift to stretch a selection, plain keys to drop it. i want this blinking
-- bastard to move properly. apparently that requires most of a file.
--
-- each motion is normal-mode keys (`keys`) or a lua function returning the
-- new caret position (`fn`). expr() wraps it for typing (insert), selections
-- (select) and plain windows. basically a permit to move before we die.

local caret_movement = {}
local api = vim.api
local helpers = require('notebashpp.helpers')

-- scintilla's character classes (document::wordcharacterclass). four kinds of
-- character. i needed fewer categories to classify my life's failures.
local SPACE, NEWLINE, WORD, PUNCTUATION = 1, 2, 3, 4

local function character_class_of(character)
    if character == nil then
        return nil
    end
    if character == '\n' then
        return NEWLINE
    end
    if character == ' ' or character == '\t' then
        return SPACE
    end
    local first_byte = character:byte()
    if first_byte >= 128 or character:match('[%w_]') then
        return WORD
    end
    return PUNCTUATION
end

-- utf-8 character length in bytes, judged from the first byte alone. i've
-- committed to worse decisions with absolutely less information.
local function utf8_sequence_length(lead_byte)
    if lead_byte >= 0xF0 then
        return 4
    elseif lead_byte >= 0xE0 then
        return 3
    elseif lead_byte >= 0xC0 then
        return 2
    end
    return 1
end

-- walk the whole buffer. every line except the last ends with a "\n"
-- character. the last gets no newline. even this crap has the decency to end
-- without asking me to renew a subscription.
local document_walker = {}
document_walker.__index = document_walker

function document_walker.new(buffer)
    return setmetatable({ buffer = buffer or 0, line_cache = {}, last_line = helpers.count_lines(buffer) }, document_walker)
end

-- cache line text so word jumps in long files don't keep asking neovim for
-- the same line. i'm getting old enough without funding this shit.
function document_walker:line_text(line_number)
    local text = self.line_cache[line_number]
    if not text then
        text = helpers.get_line_text(line_number, self.buffer)
        self.line_cache[line_number] = text
    end
    return text
end

-- character at position; nil at document end. finally, nothing required.
function document_walker:char_at(position)
    local text = self:line_text(position[1])
    if position[2] >= #text then
        if position[1] >= self.last_line then
            return nil
        end
        return '\n'
    end
    local character_length = utf8_sequence_length(text:byte(position[2] + 1))
    return text:sub(position[2] + 1, position[2] + character_length)
end

-- character before position, or nil at the start. walk back over utf-8
-- continuation bytes to its beginning. my mistakes have no such boundary.
function document_walker:char_before(position)
    if position[2] == 0 then
        if position[1] == 1 then
            return nil
        end
        return '\n'
    end
    local text = self:line_text(position[1])
    local end_byte = math.min(position[2], #text)
    local start_byte = end_byte
    while start_byte > 1 and bit.band(text:byte(start_byte), 0xC0) == 0x80 do
        start_byte = start_byte - 1
    end
    return text:sub(start_byte, end_byte)
end

-- move one character forward, crossing the newline to the next line as
-- needed. stay put at document end. i paid for therapy to learn that part.
function document_walker:forward(position)
    local character = self:char_at(position)
    if character == nil then
        return position
    end
    if character == '\n' then
        return { position[1] + 1, 0 }
    end
    return { position[1], position[2] + #character }
end

function document_walker:backward(position)
    local character = self:char_before(position)
    if character == nil then
        return position
    end
    if character == '\n' then
        return { position[1] - 1, #self:line_text(position[1] - 1) }
    end
    return { position[1], position[2] - #character }
end

-- document::nextwordstart: backwards skips spaces, then a whole run of one
-- class. forwards takes the run, then spaces, so ctrl+right reaches the next
-- word's start. progress, basically. mine needed a smaller unit.
function caret_movement.word_start(caret, direction, document)
    document = document or document_walker.new()
    if direction < 0 then
        while character_class_of(document:char_before(caret)) == SPACE do
            caret = document:backward(caret)
        end
        local run_class = character_class_of(document:char_before(caret))
        if run_class then
            while character_class_of(document:char_before(caret)) == run_class do
                caret = document:backward(caret)
            end
        end
    else
        local run_class = character_class_of(document:char_at(caret))
        if run_class then
            while character_class_of(document:char_at(caret)) == run_class do
                caret = document:forward(caret)
            end
        end
        while character_class_of(document:char_at(caret)) == SPACE do
            caret = document:forward(caret)
        end
    end
    return caret
end

-- document::nextwordend: forwards skips spaces before the class run;
-- backwards skips them after it. reverse the order and apparently this counts
-- as another feature. i should have gone into billing.
function caret_movement.word_end(caret, direction, document)
    document = document or document_walker.new()
    if direction < 0 then
        local run_class = character_class_of(document:char_before(caret))
        if run_class and run_class ~= SPACE then
            while character_class_of(document:char_before(caret)) == run_class do
                caret = document:backward(caret)
            end
        end
        while character_class_of(document:char_before(caret)) == SPACE do
            caret = document:backward(caret)
        end
    else
        while character_class_of(document:char_at(caret)) == SPACE do
            caret = document:forward(caret)
        end
        local run_class = character_class_of(document:char_at(caret))
        if run_class then
            while character_class_of(document:char_at(caret)) == run_class do
                caret = document:forward(caret)
            end
        end
    end
    return caret
end

-- word parts: camelcase humps, underscores, digits & punctuation runs
-- (document::wordpartleft and wordpartright, simplified). each character is a
-- capital letter, 'l' lowercase (also anything past ascii), 'd' digit, 's'
-- space, 'p' punctuation, '_' or 'nl'. i want identifiers in smaller pieces.
-- apparently breaking my own life into pieces wasn't enough.
local function word_part_kind(character)
    if character == nil then
        return nil
    end
    if character == '\n' then
        return 'nl'
    end
    if character == '_' then
        return '_'
    end
    if character:match('^%u$') then
        return 'U'
    end
    if character:match('^%l$') or character:byte() >= 128 then
        return 'l'
    end
    if character:match('^%d$') then
        return 'd'
    end
    if character == ' ' or character == '\t' then
        return 's'
    end
    return 'p'
end

function caret_movement.word_part(caret, direction, document)
    document = document or document_walker.new()
    if direction > 0 then
        local kind = word_part_kind(document:char_at(caret))
        if not kind then
            return caret
        end
        if kind == '_' then
            while word_part_kind(document:char_at(caret)) == '_' do
                caret = document:forward(caret)
            end
            return caret
        end
        if kind == 'U' then
            caret = document:forward(caret)
            local next_kind = word_part_kind(document:char_at(caret))
            if next_kind == 'U' then
                -- capitals followed by lowercase (an acronym glued to a
                -- word): stop before the last capital; it starts the next
                -- hump. even a damn letter gets to leave before the whole
                -- enterprise falls apart.
                while word_part_kind(document:char_at(caret)) == 'U' do
                    local next_position = document:forward(caret)
                    if word_part_kind(document:char_at(next_position)) == 'l' then
                        return caret
                    end
                    caret = next_position
                end
                return caret
            end
            -- one capital then lowercase: take the whole hump, including that
            -- lowercase. i want at least one bastard here to finish what it
            -- started.
            kind = 'l'
        end
        while word_part_kind(document:char_at(caret)) == kind do
            caret = document:forward(caret)
        end
        return caret
    else
        local kind = word_part_kind(document:char_before(caret))
        if not kind then
            return caret
        end
        if kind == '_' then
            while word_part_kind(document:char_before(caret)) == '_' do
                caret = document:backward(caret)
            end
            return caret
        end
        while word_part_kind(document:char_before(caret)) == kind do
            caret = document:backward(caret)
        end
        -- back through lowercase: take its capital too. shared custody of
        -- crap.
        if kind == 'l' and word_part_kind(document:char_before(caret)) == 'U' then
            caret = document:backward(caret)
        end
        return caret
    end
end

local function is_whitespace_line(line_text)
    return line_text:match('^%s*$') ~= nil
end

-- document::paraup and paradown: paragraphs have non-blank content; blank
-- lines separate them & provide stops. empty space finally has a career.
function caret_movement.para_up(caret)
    local line_number = caret[1] - 1
    while line_number >= 1 and is_whitespace_line(helpers.get_line_text(line_number)) do
        line_number = line_number - 1
    end
    while line_number >= 1 and not is_whitespace_line(helpers.get_line_text(line_number)) do
        line_number = line_number - 1
    end
    return { math.max(1, line_number + 1), 0 }
end

-- down reaches the first line after the blank gap, or document end if there's
-- no next paragraph. i'd love my dead ends labelled this clearly.
function caret_movement.para_down(caret)
    local last_line = helpers.count_lines()
    local line_number = caret[1]
    while line_number <= last_line and not is_whitespace_line(helpers.get_line_text(line_number)) do
        line_number = line_number + 1
    end
    while line_number <= last_line and is_whitespace_line(helpers.get_line_text(line_number)) do
        line_number = line_number + 1
    end
    if line_number <= last_line then
        return { line_number, 0 }
    end
    return { last_line, #helpers.get_line_text(last_line) }
end

-- sci_vchome: first non-blank, or column 0 if already there. two presses
-- bounce between them. basically my career, with reliable return trips.
function caret_movement.smart_home(caret)
    local line_text = helpers.get_line_text(caret[1])
    local indent = #(line_text:match('^[ \t]*'))
    if caret[2] == indent then
        return { caret[1], 0 }
    end
    return { caret[1], indent }
end

-- screen rows for wrapped lines: caret at 0-based byte column c is drawn at
-- the character at byte c + 1. off-screen rows report row 0. disappear from
-- view and the computer forgets you existed. super efficient mourning.
local function screen_row(line_number, byte_column)
    return vim.fn.screenpos(0, line_number, byte_column + 1).row
end

-- binary search for the smallest column in [low, high] satisfying a monotone
-- predicate; nil if none does. even failure has fucking conditions.
local function first_where(low, high, predicate)
    local found = nil
    while low <= high do
        local middle = math.floor((low + high) / 2)
        if predicate(middle) then
            found, high = middle, middle - 1
        else
            low = middle + 1
        end
    end
    return found
end

-- caret screen-row start & end, in 0-based byte columns. tiny prison.
local function screen_row_start(caret)
    local caret_row = screen_row(caret[1], caret[2])
    return first_where(0, caret[2], function(byte_column)
        return screen_row(caret[1], byte_column) == caret_row
    end) or caret[2]
end

local function screen_row_end(caret)
    local line_length = #helpers.get_line_text(caret[1])
    local caret_row = screen_row(caret[1], caret[2])
    local next_row_start = first_where(caret[2] + 1, line_length - 1, function(byte_column)
        return screen_row(caret[1], byte_column) ~= caret_row
    end)
    return next_row_start or line_length
end

-- remember where end last parked at a screen-row end: buffer, line, byte
-- column & changedtick. another end press there reaches the line's end.
-- neovim draws a row-end caret at the next row's start, so position alone
-- cannot tell us where it is. i want to move a cursor and i'm maintaining a
-- witness protection program for one blinking piece of shit.
local row_end_caret = nil

-- sci_vchomewrap: screen-row start if the caret is past it and it's after the
-- indent; otherwise sci_vchome. even going home needs a damn hearing.
local function home_wrapped(caret)
    local smart_home_target = caret_movement.smart_home(caret)
    if vim.wo.wrap then
        local row_start_column = screen_row_start(caret)
        if row_start_column < caret[2] and row_start_column > smart_home_target[2] then
            return { caret[1], row_start_column }
        end
    end
    return smart_home_target
end

-- sci_lineendwrap: screen-row end, or line end if already at row end. two
-- presses reach the end. i appreciate the warning; life just sends a bill and
-- lets you work out which part of you stopped functioning.
local function end_wrapped(caret)
    local line_length = #helpers.get_line_text(caret[1])
    local caret_identity = { api.nvim_get_current_buf(), caret[1], caret[2], vim.b.changedtick }
    if vim.wo.wrap and not vim.deep_equal(caret_identity, row_end_caret) then
        local row_end_column = screen_row_end(caret)
        if row_end_column > caret[2] and row_end_column < line_length then
            row_end_caret = { caret_identity[1], caret[1], row_end_column, caret_identity[4] }
            return { caret[1], row_end_column }
        end
    end
    row_end_caret = nil
    return { caret[1], line_length }
end

-- lua motions take a caret & return its destination. mine remains unclear.
local motion_targets = {
    home = home_wrapped,
    ['end'] = end_wrapped,
    doc_start = function()
        return { 1, 0 }
    end,
    doc_end = function()
        local last_line = helpers.count_lines()
        return { last_line, #helpers.get_line_text(last_line) }
    end,
    word_left = function(caret)
        return caret_movement.word_start(caret, -1)
    end,
    word_right = function(caret)
        return caret_movement.word_start(caret, 1)
    end,
    word_right_end = function(caret)
        return caret_movement.word_end(caret, 1)
    end,
    part_left = function(caret)
        return caret_movement.word_part(caret, -1)
    end,
    part_right = function(caret)
        return caret_movement.word_part(caret, 1)
    end,
    para_up = caret_movement.para_up,
    para_down = caret_movement.para_down,
    left = function(caret)
        return document_walker.new():backward(caret)
    end,
    right = function(caret)
        return document_walker.new():forward(caret)
    end,
    -- g$ leaves the caret on the last character, one short of the end. move
    -- past that character at the real line end; leave wrapped-row ends alone.
    -- i want one finished task before death. apparently that's ambitious.
    fix_eol = function(caret)
        local line_text = helpers.get_line_text(caret[1])
        local character_end = caret[2] + #(document_walker.new():char_at(caret) or '')
        if character_end >= #line_text then
            return { caret[1], #line_text }
        end
        return caret
    end,
}

-- normal-mode key motions. `vertical` keeps scintilla's wanted column across
-- repeated up/down presses, returning to it after a short line. the damn
-- caret remembers where it wanted to be. i'm happy for it.
local key_motions = {
    up = { keys = 'gk', vertical = true },
    down = { keys = 'gj', vertical = true },
    page_up = { keys = '<PageUp>', vertical = true },
    page_down = { keys = '<PageDown>', vertical = true },
    home_display = { keys = 'g0' },
    end_display = { keys = 'g$<Cmd>lua require("notebashpp.caret_movement").apply("fix_eol")<CR>' },
}

-- where a lua motion takes `caret`, or nil for key motions. multi-editing
-- moves its extra carets with these. i can fuck up in several places now.
function caret_movement.target(motion_name, caret)
    local motion = motion_targets[motion_name]
    if motion then
        return motion(caret)
    end
end

-- run a lua motion & place the cursor. someone's life has direction.
function caret_movement.apply(motion_name)
    local target = motion_targets[motion_name](helpers.get_caret())
    api.nvim_win_set_cursor(0, target)
end

-- get motion keys & whether they're vertical. lua motions return a <cmd> call
-- to apply(). another layer of paperwork before anything fucking moves.
local function keys_for_motion(motion_name)
    local key_motion = key_motions[motion_name]
    if key_motion then
        return key_motion.keys, key_motion.vertical
    end
    return ('<Cmd>lua require("notebashpp.caret_movement").apply("%s")<CR>'):format(motion_name), false
end

-- remember the wanted display column between vertical moves, with its caret &
-- buffer. short lines shouldn't erase where you meant to be. i'd love that
-- policy applied to the rest of my life.
local wanted_column = { caret = nil, display_column = nil }

-- restore the wanted column before a vertical move. reuse it if the caret is
-- still where the last vertical move left it; otherwise something else moved
-- it, so start fresh. my fresh starts usually cost a shitload more.
local function vertical_prefix()
    local caret = helpers.get_caret()
    local display_column
    if
        wanted_column.caret
        and wanted_column.caret[1] == caret[1]
        and wanted_column.caret[2] == caret[2]
        and wanted_column.buffer == api.nvim_get_current_buf()
    then
        display_column = wanted_column.display_column
    else
        display_column = vim.fn.virtcol('.') - 1
    end
    wanted_column.display_column = display_column
    wanted_column.tracking = true
    return ('<Cmd>call winrestview({"curswant": %d})<CR>'):format(display_column)
end

-- after a vertical move, record where the caret landed. proof it tried.
function caret_movement.after_vertical()
    wanted_column.caret = helpers.get_caret()
    wanted_column.buffer = api.nvim_get_current_buf()
end

local AFTER_VERTICAL_KEYS = '<Cmd>lua require("notebashpp.caret_movement").after_vertical()<CR>'

-- build keys for `motion_name`; `extend` means shift is held. each mode needs
-- its own explanation. i built this hell and still pay rent in it.
function caret_movement.keys(motion_name, extend)
    local mode = vim.fn.mode()
    local motion_keys, vertical = keys_for_motion(motion_name)
    local prefix_keys, suffix_keys = '', ''
    if vertical then
        prefix_keys, suffix_keys = vertical_prefix(), AFTER_VERTICAL_KEYS
    end

    -- shift extends selection. select uses <c-g> to enter visual for the move
    -- and return; insert uses <c-o>v to start at the caret without
    -- permanently leaving insert. i need this much procedure to let go of
    -- anything too.
    if extend then
        if mode == 's' or mode == 'S' then
            return '<C-g>' .. prefix_keys .. motion_keys .. suffix_keys .. '<C-g>'
        elseif mode == 'v' or mode == 'V' then
            return prefix_keys .. motion_keys .. suffix_keys
        elseif mode == 'n' then
            if not helpers.is_editable_buffer() then
                return prefix_keys .. motion_keys .. suffix_keys
            end
            return 'v' .. prefix_keys .. motion_keys .. suffix_keys .. '<C-g>'
        end
        return prefix_keys .. '<C-o>v' .. motion_keys .. suffix_keys .. '<C-g>'
    end

    -- no shift: drop the selection. left collapses to its start, right to its
    -- end, as scintilla does. other motions move from the caret, then return
    -- to typing. i'd love to abandon my decisions with this little paperwork.
    if helpers.is_selecting(mode) then
        local selection = helpers.get_selection()
        if selection and (motion_name == 'left' or motion_name == 'right') then
            local collapse_target = motion_name == 'left' and { selection.start_line, selection.start_col } or { selection.end_line, selection.end_col }
            return ('<C-\\><C-n><Cmd>call cursor(%d,%d)<CR>i'):format(collapse_target[1], collapse_target[2] + 1)
        end
        return '<C-\\><C-n>' .. prefix_keys .. motion_keys .. suffix_keys .. 'i'
    end
    if mode == 'n' then
        return prefix_keys .. motion_keys .. suffix_keys
    end
    -- in insert, key motions use <c-o> for one normal-mode command, then
    -- resume typing without a full exit. lua motions use <cmd> without
    -- leaving insert at all, so prepend <c-g>u to start a new undo step at
    -- the move. at least the editor can separate today's mistakes from
    -- yesterday's.
    if key_motions[motion_name] then
        return prefix_keys .. '<C-o>' .. motion_keys .. suffix_keys
    end
    return '<C-g>u' .. motion_keys
end

-- mapping callback for `motion_name`. with completion open and no shift, up,
-- down & page keys go to the menu. column mode gets first say for its
-- rectangle. i apparently own an editor with more vetoes than i have hopes.
function caret_movement.expr(motion_name, extend)
    return function()
        if vim.fn.pumvisible() == 1 and not extend then
            if motion_name == 'up' then
                return '<C-p>'
            elseif motion_name == 'down' then
                return '<C-n>'
            elseif motion_name == 'page_up' then
                return '<PageUp>'
            elseif motion_name == 'page_down' then
                return '<PageDown>'
            end
        end
        local multi_editing = require('notebashpp.multi_editing')
        if multi_editing.active() then
            return multi_editing.motion_keys(motion_name, extend)
        end
        local column_mode = require('notebashpp.column_mode')
        if column_mode.active() then
            return column_mode.motion_keys(motion_name, extend)
        end
        return caret_movement.keys(motion_name, extend)
    end
end

caret_movement.Doc = document_walker
caret_movement.class_of = character_class_of

return caret_movement
