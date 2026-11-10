-- multi-editing copies notepad++ 8.5.3 (scintilla multiple selections).
-- ctrl+click adds a caret; ctrl+click on one removes it. ctrl+drag and
-- ctrl+double-click add selections. typing, backspace, delete, enter, tab,
-- paste, ctrl+backspace and caret keys then work at every caret. esc or a
-- plain click returns to one caret. edit > multi-select all and multi-select
-- next (added in notepad++ 8.6) select further occurrences of the selected
-- text. basically i can now make the same damn mistake everywhere, with
-- absolutely no time left for reconsideration.
--
-- neovim has one cursor. the real cursor shows the main caret, added last.
-- all carets, including the main one, live in a list; extmarks draw their
-- selections. we stay in insert mode throughout, never select mode. edits run
-- bottom to top so each edit leaves the carets above untouched. extmarks
-- carry the carets below along when edits above change the text. i want some
-- order here (my life has declined the invitation).
--
-- check the session before every use. outside text changes or cursor moves
-- (undo, find, commands we do not handle) end it and leave one caret. an
-- unhandled command can never apply half an edit to the others. failure
-- should at least have the decency to finish the whole job.

local multi_editing = {}
local api = vim.api
local helpers = require('notebashpp.helpers')
local tracking_namespace = api.nvim_create_namespace('notebashpp_multi_editing_tracking')
local drawing_namespace = api.nvim_create_namespace('notebashpp_multi_editing')

-- one caret: anchor and head are { line, byte column }, like the cursor.
-- added increases per new caret; the highest is main. seniority is crap.
-- wanted_column keeps the display column across up and down presses.
---@class notebashpp.multi_caret
---@field anchor integer[]
---@field head integer[]
---@field added integer
---@field wanted_column? integer
---@field anchor_mark? integer
---@field head_mark? integer

-- live session, or nil with one caret; carets stay sorted by position.
-- expected_cursor and expected_tick hold our last cursor and changedtick.
-- anything else means outside interference. apparently i need witnesses. keep
-- it on the module table so a live code reload preserves it. even this
-- bastard gets another chance.
---@class notebashpp.multi_editing_session
---@field buffer integer
---@field window integer
---@field carets notebashpp.multi_caret[]
---@field next_added integer
---@field expected_cursor integer[]
---@field expected_tick integer
---@field last_action? string
---@field drag_caret? notebashpp.multi_caret

---@type notebashpp.multi_editing_session?
multi_editing.session = nil

-- session for multi-editing-only code: a clear error instead of indexing nil.
-- i want the failure to introduce itself.
---@return notebashpp.multi_editing_session
local function live_session()
    return assert(multi_editing.session, 'multi-editing is off')
end

-- typed characters await the next flush. insertcharpre cannot change the
-- buffer, so store the character here and queue a flush. more bureaucracy for
-- a letter that will probably make the sentence worse.
local pending_typed_text = {}

-- queue keys just after this mapping, ahead of keys already waiting. a
-- playing macro has its remaining keys queued; appending behind them runs too
-- late. i already do that with every important thing in my life.
local function feed_keys_next(keys)
    api.nvim_feedkeys(helpers.replace_termcodes(keys), 'ni', false)
end

---------------------------------------------------------------- positions

local function same_position(first_position, second_position)
    return first_position[1] == second_position[1] and first_position[2] == second_position[2]
end

local function copy_position(position)
    return { position[1], position[2] }
end

local function is_empty(caret)
    return same_position(caret.anchor, caret.head)
end

-- selection start and end in document order. even regret has boundaries.
local function range_of(caret)
    if helpers.position_is_before(caret.head, caret.anchor) then
        return caret.head, caret.anchor
    end
    return caret.anchor, caret.head
end

