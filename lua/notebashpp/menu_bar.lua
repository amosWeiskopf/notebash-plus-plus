-- the menu bar: file edit search view encoding language settings tools macro
-- run plugins window ?. alt+letter, f10 or a click opens it; arrow keys,
-- enter, esc and underlined letters drive it, like a windows menu from 1995.
-- also the right-click menu and about box. i rebuilt all this with my finite
-- life. the about box should absolutely contain an apology.

local menu_bar = {}
local api = vim.api
local helpers = require('notebashpp.helpers')

local function keybindings_module()
    return require('notebashpp.keybindings')
end

local separator = { sep = true }

-- one menu item: & before the accelerator letter; action is a command id from
-- keybindings.lua or a plain function. extra_fields (disabled, checked,
-- shortcut) get copied straight on. sub holds a submenu table or a function
-- that builds one. basically a little coffin for a perfectly good afternoon.
local function new_item(label, action, extra_fields)
    local menu_item = { label = label }
    if type(action) == 'string' then
        menu_item.id = action
    else
        menu_item.fn = action
    end
    if extra_fields then
        for field_name, field_value in pairs(extra_fields) do
            menu_item[field_name] = field_value
        end
    end
    return menu_item
end

local function new_submenu(label, submenu_items)
    return { label = label, sub = submenu_items }
end

local function editing_commands()
    return require('notebashpp.editing_commands')
end

-- edit > multi-select all / multi-select next: one item per search flavour.
-- labels & ids come from keybindings.lua; && displays a plain &. even this
-- damn menu has more choices than i do.
local function multi_select_items(command_id_prefix)
    local items = {}
    for _, flavour in ipairs(keybindings_module().MULTI_SELECT_FLAVOURS) do
        items[#items + 1] = new_item(flavour.menu_label, command_id_prefix .. flavour.id)
    end
    return items
end

-- file > recent files: the last ten files, numbered &1 through &9, then &0
-- for the tenth, like notepad++. i want my wasted time numbered so i can
-- reopen it and waste it properly.
local function recent_files()
    local items = {}
    for index, path in ipairs(require('notebashpp.file_commands').recent(10)) do
        items[#items + 1] = new_item(('&%d: %s'):format(index % 10, path), function()
            require('notebashpp.file_commands').open_path(path)
        end)
    end
    if #items == 0 then
        items[1] = new_item('(empty)', nil, { disabled = true })
    end
    return items
end

-- window menu: "windows..." opens a picker of every open document, followed
-- by the first ten documents, numbered like recent files. checks the one you
-- were in before opening the menu. somebody should know where you were.
local function window_list()
    local items = {
        new_item('&Windows...', function()
            local document_tabs = require('notebashpp.document_tabs')
            local buffer_order = document_tabs.sync()
            vim.ui.select(buffer_order, {
                prompt = 'Windows',
                format_item = function(buffer)
                    return document_tabs.name(buffer) .. (vim.bo[buffer].modified and ' *' or '') .. '   ' .. document_tabs.full_name(buffer)
                end,
            }, function(chosen_buffer)
                if chosen_buffer then
                    api.nvim_set_current_buf(chosen_buffer)
                end
            end)
        end),
        separator,
    }
    local document_tabs = require('notebashpp.document_tabs')
    for index, buffer in ipairs(document_tabs.sync()) do
        if index > 10 then
            break
        end
        items[#items + 1] = new_item(('&%d: %s'):format(index % 10, document_tabs.full_name(buffer)), function()
            api.nvim_set_current_buf(buffer)
        end, { checked = buffer == menu_bar.origin_buf })
    end
    return items
end

-- language entries pair the notepad++ label with its neovim filetype.
-- thirty-odd languages, and i still can't explain what the hell i'm doing.
local LANGUAGES = {
    { 'Normal Text', 'text' },
    { 'Batch', 'dosbatch' },
    { 'C', 'c' },
    { 'C#', 'cs' },
    { 'C++', 'cpp' },
    { 'CSS', 'css' },
    { 'CSV', 'csv' },
    { 'Diff', 'diff' },
    { 'Go', 'go' },
    { 'HTML', 'html' },
    { 'INI file', 'dosini' },
    { 'Java', 'java' },
    { 'JavaScript', 'javascript' },
    { 'JSON', 'json' },
    { 'Lua', 'lua' },
    { 'Makefile', 'make' },
    { 'Markdown', 'markdown' },
    { 'Perl', 'perl' },
    { 'PHP', 'php' },
    { 'PowerShell', 'ps1' },
    { 'Python', 'python' },
    { 'R', 'r' },
    { 'Ruby', 'ruby' },
    { 'Rust', 'rust' },
    { 'Shell', 'sh' },
    { 'SQL', 'sql' },
    { 'TeX', 'tex' },
    { 'TOML', 'toml' },
    { 'TypeScript', 'typescript' },
    { 'VB', 'vb' },
    { 'XML', 'xml' },
    { 'YAML', 'yaml' },
}

-- check the originating document's filetype. the current buffer is now the
-- menu itself, because even a menu needs to make everything about itself.
local function language_list()
    local items = {}
    for _, language in ipairs(LANGUAGES) do
        items[#items + 1] = new_item(language[1], function()
            vim.bo.filetype = language[2]
        end, { checked = vim.bo[menu_bar.origin_buf or 0].filetype == language[2] })
    end
    return items
end

-- encoding > utf-8 and friends changes the next save's encoding. disk bytes
-- stay untouched until then. basically postponing the damage, my specialty.
local function set_encoding(file_encoding, with_bom)
    return function()
        vim.bo.fileencoding = file_encoding
        vim.bo.bomb = with_bom
    end
end

-- encoding > character set rereads the disk file in another code page. this
-- would discard unsaved changes, so it refuses while any exist. absolutely
-- touching. a computer with less contempt for my work than me.
local function reopen_with_encoding(encoding_name)
    return function()
        if vim.bo.modified then
            return helpers.warn('Save the document first')
        end
        vim.cmd('edit ++enc=' .. encoding_name)
    end
end

-- macro menu: fixed items, then every user macro from shortcuts.xml, then
-- this session's saved macros alphabetically. i automated the repetition so i
-- could spend my remaining years inventing fresh crap to repeat.
local function macro_list()
    local items = {
        new_item('Start Re&cording / Stop Recording', 'macro_record'),
        new_item('&Playback', 'macro_play'),
        new_item('Sa&ve Current Recorded Macro...', 'macro_save'),
        new_item('&Run a Macro Multiple Times...', 'macro_many'),
        separator,
        new_item('Trim Trailing Space and Save', 'trim_save'),
    }
    for _, binding in ipairs(require('notebashpp.keybindings').list) do
        if binding.from_user then
            items[#items + 1] = new_item(binding.label, binding.id)
        end
    end
    local saved_macros = require('notebashpp.macros').saved
    local macro_names = vim.tbl_keys(saved_macros)
    table.sort(macro_names)
    for _, macro_name in ipairs(macro_names) do
        items[#items + 1] = new_item(macro_name, function()
            require('notebashpp.macros').play_saved(macro_name)
        end)
    end
    return items
end

-- tools > md5 / sha-256 hashes the selection, or the whole document if none,
-- and copies the hex digest to the clipboard. sha-256 is built into neovim;
-- md5 tries the system's md5sum, md5 or openssl, whichever answers first. i
-- want a checksum. apparently i need to assemble a damn support network.
local function hash(kind)
    return function()
        local text = helpers.selected_text_or_word_at_caret()
        local selection = helpers.get_selection()
        if not selection then
            text = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), '\n')
        end
        local digest
        if kind == 'sha256' then
            digest = vim.fn.sha256(text)
        else
            local md5_command = vim.fn.executable('md5sum') == 1 and { 'md5sum' }
                or vim.fn.executable('md5') == 1 and { 'md5', '-q' }
                or vim.fn.executable('openssl') == 1 and { 'openssl', 'md5', '-r' }
            if not md5_command then
                return helpers.warn('MD5 needs md5sum, md5 or openssl.')
            end
            digest = vim.trim(vim.fn.system(md5_command, text)):match('^(%x+)')
        end
        require('notebashpp.clipboard').set({ digest }, 'v')
        helpers.notify(kind:upper() .. ': ' .. digest .. '  (copied to the clipboard)')
    end
