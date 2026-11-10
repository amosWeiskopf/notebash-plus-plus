-- every key binding lives in this table. i want one place to blame myself.
-- sources, in order of who wins: a. user.lua, through
-- notebashpp.user_settings: its keys replace a command's defaults; its
-- commands go in the macro menu. you win here. enjoy it. the bank still owns
-- your ass. b. notepad++ 8.5.3's built-in table (parameters.cpp: winkeydefs
-- and scintkeydefs), plus the trim-and-save macro and the three run commands
-- from its shipped shortcuts.xml; c. compareplus 1.1.0's defaults. menus and
-- keys.md use this same table. one mistake reaches three places. basically i
-- have automated my own failure. excellent use of my remaining time.

local keybindings = {}
local api = vim.api
local helpers = require('notebashpp.helpers')

-- each getter loads its module when a key first needs it. no early loading
-- because something might be useful. i made that investment in myself once.
local function lazy_require(module_name)
    return function()
        return require('notebashpp.' .. module_name)
    end
end
local editing_commands, file_commands, document_tabs, find_and_replace, caret_movement =
    lazy_require('editing_commands'),
    lazy_require('file_commands'),
    lazy_require('document_tabs'),
    lazy_require('find_and_replace'),
    lazy_require('caret_movement')
local bookmark_commands, macros, folding, column_mode, compare_documents =
    lazy_require('bookmarks'), lazy_require('macros'), lazy_require('folding'), lazy_require('column_mode'), lazy_require('compare_documents')
local run_commands, appearance = lazy_require('run_commands'), lazy_require('appearance')

-- insert, select and visual: where a notepad++ user expects to just type.
-- all_modes adds normal for neovim's brief lapses before modeless_editing
-- brings it back. i built supervision for a damn text editor.
local editing_modes = { 'i', 's', 'x' }
local all_modes = { 'i', 's', 'x', 'n' }

keybindings.list = {}
keybindings.by_id = {}

-- the menu used by the next define_command call. sections below reassign it
-- as they go. even commands get somewhere to belong. i pay rent.
local current_section = 'File'

-- register a command. keys: key names in neovim notation; action: what runs;
-- options.modes: mapping modes; options.expr: expression mappings;
-- options.raw: skip the undo wrapper. store in the list and by_id for lookup
-- by order or name. i want my mistakes indexed before i die.
local function define_command(command_id, label, keys, action, options)
    options = options or {}
    local command = {
        id = command_id,
        label = label,
        keys = keys or {},
        fn = action,
        modes = options.modes or all_modes,
        expr = options.expr,
        raw = options.raw,
        section = current_section,
    }
    table.insert(keybindings.list, command)
    keybindings.by_id[command_id] = command
    return command
end

-- run a command by id, exactly as its key would. menus and the popup menu
-- also come here. several entrances to the same shit decision.
function keybindings.run(command_id)
    local command = keybindings.by_id[command_id]
    if not command then
        return
    end
    -- a shortcut closes any open menu first. i want one mess on screen at a
    -- time. apparently this is the extent of my control over life.
    if vim.bo.filetype == 'notebashpp_menu' then
        require('notebashpp.menu_bar').close_all()
    end
    -- any command's lua error becomes a notification & log entry through
    -- messages.lua. no stack trace waiting for enter. i already press enough
    -- buttons to confirm that my life is shit.
    local messages = require('notebashpp.messages')
    if command.expr then
        local succeeded, keys_to_feed = messages.call(command.label, command.fn)
        if succeeded and keys_to_feed and keys_to_feed ~= '' then
            api.nvim_feedkeys(helpers.replace_termcodes(keys_to_feed), 'n', false)
        end
        return
    end
    if command.raw then
        local _, result = messages.call(command.label, command.fn)
        return result
    end
    helpers.run_command_as_one_undo_step(command.label, command.fn)
end

------------------------------------------------------------- key names

-- map shifted us digit-row and bracket-key symbols back to their keys, so
-- <c-!> displays as ctrl+shift+1. even punctuation needs a damn alibi.
local unshifted_key_for_symbol = {
    ['!'] = '1',
    ['@'] = '2',
    ['#'] = '3',
    ['$'] = '4',
    ['%'] = '5',
    ['^'] = '6',
    ['&'] = '7',
    ['*'] = '8',
    ['('] = '9',
    [')'] = '0',
    ['{'] = '[',
    ['}'] = ']',
    ['?'] = '/',
    ['|'] = '\\',
}
-- neovim key names on the left, notepad++ menu names on the right. i maintain
-- both vocabularies. my life is apparently worth this little.
local key_display_names = {
    CR = 'Enter',
    kEnter = 'Numpad Enter',
    kPlus = 'Numpad +',
    kMinus = 'Numpad -',
    kDivide = 'Numpad /',
    kMultiply = 'Numpad *',
    PageUp = 'PgUp',
    PageDown = 'PgDn',
    BS = 'Backspace',
    Del = 'Del',
    Insert = 'Ins',
    Space = 'Space',
    Tab = 'Tab',
    Up = 'Up',
    Down = 'Down',
    Left = 'Left',
    Right = 'Right',
    Home = 'Home',
    End = 'End',
    Esc = 'Esc',
    lt = '<',
    Bslash = '\\',
    ScrollWheelUp = 'Wheel Up',
    ScrollWheelDown = 'Wheel Down',
}

-- format <c-s-f3> as notepad++'s ctrl+shift+f3 for menus and keys.md.
-- modifiers always print in ctrl, alt, shift order, whatever the input order.
-- i can put these in order. the rest of my affairs are absolutely fucked.
function keybindings.pretty(key)
    local inside_brackets = key:match('^<(.*)>$')
    if not inside_brackets then
        return key:upper()
    end
    local modifiers, base_key = {}, inside_brackets
    while true do
        local modifier, rest = base_key:match('^([CMSADcmsad])%-(.+)$')
        if not modifier then
            break
        end
        modifier = modifier:upper()
        modifiers[modifier == 'A' and 'M' or modifier] = true
        base_key = rest
    end
    -- user.lua can use <c-pageup> or <s-f10>; neovim ignores key-name case.
    -- we restore capitals for display. unpaid cosmetic work for a dying
    -- machine.
    for neovim_name in pairs(key_display_names) do
        if base_key:lower() == neovim_name:lower() then
            base_key = neovim_name
        end
    end
    base_key = base_key:gsub('^[fF](%d+)$', 'F%1')
    if unshifted_key_for_symbol[base_key] then
        base_key = unshifted_key_for_symbol[base_key]
        modifiers.S = true
    end
    -- <m-s> with a capital s means alt+shift+s: uppercase implies shift.
    -- apparently the key carries hidden obligations too. shit.
    if #base_key == 1 and base_key:match('%u') then
        modifiers.S = true
    end
    if base_key:match('^k%d$') then
        base_key = 'Numpad ' .. base_key:sub(2)
    elseif key_display_names[base_key] then
        base_key = key_display_names[base_key]
    elseif #base_key == 1 then
        base_key = base_key:upper()
    end
    return (modifiers.C and 'Ctrl+' or '') .. (modifiers.M and 'Alt+' or '') .. (modifiers.S and 'Shift+' or '') .. base_key
end

-- return the command's first key in menu spelling, or '' if it has none. most
-- commands have no key and wait in menus for a click. i gave them my career
-- plan (my mistake). still, somebody might need one someday.
function keybindings.shortcut(command_id)
    local command = keybindings.by_id[command_id]
    if not command or not command.keys[1] then
        return ''
    end
    return keybindings.pretty(command.keys[1])
end

----------------------------------------------------------------- file

-- file menu: opening, saving, closing. a document's whole life cycle. i want
-- mine to have a save somewhere before the bastard closes.
define_command('new', 'New', { '<C-n>' }, function()
    file_commands().new()
end)
define_command('open', 'Open...', { '<C-o>' }, function()
    file_commands().open()
end)
define_command('reload', 'Reload from Disk', { '<C-r>' }, function()
    file_commands().reload()
end)
define_command('save', 'Save', { '<C-s>' }, function()
    file_commands().save()
end)
define_command('save_as', 'Save As...', { '<C-M-s>' }, function()
    file_commands().save_as()
end)
define_command('save_copy', 'Save a Copy As...', {}, function()
    file_commands().save_copy_as()
end)
define_command('save_all', 'Save All', { '<C-S-s>' }, function()
    file_commands().save_all()
end)
define_command('close', 'Close', { '<C-w>' }, function()
    file_commands().close()
end)
define_command('close_all', 'Close All', { '<C-S-w>' }, function()
    file_commands().close_many('all')
end)
define_command('print', 'Print...', { '<C-p>' }, function()
    file_commands().print()
end)
define_command('exit', 'Exit', { '<M-F4>' }, function()
    file_commands().exit()
end, { raw = true })
define_command('restore_closed', 'Restore Recent Closed File', { '<C-S-t>' }, function()
    file_commands().restore_closed()
end)

