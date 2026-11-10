-- editing commands: clipboard, line operations, case, comments, indent.
-- behaviour follows notepad++ 8.5.3 and scintilla, quirk by quirk. i want
-- another editor's habits reproduced exactly. basically i have turned the
-- remaining years of my life into a fucking photocopier.

local editing_commands = {}
local api = vim.api
local helpers = require('notebashpp.helpers')
local clipboard = require('notebashpp.clipboard')

-- column mode is looked up on every call, rather than once at load time.
-- every command checks whether it is on first. i trust absolutely nothing in
-- this editor, which is fair considering who wrote this crap.
local function column_mode()
    return require('notebashpp.column_mode')
end

-- multi-editing: with several carets, clipboard commands act at each. my
-- mistakes now scale better than my income.
local function multi_editing()
    return require('notebashpp.multi_editing')
end

-- reselect `range` after a change so commands can keep their selection. i
-- want the text to have some continuity. my life is beyond that patch.
local function reselect(range)
    helpers.select_range({ range.start_line, range.start_col }, { range.end_line, range.end_col })
end

---------------------------------------------------------------- clipboard

function editing_commands.copy()
    if multi_editing().active() then
        return multi_editing().copy()
    end
    if column_mode().active() then
        return column_mode().copy()
    end
    local selection = helpers.get_selection()
    if not selection then
        return
    end
    local lines = helpers.get_text_in_range(selection)
    -- a linewise selection ending at column 0 of the next line includes the
    -- line break: the last piece is an empty string representing it. even
    -- nothing needs packaging before this bastard will copy it.
    if selection.linewise and selection.end_col == 0 then
        lines[#lines] = ''
    end
    clipboard.set(lines, 'v')
end

function editing_commands.cut()
    if multi_editing().active() then
        return multi_editing().cut()
    end
    if column_mode().active() then
        return column_mode().cut()
    end
    local selection = helpers.get_selection()
    if not selection then
        return
    end
    editing_commands.copy()
    helpers.replace_text_in_range(selection, { '' })
    helpers.move_caret_to({ selection.start_line, selection.start_col })
end

function editing_commands.paste()
    if multi_editing().active() then
        return multi_editing().paste()
    end
    if column_mode().active() then
        return column_mode().paste()
    end
    local lines, clipboard_kind = clipboard.get()
    local selection = helpers.get_selection()
    local insert_position
    if selection then
        helpers.replace_text_in_range(selection, { '' })
        insert_position = { selection.start_line, selection.start_col }
    else
        insert_position = helpers.get_caret()
    end
    if clipboard_kind == 'line' then
        -- paste a whole line from ctrl+l / ctrl+shift+x above the caret line.
        -- it gets to start above where it left off. i paid for consulting
        -- advice that achieved considerably less.
        api.nvim_buf_set_text(0, insert_position[1] - 1, 0, insert_position[1] - 1, 0, lines)
        helpers.move_caret_to({ insert_position[1] + #lines - 1, insert_position[2] })
    elseif clipboard_kind == 'b' then
        column_mode().paste_block(lines, insert_position)
        helpers.move_caret_to(insert_position)
    else
        api.nvim_buf_set_text(0, insert_position[1] - 1, insert_position[2], insert_position[1] - 1, insert_position[2], lines)
        helpers.move_caret_to(helpers.position_after_inserted_text(insert_position[1], insert_position[2], lines))
    end
end

-- del removes the selection. undo can bring it back, which is basically why i
-- spend my life here instead of making decisions outside.
function editing_commands.delete_selection()
    if multi_editing().active() then
        return multi_editing().delete(1)
    end
    if column_mode().active() then
        return column_mode().delete(1)
    end
    local selection = helpers.get_selection()
    if selection then
        helpers.replace_text_in_range(selection, { '' })
        helpers.move_caret_to({ selection.start_line, selection.start_col })
    end
end

-- ctrl+a: select from the first byte through the end of the last line. all my
-- work, ready to delete. finally a realistic project plan.
function editing_commands.select_all()
    column_mode().clear()
    local last_line = helpers.count_lines()
    helpers.select_range({ 1, 0 }, { last_line, #helpers.get_line_text(last_line) })
end

------------------------------------------------------------ begin/end select

-- pending first press of begin/end select: buffer, caret position and whether
-- this is the column flavour. nil when no first press is pending. i too keep
-- a record of things that never fucking went anywhere.
local pending_begin_select = nil

-- first press remembers the caret; second press (same key, same buffer)
-- selects from that position to the current one. another buffer or the other
-- command flavour starts over. even this shit has boundaries. i should
-- potentially look into having some.
function editing_commands.begin_end_select(columnar)
    local caret_position = helpers.get_caret()
    if not pending_begin_select or pending_begin_select.buffer ~= api.nvim_get_current_buf() or pending_begin_select.columnar ~= columnar then
        pending_begin_select = { buffer = api.nvim_get_current_buf(), anchor_position = caret_position, columnar = columnar }
        helpers.collapse_selection()
        helpers.notify('Begin select: move the caret, then press the same key again')
        return
    end
    local anchor_position = pending_begin_select.anchor_position
    pending_begin_select = nil
    if columnar then
        column_mode().select(anchor_position, caret_position)
    else
        helpers.select_range(anchor_position, caret_position)
    end
end

-------------------------------------------------------------- convert case

-- per-word converter for the current proper case run. a module-level upvalue
-- because vim's substitute() calls into lua through a string, which cannot
-- carry closures. i built a public doorway for this crap and somehow still
-- think of myself as someone who simplifies things.
local current_word_converter

-- apply current_word_converter to words: runs of letters (any script), digits
-- and apostrophes. "don't" stays one word. i want at least my written
-- objections to remain intact while the years disappear.
local function convert_each_word(text)
    return vim.fn.substitute(text, [[\v(\k|')+]], '\\=v:lua.require("notebashpp.editing_commands")._convert_one_word(submatch(0))', 'g')
end

-- callback for the substitute() expression above. public because v:lua cannot
-- see locals. please don't call it yourself; i made enough mess.
function editing_commands._convert_one_word(word)
    return current_word_converter(word)
end

local function to_upper_case(text)
    return vim.fn.toupper(text)
end
local function to_lower_case(text)
    return vim.fn.tolower(text)
end
-- capitalise the first character. lower_the_rest lowers the rest for proper
-- case; blend leaves it alone. a tiny promotion, same shit job.
local function capitalise_first_character(word, lower_the_rest)
    local first_character = vim.fn.strcharpart(word, 0, 1)
    local rest_of_word = vim.fn.strcharpart(word, 1)
    return to_upper_case(first_character) .. (lower_the_rest and to_lower_case(rest_of_word) or rest_of_word)
end

-- converters keyed by the kind passed by menus and keys. other files depend
-- on these keys, so the ugly names stay. basically a mortgage on a decision i
-- can no longer afford to dislike.
local converters = {
    upper = to_upper_case,
    lower = to_lower_case,
    proper = function(text)
        current_word_converter = function(word)
            return capitalise_first_character(word, true)
        end
        return (convert_each_word(text))
    end,
    proper_blend = function(text)
        current_word_converter = function(word)
            return capitalise_first_character(word, false)
        end
        return (convert_each_word(text))
    end,
    -- uppercase the first letter at text start or after . ? or !; with blend
    -- off, lowercase every other letter. any byte at 128 or above counts as a
    -- letter. i want correctness, apparently within a bullshit budget.
    sentence = function(text, blend)
        local output_characters, at_sentence_start = {}, true
        local character_count = vim.fn.strchars(text)
        for character_index = 0, character_count - 1 do
            local character = vim.fn.strcharpart(text, character_index, 1)
            if character:match('[%a]') or character:byte() >= 128 then
                if at_sentence_start then
                    character = to_upper_case(character)
                    at_sentence_start = false
                elseif not blend then
                    character = to_lower_case(character)
                end
            elseif character:match('[%.%?!]') then
                at_sentence_start = true
            end
            output_characters[#output_characters + 1] = character
        end
        return table.concat(output_characters)
    end,
    -- swap each character's case. caseless characters uppercase to themselves
    -- and therefore get lowercased, still unchanged. all that fucking effort
    -- to end up where you started. i recognise the business model.
    invert = function(text)
        local output_characters = {}
        local character_count = vim.fn.strchars(text)
        for character_index = 0, character_count - 1 do
            local character = vim.fn.strcharpart(text, character_index, 1)
            local upper_character = to_upper_case(character)
            output_characters[#output_characters + 1] = (character == upper_character) and to_lower_case(character) or upper_character
        end
        return table.concat(output_characters)
    end,
    -- a coin toss for each character's case. notepad++ ships this on purpose.
    -- i copied it on purpose. who exactly am i planning to blame???
    random = function(text)
        local output_characters = {}
        local character_count = vim.fn.strchars(text)
        for character_index = 0, character_count - 1 do
            local character = vim.fn.strcharpart(text, character_index, 1)
            output_characters[#output_characters + 1] = math.random() < 0.5 and to_lower_case(character) or to_upper_case(character)
        end
        return table.concat(output_characters)
    end,
}
converters.sentence_blend = function(text)
    return converters.sentence(text, true)
end

-- notepad++ 8.5.3 converts only the selection; no selection, no change.
-- absolutely no initiative. finally software qualified to manage me.
function editing_commands.convert_case(kind)
    if column_mode().active() then
        return column_mode().map_text(converters[kind])
    end
    local selection = helpers.get_selection()
    if not selection then
        return
    end
    local original_text = table.concat(helpers.get_text_in_range(selection), '\n')
    local converted_text = converters[kind](original_text)
    if converted_text == original_text then
        return
    end
    local converted_lines = vim.split(converted_text, '\n', { plain = true })
    helpers.replace_text_in_range(selection, converted_lines)
    local converted_end = helpers.position_after_inserted_text(selection.start_line, selection.start_col, converted_lines)
    reselect({ start_line = selection.start_line, start_col = selection.start_col, end_line = converted_end[1], end_col = converted_end[2] })
end

------------------------------------------------------------- undo, redo

-- find where the change between two buffer states ends in `lines_after`, as
-- {line, col}. trim shared lines at the top and bottom, then shared trailing
-- bytes from what remains. the position is just after the difference. i want
-- a precise account of what changed, apparently because staring at the damage
-- without coordinates wasn't enough.
local function change_end(lines_before, lines_after)
    local shared_lines_at_top = 0
    while
        shared_lines_at_top < #lines_before
        and shared_lines_at_top < #lines_after
        and lines_before[shared_lines_at_top + 1] == lines_after[shared_lines_at_top + 1]
    do
        shared_lines_at_top = shared_lines_at_top + 1
    end
    local shared_lines_at_bottom = 0
    while
        shared_lines_at_bottom < #lines_before - shared_lines_at_top
        and shared_lines_at_bottom < #lines_after - shared_lines_at_top
        and lines_before[#lines_before - shared_lines_at_bottom] == lines_after[#lines_after - shared_lines_at_bottom]
    do
        shared_lines_at_bottom = shared_lines_at_bottom + 1
    end
    -- only whole lines were removed: caret to the replacement line's start,
    -- or the last line if none moved in. vacancy filled. no mourning budget.
    if shared_lines_at_top == #lines_after - shared_lines_at_bottom then
        return { math.min(shared_lines_at_top + 1, #lines_after), 0 }
    end
    local changed_text_before = table.concat(lines_before, '\n', shared_lines_at_top + 1, #lines_before - shared_lines_at_bottom)
    local changed_text_after = table.concat(lines_after, '\n', shared_lines_at_top + 1, #lines_after - shared_lines_at_bottom)
    local shared_bytes_at_end = 0
    while
        shared_bytes_at_end < #changed_text_before
        and shared_bytes_at_end < #changed_text_after
        and changed_text_before:byte(#changed_text_before - shared_bytes_at_end) == changed_text_after:byte(#changed_text_after - shared_bytes_at_end)
    do
        shared_bytes_at_end = shared_bytes_at_end + 1
    end
    -- the shared head gets counted and never used. harmless inherited work i
    -- haven't removed. basically i gave dead code better security than me.
    local shared_bytes_at_start = 0
    while
        shared_bytes_at_start < #changed_text_before - shared_bytes_at_end
        and shared_bytes_at_start < #changed_text_after - shared_bytes_at_end
        and changed_text_before:byte(shared_bytes_at_start + 1) == changed_text_after:byte(shared_bytes_at_start + 1)
    do
        shared_bytes_at_start = shared_bytes_at_start + 1
    end
    local text_up_to_change_end = changed_text_after:sub(1, #changed_text_after - shared_bytes_at_end)
    local newline_count = select(2, text_up_to_change_end:gsub('\n', ''))
    return { shared_lines_at_top + 1 + newline_count, #(text_up_to_change_end:match('[^\n]*$')) }
end

-- undo or redo one step. as in scintilla, put the caret after restored text,
-- or where removed text was. if the undo sequence number stays the same,
-- nothing was undone and the caret stays put. i want this level of
-- accountability from the years i spent on this shit.
function editing_commands.undo(is_redo)
    local lines_before = api.nvim_buf_get_lines(0, 0, -1, false)
    local undo_sequence_before = vim.fn.undotree().seq_cur
    if not pcall(vim.api.nvim_command, is_redo and 'silent redo' or 'silent undo') or vim.fn.undotree().seq_cur == undo_sequence_before then
        return
    end
    helpers.move_caret_to(change_end(lines_before, api.nvim_buf_get_lines(0, 0, -1, false)))
end

---------------------------------------------------------- line operations

-- duplicate the selected lines, or caret line, below themselves. keep the
-- caret or selection on the original. i want twice the output with no
-- progress whatsoever. consulting finally prepared me for something.
function editing_commands.duplicate()
    local selection = helpers.get_selection()
    if selection and not require('notebashpp.user_settings').get('duplicate_whole_lines') then
        -- sci_selectionduplicate: copy selected text right after itself. same
        -- shit, immediately available again.
        local selected_text = helpers.get_text_in_range(selection)
        api.nvim_buf_set_text(0, selection.end_line - 1, selection.end_col, selection.end_line - 1, selection.end_col, selected_text)
        reselect(selection)
        return
    end
    local first_line, last_line, line_selection = helpers.selected_line_range()
    api.nvim_buf_set_lines(0, last_line, last_line, false, helpers.get_lines_text(first_line, last_line))
    if line_selection then
        reselect(line_selection)
    end
end

-- sci_linecut: selected lines (or caret line) to the clipboard, tagged as
-- whole lines so paste inserts above a line. an empty last item adds the
-- trailing line break. even an exit requires this much paperwork.
function editing_commands.line_cut()
    local first_line, last_line = helpers.selected_line_range()
    local cut_lines = helpers.get_lines_text(first_line, last_line)
    table.insert(cut_lines, '')
    clipboard.set(cut_lines, 'line')
    local buffer_last_line = helpers.count_lines()
    if last_line < buffer_last_line then
        api.nvim_buf_set_lines(0, first_line - 1, last_line, false, {})
    elseif first_line > 1 then
        -- cut reaches file end: remove the preceding line break too,
        -- otherwise a blank line survives. i want my mistakes gone, including
        -- the outline.
        local previous_line_text = helpers.get_line_text(first_line - 1)
        api.nvim_buf_set_text(0, first_line - 2, #previous_line_text, last_line - 1, #helpers.get_line_text(last_line), {})
        first_line = first_line - 1
    else
        api.nvim_buf_set_lines(0, 0, -1, false, { '' })
    end
    helpers.move_caret_to({ math.min(first_line, helpers.count_lines()), 0 })
end

-- delete selected lines, or the caret line. leave the clipboard alone; keep
-- the caret's column on the line moving up. someone inherits the mess.
function editing_commands.line_delete()
    local first_line, last_line = helpers.selected_line_range()
    if not require('notebashpp.user_settings').get('line_delete_acts_on_selected_lines') then
        -- sci_linedelete: caret line only. collateral damage has a budget.
        first_line = helpers.get_caret()[1]
        last_line = first_line
    end
    local caret_column = helpers.get_caret()[2]
    local buffer_last_line = helpers.count_lines()
    if first_line == 1 and last_line == buffer_last_line then
        api.nvim_buf_set_lines(0, 0, -1, false, { '' })
    elseif last_line < buffer_last_line then
        api.nvim_buf_set_lines(0, first_line - 1, last_line, false, {})
    else
        -- delete final lines with their preceding line break. no damn relics.
        local previous_line_text = helpers.get_line_text(first_line - 1)
        api.nvim_buf_set_text(0, first_line - 2, #previous_line_text, last_line - 1, #helpers.get_line_text(last_line), {})
        first_line = first_line - 1
    end
    helpers.move_caret_to({ first_line, math.min(caret_column, #helpers.get_line_text(first_line)) })
end

-- sci_linecopy: selected lines, or caret line, as whole lines with a trailing
-- line break. nothing moves. i too mistake remembering for work.
function editing_commands.line_copy()
    local first_line, last_line = helpers.selected_line_range()
    local copied_lines = helpers.get_lines_text(first_line, last_line)
    table.insert(copied_lines, '')
    clipboard.set(copied_lines, 'line')
end

-- sci_linetranspose: swap the caret line with the one above. keep the caret's
-- line number, clamping its column to the new line if shorter. on the first
-- line, do nothing. apparently rock bottom has an upstairs neighbour, except
-- when you actually need the bastard.
function editing_commands.line_transpose()
    local caret_position = helpers.get_caret()
    local caret_line = caret_position[1]
    if caret_line <= 1 then
        return
    end
    local line_above_text, caret_line_text = helpers.get_line_text(caret_line - 1), helpers.get_line_text(caret_line)
    api.nvim_buf_set_lines(0, caret_line - 2, caret_line, false, { caret_line_text, line_above_text })
    helpers.move_caret_to({ caret_line, math.min(caret_position[2], #line_above_text) })
end

-- sci_moveselectedlinesup / down preserves the selection. direction -1 means
-- up, 1 means down; the neighbour crosses to the block's other side. i moved
-- a whole block and still basically displaced someone else's shit.
function editing_commands.move_lines(direction)
    local first_line, last_line, selection = helpers.selected_line_range()
    local buffer_last_line = helpers.count_lines()
    if (direction < 0 and first_line == 1) or (direction > 0 and last_line == buffer_last_line) then
        return
    end
    local moved_block = helpers.get_lines_text(first_line, last_line)
    if direction < 0 then
        local line_above_text = helpers.get_line_text(first_line - 1)
        table.insert(moved_block, line_above_text)
        api.nvim_buf_set_lines(0, first_line - 2, last_line, false, moved_block)
    else
        local line_below_text = helpers.get_line_text(last_line + 1)
        table.insert(moved_block, 1, line_below_text)
        api.nvim_buf_set_lines(0, first_line - 1, last_line + 1, false, moved_block)
    end
    if selection then
        reselect({
            start_line = selection.start_line + direction,
            start_col = selection.start_col,
            end_line = selection.end_line + direction,
            end_col = selection.end_col,
        })
    else
        local caret_position = helpers.get_caret()
        api.nvim_win_set_cursor(0, { caret_position[1] + direction, caret_position[2] })
    end
end

-- ctrl+alt+enter / ctrl+alt+shift+enter: empty line above or below the caret
-- line, caret at its start. i want a fresh page. apparently the previous
-- blank one wasn't adequately documenting my failure.
function editing_commands.blank_line(below)
    local caret_line = helpers.get_caret()[1]
    if below then
        api.nvim_buf_set_lines(0, caret_line, caret_line, false, { '' })
        helpers.move_caret_to({ caret_line + 1, 0 })
    else
        api.nvim_buf_set_lines(0, caret_line - 1, caret_line - 1, false, { '' })
        helpers.move_caret_to({ caret_line, 0 })
    end
end

-- sci_linessplit uses window width because edge mode is off in config.xml.
-- minimum width is 10 columns. i gave this editor a lower bound; my own
-- standards apparently remain open to further fucking negotiation.
function editing_commands.split_lines()
    local first_line, last_line = helpers.selected_line_range()
    local window_info = vim.fn.getwininfo(api.nvim_get_current_win())[1]
    local text_width = math.max(10, window_info.width - window_info.textoff)
    local split_lines = {}
    for _, remaining_text in ipairs(helpers.get_lines_text(first_line, last_line)) do
        while vim.fn.strdisplaywidth(remaining_text) > text_width do
            -- break after the last blank that fits within the width. without
            -- a reachable blank, leave the line too long. i can't fix
            -- everything, despite the unpaid hours suggesting that i should.
            local cut_after_byte = nil
            local character_count = vim.fn.strchars(remaining_text)
            local display_width_so_far = 0
            for character_index = 0, character_count - 1 do
                local character = vim.fn.strcharpart(remaining_text, character_index, 1)
                display_width_so_far = display_width_so_far + vim.fn.strdisplaywidth(character)
                if display_width_so_far > text_width then
                    break
                end
                if character == ' ' or character == '\t' then
                    cut_after_byte = vim.fn.byteidx(remaining_text, character_index + 1)
                end
            end
            if not cut_after_byte or cut_after_byte == 0 then
                break
            end
            table.insert(split_lines, remaining_text:sub(1, cut_after_byte))
            remaining_text = remaining_text:sub(cut_after_byte + 1)
        end
        table.insert(split_lines, remaining_text)
    end
    api.nvim_buf_set_lines(0, first_line - 1, last_line, false, split_lines)
    helpers.move_caret_to({ first_line + #split_lines - 1, #split_lines[#split_lines] })
end

-- sci_linesjoin: add one space between lines unless the result so far is
-- empty or ends in a blank. caret to the result's end. all that shit under
-- one roof, which was also my understanding of buying a home.
function editing_commands.join_lines()
    local first_line, last_line = helpers.selected_line_range()
    if first_line == last_line then
        return
    end
    local lines = helpers.get_lines_text(first_line, last_line)
    local joined_text = lines[1]
    for line_index = 2, #lines do
        if joined_text ~= '' and not joined_text:match('[ \t]$') then
            joined_text = joined_text .. ' '
        end
        joined_text = joined_text .. lines[line_index]
    end
    api.nvim_buf_set_lines(0, first_line - 1, last_line, false, { joined_text })
    helpers.move_caret_to({ first_line, #joined_text })
end

------------------------------------------------------------- deleting words

local caret_movement = require('notebashpp.caret_movement')

-- delete between positions in either order; caret where the gap closed. a
-- clean disappearance. my abandoned projects should be so lucky.
local function delete_range(from_position, to_position)
    if helpers.position_is_before(to_position, from_position) then
        from_position, to_position = to_position, from_position
    end
    api.nvim_buf_set_text(0, from_position[1] - 1, from_position[2], to_position[1] - 1, to_position[2], {})
    api.nvim_win_set_cursor(0, from_position)
end

-- ctrl+backspace deletes back to the previous word's start, using ctrl+left's
-- word rules. regret, with a repeatable specification.
function editing_commands.del_word_left()
    local caret_position = helpers.get_caret()
    delete_range(caret_movement.word_start(caret_position, -1), caret_position)
end

-- ctrl+delete deletes to the next word's start, as ctrl+right goes. future
-- disappointment removed early.
function editing_commands.del_word_right()
    local caret_position = helpers.get_caret()
    delete_range(caret_position, caret_movement.word_start(caret_position, 1))
end

-- delete from line start up to the caret. i want to erase the past,
-- apparently within the pathetic limits of this one line.
function editing_commands.del_line_left()
    local caret_position = helpers.get_caret()
    delete_range({ caret_position[1], 0 }, caret_position)
end

-- delete caret to line end; spare the line break. it knows too much.
function editing_commands.del_line_right()
    local caret_position = helpers.get_caret()
    delete_range(caret_position, { caret_position[1], #helpers.get_line_text(caret_position[1]) })
end

----------------------------------------------------------------- indenting

-- indent (direction 1) or outdent (direction -1) a line span one tab stop.
-- indent skips empty lines. outdent rebuilds leading whitespace one stop
-- narrower, using tabs plus spaces or only spaces according to expandtab.
-- indentation from 1 to tabstop wide becomes nothing. i want a smaller mess;
-- naturally i wrote a whole fucking procedure for manufacturing it.
local function indent_lines(first_line, last_line, direction)
    local tab_width = vim.bo.tabstop
    local lines = helpers.get_lines_text(first_line, last_line)
    for line_index, line_text in ipairs(lines) do
        if direction > 0 then
            if line_text ~= '' then
                lines[line_index] = (vim.bo.expandtab and string.rep(' ', tab_width) or '\t') .. line_text
            end
        else
            local indentation = line_text:match('^[ \t]*')
            local indentation_width = vim.fn.strdisplaywidth(indentation)
            local new_indentation_width = math.max(0, math.floor((indentation_width - 1) / tab_width) * tab_width)
            if indentation_width == 0 then
                new_indentation_width = 0
            end
            local new_indentation = vim.bo.expandtab and string.rep(' ', new_indentation_width)
                or (string.rep('\t', math.floor(new_indentation_width / tab_width)) .. string.rep(' ', new_indentation_width % tab_width))
            lines[line_index] = new_indentation .. line_text:sub(#indentation + 1)
        end
    end
    api.nvim_buf_set_lines(0, first_line - 1, last_line, false, lines)
end

-- tab indents a multiline selection; otherwise a tab character replaces the
-- selection or enters at the caret. after multiline indent, select whole
-- lines from column 0. an endpoint at column 0 stays there since that final
-- line wasn't included. even my exclusions need explaining, which is
-- basically how i ended up spending my evenings on this crap.
function editing_commands.tab()
    local selection = helpers.get_selection()
    if selection and selection.end_line > selection.start_line then
        local first_line, last_line = helpers.selected_line_range()
        indent_lines(first_line, last_line, 1)
        reselect({
            start_line = first_line,
            start_col = 0,
            end_line = last_line < selection.end_line and last_line + 1 or last_line,
            end_col = last_line < selection.end_line and 0 or #helpers.get_line_text(last_line),
        })
        return
    end
    local tab_text = vim.bo.expandtab and string.rep(' ', vim.bo.tabstop) or '\t'
    if selection then
        helpers.replace_text_in_range(selection, { tab_text })
        helpers.move_caret_to({ selection.start_line, selection.start_col + #tab_text })
        return
    end
    local caret_position = helpers.get_caret()
    api.nvim_buf_set_text(0, caret_position[1] - 1, caret_position[2], caret_position[1] - 1, caret_position[2], { tab_text })
    api.nvim_win_set_cursor(0, { caret_position[1], caret_position[2] + #tab_text })
end

-- shift+tab outdents selected lines, or the caret line if the caret is inside
-- indentation. otherwise move back to the previous tab stop without deleting
-- anything. a retreat with no loss, apart from the time i spent implementing
-- a more successful retreat than my own.
function editing_commands.backtab()
    local selection = helpers.get_selection()
    if selection then
        local first_line, last_line = helpers.selected_line_range()
        indent_lines(first_line, last_line, -1)
        if selection.end_line > selection.start_line then
            reselect({
                start_line = first_line,
                start_col = 0,
                end_line = last_line < selection.end_line and last_line + 1 or last_line,
                end_col = last_line < selection.end_line and 0 or #helpers.get_line_text(last_line),
            })
        else
            helpers.move_caret_to({ first_line, 0 })
        end
        return
    end
    local caret_position = helpers.get_caret()
    local line_text = helpers.get_line_text(caret_position[1])
    local indentation_length = #(line_text:match('^[ \t]*'))
    if caret_position[2] <= indentation_length then
        -- outdent the line; pull the caret left by the bytes lost. even
        -- shrinking this crap requires an escort.
        local length_before = #line_text
        indent_lines(caret_position[1], caret_position[1], -1)
        local length_after = #helpers.get_line_text(caret_position[1])
        api.nvim_win_set_cursor(0, { caret_position[1], math.max(0, caret_position[2] - (length_before - length_after)) })
        return
    end
    local caret_display_column = vim.fn.strdisplaywidth(line_text:sub(1, caret_position[2]))
    local target_display_column = math.floor((caret_display_column - 1) / vim.bo.tabstop) * vim.bo.tabstop
    local target_byte_column = vim.fn.virtcol2col(0, caret_position[1], target_display_column + 1)
    api.nvim_win_set_cursor(0, { caret_position[1], math.max(0, target_byte_column - 1) })
end

---------------------------------------------------------------- comments

-- overrides where neovim filetype settings differ from notepad++ languages:
-- line symbol, stream start, stream end. false means no comment symbols;
-- normal text stays alone in notepad++. i want this much respect for my
-- silence when someone asks how the project is going.
local COMMENT_SYMBOLS_BY_FILETYPE = {
    [''] = false,
    text = false,
    csv = false,
    srt = false,
    markdown = { nil, '<!--', '-->' },
    json = { '//', '/*', '*/' },
    iss = { ';' },
    registry = { ';' },
}

-- buffer symbols: line symbol and stream start/end. the table above wins.
-- next use 'commentstring': left part alone means line comment; left and
-- right mean stream comment. 'comments' fills remaining gaps. apparently even
-- knowing how to shut text up requires a fucking chain of command.
function editing_commands.comment_symbols()
    local fixed_symbols = COMMENT_SYMBOLS_BY_FILETYPE[vim.bo.filetype]
    if fixed_symbols ~= nil then
        if not fixed_symbols then
            return nil, nil, nil
        end
        return fixed_symbols[1], fixed_symbols[2], fixed_symbols[3]
    end
    local comment_string = vim.bo.commentstring or ''
    local line_comment_symbol, stream_start, stream_end
    local left_part, right_part = comment_string:match('^%s*(.-)%s*%%s%s*(.-)%s*$')
    if left_part and left_part ~= '' and (right_part == nil or right_part == '') then
        line_comment_symbol = left_part
    elseif left_part and left_part ~= '' then
        stream_start, stream_end = left_part, right_part
    end
    -- 'comments': plain items mean line comments; s/m/e triples mean blocks.
    -- o-flagged items apply only to the o command; f items only start the
    -- first line. ignore both here. i want fewer exceptions (good luck).
    for comment_item in (vim.bo.comments or ''):gmatch('[^,]+') do
        local item_flags, item_text = comment_item:match('^([^:]*):(.*)$')
        if item_flags and item_text ~= '' and not item_flags:match('O') then
            if not item_flags:match('[sme]') and not item_flags:match('f') then
                line_comment_symbol = line_comment_symbol or item_text
            elseif item_flags:match('s') and not stream_start then
                stream_start = item_text
            elseif item_flags:match('e') and stream_start and not stream_end then
                stream_end = item_text
            end
        end
    end
    -- discard a stream start with no end. i already have enough unfinished
    -- commitments without teaching the fucking parser to make them too.
    if stream_start and not stream_end then
        stream_start = nil
    end
    return line_comment_symbol, stream_start, stream_end
end

-- doblockcomment: insert "symbol + space" per line at the indentation. mode
-- is 'toggle', 'comment' or 'uncomment'. stream-only languages (css, html)
-- wrap each line as "start body end": the stream-as-line fallback named
-- use_stream_per_line below. skip empty lines. i refuse to spend even more of
-- my life making nothing harder to read.
function editing_commands.line_comment(mode)
    local line_comment_symbol, stream_start, stream_end = editing_commands.comment_symbols()
    local use_stream_per_line = false
    if not line_comment_symbol then
        if not stream_start then
            return
        end
        if mode == 'uncomment' then
            return editing_commands.stream_uncomment()
        end
        use_stream_per_line = true
    end
    local line_symbol = line_comment_symbol or ''
    local first_line, last_line, selection = helpers.selected_line_range()
    local lines = helpers.get_lines_text(first_line, last_line)
    for line_index, line_text in ipairs(lines) do
        local indentation, line_body = line_text:match('^([ \t]*)(.*)$')
        if line_body ~= '' then
            local already_handled = false
            if mode ~= 'comment' then
                if not use_stream_per_line then
                    -- match the symbol ignoring case; remove one following
                    -- space if present. even silence gets a removal fee.
                    if line_body:sub(1, #line_symbol):lower() == line_symbol:lower() then
                        local removed_length = #line_symbol
                        if line_body:sub(removed_length + 1, removed_length + 1) == ' ' then
                            removed_length = removed_length + 1
                        end
                        lines[line_index] = indentation .. line_body:sub(removed_length + 1)
                        already_handled = true
                    end
                else
                    local block_start, block_end = stream_start, stream_end
                    if line_body:sub(1, #block_start) == block_start and line_body:sub(-#block_end) == block_end then
                        local inner_text = line_body:sub(#block_start + 1, #line_body - #block_end)
                        inner_text = inner_text:gsub('^ ', ''):gsub(' $', '')
                        lines[line_index] = indentation .. inner_text
                        already_handled = true
                    end
                end
            end
            if not already_handled and mode ~= 'uncomment' then
                if use_stream_per_line then
                    lines[line_index] = indentation .. stream_start .. ' ' .. line_body .. ' ' .. stream_end
                else
                    lines[line_index] = indentation .. line_symbol .. ' ' .. line_body
                end
            end
        end
    end
    local caret_position = helpers.get_caret()
    local caret_line_text_before = helpers.get_line_text(caret_position[1])
    api.nvim_buf_set_lines(0, first_line - 1, last_line, false, lines)
    if selection then
        reselect({
            start_line = first_line,
            start_col = 0,
            end_line = selection.end_col == 0 and selection.end_line or last_line,
            end_col = selection.end_col == 0 and 0 or #helpers.get_line_text(last_line),
        })
    else
        -- without a selection, shift the caret by its line's growth or
        -- shrinkage to keep it on the same character. i want something here
        -- to hold on.
        local length_change = #helpers.get_line_text(caret_position[1]) - #caret_line_text_before
        api.nvim_win_set_cursor(0, { caret_position[1], math.max(0, caret_position[2] + length_change) })
    end
end

-- dostreamcomment: "start " before and " end" after the selection, or around
-- the caret line's text with no selection. line-comment-only languages fall
-- back to commenting lines. insert the end first so inserting the start
-- cannot shift its position. i finally learned to prepare an exit before
-- getting involved. only took a fucking editor.
function editing_commands.stream_comment()
    local line_comment_symbol, stream_start, stream_end = editing_commands.comment_symbols()
    if not stream_start then
        if line_comment_symbol then
            return editing_commands.line_comment('comment')
        end
        return
    end
    local selection = helpers.get_selection()
    local range
    if selection then
        range = selection
    else
        local caret_line = helpers.get_caret()[1]
        local line_text = helpers.get_line_text(caret_line)
        range = { start_line = caret_line, start_col = #(line_text:match('^[ \t]*')), end_line = caret_line, end_col = #line_text }
    end
    local opening_text, closing_text = stream_start .. ' ', ' ' .. stream_end
    api.nvim_buf_set_text(0, range.end_line - 1, range.end_col, range.end_line - 1, range.end_col, { closing_text })
    api.nvim_buf_set_text(0, range.start_line - 1, range.start_col, range.start_line - 1, range.start_col, { opening_text })
    local new_end_col = range.end_col + (range.start_line == range.end_line and #opening_text or 0)
    reselect({ start_line = range.start_line, start_col = range.start_col + #opening_text, end_line = range.end_line, end_col = new_end_col })
end

-- strip every "start body end" pair from selected lines (or caret line),
-- including one optional space inside each symbol. the body survives
-- unchanged. i want that deal for whatever's left of my enthusiasm.
function editing_commands.stream_uncomment()
    local _, stream_start, stream_end = editing_commands.comment_symbols()
    if not stream_start or not stream_end then
        return
    end
    local first_line, last_line = helpers.selected_line_range()
    local text = table.concat(helpers.get_lines_text(first_line, last_line), '\n')
    local comment_pattern = vim.pesc(stream_start) .. ' ?(.-) ?' .. vim.pesc(stream_end)
    local uncommented_text = text:gsub(comment_pattern, '%1')
    api.nvim_buf_set_lines(0, first_line - 1, last_line, false, vim.split(uncommented_text, '\n', { plain = true }))
end

------------------------------------------------------------- go to things

-- ctrl+g asks for a line number, clamps it to the file, goes there and
-- centres it. nonnumeric input cancels quietly. i want directions this honest
-- outside the editor. instead i get advice about believing in myself from
-- people who haven't seen this fucking repository.
function editing_commands.goto_line()
    local current_line = helpers.get_caret()[1]
    local last_line = helpers.count_lines()
    local answer = helpers.ask(('Go to line (you are here: %d, last line: %d): '):format(current_line, last_line))
    local target_line = tonumber(answer)
    if not target_line then
        return
    end
    target_line = math.max(1, math.min(last_line, target_line))
    helpers.move_caret_to({ target_line, 0 })
    vim.cmd('normal! zz')
end

local BRACE_CHARACTERS = '()[]{}'

-- brace beside the caret as {line, col}: prefer the brace just before the
-- caret over the one just after. nil if neither exists. even a missing
-- bracket gets a clearer answer than my long-term plans.
local function brace_at_caret()
    local caret_position = helpers.get_caret()
    local line_text = helpers.get_line_text(caret_position[1])
    if caret_position[2] > 0 and BRACE_CHARACTERS:find(line_text:sub(caret_position[2], caret_position[2]), 1, true) then
        return { caret_position[1], caret_position[2] - 1 }
    end
    if caret_position[2] < #line_text and BRACE_CHARACTERS:find(line_text:sub(caret_position[2] + 1, caret_position[2] + 1), 1, true) then
        return { caret_position[1], caret_position[2] }
    end
end

-- find the matching brace for `brace_position` using neovim's %. restore the
-- view afterwards to prevent screen jumps; nil if no partner exists. i want
-- bad news delivered without rearranging the fucking furniture.
local function matching_brace(brace_position)
    local saved_view = vim.fn.winsaveview()
    api.nvim_win_set_cursor(0, brace_position)
    local jumped = pcall(vim.api.nvim_command, 'keepjumps normal! %')
    local partner_position = helpers.get_caret()
    vim.fn.winrestview(saved_view)
    if not jumped or (partner_position[1] == brace_position[1] and partner_position[2] == brace_position[2]) then
        return nil
    end
    return partner_position
end

-- ctrl+b: caret before matching brace. someone found a partner.
function editing_commands.goto_brace()
    local brace_position = brace_at_caret()
    if not brace_position then
        return
    end
    local partner_position = matching_brace(brace_position)
    if partner_position then
        helpers.move_caret_to(partner_position)
    end
end

-- ctrl+alt+b selects through the matching brace, both braces included. i want
-- the whole relationship, including the closing argument.
function editing_commands.select_braces()
    local brace_position = brace_at_caret()
    if not brace_position then
        return
    end
    local partner_position = matching_brace(brace_position)
    if not partner_position then
        return
    end
    if helpers.position_is_before(partner_position, brace_position) then
        brace_position, partner_position = partner_position, brace_position
    end
    helpers.select_range(brace_position, { partner_position[1], partner_position[2] + 1 })
end

---------------------------------------------------------------- scrolling

-- ctrl+up / ctrl+down scroll one line, caret stays. \25 is ctrl+y and \5 is
-- ctrl+e, encoded as bytes. i have made looking up and down into something
-- requiring documentation. what the hell happened to me???
function editing_commands.scroll(direction)
    local scroll_key = direction < 0 and '\25' or '\5'
    vim.cmd('normal! ' .. scroll_key)
end

------------------------------------------------------- blank and eol ops

-- apply `transform_line` to each selected line; use the whole file if nothing
-- is selected or `whole_file` is set. same function for every line. i want
-- equal treatment, even when the treatment is this crap.
local function each_line(transform_line, whole_file)
    local first_line, last_line
    if whole_file then
        first_line, last_line = 1, helpers.count_lines()
    else
        first_line, last_line = helpers.selected_line_range()
        if not helpers.get_selection() then
            first_line, last_line = 1, helpers.count_lines()
        end
    end
    local lines = helpers.get_lines_text(first_line, last_line)
    local transformed_lines = {}
    for line_index, line_text in ipairs(lines) do
        transformed_lines[line_index] = transform_line(line_text)
    end
    api.nvim_buf_set_lines(0, first_line - 1, last_line, false, transformed_lines)
end

-- trim trailing spaces and tabs. keep the caret where it was, clamped to the
-- new line end if its old position got removed. i want a safe landing for
-- something whose entire support just turned out to be shit.
function editing_commands.trim_trailing()
    local caret_position = helpers.get_caret()
    each_line(function(line_text)
        return (line_text:gsub('[ \t]+$', ''))
    end)
    local caret_line = math.min(caret_position[1], helpers.count_lines())
    api.nvim_win_set_cursor(0, { caret_line, math.min(caret_position[2], #helpers.get_line_text(caret_line)) })
end

function editing_commands.trim_leading()
    each_line(function(line_text)
        return (line_text:gsub('^[ \t]+', ''))
    end)
end

function editing_commands.trim_both()
    each_line(function(line_text)
        return (line_text:gsub('^[ \t]+', ''):gsub('[ \t]+$', ''))
    end)
end

-- eol to space: join selected lines (or the whole file) into one line using
-- single spaces, including blank lines. emptiness still pays rent.
function editing_commands.eol_to_space()
    local first_line, last_line = helpers.selected_line_range()
    if not helpers.get_selection() then
        first_line, last_line = 1, helpers.count_lines()
    end
    local lines = helpers.get_lines_text(first_line, last_line)
    api.nvim_buf_set_lines(0, first_line - 1, last_line, false, { table.concat(lines, ' ') })
end

-- tab to space: expand each tab to the next tab stop. the pattern walks utf-8
-- characters as one lead byte plus continuation bytes; wide characters count
-- by display width. i want space measured correctly, since wasting the rest
-- of my life apparently isn't precise enough.
function editing_commands.tab_to_space()
    each_line(function(line_text)
        local output_pieces, display_column = {}, 0
        for character in line_text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
            if character == '\t' then
                local space_count = vim.bo.tabstop - display_column % vim.bo.tabstop
                output_pieces[#output_pieces + 1] = string.rep(' ', space_count)
                display_column = display_column + space_count
            else
                output_pieces[#output_pieces + 1] = character
                display_column = display_column + vim.fn.strdisplaywidth(character)
            end
        end
        return table.concat(output_pieces)
    end)
end

-- space to tab, leading or all. leading rebuilds indentation as tabs plus
-- leftover spaces. all turns a space run reaching a tab stop into one tab,
-- except a lone space stays. i want to consolidate the waste, apparently
-- because simply stopping work was too fucking obvious.
function editing_commands.space_to_tab(leading_only)
    local tab_width = vim.bo.tabstop
    each_line(function(line_text)
        if leading_only then
            local indentation, rest_of_line = line_text:match('^([ \t]*)(.*)$')
            local indentation_width = vim.fn.strdisplaywidth(indentation)
            return string.rep('\t', math.floor(indentation_width / tab_width)) .. string.rep(' ', indentation_width % tab_width) .. rest_of_line
        end
        local output_pieces, display_column, pending_spaces = {}, 0, 0
        for character in line_text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
            if character == ' ' then
                pending_spaces = pending_spaces + 1
                display_column = display_column + 1
                if display_column % tab_width == 0 then
                    output_pieces[#output_pieces + 1] = pending_spaces > 1 and '\t' or ' '
                    pending_spaces = 0
                end
            else
                output_pieces[#output_pieces + 1] = string.rep(' ', pending_spaces)
                pending_spaces = 0
                if character == '\t' then
                    display_column = display_column + tab_width - display_column % tab_width
                else
                    display_column = display_column + vim.fn.strdisplaywidth(character)
                end
                output_pieces[#output_pieces + 1] = character
            end
        end
        output_pieces[#output_pieces + 1] = string.rep(' ', pending_spaces)
        return table.concat(output_pieces)
    end)
end

-- eol conversion: 'dos', 'unix' or 'mac'. neovim stores lines without endings
-- and chooses them at save time. one option does the job. i want all the
-- other crap i've worried about to be this embarrassingly cheap.
function editing_commands.set_eol(file_format)
    vim.bo.fileformat = file_format
end

------------------------------------------------------------ line sorting

-- pass selected lines (all lines with no selection) to `transform_lines`;
-- replace them with its returned list. i trust it, which is my first error.
local function line_op(transform_lines)
    local first_line, last_line = helpers.selected_line_range()
    if not helpers.get_selection() then
        first_line, last_line = 1, helpers.count_lines()
    end
    local lines = transform_lines(helpers.get_lines_text(first_line, last_line))
    api.nvim_buf_set_lines(0, first_line - 1, last_line, false, lines)
end

-- leading number for numeric sorting. decimal_separator ',' removes dots and
-- treats comma as point; '.' removes commas. nil (integer sort) leaves the
-- text as is. no number means 0. i want my failures quantified, apparently
-- because feeling them was insufficiently fucking organised.
local function leading_number(line_text, decimal_separator)
    line_text = vim.trim(line_text)
    if decimal_separator == ',' then
        line_text = line_text:gsub('%.', ''):gsub(',', '.')
    elseif decimal_separator == '.' then
        line_text = line_text:gsub(',', '')
    end
    return tonumber(line_text:match('^[-+]?%d+%.?%d*')) or 0
end

-- sort kinds: 'lex', 'lexi' (ignore case), 'int', 'dec_comma'; anything else
-- means decimal with a dot. stable sort: equal keys retain their original
-- order. arriving early finally counts for something, which should comfort me
-- while i watch another evening disappear into this.
function editing_commands.sort(kind, descending)
    line_op(function(lines)
        local sort_key_of
        if kind == 'lex' then
            sort_key_of = function(line_text)
                return line_text
            end
        elseif kind == 'lexi' then
            sort_key_of = function(line_text)
                return vim.fn.tolower(line_text)
            end
        elseif kind == 'int' then
            sort_key_of = function(line_text)
                return leading_number(line_text)
            end
        elseif kind == 'dec_comma' then
            sort_key_of = function(line_text)
                return leading_number(line_text, ',')
            end
        else
            sort_key_of = function(line_text)
                return leading_number(line_text, '.')
            end
        end
        local sort_entries = {}
        for line_index, line_text in ipairs(lines) do
            sort_entries[line_index] = { sort_key = sort_key_of(line_text), original_index = line_index, line_text = line_text }
        end
        table.sort(sort_entries, function(first_entry, second_entry)
            if first_entry.sort_key == second_entry.sort_key then
                return first_entry.original_index < second_entry.original_index
            end
            if descending then
                return first_entry.sort_key > second_entry.sort_key
            end
            return first_entry.sort_key < second_entry.sort_key
        end)
        local sorted_lines = {}
        for entry_index, sort_entry in ipairs(sort_entries) do
            sorted_lines[entry_index] = sort_entry.line_text
        end
        return sorted_lines
    end)
end

-- reverse line order, last line first. i want to see how this shit ends
-- before investing any more of my life in the beginning.
function editing_commands.reverse_lines()
    line_op(function(lines)
        local reversed_lines = {}
        for line_index = #lines, 1, -1 do
            reversed_lines[#reversed_lines + 1] = lines[line_index]
        end
        return reversed_lines
    end)
end

-- fisher-yates shuffle: every order equally likely. i want my disasters
-- fairly distributed, since apparently avoiding them is off the table.
function editing_commands.randomize_lines()
    line_op(function(lines)
        for line_index = #lines, 2, -1 do
            local swap_index = math.random(line_index)
            lines[line_index], lines[swap_index] = lines[swap_index], lines[line_index]
        end
        return lines
    end)
end

-- remove duplicate lines, keeping the first occurrence. consecutive mode
-- removes only a line identical to its immediate predecessor. basically i can
-- repeat my mistakes if i put enough unrelated shit between them.
function editing_commands.remove_duplicates(consecutive)
    line_op(function(lines)
        local kept_lines, already_seen = {}, {}
        for _, line_text in ipairs(lines) do
            if consecutive then
                if line_text ~= kept_lines[#kept_lines] then
                    kept_lines[#kept_lines + 1] = line_text
                end
            elseif not already_seen[line_text] then
                already_seen[line_text] = true
                kept_lines[#kept_lines + 1] = line_text
            end
        end
        return kept_lines
    end)
end

-- remove empty lines; blank_too also removes whitespace-only lines. keep one
-- empty line if nothing survives, since buffers cannot have zero lines. even
-- absolute failure has a minimum hosting requirement.
function editing_commands.remove_empty(blank_too)
    line_op(function(lines)
        local kept_lines = {}
        for _, line_text in ipairs(lines) do
            if not (line_text == '' or (blank_too and line_text:match('^%s*$'))) then
                kept_lines[#kept_lines + 1] = line_text
            end
        end
        if #kept_lines == 0 then
            kept_lines = { '' }
        end
        return kept_lines
    end)
end

-------------------------------------------------------------- inserting

-- type `text` as by hand: replace selection or insert at caret; \n makes new
-- lines. leave caret after it. automate the evidence i did something.
function editing_commands.insert_text(text)
    local selection = helpers.get_selection()
    local lines = vim.split(text, '\n', { plain = true })
    local insert_position
    if selection then
        helpers.replace_text_in_range(selection, { '' })
        insert_position = { selection.start_line, selection.start_col }
    else
        insert_position = helpers.get_caret()
    end
    api.nvim_buf_set_text(0, insert_position[1] - 1, insert_position[2], insert_position[1] - 1, insert_position[2], lines)
    helpers.move_caret_to(helpers.position_after_inserted_text(insert_position[1], insert_position[2], lines))
end

-- edit > insert: config.xml insertdatetime customizedformat is "yyyy-mm-dd
-- hh:mm:ss" (24 hour clock). insert the current time. i want an exact record
-- of when i was still wasting my fucking life.
function editing_commands.insert_date(kind)
    local date_format = ({ short = '%H:%M %d/%m/%Y', long = '%H:%M %A, %d %B %Y', custom = '%Y-%m-%d %H:%M:%S' })[kind]
    editing_commands.insert_text(os.date(date_format))
end

------------------------------------------------------------- completion

-- return keys for expression mappings so insert mode stays insert mode. word
-- completion uses our own popup of the document's words. the file feeds me my
-- own thoughts, apparently because i haven't suffered enough.
function editing_commands.complete_words()
    return '<Cmd>lua require("notebashpp.word_completion").trigger(true)<CR>'
end

-- path completion uses neovim's built-in file name completion. it knows where
-- my shit lives.
function editing_commands.complete_path()
    return '<C-x><C-f>'
end

-- function completion uses the filetype's omnifunc if available; otherwise
-- word completion. i want expertise; i accept my own recycled bullshit.
function editing_commands.complete_function()
    if vim.bo.omnifunc ~= '' then
        return '<C-x><C-o>'
    end
    return editing_commands.complete_words()
end

-- function parameter hints need an attached language server. without one, do
-- nothing. i want that option next time i'm asked for unpaid advice.
function editing_commands.call_tip()
    if next(vim.lsp.get_clients({ bufnr = 0 })) then
        vim.lsp.buf.signature_help()
    end
end

-------------------------------------------------------------- text direction

-- ctrl+alt+r / ctrl+alt+l: notepad++ idm_edit_rtl / idm_edit_ltr. right to
-- left enables window 'rightleft' and empties its status column; left to
-- right restores the global status column. i reversed the whole damn view.
-- somehow the same disappointing document is still in it.
function editing_commands.rtl(right_to_left)
    vim.wo.rightleft = right_to_left
    vim.wo.statuscolumn = right_to_left and '' or vim.go.statuscolumn
end

return editing_commands