end

-- five "using nth style" items: command_prefix plus the style number makes
-- the command id (style_all1, style_one3, etc.). even despair gets styles.
local function style_menu(command_prefix)
    local items = {}
    for style_number = 1, 5 do
        items[#items + 1] = new_item(
            ({ 'Using &1st Style', 'Using &2nd Style', 'Using &3rd Style', 'Using &4th Style', 'Using &5th Style' })[style_number],
            command_prefix .. style_number
        )
    end
    return items
end

-- the whole bar, in notepad++ 8.5.3 order and spelling. name is the key for
-- open() and alt+letter commands. items is a list or a function rebuilding it
-- whenever the menu opens. 300 lines of labels. i could have called a friend,
-- but apparently this was absolutely necessary.
menu_bar.MENUS = {
    {
        name = 'file',
        title = '&File',
        items = {
            new_item('&New', 'new'),
            new_item('&Open...', 'open'),
            new_submenu('Open Containing &Folder', {
                new_item('Explorer', function()
                    require('notebashpp.file_commands').open_containing_folder()
                end),
                new_item('cmd', function()
                    require('notebashpp.file_commands').open_cmd_here()
                end),
            }),
            new_item('Re&load from Disk', 'reload'),
            new_item('Load &Whole File for Editing', 'large_file_load'),
            new_item('&Save', 'save'),
            new_item('Save &As...', 'save_as'),
            new_item('Save a Cop&y As...', 'save_copy'),
            new_item('Sav&e All', 'save_all'),
            new_item('&Rename...', function()
                require('notebashpp.file_commands').rename()
            end),
            new_item('&Close', 'close'),
            new_item('Clos&e All', 'close_all'),
            new_submenu('Close &Multiple Documents', {
                new_item('Close All BUT Current Document', function()
                    require('notebashpp.file_commands').close_many('others')
                end),
                new_item('Close All to the Left', function()
                    require('notebashpp.file_commands').close_many('left')
                end),
                new_item('Close All to the Right', function()
                    require('notebashpp.file_commands').close_many('right')
                end),
                new_item('Close All Unchanged', function()
                    require('notebashpp.file_commands').close_many('unchanged')
                end),
            }),
            new_item('Move to Recycle &Bin', function()
                require('notebashpp.file_commands').delete_file()
            end),
            separator,
            new_item('&Print...', 'print'),
            separator,
            new_submenu('&Recent Files', recent_files),
            new_item('Restore Recent Closed File', 'restore_closed'),
            separator,
            new_item('E&xit', 'exit'),
        },
    },
    {
        name = 'edit',
        title = '&Edit',
        items = {
            new_item('&Undo', 'undo'),
            new_item('&Redo', 'redo'),
            separator,
            new_item('Cu&t', 'cut'),
            new_item('&Copy', 'copy'),
            new_item('&Paste', 'paste'),
            new_item('&Delete', function()
                editing_commands().delete_selection()
            end, { shortcut = 'Del' }),
            new_item('&Select All', 'select_all'),
            new_item('Begin/End &Select', 'begin_select'),
            new_item('Begin/End Select in Column Mode', 'begin_select_col'),
            new_item('E&xpand Selection', 'expand_selection'),
            new_item('Shrin&k Selection', 'shrink_selection'),
            separator,
            new_submenu('Multi-select All', multi_select_items('multi_select_all_')),
            new_submenu('Multi-select Next', function()
                local items = multi_select_items('multi_select_next_')
                items[#items + 1] = separator
                items[#items + 1] = new_item('&Undo the Latest Added Multi-Select', 'multi_select_undo')
                items[#items + 1] = new_item('&Skip Current && Go to Next Multi-Select', 'multi_select_skip')
                return items
            end),
            new_item('Column Mode to Carets', 'column_to_carets'),
            separator,
            new_submenu('Insert', {
                new_item('Date Time (short)', function()
                    editing_commands().insert_date('short')
                end),
                new_item('Date Time (long)', function()
                    editing_commands().insert_date('long')
                end),
                new_item('Date Time (customized)', function()
                    editing_commands().insert_date('custom')
                end),
            }),
            new_submenu('Cop&y to Clipboard', {
                new_item('Copy Current Full File path', function()
                    require('notebashpp.clipboard').set({ api.nvim_buf_get_name(0) }, 'v')
                end),
                new_item('Copy Current Filename', function()
                    require('notebashpp.clipboard').set({ vim.fs.basename(api.nvim_buf_get_name(0)) }, 'v')
                end),
                new_item('Copy Current Dir. Path', function()
                    require('notebashpp.clipboard').set({ vim.fs.dirname(api.nvim_buf_get_name(0)) }, 'v')
                end),
            }),
            new_submenu('&Indent', {
                new_item('Increase Line Indent', function()
                    editing_commands().tab()
                end, { shortcut = 'Tab' }),
                new_item('Decrease Line Indent', function()
                    editing_commands().backtab()
                end, { shortcut = 'Shift+Tab' }),
            }),
            new_submenu('Con&vert Case to', {
                new_item('&UPPERCASE', 'upper'),
                new_item('&lowercase', 'lower'),
                new_item('&Proper Case', 'proper'),
                new_item('Proper Case (blend)', 'proper_blend'),
                new_item('&Sentence case', 'sentence'),
                new_item('Sentence case (blend)', 'sentence_blend'),
                new_item('&iNVERT cASE', 'invert'),
                new_item('&ranDOm CasE', 'random'),
            }),
            new_submenu('&Line Operations', {
                new_item('Duplicate Current Line', 'duplicate'),
                new_item('Remove Duplicate Lines', function()
                    editing_commands().remove_duplicates(false)
                end),
                new_item('Remove Consecutive Duplicate Lines', function()
                    editing_commands().remove_duplicates(true)
                end),
                new_item('Split Lines', 'split_lines'),
                new_item('Join Lines', 'join_lines'),
                new_item('Move Up Current Line', 'line_up'),
                new_item('Move Down Current Line', 'line_down'),
                new_item('Transpose Current and Previous Lines', 'transpose'),
                new_item('Delete Current Line', 'line_delete'),
                new_item('Cut Current Line', 'line_cut'),
                new_item('Remove Empty Lines', function()
                    editing_commands().remove_empty(false)
                end),
                new_item('Remove Empty Lines (Containing Blank characters)', function()
                    editing_commands().remove_empty(true)
                end),
                new_item('Insert Blank Line Above Current', 'blank_above'),
                new_item('Insert Blank Line Below Current', 'blank_below'),
                separator,
                new_item('Sort Lines Lexicographically Ascending', function()
                    editing_commands().sort('lex', false)
                end),
                new_item('Sort Lines Lex. Ascending Ignoring Case', function()
                    editing_commands().sort('lexi', false)
                end),
                new_item('Sort Lines As Integers Ascending', function()
                    editing_commands().sort('int', false)
                end),
                new_item('Sort Lines As Decimals (Comma) Ascending', function()
                    editing_commands().sort('dec_comma', false)
                end),
                new_item('Sort Lines As Decimals (Dot) Ascending', function()
                    editing_commands().sort('dec_dot', false)
                end),
                new_item('Sort Lines Lexicographically Descending', function()
                    editing_commands().sort('lex', true)
                end),
                new_item('Sort Lines Lex. Descending Ignoring Case', function()
                    editing_commands().sort('lexi', true)
                end),
                new_item('Sort Lines As Integers Descending', function()
                    editing_commands().sort('int', true)
                end),
                new_item('Sort Lines As Decimals (Comma) Descending', function()
                    editing_commands().sort('dec_comma', true)
                end),
                new_item('Sort Lines As Decimals (Dot) Descending', function()
                    editing_commands().sort('dec_dot', true)
                end),
                new_item('Reverse Line Order', function()
                    editing_commands().reverse_lines()
                end),
                new_item('Randomize Line Order', function()
                    editing_commands().randomize_lines()
                end),
            }),
            new_submenu('Co&mment/Uncomment', {
                new_item('Toggle Single Line Comment', 'comment_toggle'),
                new_item('Single Line Comment', 'comment'),
                new_item('Single Line Uncomment', 'uncomment'),
                new_item('Block Comment', 'stream_comment'),
                new_item('Block Uncomment', 'stream_uncomment'),
            }),
            new_submenu('&Auto-Completion', {
                new_item('Function Completion', 'autocomplete'),
                new_item('Word Completion', 'autocomplete_word'),
                new_item('Function Parameters Hint', 'calltip'),
                new_item('Path Completion', 'autocomplete_path'),
            }),
            new_submenu('&EOL Conversion', {
                new_item('Windows (CR LF)', function()
                    editing_commands().set_eol('dos')
                end),
                new_item('Unix (LF)', function()
                    editing_commands().set_eol('unix')
                end),
                new_item('Macintosh (CR)', function()
                    editing_commands().set_eol('mac')
                end),
            }),
            new_submenu('&Blank Operations', {
                new_item('Trim Trailing Space', 'trim_trailing'),
                new_item('Trim Leading Space', 'trim_leading'),
                new_item('Trim Leading and Trailing Space', 'trim_both'),
                new_item('EOL to Space', 'eol_to_space'),
                new_item('TAB to Space', 'tab_to_space'),
                new_item('Space to TAB (All)', 'space_to_tab_all'),
                new_item('Space to TAB (Leading)', 'space_to_tab_leading'),
            }),
            new_submenu('&On Selection', {
                new_item('Open File', function()
                    require('notebashpp.file_commands').open_path(helpers.selected_text_or_word_at_caret())
                end),
                -- percent-encode every non-letter, non-digit byte as %xx so
                -- the search engine gets the question intact. i want
                -- absolutely no confusion about which failure i'm trying to
                -- blame on software.
                new_item('Search on Internet', function()
                    require('notebashpp.run_commands').open_url(
                        'https://www.google.com/search?q='
                            .. helpers.selected_text_or_word_at_caret():gsub('[^%w]', function(character)
                                return ('%%%02X'):format(character:byte())
                            end)
                    )
                end),
            }),
            separator,
            new_item('Column &Editor...', 'column_editor'),
            separator,
            new_item('Text Direction RTL', 'rtl'),
            new_item('Text Direction LTR', 'ltr'),
        },
    },
    {
        name = 'search',
        title = '&Search',
        items = {
            new_item('&Find...', 'find'),
            new_item('Find in Fi&les...', 'find_in_files'),
            new_item('Find &Next', 'find_next'),
            new_item('Find &Previous', 'find_prev'),
            new_item('Select and Find Next', 'set_find_next'),
            new_item('Select and Find Previous', 'set_find_prev'),
            new_item('Find (Volatile) Next', 'volatile_next'),
            new_item('Find (Volatile) Previous', 'volatile_prev'),
            new_item('&Replace...', 'replace'),
            new_item('&Incremental Search', 'incremental'),
            new_item('Searc&h Results Window', 'focus_results'),
            new_item('Next Search Result', 'next_result'),
            new_item('Previous Search Result', 'prev_result'),
            new_item('&Go to...', 'goto_line'),
            new_item('Go to &Matching Brace', 'goto_brace'),
            new_item('Select All In-between {} [] or ()', 'select_braces'),
            new_item('Mar&k...', 'mark'),
            separator,
            new_submenu('Style &All Occurrences of Token', style_menu('style_all')),
            new_submenu('Style &One Token', style_menu('style_one')),
            new_submenu('Clear Style', {
                new_item('Clear &1st Style', 'style_clear1'),
                new_item('Clear &2nd Style', 'style_clear2'),
                new_item('Clear &3rd Style', 'style_clear3'),
                new_item('Clear &4th Style', 'style_clear4'),
                new_item('Clear &5th Style', 'style_clear5'),
                new_item('Clear &all Styles', 'style_clear_all'),
            }),
            new_submenu('&Jump Up', {
                new_item('&1st Style', 'style_prev1'),
                new_item('&2nd Style', 'style_prev2'),
                new_item('&3rd Style', 'style_prev3'),
                new_item('&4th Style', 'style_prev4'),
                new_item('&5th Style', 'style_prev5'),
                new_item('Find Mark Style', 'style_prev0'),
            }),
            new_submenu('Jump &Down', {
                new_item('&1st Style', 'style_next1'),
                new_item('&2nd Style', 'style_next2'),
                new_item('&3rd Style', 'style_next3'),
                new_item('&4th Style', 'style_next4'),
                new_item('&5th Style', 'style_next5'),
                new_item('Find Mark Style', 'style_next0'),
            }),
            new_submenu('&Copy Styled Text', {
                new_item('&1st Style', 'style_copy1'),
                new_item('&2nd Style', 'style_copy2'),
                new_item('&3rd Style', 'style_copy3'),
                new_item('&4th Style', 'style_copy4'),
                new_item('&5th Style', 'style_copy5'),
                new_item('All Styles', 'style_copy_all'),
            }),
            separator,
            new_submenu('&Bookmark', {
                new_item('Toggle Bookmark', 'bookmark_toggle'),
                new_item('Next Bookmark', 'bookmark_next'),
                new_item('Previous Bookmark', 'bookmark_prev'),
                new_item('Clear All Bookmarks', 'bookmark_clear'),
                new_item('Cut Bookmarked Lines', 'bookmark_cut'),
                new_item('Copy Bookmarked Lines', 'bookmark_copy'),
                new_item('Paste to (Replace) Bookmarked Lines', 'bookmark_paste'),
                new_item('Remove Bookmarked Lines', 'bookmark_remove'),
                new_item('Remove Non-Bookmarked Lines', 'bookmark_remove_unmarked'),
                new_item('Inverse Bookmark', 'bookmark_inverse'),
            }),
        },
    },
    {
        name = 'view',
        title = '&View',
        items = {
            new_item('Toggle Full Screen Mode', 'fullscreen'),
            new_item('Post-It', 'postit'),
            separator,
            new_submenu('Show Symbol', {
                new_item('Show All Characters', 'show_all_chars', {
                    checked = function()
                        return require('notebashpp.view_settings').get('show_all_characters')
                    end,
                }),
            }),
            new_submenu('Zoom', { new_item('Zoom &In', 'zoom_in'), new_item('Zoom &Out', 'zoom_out'), new_item('Restore Default Zoom', 'zoom_restore') }),
            new_submenu('Move/Clone Current Document', { new_item('Move to Other View', 'move_view'), new_item('Clone to Other View', 'clone_view') }),
            new_submenu('Tab', {
                new_item('1st Tab', 'tab1'),
                new_item('2nd Tab', 'tab2'),
                new_item('3rd Tab', 'tab3'),
                new_item('4th Tab', 'tab4'),
                new_item('5th Tab', 'tab5'),
                new_item('6th Tab', 'tab6'),
                new_item('7th Tab', 'tab7'),
                new_item('8th Tab', 'tab8'),
                new_item('9th Tab', 'tab9'),
                new_item('Next Tab', 'tab_next'),
                new_item('Previous Tab', 'tab_prev'),
                new_item('Move Tab Forward', 'tab_move_fwd'),
                new_item('Move Tab Backward', 'tab_move_back'),
            }),
            new_item('Word wrap', 'word_wrap', {
                checked = function()
                    return require('notebashpp.view_settings').get('word_wrap')
                end,
            }),
            new_item('Focus on Another View', 'switch_view'),
            new_item('Hide Lines', 'hide_lines'),
            separator,
            new_item('Fold All', 'fold_all'),
            new_item('Unfold All', 'unfold_all'),
            new_item('Fold Current Level', 'fold_current'),
            new_item('Unfold Current Level', 'unfold_current'),
            new_submenu('Fold Level', {
                new_item('&1', 'fold1'),
                new_item('&2', 'fold2'),
                new_item('&3', 'fold3'),
                new_item('&4', 'fold4'),
                new_item('&5', 'fold5'),
                new_item('&6', 'fold6'),
                new_item('&7', 'fold7'),
                new_item('&8', 'fold8'),
            }),
            new_submenu('Unfold Level', {
                new_item('&1', 'unfold1'),
                new_item('&2', 'unfold2'),
                new_item('&3', 'unfold3'),
                new_item('&4', 'unfold4'),
                new_item('&5', 'unfold5'),
                new_item('&6', 'unfold6'),
                new_item('&7', 'unfold7'),
                new_item('&8', 'unfold8'),
            }),
        },
    },
    -- the top five set encoding for the next save; character sets reread
    -- disk. "ansi" means cp1252 here, as on a western windows box, nowhere
    -- else on earth. a local assumption with global confidence. sounds like
    -- my career.
    {
        name = 'encoding',
        title = 'E&ncoding',
        items = {
            new_item('ANSI', set_encoding('cp1252', false)),
            new_item('UTF-8', set_encoding('utf-8', false)),
            new_item('UTF-8-BOM', set_encoding('utf-8', true)),
            new_item('UTF-16 BE BOM', set_encoding('utf-16', true)),
            new_item('UTF-16 LE BOM', set_encoding('utf-16le', true)),
            separator,
            new_submenu('Character Set', {
                new_item('Hebrew (Windows-1255)', reopen_with_encoding('cp1255')),
                new_item('Hebrew (ISO 8859-8)', reopen_with_encoding('iso-8859-8')),
                new_item('Arabic (Windows-1256)', reopen_with_encoding('cp1256')),
                new_item('Western European (Windows-1252)', reopen_with_encoding('cp1252')),
                new_item('Cyrillic (Windows-1251)', reopen_with_encoding('cp1251')),
            }),
            separator,
            new_item('Convert to ANSI', set_encoding('cp1252', false)),
            new_item('Convert to UTF-8', set_encoding('utf-8', false)),
            new_item('Convert to UTF-8-BOM', set_encoding('utf-8', true)),
            new_item('Convert to UTF-16 BE BOM', set_encoding('utf-16', true)),
            new_item('Convert to UTF-16 LE BOM', set_encoding('utf-16le', true)),
        },
    },
    { name = 'language', title = '&Language', items = language_list },
    -- notepad++ has dialogs here. we have files you open, read and change,
    -- like everybody configured everything before the world got nice.
    -- (assuming that happened. i may have been editing a file.)
    {
        name = 'settings',
        title = 'Se&ttings',
        items = {
            new_item('&Preferences... (open the Notebash++ options file)', function()
                require('notebashpp.file_commands').open_path(require('notebashpp').root .. '/lua/notebashpp/editor_options.lua')
            end),
            new_item('Style &Configurator... (open the colours file)', function()
                require('notebashpp.file_commands').open_path(require('notebashpp').root .. '/lua/notebashpp/appearance.lua')
            end),
            new_item('Shortcut &Mapper... (show every key)', function()
                require('notebashpp.file_commands').open_path(require('notebashpp').root .. '/KEYS.md')
            end),
            separator,
            new_item('&Dark Mode', 'dark_mode', {
                checked = function()
                    return require('notebashpp.appearance').dark_mode()
                end,
            }),
            separator,
            new_item('Neovim &command line...', function()
                vim.api.nvim_feedkeys(':', 'n', false)
            end),
        },
    },
    {
        name = 'tools',
        title = 'To&ols',
        items = {
            new_submenu('MD5', { new_item('Generate from selection into clipboard', hash('md5')) }),
            new_submenu('SHA-256', { new_item('Generate from selection into clipboard', hash('sha256')) }),
        },
    },
    { name = 'macro', title = '&Macro', items = macro_list },
    {
        name = 'run',
        title = '&Run',
        items = {
            new_item('&Run...', 'run'),
            separator,
            new_item('Get PHP help', 'php_help'),
            new_item('Wikipedia Search', 'wikipedia'),
            new_item('Open selected file path in new instance', 'new_instance'),
        },
    },
    -- the most installed notepad++ plugins, rebuilt by hand and sorted by
    -- name, the way notepad++ does it. i could have spent this part of my
    -- life outside.
    {
        name = 'plugins',
        title = '&Plugins',
        items = {
            new_submenu('Code &Alignment', {
                new_item('Align by &Equals', 'align_equals'),
                new_item('Align by &Colon', 'align_colon'),
                new_item('Align by &Text...', 'align_text'),
            }),
            new_submenu('&Compare', {
                new_item('Set as First to Compare', 'cmp_first'),
                new_item('Compare', 'cmp_compare'),
                new_item('Compare Selections', 'cmp_selections'),
                new_item('Find Unique Lines', 'cmp_unique'),
                new_item('Find Unique Lines in Selections', 'cmp_unique_sel'),
                separator,
                new_item('Diff since last Save', 'cmp_last_save'),
                new_item('Compare file/selection to Clipboard', 'cmp_clipboard'),
                new_item('SVN Diff', 'cmp_svn'),
                new_item('Git Diff', 'cmp_git'),
                separator,
                new_item('Clear Active Compare', 'cmp_clear'),
                separator,
                new_item('First', 'cmp_first_diff'),
                new_item('Previous', 'cmp_prev'),
                new_item('Next', 'cmp_next'),
                new_item('Last', 'cmp_last_diff'),
            }),
            new_submenu('&HEX-Editor', {
                new_item('View in &HEX', 'hex_view'),
            }),
            new_submenu('&JSON', {
                new_item('&Format JSON', 'json_format'),
                new_item('&Minify JSON', 'json_minify'),
                new_item('&Check JSON', 'json_check'),
                separator,
                new_item('Show JSON &Tree', 'json_tree', {
                    checked = function()
                        local json_tree = package.loaded['notebashpp.json_tree']
                        return json_tree ~= nil and json_tree.is_open()
                    end,
                }),
                new_item('Copy JSON &Path', 'json_copy_path'),
            }),
            -- the first line lists servers running for the document this menu
            -- came from; choose it to see their programs and folders.
            -- basically a staff directory for the bastards ignoring me.
            new_submenu('&Language Server', function()
                local language_servers = require('notebashpp.language_servers')
                return {
                    new_item(language_servers.status_line(menu_bar.origin_buf), function()
                        language_servers.show_status(menu_bar.origin_buf)
                    end),
                    separator,
                    new_item('Go to &Definition', 'lsp_definition'),
                    new_item('Find &References', 'lsp_references'),
                    new_item('Show D&ocumentation', 'lsp_hover'),
                    new_item('Re&name Symbol...', 'lsp_rename'),
                    new_item('&Format Document', 'lsp_format'),
                    separator,
                    new_item('Ne&xt Problem', 'lsp_next_problem'),
                    new_item('&Previous Problem', 'lsp_prev_problem'),
                    new_item('Problem De&tails', 'lsp_problem_details'),
                    separator,
                    new_item('&Look for Language Servers Again', 'lsp_look_again'),
                    new_item('Trust This Fold&er...', 'lsp_trust_folder'),
                    new_item('Stop Trusting &All Folders', 'lsp_forget_trusted_folders'),
                }
            end),
            new_submenu('&Spell Check', {
                new_item('&Spell Check Document', 'spell_check', {
                    checked = function()
                        return require('notebashpp.view_settings').get('spell_check')
                    end,
                }),
                new_item('Find &Next Misspelling', 'spell_next'),
                new_item('Find &Previous Misspelling', 'spell_prev'),
                new_item('&Add Word to Dictionary', 'spell_add'),
            }),
            new_submenu('Sprea&dsheet', {
                new_item('&Open as Spreadsheet / View as Text', 'sheet_toggle'),
                new_item('First Row Is the &Header', 'sheet_header', {
                    checked = function()
                        local state = require('notebashpp.spreadsheet_view').current_state()
                        return state ~= nil and state.header_ref ~= nil
                    end,
                }),
                separator,
                new_item('&Edit Cell', 'sheet_edit_cell'),
                new_item('&Go to Row...', 'sheet_go_to_row'),
                separator,
                new_item('Insert Row &Above', 'sheet_row_above'),
                new_item('Insert Row &Below', 'sheet_row_below'),
                new_item('D&uplicate Rows', 'sheet_row_duplicate'),
                new_item('&Delete Rows', 'sheet_row_delete'),
                new_item('Move Rows U&p', 'sheet_row_up'),
                new_item('Move Rows Dow&n', 'sheet_row_down'),
                separator,
                new_item('Insert Column &Left', 'sheet_column_left'),
                new_item('Insert Column &Right', 'sheet_column_right'),
                new_item('Delete &Columns', 'sheet_column_delete'),
                new_item('&Widen Column', 'sheet_column_wider'),
                new_item('Narro&w Column', 'sheet_column_narrower'),
            }),
            new_submenu('&XML Tools', {
                new_item('&Pretty Print', 'xml_format'),
                new_item('&Linearize XML', 'xml_linearize'),
                new_item('&Check XML Syntax', 'xml_check'),
            }),
        },
    },
    { name = 'window', title = '&Window', items = window_list },
    {
        name = 'help',
        title = '&?',
        items = {
            new_item('Shortcut list (KEYS.md)', function()
                require('notebashpp.file_commands').open_path(require('notebashpp').root .. '/KEYS.md')
            end),
            new_item('&What does this key do?', 'key_help'),
            new_item('Message &log', 'message_log'),
            separator,
            new_item('&About Notebash++', 'about'),
        },
    },
}

------------------------------------------------------------- rendering

-- split "save &as..." into visible "save as...", the lowercase accelerator
-- letter and its byte offset. "&&" gives a plain "&", as in windows menus.
-- one ampersand gets a purpose in life. i spent my evening arranging this and
-- will die with absolutely no transferable skills (except removing myself
-- from menus, apparently).
local function split_accelerator(label)
    local plain_parts, accelerator_key, accelerator_position = {}, nil, nil
    local byte_index = 1
    while byte_index <= #label do
        local character = label:sub(byte_index, byte_index)
        if character == '&' and byte_index < #label then
            local next_character = label:sub(byte_index + 1, byte_index + 1)
            if next_character ~= '&' and not accelerator_key then
                accelerator_key = next_character:lower()
                accelerator_position = #table.concat(plain_parts)
            end
            plain_parts[#plain_parts + 1] = next_character
            byte_index = byte_index + 2
        else
            plain_parts[#plain_parts + 1] = character
            byte_index = byte_index + 1
        end
    end
    return table.concat(plain_parts), accelerator_key, accelerator_position
end

-- top menus keep their list in items; submenus use sub. either may be a
-- function, called now: recent files, window and macro need current contents.
-- basically they only know what they're doing when watched. i relate.
local function items_of(menu_or_item)
    local items = menu_or_item.items or menu_or_item.sub
    if type(items) == 'function' then
        items = items()
    end
    return items
end

-- right-side key hint: explicit shortcut wins, then keybindings.lua's key for
-- the command id, then nothing. even absence has a fallback policy.
local function shortcut_of(menu_item)
    if menu_item.shortcut then
        return menu_item.shortcut
    end
    if menu_item.id then
        return keybindings_module().shortcut(menu_item.id)
    end
    return ''
end

-- open menus form a stack: [1] is the top menu, [2] its submenu, and so on.
-- back out one level at a time. i want this for life, please. i have a few
-- decisions from years ago that are still opening submenus.
menu_bar.open_levels = {}

local menu_namespace = api.nvim_create_namespace('notebashpp_menu')

-- draw the bar in the tabline. each title is a click region calling
-- notebashmenuclick with its index; highlight the open title separately.
-- show "recording" on the right while recording a macro. on narrow screens,
-- these menus leave the bar first, but their alt keys still open them.
-- basically hiding the evidence without fixing a damn thing. i know how.
local MENUS_HIDDEN_WHEN_NARROW = { plugins = true, window = true }
local PRODUCT_TITLE = ' Notebash++ '

-- calculate which titles fit and their starting columns. the full bar is
-- about 95 columns; terminals are often 80 because a punch card had 80
-- columns in 1971. apparently the dead still set our furniture dimensions.
-- first drop the product name, then shrink padding to one space, then hide
-- the least-used menus. i want less history in my fucking terminal.
local function bar_layout()
    local available_width = vim.o.columns
    local function measure(padding, skip_hidden)
        local entries, column = {}, 0
        for menu_index, menu in ipairs(menu_bar.MENUS) do
            if not (skip_hidden and MENUS_HIDDEN_WHEN_NARROW[menu.name]) then
                local title_text = split_accelerator(menu.title)
                entries[#entries + 1] = { menu_index = menu_index, name = menu.name, title = title_text, column = column }
                column = column + vim.fn.strdisplaywidth(title_text) + 2 * padding
            end
        end
        return entries, column
    end
    for _, attempt in ipairs({ { 1, false, true }, { 1, false, false }, { 0.5, false, false }, { 0.5, true, false } }) do
        local padding, skip_hidden, with_title = attempt[1], attempt[2], attempt[3]
        local entries, width = measure(padding, skip_hidden)
        if width + (with_title and #PRODUCT_TITLE or 0) <= available_width then
            return entries, padding, with_title
        end
    end
    local entries = measure(0.5, true)
    return entries, 0.5, false
end

function menu_bar.bar()
    local open_menu_name = menu_bar.open_levels[1] and menu_bar.open_levels[1].name
    local entries, padding, with_title = bar_layout()
    local segments = {}
    for _, entry in ipairs(entries) do
        local highlight_group = entry.name == open_menu_name and 'NotebashMenuBarOpen' or 'NotebashMenuBar'
        -- half padding: one space after the title, none before. rent went up.
        local left_space = padding == 1 and ' ' or ''
        segments[#segments + 1] = ('%%#%s#%%%d@v:lua.NotebashMenuClick@%s%s %%X'):format(highlight_group, entry.menu_index, left_space, entry.title)
    end
    local recording_badge = require('notebashpp.macros').recording() and '%#ErrorMsg# Recording %#NotebashMenuBar#' or ''
    return table.concat(segments) .. '%#NotebashMenuBar#%=' .. recording_badge .. (with_title and PRODUCT_TITLE or '')
end

-- click a title to open its menu, or close it if already open, like windows.
-- schedule it because neovim can't open windows during a tabline click
-- handler. i need an appointment to open a damn menu. my time is worthless.
-- selene: allow(global_usage)
_G.NotebashMenuClick = function(menu_index)
    vim.schedule(function()
        local menu = menu_bar.MENUS[menu_index]
        if menu then
            if menu_bar.open_levels[1] and menu_bar.open_levels[1].name == menu.name then
                menu_bar.close_all()
            else
                menu_bar.open(menu.name)
            end
        end
    end)
end

-- a title's screen column sums preceding title widths and their side spaces.
-- open the dropdown there, under its own name. i can locate a menu more
-- reliably than i can locate where the hell my evening went.
local function bar_column_of(menu_name)
    local entries = bar_layout()
    for _, entry in ipairs(entries) do
        if entry.name == menu_name then
            return entry.column
        end
    end
    -- menus hidden by a narrow bar open at the left edge. even failure needs
    -- a forwarding address.
    return 0
end

-- start at start_index, walk direction (1 down, -1 up), wrapping round.
-- return the first enabled non-separator; if none exist, return start_index.
-- a full search ending exactly where i started. absolutely my life's work.
local function first_enabled(items, start_index, direction)
    local item_count = #items
    local index = start_index
    for _ = 1, item_count do
        local menu_item = items[index]
        if menu_item and not menu_item.sep and not menu_item.disabled then
            return index
        end
        index = (index - 1 + direction) % item_count + 1
    end
    return start_index
end

-- draw one level in its float: check column, label, then a right-aligned
-- shortcut or + for a submenu. extmarks highlight accelerator letters,
-- disabled items and hints. create the window once, move it afterward. a
-- windows menu built from a text buffer. i used to have potential; now i have
-- very specific opinions about where the little plus goes.
local function draw_level(level)
    local menu_level = menu_bar.open_levels[level]
    local buffer_lines = {}
    local width = 10
    local rows = {}
    for row_index, menu_item in ipairs(menu_level.items) do
        if menu_item.sep then
            rows[row_index] = { sep = true }
        else
            local label_text, accelerator_key, accelerator_offset = split_accelerator(menu_item.label)
            local shortcut_text = shortcut_of(menu_item)
            rows[row_index] = {
                text = label_text,
                accelerator_key = accelerator_key,
                accelerator_offset = accelerator_offset,
                shortcut = shortcut_text,
                sub = menu_item.sub ~= nil,
                checked = type(menu_item.checked) == 'function' and menu_item.checked() or menu_item.checked == true,
            }
            -- left margin: 3 spaces, then the label, at least 4 spaces before
            -- the shortcut or submenu mark, then 2 to the edge. even crap
            -- needs boundaries.
            local right_width = menu_item.sub and 1 or vim.fn.strdisplaywidth(shortcut_text)
            width = math.max(width, 3 + vim.fn.strdisplaywidth(label_text) + (right_width > 0 and 4 + right_width or 0) + 2)
        end
    end
    for row_index, row in ipairs(rows) do
        if row.sep then
            buffer_lines[row_index] = string.rep('─', width)
        else
            local left_part = (row.checked and ' ✓ ' or '   ') .. row.text
            local right_part = row.sub and '+ ' or (row.shortcut ~= '' and (row.shortcut .. '  ') or '')
            local padding = width - vim.fn.strdisplaywidth(left_part) - vim.fn.strdisplaywidth(right_part)
            buffer_lines[row_index] = left_part .. string.rep(' ', math.max(1, padding)) .. right_part
        end
    end
    vim.bo[menu_level.buffer].modifiable = true
    api.nvim_buf_set_lines(menu_level.buffer, 0, -1, false, buffer_lines)
    vim.bo[menu_level.buffer].modifiable = false
    api.nvim_buf_clear_namespace(menu_level.buffer, menu_namespace, 0, -1)
    for row_index, row in ipairs(rows) do
        if row.sep then
            api.nvim_buf_set_extmark(menu_level.buffer, menu_namespace, row_index - 1, 0, { line_hl_group = 'NotebashMenuSep' })
        else
            local menu_item = menu_level.items[row_index]
            if menu_item.disabled then
                api.nvim_buf_set_extmark(menu_level.buffer, menu_namespace, row_index - 1, 0, { line_hl_group = 'NotebashMenuOff' })
            end
            -- accelerator underline stand-in uses byte offsets. measure the
            -- letter with strcharpart in case utf-8 needs multiple bytes.
            -- even one letter has baggage. fine, so do i.
            if row.accelerator_offset then
                local text_before_key = (row.checked and ' ✓ ' or '   ') .. row.text:sub(1, row.accelerator_offset)
                local key_byte_column = #text_before_key
                local accelerator_character = vim.fn.strcharpart(row.text:sub(row.accelerator_offset + 1), 0, 1)
                api.nvim_buf_set_extmark(
                    menu_level.buffer,
                    menu_namespace,
                    row_index - 1,
                    key_byte_column,
                    { end_col = key_byte_column + #accelerator_character, hl_group = 'NotebashMenuKey', priority = 200 }
                )
            end
            -- shortcut hint: two spaces from the right edge. let it breathe.
            if row.shortcut ~= '' then
                local line_text = buffer_lines[row_index]
                local shortcut_column = #line_text - #row.shortcut - 2
                api.nvim_buf_set_extmark(
                    menu_level.buffer,
                    menu_namespace,
                    row_index - 1,
                    shortcut_column,
                    { end_col = shortcut_column + #row.shortcut, hl_group = 'NotebashMenuHint', priority = 150 }
                )
            end
        end
    end
    menu_level.width = width
    -- keep it on screen: push left at the right edge, shorten at the bottom.
    -- each level gets one zindex above its parent. if a submenu has no room
    -- on the right, open on the parent's left, like windows, rather than
    -- cover the parent and eat its shortcuts. i want to see my bad choices
    -- before making additional ones. apparently this requires geometry.
    local column = menu_level.column
    local parent_level = menu_bar.open_levels[level - 1]
    if parent_level and column + width + 2 > vim.o.columns and parent_level.window and api.nvim_win_is_valid(parent_level.window) then
        local parent_column = api.nvim_win_get_config(parent_level.window).col
        if type(parent_column) == 'number' and parent_column - width - 2 >= 0 then
            column = parent_column - width - 2
        end
    end
    local window_config = {
        relative = 'editor',
        row = menu_level.row,
        col = math.max(0, math.min(column, vim.o.columns - width - 2)),
        width = width,
        height = math.max(1, math.min(#buffer_lines, vim.o.lines - menu_level.row - 3)),
        style = 'minimal',
        border = 'single',
        zindex = 200 + level,
    }
    -- a menu taller than the screen scrolls. say so in its bottom border.
    -- otherwise anything below the edge is dead to us. basically my inbox.
    if #buffer_lines > window_config.height then
        window_config.footer = { { ' more ', 'NotebashMenuHint' } }
        window_config.footer_pos = 'center'
    end
    if menu_level.window and api.nvim_win_is_valid(menu_level.window) then
        api.nvim_win_set_config(menu_level.window, window_config)
    else
        menu_level.window = api.nvim_open_win(menu_level.buffer, true, window_config)
        vim.wo[menu_level.window].winhighlight = 'Normal:NotebashMenu,NormalFloat:NotebashMenu,FloatBorder:NotebashMenuSep,CursorLine:NotebashMenuSel'
        vim.wo[menu_level.window].cursorline = true
        vim.wo[menu_level.window].winbar = ''
    end
    api.nvim_win_set_cursor(menu_level.window, { menu_level.selected_row, 0 })
    vim.cmd('redrawtabline')
end

-- close this level and every deeper submenu, deepest first. bury properly.
local function close_from_level(level)
    while #menu_bar.open_levels >= level do
        local menu_level = table.remove(menu_bar.open_levels)
        if menu_level.window and api.nvim_win_is_valid(menu_level.window) then
            api.nvim_win_close(menu_level.window, true)
        end
    end
    vim.cmd('redrawtabline')
end

-- return focus and caret to the window used before opening the menu. pcall
-- handles the old caret position no longer existing. i want to go back too,
-- but apparently the place i remember has been demolished.
local function back_to_origin()
    local origin = menu_bar.origin
    if origin and api.nvim_win_is_valid(origin.window) then
        api.nvim_set_current_win(origin.window)
        pcall(api.nvim_win_set_cursor, origin.window, origin.caret)
    end
end

-- close every menu without running anything; restore the opening selection.
-- basically a wasted visit with a full refund. i'd love more of those.
function menu_bar.close_all()
    close_from_level(1)
    back_to_origin()
    local selection = menu_bar.origin and menu_bar.origin.selection
    if selection then
        helpers.select_range({ selection.start_line, selection.start_col }, { selection.end_line, selection.end_col })
    end
    menu_bar.origin = nil
end

-- chosen item waits for _pending() until the old-state restoration keys have
-- run. even my commands spend their lives waiting for this crap.
menu_bar.pending_item = nil

-- live reload calls this before discarding the module: close open menus so
-- orphaned floats don't outlive their code. my work needs an actual funeral.
function menu_bar._unload()
    if #menu_bar.open_levels > 0 then
        menu_bar.close_all()
    end
end

-- run the pending item once; functions get one undo step. called by the <cmd>
-- mapping execute_item() feeds. i want my mistakes this reversible.
function menu_bar._pending()
    local menu_item = menu_bar.pending_item
    menu_bar.pending_item = nil
    if not menu_item then
        return
    end
    if menu_item.id then
        keybindings_module().run(menu_item.id)
    elseif menu_item.fn then
        helpers.run_as_one_undo_step(menu_item.fn)
    end
end

-- run an item like its shortcut: close menus, return to the document, restore
-- the selection (or enter insert mode), then run the command. feedkeys keeps
-- all this in order and in the right mode. i spent actual life teaching
-- software to return from a fucking menu without damage.
local function execute_item(menu_item)
    if menu_item.disabled or menu_item.sep then
        return
    end
    local origin = menu_bar.origin
    close_from_level(1)
    back_to_origin()
    menu_bar.origin = nil
    menu_bar.pending_item = menu_item
    local key_prefix = ''
    if origin and origin.selection then
        key_prefix = helpers.keys_to_select_range(
            { origin.selection.start_line, origin.selection.start_col },
            { origin.selection.end_line, origin.selection.end_col }
        )
    elseif helpers.is_editable_buffer() and vim.fn.mode() == 'n' then
        key_prefix = 'i'
    end
    helpers.feed_keys(key_prefix .. '<Cmd>lua require("notebashpp.menu_bar")._pending()<CR>')
end

-- open the selected item's submenu right of its parent, level with its row.
-- return false if there's no submenu so the caller runs the item instead.
-- eventually you have to do something. i find that part unpleasant.
local function open_submenu(level)
    local menu_level = menu_bar.open_levels[level]
    local menu_item = menu_level.items[menu_level.selected_row]
    if not menu_item or not menu_item.sub then
        return false
    end
    local items = items_of(menu_item)
    local child_level = {
        items = items,
        selected_row = first_enabled(items, 1, 1),
        row = menu_level.row + menu_level.selected_row,
        column = (api.nvim_win_get_config(menu_level.window).col or menu_level.column) + menu_level.width + 1,
        buffer = menu_bar.new_menu_buffer(),
    }
    menu_bar.open_levels[level + 1] = child_level
    draw_level(level + 1)
    return true
end

-- left or right at the top level switches neighbouring bar menus, wrapping
-- from help back to file. i asked for help and ended up back at work.
-- absolutely convincing simulation of being alive.
local function switch_top_menu(direction)
    local current_name = menu_bar.open_levels[1].name
    for menu_index, menu in ipairs(menu_bar.MENUS) do
        if menu.name == current_name then
            local next_menu = menu_bar.MENUS[(menu_index - 1 + direction) % #menu_bar.MENUS + 1]
            close_from_level(1)
            menu_bar.show(next_menu.name)
            return
        end
    end
end

-- find this buffer's open level, or nil for a non-menu buffer. no belonging.
local function level_of_buffer(buffer)
    for level, menu_level in ipairs(menu_bar.open_levels) do
        if menu_level.buffer == buffer then
            return level
        end
    end
end

-- build one menu key's handler. action says what to do; argument supplies the
-- move step, edge end, key letter or menu name. i need instructions this
-- explicit too, but nobody wants to maintain that bastard.
local function menu_key_handler(action, argument)
    return function()
        local level = level_of_buffer(api.nvim_get_current_buf())
        if not level then
            return
        end
        local menu_level = menu_bar.open_levels[level]
        if action == 'move' then
            menu_level.selected_row = first_enabled(menu_level.items, (menu_level.selected_row - 1 + argument) % #menu_level.items + 1, argument)
            api.nvim_win_set_cursor(menu_level.window, { menu_level.selected_row, 0 })
        elseif action == 'edge' then
            menu_level.selected_row = first_enabled(menu_level.items, argument > 0 and #menu_level.items or 1, -argument)
            api.nvim_win_set_cursor(menu_level.window, { menu_level.selected_row, 0 })
        elseif action == 'enter' then
            if not open_submenu(level) then
                execute_item(menu_level.items[menu_level.selected_row])
            end
        elseif action == 'right' then
            if not open_submenu(level) then
                switch_top_menu(1)
            end
        elseif action == 'left' then
            if level > 1 then
                close_from_level(level)
                api.nvim_set_current_win(menu_bar.open_levels[level - 1].window)
            else
                switch_top_menu(-1)
            end
        elseif action == 'esc' then
            if level > 1 then
                close_from_level(level)
                api.nvim_set_current_win(menu_bar.open_levels[level - 1].window)
            else
                menu_bar.close_all()
            end
        elseif action == 'key' then
            -- windows accelerator rule: a unique letter runs its item
            -- immediately. shared letters cycle matches on each press without
            -- running anything. basically everyone answers and absolutely
            -- nothing gets done. i used to charge consulting fees for
            -- diagnosing that.
            local matching_rows = {}
            for row_index, menu_item in ipairs(menu_level.items) do
                if not menu_item.sep and not menu_item.disabled then
                    local _, accelerator_key = split_accelerator(menu_item.label)
                    if accelerator_key == argument:lower() then
                        matching_rows[#matching_rows + 1] = row_index
                    end
                end
            end
            if #matching_rows == 1 then
                menu_level.selected_row = matching_rows[1]
                api.nvim_win_set_cursor(menu_level.window, { menu_level.selected_row, 0 })
                if not open_submenu(level) then
                    execute_item(menu_level.items[menu_level.selected_row])
                end
            elseif #matching_rows > 1 then
                local next_row = matching_rows[1]
                for _, matching_row in ipairs(matching_rows) do
                    if matching_row > menu_level.selected_row then
                        next_row = matching_row
                        break
                    end
                end
                menu_level.selected_row = next_row
                api.nvim_win_set_cursor(menu_level.window, { menu_level.selected_row, 0 })
            end
        elseif action == 'menu' then
            close_from_level(1)
            menu_bar.show(argument)
        elseif action == 'click' then
            -- click an open level to pick its row and close deeper levels.
            -- click anywhere else to close everything. i'd love to dismiss my
            -- commitments by vaguely pointing away from them.
            local mouse = vim.fn.getmousepos()
            for clicked_level, clicked_menu in ipairs(menu_bar.open_levels) do
                if clicked_menu.window == mouse.winid and mouse.line > 0 then
                    close_from_level(clicked_level + 1)
                    api.nvim_set_current_win(clicked_menu.window)
                    clicked_menu.selected_row = mouse.line
                    local clicked_item = clicked_menu.items[mouse.line]
                    if clicked_item and not clicked_item.sep then
                        if not open_submenu(clicked_level) then
                            execute_item(clicked_item)
                        end
                    end
                    return
                end
            end
            menu_bar.close_all()
        end
    end
end

-- one scratch buffer per level. map every key a windows menu handles in
-- normal and insert mode; swallow typed characters so none enter its text. i
-- built a text editor, then paid with my evening to stop the typing.
function menu_bar.new_menu_buffer()
    local buffer = api.nvim_create_buf(false, true)
    vim.bo[buffer].bufhidden = 'wipe'
    vim.bo[buffer].filetype = 'notebashpp_menu'
    local map_options = { buffer = buffer, nowait = true, silent = true }
    local modes = { 'n', 'i' }
    for _, key in ipairs({ '<Down>', '<kDown>', '<C-n>' }) do
        vim.keymap.set(modes, key, menu_key_handler('move', 1), map_options)
    end
    for _, key in ipairs({ '<Up>', '<kUp>', '<C-p>' }) do
        vim.keymap.set(modes, key, menu_key_handler('move', -1), map_options)
    end
    vim.keymap.set(modes, '<Home>', menu_key_handler('edge', -1), map_options)
    vim.keymap.set(modes, '<End>', menu_key_handler('edge', 1), map_options)
    for _, key in ipairs({ '<CR>', '<kEnter>', '<Space>' }) do
        vim.keymap.set(modes, key, menu_key_handler('enter'), map_options)
    end
    vim.keymap.set(modes, '<Right>', menu_key_handler('right'), map_options)
    vim.keymap.set(modes, '<Left>', menu_key_handler('left'), map_options)
    vim.keymap.set(modes, '<Esc>', menu_key_handler('esc'), map_options)
    -- alt+esc and f10 close the whole menu at any depth. i want an exit this
    -- reliable for my other poor choices.
    vim.keymap.set(modes, '<M-Esc>', function()
        menu_bar.close_all()
    end, map_options)
    vim.keymap.set(modes, '<F10>', function()
        menu_bar.close_all()
    end, map_options)
    vim.keymap.set(modes, '<LeftMouse>', menu_key_handler('click'), map_options)
    local printable = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789?.-'
    for character in printable:gmatch('.') do
        vim.keymap.set(modes, character, menu_key_handler('key', character), map_options)
    end
    -- alt+letter in an open menu jumps to another top menu. fresh
    -- disappointment.
    for _, menu in ipairs(menu_bar.MENUS) do
        local _, accelerator_key = split_accelerator(menu.title)
        vim.keymap.set(modes, '<M-' .. accelerator_key .. '>', menu_key_handler('menu', menu.name), map_options)
    end
    api.nvim_create_autocmd('InsertCharPre', {
        buffer = buffer,
        callback = function()
            vim.v.char = ''
        end,
    })
    -- close the menu when focus goes elsewhere, like windows. even software
    -- leaves when i stop giving it attention. at least this one frees space.
    api.nvim_create_autocmd('WinLeave', {
        buffer = buffer,
        callback = function()
            vim.schedule(function()
                if #menu_bar.open_levels > 0 and not level_of_buffer(api.nvim_get_current_buf()) then
                    close_from_level(1)
                    menu_bar.origin = nil
                end
            end)
        end,
    })
    return buffer
end

-- draw a top menu below its title, first usable item selected. origin must
-- already be saved; use open(). i can't recover a past you never kept.
function menu_bar.show(menu_name)
    for _, menu in ipairs(menu_bar.MENUS) do
        if menu.name == menu_name then
            local items = items_of(menu)
            local menu_level = {
                name = menu_name,
                items = items,
                selected_row = first_enabled(items, 1, 1),
                -- row 0 holds the bar; put the dropdown below so it can't
                -- cover its titles. i want at least one part of my work to
                -- stop burying the evidence.
                row = 1,
                column = bar_column_of(menu_name),
                buffer = menu_bar.new_menu_buffer(),
            }
            menu_bar.open_levels[1] = menu_level
            draw_level(1)
            return
        end
    end
end

-- alt+letter opens from the caret. first save window, caret, selection and
-- buffer so close_all() can restore them. an open menu just swaps menus.
-- floating windows cannot open the bar. i gave them a boundary, which is more
-- than i've managed with this project and my remaining years.
function menu_bar.open(menu_name)
    if #menu_bar.open_levels > 0 then
        close_from_level(1)
        return menu_bar.show(menu_name)
    end
    local window = api.nvim_get_current_win()
    if api.nvim_win_get_config(window).relative ~= '' then
        return
    end
    menu_bar.origin = { window = window, caret = helpers.get_caret(), selection = helpers.get_selection(), buffer = api.nvim_get_current_buf() }
    menu_bar.origin_buf = menu_bar.origin.buffer
    -- with a selection, enter normal mode first so the menu can't inherit
    -- select mode; show it through a <cmd> mapping. inherited crap stops
    -- here, please.
    if helpers.is_selecting() then
        helpers.feed_keys(('<C-\\><C-n><Cmd>lua require("notebashpp.menu_bar").show("%s")<CR>'):format(menu_name))
        return
    end
    menu_bar.show(menu_name)
end

------------------------------------------------------------- right click

-- build the right-click menu from neovim's own popup: clipboard, select, five
-- token styles, comments and hide lines. each uses its key's command id. i
-- want the same mistake available by mouse, for when my hands are too
-- exhausted to express regret on the keyboard.
function menu_bar.setup_popup()
    vim.cmd([[
        silent! aunmenu PopUp
        anoremenu PopUp.Cut <Cmd>lua require("notebashpp.keybindings").run("cut")<CR>
        anoremenu PopUp.Copy <Cmd>lua require("notebashpp.keybindings").run("copy")<CR>
        anoremenu PopUp.Paste <Cmd>lua require("notebashpp.keybindings").run("paste")<CR>
        anoremenu PopUp.Delete <Cmd>lua require("notebashpp.editing_commands").delete_selection()<CR>
        anoremenu PopUp.Select\ All <Cmd>lua require("notebashpp.keybindings").run("select_all")<CR>
        anoremenu PopUp.Begin/End\ Select <Cmd>lua require("notebashpp.keybindings").run("begin_select")<CR>
        anoremenu PopUp.-sep1- <Nop>
        anoremenu PopUp.Style\ all\ occurrences\ of\ token.Using\ 1st\ Style <Cmd>lua require("notebashpp.keybindings").run("style_all1")<CR>
        anoremenu PopUp.Style\ all\ occurrences\ of\ token.Using\ 2nd\ Style <Cmd>lua require("notebashpp.keybindings").run("style_all2")<CR>
        anoremenu PopUp.Style\ all\ occurrences\ of\ token.Using\ 3rd\ Style <Cmd>lua require("notebashpp.keybindings").run("style_all3")<CR>
        anoremenu PopUp.Style\ all\ occurrences\ of\ token.Using\ 4th\ Style <Cmd>lua require("notebashpp.keybindings").run("style_all4")<CR>
        anoremenu PopUp.Style\ all\ occurrences\ of\ token.Using\ 5th\ Style <Cmd>lua require("notebashpp.keybindings").run("style_all5")<CR>
        anoremenu PopUp.Clear\ style.Clear\ all\ Styles <Cmd>lua require("notebashpp.keybindings").run("style_clear_all")<CR>
        anoremenu PopUp.-sep2- <Nop>
        anoremenu PopUp.Toggle\ Single\ Line\ Comment <Cmd>lua require("notebashpp.keybindings").run("comment_toggle")<CR>
        anoremenu PopUp.Block\ Comment <Cmd>lua require("notebashpp.keybindings").run("stream_comment")<CR>
        anoremenu PopUp.Block\ Uncomment <Cmd>lua require("notebashpp.keybindings").run("stream_uncomment")<CR>
        anoremenu PopUp.-sep3- <Nop>
        anoremenu PopUp.Hide\ Lines <Cmd>lua require("notebashpp.keybindings").run("hide_lines")<CR>
    ]])
end

---------------------------------------------------------------- about

-- help > about: centred box with the neovim version and where to find every
-- key. enter, esc, f1, q or space closes it and returns you where you were.
-- five ways out of a box saying my program's name. i do care about your
-- remaining time, despite what this entire project suggests.
function menu_bar.about()
    local version = vim.version()
    local lines = {
        '',
        '  Notebash++',
        '',
        ('  Neovim %d.%d.%d with the keyboard of Notepad++ 8.5.3'):format(version.major, version.minor, version.patch),
        '  (built-in shortcuts, plus your shortcuts.xml and ComparePlus).',
        '',
        '  Every key: Settings > Shortcut Mapper, or KEYS.md in',
        '  ' .. require('notebashpp').root,
        '',
        '  Enter or Esc to close',
        '',
    }
    local width = 0
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
    end
    local buffer = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].modifiable = false
    vim.bo[buffer].bufhidden = 'wipe'
    local origin_window = api.nvim_get_current_win()
    local caret = helpers.get_caret()
    local window = api.nvim_open_win(buffer, true, {
        relative = 'editor',
        row = math.floor((vim.o.lines - #lines) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        width = width,
        height = #lines,
        style = 'minimal',
        border = 'single',
        title = ' About Notebash++ ',
        title_pos = 'center',
        zindex = 250,
    })
    vim.wo[window].winbar = ''
    local function close_about_box()
        if api.nvim_win_is_valid(window) then
            api.nvim_win_close(window, true)
        end
        if api.nvim_win_is_valid(origin_window) then
            api.nvim_set_current_win(origin_window)
            pcall(api.nvim_win_set_cursor, origin_window, caret)
        end
    end
    for _, key in ipairs({ '<Esc>', '<CR>', '<F1>', 'q', '<Space>' }) do
        vim.keymap.set({ 'n', 'i' }, key, close_about_box, { buffer = buffer, nowait = true })
    end
    api.nvim_create_autocmd('InsertCharPre', {
        buffer = buffer,
        callback = function()
            vim.v.char = ''
        end,
    })
end

-- the bar lives in the tabline; neovim redraws it on its own schedule.
-- apparently my time is the only resource here with no fucking value.
function menu_bar.setup()
    vim.o.tabline = '%!v:lua.require("notebashpp.menu_bar").bar()'
end

return menu_bar