----------------------------------------------------------------- edit

current_section = 'Edit'

-- undo and redo leave visual or select mode first via keys_when_selecting
-- (ctrl+\ ctrl+n, then the command). in insert, call action_when_typing.
-- basically two ways to regret something. i already had plenty.
local function in_visual_feed(keys_when_selecting, action_when_typing)
    return function()
        if helpers.is_selecting() then
            helpers.feed_keys(keys_when_selecting)
        else
            action_when_typing()
        end
    end
end

define_command(
    'undo',
    'Undo',
    { '<C-z>', '<M-BS>' },
    in_visual_feed('<C-\\><C-n><Cmd>lua require("notebashpp.editing_commands").undo(false)<CR>', function()
        editing_commands().undo(false)
    end)
)
define_command(
    'redo',
    'Redo',
    { '<C-y>', '<C-S-z>' },
    in_visual_feed('<C-\\><C-n><Cmd>lua require("notebashpp.editing_commands").undo(true)<CR>', function()
        editing_commands().undo(true)
    end)
)
define_command('cut', 'Cut', { '<C-x>', '<S-Del>' }, function()
    editing_commands().cut()
end, { modes = editing_modes })
define_command('copy', 'Copy', { '<C-c>', '<C-Insert>' }, function()
    editing_commands().copy()
end, { modes = editing_modes, raw = true })
define_command('paste', 'Paste', { '<C-v>', '<S-Insert>' }, function()
    editing_commands().paste()
end, { modes = editing_modes })
define_command('select_all', 'Select All', { '<C-a>' }, function()
    editing_commands().select_all()
end, { modes = editing_modes, raw = true })
define_command('begin_select', 'Begin/End Select', { '<C-S-b>' }, function()
    editing_commands().begin_end_select(false)
end, { modes = editing_modes, raw = true })
define_command('begin_select_col', 'Begin/End Select in Column Mode', { '<M-S-b>', '<M-B>' }, function()
    editing_commands().begin_end_select(true)
end, { modes = editing_modes, raw = true })
-- grow selection to enclosing syntax, or step back. notepad++ has neither;
-- ctrl+alt+up and ctrl+alt+down are free in 8.5.3. finally, reversible
-- decisions. i'd love those outside this damn editor.
define_command('expand_selection', 'Expand Selection', { '<C-M-Up>' }, function()
    require('notebashpp.syntax_selection').expand()
end, { modes = editing_modes, raw = true })
define_command('shrink_selection', 'Shrink Selection', { '<C-M-Down>' }, function()
    require('notebashpp.syntax_selection').shrink()
end, { modes = editing_modes, raw = true })
-- edit > multi-select all and multi-select next come from notepad++ 8.6, each
-- with four search flavours and no assigned keys. ctrl+e and ctrl+shift+e are
-- free in 8.5.3. the notepad++ user manual suggests ctrl+e for multi-select
-- next (match case only). i read the manual. apparently this is what i'm
-- doing with the time i have left.
local function multi_editing()
    return require('notebashpp.multi_editing')
end
keybindings.MULTI_SELECT_FLAVOURS = {
    {
        id = 'ignore_case_whole_word',
        label = 'Ignore Case & Whole Word',
        menu_label = '&Ignore Case && Whole Word',
        options = { match_case = false, whole_word = false },
    },
    { id = 'match_case', label = 'Match Case Only', menu_label = 'Match &Case Only', options = { match_case = true, whole_word = false } },
    { id = 'whole_word', label = 'Match Whole Word Only', menu_label = 'Match &Whole Word Only', options = { match_case = false, whole_word = true } },
    {
        id = 'match_case_whole_word',
        label = 'Match Case & Whole Word',
        menu_label = 'Match Case && Whole W&ord',
        options = { match_case = true, whole_word = true },
    },
}
for _, flavour in ipairs(keybindings.MULTI_SELECT_FLAVOURS) do
    define_command('multi_select_all_' .. flavour.id, 'Multi-select All: ' .. flavour.label, flavour.id == 'match_case' and { '<C-S-e>' } or {}, function()
        multi_editing().select_all_occurrences(flavour.options)
    end, { modes = editing_modes, raw = true })
    define_command('multi_select_next_' .. flavour.id, 'Multi-select Next: ' .. flavour.label, flavour.id == 'match_case' and { '<C-e>' } or {}, function()
        multi_editing().select_next_occurrence(flavour.options, false)
    end, { modes = editing_modes, raw = true })
end
define_command('multi_select_undo', 'Undo the Latest Added Multi-Select', {}, function()
    multi_editing().undo_latest_added()
end, { modes = editing_modes, raw = true })
define_command('multi_select_skip', 'Skip Current & Go to Next Multi-Select', {}, function()
    multi_editing().select_next_occurrence({ match_case = true, whole_word = false }, true)
end, { modes = editing_modes, raw = true })
define_command('column_to_carets', 'Column Mode to Carets', {}, function()
    multi_editing().from_column_mode()
end, { modes = editing_modes, raw = true })
define_command('upper', 'UPPERCASE', { '<C-S-u>' }, function()
    editing_commands().convert_case('upper')
end, { modes = editing_modes })
define_command('lower', 'lowercase', { '<C-u>' }, function()
    editing_commands().convert_case('lower')
end, { modes = editing_modes })
define_command('proper', 'Proper Case', { '<M-u>' }, function()
    editing_commands().convert_case('proper')
end, { modes = editing_modes })
define_command('proper_blend', 'Proper Case (blend)', { '<M-S-u>', '<M-U>' }, function()
    editing_commands().convert_case('proper_blend')
end, { modes = editing_modes })
define_command('sentence', 'Sentence case', { '<C-M-u>' }, function()
    editing_commands().convert_case('sentence')
end, { modes = editing_modes })
define_command('sentence_blend', 'Sentence case (blend)', { '<C-M-S-u>' }, function()
    editing_commands().convert_case('sentence_blend')
end, { modes = editing_modes })
define_command('invert', 'iNVERT cASE', {}, function()
    editing_commands().convert_case('invert')
end, { modes = editing_modes })
define_command('random', 'ranDOm CasE', {}, function()
    editing_commands().convert_case('random')
end, { modes = editing_modes })
define_command('split_lines', 'Split Lines', { '<C-i>' }, function()
    editing_commands().split_lines()
end, { modes = editing_modes })
define_command('join_lines', 'Join Lines', { '<C-j>' }, function()
    editing_commands().join_lines()
end, { modes = editing_modes })
define_command('line_up', 'Move Up Current Line', { '<C-S-Up>' }, function()
    editing_commands().move_lines(-1)
end, { modes = editing_modes })
define_command('line_down', 'Move Down Current Line', { '<C-S-Down>' }, function()
    editing_commands().move_lines(1)
end, { modes = editing_modes })
define_command('blank_above', 'Insert Blank Line Above Current', { '<C-M-CR>' }, function()
    editing_commands().blank_line(false)
end, { modes = editing_modes })
define_command('blank_below', 'Insert Blank Line Below Current', { '<C-M-S-CR>' }, function()
    editing_commands().blank_line(true)
end, { modes = editing_modes })
define_command('comment_toggle', 'Toggle Single Line Comment', { '<C-q>' }, function()
    editing_commands().line_comment('toggle')
end, { modes = editing_modes })
define_command('comment', 'Single Line Comment', { '<C-k>' }, function()
    editing_commands().line_comment('comment')
end, { modes = editing_modes })
define_command('uncomment', 'Single Line Uncomment', { '<C-S-k>' }, function()
    editing_commands().line_comment('uncomment')
end, { modes = editing_modes })
define_command('stream_comment', 'Block Comment', { '<C-S-q>' }, function()
    editing_commands().stream_comment()
end, { modes = editing_modes })
define_command('stream_uncomment', 'Block Uncomment', {}, function()
    editing_commands().stream_uncomment()
end, { modes = editing_modes })
define_command('autocomplete', 'Function Completion', { '<C-Space>' }, function()
    if helpers.is_selecting() then
        return ''
    end
    return editing_commands().complete_function()
end, { modes = { 'i' }, expr = true })
define_command('autocomplete_word', 'Word Completion', { '<C-CR>' }, function()
    return editing_commands().complete_words()
end, { modes = { 'i' }, expr = true })
define_command('autocomplete_path', 'Path Completion', { '<C-M-Space>' }, function()
    return editing_commands().complete_path()
end, { modes = { 'i' }, expr = true })
define_command('calltip', 'Function Parameters Hint', { '<C-S-Space>' }, function()
    editing_commands().call_tip()
end, { modes = editing_modes, raw = true })
define_command('column_editor', 'Column Editor...', { '<M-c>' }, function()
    column_mode().editor()
end, { modes = editing_modes })
define_command('duplicate', 'Duplicate Current Line', { '<C-d>' }, function()
    editing_commands().duplicate()
end, { modes = editing_modes })
define_command('line_cut', 'Cut Current Line', { '<C-l>' }, function()
    editing_commands().line_cut()
end, { modes = editing_modes })
define_command('line_delete', 'Delete Current Line', { '<C-S-l>' }, function()
    editing_commands().line_delete()
end, { modes = editing_modes })
define_command('line_copy', 'Copy Current Line', { '<C-S-x>' }, function()
    editing_commands().line_copy()
end, { modes = editing_modes, raw = true })
define_command('transpose', 'Transpose Current and Previous Lines', { '<C-t>' }, function()
    editing_commands().line_transpose()
end, { modes = editing_modes })
define_command('rtl', 'Text Direction RTL', { '<C-M-r>' }, function()
    editing_commands().rtl(true)
end, { raw = true })
define_command('ltr', 'Text Direction LTR', { '<C-M-l>' }, function()
    editing_commands().rtl(false)
end, { raw = true })
define_command('trim_trailing', 'Trim Trailing Space', {}, function()
    editing_commands().trim_trailing()
end, { modes = editing_modes })
define_command('trim_leading', 'Trim Leading Space', {}, function()
    editing_commands().trim_leading()
end, { modes = editing_modes })
define_command('trim_both', 'Trim Leading and Trailing Space', {}, function()
    editing_commands().trim_both()
end, { modes = editing_modes })
define_command('eol_to_space', 'EOL to Space', {}, function()
    editing_commands().eol_to_space()
end, { modes = editing_modes })
define_command('tab_to_space', 'TAB to Space', {}, function()
    editing_commands().tab_to_space()
end, { modes = editing_modes })
define_command('space_to_tab_all', 'Space to TAB (All)', {}, function()
    editing_commands().space_to_tab(false)
end, { modes = editing_modes })
define_command('space_to_tab_leading', 'Space to TAB (Leading)', {}, function()
    editing_commands().space_to_tab(true)
end, { modes = editing_modes })