-- clamp into the buffer, onto a character's first byte. no half-assed bytes.
local function clamp_position(position, buffer)
    local line_number = math.max(1, math.min(position[1], helpers.count_lines(buffer)))
    local line_text = helpers.get_line_text(line_number, buffer)
    local column = math.max(0, math.min(position[2], #line_text))
    if column < #line_text then
        column = column + vim.str_utf_start(line_text, column + 1)
    end
    return { line_number, column }
end

local function is_word_character(character)
    return character ~= '' and (character:match('[%w_]') ~= nil or character:byte() >= 128)
end

-- word around `position`, using double-click's word characters; nil if it
-- touches no word. basically the computer has nothing to say either.
local function word_range_at(position)
    local line_text = helpers.get_line_text(position[1])
    local word_start, word_end = position[2], position[2]
    while word_start > 0 and is_word_character(line_text:sub(word_start, word_start)) do
        word_start = word_start - 1
    end
    while word_end < #line_text and is_word_character(line_text:sub(word_end + 1, word_end + 1)) do
        word_end = word_end + 1
    end
    if word_end == word_start then
        return nil
    end
    return { position[1], word_start }, { position[1], word_end }
end

---------------------------------------------------------------- session

-- last-added caret, shown by the real cursor. newest bastard wins.
local function main_caret()
    local main = nil
    for _, caret in ipairs(live_session().carets) do
        if not main or caret.added > main.added then
            main = caret
        end
    end
    return assert(main, 'a multi-editing session has carets')
end

-- draw every selection and all carets except main; the terminal draws that
-- real cursor. each caret highlights a character cell, or one space past line
-- end. i am now manufacturing empty space. finally, expertise.
local function render()
    local current = live_session()
    api.nvim_buf_clear_namespace(current.buffer, drawing_namespace, 0, -1)
    local main = main_caret()
    for _, caret in ipairs(current.carets) do
        if not is_empty(caret) then
            local range_start, range_end = range_of(caret)
            api.nvim_buf_set_extmark(current.buffer, drawing_namespace, range_start[1] - 1, range_start[2], {
                end_row = range_end[1] - 1,
                end_col = range_end[2],
                hl_group = 'NotebashMultiSelection',
                priority = 300,
            })
        end
        if caret ~= main then
            local line_text = helpers.get_line_text(caret.head[1], current.buffer)
            if caret.head[2] < #line_text then
                local character_length = #vim.fn.strcharpart(line_text:sub(caret.head[2] + 1), 0, 1)
                api.nvim_buf_set_extmark(current.buffer, drawing_namespace, caret.head[1] - 1, caret.head[2], {
                    end_col = caret.head[2] + character_length,
                    hl_group = 'NotebashMultiCaret',
                    priority = 310,
                })
            else
                api.nvim_buf_set_extmark(current.buffer, drawing_namespace, caret.head[1] - 1, caret.head[2], {
                    virt_text = { { ' ', 'NotebashMultiCaret' } },
                    virt_text_pos = 'overlay',
                    priority = 310,
                })
            end
        end
    end
end

-- forget session & drawing. pcall: the buffer may already be dead.
function multi_editing.clear()
    if multi_editing.session then
        pcall(api.nvim_buf_clear_namespace, multi_editing.session.buffer, drawing_namespace, 0, -1)
        pcall(api.nvim_buf_clear_namespace, multi_editing.session.buffer, tracking_namespace, 0, -1)
    end
    multi_editing.session = nil
    pending_typed_text = {}
end

-- true for a live session in this window, text & cursor as we left them. end
-- stale sessions here. in another window it waits; return with nothing
-- changed and it resumes. more patience than i deserve, frankly.
function multi_editing.active()
    if not multi_editing.session then
        return false
    end
    if not api.nvim_buf_is_valid(multi_editing.session.buffer) or not api.nvim_win_is_valid(multi_editing.session.window) then
        multi_editing.clear()
        return false
    end
    if api.nvim_get_current_buf() ~= multi_editing.session.buffer or api.nvim_get_current_win() ~= multi_editing.session.window then
        return false
    end
    if
        api.nvim_buf_get_changedtick(multi_editing.session.buffer) ~= multi_editing.session.expected_tick
        or not same_position(helpers.get_caret(), multi_editing.session.expected_cursor)
    then
        multi_editing.clear()
        return false
    end
    return true
end

-- caret count; one with multi-editing off. manageable misery.
function multi_editing.caret_count()
    return multi_editing.active() and #live_session().carets or 1
end

-- all carets as { anchor, head }, in document order. with multi-editing off,
-- just the real cursor. back to disappointing myself individually.
function multi_editing.carets()
    if not multi_editing.active() then
        local caret = helpers.get_caret()
        return { { anchor = caret, head = caret } }
    end
    local caret_list = {}
    for _, caret in ipairs(live_session().carets) do
        caret_list[#caret_list + 1] = { anchor = copy_position(caret.anchor), head = copy_position(caret.head) }
    end
    return caret_list
end

-- put the real cursor at `position` and remember it. from select or normal
-- mode, leave via keys and enter insert mode. escape requires paperwork.
local function place_cursor(position)
    local current = live_session()
    current.expected_cursor = copy_position(position)
    if helpers.is_selecting() or vim.fn.mode() == 'n' then
        feed_keys_next(('<C-\\><C-n><Cmd>call cursor(%d,%d)<CR>i'):format(position[1], position[2] + 1))
    else
        api.nvim_win_set_cursor(0, position)
    end
    current.expected_tick = api.nvim_buf_get_changedtick(current.buffer)
end

-- sort carets and merge overlaps: selections sharing text, same-position
-- carets, and carets inside or on a selection's edge. the merged caret keeps
-- the newer one's direction and age, preserving the main caret. i wish
-- merging my mistakes also made me younger. absolutely not.
local function sort_and_merge(carets)
    table.sort(carets, function(first_caret, second_caret)
        local first_start, first_end = range_of(first_caret)
        local second_start, second_end = range_of(second_caret)
        if not same_position(first_start, second_start) then
            return helpers.position_is_before(first_start, second_start)
        end
        return helpers.position_is_before(first_end, second_end)
    end)
    local merged = {}
    for _, caret in ipairs(carets) do
        local previous = merged[#merged]
        local caret_start, caret_end = range_of(caret)
        local overlaps = false
        local previous_start, previous_end
        if previous then
            previous_start, previous_end = range_of(previous)
            overlaps = helpers.position_is_before(caret_start, previous_end)
                or (same_position(caret_start, previous_end) and (is_empty(previous) or is_empty(caret)))
        end
        if overlaps then
            local union_start = copy_position(previous_start)
            local union_end = copy_position(helpers.position_is_before(previous_end, caret_end) and caret_end or previous_end)
            local keeper = caret.added > previous.added and caret or previous
            if helpers.position_is_before(keeper.head, keeper.anchor) then
                keeper.anchor, keeper.head = union_end, union_start
            else
                keeper.anchor, keeper.head = union_start, union_end
            end
            merged[#merged] = keeper
        else
            merged[#merged + 1] = caret
        end
    end
    return merged
end

-- after each change, merge. draw remaining carets & park the cursor on main;
-- if only one remains, end the session and leave a plain caret or selection.
-- even my little empire ends in administrative cleanup.
local function finish()
    local current = live_session()
    current.carets = sort_and_merge(current.carets)
    local main = main_caret()
    if #current.carets == 1 then
        multi_editing.clear()
        if is_empty(main) then
            helpers.move_caret_to(main.head)
        else
            feed_keys_next(helpers.keys_to_select_range(main.anchor, main.head))
        end
        return
    end
    render()
    place_cursor(main.head)
end

-- start from the stream selection, direction intact, or the cursor. i want at
-- least the selection to know where it was going.
local function caret_from_current_state()
    local selection = helpers.get_selection()
    local cursor = clamp_position(helpers.get_caret())
    if not selection then
        return { anchor = cursor, head = copy_position(cursor), added = 1 }
    end
    if selection.linewise then
        return { anchor = { selection.start_line, selection.start_col }, head = { selection.end_line, selection.end_col }, added = 1 }
    end
    local visual_start = vim.fn.getpos('v')
    return { anchor = clamp_position({ visual_start[2], visual_start[3] - 1 }), head = cursor, added = 1 }
end

-- start from the current caret or selection. end column mode first: one kind
-- of multiple carets at a time. ration the damn chaos.
local function start_session()
    require('notebashpp.column_mode').clear()
    multi_editing.session = {
        buffer = api.nvim_get_current_buf(),
        window = api.nvim_get_current_win(),
        carets = { caret_from_current_state() },
        next_added = 2,
        expected_cursor = helpers.get_caret(),
        expected_tick = api.nvim_buf_get_changedtick(0),
    }
    return multi_editing.session
end

local function add_caret(anchor, head)
    local current = live_session()
    local caret = { anchor = copy_position(anchor), head = copy_position(head), added = current.next_added }
    current.next_added = current.next_added + 1
    current.carets[#current.carets + 1] = caret
    return caret
end

local function remove_caret(caret_to_remove)
    local current = live_session()
    for index, caret in ipairs(current.carets) do
        if caret == caret_to_remove then
            table.remove(current.carets, index)
            return
        end
    end
end

---------------------------------------------------------------- editing

-- run compute_edit(caret, index) at every caret, bottom to top. nil means no
-- change; { start, finish, lines, caret } replaces start to finish with
-- lines, then places the caret at `caret`, or just after the new text if nil.
-- extmarks carry lower carets through edits above them. all edits form one
-- undo step; consecutive typing joins the previous step, like one caret. i
-- want my regrets refundable in bulk. life has been absolutely unhelpful
-- about implementing this.
local function edit_each_caret(action_name, compute_edit)
    local current = live_session()
    local buffer = current.buffer
    if action_name == 'typing' and current.last_action == 'typing' then
        pcall(api.nvim_command, 'undojoin')
    else
        helpers.start_new_undo_step()
    end
    current.last_action = action_name
    api.nvim_buf_clear_namespace(buffer, tracking_namespace, 0, -1)
    for _, caret in ipairs(current.carets) do
        caret.anchor_mark = api.nvim_buf_set_extmark(buffer, tracking_namespace, caret.anchor[1] - 1, caret.anchor[2], {})
        caret.head_mark = api.nvim_buf_set_extmark(buffer, tracking_namespace, caret.head[1] - 1, caret.head[2], {})
    end
    local function read_mark(mark_id)
        local mark_position = api.nvim_buf_get_extmark_by_id(buffer, tracking_namespace, mark_id, {})
        return { mark_position[1] + 1, mark_position[2] }
    end
    for index = #current.carets, 1, -1 do
        local caret = current.carets[index]
        caret.anchor, caret.head = read_mark(caret.anchor_mark), read_mark(caret.head_mark)
        local edit = compute_edit(caret, index)
        if edit then
            api.nvim_buf_set_text(buffer, edit.start[1] - 1, edit.start[2], edit.finish[1] - 1, edit.finish[2], edit.lines)
            local new_position = edit.caret or helpers.position_after_inserted_text(edit.start[1], edit.start[2], edit.lines)
            api.nvim_buf_set_extmark(buffer, tracking_namespace, new_position[1] - 1, new_position[2], { id = caret.anchor_mark })
            api.nvim_buf_set_extmark(buffer, tracking_namespace, new_position[1] - 1, new_position[2], { id = caret.head_mark })
        end
    end
    for _, caret in ipairs(current.carets) do
        caret.anchor, caret.head = read_mark(caret.anchor_mark), read_mark(caret.head_mark)
        caret.anchor_mark, caret.head_mark, caret.wanted_column = nil, nil, nil
    end
    api.nvim_buf_clear_namespace(buffer, tracking_namespace, 0, -1)
    finish()
end

-- replace selections or insert at every caret with `text`.
-- `text_for_caret(index)` supplies different text per caret instead.
-- personalized mistakes. apparently there is a market.
local function insert_at_each_caret(action_name, text, text_for_caret)
    edit_each_caret(action_name, function(caret, index)
        local range_start, range_end = range_of(caret)
        local caret_text = text_for_caret and text_for_caret(index) or text
        return { start = range_start, finish = range_end, lines = vim.split(caret_text, '\n', { plain = true }) }
    end)
end

-- type `text` at all carets, replacing selections. spread the damage.
function multi_editing.insert(text)
    if multi_editing.active() then
        insert_at_each_caret('typing', text)
    end
end

-- type insertcharpre's queued characters in one go. bulk regret.
function multi_editing.flush_typed_text()
    local text = table.concat(pending_typed_text)
    pending_typed_text = {}
    if text ~= '' and multi_editing.active() then
        insert_at_each_caret('typing', text)
    end
end

-- enter breaks the line at every caret. with autoindent, copy that line's
-- indentation, only the part before the caret, as notepad++ does. even the
-- blank lines inherit my baggage.
function multi_editing.newline()
    if not multi_editing.active() then
        return
    end
    edit_each_caret('newline', function(caret)
        local range_start, range_end = range_of(caret)
        local indentation = ''
        if vim.bo.autoindent then
            indentation = helpers.get_line_text(range_start[1]):sub(1, range_start[2]):match('^[ \t]*')
        end
        return { start = range_start, finish = range_end, lines = { '', indentation } }
    end)
end

-- tab at every caret; spaces with expandtab. billable emptiness.
function multi_editing.tab()
    if multi_editing.active() then
        insert_at_each_caret('tab', vim.bo.expandtab and string.rep(' ', vim.bo.tabstop) or '\t')
    end
end

-- direction -1: backspace; 1: delete. remove the selection, otherwise the
-- character before or after the caret, including line breaks at line start or
-- end. typing & deleting share one undo step, like one caret. basically
-- destruction comes with a receipt. keep it.
function multi_editing.delete(direction)
    if not multi_editing.active() then
        return
    end
    local document_walker = require('notebashpp.caret_movement').Doc
    edit_each_caret('typing', function(caret)
        local range_start, range_end = range_of(caret)
        if not is_empty(caret) then
            return { start = range_start, finish = range_end, lines = { '' } }
        end
        local walker = document_walker.new(0)
        local other_end = direction < 0 and walker:backward(caret.head) or walker:forward(caret.head)
        if same_position(other_end, caret.head) then
            return nil
        end
        if direction < 0 then
            return { start = other_end, finish = caret.head, lines = { '' } }
        end
        return { start = caret.head, finish = other_end, lines = { '' } }
    end)
end

-- ctrl+backspace, ctrl+delete, ctrl+shift+backspace, ctrl+shift+delete: at
-- every caret, delete the selection or up to the word or line edge. i want
-- limits on what disappears (a recent preference).
function multi_editing.delete_to(edge_name)
    if not multi_editing.active() then
        return
    end
    local caret_movement = require('notebashpp.caret_movement')
    edit_each_caret('delete_to', function(caret)
        local range_start, range_end = range_of(caret)
        if not is_empty(caret) then
            return { start = range_start, finish = range_end, lines = { '' } }
        end
        local head = caret.head
        local other_end
        if edge_name == 'del_word_left' then
            other_end = caret_movement.word_start(head, -1)
        elseif edge_name == 'del_word_right' then
            other_end = caret_movement.word_start(head, 1)
        elseif edge_name == 'del_line_left' then
            other_end = { head[1], 0 }
        else
            other_end = { head[1], #helpers.get_line_text(head[1]) }
        end
        if same_position(other_end, head) then
            return nil
        end
        if helpers.position_is_before(other_end, head) then
            return { start = other_end, finish = head, lines = { '' } }
        end
        return { start = head, finish = other_end, lines = { '' } }
    end)
end

-- selected texts in document order, joined with line breaks. unselected
-- carets add nothing. finally an honest contribution from this editor.
local function selected_texts()
    local current = live_session()
    local texts = {}
    for _, caret in ipairs(current.carets) do
        if not is_empty(caret) then
            local range_start, range_end = range_of(caret)
            local lines = api.nvim_buf_get_text(current.buffer, range_start[1] - 1, range_start[2], range_end[1] - 1, range_end[2], {})
            texts[#texts + 1] = table.concat(lines, '\n')
        end
    end
    return texts
end

-- ctrl+c copies every selection, one per line. no selection copies nothing,
-- like one caret in 8.5.3. even nothing needs a specification.
function multi_editing.copy()
    local texts = selected_texts()
    if #texts > 0 then
        require('notebashpp.clipboard').set(vim.split(table.concat(texts, '\n'), '\n', { plain = true }), 'v')
    end
end

function multi_editing.cut()
    if #selected_texts() == 0 then
        return
    end
    multi_editing.copy()
    edit_each_caret('cut', function(caret)
        if is_empty(caret) then
            return nil
        end
        local range_start, range_end = range_of(caret)
        return { start = range_start, finish = range_end, lines = { '' } }
    end)
end

-- ctrl+v: one clipboard line per caret gives each its own line, top to bottom
-- (scintilla's multipaste each). otherwise all get the whole text. a trailing
-- line break does not count as a line. i want that clear before we distribute
-- this crap to every available address.
function multi_editing.paste()
    local current = live_session()
    local lines = require('notebashpp.clipboard').get()
    local counted_lines = vim.list_slice(lines)
    if #counted_lines > 1 and counted_lines[#counted_lines] == '' then
        table.remove(counted_lines)
    end
    if #counted_lines == #current.carets then
        insert_at_each_caret('paste', '', function(index)
            return counted_lines[index]
        end)
    else
        insert_at_each_caret('paste', table.concat(lines, '\n'))
    end
end

---------------------------------------------------------------- moving

-- vertical moves keep each caret's display column, like one caret. something
-- should hold its position while i fall apart.
local function vertical_target(caret, line_delta)
    local column_mode = require('notebashpp.column_mode')
    local head = caret.head
    local wanted_column = caret.wanted_column or vim.fn.strdisplaywidth(helpers.get_line_text(head[1]):sub(1, head[2]))
    local target_line = math.max(1, math.min(helpers.count_lines(), head[1] + line_delta))
    local target_byte = column_mode.byte_at_display_column(helpers.get_line_text(target_line), wanted_column)
    return { target_line, target_byte }, wanted_column
end

-- `motion_name`'s destination for one caret. home and end ignore word wrap:
-- smart home & line end. the wrapping can go disappoint itself.
local function motion_target(motion_name, caret)
    local head = caret.head
    if motion_name == 'up' or motion_name == 'down' then
        return vertical_target(caret, motion_name == 'up' and -1 or 1)
    elseif motion_name == 'page_up' or motion_name == 'page_down' then
        local page_height = math.max(1, api.nvim_win_get_height(0) - 1)
        return vertical_target(caret, motion_name == 'page_up' and -page_height or page_height)
    elseif motion_name == 'home' then
        return require('notebashpp.caret_movement').smart_home(head)
    elseif motion_name == 'home_display' then
        return { head[1], 0 }
    elseif motion_name == 'end' or motion_name == 'end_display' then
        return { head[1], #helpers.get_line_text(head[1]) }
    end
    return require('notebashpp.caret_movement').target(motion_name, head) or head
end

-- move every caret. `extend` (shift held) moves only the head, growing each
-- selection. without shift, left/right first collapse selections to
-- start/end, as scintilla does. i wish shrinking my problems were this cheap.
-- apparently i bought the wrong keyboard.
function multi_editing.move(motion_name, extend)
    if not multi_editing.active() then
        return
    end
    local current = live_session()
    current.last_action = 'move'
    for _, caret in ipairs(current.carets) do
        local range_start, range_end = range_of(caret)
        if not extend and not is_empty(caret) and (motion_name == 'left' or motion_name == 'right') then
            local edge = motion_name == 'left' and range_start or range_end
            caret.anchor, caret.head, caret.wanted_column = copy_position(edge), copy_position(edge), nil
        else
            local target, wanted_column = motion_target(motion_name, caret)
            caret.head = clamp_position(target)
            caret.wanted_column = wanted_column
            if not extend then
                caret.anchor = copy_position(caret.head)
            end
        end
    end
    finish()
end

-- expression-mapping keys run move() in insert mode. no damn exit.
function multi_editing.motion_keys(motion_name, extend)
    return ('<Cmd>lua require("notebashpp.multi_editing").move("%s", %s)<CR>'):format(motion_name, extend and 'true' or 'false')
end

---------------------------------------------------------------- mouse

-- buffer position under the mouse in this window; nil if it missed text.
-- clicking another window goes there and ends multi-editing, like a plain
-- click. one small betrayal and the whole arrangement collapses.
local function mouse_buffer_position()
    local mouse_position = vim.fn.getmousepos()
    if mouse_position.winid == 0 or mouse_position.line == 0 then
        return nil
    end
    if mouse_position.winid ~= api.nvim_get_current_win() then
        multi_editing.clear()
        api.nvim_set_current_win(mouse_position.winid)
        helpers.move_caret_to({ mouse_position.line, math.max(0, mouse_position.column - 1) })
        return nil
    end
    if not helpers.is_editable_buffer() then
        return nil
    end
    return clamp_position({ mouse_position.line, math.max(0, mouse_position.column - 1) })
end

-- caret at `position`: an empty caret there, or a containing selection.
-- somewhere in this mess, someone has to take responsibility.
local function caret_at(position)
    for _, caret in ipairs(live_session().carets) do
        local range_start, range_end = range_of(caret)
        if is_empty(caret) and same_position(caret.head, position) then
            return caret
        end
        if not is_empty(caret) and not helpers.position_is_before(position, range_start) and not helpers.position_is_before(range_end, position) then
            return caret
        end
    end
    return nil
end

-- ctrl+click adds a mouse caret, or removes one there. cheap staffing.
function multi_editing.mouse_add()
    local position = mouse_buffer_position()
    if not position then
        return
    end
    if not multi_editing.active() then
        start_session()
    end
    local current = live_session()
    current.drag_caret = nil
    local existing_caret = caret_at(position)
    if existing_caret then
        -- keep the only caret. typing into the void is already my day job.
        if #current.carets == 1 then
            return finish()
        end
        remove_caret(existing_caret)
    else
        current.drag_caret = add_caret(position, position)
    end
    current.last_action = 'mouse'
    finish()
end

-- ctrl+drag extends the press-added caret's selection to the mouse. i made
-- this mess; naturally it follows me.
function multi_editing.mouse_drag()
    if not multi_editing.active() or not live_session().drag_caret then
        return
    end
    local position = mouse_buffer_position()
    if not position then
        return
    end
    local current = live_session()
    for _, caret in ipairs(current.carets) do
        if caret == current.drag_caret then
            caret.head = position
            return finish()
        end
    end
end

-- ctrl+double-click adds the mouse word as a selection. its first click
-- already added or removed a caret there; drop that caret and add the word.
-- correcting our own damage now counts as a feature.
function multi_editing.mouse_add_word()
    local position = mouse_buffer_position()
    if not position then
        return
    end
    local word_start, word_end = word_range_at(position)
    if not word_start or not word_end then
        return
    end
    if not multi_editing.active() then
        start_session()
    end
    local current = live_session()
    local existing_caret = caret_at(position)
    if existing_caret and is_empty(existing_caret) and #current.carets > 1 then
        remove_caret(existing_caret)
    end
    add_caret(word_start, word_end)
    current.drag_caret = nil
    finish()
end

---------------------------------------------------------- multi-select

-- all `needle` occurrences on one line as byte ranges. ignore case lowers
-- both strings (string.lower preserves byte offsets). whole word needs no
-- word character on either side. even words get personal boundaries; i
-- apparently waived mine when i started configuring neovim.
local function occurrences_in_line(line_text, needle, options)
    local haystack = options.match_case and line_text or line_text:lower()
    local wanted = options.match_case and needle or needle:lower()
    local found = {}
    local search_from = 1
    while true do
        local match_start, match_end = haystack:find(wanted, search_from, true)
        if not match_start then
            break
        end
        local whole_word = not is_word_character(line_text:sub(match_start - 1, match_start - 1))
            and not is_word_character(line_text:sub(match_end + 1, match_end + 1))
        if not options.whole_word or whole_word then
            found[#found + 1] = { match_start - 1, match_end }
        end
        search_from = match_start + 1
    end
    return found
end

-- find the main selection's text, or the caret's word. without a selection,
-- select the word first and stop, as scintilla does. return text, or nil if
-- finished or impossible. finally a function that admits when there is
-- absolutely no point continuing.
local function text_to_find()
    if multi_editing.active() then
        local main = main_caret()
        if is_empty(main) then
            local word_start, word_end = word_range_at(main.head)
            if word_start and word_end then
                main.anchor, main.head = word_start, word_end
                finish()
            end
            return nil
        end
        local range_start, range_end = range_of(main)
        if range_start[1] ~= range_end[1] then
            helpers.warn('Multi-select works on text within one line.')
            return nil
        end
        return helpers.get_line_text(range_start[1]):sub(range_start[2] + 1, range_end[2])
    end
    local selection = helpers.get_selection()
    if not selection then
        local _, word_range = helpers.word_at_caret()
        if word_range then
            feed_keys_next(helpers.keys_to_select_range({ word_range.start_line, word_range.start_col }, { word_range.end_line, word_range.end_col }))
        end
        return nil
    end
    if selection.start_line ~= selection.end_line or selection.linewise then
        helpers.warn('Multi-select works on text within one line.')
        return nil
    end
    if not helpers.is_editable_buffer() then
        return nil
    end
    local text = helpers.get_text_in_range(selection)[1]
    start_session()
    return text
end

-- selected ranges keyed by position; add each match once. enough crap.
local function selected_range_keys()
    local keys = {}
    for _, caret in ipairs(live_session().carets) do
        local range_start, range_end = range_of(caret)
        keys[table.concat({ range_start[1], range_start[2], range_end[1], range_end[2] }, ':')] = true
    end
    return keys
end

-- edit > multi-select all selects every occurrence. keep main in place so the
-- view stays still. the mistakes can multiply without a spectacle.
---@param options { match_case: boolean, whole_word: boolean }
function multi_editing.select_all_occurrences(options)
    local text = text_to_find()
    if not text or text == '' then
        return
    end
    local current = live_session()
    local already_selected = selected_range_keys()
    local main = main_caret()
    for line_index, line_text in ipairs(api.nvim_buf_get_lines(current.buffer, 0, -1, false)) do
        for _, match in ipairs(occurrences_in_line(line_text, text, options)) do
            if not already_selected[table.concat({ line_index, match[1], line_index, match[2] }, ':')] then
                add_caret({ line_index, match[1] }, { line_index, match[2] })
            end
        end
    end
    -- keep main by giving it the newest age again. aging is rigged.
    main.added = current.next_added
    current.next_added = current.next_added + 1
    current.last_action = 'select'
    finish()
end

-- edit > multi-select next adds the occurrence after the main selection,
-- wrapping at document end. it becomes main. `skip_current` first drops the
-- main selection (skip current and go to next). basically moving on without
-- learning a damn thing, now available from the menu.
---@param options { match_case: boolean, whole_word: boolean }
function multi_editing.select_next_occurrence(options, skip_current)
    local text = text_to_find()
    if not text or text == '' then
        return
    end
    local current = live_session()
    local main = main_caret()
    local main_start, main_end = range_of(main)
    local already_selected = selected_range_keys()
    local line_count = helpers.count_lines()
    -- walk from main's selection line, wrapping back. no escape, basically.
    for step = 0, line_count do
        local line_number = (main_start[1] - 1 + step) % line_count + 1
        local line_text = helpers.get_line_text(line_number)
        for _, match in ipairs(occurrences_in_line(line_text, text, options)) do
            local after_main = step > 0 or match[1] >= main_end[2]
            local before_main_on_return = step < line_count or match[2] <= main_start[2]
            if after_main and before_main_on_return and not already_selected[table.concat({ line_number, match[1], line_number, match[2] }, ':')] then
                if skip_current then
                    remove_caret(main)
                end
                add_caret({ line_number, match[1] }, { line_number, match[2] })
                current.last_action = 'select'
                return finish()
            end
        end
    end
    -- nothing left to add; show our starting selection. cherish the wreckage.
    finish()
end

-- edit > multi-select next > undo the latest added multi-select. a tiny
-- refund on regret.
function multi_editing.undo_latest_added()
    if not multi_editing.active() then
        return
    end
    remove_caret(main_caret())
    finish()
end

-- edit > column mode to carets: one caret or selection per rectangle line.
-- main goes on the rectangle's caret line. same crap, different geometry.
function multi_editing.from_column_mode()
    local column_mode = require('notebashpp.column_mode')
    if not column_mode.active() then
        return helpers.notify('Column mode to carets: make a column selection first (Alt+Shift+arrows or Alt+drag).')
    end
    local line_ranges, caret_line, caret_on_right = column_mode.line_ranges()
    column_mode.clear()
    multi_editing.clear()
    multi_editing.session = {
        buffer = api.nvim_get_current_buf(),
        window = api.nvim_get_current_win(),
        carets = {},
        next_added = 1,
        expected_cursor = helpers.get_caret(),
        expected_tick = api.nvim_buf_get_changedtick(0),
    }
    local main = nil
    for _, line_range in ipairs(line_ranges) do
        local left_position, right_position = { line_range[1], line_range[2] }, { line_range[1], line_range[3] }
        local caret = caret_on_right and add_caret(left_position, right_position) or add_caret(right_position, left_position)
        if line_range[1] == caret_line then
            main = caret
        end
    end
    if main then
        main.added = multi_editing.session.next_added
        multi_editing.session.next_added = multi_editing.session.next_added + 1
    end
    finish()
end

---------------------------------------------------------------- setup

function multi_editing.setup()
    local augroup = api.nvim_create_augroup('notebashpp_multi_editing', { clear = true })
    -- typed characters reach every caret. insertcharpre cannot change the
    -- buffer: empty v:char, save the character, queue a flush at the front of
    -- typeahead. it runs before the next key, including macro playback. all
    -- this to type a letter. what the hell have i done with my time?
    api.nvim_create_autocmd('InsertCharPre', {
        group = augroup,
        callback = function()
            if not multi_editing.active() then
                return
            end
            pending_typed_text[#pending_typed_text + 1] = vim.v.char
            vim.v.char = ''
            feed_keys_next('<Cmd>lua require("notebashpp.multi_editing").flush_typed_text()<CR>')
        end,
    })
    -- end stale sessions immediately, drawing included. bury the whole mess.
    api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'TextChanged', 'TextChangedI' }, {
        group = augroup,
        callback = function(event)
            if multi_editing.session and event.buf == multi_editing.session.buffer then
                multi_editing.active()
            end
        end,
    })
    -- saving may touch changedtick (the modified flag counts). a session live
    -- before writing stays live afterward. paying the bill should not kill
    -- the customer. apparently i have to explain this to software too.
    local live_before_write = false
    api.nvim_create_autocmd('BufWritePre', {
        group = augroup,
        callback = function(event)
            live_before_write = multi_editing.session ~= nil and event.buf == multi_editing.session.buffer and multi_editing.active()
        end,
    })
    api.nvim_create_autocmd('BufWritePost', {
        group = augroup,
        callback = function(event)
            if live_before_write and multi_editing.session and event.buf == multi_editing.session.buffer then
                for _, caret in ipairs(multi_editing.session.carets) do
                    caret.anchor, caret.head =
                        clamp_position(caret.anchor, multi_editing.session.buffer), clamp_position(caret.head, multi_editing.session.buffer)
                end
                multi_editing.session.expected_tick = api.nvim_buf_get_changedtick(multi_editing.session.buffer)
            end
            live_before_write = false
        end,
    })
end

return multi_editing