----------------------------------------------------------------- search

current_section = 'Search'

define_command('find', 'Find...', { '<C-f>' }, function()
    find_and_replace().open('find')
end, { raw = true })
define_command('find_in_files', 'Find in Files...', { '<C-S-f>' }, function()
    find_and_replace().open('files')
end, { raw = true })
define_command('find_next', 'Find Next', { '<F3>' }, function()
    find_and_replace().find_next(false)
end, { raw = true })
define_command('find_prev', 'Find Previous', { '<S-F3>' }, function()
    find_and_replace().find_next(true)
end, { raw = true })
define_command('set_find_next', 'Select and Find Next', { '<C-F3>' }, function()
    find_and_replace().set_and_find(false, false)
end, { raw = true })
define_command('set_find_prev', 'Select and Find Previous', { '<C-S-F3>' }, function()
    find_and_replace().set_and_find(true, false)
end, { raw = true })
define_command('volatile_next', 'Find (Volatile) Next', { '<C-M-F3>' }, function()
    find_and_replace().set_and_find(false, true)
end, { raw = true })
define_command('volatile_prev', 'Find (Volatile) Previous', { '<C-M-S-F3>' }, function()
    find_and_replace().set_and_find(true, true)
end, { raw = true })
define_command('replace', 'Replace...', { '<C-h>' }, function()
    find_and_replace().open('replace')
end, { raw = true })
define_command('incremental', 'Incremental Search', { '<C-M-i>' }, function()
    find_and_replace().incremental()
end, { raw = true })
define_command('focus_results', 'Search Results Window', { '<F7>' }, function()
    find_and_replace().focus_results()
end, { raw = true })
define_command('next_result', 'Next Search Result', { '<F4>' }, function()
    find_and_replace().next_result(1)
end, { raw = true })
define_command('prev_result', 'Previous Search Result', { '<S-F4>' }, function()
    find_and_replace().next_result(-1)
end, { raw = true })
define_command('goto_line', 'Go to...', { '<C-g>' }, function()
    editing_commands().goto_line()
end, { raw = true })
define_command('goto_brace', 'Go to Matching Brace', { '<C-b>' }, function()
    editing_commands().goto_brace()
end, { raw = true })
define_command('select_braces', 'Select All In-between {} [] or ()', { '<C-M-b>' }, function()
    editing_commands().select_braces()
end, { raw = true })
define_command('mark', 'Mark...', { '<C-m>' }, function()
    find_and_replace().open('mark')
end, { raw = true })
define_command('clear_marks', 'Clear all marks', {}, function()
    find_and_replace().clear_marks()
end, { raw = true })

-- us-layout shifted digits: terminals often send ctrl+shift+1 as <c-!>. bind
-- every ctrl+shift+digit both ways. i do the work; the terminal shrugs.
local shifted_symbol_for_digit = { [0] = ')', [1] = '!', [2] = '@', [3] = '#', [4] = '$', [5] = '%', [6] = '^', [7] = '&', [8] = '*', [9] = '(' }
local ordinal_words = { '1st', '2nd', '3rd', '4th', '5th' }
-- the search menu's five style all occurrences of token styles: ctrl+digit
-- jumps down; ctrl+shift+digit jumps up. also style, clear & copy. five
-- highlight colours for things i still can't make sense of. style 0, the find
-- mark style, follows the loop. even confusion gets a spare room.
for style_number = 1, 5 do
    define_command('style_next' .. style_number, 'Jump Down: Using ' .. ordinal_words[style_number] .. ' Style', { '<C-' .. style_number .. '>' }, function()
        find_and_replace().jump_style(style_number, 1)
    end, { raw = true })
    define_command(
        'style_prev' .. style_number,
        'Jump Up: Using ' .. ordinal_words[style_number] .. ' Style',
        { '<C-S-' .. style_number .. '>', '<C-' .. shifted_symbol_for_digit[style_number] .. '>' },
        function()
            find_and_replace().jump_style(style_number, -1)
        end,
        { raw = true }
    )
    define_command('style_all' .. style_number, 'Using ' .. ordinal_words[style_number] .. ' Style', {}, function()
        find_and_replace().style_all(style_number, false)
    end, { raw = true })
    define_command('style_one' .. style_number, 'Using ' .. ordinal_words[style_number] .. ' Style', {}, function()
        find_and_replace().style_all(style_number, true)
    end, { raw = true })
    define_command('style_clear' .. style_number, 'Clear ' .. ordinal_words[style_number] .. ' Style', {}, function()
        find_and_replace().clear_style(style_number)
    end, { raw = true })
    define_command('style_copy' .. style_number, ordinal_words[style_number] .. ' Style', {}, function()
        find_and_replace().copy_styled(style_number)
    end, { raw = true })
end
define_command('style_clear_all', 'Clear all Styles', {}, function()
    find_and_replace().clear_style(nil)
end, { raw = true })
define_command('style_copy_all', 'All Styles', {}, function()
    find_and_replace().copy_styled(nil)
end, { raw = true })
define_command('style_next0', 'Jump Down: Find Mark Style', { '<C-0>' }, function()
    find_and_replace().jump_style(0, 1)
end, { raw = true })
define_command('style_prev0', 'Jump Up: Find Mark Style', { '<C-S-0>', '<C-)>' }, function()
    find_and_replace().jump_style(0, -1)
end, { raw = true })

-- bookmarks put a blue "come back here" dot in the margin. i probably won't.
-- still, i leave it there. a small, stupid faith i can't quite delete.
define_command('bookmark_toggle', 'Toggle Bookmark', { '<C-F2>' }, function()
    bookmark_commands().toggle()
end, { raw = true })
define_command('bookmark_next', 'Next Bookmark', { '<F2>' }, function()
    bookmark_commands().jump(1)
end, { raw = true })
define_command('bookmark_prev', 'Previous Bookmark', { '<S-F2>' }, function()
    bookmark_commands().jump(-1)
end, { raw = true })
define_command('bookmark_clear', 'Clear All Bookmarks', {}, function()
    bookmark_commands().clear(0)
end, { raw = true })
define_command('bookmark_cut', 'Cut Bookmarked Lines', {}, function()
    bookmark_commands().cut()
end)
define_command('bookmark_copy', 'Copy Bookmarked Lines', {}, function()
    bookmark_commands().copy()
end, { raw = true })
define_command('bookmark_paste', 'Paste to (Replace) Bookmarked Lines', {}, function()
    bookmark_commands().paste_replace()
end)
define_command('bookmark_remove', 'Remove Bookmarked Lines', {}, function()
    bookmark_commands().remove()
end)
define_command('bookmark_remove_unmarked', 'Remove Non-Bookmarked Lines', {}, function()
    bookmark_commands().remove_unmarked()
end)
define_command('bookmark_inverse', 'Inverse Bookmark', {}, function()
    bookmark_commands().inverse()
end, { raw = true })

------------------------------------------------------------------ view

current_section = 'View'

-- f11 toggles neovide's own full screen. we cannot tell a terminal to do it,
-- so report its key instead. i wrote software that tells you to ask
-- elsewhere.
define_command('fullscreen', 'Toggle Full Screen Mode', { '<F11>' }, function()
    if vim.g.neovide then
        vim.g.neovide_fullscreen = not vim.g.neovide_fullscreen
    else
        helpers.notify('Full screen: use the terminal (Windows Terminal: F11 or Alt+Enter)')
    end
end, { raw = true })

-- post-it (f12) hides the tab line, status line & window bars. keep their old
-- values while enabled, nil while off; another f12 restores everything. i
-- want that for the years i spent writing this shit.
local saved_screen_options_for_postit = nil
define_command('postit', 'Post-It', { '<F12>' }, function()
    if saved_screen_options_for_postit then
        vim.o.showtabline, vim.o.laststatus, vim.o.winbar =
            saved_screen_options_for_postit[1], saved_screen_options_for_postit[2], saved_screen_options_for_postit[3]
        saved_screen_options_for_postit = nil
    else
        saved_screen_options_for_postit = { vim.o.showtabline, vim.o.laststatus, vim.o.winbar }
        vim.o.showtabline, vim.o.laststatus, vim.o.winbar = 0, 0, ''
        for _, window in ipairs(api.nvim_list_wins()) do
            vim.wo[window].winbar = ''
        end
    end
end, { raw = true })
-- ctrl+numpad 1 to 9 jumps to that tab. after the fifth, append "th" to the
-- number. the ordinals run out; my ability to care died considerably earlier.
for tab_number = 1, 9 do
    define_command(
        'tab' .. tab_number,
        ordinal_words[tab_number] and (ordinal_words[tab_number] .. ' Tab') or (tab_number .. 'th Tab'),
        { '<C-k' .. tab_number .. '>' },
        function()
            document_tabs().goto_index(tab_number)
        end,
        { raw = true }
    )
end
define_command('tab_next', 'Next Tab', { '<C-PageDown>' }, function()
    document_tabs().step(1)
end, { raw = true })
define_command('tab_prev', 'Previous Tab', { '<C-PageUp>' }, function()
    document_tabs().step(-1)
end, { raw = true })
define_command('tab_move_fwd', 'Move Tab Forward', { '<C-S-PageDown>' }, function()
    document_tabs().move(1)
end, { raw = true })
define_command('tab_move_back', 'Move Tab Backward', { '<C-S-PageUp>' }, function()
    document_tabs().move(-1)
end, { raw = true })
define_command('next_doc', 'Switch to next document', { '<C-Tab>' }, function()
    document_tabs().ctrl_tab(1)
end, { raw = true })
define_command('prev_doc', 'Switch to previous document', { '<C-S-Tab>' }, function()
    document_tabs().ctrl_tab(-1)
end, { raw = true })
define_command('hide_lines', 'Hide Lines', { '<M-h>' }, function()
    folding().hide()
end, { raw = true })
-- f8 moves to the next real editing window and wraps at the end. floating
-- windows & search results (quickfix) aren't views and get skipped. i wish it
-- were this easy to exclude distractions from my actual life.
define_command('switch_view', 'Focus on Another View', { '<F8>' }, function()
    local current_window = api.nvim_get_current_win()
    local view_windows = vim.tbl_filter(function(window)
        return api.nvim_win_get_config(window).relative == '' and vim.bo[api.nvim_win_get_buf(window)].buftype ~= 'quickfix'
    end, api.nvim_tabpage_list_wins(0))
    for position, window in ipairs(view_windows) do
        if window == current_window then
            api.nvim_set_current_win(view_windows[position % #view_windows + 1])
            return
        end
    end
end, { raw = true })
-- move to other view: split, then show the previous tab in the old view so it
-- doesn't duplicate the moved document. i want a clean separation. even my
-- editor manages that better than i do.
define_command('move_view', 'Move to Other View', {}, function()
    local moving_buffer = api.nvim_get_current_buf()
    local buffer_left_behind = document_tabs().previous(moving_buffer)
    vim.cmd('vsplit')
    if buffer_left_behind then
        vim.cmd('wincmd p')
        api.nvim_win_set_buf(0, buffer_left_behind)
        vim.cmd('wincmd p')
    end
end, { raw = true })
define_command('clone_view', 'Clone to Other View', {}, function()
    vim.cmd('vsplit')
end, { raw = true })
define_command('fold_all', 'Fold All', { '<M-0>' }, function()
    folding().fold_all()
end, { raw = true })
define_command('unfold_all', 'Unfold All', { '<M-S-0>', '<M-)>' }, function()
    folding().unfold_all()
end, { raw = true })
define_command('fold_current', 'Fold Current Level', { '<C-M-f>' }, function()
    folding().fold_current()
end, { raw = true })
define_command('unfold_current', 'Unfold Current Level', { '<C-M-S-f>' }, function()
    folding().unfold_current()
end, { raw = true })
-- alt+1 through alt+8 fold all at that level; alt+shift+digit unfolds. also
-- accept alt+shifted-symbol for terminals that send that shit instead.
for fold_level = 1, 8 do
    define_command('fold' .. fold_level, 'Fold Level ' .. fold_level, { '<M-' .. fold_level .. '>' }, function()
        folding().fold_level(fold_level)
    end, { raw = true })
    define_command(
        'unfold' .. fold_level,
        'Unfold Level ' .. fold_level,
        { '<M-S-' .. fold_level .. '>', '<M-' .. shifted_symbol_for_digit[fold_level] .. '>' },
        function()
            folding().unfold_level(fold_level)
        end,
        { raw = true }
    )
end
-- ctrl+numpad plus/minus zoom; ctrl+numpad slash restores the default.
-- ctrl+wheel also zooms. getting old is paying more to see less.
define_command('zoom_in', 'Zoom In', { '<C-kPlus>', '<C-=>', '<C-+>', '<C-S-=>', '<C-ScrollWheelUp>' }, function()
    appearance().zoom_by(1)
end, { raw = true })
define_command('zoom_out', 'Zoom Out', { '<C-kMinus>', '<C-->', '<C-ScrollWheelDown>' }, function()
    appearance().zoom_by(-1)
end, { raw = true })
define_command('zoom_restore', 'Restore Default Zoom', { '<C-kDivide>' }, function()
    appearance().zoom_by(0)
end, { raw = true })
current_section = 'Settings'
define_command('dark_mode', 'Dark Mode', {}, function()
    local appearance_module = appearance()
    appearance_module.set_dark_mode(not appearance_module.dark_mode())
end, { raw = true })
current_section = 'Plugins'
define_command('spell_check', 'Spell Check Document', {}, function()
    require('notebashpp.view_settings').toggle('spell_check')
end, { raw = true })
define_command('spell_next', 'Find Next Misspelling', {}, function()
    require('notebashpp.spell_check').jump(1)
end, { raw = true })
define_command('spell_prev', 'Find Previous Misspelling', {}, function()
    require('notebashpp.spell_check').jump(-1)
end, { raw = true })
define_command('spell_add', 'Add Word to Dictionary', {}, function()
    require('notebashpp.spell_check').add_word()
end, { raw = true })
-- json & xml (plugins menu). xml keys are xml tools' own defaults. i can't
-- even fail originally.
local function json_and_xml_tools()
    return require('notebashpp.json_and_xml_tools')
end
define_command('json_format', 'Format JSON', {}, function()
    json_and_xml_tools().format_json()
end)
define_command('json_minify', 'Minify JSON', {}, function()
    json_and_xml_tools().minify_json()
end)
define_command('json_check', 'Check JSON', {}, function()
    json_and_xml_tools().check_json()
end, { raw = true })
-- json viewer shows its tree on ctrl+alt+shift+j. same key, same hope that
-- a diagram will explain things.
define_command('json_tree', 'Show JSON Tree', { '<C-M-S-j>' }, function()
    require('notebashpp.json_tree').toggle()
end, { raw = true })
define_command('json_copy_path', 'Copy JSON Path', {}, function()
    require('notebashpp.json_tree').copy_path()
end, { raw = true })
define_command('xml_format', 'Pretty Print XML', { '<C-M-S-b>' }, function()
    json_and_xml_tools().format_xml()
end)
define_command('xml_linearize', 'Linearize XML', { '<C-M-S-l>' }, function()
    json_and_xml_tools().linearize_xml()
end)
define_command('xml_check', 'Check XML Syntax', { '<C-M-S-m>' }, function()
    json_and_xml_tools().check_xml()
end, { raw = true })
-- code alignment (plugins menu). i'm still shit.
define_command('align_equals', 'Align by Equals', {}, function()
    require('notebashpp.code_alignment').align('equals')
end)
define_command('align_colon', 'Align by Colon', {}, function()
    require('notebashpp.code_alignment').align('colon')
end)
define_command('align_text', 'Align by Text...', {}, function()
    require('notebashpp.code_alignment').align_by_text()
end)
define_command('hex_view', 'View in HEX', { '<C-M-S-h>' }, function()
    require('notebashpp.hex_view').toggle()
end, { raw = true })
-- spreadsheet (plugins menu). most of these also have their own keys inside a
-- spreadsheet, set by spreadsheet_view.lua for that buffer only. even my damn
-- shortcuts have a healthier work-life boundary.
define_command('sheet_toggle', 'Open as Spreadsheet / View as Text', {}, function()
    require('notebashpp.special_views').toggle_spreadsheet()
end, { raw = true })
local function spreadsheet_command(command_id, label, action_name, ...)
    local arguments = { ... }
    define_command(command_id, label, {}, function()
        require('notebashpp.spreadsheet_view').run(action_name, unpack(arguments))
    end, { raw = true })
end
spreadsheet_command('sheet_header', 'First Row Is the Header', 'toggle_header')
spreadsheet_command('sheet_row_above', 'Insert Row Above', 'insert_rows', false)
spreadsheet_command('sheet_row_below', 'Insert Row Below', 'insert_rows', true)
spreadsheet_command('sheet_row_duplicate', 'Duplicate Rows', 'duplicate_rows')
spreadsheet_command('sheet_row_delete', 'Delete Rows', 'delete_rows')
spreadsheet_command('sheet_row_up', 'Move Rows Up', 'move_rows', -1)
spreadsheet_command('sheet_row_down', 'Move Rows Down', 'move_rows', 1)
spreadsheet_command('sheet_column_left', 'Insert Column Left', 'insert_column', false)
spreadsheet_command('sheet_column_right', 'Insert Column Right', 'insert_column', true)
spreadsheet_command('sheet_column_delete', 'Delete Columns', 'delete_columns')
spreadsheet_command('sheet_column_wider', 'Widen Column', 'resize_column', 2)
spreadsheet_command('sheet_column_narrower', 'Narrow Column', 'resize_column', -2)
spreadsheet_command('sheet_go_to_row', 'Go to Row...', 'go_to_row')
spreadsheet_command('sheet_edit_cell', 'Edit Cell', 'edit_cell')
define_command('large_file_load', 'Load Whole File for Editing', {}, function()
    require('notebashpp.large_file_view').run('load_fully')
end, { raw = true })
current_section = 'View'
define_command('word_wrap', 'Word wrap', {}, function()
    require('notebashpp.view_settings').toggle('word_wrap')
end, { raw = true })
define_command('show_all_chars', 'Show All Characters', {}, function()
    require('notebashpp.view_settings').toggle('show_all_characters')
end, { raw = true })

----------------------------------------------------------------- macro

current_section = 'Macro'

-- record a macro after doing something twice, so the third time needs no hand
-- work. i want the machine to waste its own damn life for a change.
define_command('macro_record', 'Start Recording / Stop Recording', { '<C-S-r>' }, function()
    macros().toggle_record()
end, { raw = true })
define_command('macro_play', 'Playback', { '<C-S-p>' }, function()
    macros().play()
end, { raw = true })
define_command('macro_save', 'Save Current Recorded Macro...', {}, function()
    macros().save_current()
end, { raw = true })
define_command('macro_many', 'Run a Macro Multiple Times...', {}, function()
    macros().play_many()
end, { raw = true })
define_command('trim_save', 'Trim Trailing Space and Save', { '<M-S>', '<M-S-s>' }, function()
    macros().trim_and_save()
end)

------------------------------------------------------------------- run

current_section = 'Run'

-- run dialog, then notepad++'s three shipped shortcuts.xml run commands: php
-- help, wikipedia, new instance. another instance. haven't i suffered?
define_command('run', 'Run...', { '<F5>' }, function()
    run_commands().run_dialog()
end, { raw = true })
define_command('php_help', 'Get PHP help', { '<M-F1>' }, function()
    run_commands().php_help()
end, { raw = true })
define_command('wikipedia', 'Wikipedia Search', { '<M-F3>' }, function()
    run_commands().wikipedia()
end, { raw = true })
define_command('new_instance', 'Open selected file path in new instance', { '<M-F6>' }, function()
    run_commands().open_in_new_instance()
end, { raw = true })

-------------------------------------------------------- plugins: compare

current_section = 'Plugins (ComparePlus)'

-- compareplus 1.1.0 default keys, nearly all ctrl+alt+something. two files
-- side by side, differences in colour. my failures finally have a palette.
define_command('cmp_first', 'Set as First to Compare', { '<C-M-1>' }, function()
    compare_documents().set_first()
end, { raw = true })
define_command('cmp_compare', 'Compare', { '<C-M-c>' }, function()
    compare_documents().compare()
end, { raw = true })
define_command('cmp_selections', 'Compare Selections', { '<C-M-n>' }, function()
    compare_documents().selections()
end, { raw = true })
define_command('cmp_unique', 'Find Unique Lines', { '<C-M-S-c>' }, function()
    compare_documents().unique()
end, { raw = true })
define_command('cmp_unique_sel', 'Find Unique Lines in Selections', { '<C-M-S-n>' }, function()
    compare_documents().unique()
end, { raw = true })
define_command('cmp_clear', 'Clear Active Compare', { '<C-M-x>' }, function()
    compare_documents().clear()
end, { raw = true })
define_command('cmp_last_save', 'Diff since last Save', { '<C-M-d>' }, function()
    compare_documents().last_save()
end, { raw = true })
define_command('cmp_clipboard', 'Compare file/selection to Clipboard', { '<C-M-m>' }, function()
    compare_documents().clipboard()
end, { raw = true })
define_command('cmp_svn', 'SVN Diff', { '<C-M-v>' }, function()
    compare_documents().svn()
end, { raw = true })
define_command('cmp_git', 'Git Diff', { '<C-M-g>' }, function()
    compare_documents().git()
end, { raw = true })
define_command('cmp_prev', 'Previous', { '<M-PageUp>' }, function()
    compare_documents().next(-1)
end, { raw = true })
define_command('cmp_next', 'Next', { '<M-PageDown>' }, function()
    compare_documents().next(1)
end, { raw = true })
define_command('cmp_first_diff', 'First', { '<C-M-PageUp>' }, function()
    compare_documents().edge(-1)
end, { raw = true })
define_command('cmp_last_diff', 'Last', { '<C-M-PageDown>' }, function()
    compare_documents().edge(1)
end, { raw = true })

------------------------------------------------- plugins: language server

current_section = 'Plugins (Language Server)'

-- keys free in notepad++ 8.5.3: f12 is post-it, f2 is bookmarks, so the f12
-- family gets ctrl, shift and alt variants. f9 opens problems, shift+f6
-- renames (as in jetbrains editors), alt+shift+f formats (as in vs code). i
-- gave problems a dedicated key. basically the most honest thing i've built.
local function language_servers()
    return require('notebashpp.language_servers')
end
define_command('lsp_definition', 'Go to Definition', { '<C-F12>' }, function()
    language_servers().go_to_definition()
end, { raw = true })
define_command('lsp_references', 'Find References', { '<S-F12>' }, function()
    language_servers().find_references()
end, { raw = true })
define_command('lsp_hover', 'Show Documentation', { '<M-F12>' }, function()
    language_servers().hover()
end, { raw = true })
define_command('lsp_rename', 'Rename Symbol...', { '<S-F6>' }, function()
    language_servers().rename_symbol()
end, { raw = true })
define_command('lsp_format', 'Format Document', { '<M-S-f>', '<M-F>' }, function()
    language_servers().format_document()
end, { raw = true })
define_command('lsp_next_problem', 'Next Problem', { '<F9>' }, function()
    language_servers().jump_to_diagnostic(1)
end, { raw = true })
define_command('lsp_prev_problem', 'Previous Problem', { '<S-F9>' }, function()
    language_servers().jump_to_diagnostic(-1)
end, { raw = true })
define_command('lsp_problem_details', 'Show Problem Details', { '<C-F9>' }, function()
    language_servers().diagnostic_details()
end, { raw = true })
define_command('lsp_status', 'Language Server Status', {}, function()
    language_servers().show_status()
end, { raw = true })
define_command('lsp_look_again', 'Look for Language Servers Again', {}, function()
    language_servers().look_again()
end, { raw = true })
define_command('lsp_trust_folder', 'Trust This Folder', {}, function()
    language_servers().trust_folder()
end, { raw = true })
define_command('lsp_forget_trusted_folders', 'Stop Trusting All Folders', {}, function()
    language_servers().forget_trusted_folders()
end, { raw = true })

------------------------------------------------------------------ help

current_section = 'Help'

define_command('about', 'About Notebash++', { '<F1>' }, function()
    require('notebashpp.menu_bar').about()
end, { raw = true })
-- shift+f1 is free in notepad++ 8.5.3: windows "what's this?" help. my
-- question about this whole damn life.
define_command('key_help', 'What does this key do?', { '<S-F1>' }, function()
    require('notebashpp.key_help').ask_for_key()
end, { raw = true })
define_command('message_log', 'Message Log', {}, function()
    require('notebashpp.messages').open_log()
end, { raw = true })

------------------------------------------------------------------ menus

current_section = 'Menus'

-- alt+underlined letter opens its menu, the old windows-program convention.
-- f10 opens the menu bar at file. this habit will outlive my sorry ass.
local menu_access_keys = {
    { 'file', '<M-f>' },
    { 'edit', '<M-e>' },
    { 'search', '<M-s>' },
    { 'view', '<M-v>' },
    { 'encoding', '<M-n>' },
    { 'language', '<M-l>' },
    { 'settings', '<M-t>' },
    { 'tools', '<M-o>' },
    { 'macro', '<M-m>' },
    { 'run', '<M-r>' },
    { 'plugins', '<M-p>' },
    { 'window', '<M-w>' },
    { 'help', '<M-?>' },
}
for _, menu_and_key in ipairs(menu_access_keys) do
    define_command('menu_' .. menu_and_key[1], menu_and_key[1]:gsub('^%l', string.upper) .. ' menu', { menu_and_key[2] }, function()
        require('notebashpp.menu_bar').open(menu_and_key[1])
    end, { raw = true })
end
define_command('menu_bar', 'Menu bar', { '<F10>' }, function()
    require('notebashpp.menu_bar').open('file')
end, { raw = true })

---------------------------------------------------------- setting keys

-- when a terminal has no name for a modified function-key combination,
-- shift+f2 arrives as f14, ctrl+f2 as f26, and so on, 12 apart. this is
-- xterm's numbering, used by tmux and most terminals. left unbound, neovim
-- types the key's name into the document: "<f26>" in your file instead of a
-- bookmark. absolutely perfect. now even my failures need proofreading.
local FUNCTION_KEY_OFFSET_FOR_MODIFIERS = { ['S-'] = 12, ['C-'] = 24, ['C-S-'] = 36, ['M-'] = 48, ['M-S-'] = 60 }

local function terminal_function_key(key)
    local modifiers, number = key:upper():match('^<([CMS%-]+)F(%d+)>$')
    local offset = modifiers and FUNCTION_KEY_OFFSET_FOR_MODIFIERS[modifiers]
    number = tonumber(number)
    if offset and number and number >= 1 and number <= 12 then
        return ('<F%d>'):format(number + offset)
    end
end

-- keys here default to silent & nowait: no command-line echo, no waiting for
-- a longer key sequence. i want my mistakes executed immediately. growing old
-- is slow enough.
local function set_key(modes, key, action, options)
    options = vim.tbl_extend('force', { silent = true, nowait = true }, options or {})
    -- a failed lua action reports through messages.lua, then does nothing
    -- else; an expression mapping returns no keys. i'd love to fail this
    -- cleanly. mine usually involves an invoice.
    if type(action) == 'function' then
        local unprotected_action, key_name, is_expression = action, keybindings.pretty(key), options.expr
        action = function(...)
            local results = vim.F.pack_len(require('notebashpp.messages').call(key_name, unprotected_action, ...))
            if not results[1] then
                return is_expression and '' or nil
            end
            return unpack(results, 2, results.n)
        end
    end
    vim.keymap.set(modes, key, action, options)
    local terminal_key = terminal_function_key(key)
    if terminal_key then
        vim.keymap.set(modes, terminal_key, action, options)
    end
end

-- keys unbound in notepad++ do nothing here, suppressing their vim meanings
-- (alt+key would otherwise leave insert mode). i want a harmless dead key.
-- neovim keeps offering me a trap with historical significance.
local function block_unbound()
    local letters = 'abcdefghijklmnopqrstuvwxyz'
    for letter in letters:gmatch('.') do
        for _, key in ipairs({
            '<C-' .. letter .. '>',
            '<C-S-' .. letter .. '>',
            '<M-' .. letter .. '>',
            '<M-' .. letter:upper() .. '>',
            '<C-M-' .. letter .. '>',
            '<C-M-S-' .. letter .. '>',
        }) do
            set_key(editing_modes, key, '<Nop>')
        end
    end
    for digit = 0, 9 do
        for _, key in ipairs({ '<C-' .. digit .. '>', '<M-' .. digit .. '>', '<C-M-' .. digit .. '>', '<C-S-' .. digit .. '>' }) do
            set_key(editing_modes, key, '<Nop>')
        end
    end
    -- unbound terminal codes for modified function keys (f13 to f72) do
    -- nothing instead of typing their names into the text. i want fewer
    -- mistakes in the document (the bastard writing it is quite enough).
    for function_key_number = 13, 72 do
        local key = ('<F%d>'):format(function_key_number)
        if vim.fn.maparg(key, 'i') == '' then
            set_key(editing_modes, key, '<Nop>')
        end
    end
    for _, punctuation in ipairs({
        '!',
        '@',
        '#',
        '$',
        '%',
        '^',
        '&',
        '*',
        '(',
        ')',
        '-',
        '=',
        '_',
        '+',
        '[',
        ']',
        '{',
        '}',
        ';',
        "'",
        ':',
        '"',
        ',',
        '.',
        '/',
        '<lt>',
        '>',
        '?',
        '`',
        '~',
        '\\',
        '|',
    }) do
        set_key(editing_modes, '<M-' .. punctuation .. '>', '<Nop>')
    end
    for function_key_number = 1, 12 do
        for _, modifier_prefix in ipairs({ '', 'S-', 'C-', 'M-', 'C-S-', 'M-S-', 'C-M-', 'C-M-S-' }) do
            set_key(editing_modes, '<' .. modifier_prefix .. 'F' .. function_key_number .. '>', '<Nop>')
        end
    end
    for _, key in ipairs({
        '<C-@>',
        '<C-^>',
        '<C-_>',
        '<C-]>',
        '<C-\\>',
        '<C-[>',
        '<C-Space>',
        '<C-CR>',
        '<C-S-CR>',
        '<M-CR>',
        '<M-S-CR>',
        '<M-Space>',
        '<M-Tab>',
        '<M-Up>',
        '<M-Down>',
        '<M-Left>',
        '<M-Right>',
        '<M-Home>',
        '<M-End>',
        '<M-PageUp>',
        '<M-PageDown>',
        '<M-Del>',
        '<M-Insert>',
        '<M-Esc>',
    }) do
        set_key(editing_modes, key, '<Nop>')
    end
end

-- scintilla movement & selection: shift extends selection; no shift drops it.
-- each key gets an expression from caret_movement so the caret lands where
-- scintilla would put it. i outsourced even knowing where i am.
local function motions()
    local function map_motion(key, motion_name, extend_selection)
        set_key(editing_modes, key, caret_movement().expr(motion_name, extend_selection), { expr = true })
    end
    -- arrows, home, end & page keys also get numpad bindings (<khome> etc.).
    -- some terminals send those. i get to clean up. somehow i chose this
    -- life.
    local plain_motions = {
        Left = 'left',
        Right = 'right',
        Up = 'up',
        Down = 'down',
        Home = 'home',
        End = 'end',
        PageUp = 'page_up',
        PageDown = 'page_down',
    }
    for key_name, motion_name in pairs(plain_motions) do
        map_motion('<' .. key_name .. '>', motion_name, false)
        map_motion('<S-' .. key_name .. '>', motion_name, true)
        map_motion('<k' .. key_name .. '>', motion_name, false)
        map_motion('<S-k' .. key_name .. '>', motion_name, true)
    end
    -- ctrl+shift+right selects to word end, rather than the next word's start
    -- (sci_wordrightendextend). scintilla stops early on purpose. i kept
    -- going and ended up writing this damn configuration.
    map_motion('<C-Left>', 'word_left', false)
    map_motion('<C-Right>', 'word_right', false)
    map_motion('<C-S-Left>', 'word_left', true)
    map_motion('<C-S-Right>', 'word_right_end', true)
    map_motion('<C-Home>', 'doc_start', false)
    map_motion('<C-End>', 'doc_end', false)
    map_motion('<C-S-Home>', 'doc_start', true)
    map_motion('<C-S-End>', 'doc_end', true)
    map_motion('<C-kHome>', 'doc_start', false)
    map_motion('<C-kEnd>', 'doc_end', false)
    map_motion('<M-Home>', 'home_display', false)
    map_motion('<M-End>', 'end_display', false)
    -- ctrl+[ and ctrl+] jump paragraphs; ctrl+/ and ctrl+\ jump word parts.
    -- when shifted, terminals may send <c-{> or <c-?> for <c-s-[> or <c-s-/>.
    -- bind both spellings. i subsidise their bullshit with my finite
    -- lifespan.
    map_motion('<C-[>', 'para_up', false)
    map_motion('<C-]>', 'para_down', false)
    map_motion('<C-S-[>', 'para_up', true)
    map_motion('<C-S-]>', 'para_down', true)
    map_motion('<C-{>', 'para_up', true)
    map_motion('<C-}>', 'para_down', true)
    map_motion('<C-/>', 'part_left', false)
    map_motion('<C-\\>', 'part_right', false)
    map_motion('<C-S-/>', 'part_left', true)
    map_motion('<C-?>', 'part_left', true)
    map_motion('<C-S-\\>', 'part_right', true)
    map_motion('<C-Bar>', 'part_right', true)

    -- column (rectangular) selection: alt+shift+arrows or alt+mouse. i want
    -- one part of this mess to have boundaries. text will have to do.
    local column_motions = {
        Up = 'up',
        Down = 'down',
        Left = 'left',
        Right = 'right',
        Home = 'home',
        End = 'end',
        PageUp = 'page_up',
        PageDown = 'page_down',
    }
    for key_name, direction in pairs(column_motions) do
        set_key(editing_modes, '<M-S-' .. key_name .. '>', function()
            column_mode().extend(direction)
        end)
    end
    set_key({ 'i', 's', 'x', 'n' }, '<M-LeftMouse>', function()
        column_mode().mouse(false)
    end)
    set_key({ 'i', 's', 'x', 'n' }, '<M-LeftDrag>', function()
        column_mode().mouse(true)
    end)
    set_key({ 'i', 's', 'x', 'n' }, '<M-LeftRelease>', '<Nop>')

    -- ctrl+up/down scroll one line (sci_linescrollup, sci_linescrolldown).
    -- keep the caret still unless it would leave the screen; then drag it to
    -- the nearest edge. basically how i keep up with life, except this works
    -- and doesn't cost me money.
    local function scroll(direction)
        return function()
            local view = vim.fn.winsaveview()
            local last_line = helpers.count_lines()
            view.topline = math.max(1, math.min(last_line, view.topline + direction))
            local window_height = api.nvim_win_get_height(0)
            if view.lnum < view.topline then
                view.lnum = view.topline
            elseif view.lnum >= view.topline + window_height then
                view.lnum = view.topline + window_height - 1
            end
            vim.fn.winrestview(view)
        end
    end
    set_key(editing_modes, '<C-Up>', scroll(-1))
    set_key(editing_modes, '<C-Down>', scroll(1))
end

-- typing keys: enter, tab, backspace, delete, escape. ten thousand presses a
-- day without thinking. i want them right; the wasted life is on me.
local function typing()
    -- true if completion is open with a highlighted word. enter & tab then
    -- accept it via <c-y>, as in notepad++. commitment made stupidly easy.
    local function completion_item_selected()
        return vim.fn.pumvisible() == 1 and vim.fn.complete_info({ 'selected' }).selected >= 0
    end
    -- enter first breaks undo with <c-g>u, giving each new line its own undo
    -- step. in select mode it replaces the selection with a line break,
    -- discarding into the black hole register. i want that for my old
    -- decisions.
    local function enter_keys()
        if completion_item_selected() then
            return '<C-y>'
        end
        if multi_editing().active() then
            return '<Cmd>lua require("notebashpp.multi_editing").newline()<CR>'
        end
        if column_mode().active() then
            column_mode().clear()
        end
        return '<C-g>u<CR>'
    end
    set_key('i', '<CR>', enter_keys, { expr = true })
    set_key('i', '<S-CR>', function()
        return multi_editing().active() and '<Cmd>lua require("notebashpp.multi_editing").newline()<CR>' or '<C-g>u<CR>'
    end, { expr = true })
    set_key('i', '<kEnter>', function()
        return multi_editing().active() and '<Cmd>lua require("notebashpp.multi_editing").newline()<CR>' or '<C-g>u<CR>'
    end, { expr = true })
    set_key('s', '<CR>', '<C-g>"_c<CR>')
    set_key('s', '<S-CR>', '<C-g>"_c<CR>')
    set_key('s', '<kEnter>', '<C-g>"_c<CR>')

    -- tab accepts completion, inserts a tab on every column-selection row, or
    -- calls editing_commands.tab to indent as one undo step. busy bastard.
    set_key('i', '<Tab>', function()
        if completion_item_selected() then
            return '<C-y>'
        end
        if multi_editing().active() then
            return '<Cmd>lua require("notebashpp.multi_editing").tab()<CR>'
        end
        if column_mode().active() then
            return '<Cmd>lua require("notebashpp.column_mode").insert("\\t")<CR>'
        end
        return '<Cmd>lua require("notebashpp.helpers").run_as_one_undo_step(require("notebashpp.editing_commands").tab)<CR>'
    end, { expr = true })
    set_key({ 's', 'x' }, '<Tab>', function()
        helpers.run_as_one_undo_step(editing_commands().tab)
    end)
    set_key(editing_modes, '<S-Tab>', function()
        helpers.run_as_one_undo_step(editing_commands().backtab)
    end)

    -- backspace & delete affect every row of a column selection at once.
    -- otherwise they work normally. i want that kind of efficient removal for
    -- my regrets, but apparently i only get it for text.
    local function backspace_keys()
        if multi_editing().active() then
            return '<Cmd>lua require("notebashpp.multi_editing").delete(-1)<CR>'
        end
        if column_mode().active() then
            return '<Cmd>lua require("notebashpp.column_mode").delete(-1)<CR>'
        end
        return '<BS>'
    end
    local function delete_keys()
        if multi_editing().active() then
            return '<Cmd>lua require("notebashpp.multi_editing").delete(1)<CR>'
        end
        if column_mode().active() then
            return '<Cmd>lua require("notebashpp.column_mode").delete(1)<CR>'
        end
        return '<Del>'
    end
    set_key('i', '<BS>', backspace_keys, { expr = true })
    set_key('i', '<S-BS>', backspace_keys, { expr = true })
    set_key('i', '<Del>', delete_keys, { expr = true })
    set_key('i', '<kDel>', delete_keys, { expr = true })
    set_key({ 's', 'x' }, '<Del>', function()
        helpers.run_as_one_undo_step(editing_commands().delete_selection)
    end)
    set_key({ 's', 'x' }, '<kDel>', function()
        helpers.run_as_one_undo_step(editing_commands().delete_selection)
    end)
    set_key({ 's', 'x' }, '<S-BS>', '<C-g>"_c')

    -- ctrl+backspace & friends: sci_delwordleft, sci_delwordright,
    -- sci_dellineleft, sci_dellineright. delete an active selection instead;
    -- in column mode do nothing. i finally taught software to leave shit
    -- alone. it took more of my life than i care to calculate.
    local function delete_unless_selected(editing_command_name)
        return function()
            if multi_editing().active() then
                return helpers.run_as_one_undo_step(multi_editing().delete_to, editing_command_name)
            end
            if column_mode().active() then
                return
            end
            if helpers.get_selection() then
                return helpers.run_as_one_undo_step(editing_commands().delete_selection)
            end
            helpers.run_as_one_undo_step(editing_commands()[editing_command_name])
        end
    end
    set_key(editing_modes, '<C-BS>', delete_unless_selected('del_word_left'))
    set_key(editing_modes, '<C-Del>', delete_unless_selected('del_word_right'))
    set_key(editing_modes, '<C-S-BS>', delete_unless_selected('del_line_left'))
    set_key(editing_modes, '<C-S-Del>', delete_unless_selected('del_line_right'))

    -- escape closes completion (<c-e>), otherwise drops a column selection,
    -- otherwise does nothing. it never leaves insert mode, as in notepad++. i
    -- installed an escape key and then bricked up the damn exit.
    set_key('i', '<Esc>', function()
        if vim.fn.pumvisible() == 1 then
            return '<C-e>'
        end
        if multi_editing().active() then
            multi_editing().clear()
        end
        if column_mode().active() then
            column_mode().clear()
        end
        return ''
    end, { expr = true })
    -- insert toggles overtype like notepad++, using neovim's own insert key.
    -- the vim default i kept. apparently even i can't ruin absolutely
    -- everything.
    set_key('i', '<Insert>', '<Insert>')
end

-- ctrl+wheel zooms via the command table above. double-click selects the
-- pointer's word, start_col to end_col. at least something gets understood.
local function mouse()
    -- multi-editing: ctrl+click adds or removes a caret; ctrl+drag and
    -- ctrl+double-click add a selection. a plain click ends multi-editing and
    -- clicks as usual. i can end this mess with one click. my other mistakes
    -- apparently need a lawyer.
    set_key(all_modes, '<C-LeftMouse>', function()
        multi_editing().mouse_add()
    end)
    set_key(all_modes, '<C-LeftDrag>', function()
        multi_editing().mouse_drag()
    end)
    set_key(all_modes, '<C-2-LeftMouse>', function()
        multi_editing().mouse_add_word()
    end)
    set_key(all_modes, '<C-LeftRelease>', '<Nop>')
    set_key('i', '<LeftMouse>', function()
        if multi_editing().active() then
            multi_editing().clear()
        end
        return '<LeftMouse>'
    end, { expr = true })
    set_key(editing_modes, '<2-LeftMouse>', function()
        local mouse_position = vim.fn.getmousepos()
        if mouse_position.winid == 0 or mouse_position.line == 0 then
            return
        end
        api.nvim_set_current_win(mouse_position.winid)
        api.nvim_win_set_cursor(0, { mouse_position.line, math.max(0, mouse_position.column - 1) })
        local _, word_range = helpers.word_at_caret()
        if word_range then
            helpers.select_range({ word_range.start_line, word_range.start_col }, { word_range.end_line, word_range.end_col })
        end
    end)
end

-- notepad++ reads physical keys: ctrl+s works on hebrew or arabic layouts.
-- neovide sends the typed character (ctrl+s arrives as ctrl+ד), so ctrl or
-- alt letter shortcuts also accept the same physical key in those layouts.
-- omit hebrew q: it types "/", and ctrl+/ already means something else. i
-- want save to save. apparently this modest ambition requires a damn
-- international keyboard investigation.
local non_latin_layouts = {
    hebrew = {
        a = 'ש',
        b = 'נ',
        c = 'ב',
        d = 'ג',
        e = 'ק',
        f = 'כ',
        g = 'ע',
        h = 'י',
        i = 'ן',
        j = 'ח',
        k = 'ל',
        l = 'ך',
        m = 'צ',
        n = 'מ',
        o = 'ם',
        p = 'פ',
        r = 'ר',
        s = 'ד',
        t = 'א',
        u = 'ו',
        v = 'ה',
        w = "'",
        x = 'ס',
        y = 'ט',
        z = 'ז',
    },
    arabic = {
        a = 'ش',
        c = 'ؤ',
        d = 'ي',
        e = 'ث',
        f = 'ب',
        g = 'ل',
        h = 'ا',
        i = 'ه',
        j = 'ت',
        k = 'ن',
        l = 'م',
        m = 'ة',
        n = 'ى',
        o = 'خ',
        p = 'ح',
        q = 'ض',
        r = 'ق',
        s = 'س',
        t = 'ف',
        u = 'ع',
        v = 'ر',
        w = 'ص',
        x = 'ء',
        y = 'غ',
        z = 'ئ',
    },
}

-- walk existing mappings; add layout aliases for unshifted ctrl/alt letters.
-- skip <nop> mappings. set an alias only in an empty or <nop> slot. i want to
-- copy the useful bits. copying nothing is already my day job.
local function layout_aliases()
    for _, mode in ipairs({ 'i', 's', 'x', 'n' }) do
        for _, mapping in ipairs(api.nvim_get_keymap(mode)) do
            local modifiers, letter = mapping.lhs:match('^<([CMSA%-]+)(%a)>$')
            if modifiers and mapping.rhs ~= '' and (mapping.callback or (mapping.rhs and mapping.rhs:lower() ~= '<nop>')) then
                local has_ctrl = modifiers:find('C', 1, true) ~= nil
                local has_shift = modifiers:find('S', 1, true) ~= nil or (not has_ctrl and letter:match('%u') ~= nil)
                if not has_shift then
                    for _, letter_to_layout_char in pairs(non_latin_layouts) do
                        local layout_char = letter_to_layout_char[letter:lower()]
                        if layout_char then
                            local alias = '<' .. modifiers .. layout_char .. '>'
                            if vim.fn.maparg(alias, mode) == '' or vim.fn.maparg(alias, mode):lower() == '<nop>' then
                                vim.keymap.set(mode, alias, mapping.lhs, { remap = true, silent = true })
                            end
                        end
                    end
                end
            end
        end
    end
end

-- latin letter for each hebrew or arabic character above: ctrl+ד reads as
-- ctrl+s. save my file. something should survive.
local latin_letter_for_layout_character = {}
for _, letter_to_layout_character in pairs(non_latin_layouts) do
    for latin_letter, layout_character in pairs(letter_to_layout_character) do
        latin_letter_for_layout_character[layout_character] = latin_letter
    end
end

-- the name notepad++ prints for a key (ctrl+shift+f1). reduce every way of
-- writing or receiving the same key to one: terminal function keys f13 to f72
-- become modified f1 to f12; a hebrew or arabic character becomes the latin
-- letter on the same physical key; ctrl+letter ignores letter case, as neovim
-- does (keytrans() writes ctrl+x with an uppercase x). all this shit just to
-- agree which button i pressed. i'm getting older while the computer works
-- through its identity crisis.
function keybindings.canonical_key_name(key)
    local function_key_number = tonumber(key:upper():match('^<F(%d+)>$'))
    if function_key_number and function_key_number > 12 and function_key_number <= 72 then
        for modifiers, offset in pairs(FUNCTION_KEY_OFFSET_FOR_MODIFIERS) do
            if function_key_number - offset >= 1 and function_key_number - offset <= 12 then
                key = ('<%sF%d>'):format(modifiers, function_key_number - offset)
            end
        end
    end
    local modifiers, base_key = key:match('^<([CMSADcmsad]%-[CMSADcmsad%-]*)(.+)>$')
    if modifiers then
        base_key = latin_letter_for_layout_character[base_key] or base_key
        local upper_modifiers = modifiers:upper()
        if upper_modifiers:find('C', 1, true) and not upper_modifiers:find('S', 1, true) and base_key:match('^%a$') then
            base_key = base_key:lower()
        end
        key = '<' .. modifiers .. base_key .. '>'
    end
    return keybindings.pretty(key)
end

-- every command with `key` among its keys, in menu order. regret, sorted.
function keybindings.commands_for_key(key)
    local wanted_name = keybindings.canonical_key_name(key)
    local matching_commands = {}
    for _, command in ipairs(keybindings.list) do
        for _, command_key in ipairs(command.keys) do
            if keybindings.canonical_key_name(command_key) == wanted_name then
                matching_commands[#matching_commands + 1] = command
                break
            end
        end
    end
    return matching_commands
end

-- user.lua commands enter the macro menu; its keys replace existing commands'
-- defaults. warn if a key names an unknown id. i want to catch the wrong name
-- before it becomes another unpaid investigation.
local function apply_user_settings()
    local settings = require('notebashpp.user_settings')
    for _, user_command in ipairs(settings.get('commands') or {}) do
        if user_command.id and not keybindings.by_id[user_command.id] and type(user_command.run) == 'function' then
            current_section = 'Macro'
            local command = define_command(user_command.id, user_command.label or user_command.id, user_command.keys or {}, user_command.run)
            command.from_user = true
        end
    end
    for command_id, keys in pairs(settings.get('keys') or {}) do
        if keybindings.by_id[command_id] then
            keybindings.by_id[command_id].keys = keys
        else
            vim.schedule(function()
                vim.notify('Notebash++: user.lua gives keys to an unknown command: ' .. command_id, vim.log.levels.WARN)
            end)
        end
    end
end

-- order matters: apply user.lua, block with <nop>s, overlay real keys, then
-- add layout aliases so they see everything already mapped. i want one
-- sequence in my life where hindsight arrives in time.
function keybindings.setup()
    apply_user_settings()
    block_unbound()
    for _, command in ipairs(keybindings.list) do
        for _, key in ipairs(command.keys) do
            if command.expr then
                set_key(command.modes, key, command.fn, { expr = true })
            else
                set_key(command.modes, key, function()
                    keybindings.run(command.id)
                end)
            end
        end
    end
    motions()
    typing()
    mouse()
    layout_aliases()
    -- search results: enter opens the hit; esc returns to the previous
    -- window. i can get you back this far. the rest of your life is beyond my
    -- skill.
    api.nvim_create_autocmd('FileType', {
        group = api.nvim_create_augroup('notebashpp_qf', { clear = true }),
        pattern = 'qf',
        callback = function(event)
            vim.keymap.set('n', '<Esc>', '<Cmd>wincmd p<CR>', { buffer = event.buf, silent = true })
            vim.keymap.set('n', '<2-LeftMouse>', '<CR>', { buffer = event.buf, silent = true })
        end,
    })
    -- on each buffer's file type event, notebashpp.folding sets up its
    -- folds. i want every file to have somewhere to hide. seems only fair.
    api.nvim_create_autocmd('FileType', {
        group = api.nvim_create_augroup('notebashpp_folds', { clear = true }),
        callback = function(event)
            require('notebashpp.folding').setup_buffer(event.buf)
        end,
    })
    require('notebashpp.column_mode').setup()
    require('notebashpp.multi_editing').setup()
end

return keybindings
